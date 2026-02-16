import json
import os
import subprocess
import tempfile
import unittest


class StateStoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = os.path.join(self.tmp.name, "state.db")
        self.store = os.path.join(os.getcwd(), "bin", "state-store")
        self.run_store(["init"])

    def tearDown(self):
        self.tmp.cleanup()

    def run_store(self, args):
        cmd = [self.store, "--db", self.db] + args
        out = subprocess.check_output(cmd, text=True)
        return json.loads(out or "{}")

    def test_event_enqueue_and_dedupe(self):
        event = {
            "event_id": "evt-1",
            "source": "webhook",
            "event_type": "comment.create",
            "issue_id": "issue-1",
            "issue_identifier": "TEAM-1",
            "comment_id": "comment-1",
            "actor_id": "human-1",
            "contains_mention": True,
            "payload": {},
        }

        first = self.run_store(["enqueue", "--event", json.dumps(event)])
        self.assertTrue(first["inserted"])

        dup = self.run_store(["enqueue", "--event", json.dumps(event)])
        self.assertTrue(dup["duplicate"])

        claimed = self.run_store(["claim-next", "--worker-id", "w1"])
        self.assertTrue(claimed["claimed"])
        self.assertEqual(claimed["event_id"], "evt-1")

        self.run_store(["mark-done", "--event-id", "evt-1"])
        stats = self.run_store(["queue-stats"])
        self.assertEqual(stats["done"], 1)

    def test_lock_acquire_release(self):
        acquired = self.run_store([
            "acquire-lock",
            "--issue-id",
            "issue-1",
            "--owner",
            "owner-a",
            "--lease-sec",
            "30",
        ])
        self.assertTrue(acquired["acquired"])

        denied = self.run_store([
            "acquire-lock",
            "--issue-id",
            "issue-1",
            "--owner",
            "owner-b",
            "--lease-sec",
            "30",
        ])
        self.assertFalse(denied["acquired"])

        self.run_store(["release-lock", "--issue-id", "issue-1", "--owner", "owner-a"])
        acquired2 = self.run_store([
            "acquire-lock",
            "--issue-id",
            "issue-1",
            "--owner",
            "owner-b",
            "--lease-sec",
            "30",
        ])
        self.assertTrue(acquired2["acquired"])

    def test_session_upsert(self):
        self.run_store([
            "upsert-session",
            "--issue-id",
            "issue-1",
            "--fields",
            json.dumps({"issue_identifier": "TEAM-1", "status": "running", "active_session_id": "sess-1"}),
        ])
        session = self.run_store(["get-session", "--issue-id", "issue-1"])
        self.assertEqual(session["issue_identifier"], "TEAM-1")
        self.assertEqual(session["status"], "running")
        self.assertEqual(session["active_session_id"], "sess-1")


if __name__ == "__main__":
    unittest.main()
