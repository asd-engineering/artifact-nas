#!/bin/sh
# fix-sftp-cicd.sh — make Asustor's dedicated SFTP daemon survive CI load
# =============================================================================
# Run ON THE NAS as root:
#     sudo sh fix-sftp-cicd.sh            # apply (idempotent; writes backups)
#     sudo sh fix-sftp-cicd.sh --check    # show current vs desired, no changes
#     sudo sh fix-sftp-cicd.sh --verify   # apply nothing; load-probe + report
#
# WHY THIS EXISTS (the layer the binary patches do NOT cover)
# -----------------------------------------------------------------------------
# patch-sshd-session.py (DefaultAllowGroups) and patch-seccomp.py (SIGSYS on
# unlink/syscall-87) fix per-connection *crashes*. Verified on AS6706T / ADM
# 4.2.5 / OpenSSH_9.8p1 (2026-05-31): with both patches applied, a burst of
# concurrent connections to :4589 produces ZERO new `sig=31` audits — the
# crash fix holds.
#
# BUT the SFTP master still dies under a concurrent connection burst *without*
# crashing, and Asustor does NOT auto-restart it: `sftpmand` + `sshd_sftp`
# both disappear and port 4589 stays down. Three stock-config facts make a
# CI artifact-nas run (parallel rclone uploads + retry storms) trip this:
#
#   1. MaxStartups unset -> OpenSSH default 10:30:100. Past 10 pre-auth
#      connections the daemon random-early-drops them with no banner; rclone
#      reports `couldn't initialise SFTP: EOF` / `handshake failed: EOF`.
#   2. PerSourcePenalties on (9.8 default) -> a single runner IP doing many
#      rapid connections gets progressively dropped ("penalty: ...").
#   3. ipblock policy Login_Attempt=1 / Time_Period=0 / Block_Time=0 -> ONE
#      failed auth permabans the source IP (manual clear only).
#
# This script raises the concurrency ceiling, disables the per-source penalty
# escalation, loosens ipblock to a self-healing window, installs a watchdog
# that brings the daemon back if a burst still knocks it over, and restarts
# the service. It patches BOTH config copies (runtime + etc.default) because
# firmware updates and the init script's `cp defaults -> runtime` line restore
# from etc.default.
# =============================================================================

set -u

RUNTIME=/usr/builtin/etc/sshd_config_sftp
DEFAULTS=/usr/builtin/etc.default/sshd_config_sftp
IPBLOCK=/usr/builtin/etc/ipblock/ipblock.conf
INIT=/usr/builtin/etc/init.d/S79sftpmand
WATCHDOG=/usr/local/sbin/sftp-cicd-watchdog.sh
SECCOMP_BAK=/usr/bin/sshd-session.before-seccomp-patch
ALLOWGRP_BAK=/usr/bin/sshd-session.asustor-original
PORT=4589

MODE=apply
case "${1:-}" in
  --check)  MODE=check ;;
  --verify) MODE=verify ;;
  "")       MODE=apply ;;
  *) echo "usage: $0 [--check|--verify]"; exit 2 ;;
esac

log()  { printf '%s\n' "$*"; }
ok()   { printf '  [ok]   %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
need_root() {
  [ "$(id -u)" = "0" ] || { echo "ERROR: must run as root (sudo sh $0)"; exit 1; }
}

# port_listening -> 0 if something is LISTENing on $PORT
port_listening() {
  if command -v ss >/dev/null 2>&1; then ss -tln 2>/dev/null | grep -q ":$PORT "
  else netstat -tln 2>/dev/null | grep -q ":$PORT "; fi
}

# set_directive FILE KEY VALUE
#   Make `KEY VALUE` the single active line for KEY: strip every existing
#   commented-or-active KEY line, append the canonical one. Preserves the
#   file's inode/perms (write tmp, copy bytes back).
set_directive() {
  f="$1"; k="$2"; v="$3"
  [ -f "$f" ] || { warn "missing $f (skipped $k)"; return 0; }
  cur=$(grep -iE "^[[:space:]]*#?[[:space:]]*$k([[:space:]]|\$)" "$f" 2>/dev/null | head -1)
  if [ "$MODE" = check ]; then
    printf '  %-46s %-22s have: %s\n' "$f" "$k $v" "${cur:-<unset>}"
    return 0
  fi
  t="${f}.cicd.tmp.$$"
  grep -viE "^[[:space:]]*#?[[:space:]]*$k([[:space:]]|\$)" "$f" > "$t" 2>/dev/null || :
  printf '%s %s\n' "$k" "$v" >> "$t"
  cat "$t" > "$f"          # keep original inode + perms
  rm -f "$t"
  ok "$f: $k $v"
}

backup_once() {
  f="$1"; [ -f "$f" ] || return 0
  [ -f "${f}.cicd-bak" ] || { cp -p "$f" "${f}.cicd-bak"; ok "backup ${f}.cicd-bak"; }
}

# set_ini_kv FILE KEY VALUE  (for ipblock.conf "Key = Value" INI lines)
set_ini_kv() {
  f="$1"; k="$2"; v="$3"
  [ -f "$f" ] || { warn "missing $f (skipped $k)"; return 0; }
  cur=$(grep -iE "^[[:space:]]*$k[[:space:]]*=" "$f" 2>/dev/null | head -1)
  if [ "$MODE" = check ]; then
    printf '  %-46s %-22s have: %s\n' "$f" "$k = $v" "${cur:-<unset>}"
    return 0
  fi
  if grep -qiE "^[[:space:]]*$k[[:space:]]*=" "$f" 2>/dev/null; then
    sed -i "s|^[[:space:]]*$k[[:space:]]*=.*|$k = $v|I" "$f"
  else
    printf '%s = %s\n' "$k" "$v" >> "$f"
  fi
  ok "$f: $k = $v"
}

# ----------------------------------------------------------------------------
log "== Asustor SFTP CI hardening ($MODE) =="

if [ "$MODE" = verify ]; then
  need_root
  log "-- binary-patch state --"
  [ -f "$SECCOMP_BAK" ]  && ok "seccomp patch applied ($SECCOMP_BAK present)"   || warn "seccomp patch NOT applied — run patch-seccomp.py"
  [ -f "$ALLOWGRP_BAK" ] && ok "AllowGroups patch applied ($ALLOWGRP_BAK present)" || warn "AllowGroups patch NOT applied — run patch-sshd-session.py"
  log "-- listener --"
  port_listening && ok "port $PORT LISTEN" || warn "port $PORT DOWN — run without --verify to restart"
  log "-- new seccomp kills since boot --"
  n=$(dmesg 2>/dev/null | grep -c "comm=\"sshd-session\".*sig=31")
  printf '  sig=31 sshd-session audits in dmesg: %s\n' "$n"
  exit 0
fi

[ "$MODE" = apply ] && need_root

# 1) sshd_config_sftp hardening — BOTH copies
log "-- sshd_config_sftp (concurrency + per-source) --"
for f in "$RUNTIME" "$DEFAULTS"; do
  [ "$MODE" = apply ] && backup_once "$f"
  set_directive "$f" MaxStartups        "200:30:1000"
  set_directive "$f" MaxSessions        "100"
  set_directive "$f" PerSourceMaxStartups "100"
  set_directive "$f" PerSourcePenalties "no"
  # NB: deliberately NOT touching PrintLastLog — patch-seccomp.py already
  # covers the unlink/syscall-87 path, and the README documents PrintLastLog
  # as a peripheral tweak that rots back. This script only addresses the
  # concurrency + resilience layer the binary patches don't.
done

# 2) ipblock: turn the permaban into a short self-healing window
log "-- ipblock policy (self-healing window instead of permaban) --"
[ "$MODE" = apply ] && backup_once "$IPBLOCK"
set_ini_kv "$IPBLOCK" Login_Attempt 10
set_ini_kv "$IPBLOCK" Time_Period   300
set_ini_kv "$IPBLOCK" Block_Time    600

# 3) binary-patch presence check (do NOT auto re-patch — that's the .py scripts' job)
log "-- binary-patch presence --"
[ -f "$SECCOMP_BAK" ]  && ok "seccomp patch applied"   || warn "seccomp patch NOT applied — run: sudo python3 patch-seccomp.py"
[ -f "$ALLOWGRP_BAK" ] && ok "AllowGroups patch applied" || warn "AllowGroups patch NOT applied — run: sudo python3 patch-sshd-session.py"

if [ "$MODE" = check ]; then
  log "(check only — no changes written)"
  exit 0
fi

# 4) watchdog: restart sftpmand if the master dies under a burst
log "-- watchdog --"
cat > "$WATCHDOG" <<WD
#!/bin/sh
# Restart Asustor sftpmand if port $PORT is not listening. Installed by fix-sftp-cicd.sh.
if command -v ss >/dev/null 2>&1; then ss -tln 2>/dev/null | grep -q ":$PORT " && exit 0
else netstat -tln 2>/dev/null | grep -q ":$PORT " && exit 0; fi
logger -t sftp-watchdog "port $PORT down — restarting sftpmand" 2>/dev/null || true
$INIT stop  >/dev/null 2>&1
sleep 1
$INIT start >/dev/null 2>&1
WD
chmod 0755 "$WATCHDOG"
ok "installed $WATCHDOG"

# register watchdog every minute, idempotently. Asustor runs BUSYBOX crond
# reading /var/spool/cron/crontabs/<user> (-> /usr/builtin/etc/crontabs,
# persistent on /volume0). That format has NO user field: "* * * * * cmd".
# Prefer the `crontab` command (writes the right spool); fall back to a
# direct spool append, then to /etc/crontab (user-field) as a last resort.
if command -v crontab >/dev/null 2>&1; then
  if crontab -l 2>/dev/null | grep -q "sftp-cicd-watchdog"; then
    ok "cron: watchdog already registered (crontab -l)"
  else
    ( crontab -l 2>/dev/null | grep -v "sftp-cicd-watchdog"
      printf '* * * * * %s\n' "$WATCHDOG" ) | crontab -
    ok "cron: per-minute watchdog added (crontab, no user field)"
  fi
  killall -HUP crond 2>/dev/null || true
elif [ -d /usr/builtin/etc/crontabs ] || [ -d /var/spool/cron/crontabs ]; then
  CT=/usr/builtin/etc/crontabs/root
  [ -d /usr/builtin/etc/crontabs ] || CT=/var/spool/cron/crontabs/root
  touch "$CT" 2>/dev/null
  if grep -q "sftp-cicd-watchdog" "$CT" 2>/dev/null; then
    ok "cron: watchdog already registered in $CT"
  else
    printf '* * * * * %s\n' "$WATCHDOG" >> "$CT"
    chmod 600 "$CT" 2>/dev/null
    ok "cron: per-minute watchdog added to $CT (no user field)"
  fi
  killall -HUP crond 2>/dev/null || true
elif [ -f /etc/crontab ]; then
  grep -q "sftp-cicd-watchdog" /etc/crontab 2>/dev/null || \
    printf '* * * * * root %s\n' "$WATCHDOG" >> /etc/crontab
  ok "cron: watchdog added to /etc/crontab (user-field format)"
  killall -HUP crond 2>/dev/null || true
else
  warn "no crontab mechanism found — watchdog installed but not scheduled; add manually: * * * * * $WATCHDOG"
fi

# 5) restart the SFTP service and verify
log "-- restart sftpmand --"
"$INIT" stop  >/dev/null 2>&1
sleep 1
"$INIT" start >/dev/null 2>&1
sleep 2
if port_listening; then
  ok "port $PORT LISTEN — SFTP service up"
else
  warn "port $PORT still DOWN after restart — check: $INIT start ; tail /var/log/messages"
fi

log "== done. Re-run with --verify after a CI run to confirm no new sig=31 and port stays up. =="
