# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A shell-based bridge that polls Linear for issues assigned to an agent user, dispatches coding agents (Codex or Claude Code) in tmux sessions. Agents manage their own Linear workflow — assigning issues, updating status, posting comments — via `bin/linear-tool`. Machine.sh is a lightweight supervisor: dispatch + crash recovery + resume on human reply.

The full lifecycle: **Todo** → machine dispatches agent → agent self-assigns + moves to **In Progress** → agent works → agent posts comment + moves to **In Review** → human replies → machine resumes agent → repeat. If the agent is stuck, it moves to **Blocked** and stops; machine resumes when a human replies.

## Commands

```bash
./machine.sh start    # Start polling loop (background)
./machine.sh stop     # Stop loop + kill all agent tmux sessions
./machine.sh status   # Show running agents and tracked issues
```

Watch a live agent session: `tmux attach -t linear-<issue-id>`
Logs: `tail -f /tmp/linear-agent/machine.log`

There are no build, lint, or test commands — the project is pure bash.

## Architecture

The system has six layers connected by filesystem state:

1. **`machine.sh`** — Lightweight supervisor. Runs two phases each cycle:
   - `handle_finished_agents`: checks `runner_is_running` for each tracked issue. Exit code 0 = success (agent handled everything). Exit code 100 = blocked (agent signaled via linear-tool). Other = crash → posts error comment, moves issue to Blocked.
   - `poll_and_dispatch`: queries Linear for ALL issues assigned to agent (no state filter), plus @mentions. Filters by state name: Todo → dispatch new, In Review/Blocked → check for human reply and resume.
   - `build_prompt`: writes enriched prompt with tool docs and workflow instructions.
   - `write_agent_env`: writes `$state_dir/env.sh` with Linear-specific vars for `linear-tool`.
   - Environment helpers: `resolve_environment`, `env_repo_path`.
   - Writes `$state_dir/workdir` before calling `runner_start`, so runners know where the repo is.

2. **`lib/runner.sh` + `runners/`** — Runner abstraction: decides WHERE agents run. `lib/runner.sh` loads `runners/${RUNNER_TYPE}.sh` (defaults to `local`) and validates the contract. Each runner implements 5 functions:
   - `runner_start ID STATE_DIR ENV_DIR AGENT_TYPE ACTION` — launch or resume an agent
   - `runner_is_running ID` — exit 0 if agent still active, 1 if done
   - `runner_stop ID` — kill agent (and destroy VM for remote providers)
   - `runner_stop_all` — kill all `linear-*` agents
   - `runner_list` — print running agents
   - **`runners/local.sh`** — Default. Runs agents in local tmux sessions (extracted from machine.sh).
   - **`runners/exe.sh`** — exe.dev managed VMs. Full lifecycle: spin up → clone repo → sync state → run agent → sync results back. VMs persist between start/resume. Reads `repo_url` from env dir for remote cloning.

3. **`bin/linear-tool`** — Agent-callable CLI for Linear operations. Subcommands:
   - `assign` — self-assign the issue
   - `status "State Name"` — update issue status (resolves name → UUID via cached workflow states)
   - `comment "body"` — post a comment
   - `get-comments` — print recent comments
   - Setting status to anything matching "block" writes exit code 100 to signal the agent should stop.

4. **`environments/`** — Per-project configuration. Each Linear project maps to an environment directory via `mapping.conf`. Each environment contains:
   - `repo_path` — single line with the target repository path (local runner uses this)
   - `repo_url` — optional: git clone URL for remote runners (e.g. `https://github.com/org/repo`)
   - `config.sh` — reserved for future per-environment config (STATUS_* IDs removed; states now resolved dynamically)
   - `env.sh` — optional, git-ignored: environment variables sourced before agent runs
   - `setup.sh` — optional, executable: runs on first dispatch only (not resume)
   - `environments/default/` is the fallback for unmapped projects.

5. **`adapters/{codex,claude}.sh`** — Agent adapters with a uniform interface: `start STATE_DIR WORKDIR` and `resume STATE_DIR`. Each:
   - Sources `$state_dir/env.sh` (Linear vars for `linear-tool`)
   - Adds `bin/` to PATH (makes `linear-tool` available)
   - Writes `session`, `output`, and debug files to STATE_DIR
   - Writes default `exit_code` (0) if agent didn't set one via `linear-tool`

6. **`lib/linear.sh`** — Linear GraphQL API layer. Uses `curl` for HTTP + `python3 -c` with `json.dumps` to safely escape query variables. Functions:
   - `linear_poll_issues` — all issues assigned to agent (no state filter)
   - `linear_poll_mentions` — unassigned issues where a comment mentions the agent name
   - `linear_post_comment`, `linear_set_status`, `linear_assign_issue`
   - `linear_get_comments`, `linear_get_workflow_states`

**State directory** (`/tmp/linear-agent/<issue-id>/`): `prompt`, `session`, `output`, `issue_uuid`, `title`, `team_id`, `project_id`, `workdir`, `posted_at`, `exit_code`, `agent_state`, `env.sh`, `workflow_states.json`. Remote runners also write: `vm_name`, `ssh_dest`, `remote_workdir`.

## Key Design Decisions

- The Linear API key must belong to the **agent user account**, not a personal account. This is how the script distinguishes agent comments from human comments when deciding whether to resume.
- **Agents own their workflow**: agents call `linear-tool` to assign, update status, and post comments. Machine.sh only intervenes on crash (posts error comment, moves to Blocked).
- **No hardcoded status UUIDs**: workflow state names (e.g. "In Progress", "Blocked") are resolved to UUIDs dynamically via the Linear API. Cached per-session in `workflow_states.json`.
- GraphQL payloads are built via `python3 -c "import json; ..."` rather than string interpolation, because issue descriptions and comments contain arbitrary text that would break JSON if shell-escaped.
- `POLL_INTERVAL`, `STATE_DIR`, `REPOS_DIR`, `AGENT_TYPE`, `AGENT_DISPLAY_NAME`, and `RUNNER_TYPE` are configured in `.env`.
- **Environment resolution**: issue project ID → `mapping.conf` lookup → environment dir. No match → `environments/default/`. No `default/` → legacy `$REPOS_DIR`.
- **Setup vs resume**: `setup.sh` runs only on first dispatch; `env.sh` is sourced on both start and resume.
- **Exit code protocol**: 0 = success, 100 = blocked (agent chose to stop), other = crash.
- **Runner abstraction**: `machine.sh → runner (where) → adapter (what)`. Runners handle WHERE agents run (local tmux vs remote VM). Adapters handle WHICH agent runs (Claude vs Codex). Adding a new provider means creating one file in `runners/` implementing 5 functions — no changes to machine.sh or adapters.
- **Remote VM lifecycle**: exe.dev VMs persist between start/resume (same repo state + agent session). Destroyed on `runner_stop` or `runner_stop_all`. A background watcher syncs result files back to local state dir when the remote agent finishes.

## Dependencies

`curl`, `jq`, `tmux`, `python3`, and the chosen agent CLI (`codex` or `claude`).

## Maintaining This File

Keep this CLAUDE.md up to date. Whenever you add new scripts, change the architecture, modify the adapter contract, add new Linear API functions, or alter the state directory layout, update the relevant sections above in the same commit.
