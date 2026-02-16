# Linear Machine

**Tag an issue. Your agent handles the rest.**

A self-hosted implementation of [Linear for Agents](https://linear.app/agents) using your own agent CLI and infrastructure.

## What Changed

Linear Machine is now **webhook-first**:

- Primary triggers come from Linear webhooks (`commentCreate`, `issueUpdate` for assignee changes).
- Events are durably queued in SQLite with idempotency + per-comment dedupe.
- A worker processes events with per-issue locks and persistent session state.
- Polling remains only as a fallback reconciler.

## Trigger Rules

Dispatch/resume happens only when:

1. Issue is assigned to the agent user, or
2. A new **human** comment contains `@<agent-name>` (case-insensitive)

Ignored:

- Agent-authored comments (`actor_id == AGENT_USER_ID`)
- Closed/canceled issues
- Duplicate webhook deliveries/comments

## Quick Start

1. Configure `.env`:

```bash
LINEAR_API_KEY=lin_api_...
AGENT_USER_ID=...
AGENT_TYPE=claude                 # or codex
RUNNER_TYPE=local                 # or exe
STATE_DIR=/tmp/linear-agent
LINEAR_WEBHOOK_SECRET=...         # required
WEBHOOK_HOST=0.0.0.0              # optional
WEBHOOK_PORT=8787                 # optional
WEBHOOK_PATH=/webhooks/linear     # optional
RECONCILER_INTERVAL=300           # optional fallback cadence
```

2. Start machine:

```bash
./machine.sh start
```

3. Register Linear webhook URL:

```text
http://<host>:8787/webhooks/linear
```

4. Check runtime:

```bash
./machine.sh status
```

## Commands

```bash
./machine.sh start
./machine.sh stop
./machine.sh status
./machine.sh cleanup --issues
./machine.sh debug issue <issue-id-or-identifier>
./machine.sh run-reconciler
```

## Architecture

```
Linear webhooks --> bin/linear-webhook-listener --> SQLite queue (bin/state-store)
                                                      |
                                                      v
                                              machine.sh worker loop
                                                      |
                                              runner + adapter
                                                      |
                                                  agent CLI
```

Key files:

- `machine.sh` — worker loop, reconciler fallback, lifecycle/status/debug commands
- `bin/linear-webhook-listener` — HTTP intake + signature/timestamp validation + enqueue
- `bin/state-store` — durable queue/session store (SQLite)
- `lib/event_parser.py` — webhook parsing, signature checks, mention matcher
- `lib/linear.sh` — Linear GraphQL calls
- `runners/*`, `adapters/*`, `providers/*` — unchanged execution contracts

## Runtime State Model

Durable source of truth: `STATE_DB` (`$STATE_DIR/state.db`):

- `events`: pending/processing/done/failed + retries + dedupe keys
- `issue_sessions`: per-issue session state (`active_session_id`, last comment markers, VM metadata, status)
- `issue_locks`: per-issue lease for single-worker semantics
- `event_timeline`: debug timeline and structured action history

Filesystem state under `/tmp/linear-agent/<issue-id>/` remains runtime cache for adapters/runners.

## Lifecycle Semantics

- `start`: initializes DB, starts webhook listener + worker loop
- `stop`: stops worker/listener only (does **not** destroy unrelated VMs)
- `cleanup --issues`: explicit cleanup for issue-bound runtime state/VMs

## Testing

Run local test suite:

```bash
python3 -m unittest discover -s tests -p 'test_*.py'
```

Real E2E acceptance test:

```bash
LINEAR_E2E_TEAM_ID=<team-id> LINEAR_E2E_PROJECT_ID=<project-id-optional> \
  tests/e2e_linear_mention.sh
```

E2E flow:

1. Create new issue
2. Post `@francis are you there?`
3. Wait for Francis reply comment
4. Fail if no reply before timeout

## Dependencies

- `curl`, `jq`, `tmux`, `python3`
- agent CLI (`claude` or `codex`)
- optional `trash` command for safer runtime-cache deletion
