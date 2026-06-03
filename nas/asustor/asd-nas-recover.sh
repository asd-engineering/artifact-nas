#!/bin/sh
# ASD CI NAS recovery — re-apply sshd-session patches + (re)start sftpmand (4589).
# Persistent copy lives at /usr/local/sbin/ and is wired to @reboot (see crontab).
# Manual run: sudo sh /usr/local/sbin/asd-nas-recover.sh
PSS=/usr/local/sbin/patch-sshd-session.py
PSC=/usr/local/sbin/patch-seccomp.py
PY="$(command -v python3 || command -v python || echo /usr/local/bin/python3)"
echo "=== asd-nas-recover $(date) ==="
echo "--- [1/4] AllowGroups patch ---"
[ -f "$PSS" ] && "$PY" "$PSS"; echo "exit=$?"
echo "--- [2/4] seccomp patch ---"
[ -f "$PSC" ] && "$PY" "$PSC"; echo "exit=$?"
echo "--- [3/4] restart sftpmand ---"
/usr/builtin/etc/init.d/S79sftpmand stop 2>/dev/null; sleep 1
/usr/builtin/etc/init.d/S79sftpmand start; sleep 2
echo "--- [4/4] verify ---"
if ps -ef | grep -q '[s]ftpmand'; then echo "sftpmand: RUNNING"; else echo "sftpmand: NOT RUNNING"; fi
( ss -tlnp 2>/dev/null || netstat -tln 2>/dev/null ) | grep -E ':4589' || echo "  (4589 not listening)"
echo "=== done ==="
