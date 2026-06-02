#!/usr/bin/env bash
# sftp-loadtest.sh — concurrency ramp against an SSH/SFTP endpoint to find the
# *handshake* breaking point and differentiate NAS-daemon vs router/NAT walls.
#
# Two arms:
#   raw    — credential-free SSH KEX probe. Drives the exact CPU-heavy crypto
#            handshake CI fails at. "Permission denied" == KEX completed (GOOD);
#            kex_exchange_identification / reset / EOF == the CI symptom (BAD).
#            Needs NO credentials and is rclone-independent — so a BAD result
#            here simultaneously locates the ceiling AND exonerates rclone.
#   rclone — real SFTP round-trip using --key (optional confirmation arm).
#
# Server-side snapshots (load/free/swap/dmesg sig=31/sftpmand pid) are taken via
# an admin SSH alias (default nas-kelvin) before+after each burst, so they never
# pollute the port-4589 measurement (separate daemon on 2324).
#
# Usage:
#   sftp-loadtest.sh --host H [--port 4589] [--conc 50] [--arm raw|rclone]
#                    [--user U] [--key PATH] [--label TXT] [--admin SSH_ALIAS]
#                    [--outdir DIR] [--timeout 15]
#
#   --host     target SSH/SFTP host (required)
#   --conc     number of simultaneous connections to fire
#   --arm raw  credential-free KEX probe (default) — needs nothing, measures the
#              handshake layer that CI fails at and is rclone-independent.
#   --arm rclone  real SFTP round-trip; requires --user and --key (an SSH key
#              authorized for that user on the target).
#   --admin    OPTIONAL ssh alias/target with admin access for server-side
#              snapshots (load/mem/swap/dmesg/master-pid). Omit to skip them and
#              run a pure client-side load test from anywhere.
#   --outdir   where per-run traces land (default: ${TMPDIR:-/tmp}/sftp-loadtest)
set -u
shopt -s nullglob

HOST=""; PORT="4589"; USER_NAME="loadtest"; CONC="10"; ARM="raw"
KEY=""; LABEL=""; ADMIN=""; OUTDIR=""
CONNECT_TIMEOUT="15"

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --user) USER_NAME="$2"; shift 2;;
    --conc|--concurrency) CONC="$2"; shift 2;;
    --arm) ARM="$2"; shift 2;;
    --key) KEY="$2"; shift 2;;
    --label) LABEL="$2"; shift 2;;
    --admin) ADMIN="$2"; shift 2;;
    --outdir) OUTDIR="$2"; shift 2;;
    --timeout) CONNECT_TIMEOUT="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -n "$HOST" ] || { echo "ERROR: --host required" >&2; exit 2; }
[ -n "$OUTDIR" ] || OUTDIR="${TMPDIR:-/tmp}/sftp-loadtest"
mkdir -p "$OUTDIR"
TS="$(date +%Y%m%d-%H%M%S)"
[ -n "$LABEL" ] || LABEL="${ARM}-${HOST}-p${PORT}-c${CONC}"
RUNDIR="$OUTDIR/${TS}_${LABEL//[^A-Za-z0-9._-]/_}"
mkdir -p "$RUNDIR/probes"
TRACE="$RUNDIR/trace.txt"

# --- server snapshot helper (via admin path; best-effort) ----------------------
snap() {
  [ -n "$ADMIN" ] || { echo "(no --admin; server snapshot skipped)"; return 0; }
  timeout 20 ssh -o ConnectTimeout=8 "$ADMIN" '
    echo "load:$(cut -d" " -f1-3 /proc/loadavg)";
    free -m | awk "/^Mem:/{print \"mem_used_mb:\"\$3\" mem_free_mb:\"\$4\" buffcache_mb:\"\$6} /^Swap:/{print \"swap_used_mb:\"\$3}";
    echo "sig31:$(dmesg 2>/dev/null | grep -c "sig=31")";
    echo "sshd_sftp_master:$(cat /var/run/sshd_sftp.pid 2>/dev/null)";
    echo "sshd_sftp_children:$(pgrep -f sshd_sftp 2>/dev/null | wc -l)";
    echo "estab_4589:$(ss -tn state established 2>/dev/null | grep -c ":4589")";
  ' 2>/dev/null
}

# --- single raw KEX probe ------------------------------------------------------
raw_probe() {
  local idx="$1"
  local out="$RUNDIR/probes/p${idx}.err"
  # PreferredAuthentications=none → server runs full KEX, then refuses auth.
  ssh -p "$PORT" \
      -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o PreferredAuthentications=none -o PubkeyAuthentication=no \
      -o ConnectTimeout="$CONNECT_TIMEOUT" -o LogLevel=ERROR \
      "${USER_NAME}@${HOST}" exit 2>"$out" >/dev/null
  return 0
}

# --- single rclone round-trip probe (optional) ---------------------------------
rclone_probe() {
  local idx="$1"
  local out="$RUNDIR/probes/p${idx}.err"
  local tmp="$RUNDIR/probes/p${idx}.dat"
  head -c 4096 /dev/urandom > "$tmp" 2>/dev/null
  RCLONE_CONFIG_LT_TYPE=sftp \
  RCLONE_CONFIG_LT_HOST="$HOST" RCLONE_CONFIG_LT_PORT="$PORT" \
  RCLONE_CONFIG_LT_USER="$USER_NAME" RCLONE_CONFIG_LT_KEY_FILE="$KEY" \
  RCLONE_CONFIG_LT_SHELL_TYPE=unix \
  RCLONE_CONFIG_LT_MD5SUM_COMMAND=none RCLONE_CONFIG_LT_SHA1SUM_COMMAND=none \
    rclone copyto "$tmp" "LT:/share/loadtest/lt-${idx}.dat" \
      --sftp-concurrency 1 --sftp-disable-concurrent-reads \
      --timeout 30s --contimeout 10s --low-level-retries 1 --retries 1 \
      2>"$out" >/dev/null
  echo "rc=$?" >> "$out"
  rm -f "$tmp"
}

# --- classify one probe's stderr ----------------------------------------------
classify() {
  local f="$1"
  if grep -qiE "permission denied|authentication|no more authentication|too many authentication" "$f"; then
    echo OK            # KEX completed, auth refused == handshake healthy
  elif grep -qiE "kex_exchange_identification|connection closed by|connection reset|unexpectedly closed|banner exchange|broken pipe" "$f"; then
    echo KEXFAIL       # the CI symptom: dropped mid/at-handshake
  elif grep -qiE "connection timed out|operation timed out|timed out waiting" "$f"; then
    echo TIMEOUT
  elif grep -qiE "connection refused" "$f"; then
    echo REFUSED       # port down
  elif [ "$ARM" = rclone ] && grep -qiE "rc=0" "$f"; then
    echo OK
  else
    echo OTHER
  fi
}

# ============================ run ==============================================
{
  echo "=== sftp-loadtest ==="
  echo "ts=$TS host=$HOST port=$PORT user=$USER_NAME arm=$ARM conc=$CONC label=$LABEL"
  echo "--- server BEFORE ---"; snap
} | tee "$TRACE"

START=$(date +%s.%N)
pids=""
i=0
while [ "$i" -lt "$CONC" ]; do
  if [ "$ARM" = rclone ]; then rclone_probe "$i" & else raw_probe "$i" & fi
  pids="$pids $!"
  i=$((i+1))
done
wait $pids 2>/dev/null
END=$(date +%s.%N)
WALL=$(awk "BEGIN{printf \"%.2f\", $END-$START}")

# tally
ok=0; kexfail=0; timeout=0; refused=0; other=0
for f in "$RUNDIR"/probes/p*.err; do
  case "$(classify "$f")" in
    OK) ok=$((ok+1));; KEXFAIL) kexfail=$((kexfail+1));;
    TIMEOUT) timeout=$((timeout+1));; REFUSED) refused=$((refused+1));;
    *) other=$((other+1));;
  esac
done
bad=$((kexfail+timeout+refused+other))

{
  echo "--- server AFTER ---"; snap
  echo "--- RESULT ---"
  echo "wall_s=$WALL conc=$CONC OK=$ok KEXFAIL=$kexfail TIMEOUT=$timeout REFUSED=$refused OTHER=$other BAD=$bad"
  pct=$(awk "BEGIN{printf \"%.1f\", ($bad/$CONC)*100}")
  echo "VERDICT: ${pct}% failed at concurrency ${CONC} ($([ "$bad" -eq 0 ] && echo CLEAN || echo BREAK))"
  echo "--- sample failure signatures ---"
  for f in "$RUNDIR"/probes/p*.err; do
    if [ "$(classify "$f")" != OK ]; then head -1 "$f"; fi
  done | sort | uniq -c | sort -rn | head -6
} | tee -a "$TRACE"

# machine-readable one-liner for ramp aggregation
echo "ROW conc=$CONC ok=$ok bad=$bad kexfail=$kexfail timeout=$timeout refused=$refused other=$other wall=$WALL" >> "$OUTDIR/ramp-${ARM}-$(echo "$HOST" | tr '.' '_')-p${PORT}.tsv"
echo
echo "trace: $TRACE"
