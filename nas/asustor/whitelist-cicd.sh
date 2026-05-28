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
#                        192.168.2.0/24, public IP: 88.159.241.238).
#                        For a typical CI setup this is the only flag
#                        you need.
#   --dry-run            (default) Print proposed defender.safe lines to
#                        stdout; do NOT write.
#   --apply              Append non-duplicate lines to
#                        /usr/builtin/etc/ipblock/defender.safe. Requires
#                        root / sudo on the NAS.
#   --out PATH           Override target file (testing). Default
#                        /usr/builtin/etc/ipblock/defender.safe.
#   --max-expand N       Skip CIDRs larger than /N when expanding to
#                        individual IPs. Default 24 (i.e. expand /24 →
#                        256 IPs; skip /16 → 65536 IPs with a warning).
#                        The Asustor defender.safe format only takes
#                        individual <ip>;<netmask>;<flag> lines; netmask-
#                        based CIDR support is version-dependent (TODO).
#
# Examples:
#   # COMMON CASE — whitelist your self-hosted runner LAN + public IP
#   ./whitelist-cicd.sh --custom "192.168.2.0/24,88.159.241.238" --dry-run
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

while [ "$#" -gt 0 ]; do
  case "$1" in
    --include)    INCLUDE="$2"; shift 2 ;;
    --custom)     CUSTOM="$2"; shift 2 ;;
    --dry-run)    MODE="dry-run"; shift ;;
    --apply)      MODE="apply"; shift ;;
    --out)        OUT="$2"; shift 2 ;;
    --max-expand) MAX_EXPAND="$2"; shift 2 ;;
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

# --- CIDR expansion --------------------------------------------------------

# Convert CIDR to individual IPv4 host addresses. POSIX-shell-friendly;
# uses awk for the bit math (POSIX awk lacks bitwise ops on some
# implementations, so we provide portable bshl/and macros).
cidr_expand() {
  cidr="$1"
  case "$cidr" in
    */*)  ip="${cidr%/*}"; mask="${cidr#*/}" ;;
    *)    ip="$cidr"; mask="32" ;;
  esac
  case "$ip" in
    *:*) echo "::warning::ipv6 not supported, skipping: $cidr" >&2; return 0 ;;
  esac
  if [ "$mask" -eq 32 ]; then echo "$ip"; return 0; fi
  if [ "$mask" -lt "$MAX_EXPAND" ]; then
    SIZE=1
    HOSTBITS=$((32 - mask))
    i=0
    while [ "$i" -lt "$HOSTBITS" ]; do SIZE=$((SIZE * 2)); i=$((i+1)); done
    echo "::warning::CIDR ${cidr} is larger than /${MAX_EXPAND} (${SIZE} IPs) — skipping; widen --max-expand to include it" >&2
    return 0
  fi
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
        printf "%d.%d.%d.%d\n", int(x/16777216)%256, int(x/65536)%256, int(x/256)%256, int(x)%256
      }
    }
  '
}

# --- build the candidate set -----------------------------------------------

TMP_RAW="$(mktemp)"
TMP_IPS="$(mktemp)"
TMP_LINES="$(mktemp)"
trap 'rm -f "$TMP_RAW" "$TMP_IPS" "$TMP_LINES"' EXIT

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
echo "→ expanding ${CIDR_COUNT} CIDRs to individual IPs (--max-expand /${MAX_EXPAND})..." >&2

while IFS= read -r cidr; do
  [ -z "$cidr" ] && continue
  cidr_expand "$cidr"
done < "$TMP_RAW" | sort -u > "$TMP_IPS"

IPCOUNT=$(wc -l < "$TMP_IPS" | tr -d ' ')
echo "→ ${IPCOUNT} unique IPs to consider" >&2

awk '{print $1 ";0.0.0.0;0"}' "$TMP_IPS" > "$TMP_LINES"

# --- diff against existing + apply ----------------------------------------

if [ "$MODE" = "dry-run" ]; then
  if [ -r "$OUT" ]; then
    NEW=$(comm -23 "$TMP_LINES" "$(sort -u "$OUT" > /tmp/.wl-existing-$$ && echo /tmp/.wl-existing-$$)" 2>/dev/null | wc -l | tr -d ' ')
    rm -f /tmp/.wl-existing-$$
    echo "→ would add ${NEW} new entries to ${OUT} (${IPCOUNT} candidates, $((IPCOUNT - NEW)) already present)" >&2
  else
    echo "→ ${OUT} does not exist yet — would create with ${IPCOUNT} entries" >&2
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
