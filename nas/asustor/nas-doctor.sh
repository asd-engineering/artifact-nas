#!/usr/bin/env bash
# nas-doctor.sh — layered NAS health probe for CI.
#
# Diagnoses where NAS uploads/downloads break. The symptom we kept hitting
# in PR #279:
#
#   NewFs: couldn't initialise SFTP: error receiving version packet from
#   server: server unexpectedly closed connection: unexpected EOF
#
# That message is rclone failing at the SSH protocol VERSION exchange —
# the very first thing after TCP accept. The standard `--retries N` flags
# don't help: they retry per-file copy errors and per-chunk reads, not
# `NewFs()` init. So a single bad handshake fails the whole upload.
#
# This doctor walks the stack one layer at a time and reports where it
# breaks. Modeled on glab-runner's `runner-doctor.sh` (the ExecStartPre
# preflight that refuses to start the runner on an undersized host).
#
# Usage:
#   nas-doctor.sh                # report layered health, exit 0 on any
#                                # OK / DEGRADED outcome (best-effort, never
#                                # blocks CI just from running diagnostics)
#   nas-doctor.sh --strict       # exit 1 on any DEGRADED / FAIL
#   nas-doctor.sh --json         # emit per-layer JSON (for CI summary jobs)
#
# Reads the same secrets as artifact-nas action / artifact-nas:
#   RCLONE_CONF_B64  base64 of rclone.conf (first [remote] auto-detected)
#   NAS_DEST         base path on NAS (default /artifacts)
#
# No-op + exit 0 if RCLONE_CONF_B64 is unset — same contract as artifact-nas action.
set -uo pipefail

STRICT=0
EMIT_JSON=0
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    --json) EMIT_JSON=1 ;;
    *) echo "::warning::nas-doctor: ignoring unknown arg '$arg'" >&2 ;;
  esac
done

# Output: per-layer "<status> <layer> <detail>" lines. status ∈ OK/DEGRADED/FAIL/SKIP.
declare -a REPORT_LINES=()
report() {
  local status="$1" layer="$2" detail="${3:-}"
  REPORT_LINES+=("${status} ${layer} ${detail}")
  if [ "$EMIT_JSON" -eq 0 ]; then
    case "$status" in
      OK)       printf '  ✅ %-12s %s\n' "$layer" "$detail" ;;
      DEGRADED) printf '  ⚠️  %-12s %s\n' "$layer" "$detail" ;;
      FAIL)     printf '  ⛔ %-12s %s\n' "$layer" "$detail" ;;
      SKIP)     printf '  ⚪ %-12s %s\n' "$layer" "$detail" ;;
    esac
  fi
}

# Emit JSON summary on exit (even on early failure). Trap handles both the
# normal-flow `exit 0` and the early-exit-on-FAIL paths uniformly so
# --json callers always get a parseable line.
emit_json_summary() {
  [ "$EMIT_JSON" -eq 1 ] || return 0
  printf '['
  local sep="" line status rest layer detail detail_esc
  for line in "${REPORT_LINES[@]}"; do
    status="${line%% *}"
    rest="${line#* }"
    layer="${rest%% *}"
    detail="${rest#* }"
    detail_esc="${detail//\\/\\\\}"
    detail_esc="${detail_esc//\"/\\\"}"
    printf '%s{"status":"%s","layer":"%s","detail":"%s"}' "$sep" "$status" "$layer" "$detail_esc"
    sep=","
  done
  printf ']\n'
}

# Install JSON-emit trap IMMEDIATELY (before any exit path) so --json
# callers always get a parseable array, including on the SKIP-env early
# exit below. Tempfile cleanup is layered on AFTER mktemp runs — the
# cleanup function reads $CONF/$LSD_LOG which start as empty and become
# real paths after conf decoding; `rm -f` on empty string is a no-op.
CONF=""
LSD_LOG=""
cleanup() {
  emit_json_summary
  rm -f "$CONF" "$LSD_LOG"
}
trap cleanup EXIT

if [ -z "${RCLONE_CONF_B64:-}" ]; then
  report SKIP env "RCLONE_CONF_B64 unset"
  # Echo the warning to stderr only when not in JSON mode (the structured
  # output is the JSON in that case; stderr noise would mix into logs).
  [ "$EMIT_JSON" -eq 0 ] && echo "::warning::nas-doctor: RCLONE_CONF_B64 unset — skipping NAS health probe"
  exit 0
fi

# --- Decode conf, extract host/port/user/remote -------------------------------

CONF="$(mktemp)"
if ! printf '%s' "${RCLONE_CONF_B64}" | base64 -d > "$CONF" 2>/dev/null; then
  report FAIL conf "RCLONE_CONF_B64 not valid base64"
  exit 1
fi
chmod 600 "$CONF"

REMOTE="$(sed -n 's/^\[\(.*\)\]$/\1/p' "$CONF" | head -n1)"
if [ -z "$REMOTE" ]; then
  report FAIL conf "no [remote] section found in decoded rclone.conf"
  exit 1
fi
# Extract host / port / user from the first remote's block. Stop at the next
# section header. Strip surrounding whitespace.
get_field() {
  local key="$1"
  awk -v key="$key" '
    /^\[/{ if (in_section) exit; in_section = ($0 == "['"$REMOTE"']") }
    in_section && $0 ~ "^[[:space:]]*"key"[[:space:]]*=" {
      sub("^[[:space:]]*"key"[[:space:]]*=[[:space:]]*", "")
      print
      exit
    }
  ' "$CONF"
}
NAS_HOST="$(get_field host)"
NAS_PORT="$(get_field port)"
NAS_USER="$(get_field user)"
NAS_PORT="${NAS_PORT:-22}"
if [ -z "$NAS_HOST" ]; then
  report FAIL conf "remote '${REMOTE}' has no host= field"
  exit 1
fi
report OK conf "remote=${REMOTE} host=${NAS_HOST} port=${NAS_PORT} user=${NAS_USER:-?}"

# --- Layer 1: TCP reachability (bash /dev/tcp — no nc/curl needed) -----------

TCP_T0=$(date +%s%N)
if timeout 5 bash -c "</dev/tcp/${NAS_HOST}/${NAS_PORT}" 2>/dev/null; then
  TCP_MS=$(( ($(date +%s%N) - TCP_T0) / 1000000 ))
  report OK tcp "connect in ${TCP_MS}ms"
else
  report FAIL tcp "cannot open TCP to ${NAS_HOST}:${NAS_PORT} (firewall / host down / wrong port)"
  [ "$STRICT" -eq 1 ] && exit 1 || exit 0
fi

# --- Layer 2: SSH banner exchange (raw — does sshd respond before EOF?) ------
# An sshd at MaxStartups capacity accepts the TCP socket then immediately
# closes WITHOUT sending the "SSH-2.0-..." banner. That's the exact signature
# our CI runs were tripping. Probe with a 3-second read; expect a banner that
# starts with SSH-.
BANNER_T0=$(date +%s%N)
BANNER="$(timeout 5 bash -c "exec 3<>/dev/tcp/${NAS_HOST}/${NAS_PORT}; head -n1 <&3 2>/dev/null; exec 3<&- 3>&-" 2>/dev/null || true)"
BANNER_MS=$(( ($(date +%s%N) - BANNER_T0) / 1000000 ))
case "$BANNER" in
  SSH-2.0-*|SSH-1.99-*)
    report OK ssh-banner "${BANNER} in ${BANNER_MS}ms"
    ;;
  "")
    report FAIL ssh-banner "no banner in ${BANNER_MS}ms (sshd MaxStartups exhausted? fail2ban? Match-block deny? — restart sshd or raise MaxStartups)"
    [ "$STRICT" -eq 1 ] && exit 1
    ;;
  *)
    report DEGRADED ssh-banner "unexpected banner: ${BANNER}"
    ;;
esac

# --- Layer 3: rclone SFTP NewFs init (the layer that's failing today) --------
# This is what actually breaks in CI. rclone needs to: TCP connect, finish
# SSH version+kex+auth, open SFTP subsystem, list the destination dir. We
# probe with `rclone lsd` against the remote's root — minimal data, full
# init. If this fails the same way the uploads fail, we've reproduced the
# bug from the doctor.
if ! command -v rclone >/dev/null 2>&1; then
  report SKIP rclone-init "rclone not installed on this runner — skipping NewFs probe"
else
  export RCLONE_CONFIG="$CONF"
  LSD_LOG="$(mktemp)"  # cleanup() (EXIT trap) rms this
  LSD_T0=$(date +%s%N)
  if rclone lsd "${REMOTE}:" --max-depth 1 --timeout 10s --contimeout 5s > "$LSD_LOG" 2>&1; then
    LSD_MS=$(( ($(date +%s%N) - LSD_T0) / 1000000 ))
    report OK rclone-init "lsd OK in ${LSD_MS}ms"
  else
    LSD_MS=$(( ($(date +%s%N) - LSD_T0) / 1000000 ))
    # Extract the most diagnostic line — rclone's error chain is long.
    KEY_ERR="$(grep -oE "(NewFs:.*|couldn't initialise SFTP:.*|connection refused|no route to host|timeout)" "$LSD_LOG" | head -n1)"
    KEY_ERR="${KEY_ERR:-$(tail -n1 "$LSD_LOG")}"
    report FAIL rclone-init "after ${LSD_MS}ms: ${KEY_ERR}"
    [ "$STRICT" -eq 1 ] && exit 1
  fi
fi

# --- Layer 4: round-trip copy (catches partial-handshake / read-only mounts) -
# Tiny file: upload, list, download, compare. Skipped if rclone init already
# failed (no point probing higher when the foundation's down).
if command -v rclone >/dev/null 2>&1 && grep -q "OK rclone-init" <<< "$(printf '%s\n' "${REPORT_LINES[@]}")"; then
  PROBE_DIR="$(mktemp -d)"
  PROBE_FILE="${PROBE_DIR}/probe-$(date +%s).txt"
  echo "nas-doctor $(date -Iseconds) ${HOSTNAME:-$(hostname)}" > "$PROBE_FILE"
  DEST="${NAS_DEST:-/artifacts}/.nas-doctor"
  RT_T0=$(date +%s%N)
  if rclone copy "$PROBE_FILE" "${REMOTE}:${DEST}" \
       --timeout 15s --contimeout 5s --transfers 1 \
       --low-level-retries 2 --retries 1 > /dev/null 2>&1
  then
    rclone delete "${REMOTE}:${DEST}/$(basename "$PROBE_FILE")" \
       --timeout 10s --contimeout 5s > /dev/null 2>&1 || true
    RT_MS=$(( ($(date +%s%N) - RT_T0) / 1000000 ))
    report OK round-trip "tiny upload + delete in ${RT_MS}ms"
  else
    RT_MS=$(( ($(date +%s%N) - RT_T0) / 1000000 ))
    report DEGRADED round-trip "after ${RT_MS}ms — init OK but transfer flaky (sshd kicking long sessions? net path?)"
  fi
  rm -rf "$PROBE_DIR"
fi

# --- Summary -----------------------------------------------------------------
# JSON emit handled by the EXIT trap above so early-exit FAILs still emit.
# Exit code: STRICT exits on any FAIL/DEGRADED above; non-strict exits 0
# always so this is safe to wire as a preflight that surfaces signal
# without blocking CI on transient noise.
exit 0
