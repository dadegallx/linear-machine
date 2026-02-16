#!/usr/bin/env bash
# Claude Code provider auth sync.

provider_sync_credentials() {
  local ssh_dest="$1"
  local local_auth="${CLAUDE_AUTH_FILE:-~/.claude/.credentials.json}"
  local remote_auth="${CLAUDE_REMOTE_AUTH_FILE:-~/.claude/.credentials.json}"

  provider_sync_file "$ssh_dest" "$local_auth" "$remote_auth" "Claude Code"
  log "Synced Claude Code credentials to $ssh_dest"
}
