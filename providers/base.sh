#!/usr/bin/env bash
# Base provider helpers for remote credential sync.

provider_expand_home() {
  case "$1" in
    "~")
      echo "$HOME"
      ;;
    "~/"*)
      echo "$HOME/${1#~/}"
      ;;
    *)
      echo "$1"
      ;;
  esac
}

provider_sync_file() {
  local ssh_dest="$1" local_path="$2" remote_path="$3" label="$4"
  local local_abs remote_home remote_abs remote_escaped_dir remote_escaped_path

  local_abs=$(provider_expand_home "$local_path")
  if [ ! -f "$local_abs" ]; then
    echo "Missing ${label} auth file: $local_abs" >&2
    return 1
  fi

  remote_home=$(_exe_ssh "$ssh_dest" 'printf %s "$HOME"')
  case "$remote_path" in
    "~/"*)
      remote_abs="$remote_home/${remote_path#~/}"
      ;;
    *)
      remote_abs="$remote_path"
      ;;
  esac

  remote_escaped_dir=$(printf "%q" "$(dirname "$remote_abs")")
  remote_escaped_path=$(printf "%q" "$remote_abs")

  _exe_ssh "$ssh_dest" "mkdir -p $remote_escaped_dir"
  _exe_scp "$local_abs" "$ssh_dest:$remote_abs"
  _exe_ssh "$ssh_dest" "chmod 600 $remote_escaped_path" 2>/dev/null || true
}
