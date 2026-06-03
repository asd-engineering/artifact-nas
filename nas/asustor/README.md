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
192.168.1.99;0.0.0.0;0
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
./whitelist-cicd.sh --custom "192.168.1.0/24,203.0.113.42" --dry-run

# Apply (sudo on NAS)
sudo ./whitelist-cicd.sh --custom "192.168.1.0/24,203.0.113.42" --apply

# WITH GitHub hosted-runner ranges (publicly-reachable NAS only — rare)
# Auto mode emits ~20 netmask lines instead of 500k individual IPs
./whitelist-cicd.sh --include github,gitlab --custom 192.168.1.0/24 --dry-run

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

# The SFTP service is `sftpmand` on port 4589 — NOT the main sshd

The single most confusing thing about this appliance: **CI's SFTP and your
interactive SSH login are two different daemons.**

| Daemon | Port | Binary | Config | Serves |
|---|---|---|---|---|
| main `sshd` | 2324 (custom) | `/usr/sbin/sshd` | `/usr/etc/ssh/sshd_config` (`Subsystem sftp /bin/false`) | your interactive admin login |
| **`sftpmand`** | **4589** | `/usr/builtin/sbin/sftpmand` | `/usr/builtin/etc/sshd_config_sftp` (`Port 4589`, `AllowGroups users`, `Subsystem sftp internal-sftp`, `ForceCommand internal-sftp`) | **the `artifact-nas` / `asd-cicd` SFTP** |

So **"I can still SSH in"** (2324) tells you nothing about whether CI's 4589 is
up. Diagnose 4589 specifically:

```sh
ps -ef | grep '[s]ftpmand'        # is the daemon alive?
ss -tlnp | grep :4589             # is it listening?
```

`sftpmand` is gated on `confutil -get /usr/builtin/etc/sftp.conf "" enable` ==
`Yes` and started by `/usr/builtin/etc/init.d/S79sftpmand`. Connections fork
`sshd-session`, which is subject to the two binary patches below.

## Two binary patches `sshd-session` needs (`nas/asustor/`)

ADM ships `/usr/bin/sshd-session` with two independent bugs that both surface
as "port 4589 unreachable" — **both** must be applied:

1. **`patch-sshd-session.py`** — ADM hardcodes `DefaultAllowGroups =
   "administrators"`; CI users (group `users`) are rejected as NOUSER. Patches
   the embedded string to `"users"`.
2. **`patch-seccomp.py`** — the preauth privsep seccomp filter's default action
   is `KILL_THREAD`; something in the monitor calls `unlink` (syscall 87), so
   sessions crash with `SIGSYS` (`dmesg`: `sig=31 … syscall=87`), escalate
   `PerSourcePenalties`, and eventually the service supervisor drops the 4589
   listener. Flips the BPF default to `ALLOW`. Idempotent; refuses to write if
   the binary doesn't match (offset drift across firmware builds → re-find).

## Recovery + boot-persistence (the durable fix)

ADM **regenerates `/usr/etc` and resets `/usr/bin/sshd-session` on reboot /
firmware update**, which un-patches the binary and lets `sftpmand` die without
auto-restarting — the recurring "4589 was working, now it's refused" cycle.

Recovery is a single idempotent script (`asd-nas-recover.sh`): re-apply both
patches → restart `sftpmand` → `HUP` the main sshd (clears penalties) → verify
4589. Persist the script + the seccomp patch on the **data volume** (`/usr/local`
is on the RAID and survives firmware resets, unlike `/usr/etc`) and wire it to
`@reboot`:

```sh
# persistent home (survives firmware resets):
/usr/local/sbin/patch-sshd-session.py
/usr/local/sbin/patch-seccomp.py
/usr/local/sbin/asd-nas-recover.sh

# root crontab (/usr/builtin/etc/crontabs/root): run full recovery on boot
@reboot sleep 45 && /bin/sh /usr/local/sbin/asd-nas-recover.sh >> /var/log/asd-nas-recover.log 2>&1

# manual run any time 4589 is down:
sudo sh /usr/local/sbin/asd-nas-recover.sh
```

`sleep 45` lets the stock `S79sftpmand` + filesystem come up first, then the
recovery re-patches and restarts cleanly on top.

## Intermittent empty `readdir` under load

Even when healthy, `sftpmand` (`internal-sftp`) can occasionally return an
**empty directory listing for a populated dir** when many CI connections hit it
at once (uploads + cross-runner reads during a full release matrix). It's rare,
load-dependent, and not reproducible in isolation (a sequential and a 6-way
concurrent probe were both 0-failure). The `artifact-nas` action mitigates it
(v1.4.6 zero-gain retry) and v1.4.7's `RUN_ID`-only path makes
`gh run rerun <id> --failed` a reliable recovery — see the action README's
"Reliability hardening" section. Loosening `MaxStartups` in `sshd_config_sftp`
may help but is unverified on this firmware.

## Load-test harness (`.github/workflows/nas-loadtest.yml`)

A tunable, public-safe load test for the NAS SFTP path, living next to the action
it exercises. Fans out N GitHub runners (distinct egress IPs); each runs a
layered `nas-doctor.sh` sanity probe, then a concurrent **upload** burst via
`nas-rclone.sh` (the same flags the upload/download actions use), byte-verified.

Run it from the Actions tab (manual). Inputs let you **sweep the rclone config**
without touching the action — confirm a setting doesn't break the NAS first:

| input | maps to | default |
|---|---|---|
| `fanout` | parallel runners (distinct source IPs) | 20 |
| `burst_seconds` | per-runner sustained upload duration | 30 |
| `transfers` | rclone `--transfers` | 2 |
| `checkers` | rclone `--checkers` | 2 |
| `tpslimit` | rclone `--tpslimit` | 4 |

The run **Summary** reports per-runner ok/bad + byte-verify and the `nas-doctor`
failing layer. `nas-rclone.sh` defaults equal the action's flags (it mirrors
production) and reads `NAS_RCLONE_*` env for the sweep.

**Requires** repo/org secrets `RCLONE_CONF_B64` (base64 rclone.conf — NAS host/
port/user live here, never in the repo) and `NAS_DEST`. Validated config
`transfers=2 checkers=2 tpslimit=4`: 0% upload failure at fanout 40 & 80 with the
firewall on, no daemon wedge.
