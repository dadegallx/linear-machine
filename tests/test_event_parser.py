import hashlib
import hmac
import unittest
from datetime import datetime, timedelta, timezone

from lib.event_parser import (
    contains_agent_mention,
    is_timestamp_fresh,
    make_fallback_event_id,
    parse_event,
    verify_linear_signature,
)


class EventParserTests(unittest.TestCase):
    def test_mention_matcher_cases(self):
        self.assertTrue(contains_agent_mention("@francis are you there?", "francis"))
        self.assertTrue(contains_agent_mention("Hey @Francis, ping", "francis"))
        self.assertFalse(contains_agent_mention("@francois are you there?", "francis"))
        self.assertFalse(contains_agent_mention("francis are you there?", "francis"))

    def test_signature_verification_and_fallback_id(self):
        secret = "test_secret"
        body = b'{"a":1}'
        expected = hmac.new(secret.encode("utf-8"), body, hashlib.sha256).hexdigest()
        self.assertTrue(verify_linear_signature(body, expected, secret))
        self.assertTrue(verify_linear_signature(body, f"sha256={expected}", secret))
        self.assertFalse(verify_linear_signature(body, "sha256=deadbeef", secret))

        fallback = make_fallback_event_id(body)
        self.assertEqual(len(fallback), 64)

    def test_timestamp_freshness(self):
        now = datetime.now(timezone.utc)
        fresh = {"webhookTimestamp": now.isoformat()}
        stale = {"webhookTimestamp": (now - timedelta(minutes=10)).isoformat()}
        missing = {}

        self.assertTrue(is_timestamp_fresh(fresh, max_age_seconds=300))
        self.assertFalse(is_timestamp_fresh(stale, max_age_seconds=300))
        self.assertFalse(is_timestamp_fresh(missing, max_age_seconds=300))

    def test_parse_event_comment_create(self):
        payload = {
            "type": "Comment",
            "action": "create",
            "webhookId": "evt_1",
            "data": {
                "id": "comment_1",
                "body": "@francis are you there?",
                "user": {"id": "human_1"},
                "issue": {"id": "issue_1", "identifier": "TEAM-1"},
            },
            "actor": {"id": "human_1"},
        }

        event = parse_event(payload, agent_name="francis", fallback_event_id="fallback")
        self.assertEqual(event["event_id"], "evt_1")
        self.assertEqual(event["event_type"], "comment.create")
        self.assertEqual(event["issue_id"], "issue_1")
        self.assertEqual(event["issue_identifier"], "TEAM-1")
        self.assertEqual(event["comment_id"], "comment_1")
        self.assertEqual(event["actor_id"], "human_1")
        self.assertTrue(event["contains_mention"])


if __name__ == "__main__":
    unittest.main()
