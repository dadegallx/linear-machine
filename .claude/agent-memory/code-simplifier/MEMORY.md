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
- FIX: Use process substitution or eliminate the counter if unused

### Unnecessary Pipes
- Found: `curl | python3 -c "json.dump(json.load())"` to pretty-print JSON
- The output goes to `jq` anyway, which doesn't care about formatting
- DELETED: Python formatting step (saves a process spawn per API call)

## Architecture Notes
- `/Users/davide/Repos/linear-machine/machine.sh`: main poll loop
- `/Users/davide/Repos/linear-machine/lib/linear.sh`: GraphQL wrapper
- `/Users/davide/Repos/linear-machine/adapters/{codex,claude}.sh`: agent adapters
- Per-project environments: `/Users/davide/Repos/linear-machine/environments/*/`

## Future Refactoring Candidates
- `dispatch_new()` and `check_and_resume()` share 80% logic → consider extract-common pattern
- Environment resolution logic appears 3x → potential for consolidation if it grows
