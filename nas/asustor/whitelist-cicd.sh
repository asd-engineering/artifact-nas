#!/usr/bin/env sh
# whitelist-cicd.sh — add CI/CD platform IP ranges to Asustor's
# /usr/builtin/etc/ipblock/defender.safe so CI runners aren't banned
# by ADM Defender's aggressive auto-block policy.
#
# Goal: make `artifact-nas`'s SFTP uploads/downloads survive runner
# bursts without tripping ipblock's "1 failed auth → permanent ban"
# default. See ../README.md (top-level) and ./README.md (Asustor
# mechanics) for the why.
#
# Usage:
#   ./whitelist-cicd.sh [--include LIST] [--custom CIDR,...] [--dry-run | --apply]
#                       [--out PATH] [--max-expand N]
#
#   --include LIST       Comma-separated providers to whitelist. EMPTY by
#                        default — for self-hosted-runner setups (the
#                        common artifact-nas use case) the NAS is on a
#                        private LAN and only sees connections from the
#                        runners themselves. GitHub-hosted runner IPs are
#                        irrelevant unless your NAS is publicly reachable
#                        AND you use GitHub-hosted runners. Choices:
#                          github     (api.github.com/meta — Azure-backed
#                                     ranges; expands to ~500k IPs even
#                                     with --max-expand 24)
#                          gitlab     (documented gitlab.com runner ranges)
#   --custom CIDR,...    THE THING YOU PROBABLY WANT: CIDRs/IPs to
#                        whitelist (e.g. self-hosted runner LAN:
#                        192.168.2.0/24, public IP: 203.0.113.42).
#                        For a typical CI setup this is the only flag
#                        you need.
#   --cidr-mode MODE     How to write CIDR ranges (v1.4.0+):
#                          auto    — default; netmask form for /<max-expand>+,
#                                    individual IPs for ≤ /<max-expand>
#                          expand  — always individual IPs (safest; bloats)
#                          netmask — always single netmask line per CIDR
#                                    (EXPERIMENTAL — verify on YOUR ADM
#                                    version; defender.safe netmask matching
#                                    is undocumented by Asustor)
#   --max-expand N       Threshold for auto/expand. Default 24 (/24 = 256
#                        IPs). Below threshold: per-IP. Above (with auto):
#                        netmask form. Above (with expand): skipped + warning.
#   --dry-run            (default) Print proposed defender.safe lines to
#                        stdout; do NOT write.
#   --apply              Append non-duplicate lines to
#                        /usr/builtin/etc/ipblock/defender.safe. Requires
#                        root / sudo on the NAS.
#   --out PATH           Override target file (testing). Default
#                        /usr/builtin/etc/ipblock/defender.safe.
#
# Examples:
#   # COMMON CASE — whitelist your self-hosted runner LAN + public IP
#   ./whitelist-cicd.sh --custom "192.168.2.0/24,203.0.113.42" --dry-run
#
#   # Rare: also whitelist GitHub Actions hosted-runner ranges (large)
#   ./whitelist-cicd.sh --include github,gitlab --max-expand 20 --dry-run
#
#   # Run locally on the NAS, apply changes
#   ssh -p 2324 admin@nas 'sudo sh -s' < whitelist-cicd.sh --apply --include github
#
#   # Just emit the lines; pipe through your own filter
#   ./whitelist-cicd.sh --include github | grep '^192\.' >> custom.safe
#
# Idempotent: re-running with the same inputs adds nothing (existing
# entries are detected and skipped).

set -eu

# Default OFF for --include: most users only need --custom for their
# self-hosted runner LAN. Hosted-runner whitelisting (GitHub Actions
# IPs) only matters when the NAS is publicly reachable AND CI runs on
# GitHub-hosted runners — uncommon. Without this default, the script
# would emit ~500k IPs from GitHub's published ranges (Azure-backed),
# bloating defender.safe for no benefit.
INCLUDE=""
CUSTOM=""
MODE="dry-run"
OUT="/usr/builtin/etc/ipblock/defender.safe"
MAX_EXPAND=24
# CIDR-emission strategy:
#   expand  — every CIDR → individual <ip>;0.0.0.0;0 lines
#             (always works on every ADM version; bloats for /16+)
#   netmask — every CIDR → single <network>;<netmask>;0 line
#             (EXPERIMENTAL — Asustor defender.safe netmask matching is
#             undocumented; existing entries all use 0.0.0.0 single-IP
#             form. Test on YOUR ADM version before trusting.)
#   auto    — netmask for CIDRs > /<max-expand>, expand for ≤
#             (DEFAULT, balances size + safety: small ranges stay in
#             the proven single-IP form, big ones use netmask)
CIDR_MODE="auto"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --include)    INCLUDE="$2"; shift 2 ;;
    --custom)     CUSTOM="$2"; shift 2 ;;
    --dry-run)    MODE="dry-run"; shift ;;
    --apply)      MODE="apply"; shift ;;
    --out)        OUT="$2"; shift 2 ;;
    --max-expand) MAX_EXPAND="$2"; shift 2 ;;
    --cidr-mode)  CIDR_MODE="$2"; shift 2 ;;
    -h|--help)    sed -n '1,/^set -eu/p' "$0" | grep -E '^#( |$)' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            echo "::error::unknown arg: $1" >&2; exit 2 ;;
  esac
done

# --- fetch helpers ----------------------------------------------------------

fetch_github_cidrs() {
  # GitHub publishes their IP ranges at api.github.com/meta. Pull the
  # categories that matter for outbound rclone/git/webhook traffic.
  # No auth needed for /meta.
  echo "→ fetching GitHub IPs from api.github.com/meta..." >&2
  if command -v jq >/dev/null 2>&1; then
    curl -sf https://api.github.com/meta \
      | jq -r '(.actions // []) + (.git // []) + (.api // []) + (.hooks // []) + (.web // []) | .[]' \
      | sort -u
  else
    # jq-free fallback: extract IPv4 CIDR tokens. Less precise but works.
    curl -sf https://api.github.com/meta \
      | grep -oE '"[0-9]+(\.[0-9]+){3}/[0-9]+"' \
      | tr -d '"' \
      | sort -u
  fi
}

fetch_gitlab_cidrs() {
  # GitLab.com publishes their shared-runner IP ranges in their handbook
  # (intermittently changes). Pinning the documented set here; users can
  # supplement via --custom. As of 2026-Q1:
  #   - 34.74.90.64/28          (legacy gitlab.com runners)
  #   - 35.190.16.0/24          (CDN / runner output)
  #   - 64.41.200.0/24          (gitlab.com web/api)
  #   - 35.235.240.0/20         (CI runner pool)
  # If GitLab adds an /meta-style endpoint, swap this for a fetch.
  echo "→ using static GitLab.com IP ranges (no /meta endpoint exists)" >&2
  cat <<'EOF'
34.74.90.64/28
35.190.16.0/24
64.41.200.0/24
35.235.240.0/20
EOF
}

# --- CIDR → defender.safe line emitters -----------------------------------
# Two strategies, picked per-CIDR by `cidr_to_lines` based on $CIDR_MODE
# and the CIDR's prefix length:
#
#   - cidr_expand_to_ips   one <ip>;0.0.0.0;0 line PER host IP (always
#                          works on every ADM version; bloats for /16+)
#   - cidr_to_netmask_line single <network>;<netmask>;0 line per CIDR
#                          (EXPERIMENTAL — netmask matching in
#                          defender.safe is undocumented; existing
#                          entries on shipping ADM all use 0.0.0.0)
#
# POSIX-sh-friendly; awk for bit math (POSIX awk lacks bitwise ops on
# some implementations, so we provide portable bshl/band).

cidr_expand_to_ips() {
  cidr="$1"
  case "$cidr" in
    */*)  ip="${cidr%/*}"; mask="${cidr#*/}" ;;
    *)    ip="$cidr"; mask="32" ;;
  esac
  case "$ip" in *:*) return 0 ;; esac
  if [ "$mask" -eq 32 ]; then echo "${ip};0.0.0.0;0"; return 0; fi
  awk -v ip="$ip" -v mask="$mask" '
    function bshl(v, n) { while (n-- > 0) v *= 2; return v }
    function band(a, b,   r, p) {
      r = 0; p = 1
      while (a > 0 || b > 0) {
        if ((a % 2 == 1) && (b % 2 == 1)) r += p
        a = int(a / 2); b = int(b / 2); p *= 2
      }
      return r
    }
    BEGIN {
      split(ip, a, ".")
      ipi = a[1]*16777216 + a[2]*65536 + a[3]*256 + a[4]
      hostbits = 32 - mask
      size = bshl(1, hostbits)
      base = band(ipi, bshl(0xFFFFFFFF, hostbits))
      for (i = 0; i < size; i++) {
        x = base + i
        printf "%d.%d.%d.%d;0.0.0.0;0\n", int(x/16777216)%256, int(x/65536)%256, int(x/256)%256, int(x)%256
      }
    }
  '
}

cidr_to_netmask_line() {
  cidr="$1"
  case "$cidr" in
    */*)  ip="${cidr%/*}"; mask="${cidr#*/}" ;;
    *)    ip="$cidr"; mask="32" ;;
  esac
  case "$ip" in *:*) return 0 ;; esac
  awk -v ip="$ip" -v mask="$mask" '
    function bshl(v, n) { while (n-- > 0) v *= 2; return v }
    function band(a, b,   r, p) {
      r = 0; p = 1
      while (a > 0 || b > 0) {
        if ((a % 2 == 1) && (b % 2 == 1)) r += p
        a = int(a / 2); b = int(b / 2); p *= 2
      }
      return r
    }
    BEGIN {
      split(ip, a, ".")
      ipi = a[1]*16777216 + a[2]*65536 + a[3]*256 + a[4]
      hostbits = 32 - mask
      base = band(ipi, bshl(0xFFFFFFFF, hostbits))
      netmask = bshl(0xFFFFFFFF, hostbits) % 4294967296
      printf "%d.%d.%d.%d;%d.%d.%d.%d;0\n", \
        int(base/16777216)%256, int(base/65536)%256, int(base/256)%256, int(base)%256, \
        int(netmask/16777216)%256, int(netmask/65536)%256, int(netmask/256)%256, int(netmask)%256
    }
  '
}

# Dispatcher: per --cidr-mode + per-CIDR-size, pick the emitter.
# Returns lines on stdout in the defender.safe wire format.
cidr_to_lines() {
  cidr="$1"
  case "$cidr" in
    */*)  mask="${cidr#*/}" ;;
    *)    mask="32" ;;
  esac
  case "$cidr" in *:*) echo "::warning::ipv6 not supported, skipping: $cidr" >&2; return 0 ;; esac

  case "$CIDR_MODE" in
    expand)
      # Force per-IP enumeration. Skip if larger than --max-expand.
      if [ "$mask" -lt "$MAX_EXPAND" ]; then
        echo "::warning::CIDR ${cidr} > /${MAX_EXPAND}; skipping (--cidr-mode=expand). Use --cidr-mode=netmask or widen --max-expand." >&2
        return 0
      fi
      cidr_expand_to_ips "$cidr"
      ;;
    netmask)
      # Single netmask line per CIDR. Works for any size; UNTESTED on
      # Asustor — if it doesn't match, fall back to --cidr-mode=auto.
      cidr_to_netmask_line "$cidr"
      ;;
    auto|*)
      # Expand small CIDRs (well-tested individual-IP form);
      # netmask the big ones (experimental but the only way to fit).
      if [ "$mask" -ge "$MAX_EXPAND" ]; then
        cidr_expand_to_ips "$cidr"
      else
        cidr_to_netmask_line "$cidr"
      fi
      ;;
  esac
}

# --- build the candidate set -----------------------------------------------

TMP_RAW="$(mktemp)"
# TMP_IPS removed (v1.4 — cidr_to_lines emits final form directly)
TMP_LINES="$(mktemp)"
trap 'rm -f "$TMP_RAW" "$TMP_LINES"' EXIT

OLD_IFS="$IFS"
IFS=','
for p in $INCLUDE; do
  case "$p" in
    github) fetch_github_cidrs >> "$TMP_RAW" ;;
    gitlab) fetch_gitlab_cidrs >> "$TMP_RAW" ;;
    "")     ;;
    *)      echo "::warning::unknown provider: $p (skipping)" >&2 ;;
  esac
done
IFS="$OLD_IFS"

if [ -n "$CUSTOM" ]; then
  echo "$CUSTOM" | tr ', ' '\n\n' | grep -v '^$' >> "$TMP_RAW"
fi

if [ ! -s "$TMP_RAW" ]; then
  echo "::error::no CIDRs collected — nothing to whitelist" >&2
  exit 1
fi

CIDR_COUNT=$(wc -l < "$TMP_RAW" | tr -d ' ')
case "$CIDR_MODE" in
  expand)  echo "→ emitting ${CIDR_COUNT} CIDRs as individual IPs (--cidr-mode=expand, --max-expand /${MAX_EXPAND})..." >&2 ;;
  netmask) echo "→ emitting ${CIDR_COUNT} CIDRs as single netmask lines (--cidr-mode=netmask; EXPERIMENTAL — verify Asustor honors netmask matching)" >&2 ;;
  auto|*)  echo "→ emitting ${CIDR_COUNT} CIDRs in auto mode (expand for /${MAX_EXPAND}+, netmask for larger)..." >&2 ;;
esac

while IFS= read -r cidr; do
  [ -z "$cidr" ] && continue
  cidr_to_lines "$cidr"
done < "$TMP_RAW" | sort -u > "$TMP_LINES"

LINE_COUNT=$(wc -l < "$TMP_LINES" | tr -d ' ')
echo "→ ${LINE_COUNT} unique defender.safe lines produced" >&2

# --- diff against existing + apply ----------------------------------------

if [ "$MODE" = "dry-run" ]; then
  if [ -r "$OUT" ]; then
    NEW=$(comm -23 "$TMP_LINES" "$(sort -u "$OUT" > /tmp/.wl-existing-$$ && echo /tmp/.wl-existing-$$)" 2>/dev/null | wc -l | tr -d ' ')
    rm -f /tmp/.wl-existing-$$
    echo "→ would add ${NEW} new entries to ${OUT} (${LINE_COUNT} candidates, $((LINE_COUNT - NEW)) already present)" >&2
  else
    echo "→ ${OUT} does not exist yet — would create with ${LINE_COUNT} entries" >&2
  fi
  echo "→ preview (first 20 lines that would land in ${OUT}):" >&2
  head -20 "$TMP_LINES"
  echo
  echo "::notice::dry-run complete. Re-run with --apply to write to ${OUT}." >&2
  exit 0
fi

# --- apply mode ------------------------------------------------------------

if [ "$(id -u)" -ne 0 ] && [ ! -w "$(dirname "$OUT")" ]; then
  echo "::error::need root/sudo to write ${OUT}" >&2
  exit 1
fi

if [ -r "$OUT" ]; then
  EXISTING="$(mktemp)"
  sort -u "$OUT" > "$EXISTING"
  NEW_FILE="$(mktemp)"
  comm -23 "$TMP_LINES" "$EXISTING" > "$NEW_FILE"
  ADD_COUNT=$(wc -l < "$NEW_FILE" | tr -d ' ')
  rm -f "$EXISTING"
  if [ "$ADD_COUNT" -eq 0 ]; then
    rm -f "$NEW_FILE"
    echo "✅ ${OUT}: already contains all ${IPCOUNT} candidates — nothing to do"
    exit 0
  fi
  BACKUP="${OUT}.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$OUT" "$BACKUP"
  echo "→ appending ${ADD_COUNT} new entries to ${OUT} (backup: ${BACKUP})..."
  cat "$NEW_FILE" >> "$OUT"
  rm -f "$NEW_FILE"
else
  echo "→ creating ${OUT} with ${IPCOUNT} entries..."
  mkdir -p "$(dirname "$OUT")"
  cp "$TMP_LINES" "$OUT"
fi

chmod 644 "$OUT" 2>/dev/null || true
echo "✅ wrote ${OUT} (total entries: $(wc -l < "$OUT" | tr -d ' '))"

# Reload ipblock daemon — best effort (script name varies across ADM versions)
echo "→ attempting ipblockd reload (best-effort)..."
{ killall -HUP ipblockd 2>/dev/null && echo "  ✅ sent SIGHUP to ipblockd"; } \
  || { /etc/init.d/ipblockd restart 2>/dev/null && echo "  ✅ restarted via /etc/init.d/ipblockd"; } \
  || { /usr/builtin/etc.init.d/ipblockd restart 2>/dev/null && echo "  ✅ restarted via /usr/builtin/etc.init.d/ipblockd"; } \
  || echo "  ⚠️  could not auto-reload — toggle Defender off+on in the ADM web UI, OR reboot, to apply"

echo
echo "Done. Verify a runner IP can now connect cleanly:"
echo "  ssh -p <port> <user>@<nas-ip>"
