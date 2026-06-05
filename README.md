# artifact-nas

**Version:** 1.4.7
**Last Updated:** 2026-05-31
**Status:** ACTIVE

Two reusable **GitHub composite actions** — `upload` and `download` — that move
CI artifacts through GitHub Actions and, **if GitHub can't (e.g. the artifact-
storage quota is hit), fall back to a NAS over rclone SFTP**. Use them as a
matched pair so an artifact stored on the NAS at upload time is still found at
download time.

| Flavour | `uses:` | Mirrors |
|---------|---------|---------|
| upload   | `asd-engineering/artifact-nas/upload@v1`   | `actions/upload-artifact` |
| download | `asd-engineering/artifact-nas/download@v1` | `actions/download-artifact` |

> **Repo rename:** if this repo is renamed from `upload-artifact-nas` to
> `artifact-nas`, GitHub redirects the old path, so existing
> `upload-artifact-nas/upload@v1` references keep resolving.

Credentials are supplied as **GitHub secrets** (username/password *or* a base64
`rclone.conf`) — there is **no `rclone.conf` checked into this repo**. The local
`.rclone/rclone.conf` and `.env` are the source you generate the secrets *from*;
both are `.gitignore`d.

---

## How another repo uses it

```yaml
# upload (job that produces the artifact)
- uses: asd-engineering/artifact-nas/upload@v1
  with:
    name: release-asd-linux-x64
    path: dist/asd-linux-x64.tar.gz
    mode: fallback                 # GitHub first, NAS only on failure
    nas-conf-b64: ${{ secrets.RCLONE_CONF_B64 }}
    nas-dest: ${{ secrets.NAS_DEST }}

# download (a later job in the SAME run that consumes it)
- uses: asd-engineering/artifact-nas/download@v1
  with:
    name: release-asd-linux-x64
    path: dist/
    mode: fallback                 # GitHub first, NAS only if missing
    nas-conf-b64: ${{ secrets.RCLONE_CONF_B64 }}
    nas-dest: ${{ secrets.NAS_DEST }}
```

Set the creds once at job/workflow `env:` level (`RCLONE_CONF_B64` + `NAS_DEST`)
and you can drop the `nas-*` inputs entirely — both actions read them via env
fallback. The artifact lands on / is read from the NAS under:

```
<nas-dest>/<owner/repo>/<run_id>-<attempt>/<artifact-name>/
```

Because the path keys on `run_id`-`run_attempt`, download resolves the same
location upload wrote **within the same workflow run** (the intra-run handoff
that `actions/download-artifact` does via GitHub storage).

### Inputs

| Input | Default | Notes |
|-------|---------|-------|
| `name` | — (required) | Artifact name. |
| `path` | — (required) | One path per line; globs expanded. No spaces in NAS mode (v1). |
| `mode` | `fallback` | `fallback` \| `always` \| `nas-only` \| `nas-first` (v1.2.0+). |
| `retention-days` | `7` | GitHub artifact retention. |
| `if-no-files-found` | `warn` | `warn` \| `error` \| `ignore`. |
| `nas-host` / `nas-user` / `nas-pass` / `nas-port` | — / — / — / `22` | SFTP creds (from secrets). |
| `nas-dest` | `/artifacts` | Base path on the NAS. |
| `nas-conf-b64` | — | **Alternative**: base64 of a full `rclone.conf`; overrides the user/pass inputs. |
| `nas-remote` | _(auto-detected)_ | Remote name inside `nas-conf-b64`. If empty, the first remote in the conf is used. |

`rclone` is auto-downloaded (static binary, no sudo) if it isn't already on
the runner.

### Modes

| Mode | Behaviour | When to use |
|------|-----------|-------------|
| `fallback` (default) | GitHub first, NAS only if GitHub upload fails. | Most cases — let GitHub do the work, use NAS as a safety net when quota hits. |
| `always` | GitHub AND NAS, both every time. | Mirror critical artifacts to a self-hosted copy. |
| `nas-only` | Skip GitHub entirely. | NAS is the canonical store, GitHub quota is precious. |
| `nas-first` (v1.2.0) | NAS first; if NAS fails, fall back to GitHub. | NAS is preferred (faster on self-hosted runners, doesn't burn quota) but GitHub is the safety net when the NAS is having an off-day. |
| `cache` (v1.3.0) | NAS-only at a stable cross-run path (`<nas-dest>/cache/<name>/` — no `<owner/repo>/<run_id>` per-run scoping). Download tolerates cache miss (exits 0). | Cross-run cache of helper binaries / build outputs / anything else you'd give to `actions/cache` but want on a self-hosted NAS instead. Pair with the same `mode: cache` on both upload + download. Encode any "what version" key into the artifact name (e.g. `helpers-linux-<hashFiles>`). |

### Cache mode (v1.3.0)

```yaml
# Restore (cache miss exits 0)
- uses: asd-engineering/artifact-nas/download@v1.3.0
  with:
    mode: cache
    name: helpers-linux-${{ hashFiles('modules/caddy/tpl.env', 'modules/ttyd/tpl.env') }}
    path: ~/.cache/asd-helpers

- name: Warm helpers if cache missed
  run: ./scripts/warm-helpers.sh  # idempotent — re-runs the build only if cache was empty

# Save (always overwrites the keyed path)
- uses: asd-engineering/artifact-nas/upload@v1.3.0
  with:
    mode: cache
    name: helpers-linux-${{ hashFiles('modules/caddy/tpl.env', 'modules/ttyd/tpl.env') }}
    path: ~/.cache/asd-helpers
```

Use cache mode instead of writing a custom rclone wrapper script (e.g. the previously-needed `scripts/ci/nas-cache.sh` pattern). The action's `rclone_retry` from v1.2.0 covers SFTP-init flakes on cache mode too.

### SFTP hardening (v1.2.0+)

Default `rclone` flags include `--sftp-concurrency 1`, `--sftp-disable-concurrent-reads`, `--timeout 30s`, `--contimeout 10s`. Combined with the new `rclone_retry()` wrapper, the action survives transient `NewFs: ... unexpected EOF` failures from appliance NAS units (Asustor / Synology / QNAP) whose `sshd` has a low `MaxStartups` cap. Retry uses exponential backoff (1s, 3s, 7s, 15s, 31s; ~57 s budget across 5 attempts) and only triggers on init-layer error signatures — real errors (auth failure, permission denied) fail immediately.

### Wall-clock guard + NAS retry window (v1.5.0)

`--contimeout` bounds only the **TCP dial** and `--timeout` is an **idle-IO** timer on an *established* data connection — **neither covers the SSH handshake / SFTP-subsystem open** (`NewFs`). A NAS whose `sshd` accepts the TCP connection but then stalls mid-handshake (e.g. `MaxStartups` queue, or a half-open connection after a `fail2ban` race) wedges a **single** `rclone` invocation **forever**: no output, no error, so `rclone_retry` never fires and the `nas-first → GitHub` fallback never triggers (both key off a non-zero *exit*, which a hang never produces). In v1.4.8 this hung one upload for **61 minutes** until the job hit its 90-minute cap and GitHub cancelled it (`The operation was canceled.`).

**Policy:** the NAS is the preferred sink, and a *refusing or stalling* NAS is **not** "dead" — v1.5.0 **retries it, hard, for a bounded window** to get the artifact onto the NAS. GitHub (or a cache miss) is the **last resort**, used only once that window is genuinely spent — i.e. the NAS is unreachable *for this run*.

How it works:

- **Every `rclone` runs under an OS wall-clock killer** (`timeout`, or `gtimeout` on macOS+coreutils; unguarded with a warning if neither is present). A wedge becomes exit `124`/`137` and **re-enters the retry loop** instead of blocking.
- **Per-subcommand deadline.** List/`mkdir`/probe ops (where the handshake hang surfaces) get a **short** deadline so a wedge is caught and retried fast; `copy`/`sync` ops get a **long** deadline so a legitimately slow transfer over the throttled link isn't killed.
- **A `mkdir` liveness probe runs before the upload copy** — it exercises connect+auth+session in one cheap call, so the retry window is spent probing the NAS rather than blocking on one big copy.
- **`connection refused` is now *retried*, not instantly failed over** (it usually means a transient `fail2ban` ban or `sshd` not-yet-ready, i.e. *alive but refusing*). Backoff is spaced (5→60s) so the retries don't hammer `fail2ban` into *sustaining* the ban. If the ban outlasts the window, we fall over — the accepted "NAS dead-for-this-run" outcome.
- **Auth / permission errors fail fast** (no retry) — they never self-heal, so they don't burn the window.

| Env var | Default | Meaning |
|---|---|---|
| `RCLONE_PROBE_TIMEOUT` | `45s` | Wall-clock limit for a single list/`mkdir`/probe op. |
| `RCLONE_OP_TIMEOUT` | `600s` | Wall-clock limit for a single `copy`/`sync` op. |
| `RCLONE_MAX_TOTAL` | `300` | NAS retry window (seconds): how long we keep retrying the NAS before declaring it dead-for-this-run and falling over. |

> **Note:** the window can't exceed the GitHub job clock — set it relative to your job's `timeout-minutes`. The 300s default suits short transient stalls and `MaxStartups` bursts; raise it if you want to wait out a full `fail2ban` ban (whose `findtime` is typically ~10 min) instead of falling over.

### Reliability hardening (v1.4.5 – v1.4.7)

Battle-tested against a real Asustor `sftpmand` (OpenSSH `internal-sftp`) under
a full cross-OS release matrix. These fixes turn "the NAS had a bad moment" from
a hard red into a self-healing or trivially-recoverable event:

| Version | Fix | Why |
|---|---|---|
| **v1.4.5** | **Fail fast on `connection refused`** — `rclone_retry` no longer burns its 5-attempt budget when the error is `connection refused` (host down / IP firewall-banned). It fails over to the GitHub leg / cache-miss on the *first* refusal. | Retrying a hard block just hammers the appliance and (with `ipblock`/`fail2ban`) **sustains the ban** — CI was re-banning itself. Distinct from the transient `NewFs: unexpected EOF` init races, which still get the full backoff. |
| **v1.4.5** | **Single-target download no longer gated on `lsf`** — a `path: dist/`-style restore attempts the direct `rclone copy SRC_DIR target` unconditionally and judges success by actual file count, instead of skipping when a pre-flight `lsf` returned empty. | `lsf` is wrapped in `2>/dev/null \|\| true`, so *any* listing error read as "empty" and aborted the download with "produced no files" — even with the file on disk. |
| **v1.4.6** | **Retry a single-target copy that gains zero files** (4×, 2/4/8 s) when the source should be populated; `cache` mode breaks on the first zero-gain (a genuine miss must not retry-storm). | `rclone copy` returns exit 0 even when the server's `readdir` momentarily returned an empty listing — so `rclone_retry` (which only watches for connection/init errors) never fired, and one bad listing was a hard failure. |
| **v1.4.7** | **Per-run path keyed on `GITHUB_RUN_ID` only** — `<dest>/<owner/repo>/<run_id>/<name>/` (previously `<run_id>-<run_attempt>/`). | A **`--failed` re-run** bumps `GITHUB_RUN_ATTEMPT` for the re-run jobs but **not** for the already-succeeded *producer* (build) job, so an attempt-scoped path sent the consumer to `<run>-2/` while the artifact sat at `<run>-1/` → `directory not found`, and **re-running failed jobs could never recover**. `RUN_ID` is stable across attempts; a re-run reads the original upload. Same-run re-uploads overwrite idempotently; distinct runs have distinct `RUN_ID`s (no cross-run clobber). |

#### Known limitation: intermittent `readdir`-empty under heavy concurrent load

On a busy appliance (full release matrix uploading + several e2e jobs reading
across different runners simultaneously) the SFTP server can occasionally return
an **empty directory listing for a populated directory** without erroring —
`rclone copy` then "succeeds" having transferred nothing. In isolation the NAS
is reliable (a sequential and a 6-way-concurrent probe were both 0-failure); the
window is rare and load-dependent, and we could not reproduce it in a harness.

The action absorbs most of these via the v1.4.6 zero-gain retry. For the rare
case that survives the in-step retries, the v1.4.7 `RUN_ID`-only path makes the
recovery trivial: **just re-run the failed job(s)** (`gh run rerun <id> --failed`)
— the artifact is still at the same `<run_id>/<name>/` path the producer wrote,
so the re-run reads it cleanly. If your appliance hits this often, prefer
GitHub-primary modes (`fallback`/`always`) for release-critical artifacts and
keep the NAS for caches, where a flaky read is a non-fatal cache miss.

**Env fallback (DRY):** every `nas-*` input also reads from an ambient env var
when the input is omitted — `nas-conf-b64`←`RCLONE_CONF_B64`,
`nas-dest`←`NAS_DEST`, `nas-host`←`NAS_HOST`, `nas-user`←`NAS_USER`,
`nas-pass`←`NAS_PASS`, `nas-port`←`NAS_PORT`. Set them once at job/workflow
level and each step is a one-line `uses:` with just `name`/`path`:

```yaml
jobs:
  build:
    env:
      RCLONE_CONF_B64: ${{ secrets.RCLONE_CONF_B64 }}
      NAS_DEST: ${{ secrets.NAS_DEST }}
    steps:
      - uses: asd-engineering/upload-artifact-nas@v1
        with: { name: my-archive, path: dist/my-archive.tar.gz }
```

---

## One-time setup: push the credentials to GitHub

Site-specific values live in `.env` (copy it from [`tpl.env`](./tpl.env) and
fill in your NAS host/user/port/dest + org). Nothing site-specific is committed.

```bash
cp tpl.env .env && $EDITOR .env     # fill in your NAS + GH_ORG
just rclone-nas-secrets             # host/user/port/dest + hidden password prompt
```

That recipe reads `.env` and runs, in effect:

```bash
gh secret set NAS_HOST --org "$GH_ORG" --visibility all --body "$NAS_HOST"
gh secret set NAS_USER --org "$GH_ORG" --visibility all --body "$NAS_USER"
gh secret set NAS_PORT --org "$GH_ORG" --visibility all --body "$NAS_PORT"
gh secret set NAS_DEST --org "$GH_ORG" --visibility all --body "$NAS_DEST"
# password read hidden, piped (never in shell history):
read -rsp 'SFTP password: ' p && printf %s "$p" | gh secret set NAS_PASS --org "$GH_ORG" --visibility all
```

> **Chroot note:** many NAS SFTP accounts are jailed to their shares, so a bare
> `/artifacts` won't exist — set `NAS_DEST` under an existing share (e.g.
> `/Home/ci-artifacts`).
>
> `NAS_HOST/USER/PORT/DEST` aren't really secret — you may keep them as org
> **variables** (`gh variable set …`, referenced via `${{ vars.X }}`) and only
> `NAS_PASS` as a secret. The action doesn't care which; the caller wires them.

### Alternative: ship the whole rclone.conf as one secret

If you'd rather reuse your existing `rclone.conf` verbatim:

```bash
just rclone-nas-secret-conf      # base64 .rclone/rclone.conf -> RCLONE_CONF_B64
```

then pass `nas-conf-b64: ${{ secrets.RCLONE_CONF_B64 }}` instead of the
user/pass inputs (the remote name is auto-detected from the conf).

---

## Local development & testing

The `rclone.ts` CLI (run with `bun`) + `justfile` build and verify the NAS
remote locally before you trust it in CI:

```bash
just rclone-nas-info          # show resolved settings
just rclone-nas-port-check    # TCP reachability to the SFTP port
just rclone-nas-config        # write .rclone/rclone.conf (password auth, obscured)
just rclone-nas-dirs /        # list the NAS path
just rclone-nas-test          # upload + checksum-verify a probe file
```

`.rclone/rclone.conf` holds the rclone-obscured password (reversible
obfuscation, **not** encryption) — that's why it's git-ignored and only ever
leaves this machine as a GitHub secret.

---

## Security notes

- No plaintext or obscured password is ever committed; secrets live only in
  GitHub's encrypted store.
- The runtime obscured password is `::add-mask::`ed so it can't leak into logs.
- In `nas-conf-b64` mode the decoded config is written to a `mktemp` file with
  `chmod 600` and removed on step exit (`trap … EXIT`).
- The NAS host is a public SFTP endpoint — keep `NAS_HOST` a secret too if you
  don't want the IP/port in workflow logs.
