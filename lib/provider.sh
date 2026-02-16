#!/usr/bin/env bash
# Provider loader — sources auth sync behavior for the active agent type.
# Providers implement HOW credentials are synced to remote runners.

source "$SCRIPT_DIR/providers/base.sh"

provider_file="$SCRIPT_DIR/providers/${AGENT_TYPE}.sh"
if [ -f "$provider_file" ]; then
  source "$provider_file"
fi

if ! declare -f provider_sync_credentials >/dev/null; then
  provider_sync_credentials() {
    return 0
  }
fi

unset provider_file
