#!/usr/bin/env bash
# Codex provider auth sync.

provider_sync_credentials() {
  local ssh_dest="$1"
  local local_auth="${CODEX_AUTH_FILE:-~/.codex/auth.json}"
  local remote_auth="${CODEX_REMOTE_AUTH_FILE:-~/.codex/auth.json}"

  provider_sync_file "$ssh_dest" "$local_auth" "$remote_auth" "Codex"
  log "Synced Codex credentials to $ssh_dest"
}
