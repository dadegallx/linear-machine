# Linear Machine E2E Testing Notes

## Runner Abstraction (2026-02-13)
- Runner loader (`lib/runner.sh`) validates contract: all 5 functions must exist (start, is_running, stop, stop_all, list)
- Local runner (`runners/local.sh`) extracts previous inline tmux logic — behaves identically
- `./machine.sh status` displays runner type in "Active Agents" header (e.g., "Active Agents (local)")
- Default `RUNNER_TYPE=local` if not set in .env

## Typical Execution Times (Local Runner)
- Poll cycle: 30s (configurable via POLL_INTERVAL)
- Simple file creation task: ~30s from dispatch to completion
- Agent pickup: immediate on poll (within poll interval)

## Test Procedure Validated
1. Create issue via Linear API, assign to agent user, set to Todo
2. Start machine: `./machine.sh start` (spawns background process)
3. Monitor: `tail -f /tmp/linear-agent/machine.log`
4. Verify: tmux session created, file artifact created, exit code 0
5. Stop: `./machine.sh stop` (kills loop + all tmux sessions)

## Follow-Up Message Testing Limitation
- Cannot test follow-up handling via Linear MCP tool — it uses agent credentials
- System correctly filters comments by agent user ID (machine.sh line 339)
- Follow-up detection requires comment from a different user account
- For full E2E, need a second Linear account or manual web UI comment

## Audit Trail Structure
State dir (`/tmp/linear-agent/<issue-id>/`):
- `issue_uuid`, `title`, `team_id`, `workdir` — context
- `session`, `exit_code`, `agent_state`, `output` — results
- `raw.json` — full agent execution metrics (timing, cost, tokens)
- `workflow_states.json` — cached workflow state mappings
- `env.sh` — Linear API vars for linear-tool
- `prompt` — enriched prompt sent to agent

## Common Failure Modes
- None observed in runner refactor — identical behavior to pre-refactor

## Documentation Gaps (README)
- No mention of RUNNER_TYPE or runner abstraction
- README still references tmux as hardcoded implementation
- Missing: how runner system works, how to add new runners
