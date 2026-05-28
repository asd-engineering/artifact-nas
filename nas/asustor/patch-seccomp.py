"""
Patch /usr/bin/sshd-session: flip the BPF filter default action from
SECCOMP_RET_KILL_THREAD (0x00000000 — SIGSYS the child) to
SECCOMP_RET_ALLOW (0x7fff0000).

WHAT this changes
- The very last instruction of the seccomp filter (file offset 0x90988)
  is `BPF_RET+BPF_K, k=KILL_THREAD`. Any syscall not explicitly listed
  in the ALLOW/DENY chain falls through here and gets SIGSYSd.
- We change its k field from 0x00000000 to 0x7fff0000.

WHAT this does NOT touch
- The arch-mismatch kill at 0x90350 (RET KILL after AUDIT_ARCH_X86_64
  mismatch) stays — protects against ABI confusion.
- All explicit ALLOWs (read/write/futex/mmap/... ~100 of them) stay.
- All explicit DENYs returning EACCES (open/openat/lstat/fstat/...
  ~12 of them) stay.

EFFECT
- sshd-session no longer crashes with SIGSYS when its preauth privsep
  monitor calls a syscall outside the explicit allowlist. The Asustor
  build of OpenSSH 9.8p1 hits this on `unlink` (syscall 87) during
  session cleanup. Removing the kill stops the cascade
  SIGSYS → PerSourcePenalties → ipblockman.

USAGE
  sudo cp /usr/bin/sshd-session /usr/bin/sshd-session.before-seccomp-patch
  sudo python3 /tmp/patch-seccomp.py
  sudo /usr/builtin/etc/init.d/S79sftpmand stop
  sudo /usr/builtin/etc/init.d/S79sftpmand start
  ss -tlnp | grep 4589   # should now show LISTEN
"""
import struct, sys, hashlib, shutil, os

TARGET = "/usr/bin/sshd-session"
PATCH_OFFSET = 0x90988
KILL = bytes.fromhex("0600000000000000")
ALLOW = bytes.fromhex("060000000000ff7f")

with open(TARGET, "rb") as f:
    data = f.read()

existing = data[PATCH_OFFSET:PATCH_OFFSET + 8]
print("at 0x%05x: %s" % (PATCH_OFFSET, existing.hex()))

if existing == ALLOW:
    print("ALREADY PATCHED — no-op")
    sys.exit(0)
if existing != KILL:
    print("UNEXPECTED bytes — expected %s, got %s" % (KILL.hex(), existing.hex()))
    print("Refusing to patch. Aborting.")
    sys.exit(1)

# Backup
bak = TARGET + ".before-seccomp-patch"
if not os.path.exists(bak):
    shutil.copy2(TARGET, bak)
    print("Backup: %s" % bak)
else:
    print("Backup already present: %s" % bak)

new_data = data[:PATCH_OFFSET] + ALLOW + data[PATCH_OFFSET + 8:]
assert len(new_data) == len(data), "length mismatch — refusing to write"

with open(TARGET, "wb") as f:
    f.write(new_data)
os.chmod(TARGET, 0o755)
print("patched %d bytes at 0x%05x" % (8, PATCH_OFFSET))
print("new bytes: %s" % new_data[PATCH_OFFSET:PATCH_OFFSET + 8].hex())

with open(TARGET, "rb") as f:
    h = hashlib.sha256(f.read()).hexdigest()
print("new sha256: %s" % h)
