#!/usr/bin/env python3
"""
Surgical binary patch: Asustor's sshd-session has DefaultAllowGroups
hardcoded to "administrators". Replace with "users" so users in `users`
group (primary GID 100) pass the AllowGroups check WITHOUT being
granted sudo/ADM admin via UNIX `administrators` membership.

Patches ONLY the "administrators" string that immediately follows the
"DefaultAllowGroups" symbol — other "administrators" references
(Is_Nas_Administrators_Member, log messages) are left intact so
legitimate admin checks still function for Kelvin/admin.

Replacement is "users" (5 bytes + null) padded with 9 nulls to keep
the 15-byte slot identical → no shift in subsequent offsets.
"""
import os, shutil, sys

BIN = "/usr/bin/sshd-session"
BACKUP = "/usr/bin/sshd-session.asustor-original"

ORIGINAL = b"administrators\x00"            # 15 bytes
REPLACEMENT = b"users\x00" + b"\x00" * 9    # 15 bytes
assert len(ORIGINAL) == 15 == len(REPLACEMENT), "patch slot size mismatch"

if not os.path.isfile(BIN):
    sys.exit(f"ERROR: {BIN} not found")

# 1. Backup (idempotent)
if not os.path.isfile(BACKUP):
    shutil.copy2(BIN, BACKUP)
    print(f"→ backed up {BIN} to {BACKUP}")
else:
    print(f"  backup already exists at {BACKUP}")

data = open(BIN, "rb").read()

# 2. Find DefaultAllowGroups symbol
sym_off = data.find(b"DefaultAllowGroups\x00")
if sym_off < 0:
    sys.exit("ERROR: 'DefaultAllowGroups' symbol not found — binary may already be patched, "
             "or sshd-session is a different version. To force re-patch, restore from backup first: "
             f"cp {BACKUP} {BIN}")
print(f"→ DefaultAllowGroups symbol at offset: {sym_off} (0x{sym_off:x})")

# 3. Find the "administrators" value string AFTER the symbol — but
#    skip the "DefaultAllowGroups" symbol itself (which starts with
#    same prefix? no — but other "administrators" strings may precede)
# Scan from a window after the symbol to find the closest match.
search_start = sym_off + len(b"DefaultAllowGroups\x00")
search_end = sym_off + 256  # don't look too far — value is adjacent
admin_off = data.find(ORIGINAL, search_start, search_end)
if admin_off < 0:
    # Fall back: maybe "administrators" without null term (unlikely for default)
    admin_off = data.find(b"administrators", search_start, search_end)
    if admin_off < 0:
        sys.exit("ERROR: 'administrators' value string not found near DefaultAllowGroups. "
                 "Cannot patch safely.")
    if data[admin_off + 14:admin_off + 15] != b"\x00":
        sys.exit(f"ERROR: 'administrators' at {admin_off} is not null-terminated. "
                 "Refusing to patch (may corrupt adjacent string).")

delta = admin_off - sym_off
print(f"→ 'administrators' value at offset: {admin_off} (delta {delta} bytes from symbol)")

# Sanity: read what's there
before = data[admin_off:admin_off + 15]
print(f"→ bytes at offset (before): {before!r}")

# 4. Apply patch in-memory
patched = data[:admin_off] + REPLACEMENT + data[admin_off + 15:]
assert len(patched) == len(data), "patched binary size changed!"

# 5. Atomic write via temp file + rename
tmp = BIN + ".tmp"
with open(tmp, "wb") as f:
    f.write(patched)
os.chmod(tmp, os.stat(BIN).st_mode)
os.rename(tmp, BIN)
print(f"→ wrote patched binary")

# 6. Verify
verify = open(BIN, "rb").read()[admin_off:admin_off + 15]
print(f"→ bytes at offset (after):  {verify!r}")
if verify != REPLACEMENT:
    sys.exit("ERROR: verification failed — patched bytes don't match expected!")

print()
print("DONE — DefaultAllowGroups is now 'users'.")
print()
print("Next:")
print("  sudo pkill -f 'sshd -f /usr/builtin/etc/sshd_config_sftp'")
print("  sleep 1")
print("  sudo /usr/sbin/sshd -f /usr/builtin/etc/sshd_config_sftp")
print()
print(f"REVERSE: sudo cp {BACKUP} {BIN}")
