#!/usr/bin/env bash
# nas-rclone.sh — CANDIDATE optimized rclone upload logic for artifact-nas.
#
# Goal: survive a CI fan-out against the Asustor SFTP listener without tripping
# MaxStartups or counting recoverable blips as failures. Gentle on the listener
# (few concurrent pre-auth connections, paced) + broad transient-retry with
# jittered exponential backoff.
#
# SOURCE OF TRUTH = artifact-nas (upload/action.yml + download/action.yml:
# the RC_FLAGS array + rclone_retry()). This script MIRRORS that logic so the
# nas-test load test exercises the exact production behaviour — keep the two in
# sync (change artifact-nas, then mirror here). Validated 2026-06-03: 0% fail at
# fanout 40 & 80 with the firewall on, no wedge.
#
# Usage: nas-rclone.sh <localfile> <remote:dest>
set -uo pipefail
SRC="${1:?source file required}"
DST="${2:?remote:dest required}"

# Flags — minimise concurrent pre-auth connections per job + pace the rate:
#   --transfers 2 --checkers 2     cap concurrent SSH channels (checkers
#                                  defaulted to 8 → 8 connections in the check
#                                  phase; capping is the main win).
#   --sftp-concurrency 1           one SFTP request in flight per connection.
#   --sftp-disable-concurrent-reads
#   --tpslimit 4 --tpslimit-burst 4  smooth the transaction rate so a job
#                                  doesn't burst the listener (MaxStartups).
#   --low-level-retries 10         ride out momentary throttling per-chunk
#                                  instead of failing the whole transfer.
#   --retries 1                    no immediate (un-backed-off) whole-sync
#                                  retry — backoff is handled by the wrapper.
#   --timeout 60s --contimeout 20s tolerate a brief throttle window on connect.
# Flag values are env-overridable (defaults == the artifact-nas action flags, so
# this MIRRORS production by default). The nas-loadtest workflow sweeps these via
# NAS_RCLONE_* inputs to find/confirm a config that doesn't break the NAS.
RC_FLAGS=(
  --transfers "${NAS_RCLONE_TRANSFERS:-2}" --checkers "${NAS_RCLONE_CHECKERS:-2}"
  --retries 1 --low-level-retries "${NAS_RCLONE_LLR:-10}"
  --sftp-concurrency 1 --sftp-disable-concurrent-reads
  --tpslimit "${NAS_RCLONE_TPSLIMIT:-4}" --tpslimit-burst "${NAS_RCLONE_TPSLIMIT:-4}"
  --timeout "${NAS_RCLONE_TIMEOUT:-60s}" --contimeout "${NAS_RCLONE_CONTIMEOUT:-20s}"
  --stats-one-line
)

# Retry on ANY connection/init-layer transient (the old wrapper only caught
# NewFs/EOF/reset and missed MaxStartups drops that surface as "connection
# closed" / "kex_exchange" / "handshake failed" / "i/o timeout").
TRANSIENT='NewFs:|couldn.?t initialise SFTP|couldn.?t connect|unexpected EOF|connection reset|connection closed|version packet|kex_exchange|handshake failed|broken pipe|i/o timeout|connection refused|too many|throttl'

max_attempts="${NAS_RCLONE_MAX_ATTEMPTS:-7}"
attempt=1; backoff=1
errlog="$(mktemp)"
while [ "$attempt" -le "$max_attempts" ]; do
  if rclone copyto "$SRC" "$DST" "${RC_FLAGS[@]}" 2> >(tee "$errlog" >&2); then
    rm -f "$errlog"; exit 0
  fi
  rc=$?
  if grep -qiE "$TRANSIENT" "$errlog" && [ "$attempt" -lt "$max_attempts" ]; then
    jitter=$(( RANDOM % 4 ))   # de-sync retries across parallel CI jobs
    echo "nas-rclone: transient SFTP error (attempt ${attempt}/${max_attempts}) — retry in $(( backoff + jitter ))s" >&2
    sleep "$(( backoff + jitter ))"
    backoff=$(( backoff * 2 + 1 ))   # 1,3,7,15,31,63 (+jitter)
    attempt=$(( attempt + 1 ))
    continue
  fi
  # non-transient (auth/permission/real error) → fail fast, don't hammer
  rm -f "$errlog"; exit "$rc"
done
rm -f "$errlog"
echo "nas-rclone: SFTP init kept failing after ${max_attempts} attempts" >&2
exit 1
