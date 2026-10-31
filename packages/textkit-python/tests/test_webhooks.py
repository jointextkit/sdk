"""verify_webhook against signatures produced by the server's own signer.

fixtures/webhook_vectors.json is generated from src/lib/api/webhook-signature.ts
(npx tsx scripts/qa/webhook-vectors.ts), and the repo's Node test suite fails
if the file ever drifts from what production signs."""
from __future__ import annotations

import hashlib
import hmac
import json
import pathlib
import unittest

from jointextkit import TextKit, TextKitError, verify_webhook

FIXTURE = json.loads((pathlib.Path(__file__).parent / "fixtures" / "webhook_vectors.json").read_text("utf-8"))
SECRET = FIXTURE["secret"]
VECTORS = FIXTURE["vectors"]


class WebhookTests(unittest.TestCase):
    def assertInvalid(self, fn, pattern: str) -> None:  # type: ignore[no-untyped-def]
        with self.assertRaises(TextKitError) as ctx:
            fn()
        self.assertEqual(ctx.exception.code, "invalid_signature")
        self.assertRegex(ctx.exception.message, pattern)

    def test_server_vectors_verify_as_str_and_bytes(self) -> None:
        for v in VECTORS:
            event = verify_webhook(v["payload"], v["signature"], SECRET, now=v["timestamp"])
            self.assertEqual(event, json.loads(v["payload"]))
            event_b = verify_webhook(v["payload"].encode("utf-8"), v["signature"], SECRET, now=v["timestamp"])
            self.assertEqual(event_b, event)

    def test_client_namespace(self) -> None:
        v = VECTORS[0]
        self.assertEqual(TextKit.webhooks.verify(v["payload"], v["signature"], SECRET, now=v["timestamp"])["id"], "evt_a1B2c3D4e5F6g7H8")

    def test_any_header_name_verifies(self) -> None:
        # The signature is sent under all three names; a headers mapping with
        # any one of them (any casing) verifies.
        v = VECTORS[0]
        for name in ("textkit-signature", "dsms-signature", "resms-signature", "TextKit-Signature", "Dsms-Signature"):
            event = verify_webhook(v["payload"], {name: v["signature"], "content-type": "application/json"}, SECRET, now=v["timestamp"])
            self.assertEqual(event["id"], "evt_a1B2c3D4e5F6g7H8", name)
        self.assertInvalid(lambda: verify_webhook(v["payload"], {"x-other": "1"}, SECRET, now=v["timestamp"]), "Missing")

    def test_header_helpers(self) -> None:
        from jointextkit import event_id_from_headers, signature_from_headers

        self.assertEqual(signature_from_headers({"dsms-signature": "t=1,v1=aa"}), "t=1,v1=aa")
        self.assertEqual(signature_from_headers({"textkit-signature": "new", "dsms-signature": "old"}), "new")
        self.assertEqual(event_id_from_headers({"Resms-Event-Id": "evt_1"}), "evt_1")
        self.assertIsNone(event_id_from_headers({}))

    def test_tampered_payload(self) -> None:
        v = VECTORS[0]
        self.assertInvalid(lambda: verify_webhook(v["payload"].replace("0006", "0007"), v["signature"], SECRET, now=v["timestamp"]), "does not match")

    def test_reserialized_json_fails(self) -> None:
        v = VECTORS[1]
        reserialized = json.dumps(json.loads(v["payload"]))  # ensure_ascii escapes: different bytes
        self.assertInvalid(lambda: verify_webhook(reserialized, v["signature"], SECRET, now=v["timestamp"]), "does not match")

    def test_wrong_secret(self) -> None:
        v = VECTORS[0]
        self.assertInvalid(lambda: verify_webhook(v["payload"], v["signature"], "whsec_other", now=v["timestamp"]), "does not match")

    def test_tolerance_both_directions(self) -> None:
        v = VECTORS[0]
        t = v["timestamp"]
        verify_webhook(v["payload"], v["signature"], SECRET, now=t + 300)
        self.assertInvalid(lambda: verify_webhook(v["payload"], v["signature"], SECRET, now=t + 301), "tolerance")
        self.assertInvalid(lambda: verify_webhook(v["payload"], v["signature"], SECRET, now=t - 301), "tolerance")
        verify_webhook(v["payload"], v["signature"], SECRET, now=t + 10_000, tolerance=0)

    def test_forged_timestamp(self) -> None:
        v = VECTORS[0]
        sig = v["signature"].split("v1=")[1]
        forged = f"t={v['timestamp'] + 5},v1={sig}"
        self.assertInvalid(lambda: verify_webhook(v["payload"], forged, SECRET, now=v["timestamp"] + 5), "does not match")

    def test_rotation_any_v1_matches(self) -> None:
        v = VECTORS[0]
        good = hmac.new(SECRET.encode(), f"{v['timestamp']}.{v['payload']}".encode(), hashlib.sha256).hexdigest()
        verify_webhook(v["payload"], f"t={v['timestamp']},v1={'0' * 64},v1={good}", SECRET, now=v["timestamp"])

    def test_missing_and_malformed(self) -> None:
        v = VECTORS[0]
        self.assertInvalid(lambda: verify_webhook(v["payload"], None, SECRET), "Missing")
        self.assertInvalid(lambda: verify_webhook(v["payload"], "v1=abc", SECRET), "Malformed")
        self.assertInvalid(lambda: verify_webhook(v["payload"], f"t={v['timestamp']}", SECRET), "Malformed")
        self.assertInvalid(lambda: verify_webhook(v["payload"], "garbage", SECRET), "Malformed")
        self.assertInvalid(lambda: verify_webhook(v["payload"], v["signature"], ""), "secret")


if __name__ == "__main__":
    unittest.main()
