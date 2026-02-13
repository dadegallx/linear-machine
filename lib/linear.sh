#!/usr/bin/env bash
# Linear API functions — pure curl + jq, no dependencies

linear_gql() {
  local payload="$1"
  curl -s -X POST https://api.linear.app/graphql \
    -H "Authorization: $LINEAR_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload"
}

linear_poll_issues() {
  # Fetch ALL issues assigned to agent (no state filter).
  # Machine.sh filters by state name after receiving results.
  local payload
  payload=$(python3 -c "
import json, sys
q = 'query(\$uid: ID!) { issues(filter: { assignee: { id: { eq: \$uid } } }) { nodes { id identifier title description state { id name } project { id name } team { id } comments(last: 20) { nodes { id body createdAt user { id displayName } } } } } }'
print(json.dumps({'query': q, 'variables': {'uid': sys.argv[1]}}))" "$AGENT_USER_ID")
  linear_gql "$payload"
}

linear_poll_mentions() {
  # Fetch issues NOT assigned to agent where a recent comment mentions agent name.
  # Returns same shape as linear_poll_issues for uniform handling.
  local agent_name="$1"
  local payload
  payload=$(python3 -c "
import json, sys
q = 'query(\$uid: ID!, \$term: String!) { issueSearch(filter: { assignee: { null: true } }, term: \$term) { nodes { id identifier title description state { id name } project { id name } team { id } comments(last: 20) { nodes { id body createdAt user { id displayName } } } } } }'
print(json.dumps({'query': q, 'variables': {'uid': sys.argv[1], 'term': sys.argv[2]}}))" "$AGENT_USER_ID" "$agent_name")
  linear_gql "$payload"
}

linear_post_comment() {
  local issue_id="$1"
  local body="$2"
  local payload
  payload=$(python3 -c "
import json, sys
q = 'mutation(\$input: CommentCreateInput!) { commentCreate(input: \$input) { success comment { id } } }'
print(json.dumps({'query': q, 'variables': {'input': {'issueId': sys.argv[1], 'body': sys.argv[2]}}}))" "$issue_id" "$body")
  linear_gql "$payload"
}

linear_set_status() {
  local issue_id="$1"
  local status_id="$2"
  local payload
  payload=$(python3 -c "
import json, sys
q = 'mutation(\$id: String!, \$input: IssueUpdateInput!) { issueUpdate(id: \$id, input: \$input) { success } }'
print(json.dumps({'query': q, 'variables': {'id': sys.argv[1], 'input': {'stateId': sys.argv[2]}}}))" "$issue_id" "$status_id")
  linear_gql "$payload"
}

linear_assign_issue() {
  local issue_id="$1"
  local user_id="$2"
  local payload
  payload=$(python3 -c "
import json, sys
q = 'mutation(\$id: String!, \$input: IssueUpdateInput!) { issueUpdate(id: \$id, input: \$input) { success } }'
print(json.dumps({'query': q, 'variables': {'id': sys.argv[1], 'input': {'assigneeId': sys.argv[2]}}}))" "$issue_id" "$user_id")
  linear_gql "$payload"
}

linear_get_comments() {
  local issue_id="$1"
  local payload
  payload=$(python3 -c "
import json, sys
q = 'query(\$id: String!) { issue(id: \$id) { comments(last: 20) { nodes { id body createdAt user { id displayName } } } } }'
print(json.dumps({'query': q, 'variables': {'id': sys.argv[1]}}))" "$issue_id")
  linear_gql "$payload"
}

linear_get_workflow_states() {
  local team_id="$1"
  local payload
  payload=$(python3 -c "
import json, sys
q = 'query(\$tid: ID!) { workflowStates(filter: { team: { id: { eq: \$tid } } }) { nodes { id name type } } }'
print(json.dumps({'query': q, 'variables': {'tid': sys.argv[1]}}))" "$team_id")
  linear_gql "$payload"
}
