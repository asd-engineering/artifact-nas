# Asustor platform notes — fast-comprehension cheat-sheet

**Why this file:** the ADM appliance diverges from a normal Linux box in
ways that waste hours if you rediscover them each time. Verified on
**AS6706T / ADM 4.2.5.RN33 / OpenSSH_9.8p1 / kernel 6.6.x** (2026-05-31).
Read this before touching SSH/SFTP/cron on the NAS.

## Shell & coreutils
- **No `bash`** — `/bin/sh` is busybox `ash`. No bash-isms (`[[ ]]`,
  arrays, `${x^^}`). All scripts here are POSIX `sh`.
- Most coreutils are **busybox applets** (`crond`, `crontab`, `sed`,
  `grep`, `ps`, `netstat`). `ss` exists; `ps aux` works but `ps w` is
  the busybox form. `dmesg`, `dd`, `sha256sum`, `strings`, `logger`
  present.
- `sudo` needs a **tty** → `ssh host 'sudo ...'` fails with *"a terminal
  is required to read the password"*. Use an interactive
  `ssh -p 2324 user@host` session, or `ssh -t`. Agent-forwarded keys do
  not grant passwordless sudo here.

## SSH / SFTP — TWO separate daemons
| Daemon | Port | Config | Role |
|---|---|---|---|
| `sshd` | **2324** | `/usr/etc/ssh/sshd_config` | admin shell login |
| `sshd_sftp` (+ `sftpmand` supervisor) | **4589** | `/usr/builtin/etc/sshd_config_sftp` | the SFTP service rclone/CI uses |

- Port 22 is closed; admin SSH is **2324**. SFTP is **4589** (set by
  `Port` in `sshd_config_sftp`).
- **Two config copies, both must be patched:**
  `/usr/builtin/etc/sshd_config_sftp` (runtime, what the daemon reads)
  and `/usr/builtin/etc.default/sshd_config_sftp` (defaults). The init
  script has a (currently commented) `cp defaults → runtime` line, and
  firmware updates restore runtime from defaults. Patch BOTH.
- Service control: `/usr/builtin/etc/init.d/S79sftpmand {start|stop}`
  (start spawns `sftpmand`, which spawns `sshd_sftp`). Also
  `/usr/bin/serviceutil sshd {start|stop|restart}`. **No `restart` verb
  on the init script** — stop, sleep 1, start.
- **The master does NOT auto-restart if it dies.** A concurrent
  connection burst can make `sftpmand` + `sshd_sftp` both exit and port
  4589 stays down until a manual restart. Hence the watchdog cron.

## The three independent SFTP failure modes (all surface as "NAS unreachable" to rclone)
1. **Hardcoded `DefaultAllowGroups="administrators"`** baked into
   `/usr/bin/sshd-session` → non-admin users rejected as NOUSER. Fix:
   `patch-sshd-session.py` (string patch @ offset ~551273). Backup:
   `sshd-session.asustor-original`.
2. **Preauth seccomp filter kills `unlink` (syscall 87) → SIGSYS
   (`sig=31`)** every session; OpenSSH 9.8 `PerSourcePenalties` then
   escalates drops. Fix: `patch-seccomp.py` (flip BPF default
   KILL→ALLOW @ 0x90988). Backup: `sshd-session.before-seccomp-patch`.
   Detect with: `dmesg | grep 'comm="sshd-session".*sig=31'`.
3. **Burst fragility + brutal throttle (post-patch).** Even with 1+2
   applied, concurrency knocks the master over. Drivers: `MaxStartups`
   unset→default `10:30:100`; `PerSourcePenalties` on; **ipblock policy
   `Login_Attempt=1 / Time_Period=0 / Block_Time=0` = permaban after ONE
   failed auth**. Fix: `fix-sftp-cicd.sh` (config hardening + ipblock
   window + watchdog + restart).

Run order on a fresh / firmware-reset NAS:
`patch-sshd-session.py` → `patch-seccomp.py` → `fix-sftp-cicd.sh` → `--verify`.

## ipblock / ADM Defender
- Policy file: `/usr/builtin/etc/ipblock/ipblock.conf` (`[Policy]`
  INI: `Login_Attempt`, `Time_Period`, `Block_Time`, `Service` bitmask).
  Stock = permaban; loosen to `10 / 300 / 600` for CI.
- Manual whitelist: `/usr/builtin/etc/ipblock/defender.safe`
  (`<ip>;<netmask>;<flag>`, `0.0.0.0` netmask = single host). See
  `whitelist-cicd.sh`.
- nftables firewall (ADM "Network Defender") lives in
  `/usr/builtin/etc/defender/` (`global.json` enable flag, `profiles.json`
  rules, generated `firewall.nft_*`). Separate from ipblock.
  **CORRECTION (2026-06-03): this firewall is THE main CI root cause, not
  "inactive".** Its active profile `Migration_ADM Defender` GEO-BLOCKS inbound
  by source country (`@NA_US drop`, …) — only Europe + TrustedIP is allowed, so
  US-registered GitHub runners are dropped before reaching `sshd_sftp`. Rules
  are source-based only (no port scoping). Full writeup + the keep-firewall-on
  fix (nft `tcp dport 4589 accept` ahead of the geo-drops, watchdog-reasserted)
  in [`CI-GEO-BLOCK-AND-RELIABILITY.md`](./CI-GEO-BLOCK-AND-RELIABILITY.md).

## Cron — busybox, NO user field
- `crond` is busybox (`/usr/sbin/crond → /bin/busybox`). It reads
  **`/var/spool/cron/crontabs/<user>`**, which is a **symlink** to
  **`/usr/builtin/etc/crontabs/`** (persistent on `/volume0`).
- **Format has NO user field**: `* * * * * /path/cmd` (NOT
  `* * * * * root /path/cmd`). Confirmed by the stock `admin` job.
- Add jobs via the `crontab` command (writes the right spool) or append
  to `/usr/builtin/etc/crontabs/root` directly, then `killall -HUP
  crond`. `/etc/crontab` and `/usr/builtin/etc/crontab` (singular) do
  **not** exist here — don't target them.
- There is also a second `/usr/sbin/cron -P` (isc-cron) process running;
  the busybox spool above is the one that runs these jobs.

## Logging
- `sshd_sftp` does **not** log to `/var/log/messages` (only the admin
  `sshd` does). Auth/SFTP failures from CI won't appear there — use
  `dmesg` (seccomp audits) and the ipblock deny files instead.
- Kernel audit signature for the seccomp crash:
  `type=1326 ... comm="sshd-session" sig=31 ... syscall=87`.

## Durable answer vs. mitigation
These patches keep the vendor daemon working but it stays fragile under
load (watchdog revives it within ~1 min). For a genuinely stable CI
endpoint, run a plain **OpenSSH/SFTP container** on the NAS host (sane
`MaxStartups`, no ipblock supervisor, no vendor-patched binary). Client
belt: keep rclone `--transfers/--checkers` modest in the upload/download
actions so CI never bursts the listener.
