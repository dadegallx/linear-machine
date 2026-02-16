import hashlib
import hmac
import json
import os
import socket
import subprocess
import tempfile
import time
import unittest
from datetime import datetime, timezone
from urllib import request


def free_port() -> int:
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


class WebhookListenerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = os.path.join(self.tmp.name, "state.db")
        self.secret = "listener_secret"
        self.port = free_port()
        self.listener = os.path.join(os.getcwd(), "bin", "linear-webhook-listener")
        self.store = os.path.join(os.getcwd(), "bin", "state-store")

        subprocess.check_output([self.store, "--db", self.db, "init"], text=True)
        self.proc = subprocess.Popen(
            [
                self.listener,
                "--host",
                "127.0.0.1",
                "--port",
                str(self.port),
                "--path",
                "/webhooks/linear",
                "--db",
                self.db,
                "--webhook-secret",
                self.secret,
                "--agent-name",
                "francis",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        time.sleep(0.4)

    def tearDown(self):
        self.proc.terminate()
        self.proc.wait(timeout=5)
        self.tmp.cleanup()

    def _post(self, payload):
        raw = json.dumps(payload).encode("utf-8")
        signature = hmac.new(self.secret.encode("utf-8"), raw, hashlib.sha256).hexdigest()
        req = request.Request(
            f"http://127.0.0.1:{self.port}/webhooks/linear",
            data=raw,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "Linear-Signature": signature,
            },
        )
        with request.urlopen(req, timeout=3) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))

    def _queue_stats(self):
        out = subprocess.check_output([self.store, "--db", self.db, "queue-stats"], text=True)
        return json.loads(out)

    def test_webhook_signature_and_dedupe(self):
        payload = {
            "type": "Comment",
            "action": "create",
            "webhookId": "evt-listener-1",
            "webhookTimestamp": datetime.now(timezone.utc).isoformat(),
            "data": {
                "id": "comment-1",
                "body": "@francis are you there?",
                "user": {"id": "human-1"},
                "issue": {"id": "issue-1", "identifier": "TEAM-1"},
            },
            "actor": {"id": "human-1"},
        }

        status, body = self._post(payload)
        self.assertEqual(status, 200)
        self.assertTrue(body.get("ok"))

        status2, body2 = self._post(payload)
        self.assertEqual(status2, 200)
        self.assertTrue(body2.get("duplicate"))

        stats = self._queue_stats()
        self.assertEqual(stats["pending"], 1)


if __name__ == "__main__":
    unittest.main()
