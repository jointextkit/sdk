"""Client behaviour against a scripted in-memory transport. No network."""
from __future__ import annotations

import json
import os
import socket
import unittest
from typing import Any, Dict, List, Optional, Tuple
from unittest import mock

from jointextkit import TextKit, TextKitError, Response

KEY = "ssms_sk_test_" + "a" * 32


class FakeTransport:
    """Pops one scripted reply per call and records every request."""

    def __init__(self, *replies: Any) -> None:
        self.replies = list(replies)
        self.calls: List[Dict[str, Any]] = []

    def __call__(self, method: str, url: str, headers: Dict[str, str], body: Optional[bytes], timeout: float) -> Response:
        self.calls.append(
            {"method": method, "url": url, "headers": headers, "json": json.loads(body) if body else None, "timeout": timeout}
        )
        reply = self.replies.pop(0)
        if isinstance(reply, BaseException):
            raise reply
        status, payload, headers_out = reply if len(reply) == 3 else (*reply, {})
        raw = payload.encode() if isinstance(payload, str) else json.dumps(payload).encode()
        return Response(status, headers_out, raw)


def err(code: str, message: str = "nope", **extra: Any) -> Dict[str, Any]:
    return {"error": {"code": code, "message": message, **extra}}


MSG = {"id": "msg_1", "object": "message", "to": "+15005550006", "from": "+15005550100", "body": "hi"}


def client(transport: FakeTransport, **kw: Any) -> Tuple[TextKit, List[float]]:
    sleeps: List[float] = []
    return TextKit(KEY, base_url="https://api.test", transport=transport, sleep=sleeps.append, **kw), sleeps


class ConstructionTests(unittest.TestCase):
    def test_reads_env_key(self) -> None:
        with mock.patch.dict(os.environ, {"TEXTKIT_API_KEY": KEY}):
            self.assertTrue(TextKit(transport=FakeTransport()).is_test_mode)

    def test_legacy_env_names_still_read(self) -> None:
        # Deployments configured before each rename set SIMPLESMS_*, DELIVERED_* (or RESMS_*).
        for name in ("SIMPLESMS_API_KEY", "DELIVERED_API_KEY", "RESMS_API_KEY"):
            with mock.patch.dict(os.environ, {name: KEY}, clear=True):
                self.assertTrue(TextKit(transport=FakeTransport()).is_test_mode)
        with mock.patch.dict(os.environ, {"DELIVERED_BASE_URL": "https://old.test/"}, clear=True):
            self.assertEqual(TextKit(KEY, transport=FakeTransport()).base_url, "https://old.test")
        with mock.patch.dict(os.environ, {"SIMPLESMS_BASE_URL": "https://simple.test/"}, clear=True):
            self.assertEqual(TextKit(KEY, transport=FakeTransport()).base_url, "https://simple.test")

    def test_simplesms_aliases(self) -> None:
        from jointextkit import SimpleSMS, SimpleSMSError, TextKitError
        self.assertIs(SimpleSMS, TextKit)
        self.assertIs(SimpleSMSError, TextKitError)

    def test_new_env_name_wins_over_legacy(self) -> None:
        env = {"TEXTKIT_API_KEY": "ssms_sk_live_" + "n" * 32, "DELIVERED_API_KEY": KEY,
               "TEXTKIT_BASE_URL": "https://new.test", "DELIVERED_BASE_URL": "https://old.test"}
        with mock.patch.dict(os.environ, env, clear=True):
            c = TextKit(transport=FakeTransport())
            self.assertFalse(c.is_test_mode)
            self.assertEqual(c.base_url, "https://new.test")

    def test_default_base_url_is_the_primary_domain(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(TextKit(KEY, transport=FakeTransport()).base_url, "https://api.jointextkit.com")

    def test_every_key_prefix_is_recognised(self) -> None:
        for prefix in ("ssms", "dsms", "resms"):
            self.assertTrue(TextKit(f"{prefix}_sk_test_" + "a" * 32, transport=FakeTransport()).is_test_mode, prefix)
            self.assertFalse(TextKit(f"{prefix}_sk_live_" + "a" * 32, transport=FakeTransport()).is_test_mode, prefix)

    def test_delivered_aliases(self) -> None:
        from jointextkit import Delivered, DeliveredError

        self.assertIs(Delivered, TextKit)
        self.assertIs(DeliveredError, TextKitError)

    def test_missing_key_raises(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(TextKitError) as ctx:
                TextKit()
            self.assertEqual(ctx.exception.code, "invalid_api_key")

    def test_live_key_is_not_test_mode(self) -> None:
        self.assertFalse(TextKit("ssms_sk_live_" + "b" * 32, transport=FakeTransport()).is_test_mode)


class MessagesTests(unittest.TestCase):
    def test_send_shape_auth_and_idempotency(self) -> None:
        t = FakeTransport((201, MSG))
        c, _ = client(t)
        out = c.messages.send(to="+15005550006", text="hi", from_="+15005550100")
        self.assertEqual(out["id"], "msg_1")
        call = t.calls[0]
        self.assertEqual((call["method"], call["url"]), ("POST", "https://api.test/v1/messages"))
        self.assertEqual(call["json"], {"to": "+15005550006", "body": "hi", "from": "+15005550100"})
        self.assertEqual(call["headers"]["Authorization"], f"Bearer {KEY}")
        self.assertTrue(call["headers"]["Idempotency-Key"].startswith("sdk_"))
        self.assertIn("jointextkit-python/", call["headers"]["User-Agent"])

    def test_send_requires_a_body(self) -> None:
        c, _ = client(FakeTransport())
        with self.assertRaises(TextKitError) as ctx:
            c.messages.send(to="+15005550006", from_="+15005550100")
        self.assertEqual(ctx.exception.param, "body")

    def test_send_passes_customer_id_and_own_idempotency_key(self) -> None:
        t = FakeTransport((201, MSG))
        c, _ = client(t)
        c.messages.send("+15005550006", "hi", from_="+15005550100", customer_id="cus_x", idempotency_key="order:1")
        self.assertEqual(t.calls[0]["json"]["customer_id"], "cus_x")
        self.assertEqual(t.calls[0]["headers"]["Idempotency-Key"], "order:1")

    def test_send_retries_5xx_with_the_same_idempotency_key(self) -> None:
        t = FakeTransport((502, err("carrier_error")), (201, MSG))
        c, sleeps = client(t)
        c.messages.send(to="+15005550006", body="hi", from_="+15005550100")
        self.assertEqual(len(t.calls), 2)
        self.assertEqual(t.calls[0]["headers"]["Idempotency-Key"], t.calls[1]["headers"]["Idempotency-Key"])
        self.assertEqual(len(sleeps), 1)

    def test_429_honors_retry_after_header(self) -> None:
        t = FakeTransport((429, err("rate_limited"), {"retry-after": "7"}), (200, {"data": [], "has_more": False, "next_cursor": None}))
        c, sleeps = client(t)
        c.messages.list()
        self.assertEqual(sleeps, [7.0])

    def test_429_honors_retry_after_in_body(self) -> None:
        t = FakeTransport((429, err("rate_limited", retry_after=3)), (200, MSG))
        c, sleeps = client(t)
        c.messages.get("msg_1")
        self.assertEqual(sleeps, [3.0])

    def test_gives_up_after_max_retries(self) -> None:
        t = FakeTransport(*[(503, err("internal_error"))] * 3)
        c, sleeps = client(t, max_retries=2)
        with self.assertRaises(TextKitError) as ctx:
            c.messages.get("msg_1")
        self.assertEqual(ctx.exception.status, 503)
        self.assertEqual(len(t.calls), 3)
        self.assertEqual(len(sleeps), 2)

    def test_connection_errors_are_retried_for_gets(self) -> None:
        t = FakeTransport(socket.timeout("slow"), ConnectionResetError("reset"), (200, MSG))
        c, _ = client(t)
        self.assertEqual(c.messages.get("msg_1")["id"], "msg_1")

    def test_connection_error_surfaces(self) -> None:
        t = FakeTransport(*[ConnectionRefusedError("down")] * 3)
        c, _ = client(t)
        with self.assertRaises(TextKitError) as ctx:
            c.messages.get("msg_1")
        self.assertEqual((ctx.exception.code, ctx.exception.status), ("connection_error", 0))
        self.assertTrue(ctx.exception.retryable)

    def test_4xx_is_not_retried_and_parses_the_envelope(self) -> None:
        t = FakeTransport((400, err("invalid_request", "`to` is bad", param="to")))
        c, _ = client(t)
        with self.assertRaises(TextKitError) as ctx:
            c.messages.send(to="nope", body="hi", from_="+15005550100")
        e = ctx.exception
        self.assertEqual((e.code, e.status, e.param, e.message), ("invalid_request", 400, "to", "`to` is bad"))
        self.assertFalse(e.retryable)
        self.assertEqual(len(t.calls), 1)

    def test_non_json_error_body(self) -> None:
        t = FakeTransport((500, "<html>bad gateway</html>"))
        c, _ = client(t, max_retries=0)
        with self.assertRaises(TextKitError) as ctx:
            c.messages.get("msg_1")
        self.assertEqual(ctx.exception.code, "internal_error")

    def test_default_from_is_looked_up_once(self) -> None:
        numbers = {"data": [{"phone_number": "+15005550100", "status": "active"}], "has_more": False, "next_cursor": None}
        t = FakeTransport((200, numbers), (201, MSG), (201, MSG))
        c, _ = client(t)
        with mock.patch.dict(os.environ, {}, clear=True):
            c._default_from = None
            c.messages.send(to="+15005550006", text="a")
            c.messages.send(to="+15005550006", text="b")
        self.assertEqual([x["url"] for x in t.calls].count("https://api.test/v1/numbers"), 1)
        self.assertEqual(t.calls[1]["json"]["from"], "+15005550100")

    def test_default_from_refuses_to_guess_between_numbers(self) -> None:
        numbers = {
            "data": [{"phone_number": "+15005550100", "status": "active"}, {"phone_number": "+15005550101", "status": "active"}],
            "has_more": False,
            "next_cursor": None,
        }
        t = FakeTransport((200, numbers))
        c, _ = client(t)
        c._default_from = None
        with self.assertRaises(TextKitError) as ctx:
            c.messages.send(to="+15005550006", text="a")
        self.assertEqual(ctx.exception.param, "from")

    def test_list_all_follows_cursors(self) -> None:
        t = FakeTransport(
            (200, {"data": [{"id": "m3"}, {"id": "m2"}], "has_more": True, "next_cursor": "k2"}),
            (200, {"data": [{"id": "m1"}], "has_more": False, "next_cursor": None}),
        )
        c, _ = client(t)
        ids = [m["id"] for m in c.messages.list_all(limit=2, customer_id="cus_x")]
        self.assertEqual(ids, ["m3", "m2", "m1"])
        self.assertEqual(t.calls[0]["url"], "https://api.test/v1/messages?limit=2&customer_id=cus_x")
        self.assertEqual(t.calls[1]["url"], "https://api.test/v1/messages?limit=2&cursor=k2&customer_id=cus_x")

    def test_schedule_serializes_datetime_as_utc(self) -> None:
        import datetime as dt

        t = FakeTransport((201, {"id": "job_1", "object": "scheduled_message"}))
        c, _ = client(t, default_from="+15005550100")
        c.messages.schedule("+15005550006", "later", dt.datetime(2026, 10, 2, 9, 30))
        self.assertEqual(t.calls[0]["json"]["scheduled_at"], "2026-10-02T09:30:00Z")


class VerifyTests(unittest.TestCase):
    def test_send_is_not_retried_without_idempotency(self) -> None:
        t = FakeTransport((500, err("internal_error")))
        c, _ = client(t)
        with self.assertRaises(TextKitError):
            c.verify.send("+14155550132", app_name="Acme", customer_id="cus_x")
        self.assertEqual(len(t.calls), 1)
        self.assertEqual(t.calls[0]["json"], {"to": "+14155550132", "app_name": "Acme", "customer_id": "cus_x"})

    def test_cooldown_is_policy_not_retried(self) -> None:
        t = FakeTransport((429, err("rate_limited", retry_after=60)))
        c, sleeps = client(t)
        with self.assertRaises(TextKitError) as ctx:
            c.verify.get("ver_1")  # GETs retry, but never on /verify cooldowns
        self.assertEqual(ctx.exception.retry_after, 60)
        self.assertEqual(sleeps, [])

    def test_check(self) -> None:
        t = FakeTransport((200, {"verified": True, "status": "approved"}))
        c, _ = client(t)
        self.assertTrue(c.verify.check("+14155550132", "111111")["verified"])
        self.assertEqual(t.calls[0]["json"], {"to": "+14155550132", "code": "111111"})

    def test_email_channel_send_and_check(self) -> None:
        t = FakeTransport((201, {"id": "ver_1", "channel": "email"}), (200, {"verified": True, "channel": "email"}))
        c, _ = client(t)
        c.verify.send("ada@example.com", channel="email", app_name="Acme")
        self.assertEqual(t.calls[0]["json"], {"channel": "email", "email": "ada@example.com", "app_name": "Acme"})
        c.verify.check("ada@example.com", "111111")
        self.assertEqual(t.calls[1]["json"], {"email": "ada@example.com", "code": "111111"})

    def test_fallback(self) -> None:
        t = FakeTransport((200, {"id": "ver_1", "channel": "email"}))
        c, _ = client(t)
        self.assertEqual(c.verify.fallback("ver_1", email="ada@example.com")["channel"], "email")
        self.assertEqual(t.calls[0]["method"], "POST")
        self.assertTrue(t.calls[0]["url"].endswith("/verify/ver_1/fallback"))
        self.assertEqual(t.calls[0]["json"], {"channel": "email", "email": "ada@example.com"})


class NumbersTests(unittest.TestCase):
    def test_update_sends_explicit_null_to_unassign(self) -> None:
        t = FakeTransport((200, {"customer_id": None}))
        c, _ = client(t)
        c.numbers.update("+15005550100", customer_id=None)
        call = t.calls[0]
        self.assertEqual((call["method"], call["url"]), ("PATCH", "https://api.test/v1/numbers/%2B15005550100"))
        self.assertEqual(call["json"], {"customer_id": None})

    def test_buy_with_customer_and_list_filter(self) -> None:
        t = FakeTransport((201, {}), (200, {"data": [], "has_more": False, "next_cursor": None}))
        c, _ = client(t)
        c.numbers.buy("+15005550110", customer_id="cus_x")
        c.numbers.list(customer_id="cus_x")
        self.assertEqual(t.calls[0]["json"], {"phone_number": "+15005550110", "customer_id": "cus_x"})
        self.assertEqual(t.calls[1]["url"], "https://api.test/v1/numbers?customer_id=cus_x")

    def test_release_is_not_retried(self) -> None:
        t = FakeTransport((502, err("carrier_error")))
        c, _ = client(t)
        with self.assertRaises(TextKitError):
            c.numbers.release("+15005550110")
        self.assertEqual(len(t.calls), 1)


class ConsentAndCustomersTests(unittest.TestCase):
    def test_consent_calls(self) -> None:
        t = FakeTransport(
            (200, {"status": "opted_out"}),
            (200, {"status": "opted_in"}),
            (200, {"imported": 1, "skipped": []}),
            (200, "phone,status\n+14155550132,opted_out\n"),
        )
        c, _ = client(t)
        c.consent.opt_out("+14155550132", note="crm")
        c.consent.opt_in("+14155550132")
        c.consent.import_(["+14155550132"])
        csv = c.consent.export()
        self.assertEqual(t.calls[0]["json"], {"status": "opted_out", "note": "crm"})
        self.assertEqual(t.calls[1]["json"], {"status": "opted_in"})
        self.assertEqual(t.calls[2]["json"], {"phone_numbers": ["+14155550132"]})
        self.assertTrue(csv.startswith("phone,status"))

    def test_customer_update_sends_only_given_fields(self) -> None:
        t = FakeTransport((200, {}), (200, {}))
        c, _ = client(t)
        c.customers.update("cus_x", name="Acme")
        c.customers.update("cus_x", external_id=None, metadata={"plan": "pro"})
        self.assertEqual(t.calls[0]["json"], {"name": "Acme"})
        self.assertEqual(t.calls[1]["json"], {"external_id": None, "metadata": {"plan": "pro"}})

    def test_customer_create_usage_and_lookup_by_external_id(self) -> None:
        t = FakeTransport((201, {"id": "cus_x"}), (200, {"object": "customer_usage"}), (200, {"data": [], "has_more": False, "next_cursor": None}))
        c, _ = client(t)
        c.customers.create(name="Acme", external_id="acct_1", metadata={"plan": "pro"})
        c.customers.usage("cus_x", start="2026-10-01", end="2026-10-31")
        c.customers.list(external_id="acct 1")
        self.assertEqual(t.calls[0]["json"], {"name": "Acme", "external_id": "acct_1", "metadata": {"plan": "pro"}})
        self.assertEqual(t.calls[1]["url"], "https://api.test/v1/customers/cus_x/usage?start=2026-10-01&end=2026-10-31")
        self.assertEqual(t.calls[2]["url"], "https://api.test/v1/customers?external_id=acct+1")


class AutomationTests(unittest.TestCase):
    def test_track_sends_an_idempotency_key_and_drops_unset_fields(self) -> None:
        t = FakeTransport((201, {"id": "tev_1", "runs_started": ["run_1"]}), (201, {"id": "tev_2"}))
        c, _ = client(t)
        r = c.events.track("trial_started", user_id="123", phone="+15005550006", properties={"plan": "pro"})
        c.events.track("subscription_created", user_id="123", idempotency_key="mine")
        self.assertEqual(r["runs_started"], ["run_1"])
        self.assertEqual(t.calls[0]["url"], "https://api.test/v1/track")
        self.assertEqual(
            t.calls[0]["json"],
            {"event": "trial_started", "user_id": "123", "phone": "+15005550006", "properties": {"plan": "pro"}},
        )
        self.assertTrue(t.calls[0]["headers"]["Idempotency-Key"])
        self.assertEqual(t.calls[1]["json"], {"event": "subscription_created", "user_id": "123"})
        self.assertEqual(t.calls[1]["headers"]["Idempotency-Key"], "mine")

    def test_automation_lifecycle_calls(self) -> None:
        page = {"data": [], "has_more": False, "next_cursor": None}
        t = FakeTransport((201, {"id": "auto_x"}), (200, {}), (200, {}), (200, {}), (200, page), (200, {}), (200, {}))
        c, _ = client(t)
        steps = [{"type": "send_sms", "body": "hi"}]
        c.automations.create(name="Welcome", trigger={"event": "user_signed_up"}, steps=steps, from_="+15005550100")
        c.automations.update("auto_x", topic_id=None)
        c.automations.activate("auto_x")
        c.automations.pause("auto_x")
        c.automations.runs("auto_x", limit=5)
        c.automations.cancel_run("auto_x", "run_1")
        c.automations.delete("auto_x")
        self.assertEqual(
            t.calls[0]["json"],
            {"name": "Welcome", "from": "+15005550100", "trigger": {"event": "user_signed_up"}, "steps": steps},
        )
        self.assertEqual(t.calls[1]["json"], {"topic_id": None})
        paths = [(x["method"], x["url"].replace("https://api.test/v1", "")) for x in t.calls[2:]]
        self.assertEqual(paths[0], ("POST", "/automations/auto_x/activate"))
        self.assertEqual(paths[1], ("POST", "/automations/auto_x/pause"))
        self.assertEqual(paths[2], ("GET", "/automations/auto_x/runs?limit=5"))
        self.assertEqual(paths[3][1], "/automations/auto_x/runs/run_1")
        self.assertEqual(paths[4][1], "/automations/auto_x")


class ScheduleTests(unittest.TestCase):
    REPEAT = {"frequency": "daily", "time": "08:00", "timezone": "America/New_York"}

    def test_create_omits_from_and_sends_an_idempotency_key(self) -> None:
        t = FakeTransport((201, {"id": "sch_x", "object": "schedule"}))
        c, _ = client(t)
        c.schedules.create("+15005550006", "Good morning", self.REPEAT, max_occurrences=30)
        call = t.calls[0]
        self.assertEqual((call["method"], call["url"]), ("POST", "https://api.test/v1/schedules"))
        # No `from`: the API picks the account's one number for the key's mode.
        self.assertEqual(
            call["json"], {"to": "+15005550006", "body": "Good morning", "repeat": self.REPEAT, "max_occurrences": 30}
        )
        self.assertTrue(call["headers"]["Idempotency-Key"])

    def test_create_uses_from_and_default_from(self) -> None:
        t = FakeTransport((201, {}), (201, {}))
        c, _ = client(t, default_from="+15005550100")
        c.schedules.create("+15005550006", "a", self.REPEAT)
        c.schedules.create("+15005550006", "a", self.REPEAT, from_="+15005550199", idempotency_key="mine")
        self.assertEqual(t.calls[0]["json"]["from"], "+15005550100")
        self.assertEqual(t.calls[1]["json"]["from"], "+15005550199")
        self.assertEqual(t.calls[1]["headers"]["Idempotency-Key"], "mine")

    def test_lifecycle_calls(self) -> None:
        page = {"data": [], "has_more": False, "next_cursor": None}
        t = FakeTransport((200, {}), (200, page), (200, {}), (200, {}), (200, {}), (200, {}), (200, page))
        c, _ = client(t)
        c.schedules.get("sch_x")
        c.schedules.list()
        c.schedules.pause("sch_x")
        c.schedules.resume("sch_x")
        c.schedules.update("sch_x", body="new", end_date=None)
        c.schedules.delete("sch_x")
        c.messages.list(schedule_id="sch_x")
        calls = [(x["method"], x["url"].replace("https://api.test/v1", ""), x["json"]) for x in t.calls]
        self.assertEqual(calls[0], ("GET", "/schedules/sch_x", None))
        self.assertEqual(calls[1], ("GET", "/schedules", None))
        self.assertEqual(calls[2], ("PATCH", "/schedules/sch_x", {"active": False}))
        self.assertEqual(calls[3], ("PATCH", "/schedules/sch_x", {"active": True}))
        # An explicit None clears the field; unset fields are not sent.
        self.assertEqual(calls[4], ("PATCH", "/schedules/sch_x", {"body": "new", "end_date": None}))
        self.assertEqual(calls[5], ("DELETE", "/schedules/sch_x", None))
        self.assertEqual(calls[6][1], "/messages?schedule_id=sch_x")


class WebhookEndpointTests(unittest.TestCase):
    def test_crud_paths_and_bodies(self) -> None:
        ep = {"id": "we_1", "object": "webhook_endpoint", "url": "https://example.com/h", "events": "*", "active": True}
        t = FakeTransport(
            (201, {**ep, "secret": "whsec_x"}), (200, {"data": [ep]}), (200, ep), (200, ep), (200, ep), (200, {"deleted": True})
        )
        c, _ = client(t)
        created = c.webhooks.create("https://example.com/h", events=["message.received"], description="orders")
        self.assertEqual(created["secret"], "whsec_x")
        c.webhooks.list()
        c.webhooks.get("we_1")
        c.webhooks.update("we_1", active=False)
        c.webhooks.update("we_1", description=None, events="*")
        c.webhooks.delete("we_1")
        calls = [(x["method"], x["url"].replace("https://api.test/v1", ""), x["json"]) for x in t.calls]
        self.assertEqual(
            calls[0],
            ("POST", "/webhooks", {"url": "https://example.com/h", "events": ["message.received"], "description": "orders"}),
        )
        self.assertEqual(calls[1], ("GET", "/webhooks", None))
        self.assertEqual(calls[2], ("GET", "/webhooks/we_1", None))
        # Only what was passed is sent; an explicit None clears the description.
        self.assertEqual(calls[3], ("PATCH", "/webhooks/we_1", {"active": False}))
        self.assertEqual(calls[4], ("PATCH", "/webhooks/we_1", {"events": "*", "description": None}))
        self.assertEqual(calls[5], ("DELETE", "/webhooks/we_1", None))

    def test_create_is_not_retried(self) -> None:
        # No idempotency key on this call: a retry could register the endpoint twice.
        t = FakeTransport((500, err("internal_error")))
        c, _ = client(t)
        with self.assertRaises(TextKitError):
            c.webhooks.create("https://example.com/h")
        self.assertEqual(len(t.calls), 1)

    def test_verify_still_works_on_the_class_and_the_instance(self) -> None:
        c, _ = client(FakeTransport())
        self.assertIs(type(c.webhooks).verify, type(TextKit.webhooks).verify)
        with self.assertRaises(TextKitError):
            TextKit.webhooks.list()

    def test_events_wait(self) -> None:
        t = FakeTransport(
            (200, {"object": "event_wait", "data": [], "cursor": "c1", "has_more": False}),
            (200, {"object": "event_wait", "data": [{"id": "evt_1"}], "cursor": "c2", "has_more": False}),
        )
        c, _ = client(t)
        first = c.events.wait()
        second = c.events.wait(cursor=first["cursor"], timeout=20)
        self.assertEqual(second["data"][0]["id"], "evt_1")
        self.assertTrue(t.calls[0]["url"].endswith("/v1/events/wait"))
        self.assertTrue(t.calls[1]["url"].endswith("/v1/events/wait?cursor=c1&timeout=20"))


if __name__ == "__main__":
    unittest.main()
