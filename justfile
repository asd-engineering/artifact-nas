# file: justfile
# All site-specific values come from .env (copy it from tpl.env). Nothing in
# this file is environment-specific, so the repo is safe to publish.
set dotenv-load := true

nas_host      := env_var_or_default("NAS_HOST", "")
nas_user      := env_var_or_default("NAS_USER", "")
nas_port      := env_var_or_default("NAS_PORT", "22")
nas_remote    := env_var_or_default("NAS_REMOTE", "artifacts-nas")
nas_path      := env_var_or_default("NAS_DEST", "/artifacts")
gh_org        := env_var_or_default("GH_ORG", "")
rclone_config := env_var_or_default("RCLONE_CONFIG_FILE", ".rclone/rclone.conf")
rclone_cli    := "bun rclone.ts"

# Push NAS credentials to GitHub org secrets (password prompted, hidden, never in history).
rclone-nas-secrets:
    gh secret set NAS_HOST --org {{gh_org}} --visibility all --body "{{nas_host}}"
    gh secret set NAS_USER --org {{gh_org}} --visibility all --body "{{nas_user}}"
    gh secret set NAS_PORT --org {{gh_org}} --visibility all --body "{{nas_port}}"
    gh secret set NAS_DEST --org {{gh_org}} --visibility all --body "{{nas_path}}"
    @bash -c 'read -rsp "SFTP password for {{nas_user}}: " p; printf %s "$p" | gh secret set NAS_PASS --org {{gh_org}} --visibility all; echo; echo "NAS_PASS set"'

# Alternative: push the whole rclone.conf as one base64 secret (RCLONE_CONF_B64).
rclone-nas-secret-conf:
    base64 -w0 {{rclone_config}} | gh secret set RCLONE_CONF_B64 --org {{gh_org}} --visibility all
    @echo "RCLONE_CONF_B64 set (remote: {{nas_remote}})"

# Show resolved NAS artifact settings.
rclone-nas-info:
    @{{rclone_cli}} info \
      --host "{{nas_host}}" \
      --user "{{nas_user}}" \
      --port "{{nas_port}}" \
      --remote "{{nas_remote}}" \
      --path "{{nas_path}}" \
      --config "{{rclone_config}}"

# Configure rclone SFTP password auth for the NAS artifact remote.
rclone-nas-config:
    @{{rclone_cli}} config \
      --host "{{nas_host}}" \
      --user "{{nas_user}}" \
      --port "{{nas_port}}" \
      --remote "{{nas_remote}}" \
      --path "{{nas_path}}" \
      --config "{{rclone_config}}" \
      --auth password \
      --mode merge

# Configure rclone SFTP key auth for the NAS artifact remote.
rclone-nas-config-key key_file:
    @{{rclone_cli}} config \
      --host "{{nas_host}}" \
      --user "{{nas_user}}" \
      --port "{{nas_port}}" \
      --remote "{{nas_remote}}" \
      --path "{{nas_path}}" \
      --config "{{rclone_config}}" \
      --auth key \
      --key-file "{{key_file}}" \
      --mode merge

# Check TCP connectivity to the configured NAS SFTP port.
rclone-nas-port-check:
    @{{rclone_cli}} port-check \
      --host "{{nas_host}}" \
      --port "{{nas_port}}"

# List directories on the configured NAS path.
rclone-nas-dirs path="/":
    @{{rclone_cli}} dirs \
      --remote "{{nas_remote}}" \
      --config "{{rclone_config}}" \
      --path "{{path}}"

# Debug directory listing with verbose rclone logs and short retries.
rclone-nas-debug path="/":
    @{{rclone_cli}} debug \
      --remote "{{nas_remote}}" \
      --config "{{rclone_config}}" \
      --path "{{path}}"

# Upload and verify a small artifact file.
rclone-nas-test:
    @{{rclone_cli}} test \
      --remote "{{nas_remote}}" \
      --config "{{rclone_config}}" \
      --path "{{nas_path}}"
