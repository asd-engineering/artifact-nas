# Asustor — `ipblock` (ADM Defender) tuning for CI

Asustor's ADM has a built-in "Defender" / `ipblock` mechanism that
auto-bans IPs after failed auth attempts. The defaults are aggressive
enough to break CI use cases out of the box:

```
# /usr/builtin/etc/ipblock/ipblock.conf
[Policy]
Enable = Yes
Login_Attempt = 1     ← BAN after a single failed login
Time_Period = 0       ← no time window (instant trigger)
Block_Time = 0        ← ban forever (manual clear only)
Service = 892         ← bitmask: SSH/SFTP/AFP/SMB/etc.
```

Even a single mis-authed `rclone` connection from a runner → IP banned →
every subsequent connection from that IP gets reset during SSH key-
exchange. From the rclone client side, that surfaces as
`NewFs: couldn't initialise SFTP: ... unexpected EOF` (the same error
the `artifact-nas` action's v1.2.0 retry wrapper exists to absorb).

The retry wrapper handles transient noise. It does NOT outlast a
permanent ban. The proper fix is on the NAS.

## File layout

```
/usr/builtin/etc/ipblock/
├── ipblock.conf              ← global policy (above)
├── defender.conf             ← Defender_Type (mode selector)
├── defender.safe             ← WHITELIST: IPs never banned
├── abuseip.conf              ← AbuseIPDB integration config
├── abuseip.safe              ← AbuseIPDB whitelist (auto-managed)
├── abuseip.deny              ← AbuseIPDB-sourced bans
├── abuseipdb_record.csv      ← audit log of submissions
└── ipblock.conntrack         ← runtime state
```

The file we care about: **`defender.safe`** (the manual whitelist).

## `defender.safe` format

Each line is `<ip>;<netmask>;<flag>`. Example:

```
198.51.100.7;0.0.0.0;0
10.10.10.99;0.0.0.0;0
```

- `<ip>` — IPv4 dotted-quad
- `<netmask>` — `0.0.0.0` for single host (the form every shipped ADM
  uses). Asustor's netmask-matching (e.g. `255.255.255.0` for /24,
  `255.255.0.0` for /16) is undocumented and version-dependent. The
  script can emit either form (`--cidr-mode expand` vs `--cidr-mode
  netmask`); default `auto` blends them — see below.
- `<flag>` — observed value is always `0` in the wild; semantics
  undocumented by Asustor.

## Three fix options (combine as needed)

### Option A — Whitelist runner IPs (recommended for CI)

Run `whitelist-cicd.sh` (locally on the NAS) or pipe it via SSH from
a workstation that already has a non-banned login. It supports CIDRs
via `--custom` and can also fetch GitHub Actions / GitLab.com hosted-
runner IP ranges via `--include`. Three CIDR-emission modes:

| `--cidr-mode` | What gets written per CIDR | When to use |
|---|---|---|
| `auto` (default) | `≤ /<max-expand>` → individual IPs; `> /<max-expand>` → single netmask line | Safe + compact. Default `--max-expand 24`. |
| `expand` | Always individual `<ip>;0.0.0.0;0` lines | Maximum safety; bloats for `/16+` (skips them with warning) |
| `netmask` | Always single `<network>;<netmask>;0` line | Compact; EXPERIMENTAL — verify your ADM version honors netmask matching by trying a small CIDR first |

```bash
# COMMON CASE — self-hosted runners on LAN; auto mode handles your /24
./whitelist-cicd.sh --custom "10.10.10.0/24,203.0.113.42" --dry-run

# Apply (sudo on NAS)
sudo ./whitelist-cicd.sh --custom "10.10.10.0/24,203.0.113.42" --apply

# WITH GitHub hosted-runner ranges (publicly-reachable NAS only — rare)
# Auto mode emits ~20 netmask lines instead of 500k individual IPs
./whitelist-cicd.sh --include github,gitlab --custom 10.10.10.0/24 --dry-run

# Test netmask-matching support on YOUR ADM first
./whitelist-cicd.sh --custom 10.99.99.0/24 --cidr-mode netmask --apply
# Then SSH from inside 10.99.99.0/24 and confirm the previously-banned
# IP can now connect cleanly. If it can't, your ADM doesn't honor
# netmask matching; fall back to --cidr-mode expand (or just don't
# whitelist hosted-runner ranges).
```

### Option B — Loosen the policy

Edit `/usr/builtin/etc/ipblock/ipblock.conf` (or use the ADM web UI →
*System Settings → ADM Defender*):

```ini
[Policy]
Login_Attempt = 10      # allow ~10 failed attempts
Time_Period = 300       # within a 5-minute window
Block_Time = 600        # then ban for 10 minutes (auto-expires)
```

`Block_Time = 600` is the critical change — combined with
`artifact-nas`'s 57s retry budget × multiple jobs, transient bans
clear inside the CI run.

### Option C — Disable for SSH/SFTP only

`Service = 892` is a bitmask. Clearing the SSH bit removes the
ban-policy for SSH/SFTP while keeping it for AFP, SMB, etc. Bit values
are version-dependent — easier to set via ADM web UI checkboxes than
to decode the integer.

## After editing config files

The `ipblock` daemon may need a reload:

```bash
sudo killall -HUP ipblockd 2>/dev/null || sudo /etc/init.d/ipblockd restart 2>/dev/null || \
  sudo /usr/builtin/etc.init.d/ipblockd restart 2>/dev/null || echo "manually restart via ADM web UI"
```

The exact init script name varies; some ADM versions handle config
changes via inotify and don't need a restart.

## Confirming whitelist took effect

After applying the whitelist:

1. Pick a previously-banned IP (or simulate by failing-auth once):
   `ssh -p 2324 invalid@<nas>` once → wait the ban window
2. Re-attempt from the whitelisted IP — should connect cleanly without
   `kex_exchange_identification: read: Connection reset by peer`.
3. Check `/usr/builtin/etc/ipblock/abuseip.deny` (the deny list) to see
   it does NOT contain your runner's IP.

---

# SFTP daemon crash-loop — OpenSSH seccomp + missing `/var/log/lastlog`

A second, independent failure mode on Asustor 4.2.5.RN33+ firmware that
also surfaces to `artifact-nas` users as "NAS is unreachable":

```
sshd-session: error: mm_reap: preauth child terminated by signal 31
kernel audit: comm="sshd-session" sig=31 syscall=87 code=0x0
```

**Root cause:** `PrintLastLog yes` (default in `sshd_config_sftp`) makes
OpenSSH's preauth privsep child write to `/var/log/lastlog`. On recent
Asustor builds that file does not exist; OpenSSH's write path includes
`unlink(2)` (syscall 87 on x86_64) which is NOT in the preauth seccomp
filter's allowlist. The kernel kills the child with `SIGSYS` (signal 31).
Every connection crashes. OpenSSH's `PerSourcePenalties` (built into
9.8+) starts dropping further connections from the same source IP with
`penalty: caused crash`. Eventually the Asustor service supervisor
SIGTERMs the master sshd because too many children died — the listener
disappears off port 4589 and `artifact-nas` uploads get
`connection refused`. From the client side this looks identical to
ipblock having banned the runner — but it's a different problem at a
different layer.

## Asustor has TWO SFTP config files

```
/usr/builtin/etc.default/sshd_config_sftp   ← defaults; firmware updates restore from here
/usr/builtin/etc/sshd_config_sftp           ← runtime; what the daemon actually reads
```

Patching only the runtime works until the next firmware update, which
may copy defaults → runtime and undo your fix. `fix-sftp-seccomp-crash.sh`
patches BOTH and adds a `@reboot` cron guard that recreates the lastlog
file even if it gets wiped by future updates.

## Usage

```bash
# Apply the persistent fix (writes backups; idempotent — safe to re-run):
sudo sh fix-sftp-seccomp-crash.sh

# Inspect current state, no changes:
sudo sh fix-sftp-seccomp-crash.sh --check

# After running + a few new connections, confirm no new seccomp kills:
sudo sh fix-sftp-seccomp-crash.sh --verify
```

The fix restarts the SFTP service via `/usr/bin/serviceutil sshd
restart` (Asustor's CLI service tool — bypasses the ADM web UI toggle,
which is unreliable when the service is in the crash-loop).

## How this relates to the ipblock whitelist

Different problems, both produce "NAS unreachable" to `artifact-nas`:

| Layer | Symptom (client-side) | Symptom (NAS-side) | Fix |
|---|---|---|---|
| ipblock IP-ban | `Connection reset by peer` during kex | `Failed publickey` in defenderd logs | `whitelist-cicd.sh` |
| seccomp crash | `Connection refused` (port closed) | `sig=31 syscall=87` in dmesg | `fix-sftp-seccomp-crash.sh` |

Run both if you've seen either symptom — they don't conflict.

---

# REAL root cause (corrected): hardcoded `DefaultAllowGroups = "administrators"`

After exhaustive triage on a live Asustor AS6706T running ADM 4.2.5
(2026-05-28), the SIGSYS crashes documented above turned out to be a
SECONDARY symptom of a different root cause. Capturing it here so the
next person doesn't waste hours like we did:

## The actual bug

Asustor patched OpenSSH 9.8p1 with a hardcoded **`DefaultAllowGroups = "administrators"`**.
The string `"administrators\0"` sits at file offset **551273** in
`/usr/bin/sshd-session` (immediately following the `"DefaultAllowGroups"`
symbol at 551254). Source: `strings /usr/bin/sshd-session | grep -B1 administrators`.

When a user connects, sshd checks group membership against this
hardcoded value EVEN IF the config has `AllowGroups` set to something
else (the patch checks BOTH). Any user not in the UNIX `administrators`
group (`/etc/group: administrators:x:999:admin,sysadmin`) gets:

1. Treated as `NOUSER` (anti-enumeration downgrade)
2. Authentication "fails" — every method
3. The cleanup-on-failed-auth code path calls `unlink()` on a temp/lock file
4. OpenSSH's seccomp filter doesn't allow `unlink` in preauth → SIGSYS
5. Child crashes; PerSourcePenalties keeps subsequent connections out
6. Eventually the service supervisor SIGTERMs the master listener
7. SFTP service "is offline" from the outside

So the visible-from-outside symptom is `connection refused` /
`connection reset by peer` from rclone, the visible-on-NAS symptom is
the SIGSYS audits + sshd master flapping. Both are downstream of one
hardcoded string in the patched binary.

## The fix — `patch-sshd-session.py`

Surgical binary patch: replaces the 15-byte slot `"administrators\0"`
with `"users\0\0\0\0\0\0\0\0\0\0"` (5 chars + 10 null padding).
C reads up to the first null → sees `"users"`. The padding keeps the
file size and all subsequent offsets identical (no relocations break).

```bash
sudo python3 nas/asustor/patch-sshd-session.py
sudo pkill -f 'sshd -f /usr/builtin/etc/sshd_config_sftp'; sleep 1
sudo /usr/sbin/sshd -f /usr/builtin/etc/sshd_config_sftp
```

After patching:
- Users in `users` group (the default primary group for Asustor users
  created via ADM UI) pass the AllowGroups check
- Auth proceeds normally — key or password
- No more SIGSYS kills (the cleanup-after-NOUSER-rejection code path
  is never entered for normal users)
- UNIX `administrators` group membership is STILL meaningful for sudo
  + ADM admin role (other `administrators` references in the binary,
  the `%administrators ALL=(ALL:ALL) ALL` sudoers line, and
  `Is_Nas_Administrators_Member` are unchanged)

Reversal: `sudo cp /usr/bin/sshd-session.asustor-original /usr/bin/sshd-session`
(the script auto-backs up before patching).

## **Required after firmware updates**

Asustor firmware updates may replace `/usr/bin/sshd-session`. The
`patch-sshd-session.py` script is idempotent — re-run it after any
ADM upgrade. Add it to your post-upgrade checklist.

---

# Per-user setup playbook

Every new SFTP user added to the NAS for artifact-nas use needs the
following. The binary patch is one-time per appliance; everything
else is per-user.

| Step | Where | Command / Action |
|---|---|---|
| 1. Create UNIX user | NAS (one-time) | Asustor ADM UI → Users → Add. Primary group: `users` (default). Do NOT add to `administrators`. |
| 2. Verify primary GID | NAS | `id <user>` should show `gid=100(users)` |
| 3. Prepare `.ssh` dir | NAS | `sudo install -d -m 700 -o <user> -g users /home/<user>/.ssh` |
| 4. Drop pubkey | NAS | `sudo tee /home/<user>/.ssh/authorized_keys < your-key.pub; sudo chown <user>:users /home/<user>/.ssh/authorized_keys; sudo chmod 600 /home/<user>/.ssh/authorized_keys` |
| 5. Verify binary patched | NAS (one-time) | `grep -aboF "DefaultAllowGroups" /usr/bin/sshd-session; sudo python3 patch-sshd-session.py` (no-op if already patched) |
| 6. Generate rclone profile | Local | Use the inline `key_pem` form so it ships in ONE secret. See template below. |
| 7. Push RCLONE_CONF_B64 | Local | `base64 -w0 rclone.conf \| gh secret set RCLONE_CONF_B64 --org <ORG> --visibility all` |
| 8. Push NAS_DEST | Local | `echo "/home/<user>/ci-artifacts" \| gh secret set NAS_DEST --org <ORG> --visibility all` (NOTE: lowercase `/home/...` — `/Home` is NOT a valid path on most Asustor builds) |
| 9. Verify | Local | `RCLONE_CONFIG=./rclone.conf rclone lsd <remote>:` (should list the user's home content), `RCLONE_CONFIG=./rclone.conf rclone copy testfile <remote>:/home/<user>/ci-artifacts/test/` |

## rclone.conf template (inline ed25519 key, one-secret)

```ini
[my-nas]
type = sftp
host = <PUBLIC_IP_OR_DDNS>
user = <USER>
port = <PORT>
key_pem = -----BEGIN OPENSSH PRIVATE KEY-----\n
   ... base64 blob, newlines preserved as \n ...\n
   -----END OPENSSH PRIVATE KEY-----\n
shell_type = unix
connect_timeout = 10s
timeout = 20s
md5sum_command = none
sha1sum_command = none
```

Build the `key_pem` line by collapsing the private key with literal
`\n` for newlines:

```bash
awk '{printf "%s\\n", $0}' ~/.ssh/cicd_ed25519 | sed 's/\\n$//'
```

## Things that look like fixes but aren't

If you see SIGSYS audits on `/var/log/messages` from `sshd-session`
with `syscall=87` (unlink), it is tempting to fix:
- `/var/log/lastlog` missing → `touch` it
- `/var/log/btmp` perms → `chmod 600`
- `pam_google_authenticator` required → make optional
- `UsePAM yes` → `UsePAM no`
- `ipblockman` syscalls → no-op shim

**Don't.** Each of those scratches one surface symptom and leaves the
real bug (DefaultAllowGroups rejection → cleanup unlink → SIGSYS) in
place. Patch the binary, leave the rest alone.
