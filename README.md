# upload-artifact-nas

**Version:** 1.0.0
**Last Updated:** 2026-05-25
**Status:** ACTIVE

A reusable **GitHub composite action** that uploads a CI artifact to GitHub
Actions and, **if that fails** (e.g. the org artifact-storage quota is hit),
falls back to copying the artifact to a NAS over **rclone SFTP**.

Credentials are supplied as **GitHub secrets (username/password)** — there is
**no `rclone.conf` checked into this repo**. The local `.rclone/rclone.conf`
and `.env` are the source you generate the secrets *from*; both are
`.gitignore`d.

---

## How another repo uses it

```yaml
# .github/workflows/test.yml (any repo in the org)
- uses: asd-engineering/upload-artifact-nas@v1
  with:
    name: test-report
    path: |
      coverage/
      tmp/test-report/
    mode: fallback                 # GitHub first, NAS only on failure
    nas-host: ${{ secrets.NAS_HOST }}
    nas-user: ${{ secrets.NAS_USER }}
    nas-pass: ${{ secrets.NAS_PASS }}
    nas-port: ${{ secrets.NAS_PORT }}
    nas-dest: ${{ secrets.NAS_DEST }}
```

The artifact lands on the NAS under:

```
<nas-dest>/<owner/repo>/<run_id>-<attempt>/<artifact-name>/
```

### Inputs

| Input | Default | Notes |
|-------|---------|-------|
| `name` | — (required) | Artifact name. |
| `path` | — (required) | One path per line; globs expanded. No spaces in NAS mode (v1). |
| `mode` | `fallback` | `fallback` \| `always` \| `nas-only`. |
| `retention-days` | `7` | GitHub artifact retention. |
| `if-no-files-found` | `warn` | `warn` \| `error` \| `ignore`. |
| `nas-host` / `nas-user` / `nas-pass` / `nas-port` | — / — / — / `22` | SFTP creds (from secrets). |
| `nas-dest` | `/artifacts` | Base path on the NAS. |
| `nas-conf-b64` | — | **Alternative**: base64 of a full `rclone.conf`; overrides the user/pass inputs. |
| `nas-remote` | _(auto-detected)_ | Remote name inside `nas-conf-b64`. If empty, the first remote in the conf is used. |

`rclone` is auto-downloaded (static binary, no sudo) if it isn't already on
the runner.

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
