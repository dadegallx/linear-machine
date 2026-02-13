# Code Simplification Memory: linear-machine

## Project Overview
- Pure bash project: Linear API polling → agent dispatch → result posting
- No build/test/lint infrastructure
- State managed via filesystem (`/tmp/linear-agent/`)
- tmux sessions as lock mechanism

## Common Patterns Found

### Bash Quoting Issues
- **${var@Q} double-wrapping**: Found tmux commands wrapping `${var@Q}` in double quotes
  - WRONG: `tmux new-session -d -s "$session" "bash -c ${tmux_cmd@Q}"`
  - RIGHT: `tmux new-session -d -s "$session" bash -c ${tmux_cmd@Q}`
  - The `@Q` operator already produces shell-quoted output; outer quotes break it

### Config File Reading
- Pattern: `grep "^KEY=" file | cut -d= -f2`
- Extracted to `read_config_var()` helper (used 8+ times)
- Alternative considered: sourcing config files (rejected due to namespace pollution in multi-env setup)

### Over-Abstraction Red Flags
- **Single-use abstractions**: If a helper is called ≤2 times, inline it or question the need
- **String concatenation builders**: Building shell commands as strings is fragile; prefer direct execution or wrapper scripts
- **Indirect variable expansion**: `${!var}` makes code harder to follow; prefer explicit fallback patterns

## Bash-Specific Simplifications

### Subshell Variable Loss
- Variables modified in pipeline subshells are lost:
  ```bash
  count=0
  cat file | while read line; do count=$((count+1)); done
  echo $count  # Always 0
  ```
- FIX: Use process substitution (`while read ... done < <(cmd)`) when vars need to escape

### Unnecessary String Building
- Building shell commands as concatenated strings is fragile and hard to read
- tmux/ssh already handle quoting — don't double-wrap with `bash -c` unless needed
- Prefer direct execution or simple `&&` chains over string interpolation
- Example: `cmd="a && b && c"; tmux new-session -d "$cmd"` not `"bash -c '$cmd'"`

### Extract Repeated Options
- Repeated tool invocations with same flags → helper function
- Found: `scp -o ConnectTimeout=X` used 10+ times → extracted to `_exe_scp()`
- Same for `ssh` → `_exe_ssh()` already existed

### Inline Single-Use Variables
- `repo_basename=$(basename "$local_workdir"); remote="$dir/$repo_basename"`
- SIMPLIFIED: `remote="$dir/$(basename "$local_workdir")"`
- Only extract when reused or complex

### Command Chains: Unnecessary Checks
- Checking if env file exists before conditionally sourcing it is redundant if the copy is also conditional
- WRONG: `[ -f env.sh ] && cmd="$cmd && source env.sh"` after `[ -f env.sh ] && scp env.sh`
- Either both succeed or both fail — no need to re-check

## Architecture Notes
- `/Users/davide/Repos/linear-machine/machine.sh`: main poll loop
- `/Users/davide/Repos/linear-machine/lib/linear.sh`: GraphQL wrapper
- `/Users/davide/Repos/linear-machine/lib/runner.sh`: runner loader + contract validation
- `/Users/davide/Repos/linear-machine/runners/{local,exe}.sh`: execution backends (tmux vs exe.dev VM)
- `/Users/davide/Repos/linear-machine/adapters/{codex,claude}.sh`: agent adapters
- Per-project environments: `/Users/davide/Repos/linear-machine/environments/*/`
- Runner contract: `runner_start`, `runner_is_running`, `runner_stop`, `runner_stop_all`, `runner_list`

## Future Refactoring Candidates
- `dispatch_new()` and `check_and_resume()` share 80% logic → consider extract-common pattern
- Environment resolution logic appears 3x → potential for consolidation if it grows
