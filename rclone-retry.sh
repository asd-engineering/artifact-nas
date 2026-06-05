# shellcheck shell=bash
# Shared rclone retry / wall-clock-guard library for the upload + download
# composite actions. SOURCED (not executed) by each step:
#
#     source "${GITHUB_ACTION_PATH}/../rclone-retry.sh"
#
# (GITHUB_ACTION_PATH points at the action's own dir — upload/ or download/ —
#  and the whole repo is checked out, so the sibling file is one level up.)
#
# Defines: run_rclone, rclone_retry, the RCLONE_* knob defaults, NAS_DEAD_RC,
# and the wall-clock-killer detection. One source of truth so the three call
# sites (upload nas, upload nas-first, download) can't drift.
#
# --- Why a wall-clock guard at all -------------------------------------------
# rclone's --contimeout bounds only the TCP dial and --timeout is an idle-IO
# timer on an ESTABLISHED connection — neither covers the SSH handshake /
# SFTP-subsystem open (NewFs). A NAS that accepts the TCP connection then
# stalls mid-handshake wedges a single rclone call forever (no output, no
# exit). In v1.4.8 one upload hung 61 min until the job's 90-min cap killed
# it. We run every rclone under an OS wall-clock killer so a wedge becomes
# exit 124/137 and re-enters the retry loop instead of blocking.
#
# --- Budget model ------------------------------------------------------------
# A refusing/stalling NAS is the preferred sink having a bad moment, not a
# dead one — so we retry it hard. "Hard, but bounded" is enforced two ways:
#   * per-attempt: a subcommand-aware wall-clock cap (no single op can hang).
#   * across the step: a FAILURE budget (RCLONE_MAX_TOTAL) that counts only
#     time spent on FAILED attempts + backoff. A slow but SUCCESSFUL transfer
#     never eats the budget, so a healthy-but-large copy can't starve a later
#     item of its retries. Only when accumulated failure time crosses the
#     budget do we declare the NAS dead-for-this-run and let the caller fall
#     over (GitHub last-resort for nas-first/fallback; hard fail otherwise).

# --- timeout binary: GNU `timeout` (Linux) or `gtimeout` (macOS+coreutils) ---
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"; fi
[ -z "${TIMEOUT_BIN}" ] && echo "::warning::no 'timeout'/'gtimeout' on PATH — rclone runs without a wall-clock guard" >&2

# --- knobs (integer SECONDS; env-overridable) --------------------------------
RCLONE_PROBE_TIMEOUT="${RCLONE_PROBE_TIMEOUT:-45}"   # per-attempt cap for quick metadata ops (lsf/mkdir/…)
RCLONE_OP_TIMEOUT="${RCLONE_OP_TIMEOUT:-600}"        # per-attempt cap for data ops (copy/sync) AND any unlisted op
RCLONE_MAX_TOTAL="${RCLONE_MAX_TOTAL:-300}"          # FAILURE budget: cumulative failed-attempt + backoff seconds before NAS is "dead"

# Exit code rclone_retry returns when the failure budget is exhausted — kept
# distinct from rclone's own codes so callers can tell "NAS dead" apart from
# e.g. "directory not found" (a clean cache miss).
NAS_DEAD_RC=75

# run_rclone <deadline-seconds> <rclone args…>
# Run rclone under an OS wall-clock killer: SIGTERM at <deadline> (exit 124),
# SIGKILL 15s later if it ignores that (exit 137).
run_rclone() {
  local deadline="$1"; shift
  if [ -n "${TIMEOUT_BIN}" ]; then
    "${TIMEOUT_BIN}" --kill-after=15s "${deadline}" rclone "$@"
  else
    rclone "$@"
  fi
}

# rclone_retry <rclone args…>
# Returns 0 on success, NAS_DEAD_RC when the failure budget is spent, or
# rclone's own exit code on a hard (non-retryable) error. Diagnostics go to
# stderr so stdout stays clean for callers that capture it (download's lsf).
rclone_retry() {
  : "${NAS_FAILTIME:=0}"   # cumulative failed-attempt+backoff seconds (persists across calls in one step)
  local backoff=5 errlog exit_code transient t0 cap
  # Per-attempt deadline by subcommand. Default to the LONG cap so an
  # unlisted (possibly slow) op is never wrongly killed; only known-quick
  # metadata ops get the short probe cap. (Killing a healthy slow op at 45s
  # would be misread as a transient and retried into a spurious failover.)
  case "${1:-}" in
    lsf|lsd|ls|lsl|lsjson|md5sum|sha1sum|mkdir|rmdir|rmdirs|touch|stat|about|size) cap="${RCLONE_PROBE_TIMEOUT}" ;;
    *) cap="${RCLONE_OP_TIMEOUT}" ;;
  esac
  while :; do
    errlog="$(mktemp)"
    t0=$SECONDS
    # Capture stderr to a file (NOT a `tee` process substitution: bash does
    # not wait for the substituted process, so a following grep could read an
    # unflushed errlog and misclassify the failure). Surface it afterwards.
    if run_rclone "${cap}" "$@" 2>"$errlog"; then
      cat "$errlog" >&2; rm -f "$errlog"; return 0
    else
      exit_code=$?
    fi
    cat "$errlog" >&2
    # Hard, non-retryable: bad credentials / permissions / unknown SSH key.
    if grep -qiE "permission denied|unable to authenticate|authentication failed|no such identity|publickey" "$errlog"; then
      echo "::error::NAS hard error (auth/permission) — not retryable" >&2
      rm -f "$errlog"; return "$exit_code"
    fi
    # Transient (retry): wall-clock kill (124/137, usually an EMPTY errlog so
    # match on the exit code), connection refused (fail2ban / sshd-not-ready),
    # transient DNS (as self-healing as 'refused'), and the init-layer races.
    transient=0
    if [ "$exit_code" -eq 124 ] || [ "$exit_code" -eq 137 ]; then
      echo "::warning::rclone wedged — killed by wall-clock guard (exit ${exit_code})" >&2
      transient=1
    elif grep -qiE "connection refused|no such host|name resolution|temporary failure in name resolution|NewFs:|couldn.?t initialise SFTP|couldn.?t connect|unexpected EOF|connection reset|connection closed|version packet|kex_exchange|handshake failed|broken pipe|i/o timeout|too many|throttl" "$errlog"; then
      transient=1
    fi
    rm -f "$errlog"
    if [ "$transient" -ne 1 ]; then return "$exit_code"; fi   # unknown hard error
    # Charge only the FAILED attempt's wall time (a successful transfer never
    # reaches here), then check the budget BEFORE sleeping/backing off.
    NAS_FAILTIME=$(( NAS_FAILTIME + (SECONDS - t0) ))
    if [ "$NAS_FAILTIME" -ge "${RCLONE_MAX_TOTAL}" ]; then
      echo "::warning::NAS retry budget ${RCLONE_MAX_TOTAL}s spent on failures — treating NAS as dead for this run" >&2
      return "${NAS_DEAD_RC}"
    fi
    echo "::warning::NAS not ready (exit ${exit_code}) — retrying in ${backoff}s (failure budget ${NAS_FAILTIME}/${RCLONE_MAX_TOTAL}s)" >&2
    sleep "$backoff"
    NAS_FAILTIME=$(( NAS_FAILTIME + backoff ))
    backoff=$(( backoff * 2 )); [ "$backoff" -gt 60 ] && backoff=60
  done
}
