#!/usr/bin/env python3
"""Linear webhook parsing + mention matching utilities."""

from __future__ import annotations

import hashlib
import hmac
import json
import re
from datetime import datetime, timezone
from typing import Any, Dict, Optional


MENTION_PATTERN_TEMPLATE = r"(^|\W)@{name}(\W|$)"


def contains_agent_mention(body: str, agent_name: str) -> bool:
    if not body or not agent_name:
        return False
    name = re.escape(agent_name.strip().lower())
    if not name:
        return False
    pattern = re.compile(MENTION_PATTERN_TEMPLATE.format(name=name), re.IGNORECASE)
    return bool(pattern.search(body.lower()))


def _normalize_signature(value: Optional[str]) -> str:
    if not value:
        return ""
    sig = value.strip()
    if "=" in sig:
        _, sig = sig.split("=", 1)
    return sig.lower()


def verify_linear_signature(raw_body: bytes, signature_header: str, secret: str) -> bool:
    if not secret:
        return False
    provided = _normalize_signature(signature_header)
    if not provided:
        return False
    expected = hmac.new(secret.encode("utf-8"), raw_body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(provided, expected)


def parse_webhook_timestamp(payload: Dict[str, Any]) -> Optional[datetime]:
    ts = payload.get("webhookTimestamp")
    if not isinstance(ts, str) or not ts:
        return None
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(ts)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def is_timestamp_fresh(payload: Dict[str, Any], max_age_seconds: int = 300) -> bool:
    ts = parse_webhook_timestamp(payload)
    if ts is None:
        return False
    age = abs((datetime.now(timezone.utc) - ts).total_seconds())
    return age <= max_age_seconds


def _obj(value: Any) -> Dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _get(obj: Dict[str, Any], *path: str) -> Any:
    cur: Any = obj
    for key in path:
        if not isinstance(cur, dict):
            return None
        cur = cur.get(key)
    return cur


def _event_type(payload: Dict[str, Any]) -> str:
    typ = str(payload.get("type") or "").strip().lower()
    action = str(payload.get("action") or "").strip().lower()
    if typ and action:
        return f"{typ}.{action}"
    if typ:
        return typ
    return "unknown"


def parse_event(raw_payload: Dict[str, Any], *, agent_name: str, fallback_event_id: str) -> Dict[str, Any]:
    payload = _obj(raw_payload)
    data = _obj(payload.get("data"))
    issue = _obj(_get(data, "issue"))
    if not issue and str(payload.get("type", "")).lower() == "issue":
        issue = data

    comment_body = str(data.get("body") or "")
    actor_id = str(_get(payload, "actor", "id") or _get(data, "user", "id") or "")

    issue_id = str(issue.get("id") or data.get("issueId") or "")
    issue_identifier = str(issue.get("identifier") or data.get("identifier") or "")
    comment_id = str(data.get("id") or "") if str(payload.get("type", "")).lower() == "comment" else ""
    assignee_id = str(_get(data, "assignee", "id") or data.get("assigneeId") or "")

    mention = contains_agent_mention(comment_body, agent_name)
    event_id = (
        str(payload.get("webhookId") or "")
        or str(payload.get("id") or "")
        or fallback_event_id
    )

    return {
        "event_id": event_id,
        "source": "webhook",
        "event_type": _event_type(payload),
        "issue_id": issue_id,
        "issue_identifier": issue_identifier,
        "comment_id": comment_id,
        "actor_id": actor_id,
        "assignee_id": assignee_id,
        "mention_text": comment_body,
        "contains_mention": mention,
        "payload": payload,
    }


def make_fallback_event_id(raw_body: bytes) -> str:
    return hashlib.sha256(raw_body).hexdigest()


def parse_json_bytes(raw_body: bytes) -> Dict[str, Any]:
    return json.loads(raw_body.decode("utf-8"))
