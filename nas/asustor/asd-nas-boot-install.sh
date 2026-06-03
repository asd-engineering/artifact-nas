#!/bin/sh
# One-time root installer: make the NAS sftpmand/4589 recovery survive reboots.
# Run as root: sudo sh /volume1/home/Kelvin/asd-nas-boot-install.sh
set -e
SBIN=/usr/local/sbin
CRON=/usr/builtin/etc/crontabs/root

echo "1) persist patch-seccomp.py -> $SBIN"
for src in /usr/local/sbin/patch-seccomp.py /volume1/home/Kelvin/patch-seccomp.py /tmp/patch-seccomp.py; do
  [ -f "$src" ] && { cp "$src" "$SBIN/patch-seccomp.py"; break; }
done
chmod 755 "$SBIN/patch-seccomp.py"

echo "2) persist asd-nas-recover.sh -> $SBIN"
cp /volume1/home/Kelvin/asd-nas-recover.sh "$SBIN/asd-nas-recover.sh"
chmod 755 "$SBIN/asd-nas-recover.sh"

echo "3) wire @reboot (full recovery: both patches + sftpmand restart)"
if ! grep -q 'asd-nas-recover.sh' "$CRON"; then
  # sleep 45 so the stock S79sftpmand + filesystem are up before we re-patch+restart
  echo '@reboot sleep 45 && /bin/sh /usr/local/sbin/asd-nas-recover.sh >> /var/log/asd-nas-recover.log 2>&1' >> "$CRON"
  echo "   added @reboot asd-nas-recover.sh"
else
  echo "   @reboot asd-nas-recover.sh already present"
fi
# reload busybox crond so the new crontab is picked up
kill -HUP "$(pgrep -x crond | head -1)" 2>/dev/null && echo "   crond reloaded" || true

echo "=== installed. @reboot lines now: ==="
grep -nE 'reboot.*(patch|recover)' "$CRON"
echo "=== running recovery once now to verify ==="
/bin/sh "$SBIN/asd-nas-recover.sh"
