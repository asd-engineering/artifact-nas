#!/bin/sh
#
# fix-sftp-seccomp-crash.sh — Asustor ADM SFTP-daemon seccomp crash recovery
#
# SYMPTOM
#   - SFTP service on port 4589 dies repeatedly with no obvious config error.
#   - /var/log/messages shows:
#       sshd-session: error: mm_reap: preauth child terminated by signal 31
#       kernel audit: comm="sshd-session" sig=31 syscall=87 code=0x0
#   - Subsequent SSH/SFTP attempts from same IP get
#       sshd: drop connection #0 ... penalty: caused crash
#   - ADM UI toggle for SFTP fails to start the service.
#
# ROOT CAUSE
#   OpenSSH preauth privsep child tries to update /var/log/lastlog when
#   `PrintLastLog yes` is set. The lastlog file is absent on some Asustor
#   firmware builds (4.2.5.RN33+). OpenSSH's write path includes an
#   unlink(2) syscall (syscall 87 on x86_64). The privsep seccomp filter
#   does NOT allow unlink() in the preauth context, so the kernel kills
#   the child with SIGSYS (signal 31). Every connection crashes; eventually
#   the service supervisor SIGTERMs the master and the listener disappears.
#
#   Asustor has TWO independent SFTP sshd config files:
#     /usr/builtin/etc.default/sshd_config_sftp  (defaults; firmware updates restore from here)
#     /usr/builtin/etc/sshd_config_sftp          (runtime; what the daemon actually reads)
#   A fix to runtime alone may be undone by the next firmware update if it
#   copies defaults → runtime. We patch BOTH.
#
# WHAT THIS SCRIPT DOES (idempotent)
#   1. touch /var/log/lastlog so the preauth path does not need unlink()
#   2. chown root:root, chmod 644
#   3. Edit `PrintLastLog yes` -> `PrintLastLog no` in BOTH config files
#      (defaults + runtime), with timestamped .bak.* backups
#   4. Add a @reboot cron entry so the lastlog file is recreated after
#      any wipe / firmware update / tmpfs-style cleanup
#   5. Restart the SFTP service via Asustor's own service tool:
#         /usr/bin/serviceutil sshd restart
#      (ADM UI toggle is unreliable when the service is in a crash-loop;
#      CLI restart works because it doesn't depend on the UI state)
#
# USAGE
#   sudo sh fix-sftp-seccomp-crash.sh           # apply
#   sudo sh fix-sftp-seccomp-crash.sh --check   # report only, no changes
#   sudo sh fix-sftp-seccomp-crash.sh --verify  # post-apply: tail audit log
#
# VERIFICATION
#   After running, connect to port 4589 from outside and watch:
#     sudo dmesg | grep 'sig=31' | tail
#   The count should NOT increase as new connections come in.
#
# REVERSAL
#   Backups are at /usr/builtin/etc{,.default}/sshd_config_sftp.bak.<ts>.
#   Restore with cp; serviceutil sshd restart.

set -e

CONF_RUNTIME=/usr/builtin/etc/sshd_config_sftp
CONF_DEFAULT=/usr/builtin/etc.default/sshd_config_sftp
LASTLOG=/var/log/lastlog
CRONFILE=/usr/builtin/etc/crontabs/root
CRON_LINE='@reboot touch /var/log/lastlog && chmod 644 /var/log/lastlog'

MODE="apply"
case "${1:-}" in
  --check)  MODE="check" ;;
  --verify) MODE="verify" ;;
  -h|--help)
    sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

if [ "$MODE" = "verify" ]; then
  echo "=== Recent SIGSYS (sig=31) kernel audits — should NOT grow on new connections ==="
  dmesg 2>/dev/null | grep -E 'sshd-session.*sig=31' | tail -5
  echo ""
  echo "=== Current SFTP listener (expect 0.0.0.0:4589) ==="
  netstat -tnl 2>/dev/null | grep -E ':4589' || echo "  not listening on 4589"
  echo ""
  echo "=== Current PrintLastLog state ==="
  grep -nH PrintLastLog "$CONF_RUNTIME" "$CONF_DEFAULT" 2>/dev/null || true
  exit 0
fi

if [ "$MODE" = "check" ]; then
  echo "=== Lastlog file ==="
  ls -la "$LASTLOG" 2>&1 || echo "  MISSING (would create)"
  echo ""
  echo "=== PrintLastLog in both configs ==="
  grep -nH PrintLastLog "$CONF_RUNTIME" "$CONF_DEFAULT" 2>/dev/null
  echo ""
  echo "=== Cron @reboot hook ==="
  grep -nH lastlog "$CRONFILE" 2>/dev/null || echo "  ABSENT (would add)"
  exit 0
fi

# Idempotent apply path —————————————————————————————————————

# 1. lastlog file
if [ ! -e "$LASTLOG" ]; then
  echo "→ creating $LASTLOG"
  touch "$LASTLOG"
fi
chmod 644 "$LASTLOG"
chown root:root "$LASTLOG"

# 2. patch both configs (runtime + defaults)
for f in "$CONF_RUNTIME" "$CONF_DEFAULT"; do
  if [ ! -f "$f" ]; then
    echo "  $f does not exist — skipping"
    continue
  fi
  if grep -q '^PrintLastLog yes$' "$f"; then
    bak="${f}.bak.$(date +%s)"
    cp "$f" "$bak"
    sed -i 's/^PrintLastLog yes$/PrintLastLog no/' "$f"
    echo "→ patched $f (backup: $bak)"
  else
    echo "  $f already has PrintLastLog set to $(grep ^PrintLastLog "$f" | head -1)"
  fi
done

# 3. cron @reboot guard
if ! grep -qF 'lastlog' "$CRONFILE" 2>/dev/null; then
  echo "$CRON_LINE" >> "$CRONFILE"
  echo "→ added @reboot guard to $CRONFILE"
else
  echo "  cron @reboot guard already present in $CRONFILE"
fi

# 4. restart SFTP service via Asustor service tool
if [ -x /usr/bin/serviceutil ]; then
  echo "→ /usr/bin/serviceutil sshd restart"
  /usr/bin/serviceutil sshd restart || {
    echo "  serviceutil failed; trying direct sshd kill+start as last resort"
    pkill -f "sshd_config_sftp" 2>/dev/null || true
    sleep 1
    /usr/sbin/sshd -f "$CONF_RUNTIME"
  }
else
  echo "  serviceutil not found — attempting direct sshd start"
  /usr/sbin/sshd -f "$CONF_RUNTIME"
fi

echo ""
echo "DONE."
echo ""
echo "Verify externally:"
echo "  timeout 5 bash -c 'echo > /dev/tcp/<public-ip>/4589' && echo OPEN || echo CLOSED"
echo ""
echo "Confirm seccomp kills stopped (run this script with --verify after a few connections):"
echo "  sudo sh $0 --verify"
