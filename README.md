# Y.A.N.K

**Y**ank-safe **A**uto-unmount, **N**AS **K**ept local.
The commands are still called `shuttle`. Write-up: https://projects.jonathanearp.xyz/shuttle/

Two tools for a UGreen dock with a built-in NVMe SSD:

1. **`shuttle-ejectd`** — unmounts the SSD automatically when you close the lid,
   so you can unplug and walk away without corrupting anything.
2. **`shuttle`** — stages folders from a Synology NAS onto that SSD and pushes
   them back, so video work runs at local speed instead of over Tailscale.

---

## ⚠️ Read this first: the dock is running at USB 2.0

Measured on this machine:

| Path | Speed |
|---|---|
| Dock SSD sequential write | **38 MB/s** |
| NAS → Mac (Tailscale/SFTP, same LAN) | **7.6 MB/s** |
| USB 2.0 theoretical ceiling | ~40 MB/s |

Every USB device in the dock — both internal hubs, the Realtek LAN, and the
storage bridge — enumerates at `Device Speed = 2` (USB 2.0 High Speed,
480 Mb/s). There are **zero SuperSpeed devices** on the machine, and all three
Thunderbolt buses report no device connected.

That combination is the tell. A USB 3 hub always presents *two* device trees, a
USB 2.0 one and a separate SuperSpeed one. Only the 2.0 tree exists here, so the
SuperSpeed link is not training at all. Reformatting the drive to APFS changed
nothing (38.1 → 38.2 MB/s), which rules out the filesystem and the driver.

On a Thunderbolt 5 MacBook Pro the overwhelmingly likely cause is **the cable**:
USB-C charging cables carry only the USB 2.0 pairs and look identical to full
ones. A cable rated **USB 3.2 Gen 2 (10 Gb/s)** should take the SSD to roughly
800–1000 MB/s — a 20–25× improvement, and the difference between this cache
being a nice-to-have and being transformative.

Check any time with:

```bash
shuttle doctor
```

---

## Install

```bash
./install.sh
```

Builds the daemon, installs the LaunchAgent, and links `shuttle` into
`~/.local/bin`. Then:

```bash
shuttle setup        # NAS credentials + phone alerts
shuttle notify-test  # confirm the phone alert arrives
shuttle doctor       # full diagnostic
```

---

## 1. Auto-eject on lid close

### Why it needs two signals

Neither IOKit signal is sufficient alone:

- **`AppleClamshellState` on `IOPMrootDomain`** fires on lid close *even in
  clamshell mode* — external display plus AC power, where the Mac never sleeps
  and therefore never emits a sleep notification at all.
- **`kIOMessageCanSystemSleep` / `kIOMessageSystemWillSleep`** is the only way to
  *hold off* sleep. Between receiving one and calling `IOAllowPowerChange`, the
  system waits for us. That window is what lets the unmount — and the phone
  notification — finish before power drops and Wi-Fi dies.

The daemon registers for both.

### Unmount, not eject

It runs `diskutil unmountDisk`, not `eject`. Both flush all pending writes and
make the drive safe to unplug with no "Disk Not Ejected Properly" warning, but
unmount leaves the device node attached, so the volume can be brought back in
software when you open the lid. A true eject would need a physical replug.

### When something has files open

It **never forces**. Forcing is the exact data loss this is meant to prevent.
Instead it leaves the volume mounted and tells you what is holding it, named
from `diskutil`'s own dissent report:

```
Shuttle BUSY — held by Python (pid 52878)
```

That alert goes to **your phone as well as the Mac**, because a Mac notification
behind a closed lid is invisible. It is sent synchronously inside the
sleep-delay window, before the radio goes away.

**It is sent before the unmount is attempted, not after.** `diskutil` is
authoritative about what is blocking a volume, but it blocks on each dissenter's
timeout — a well-behaved process refuses in ~2s, while a GUI app that ignores
the request costs ~10s (measured: QuickTime Player, 12s). Waiting for that put
the alert 15s behind the lid close. So the daemon takes `lsof`'s fast answer
(~0.2s), warns immediately, and lets `diskutil` confirm afterwards. If the
volume turns out to release cleanly after all, a short "safe to unplug"
follow-up corrects the earlier warning.

Measured, lid close → phone alert: **~0.2s** to fire, ~1s to leave the machine.

A single lid close fires *both* the clamshell and the sleep notification. The
daemon guards on an in-progress flag rather than a time window, because the
unmount can outlast any sensible window — that bug sent every alert twice.

Configure via `shuttle setup`. Supports **ntfy** (default; free, no account —
install the app and subscribe to your topic), **Pushover**, or a custom webhook.

### Commands

```bash
shuttle eject           # unmount now
shuttle daemon status   # is it running, is the lid open, what disk
shuttle daemon log      # recent activity
shuttle daemon restart
```

Tune behaviour in `~/.config/shuttle/config.json`:

```jsonc
"eject": {
  "on_lid_close": true,
  "on_sleep": true,
  "remount_on_lid_open": true,   // bring it back when you reopen
  "force": false,                // leave false unless you like risk
  "settle_seconds": 1,
  "retry_seconds": 0             // >0 retries a busy volume for N seconds
}
```

### Clamshell mode is handled automatically

If you work with the lid shut and an external display, the lid closing is the
**start** of a work session, not the end — and unmounting then pulls the disk out
from under you.

The daemon reads `AppleClamshellCausesSleep` on `IOPMrootDomain` to tell the two
apart. macOS sets it to `No` when an external display is attached on AC power,
because the machine then stays awake with the lid shut. It is derived from
display and power state rather than the lid, so it is already correct at the
instant the lid closes:

| `AppleClamshellCausesSleep` | Meaning | Action |
|---|---|---|
| `Yes` | Lid close will sleep the Mac — you're leaving | unmount |
| `No` | Clamshell mode, machine stays awake — you're working | **stay mounted** |

In the clamshell case it still runs `sync()`, which costs nothing and means an
abrupt unplug loses nothing already written.

Check what it will do without having to close the lid and read the log:

```bash
shuttle daemon status
```

```
lid:     closed
mode:    CLAMSHELL (lid close keeps it awake)
on lid close: stay mounted (clamshell)
```

Set `skip_when_clamshell_active` to `false` to go back to unmounting on every
lid close.

### Leaving from clamshell mode

Staying mounted leaves one gap: you finish work, and unplug the dock without
ever sleeping the Mac. Three ways to cover it, in order of preference:

1. **Sleep the Mac before unplugging** (Apple menu → Sleep). The sleep trigger
   unmounts, and you get the phone alert if anything is still open.
2. **`shuttle eject`** — explicit, instant. Worth binding to a hotkey in
   Raycast/Alfred/Shortcuts.
3. **The idle watchdog.** Set `clamshell_idle_eject_minutes` to e.g. `20`: after
   that long with no keyboard or mouse input it assumes you left and unmounts,
   then remounts by itself when input resumes. Off by default, because it will
   also fire during a long video — and if the file is on the SSD you get a
   "still in use" alert instead of a silent unmount.

`shuttle mount` brings the volume back any time without replugging.

---

## 2. NAS cache

### The model: explicit, not transparent

This is **pin / unpin**, not a transparent on-demand cache. A real one on macOS
needs macFUSE (a kernel extension, requiring reduced security) or a File
Provider extension (a full app with special entitlements). Both are large and
fragile. Explicit staging gives the same practical result for video work with
none of that risk.

### NAS prerequisite: enable the rsync service

DSM ships `/usr/bin/rsync` as a **setuid-root, Synology-patched binary** that
refuses `--server` mode unless the rsync service is enabled. Until you tick it:

> Control Panel → File Services → **rsync** → *Enable rsync service*

...every transfer fails with a bare `Permission denied, please try again.` from
the remote side — *after* SSH has already authenticated successfully. It looks
exactly like an auth problem and is not one. The underlying error is
`rsync error: rsync service is no running (code 43)`.

`shuttle doctor` probes for this specifically and names it, and `pin`, `pull`,
`push` and `unpin` all fail fast with the fix rather than a cryptic rsync error.

Once enabled, DSM maps SSH rsync paths onto **shared-folder modules**. A real
share path like `/volume1/_Staging/...` works; the bare volume root
`/volume1/` is not itself a module and returns `module is write only`. That is
normal and not a fault.

*(Enabled and verified working on this NAS.)*

### Why rsync over SSH, not SMB

SMB is chatty and latency-sensitive; it degrades badly over a WAN link. Since
the NAS is reached over Tailscale from other networks, rsync-over-SSH is the
right transport — it streams instead of round-tripping, resumes interrupted
transfers (`--partial`), and only moves changed data.

The default cipher is `chacha20-poly1305@openssh.com`, chosen by measurement,
not assumption. On this DS220j (150 MB pulls):

| Cipher | Throughput |
|---|---|
| chacha20-poly1305 | **8.4 MB/s** |
| aes128-ctr | 8.4 MB/s |
| negotiated default | 7.3 MB/s |
| aes128-gcm | 6.9 MB/s |
| aes256-gcm | 6.9 MB/s |

The AES-GCM modes are the *slowest* here despite the ARMv8 crypto extensions —
the opposite of what you would expect. Don't "optimise" this back to AES without
re-measuring.

### Commands

```bash
shuttle ls "/volume1/Drone Footage"          # browse the NAS
shuttle pin "/volume1/Drone Footage/Trip"    # copy onto the SSD
shuttle pin "/volume1/video/Raw" --as raw    # ...under a custom name

shuttle status                                # what's cached
shuttle pull raw                              # refresh from the NAS
shuttle push raw                              # send changes back, keep local
shuttle unpin raw                             # push, verify, then free the space
```

Pinned folders get a stable path at `~/Shuttle/<name>` (a symlink onto the SSD).
Point your editor at that, so projects keep resolving even though the real files
live on `/Volumes/Shuttle/cache`.

### The safety guarantee

**`unpin` never deletes local data until the NAS copy is verified.** Verification
is a dry-run rsync in the local → remote direction: any file rsync still wants to
transfer is a file that is not safely on the NAS. Anything pending, and it
refuses to delete and leaves everything untouched.

That check is two-stage, because neither stage alone is both fast and sound:

1. **Quick check** (size + mtime) over everything. Cheap — but rsync's protocol
   carries mtime as *whole seconds*, so a file rewritten to the **same size**
   within the **same second** is invisible to it. This is a real gap, and the
   test suite demonstrates it rather than assuming it away.
2. **Checksum pass restricted to files modified since the push began** — exactly
   the window where stage 1 can be fooled, and normally only a handful of files,
   so it costs almost nothing.

`shuttle unpin --checksum` forces a full byte-for-byte pass over everything.
That is the strongest guarantee, but it reads every byte on both ends: on a
large pin, expect hours at NAS read speeds.

Run the tests:

```bash
python3 tests/test_verify.py
```

They exercise real rsync output, not fixtures — the entire risk lives in whether
our reading of `--itemize-changes` matches what rsync actually emits.

---

## Layout

```
src/ejectd/main.swift   the lid-close daemon
bin/shuttle             the cache CLI
launchd/                LaunchAgent template
tests/test_verify.py    safety-gate tests
install.sh uninstall.sh
```

Config: `~/.config/shuttle/config.json`
Log: `~/Library/Logs/shuttle-ejectd.log`
Manifest: `/Volumes/Shuttle/.shuttle/manifest.json` (travels with the drive,
mirrored to `~/.local/state/shuttle/` so `status` works when it is unplugged)

## Uninstall

```bash
./uninstall.sh   # removes the agent; leaves your config and cached data alone
```


## Credentials

`shuttle` authenticates to the NAS with the SSH key at
the SSH key set in `config.json` (default `~/.ssh/nas_agent_ed25519`). **No password is stored in, or read
by, the tool** — `config.json` contains no credential.

The NAS account password is kept in the macOS Keychain for recovery only:

```bash
security find-generic-password -a <nas-user> -s shuttle-nas -w
```
