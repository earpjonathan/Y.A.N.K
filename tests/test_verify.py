#!/usr/bin/env python3
"""Exercises the gate that protects unpin from deleting unsynced data.

Uses real rsync output rather than fixtures: the whole risk lives in whether
our reading of --itemize-changes matches what rsync actually emits.
"""
import importlib.util
import importlib.machinery
import shutil, subprocess, sys, tempfile
from pathlib import Path

spec = importlib.util.spec_from_loader(
    "shuttle", importlib.machinery.SourceFileLoader(
        "shuttle", str(Path(__file__).resolve().parent.parent / "bin" / "shuttle")))
sh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sh)

RSYNC = sh.find_rsync()
FAILURES = []


def check(label, cond):
    print(f"  {'PASS' if cond else 'FAIL'}  {label}")
    if not cond:
        FAILURES.append(label)


def itemize(src: Path, dst: Path, checksum=False):
    """Local dry-run mirroring what verify_synced does over SSH."""
    cmd = [RSYNC, "-rlptD", "--no-owner", "--no-group", "--dry-run",
           "--itemize-changes", "--out-format=%i %n"]
    if checksum:
        cmd.append("--checksum")
    for e in sh.EXCLUDES:
        cmd += ["--exclude", e]
    cmd += [f"{src}/", f"{dst}/"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return sh.parse_pending(r.stdout)


def main():
    tmp = Path(tempfile.mkdtemp(prefix="shuttle-test-"))
    src, dst = tmp / "local", tmp / "nas"
    (src / "sub").mkdir(parents=True)
    dst.mkdir()
    (src / "a.mov").write_bytes(b"A" * 4096)
    (src / "sub" / "b.mov").write_bytes(b"B" * 8192)

    print("\n1. Nothing copied yet -> everything must be pending")
    p = itemize(src, dst)
    check("detects unsynced files", len(p) >= 2)

    print("\n2. After a real copy -> must verify clean")
    subprocess.run([RSYNC, "-rlptD", "--no-owner", "--no-group",
                    f"{src}/", f"{dst}/"], capture_output=True)
    p = itemize(src, dst)
    check("clean after sync (no false positives)", p == [])

    print("\n3. Modified file, DIFFERENT size -> quick check catches it")
    (src / "a.mov").write_bytes(b"C" * 9000)
    p = itemize(src, dst)
    check("detects size change", any("a.mov" in x for x in p))

    print("\n4. New local file -> must be caught")
    subprocess.run([RSYNC, "-rlptD", "--no-owner", "--no-group",
                    f"{src}/", f"{dst}/"], capture_output=True)
    (src / "new.mov").write_bytes(b"D" * 2048)
    p = itemize(src, dst)
    check("detects new file", any("new.mov" in x for x in p))

    print("\n5. Same size, same second -> quick check is blind, stage 2 must catch it")
    subprocess.run([RSYNC, "-rlptD", "--no-owner", "--no-group",
                    f"{src}/", f"{dst}/"], capture_output=True)
    import os, time
    push_started = time.time()
    tgt = src / "a.mov"
    st = tgt.stat()
    tgt.write_bytes(b"Z" * 9000)                      # identical size
    os.utime(tgt, (st.st_atime, st.st_mtime))         # identical whole-second mtime

    fast = itemize(src, dst)
    check("quick check is blind here (the gap we must cover)", fast == [])

    recent = sh.files_modified_since(src, push_started - 2)
    check("stage 2 flags the file as recently touched", "a.mov" in recent)

    # Stage 2: checksum pass restricted to that file
    import tempfile as tf
    with tf.NamedTemporaryFile("w", suffix=".lst", delete=False) as fh:
        fh.write(chr(10).join(recent) + chr(10))
        lst = fh.name
    cmd = [RSYNC, "-rlptD", "--no-owner", "--no-group", "--dry-run",
           "--itemize-changes", "--out-format=%i %n", "--checksum",
           "--files-from", lst, f"{src}/", f"{dst}/"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    staged = sh.parse_pending(r.stdout)
    os.unlink(lst)
    check("stage 2 checksum catches the silent change", any("a.mov" in x for x in staged))

    print("\n6. Synology noise must not block verification")
    subprocess.run([RSYNC, "-rlptD", "--no-owner", "--no-group",
                    f"{src}/", f"{dst}/"], capture_output=True)
    (src / "@eaDir").mkdir(exist_ok=True)
    (src / "@eaDir" / "junk").write_bytes(b"x")
    (src / ".DS_Store").write_bytes(b"x")
    p = itemize(src, dst)
    check("@eaDir and .DS_Store excluded", p == [])

    shutil.rmtree(tmp, ignore_errors=True)
    print(f"\n{'ALL PASSED' if not FAILURES else 'FAILURES: ' + ', '.join(FAILURES)}")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
