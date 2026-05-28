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
192.168.2.99;0.0.0.0;0
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
./whitelist-cicd.sh --custom "192.168.2.0/24,203.0.113.42" --dry-run

# Apply (sudo on NAS)
sudo ./whitelist-cicd.sh --custom "192.168.2.0/24,203.0.113.42" --apply

# WITH GitHub hosted-runner ranges (publicly-reachable NAS only — rare)
# Auto mode emits ~20 netmask lines instead of 500k individual IPs
./whitelist-cicd.sh --include github,gitlab --custom 192.168.2.0/24 --dry-run

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
