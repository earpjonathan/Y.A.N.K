// shuttle-ejectd — safely unmounts dock storage when the laptop lid closes.
//
// Two IOKit signals are needed, and neither is sufficient alone:
//
//   1. AppleClamshellState on IOPMrootDomain — fires on lid close even in
//      clamshell mode (external display + AC power), where the Mac never sleeps
//      and therefore never emits a sleep notification at all.
//
//   2. kIOMessageCanSystemSleep / kIOMessageSystemWillSleep — the only way to
//      hold off sleep. Between receiving one of these and calling
//      IOAllowPowerChange, the system waits for us. That window is what makes
//      the unmount (and the phone notification) actually complete before power
//      drops and Wi-Fi dies.

import Foundation
import IOKit
import IOKit.pwr_mgt

// MARK: - IOKit message constants
// iokit_common_msg(x) == 0xE0000000 | x   (see IOKit/IOMessage.h)
let kMsgCanSystemSleep:    UInt32 = 0xE0000270
let kMsgSystemWillSleep:   UInt32 = 0xE0000280
let kMsgSystemHasPoweredOn: UInt32 = 0xE0000300
let kMsgSystemWillPowerOn: UInt32 = 0xE0000320

// MARK: - Logging

let logQueue = DispatchQueue(label: "shuttle.log")
let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

let logPath = ("~/Library/Logs/shuttle-ejectd.log" as NSString).expandingTildeInPath

// The daemon writes its own log rather than relying on launchd's
// StandardErrorPath, which proved unreliable for this agent: the redirect
// silently dropped every line across restarts. Owning the file makes logging
// deterministic and lets `shuttle daemon log` always work.
let logHandle: FileHandle? = {
    let fm = FileManager.default
    let dir = (logPath as NSString).deletingLastPathComponent
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if !fm.fileExists(atPath: logPath) {
        fm.createFile(atPath: logPath, contents: nil)
    }
    guard let h = FileHandle(forWritingAtPath: logPath) else { return nil }
    // Crude rotation: this agent logs a handful of lines per lid event, so a
    // size cap is plenty and avoids pulling in a rotation dependency.
    if let attrs = try? fm.attributesOfItem(atPath: logPath),
       let size = attrs[.size] as? UInt64, size > 5_000_000 {
        try? h.truncate(atOffset: 0)
    }
    return h
}()

func log(_ level: String, _ message: String) {
    logQueue.sync {
        let line = "[\(isoFormatter.string(from: Date()))] \(level) \(message)\n"
        let data = Data(line.utf8)
        if let h = logHandle {
            h.seekToEndOfFile()      // re-seek: another instance may have appended
            h.write(data)
        }
        FileHandle.standardError.write(data)
    }
}
func info(_ m: String)  { log("INFO ", m) }
func warn(_ m: String)  { log("WARN ", m) }
func error(_ m: String) { log("ERROR", m) }

// MARK: - Subprocess helper

@discardableResult
func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 30) -> (status: Int32, output: String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: launchPath)
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe

    do { try proc.run() } catch {
        return (-1, "failed to launch \(launchPath): \(error)")
    }

    // Drain concurrently so a chatty child can never deadlock on a full pipe.
    var data = Data()
    let drain = DispatchQueue(label: "shuttle.drain")
    let done = DispatchSemaphore(value: 0)
    drain.async {
        data = pipe.fileHandleForReading.readDataToEndOfFile()
        done.signal()
    }

    let deadline = Date().addingTimeInterval(timeout)
    while proc.isRunning && Date() < deadline {
        usleep(50_000)
    }
    if proc.isRunning {
        warn("timeout after \(Int(timeout))s, terminating: \(launchPath) \(args.joined(separator: " "))")
        proc.terminate()
        usleep(200_000)
        if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
    }
    proc.waitUntilExit()
    _ = done.wait(timeout: .now() + 3)
    let out = String(data: data, encoding: .utf8) ?? ""
    return (proc.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines))
}

// MARK: - Configuration

struct NotifyPhone {
    var provider = "ntfy"          // ntfy | pushover | webhook | none
    var server   = "https://ntfy.sh"
    var topic    = ""
    var priority = "urgent"
    var pushoverToken = ""
    var pushoverUser  = ""
    var webhookURL    = ""
    var enabled: Bool {
        switch provider {
        case "ntfy":     return !topic.isEmpty
        case "pushover": return !pushoverToken.isEmpty && !pushoverUser.isEmpty
        case "webhook":  return !webhookURL.isEmpty
        default:         return false
        }
    }
}

struct Config {
    var volume            = "Shuttle"
    var onLidClose        = true
    var skipWhenClamshell = true
    var idleEjectMinutes  = 0.0
    var onSleep           = true
    var remountOnLidOpen  = true
    var force             = false
    var settleSeconds     = 1.0
    var retrySeconds      = 0.0
    var notifyMac         = true
    var phone             = NotifyPhone()

    static let path = ("~/.config/shuttle/config.json" as NSString).expandingTildeInPath

    // Hand-rolled rather than Codable: the CLI writes this same file, and a
    // forgiving parser means an unknown or missing key degrades to a default
    // instead of taking the daemon down.
    static func load() -> Config {
        var c = Config()
        guard let data = FileManager.default.contents(atPath: path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            warn("no config at \(path); using defaults")
            return c
        }
        if let v = root["volume"] as? String, !v.isEmpty { c.volume = v }
        if let e = root["eject"] as? [String: Any] {
            c.onLidClose       = e["on_lid_close"]        as? Bool   ?? c.onLidClose
            c.skipWhenClamshell = e["skip_when_clamshell_active"] as? Bool ?? c.skipWhenClamshell
            c.idleEjectMinutes = e["clamshell_idle_eject_minutes"] as? Double ?? c.idleEjectMinutes
            c.onSleep          = e["on_sleep"]            as? Bool   ?? c.onSleep
            c.remountOnLidOpen = e["remount_on_lid_open"] as? Bool   ?? c.remountOnLidOpen
            c.force            = e["force"]               as? Bool   ?? c.force
            c.settleSeconds    = e["settle_seconds"]      as? Double ?? c.settleSeconds
            c.retrySeconds     = e["retry_seconds"]       as? Double ?? c.retrySeconds
        }
        if let n = root["notify"] as? [String: Any] {
            c.notifyMac = n["mac"] as? Bool ?? c.notifyMac
            if let p = n["phone"] as? [String: Any] {
                c.phone.provider      = p["provider"]       as? String ?? c.phone.provider
                c.phone.server        = p["server"]         as? String ?? c.phone.server
                c.phone.topic         = p["topic"]          as? String ?? c.phone.topic
                c.phone.priority      = p["priority"]       as? String ?? c.phone.priority
                c.phone.pushoverToken = p["pushover_token"] as? String ?? c.phone.pushoverToken
                c.phone.pushoverUser  = p["pushover_user"]  as? String ?? c.phone.pushoverUser
                c.phone.webhookURL    = p["webhook_url"]    as? String ?? c.phone.webhookURL
            }
        }
        return c
    }
}

// MARK: - Notifications

enum Notifier {
    static func mac(title: String, body: String, config: Config) {
        guard config.notifyMac else { return }
        // Escaped for AppleScript string literals.
        let esc = { (s: String) in
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let script = "display notification \"\(esc(body))\" with title \"\(esc(title))\""
        run("/usr/bin/osascript", ["-e", script], timeout: 5)
    }

    /// Synchronous by design: this must reach the network before we release the
    /// sleep hold, because once the machine sleeps the radio is gone.
    static func phone(title: String, body: String, config: Config) {
        let p = config.phone
        guard p.enabled else {
            info("phone notification skipped (provider '\(p.provider)' not configured)")
            return
        }
        var args: [String]
        switch p.provider {
        case "ntfy":
            let url = p.server.hasSuffix("/") ? "\(p.server)\(p.topic)" : "\(p.server)/\(p.topic)"
            args = ["-fsS", "--max-time", "6",
                    "-H", "Title: \(title)",
                    "-H", "Priority: \(p.priority)",
                    "-H", "Tags: warning,floppy_disk",
                    "-d", body, url]
        case "pushover":
            args = ["-fsS", "--max-time", "6",
                    "--form-string", "token=\(p.pushoverToken)",
                    "--form-string", "user=\(p.pushoverUser)",
                    "--form-string", "title=\(title)",
                    "--form-string", "message=\(body)",
                    "--form-string", "priority=1",
                    "https://api.pushover.net/1/messages.json"]
        case "webhook":
            let payload: [String: String] = ["title": title, "message": body]
            let json = (try? JSONSerialization.data(withJSONObject: payload)).flatMap {
                String(data: $0, encoding: .utf8)
            } ?? "{}"
            args = ["-fsS", "--max-time", "6",
                    "-H", "Content-Type: application/json",
                    "-d", json, p.webhookURL]
        default:
            return
        }
        let r = run("/usr/bin/curl", args, timeout: 8)
        if r.status == 0 {
            info("phone notification sent via \(p.provider)")
        } else {
            warn("phone notification FAILED via \(p.provider) (exit \(r.status)): \(r.output)")
        }
    }

    static func both(title: String, body: String, config: Config) {
        mac(title: title, body: body, config: config)
        phone(title: title, body: body, config: config)
    }
}

// MARK: - Disk operations

struct DiskOps {
    /// Resolve a volume name to its *whole disk* identifier (e.g. "disk5").
    /// Never cache this: the identifier changes across replug and reformat.
    static func wholeDisk(forVolume name: String) -> String? {
        let mountPoint = "/Volumes/\(name)"
        guard FileManager.default.fileExists(atPath: mountPoint) else { return nil }
        let r = run("/usr/sbin/diskutil", ["info", "-plist", mountPoint], timeout: 15)
        guard r.status == 0, let data = r.output.data(using: .utf8) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any] else { return nil }
        if let parent = plist["ParentWholeDisk"] as? String { return parent }
        return plist["DeviceIdentifier"] as? String
    }

    static func isMounted(volume: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: "/Volumes/\(volume)", isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    /// diskutil names the exact process that refused the unmount, e.g.
    ///   "Unmount was dissented by PID 52841 (/path/to/Python)"
    /// That is authoritative and free, so prefer it over shelling out to lsof —
    /// which is slow, and we are inside a sleep-delay window.
    static func dissenters(from output: String) -> [String] {
        var found: [String] = []
        for raw in output.split(separator: "\n") {
            let line = String(raw)
            guard line.contains("dissented by PID"),
                  let r = line.range(of: "PID ") else { continue }
            let rest = line[r.upperBound...]
            let pid = String(rest.prefix(while: { $0.isNumber }))
            var name = ""
            if let open = rest.firstIndex(of: "("), let close = rest.lastIndex(of: ")"),
               open < close {
                let path = String(rest[rest.index(after: open)..<close])
                name = (path as NSString).lastPathComponent
            }
            let label = name.isEmpty ? "pid \(pid)" : "\(name) (pid \(pid))"
            if !found.contains(label) { found.append(label) }
        }
        return found
    }

    /// Processes holding files open on the volume. Only called on failure —
    /// lsof is slow, and we are inside a sleep-delay window.
    static func blockers(volume: String) -> [String] {
        let r = run("/usr/sbin/lsof", ["-Fcn", "--", "/Volumes/\(volume)"], timeout: 8)
        guard !r.output.isEmpty else { return [] }
        var names = Set<String>()
        for line in r.output.split(separator: "\n") {
            if line.hasPrefix("c") { names.insert(String(line.dropFirst())) }
        }
        // Finder always holds a handle on any mounted volume; naming it as a
        // blocker is noise, not signal.
        names.remove("Finder")
        return names.sorted()
    }

    /// System processes that hold a handle on every mounted volume but always
    /// release it on unmount. Naming them as blockers would be a false alarm.
    static let benignHolders: Set<String> = [
        "Finder", "mds", "mds_stores", "mdworker", "mdworker_shared",
        "fseventsd", "Spotlight", "diskarbitrationd", "distnoted",
    ]

    /// Fast look at what is holding the volume, used BEFORE attempting the
    /// unmount so the phone alert can go out immediately.
    ///
    /// diskutil is authoritative but slow: it asks each dissenter and waits out
    /// a timeout. A well-behaved process refuses in ~2s; a GUI app that ignores
    /// the request costs ~10s (measured: QuickTime Player, 12s). Waiting for
    /// that before notifying is what made the alert arrive 15s after lid close.
    /// lsof answers in well under a second, so we warn on its answer and let
    /// diskutil confirm afterwards.
    static func likelyBlockers(volume: String) -> [String] {
        let r = run("/usr/sbin/lsof", ["-w", "-Fcn", "--", "/Volumes/\(volume)"],
                    timeout: 4)
        guard !r.output.isEmpty else { return [] }
        var names = Set<String>()
        for line in r.output.split(separator: "\n") where line.hasPrefix("c") {
            names.insert(String(line.dropFirst()))
        }
        return names.subtracting(benignHolders).sorted()
    }

    enum Result {
        case notPresent
        case unmounted
        case busy(blockers: [String], detail: String)
        case failed(detail: String)
    }

    static func unmount(volume: String, force: Bool) -> Result {
        guard isMounted(volume: volume) else { return .notPresent }
        guard let disk = wholeDisk(forVolume: volume) else {
            return .failed(detail: "could not resolve whole disk for \(volume)")
        }
        var args = ["unmountDisk"]
        if force { args.append("force") }
        args.append("/dev/\(disk)")

        let r = run("/usr/sbin/diskutil", args, timeout: 25)
        if r.status == 0 { return .unmounted }
        // Confirm against reality rather than trusting the exit code alone.
        if !isMounted(volume: volume) { return .unmounted }
        let named = dissenters(from: r.output)
        let who = named.isEmpty ? blockers(volume: volume) : named
        let lower = r.output.lowercased()
        if !who.isEmpty || lower.contains("busy") || lower.contains("in use")
            || lower.contains("dissent") {
            return .busy(blockers: who, detail: r.output)
        }
        return .failed(detail: r.output)
    }

    static func remount(volume: String) {
        guard !isMounted(volume: volume) else { return }
        // After unmountDisk the device node persists, so a software remount
        // works as long as the dock was not physically unplugged.
        //
        // Note: this must NOT filter on `physical`. An APFS volume lives on a
        // synthesized disk, which that filter hides — leaving only the EFI
        // partition and the container's physical store, neither of which is
        // mountable as the volume. Match on VolumeName so we mount exactly the
        // intended volume and never blindly mount an unrelated disk.
        let r = run("/usr/sbin/diskutil", ["list", "-plist", "external"], timeout: 15)
        guard r.status == 0, let data = r.output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let disks = plist["AllDisksAndPartitions"] as? [[String: Any]]
        else {
            warn("remount: could not enumerate external disks")
            return
        }

        var target: String?
        outer: for d in disks {
            for key in ["APFSVolumes", "Partitions"] {
                for entry in (d[key] as? [[String: Any]]) ?? [] {
                    if entry["VolumeName"] as? String == volume,
                       let id = entry["DeviceIdentifier"] as? String {
                        target = id
                        break outer
                    }
                }
            }
        }

        guard let id = target else {
            info("remount: volume '\(volume)' not present (dock unplugged?)")
            return
        }
        let m = run("/usr/sbin/diskutil", ["mount", id], timeout: 20)
        if m.status == 0 && isMounted(volume: volume) {
            info("remounted \(volume) from \(id)")
        } else {
            warn("remount of \(volume) (\(id)) failed: \(m.output)")
        }
    }
}

// MARK: - Daemon

final class Daemon {
    private var config: Config
    private var rootPort: io_connect_t = 0
    private var powerNotifier: io_object_t = 0
    private var clamshellNotifier: io_object_t = 0
    private var notifyPort: IONotificationPortRef?
    private var lidClosed = false
    private var lastActionAt = Date.distantPast
    private var inProgress = false
    private let gate = NSLock()
    private var idleWatchdog: DispatchSourceTimer?
    private var ejectedForIdle = false

    init(config: Config) { self.config = config }

    // MARK: Clamshell

    static func clamshellClosed() -> Bool? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault,
                                                IOServiceMatching("IOPMrootDomain"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let cf = IORegistryEntryCreateCFProperty(
                entry, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        else { return nil }
        return (cf.takeRetainedValue() as? Bool)
    }

    /// Whether closing the lid will actually put the machine to sleep.
    ///
    /// This is the discriminator between "closing the lid to leave" and
    /// "working in clamshell mode". macOS sets it to No when an external
    /// display is attached on AC power, because the machine then stays awake
    /// with the lid shut. It is derived from display + power state, not from
    /// the lid, so it is already correct at the moment the lid closes.
    static func clamshellCausesSleep() -> Bool? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault,
                                                IOServiceMatching("IOPMrootDomain"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let cf = IORegistryEntryCreateCFProperty(
                entry, "AppleClamshellCausesSleep" as CFString, kCFAllocatorDefault, 0)
        else { return nil }
        return (cf.takeRetainedValue() as? Bool)
    }

    /// Seconds since the last keyboard/mouse event, from IOHIDSystem.
    static func hidIdleSeconds() -> Double? {
        let r = run("/usr/sbin/ioreg", ["-c", "IOHIDSystem", "-d", "4"], timeout: 8)
        guard let line = r.output.split(separator: "\n")
                .first(where: { $0.contains("HIDIdleTime") }) else { return nil }
        let digits = line.filter { $0.isNumber }
        guard let ns = Double(digits) else { return nil }
        return ns / 1_000_000_000.0   // IOHIDSystem reports nanoseconds
    }

    // MARK: Core action

    /// Reloads config each time so edits take effect without a restart.
    func performUnmount(reason: String) {
        // One lid close fires BOTH the clamshell and the sleep notification, and
        // the unmount itself can take >10s. A purely time-based debounce is
        // useless here: the window expires while the first attempt is still
        // running, so the second trigger starts a whole duplicate run and the
        // user gets two alerts. Guard on actual progress instead.
        gate.lock()
        if inProgress {
            gate.unlock()
            info("skipping trigger (\(reason)) — an unmount is already running")
            return
        }
        if Date().timeIntervalSince(lastActionAt) < 3 {
            gate.unlock()
            info("skipping duplicate trigger (\(reason)) within debounce window")
            return
        }
        inProgress = true
        gate.unlock()
        defer {
            gate.lock()
            inProgress = false
            lastActionAt = Date()   // debounce from completion, not from start
            gate.unlock()
        }

        config = Config.load()
        let vol = config.volume
        guard DiskOps.isMounted(volume: vol) else {
            info("\(vol) not mounted; nothing to do (\(reason))")
            return
        }

        let began = Date()
        info("trigger=\(reason) — unmounting \(vol)")

        // Warn on lsof's fast answer rather than waiting for diskutil. diskutil
        // is authoritative but blocks on each dissenter's timeout, which is what
        // delayed the alert by ~15s. Getting the phone alert out in under a
        // second matters more than being certain, because the failure mode of a
        // false alarm is mild and the failure mode of a late alert is unplugging
        // a mounted disk.
        let holders = DiskOps.likelyBlockers(volume: vol)
        var warned = false
        if !holders.isEmpty {
            let list = holders.joined(separator: ", ")
            warn("\(vol) looks busy — \(list) — alerting now "
                 + "(\(String(format: "%.2f", Date().timeIntervalSince(began)))s)")
            // Short body: it has to fit in the APNs payload, or the iOS app has
            // to fetch it from the server and delivery gets slower.
            Notifier.phone(title: "⚠️ \(vol) in use",
                           body: "\(list) has files open. Don't unplug.",
                           config: config)
            warned = true
        }

        if config.settleSeconds > 0 {
            Thread.sleep(forTimeInterval: config.settleSeconds)
        }
        sync()   // flush the unified buffer cache before asking diskutil

        var result = DiskOps.unmount(volume: vol, force: config.force)

        if case .busy = result, config.retrySeconds > 0 {
            info("busy; retrying for \(Int(config.retrySeconds))s")
            let deadline = Date().addingTimeInterval(config.retrySeconds)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 1.0)
                result = DiskOps.unmount(volume: vol, force: config.force)
                if case .busy = result { continue }
                break
            }
        }

        let elapsed = String(format: "%.1f", Date().timeIntervalSince(began))
        switch result {
        case .unmounted:
            info("\(vol) unmounted — safe to unplug (\(elapsed)s)")
            if warned {
                // We already said "don't unplug"; that is now wrong, so correct it.
                Notifier.phone(title: "✅ \(vol) ejected",
                               body: "Released after all. Safe to unplug.",
                               config: config)
            }
            Notifier.mac(title: "Shuttle ejected",
                         body: "\(vol) is unmounted. Safe to unplug.",
                         config: config)
        case .notPresent:
            info("\(vol) disappeared before unmount completed")
        case .busy(let who, let detail):
            let named = !who.isEmpty ? who : holders
            let list = named.isEmpty ? "an unknown process" : named.joined(separator: ", ")
            error("\(vol) BUSY — held by \(list) (\(elapsed)s). \(detail)")
            if !warned {   // pre-check missed it; this is the first they hear
                Notifier.phone(title: "⚠️ \(vol) NOT ejected",
                               body: "\(list) has files open. Don't unplug.",
                               config: config)
            }
            Notifier.mac(title: "⚠️ Shuttle NOT ejected",
                         body: "Still in use by \(list). Left mounted — do not unplug.",
                         config: config)
        case .failed(let detail):
            error("\(vol) unmount failed (\(elapsed)s): \(detail)")
            Notifier.phone(title: "⚠️ \(vol) eject failed",
                           body: "Could not unmount. Don't unplug.",
                           config: config)
            Notifier.mac(title: "⚠️ Shuttle eject failed",
                         body: "Could not unmount \(vol). Left mounted — do not unplug.",
                         config: config)
        }
    }

    // MARK: Event handlers

    func handleClamshell() {
        guard let closed = Daemon.clamshellClosed() else { return }
        guard closed != lidClosed else { return }
        lidClosed = closed
        info("lid \(closed ? "closed" : "opened")")

        if closed {
            guard config.onLidClose else { return }

            // Clamshell mode: an external display on AC power, so the machine
            // stays awake and the user is still working at it. Unmounting here
            // pulled the disk out from under a live session — the lid closing
            // is the START of the work session, not the end of it.
            if config.skipWhenClamshell, Daemon.clamshellCausesSleep() == false {
                info("lid closed but clamshell keeps the machine awake — "
                     + "leaving \(config.volume) mounted")
                // Flush regardless: costs nothing, and means an abrupt unplug
                // loses nothing that had already been written.
                sync()
                startIdleWatchdog()
                return
            }
            performUnmount(reason: "lid-close")
        } else {
            stopIdleWatchdog()
            ejectedForIdle = false
            if config.remountOnLidOpen {
                // The unmount leaves the device attached, so this brings the
                // volume back without a replug — provided it was not
                // physically removed.
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self else { return }
                    DiskOps.remount(volume: self.config.volume)
                }
            }
        }
    }

    // MARK: Idle watchdog
    //
    // Covers the gap left by staying mounted in clamshell mode: you close the
    // lid, walk away, and later unplug the dock without ever sleeping the
    // machine. After a long stretch with no keyboard or mouse input we assume
    // you have gone and unmount; if input resumes we put it straight back.

    func startIdleWatchdog() {
        stopIdleWatchdog()
        guard config.idleEjectMinutes > 0 else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        t.schedule(deadline: .now() + 60, repeating: 60)
        t.setEventHandler { [weak self] in self?.idleTick() }
        t.resume()
        idleWatchdog = t
        info("idle watchdog armed — unmount after \(Int(config.idleEjectMinutes)) min without input")
    }

    func stopIdleWatchdog() {
        idleWatchdog?.cancel()
        idleWatchdog = nil
    }

    func idleTick() {
        // Only meaningful while the lid is shut and clamshell is holding us awake.
        guard lidClosed, Daemon.clamshellCausesSleep() == false else { return }
        guard let idle = Daemon.hidIdleSeconds() else { return }
        let threshold = config.idleEjectMinutes * 60
        let mounted = DiskOps.isMounted(volume: config.volume)

        if idle >= threshold, mounted {
            info("clamshell idle \(Int(idle))s — assuming you left; unmounting")
            ejectedForIdle = true
            performUnmount(reason: "clamshell-idle")
        } else if idle < threshold, ejectedForIdle, !mounted {
            info("input resumed after an idle unmount — remounting")
            ejectedForIdle = false
            DiskOps.remount(volume: config.volume)
        }
    }

    func handlePower(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case kMsgCanSystemSleep, kMsgSystemWillSleep:
            let label = messageType == kMsgCanSystemSleep ? "can-sleep" : "will-sleep"
            info("power: \(label) — holding sleep while we unmount")
            if config.onSleep { performUnmount(reason: label) }
            // Releasing the hold is mandatory. Skipping it wedges sleep entirely,
            // so it must happen on every path out of this branch.
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
            info("power: sleep hold released")

        case kMsgSystemHasPoweredOn, kMsgSystemWillPowerOn:
            info("power: woke")
            lidClosed = Daemon.clamshellClosed() ?? false
            if config.remountOnLidOpen && !lidClosed {
                DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self else { return }
                    DiskOps.remount(volume: self.config.volume)
                }
            }
        default:
            break
        }
    }

    // MARK: Wiring

    func start() -> Bool {
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        let powerCallback: IOServiceInterestCallback = { refcon, _, messageType, argument in
            guard let refcon else { return }
            Unmanaged<Daemon>.fromOpaque(refcon).takeUnretainedValue()
                .handlePower(messageType: messageType, argument: argument)
        }

        var pPort: IONotificationPortRef?
        rootPort = IORegisterForSystemPower(ctx, &pPort, powerCallback, &powerNotifier)
        guard rootPort != 0, let pPort else {
            error("IORegisterForSystemPower failed — cannot hold off sleep")
            return false
        }
        notifyPort = pPort
        CFRunLoopAddSource(CFRunLoopGetCurrent(),
                           IONotificationPortGetRunLoopSource(pPort).takeUnretainedValue(),
                           .defaultMode)

        // Clamshell interest on the same port.
        let clamshellCallback: IOServiceInterestCallback = { refcon, _, _, _ in
            guard let refcon else { return }
            Unmanaged<Daemon>.fromOpaque(refcon).takeUnretainedValue().handleClamshell()
        }
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault,
                                                    IOServiceMatching("IOPMrootDomain"))
        if rootDomain != 0 {
            let kr = IOServiceAddInterestNotification(pPort, rootDomain, kIOGeneralInterest,
                                                      clamshellCallback, ctx, &clamshellNotifier)
            IOObjectRelease(rootDomain)
            if kr != KERN_SUCCESS {
                warn("clamshell notification unavailable (\(kr)); sleep events only")
            }
        } else {
            warn("IOPMrootDomain not found; sleep events only")
        }

        lidClosed = Daemon.clamshellClosed() ?? false
        info("shuttle-ejectd started — volume='\(config.volume)' lid=\(lidClosed ? "closed" : "open") " +
             "phone=\(config.phone.enabled ? config.phone.provider : "disabled")")
        return true
    }
}

// MARK: - Entry point

setvbuf(stderr, nil, _IOLBF, 0)
var config = Config.load()

// One-shot modes, used by the CLI and for testing without touching launchd.
let args = CommandLine.arguments
if args.contains("--eject-now") {
    let d = Daemon(config: config)
    d.performUnmount(reason: "manual")
    exit(0)
}
if args.contains("--remount-now") {
    DiskOps.remount(volume: config.volume)
    exit(DiskOps.isMounted(volume: config.volume) ? 0 : 1)
}
if args.contains("--test-concurrent") {
    // Fires two performUnmount calls at once in ONE process, which is what a
    // real lid close does (clamshell + will-sleep). Exactly one should run.
    let d = Daemon(config: config)
    let g = DispatchGroup()
    for label in ["lid-close", "will-sleep"] {
        g.enter()
        DispatchQueue.global().async {
            d.performUnmount(reason: label)
            g.leave()
        }
    }
    g.wait()
    exit(0)
}
if args.contains("--test-notify") {
    Notifier.both(title: "Shuttle test",
                  body: "If this reached your phone, notifications are working.",
                  config: config)
    exit(0)
}
if args.contains("--status") {
    let mounted = DiskOps.isMounted(volume: config.volume)
    let lid = Daemon.clamshellClosed()
    let causes = Daemon.clamshellCausesSleep()
    print("volume:  \(config.volume)")
    print("mounted: \(mounted)")
    print("disk:    \(DiskOps.wholeDisk(forVolume: config.volume) ?? "-")")
    print("lid:     \(lid == nil ? "unknown" : (lid! ? "closed" : "open"))")
    if let c = causes {
        print("mode:    \(c ? "normal (lid close sleeps the Mac)" : "CLAMSHELL (lid close keeps it awake)")")
    }
    // Say plainly what would happen, so the behaviour is verifiable without
    // having to close the lid and read the log afterwards.
    let wouldSkip = config.skipWhenClamshell && causes == false
    print("on lid close: \(config.onLidClose ? (wouldSkip ? "stay mounted (clamshell)" : "unmount") : "nothing (disabled)")")
    if let idle = Daemon.hidIdleSeconds() {
        print("input idle: \(Int(idle))s")
    }
    print("idle eject: \(config.idleEjectMinutes > 0 ? "after \(Int(config.idleEjectMinutes)) min" : "off")")
    print("phone:   \(config.phone.enabled ? config.phone.provider : "disabled")")
    exit(0)
}

let daemon = Daemon(config: config)
guard daemon.start() else { exit(1) }
CFRunLoopRun()
