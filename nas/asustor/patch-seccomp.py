"""
Patch /usr/bin/sshd-session: flip BPF filter default action
SECCOMP_RET_KILL_THREAD (k=0x00000000) -> SECCOMP_RET_ALLOW (k=0x7fff0000)
at file offset 0x90988.

Handles "Text file busy" by writing the patched content to a sibling
temp file and atomic-rename'ing it over the target. Running sshd-session
children keep their old inode; fresh execve calls pick up the patched
binary.

Idempotent. Re-runnable.
"""
import struct, sys, hashlib, shutil, os

TARGET = "/usr/bin/sshd-session"
PATCH_OFFSET = 0x90988
KILL  = bytes.fromhex("0600000000000000")
ALLOW = bytes.fromhex("060000000000ff7f")

with open(TARGET, "rb") as f:
    data = f.read()

existing = data[PATCH_OFFSET:PATCH_OFFSET + 8]
print("at 0x%05x: %s" % (PATCH_OFFSET, existing.hex()))

if existing == ALLOW:
    print("ALREADY PATCHED -- no-op")
    sys.exit(0)
if existing != KILL:
    print("UNEXPECTED bytes -- expected %s, got %s" % (KILL.hex(), existing.hex()))
    print("Refusing to patch. Aborting.")
    sys.exit(1)

# Backup
bak = TARGET + ".before-seccomp-patch"
if not os.path.exists(bak):
    shutil.copy2(TARGET, bak)
    print("Backup: %s" % bak)
else:
    print("Backup already present: %s (left untouched)" % bak)

new_data = data[:PATCH_OFFSET] + ALLOW + data[PATCH_OFFSET + 8:]
assert len(new_data) == len(data), "length mismatch -- refusing to write"

tmp_path = TARGET + ".patched-tmp"
with open(tmp_path, "wb") as f:
    f.write(new_data)
st = os.stat(TARGET)
os.chmod(tmp_path, st.st_mode)
try:
    os.chown(tmp_path, st.st_uid, st.st_gid)
except PermissionError:
    pass

os.rename(tmp_path, TARGET)
print("patched %d bytes at 0x%05x via atomic rename" % (8, PATCH_OFFSET))

with open(TARGET, "rb") as f:
    h = hashlib.sha256(f.read()).hexdigest()
print("new sha256: %s" % h)
