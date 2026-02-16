# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A webhook-first bridge from Linear to coding agents (Codex or Claude Code) in tmux/VM sessions.

- Webhook listener ingests `commentCreate` and `issueUpdate` events.
- Events are durably queued with dedupe/idempotency.
- Worker loop decides dispatch/resume deterministically.
- Polling remains a fallback reconciler only.

Agents manage issue workflow via `bin/linear-tool` (assign/status/comment).

## Commands

```bash
./machine.sh start
./machine.sh stop
./machine.sh status
./machine.sh cleanup --issues
./machine.sh debug issue <issue-id-or-identifier>
./machine.sh run-reconciler
```

Watch sessions/logs:

```bash
tmux attach -t linear-<issue-id>
tail -f /tmp/linear-agent/machine.log
```

## Architecture

The system has eight layers:

1. **`machine.sh`** — Worker supervisor and control plane
   - Starts webhook listener and event worker loop
   - Handles finished agents (success/blocked/crash)
   - Consumes durable queue with per-issue lock lease
   - Applies deterministic trigger rules
   - Runs fallback reconciler interval
   - Provides `status`, `cleanup --issues`, `debug issue`

2. **`bin/linear-webhook-listener`** — HTTP intake
   - `POST /webhooks/linear`
   - Verifies `Linear-Signature` using webhook secret
   - Validates `webhookTimestamp` freshness
   - Parses event fields and enqueues quickly (200 ACK)

3. **`bin/state-store`** — Durable state backend (SQLite)
   - `events` queue: pending/processing/done/failed + retries
   - `issue_sessions`: source of truth for per-issue runtime state
   - `issue_locks`: single worker per issue
   - `event_timeline`: debug timeline and structured action logs

4. **`lib/event_parser.py`** — Webhook parsing utilities
   - Mention matcher (`@francis` case-insensitive)
   - Signature verification helper
   - Event payload normalization

5. **`lib/provider.sh` + `providers/`** — Provider auth abstraction
   - `provider_sync_credentials SSH_DEST`
   - Shared + per-agent credential sync scripts

6. **`lib/runner.sh` + `runners/`** — Runner abstraction (where to execute)
   - `runner_start`, `runner_is_running`, `runner_stop`, `runner_stop_all`, `runner_list`
   - `local` tmux runner and `exe` VM runner

7. **`adapters/{codex,claude}.sh`** — Agent adapters (what to execute)
   - Uniform interface: `start STATE_DIR WORKDIR`, `resume STATE_DIR`
   - Source env + write `session`, `output`, `exit_code`

8. **`lib/linear.sh`** — Linear GraphQL layer
   - Poll APIs (fallback reconciler)
   - Issue context fetch (`linear_get_issue_context`)
   - Comment/status/assign mutations

## Trigger Rules

Dispatch/resume when:

- issue assigned to `AGENT_USER_ID`, or
- new human comment contains `@<agent-name>`

Ignore when:

- comment actor is `AGENT_USER_ID`
- issue is completed/canceled
- event/comment already deduped

## State Model

Source of truth is SQLite (`$STATE_DIR/state.db`).

Per issue persisted fields include:

- `issue_id`, `issue_identifier`
- `active_session_id`
- `last_processed_comment_id`
- `last_human_comment_ts`
- `vm_name`, `ssh_dest`
- `status` (`idle|running|blocked|done`)
- `project_id`, `team_id`, `state_dir`, `last_assignee_id`

Filesystem under `/tmp/linear-agent/<issue-id>/` is runtime cache only.

## Key Design Decisions

- API key must belong to the agent account to distinguish human vs agent comments.
- Agents own lifecycle/status updates through `linear-tool`.
- No hardcoded workflow state UUIDs (resolved by name at runtime).
- Worker path is webhook-first; reconciler is safety net only.
- `machine.sh stop` stops worker/listener only; cleanup is explicit via `cleanup --issues`.
- Remote VM handling remains isolated to runner layer.

## Testing

```bash
python3 -m unittest discover -s tests -p 'test_*.py'
```

Important E2E acceptance test:

```bash
LINEAR_E2E_TEAM_ID=<team-id> tests/e2e_linear_mention.sh
```

This must prove: new issue + human `@francis are you there?` => Francis replies.

## Dependencies

`curl`, `jq`, `tmux`, `python3`, and selected agent CLI (`codex` or `claude`).

## Maintaining Docs

Keep **both** CLAUDE.md and README.md synchronized whenever architecture, scripts, state model, or runner behavior changes.
