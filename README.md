# Y.A.N.K

**Y**ank-safe **A**uto-unmount, **N**AS **K**ept local.
The commands are still called `shuttle`. Write-up: https://projects.jonathanearp.xyz/shuttle/

Two tools for a UGreen dock with an NVMe SSD built in:

1. `shuttle-ejectd` unmounts the SSD when you close the lid, so you can unplug
   and leave without corrupting anything.
2. `shuttle` copies folders from a Synology NAS onto that SSD and pushes them
   back, so video work runs at local speed instead of over Tailscale.

## Install

```bash
./install.sh
```

This builds the daemon, installs the LaunchAgent and links `shuttle` into
`~/.local/bin`. Then:

```bash
shuttle setup        # NAS details and phone alerts
shuttle notify-test  # check the phone alert arrives
shuttle doctor       # full diagnostic
```

## My dock is running at USB 2.0

Measured on my machine:

| Path | Speed |
|---|---|
| Dock SSD, sequential write | 38 MB/s |
| NAS to Mac (Tailscale/SFTP, same LAN) | 7.6 MB/s |
| USB 2.0 theoretical ceiling | ~40 MB/s |

Every USB device in the dock (both internal hubs, the Realtek LAN chip and the
storage bridge) reports `Device Speed = 2`, which is USB 2.0 High Speed,
480 Mb/s. There are no SuperSpeed devices on the machine at all, and all three
Thunderbolt buses report nothing connected.

A USB 3 hub always shows up as two device trees, a USB 2.0 one and a separate
SuperSpeed one. Only the 2.0 tree exists here, so the SuperSpeed link isn't
coming up. Reformatting the drive to APFS changed nothing (38.1 to 38.2 MB/s),
so it isn't the filesystem or the driver.

On a Thunderbolt 5 MacBook Pro the likeliest cause is the cable. USB-C charging
cables only carry the USB 2.0 pairs and look the same as full ones. A cable rated
USB 3.2 Gen 2 (10 Gb/s) should get the SSD to roughly 800-1000 MB/s, which is
20-25x faster. I got that from the spec and haven't measured it yet. Until then
the cache only beats the NAS by about 5x.

`shuttle doctor` checks the link speed every time it runs.

## 1. Unmounting on lid close

### Why it listens for two signals

Neither IOKit signal is enough on its own.

- `AppleClamshellState` on `IOPMrootDomain` changes on every lid close, including
  in clamshell mode (external display plus AC power). In that mode the Mac never
  sleeps, so no sleep notification ever arrives.
- `kIOMessageCanSystemSleep` / `kIOMessageSystemWillSleep` are the only way to
  hold off sleep. Between receiving one and calling `IOAllowPowerChange`, the
  system waits. That's the window where the unmount and the phone alert have to
  finish, before power drops and Wi-Fi goes.

So the daemon registers for both.

A single lid close fires both of them. The first version de-duplicated them with
a time window, and since an unmount can outlast any sensible window, every alert
went out twice. It uses an in-progress flag now.

### It unmounts instead of ejecting

It runs `diskutil unmountDisk`. Unmount and eject both flush pending writes and
make the drive safe to unplug with no "Disk Not Ejected Properly" warning, but
unmount leaves the device node attached, so the volume can come back in software
when you open the lid. An eject would need a physical replug.

### When something has a file open

It never forces the unmount, because forcing is exactly how you lose data. It
leaves the volume mounted and tells you what's holding it:

```
⚠️ Shuttle in use
Python has files open. Don't unplug.
```

That alert goes to your phone as well as the Mac, since a Mac notification
behind a closed lid is no use. It's sent inside the sleep-delay window, before
the radio goes.

The warning goes out before the unmount is tried. `diskutil` is the authority on
what's blocking a volume, but it waits out each process that refuses. A
well-behaved process refuses in about 2 s. QuickTime Player ignores the request
and took 12 s when I measured it. Waiting for `diskutil` put the alert 15 s
behind the lid close. Now the daemon takes `lsof`'s answer (about 0.2 s), warns
straight away, and lets `diskutil` confirm afterwards. If the volume ends up
releasing cleanly, a short "safe to unplug" follow-up corrects the warning.

Lid close to phone alert, measured: about 0.2 s to fire, and about 1 s to leave
the machine.

Alerts go through ntfy by default (free, no account: install the app and
subscribe to your topic), or Pushover, or a custom webhook. Set it up with
`shuttle setup`.

### Commands

```bash
shuttle eject           # unmount now
shuttle daemon status   # is it running, is the lid open, which disk
shuttle daemon log      # recent activity
shuttle daemon restart
```

Settings live in `~/.config/shuttle/config.json`:

```jsonc
"eject": {
  "on_lid_close": true,
  "on_sleep": true,
  "remount_on_lid_open": true,   // bring it back when you reopen
  "force": false,                // leave this off
  "settle_seconds": 1,
  "retry_seconds": 0             // >0 retries a busy volume for N seconds
}
```

### Clamshell mode

If you work with the lid shut and an external display, closing the lid is when
you start working, and unmounting then would pull the disk out from under you.

The daemon reads `AppleClamshellCausesSleep` on `IOPMrootDomain` to tell the two
cases apart. macOS sets it to `No` when an external display is attached on AC
power, because the Mac will stay awake with the lid shut. It comes from the
display and power state, so it's already right at the moment the lid closes.

| `AppleClamshellCausesSleep` | Meaning | Action |
|---|---|---|
| `Yes` | Lid close will sleep the Mac, so you're leaving | unmount |
| `No` | Clamshell mode, the Mac stays awake | stay mounted |

When it stays mounted it still runs `sync()`, so an abrupt unplug doesn't lose
anything that was already written.

To see what it will do without closing the lid:

```bash
shuttle daemon status
```

```
lid:     closed
mode:    CLAMSHELL (lid close keeps it awake)
on lid close: stay mounted (clamshell)
```

Set `skip_when_clamshell_active` to `false` to unmount on every lid close.

### Leaving from clamshell mode

Staying mounted leaves one gap: you can finish and unplug the dock without the
Mac ever going to sleep. Ways to cover it:

1. Sleep the Mac before unplugging (Apple menu > Sleep). That triggers the
   unmount, and you get the phone alert if anything is still open.
2. Run `shuttle eject`.
3. Turn on the idle watchdog. Set `clamshell_idle_eject_minutes` to something
   like `20`, and after that long with no keyboard or mouse input it unmounts,
   then remounts when input comes back. It's off by default because a long
   video counts as idle too. If the video is on the SSD you get a "still in use"
   alert, and nothing is unmounted.

`shuttle mount` brings the volume back without replugging.

## 2. The NAS cache

### Pinning by hand

You pin a folder and it gets copied onto the SSD. There's no on-demand fetching.
A transparent cache on macOS needs either macFUSE, a kernel extension that means
lowering the Mac's security settings, or a File Provider extension, which is a
whole app with special entitlements. For video work, pinning folders by hand is
enough.

### On the NAS: turn on the rsync service

DSM ships its own patched, setuid-root `/usr/bin/rsync`, and it refuses
`--server` mode unless the rsync service is on:

> Control Panel > File Services > rsync > Enable rsync service

Until you turn it on, every transfer fails with a bare
`Permission denied, please try again.` from the NAS, even though SSH has already
logged in. The real error underneath is
`rsync error: rsync service is no running (code 43)`.

`shuttle doctor` checks for this, and `pin`, `pull`, `push` and `unpin` all stop
early and tell you the fix.

Once it's on, DSM maps SSH rsync paths onto shared folders. A share path like
`/volume1/_Staging/...` works. The bare `/volume1/` isn't a shared folder and
answers `module is write only`, which is normal.

### Why rsync over SSH

SMB is chatty and slows down badly over a WAN link, and I reach the NAS over
Tailscale from other networks. rsync over SSH resumes interrupted transfers
(`--partial`) and only sends what changed.

The default cipher is `chacha20-poly1305@openssh.com`. I timed a 150 MB pull
with each cipher on my DS220j:

| Cipher | Throughput |
|---|---|
| chacha20-poly1305 | 8.4 MB/s |
| aes128-ctr | 8.4 MB/s |
| negotiated default | 7.3 MB/s |
| aes128-gcm | 6.9 MB/s |
| aes256-gcm | 6.9 MB/s |

The AES-GCM modes came last, even though the DS220j's ARM cores have crypto
extensions. Don't switch it back to AES without measuring again.

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

Pinned folders show up at `~/Shuttle/<name>`, a symlink onto the SSD. Point your
editor at that path so projects keep resolving, even though the files live in
`/Volumes/Shuttle/cache`.

### How unpin decides it's safe

`unpin` won't delete the local copy until the NAS copy is verified. The check is
a dry-run rsync from the SSD to the NAS. Any file rsync still wants to send isn't
safely on the NAS yet, and if there's even one, `unpin` refuses and leaves
everything where it is.

The check has two stages:

1. A quick check (size and mtime) over everything. It's cheap, but rsync's
   protocol carries mtime in whole seconds, so a file rewritten to the same size
   within the same second looks unchanged.
2. A checksum pass over only the files modified since the push started. That's
   the window where stage 1 can be fooled, and it's usually a handful of files.

`shuttle unpin --checksum` forces a full checksum pass over everything. It reads
every byte on both ends, so on a large pin it takes hours at NAS speeds.

Run the tests:

```bash
python3 tests/test_verify.py
```

They run real rsync instead of using fixtures, because the risk is whether my
parsing of `--itemize-changes` matches what rsync actually prints. The
same-second test first checks that the quick check really does miss the change,
then checks that stage 2 catches it.

## Layout

```
src/ejectd/main.swift   the lid-close daemon
bin/shuttle             the cache CLI
launchd/                LaunchAgent template
tests/test_verify.py    safety-gate tests
install.sh uninstall.sh
```

- Config: `~/.config/shuttle/config.json`
- Log: `~/Library/Logs/shuttle-ejectd.log`
- Manifest: `/Volumes/Shuttle/.shuttle/manifest.json`. It's stored on the drive
  and mirrored to `~/.local/state/shuttle/`, so `status` works with the dock
  unplugged.

## Uninstall

```bash
./uninstall.sh   # removes the agent, leaves your config and cached files alone
```

## Credentials

`shuttle` logs in to the NAS with the SSH key set in `config.json` (default
`~/.ssh/nas_agent_ed25519`). The tool doesn't store or read a password, and
`config.json` has no credentials in it.

The NAS account password is kept in the macOS Keychain, only for recovery:

```bash
security find-generic-password -a <nas-user> -s shuttle-nas -w
```
