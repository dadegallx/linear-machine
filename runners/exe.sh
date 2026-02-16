#!/usr/bin/env bash
# exe.dev runner — agents run on managed VMs via exe.dev.
# Each issue gets its own VM. VMs persist between start/resume (same repo + session).
# Destroyed on runner_stop, runner_stop_all, or machine.sh stop.

EXE_REPOS_DIR="${EXE_REPOS_DIR:-~/repos}"
EXE_SSH_TIMEOUT="${EXE_SSH_TIMEOUT:-10}"

_exe_ssh() {
  ssh -o ConnectTimeout="$EXE_SSH_TIMEOUT" -o StrictHostKeyChecking=accept-new "$@"
}

_exe_scp() {
  scp -o ConnectTimeout="$EXE_SSH_TIMEOUT" "$@"
}

_exe_slug() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

_exe_managed_vm_name() {
  local id="$1" state_dir="$2"
  local repo repo_slug id_slug name
  repo=$(basename "$(cat "$state_dir/workdir" 2>/dev/null || echo linear)")
  repo_slug=$(_exe_slug "$repo")
  id_slug=$(_exe_slug "$id")
  name="${repo_slug:-linear}-${id_slug:-issue}"
  echo "${name:0:56}"
}

_exe_each_managed_issue() {
  local state_dir id
  for state_dir in "$STATE_DIR"/*/; do
    [ -d "$state_dir" ] || continue
    [ -f "$state_dir/vm_name" ] || continue
    id=$(basename "$state_dir")
    echo "$id"
  done
}

_exe_expand_remote_path() {
  local remote_home="$1" path="$2"
  case "$path" in
    "~")
      echo "$remote_home"
      ;;
    "~/"*)
      echo "$remote_home/${path#\~/}"
      ;;
    *)
      echo "$path"
      ;;
  esac
}

_exe_write_remote_runner_script() {
  local state_dir="$1" ssh_dest="$2" remote_state_dir="$3" cmd="$4"
  local local_script="$state_dir/runner_cmd.sh"

  cat > "$local_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
$cmd
EOF
  chmod +x "$local_script"
  _exe_scp "$local_script" "$ssh_dest:$remote_state_dir/runner_cmd.sh"
  _exe_ssh "$ssh_dest" "chmod +x $remote_state_dir/runner_cmd.sh"
}

# ---------------------------------------------------------------------------
# Background watcher: polls remote tmux, syncs results when done
# ---------------------------------------------------------------------------
_exe_spawn_watcher() {
  local id="$1" state_dir="$2" ssh_dest="$3" remote_state_dir="$4"
  (
    while sleep 15; do
      if ! _exe_ssh "$ssh_dest" tmux has-session -t "linear-$id" 2>/dev/null; then
        # Agent finished — sync results back
        log "VM session ended for $id ($ssh_dest), syncing results"
        for f in output session raw.json raw.jsonl all_messages agent.err exit_code; do
          _exe_scp "$ssh_dest:$remote_state_dir/$f" "$state_dir/$f" 2>/dev/null || true
        done
        break
      fi
    done
  ) &
}

# ---------------------------------------------------------------------------
# runner_start ID STATE_DIR ENV_DIR AGENT_TYPE ACTION
# ---------------------------------------------------------------------------
runner_start() {
  local id="$1" state_dir="$2" env_dir="$3" agent_type="$4" action="$5"
  local remote_workdir_base="$EXE_REPOS_DIR/$(basename "$(cat "$state_dir/workdir")")"
  local remote_home remote_workdir remote_state_dir remote_adapters_dir remote_bin_dir remote_lib_dir

  if [ "$action" = "start" ]; then
    # Spin up a new VM
    local vm_json vm_json_fallback vm_info vm_name ssh_dest requested_name
    requested_name=$(_exe_managed_vm_name "$id" "$state_dir")
    vm_json=$(_exe_ssh exe.dev new --json --name "$requested_name" 2>/dev/null || true)
    vm_json_fallback=""
    vm_info=$(printf '%s\n' "$vm_json" | jq -rs '
      map(select(type == "object" and (.vm_name? | type == "string") and (.ssh_dest? | type == "string")))
      | .[0] // empty
    ' 2>/dev/null || true)
    if [ -z "$vm_info" ]; then
      vm_json_fallback=$(_exe_ssh exe.dev new --json 2>/dev/null || true)
      vm_info=$(printf '%s\n' "$vm_json_fallback" | jq -rs '
        map(select(type == "object" and (.vm_name? | type == "string") and (.ssh_dest? | type == "string")))
        | .[0] // empty
      ' 2>/dev/null || true)
    fi
    if [ -z "$vm_info" ]; then
      local err_msg
      err_msg=$(printf '%s\n%s\n' "$vm_json" "$vm_json_fallback" | jq -rs '
        map(select(type == "object") | .error // empty)
        | map(select(length > 0))
        | .[0] // "unknown exe VM provisioning error"
      ' 2>/dev/null || echo "unknown exe VM provisioning error")
      log "VM provision failed for $id: $err_msg"
      return 1
    fi
    vm_name=$(echo "$vm_info" | jq -r '.vm_name')
    ssh_dest=$(echo "$vm_info" | jq -r '.ssh_dest')
    if [ -z "$vm_name" ] || [ "$vm_name" = "null" ] || [ -z "$ssh_dest" ] || [ "$ssh_dest" = "null" ]; then
      log "VM provision failed for $id: invalid exe response"
      return 1
    fi

    log "VM provisioned for $id: $vm_name ($ssh_dest)"
    remote_home=$(_exe_ssh "$ssh_dest" 'printf %s "$HOME"')
    remote_workdir=$(_exe_expand_remote_path "$remote_home" "$remote_workdir_base")
    remote_state_dir="$remote_home/state/$id"
    remote_adapters_dir="$remote_home/adapters"
    remote_bin_dir="$remote_home/bin"
    remote_lib_dir="$remote_home/lib"

    # Save VM identity
    echo "$vm_name" > "$state_dir/vm_name"
    echo "$ssh_dest" > "$state_dir/ssh_dest"

    # Ensure remote repo exists when repo_url is configured.
    # Keep this idempotent so restarts don't crash on existing directories.
    if [ -n "$env_dir" ] && [ -f "$env_dir/repo_url" ]; then
      local repo_url remote_parent
      repo_url=$(tr -d '[:space:]' < "$env_dir/repo_url")
      remote_parent="${remote_workdir%/*}"
      if [ -n "$repo_url" ]; then
        _exe_ssh "$ssh_dest" "mkdir -p $remote_parent"
        if ! _exe_ssh "$ssh_dest" "[ -d $remote_workdir/.git ] || git clone $repo_url $remote_workdir"; then
          log "Repo clone failed for $id ($repo_url). Continuing without clone."
          _exe_ssh "$ssh_dest" "mkdir -p $remote_workdir"
        fi
      fi
    else
      _exe_ssh "$ssh_dest" "mkdir -p $remote_workdir"
    fi

    # Create remote structure
    _exe_ssh "$ssh_dest" "mkdir -p $remote_state_dir/env $remote_adapters_dir $remote_bin_dir $remote_lib_dir"

    # Sync tooling
    _exe_scp "$SCRIPT_DIR/adapters/${agent_type}.sh" "$ssh_dest:$remote_adapters_dir/"
    _exe_scp "$SCRIPT_DIR/bin/linear-tool" "$ssh_dest:$remote_bin_dir/"
    _exe_scp "$SCRIPT_DIR/lib/linear.sh" "$ssh_dest:$remote_lib_dir/"

    # Sync state files + write remote workdir
    echo "$remote_workdir" > "$state_dir/remote_workdir"
    for f in prompt issue_uuid title team_id env.sh; do
      [ -f "$state_dir/$f" ] && _exe_scp "$state_dir/$f" "$ssh_dest:$remote_state_dir/" 2>/dev/null || true
    done
    _exe_ssh "$ssh_dest" "sed -i 's|^export LINEAR_STATE_DIR=.*|export LINEAR_STATE_DIR=$remote_state_dir|' $remote_state_dir/env.sh" 2>/dev/null || true
    _exe_ssh "$ssh_dest" "echo $remote_workdir > $remote_state_dir/workdir"

    # Sync env dir files
    if [ -n "$env_dir" ]; then
      [ -f "$env_dir/env.sh" ] && _exe_scp "$env_dir/env.sh" "$ssh_dest:$remote_state_dir/env/"
      [ -x "$env_dir/setup.sh" ] && _exe_scp "$env_dir/setup.sh" "$ssh_dest:$remote_state_dir/env/"
    fi

    # Sync provider credentials (Codex/Claude/etc.) before starting agent.
    provider_sync_credentials "$ssh_dest"

    # Build remote command chain
    local cmd="export PATH=$remote_bin_dir:\$PATH && source $remote_state_dir/env.sh"
    [ -n "$env_dir" ] && [ -f "$env_dir/env.sh" ] && cmd="$cmd && source $remote_state_dir/env/env.sh || true"
    [ -n "$env_dir" ] && [ -x "$env_dir/setup.sh" ] && cmd="$cmd && $remote_state_dir/env/setup.sh"
    cmd="$cmd && $remote_adapters_dir/${agent_type}.sh start $remote_state_dir $remote_workdir"

    _exe_write_remote_runner_script "$state_dir" "$ssh_dest" "$remote_state_dir" "$cmd"
    _exe_ssh "$ssh_dest" "tmux new-session -d -s linear-$id $remote_state_dir/runner_cmd.sh"
    _exe_spawn_watcher "$id" "$state_dir" "$ssh_dest" "$remote_state_dir"

  else
    # Resume — reuse existing VM
    local ssh_dest
    ssh_dest=$(cat "$state_dir/ssh_dest") || {
      echo "No ssh_dest for $id — cannot resume" >&2
      return 1
    }
    remote_home=$(_exe_ssh "$ssh_dest" 'printf %s "$HOME"')
    remote_workdir=$(_exe_expand_remote_path "$remote_home" "$remote_workdir_base")
    remote_state_dir="$remote_home/state/$id"
    remote_adapters_dir="$remote_home/adapters"
    remote_bin_dir="$remote_home/bin"
    remote_lib_dir="$remote_home/lib"

    # Sync updated state
    _exe_scp "$state_dir/prompt" "$ssh_dest:$remote_state_dir/"
    [ -f "$state_dir/env.sh" ] && _exe_scp "$state_dir/env.sh" "$ssh_dest:$remote_state_dir/" 2>/dev/null || true
    _exe_scp "$SCRIPT_DIR/lib/linear.sh" "$ssh_dest:$remote_lib_dir/" 2>/dev/null || true
    _exe_ssh "$ssh_dest" "sed -i 's|^export LINEAR_STATE_DIR=.*|export LINEAR_STATE_DIR=$remote_state_dir|' $remote_state_dir/env.sh" 2>/dev/null || true

    # Clear previous exit markers
    _exe_ssh "$ssh_dest" "rm -f $remote_state_dir/exit_code $remote_state_dir/agent_state"

    # Refresh provider credentials before resuming agent session.
    provider_sync_credentials "$ssh_dest"

    # Build remote command (no setup.sh on resume)
    local cmd="export PATH=$remote_bin_dir:\$PATH && source $remote_state_dir/env.sh"
    [ -n "$env_dir" ] && [ -f "$env_dir/env.sh" ] && cmd="$cmd && source $remote_state_dir/env/env.sh || true"
    cmd="$cmd && $remote_adapters_dir/${agent_type}.sh resume $remote_state_dir"

    _exe_write_remote_runner_script "$state_dir" "$ssh_dest" "$remote_state_dir" "$cmd"
    _exe_ssh "$ssh_dest" "tmux new-session -d -s linear-$id $remote_state_dir/runner_cmd.sh"
    _exe_spawn_watcher "$id" "$state_dir" "$ssh_dest" "$remote_state_dir"
  fi
}

# ---------------------------------------------------------------------------
# runner_is_running ID
# ---------------------------------------------------------------------------
runner_is_running() {
  local ssh_dest
  ssh_dest=$(cat "$STATE_DIR/$1/ssh_dest" 2>/dev/null) || return 1
  _exe_ssh "$ssh_dest" tmux has-session -t "linear-$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# runner_stop ID
# ---------------------------------------------------------------------------
runner_stop() {
  local vm_name ssh_dest
  vm_name=$(cat "$STATE_DIR/$1/vm_name" 2>/dev/null) || return 0
  ssh_dest=$(cat "$STATE_DIR/$1/ssh_dest" 2>/dev/null) || true

  [ -n "$ssh_dest" ] && _exe_ssh "$ssh_dest" tmux kill-session -t "linear-$1" 2>/dev/null || true
  if [ -n "$vm_name" ]; then
    _exe_ssh exe.dev rm "$vm_name" 2>/dev/null || true
    log "VM destroyed for $1: $vm_name"
  fi
  rm -f "$STATE_DIR/$1/vm_name" "$STATE_DIR/$1/ssh_dest"
}

# ---------------------------------------------------------------------------
# runner_stop_all
# ---------------------------------------------------------------------------
runner_stop_all() {
  local id
  while read -r id; do
    [ -n "$id" ] || continue
    runner_stop "$id"
  done < <(_exe_each_managed_issue)
}

# ---------------------------------------------------------------------------
# runner_list
# ---------------------------------------------------------------------------
runner_list() {
  local vms_json id vm status
  vms_json=$(_exe_ssh exe.dev ls --json 2>/dev/null || true)
  while read -r id; do
    [ -n "$id" ] || continue
    vm=$(cat "$STATE_DIR/$id/vm_name" 2>/dev/null || true)
    [ -n "$vm" ] || continue
    status=$(echo "$vms_json" | jq -r --arg vm "$vm" '[.vms[] | select(.vm_name == $vm) | .status][0] // "stopped"' 2>/dev/null || echo "unknown")
    echo "$id: $vm ($status)"
  done < <(_exe_each_managed_issue)
}
