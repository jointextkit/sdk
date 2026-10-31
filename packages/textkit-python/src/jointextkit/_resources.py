from __future__ import annotations

from datetime import datetime, timezone
from typing import TYPE_CHECKING, Any, Callable, Dict, Iterator, List, Mapping, Optional, Union, cast

from ._client import _query, _quote, new_idempotency_key
from ._errors import TextKitError
from .types import (
    Automation,
    AutomationRun,
    AvailableNumber,
    ConsentDetail,
    ConsentImport,
    ConsentRecord,
    ConsentUpdate,
    Contact,
    ContactBulk,
    ContactImport,
    Customer,
    CustomerUsage,
    DeletedAutomation,
    DeletedContact,
    DeletedCustomer,
    DeletedWebhookEndpoint,
    CreatedWebhookEndpoint,
    Event,
    EventWait,
    Lookup,
    Message,
    Page,
    PhoneNumber,
    DeletedSchedule,
    Registration,
    Schedule,
    ScheduledMessage,
    TrackedEvent,
    Verification,
    VerificationCheck,
    WebhookEndpoint,
)
from .webhooks import verify_webhook

if TYPE_CHECKING:
    from . import TextKit

# Distinguishes "not passed" from an explicit None (which the API reads as null).
_UNSET: Any = object()


def _compact(**fields: Any) -> Dict[str, Any]:
    return {k: v for k, v in fields.items() if v is not _UNSET and v is not None}


def _paginate(fetch: Callable[[Optional[str]], Page]) -> Iterator[Any]:
    cursor: Optional[str] = None
    while True:
        page = fetch(cursor)
        yield from page["data"]
        if not page.get("has_more") or not page.get("next_cursor"):
            return
        cursor = page["next_cursor"]


class _Resource:
    def __init__(self, client: "TextKit") -> None:
        self._client = client


class Messages(_Resource):
    def send(
        self,
        to: str,
        body: Optional[str] = None,
        *,
        from_: Optional[str] = None,
        text: Optional[str] = None,
        customer_id: Optional[str] = None,
        category: Optional[str] = None,
        quiet_hours: Optional[str] = None,
        consent: Optional[Dict[str, Any]] = None,
        tags: Optional[List[str]] = None,
        idempotency_key: Optional[str] = None,
    ) -> Message:
        """Send an SMS.

        ``text`` is an alias for ``body``. ``from_`` defaults to the client's
        ``default_from``, else your account's only number (looked up once).
        Retries are safe: an Idempotency-Key is generated when you don't pass
        one, so a network blip can never double-send.

        ``category`` (``"marketing"``, ``"transactional"`` or ``"otp"``) can
        make the message stricter, never looser: what a message is comes from
        the from-number's registration and the wording, and one outside its
        registration's use case raises ``campaign_mismatch``. Only marketing
        messages are held or refused outside 8:00am-9:00pm in the recipient's
        local time. ``quiet_hours`` says which: ``"block"`` raises
        ``quiet_hours`` (with ``send_after``), ``"defer"`` holds it until the
        recipient's 8:00am and returns a scheduled message (check
        ``["object"]``).

        ``consent`` (``{"source": "checkout", "collected_at": "..."}``,
        plus ``page_url`` for a web form) records how the recipient agreed,
        for a recurring non-marketing message from a registered number that
        has no opt-in on file yet. It never counts for marketing.

        ``tags`` (up to 10, e.g. ``["spring-sale"]``) are your own labels: on
        the message, on its webhook events, and in deliverability by tag.
        """
        content = body if body is not None else text
        if content is None:
            raise TextKitError("Pass the message as `body` (or `text`).", code="invalid_request", status=0, param="body")
        payload = _compact(
            to=to,
            body=content,
            customer_id=customer_id,
            category=category,
            quiet_hours=quiet_hours,
            consent=consent,
            tags=tags,
            **{"from": from_ or self._client._resolve_from()},
        )
        return cast(
            Message,
            self._client._request(
                "POST",
                "/messages",
                body=payload,
                idempotency_key=idempotency_key or new_idempotency_key(),
                retryable=True,
            ),
        )

    def schedule(
        self,
        to: str,
        body: str,
        send_at: Union[datetime, str],
        *,
        from_: Optional[str] = None,
        customer_id: Optional[str] = None,
        category: Optional[str] = None,
        quiet_hours: Optional[str] = None,
        tags: Optional[List[str]] = None,
    ) -> ScheduledMessage:
        """Queue a message for later (up to 30 days ahead)."""
        if isinstance(send_at, datetime):
            when = send_at if send_at.tzinfo else send_at.replace(tzinfo=timezone.utc)
            send_at = when.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
        payload = _compact(
            to=to,
            body=body,
            scheduled_at=send_at,
            customer_id=customer_id,
            category=category,
            quiet_hours=quiet_hours,
            tags=tags,
            **{"from": from_ or self._client._resolve_from()},
        )
        return cast(ScheduledMessage, self._client._request("POST", "/messages", body=payload))

    def get(self, id: str) -> Message:
        return cast(Message, self._client._request("GET", f"/messages/{_quote(id)}", retryable=True))

    def list(
        self,
        *,
        limit: Optional[int] = None,
        cursor: Optional[str] = None,
        number: Optional[str] = None,
        customer_id: Optional[str] = None,
        schedule_id: Optional[str] = None,
        tag: Optional[str] = None,
        status: Optional[str] = None,
        blocked_reason: Optional[str] = None,
        failure_code: Optional[str] = None,
    ) -> Page:
        """One page of messages, newest first. ``schedule_id`` keeps only the
        occurrences of one recurring schedule. ``status="blocked"`` lists the
        sends a check refused; ``blocked_reason`` narrows to one reason."""
        q = _query(
            {
                "limit": limit,
                "cursor": cursor,
                "number": number,
                "customer_id": customer_id,
                "schedule_id": schedule_id,
                "tag": tag,
                "status": status,
                "blocked_reason": blocked_reason,
                "failure_code": failure_code,
            }
        )
        return cast(Page, self._client._request("GET", f"/messages{q}", retryable=True))

    def list_all(
        self, *, limit: Optional[int] = None, number: Optional[str] = None, customer_id: Optional[str] = None
    ) -> Iterator[Message]:
        """Every message, newest first, fetching pages as you iterate."""
        return _paginate(lambda c: self.list(limit=limit, cursor=c, number=number, customer_id=customer_id))


class Verify(_Resource):
    def send(
        self,
        to: str,
        *,
        channel: Optional[str] = None,
        app_name: Optional[str] = None,
        from_: Optional[str] = None,
        customer_id: Optional[str] = None,
        user_ip: Optional[str] = None,
    ) -> Verification:
        """Send a one-time code. You don't need to own a number.

        With ``channel="email"``, ``to`` is an email address and the code goes by email.
        """
        if channel == "email":
            payload = _compact(channel="email", email=to, app_name=app_name, customer_id=customer_id, user_ip=user_ip)
        else:
            payload = _compact(to=to, channel=channel, app_name=app_name, customer_id=customer_id, user_ip=user_ip, **{"from": from_})
        return cast(Verification, self._client._request("POST", "/verify", body=payload))

    def check(self, to: str, code: str) -> VerificationCheck:
        """Check a code. ``to`` is where the code went.

        The phone for a texted code, the email address for an emailed one.
        After ``fallback`` the code went by email, so check it by the address;
        a check by phone raises ``invalid_state`` (409). You are billed only
        when ``verified`` is true.
        """
        body = {"email": to, "code": code} if "@" in to else {"to": to, "code": code}
        return cast(VerificationCheck, self._client._request("POST", "/verify/check", body=body))

    def fallback(self, id: str, *, email: str, user_ip: Optional[str] = None) -> Verification:
        """The text didn't arrive: email a new code for the same verification.

        One id, one charge. The emailed code replaces the texted one. Once per
        verification, while it is pending.
        """
        payload = _compact(channel="email", email=email, user_ip=user_ip)
        return cast(Verification, self._client._request("POST", f"/verify/{_quote(id)}/fallback", body=payload))

    def get(self, id: str) -> Verification:
        return cast(Verification, self._client._request("GET", f"/verify/{_quote(id)}", retryable=True))


class Numbers(_Resource):
    def request(self, type: str, *, business_name: str, monthly_volume: str, use_case: str) -> Dict[str, Any]:
        """Ask our team for a short code (``type="short_code"``) or a toll-free
        number they set up. Provisions nothing by itself: carriers take 8-12
        weeks to approve a short code. ``monthly_volume`` is ``under_1k``,
        ``1k_10k``, ``10k_100k`` or ``over_100k``."""
        payload = {"type": type, "business_name": business_name, "monthly_volume": monthly_volume, "use_case": use_case}
        return cast(Dict[str, Any], self._client._request("POST", "/numbers/requests", body=payload))

    def requests(self) -> Page:
        """Open short-code and toll-free requests."""
        return cast(Page, self._client._request("GET", "/numbers/requests", retryable=True))

    def available(self, *, area_code: Optional[str] = None) -> Page:
        q = _query({"area_code": area_code})
        return cast(Page, self._client._request("GET", f"/numbers/available{q}", retryable=True))

    def buy(self, phone_number: str, *, customer_id: Optional[str] = None) -> PhoneNumber:
        payload = _compact(phone_number=phone_number, customer_id=customer_id)
        return cast(PhoneNumber, self._client._request("POST", "/numbers", body=payload))

    def list(self, *, customer_id: Optional[str] = None) -> Page:
        q = _query({"customer_id": customer_id})
        return cast(Page, self._client._request("GET", f"/numbers{q}", retryable=True))

    def update(self, phone_number: str, *, customer_id: Optional[str]) -> PhoneNumber:
        """Assign a number to a customer, or pass ``customer_id=None`` to unassign it."""
        return cast(
            PhoneNumber,
            self._client._request(
                "PATCH", f"/numbers/{_quote(phone_number)}", body={"customer_id": customer_id}, retryable=True
            ),
        )

    def release(self, phone_number: str) -> PhoneNumber:
        return cast(PhoneNumber, self._client._request("DELETE", f"/numbers/{_quote(phone_number)}"))


class BalanceResource(_Resource):
    def get(self) -> Dict[str, Any]:
        """Your prepaid credit balance and auto-recharge setting."""
        return cast(Dict[str, Any], self._client._request("GET", "/balance", retryable=True))


class Links(_Resource):
    def create(self, url: str, *, name: Optional[str] = None) -> Dict[str, Any]:
        """A tracked link to copy anywhere. The same url again returns the same link."""
        body: Dict[str, Any] = {"url": url}
        if name is not None:
            body["name"] = name
        return cast(Dict[str, Any], self._client._request("POST", "/links", body=body))

    def list(self) -> Dict[str, Any]:
        """Every tracked destination with its clicks and conversions."""
        return cast(Dict[str, Any], self._client._request("GET", "/links", retryable=True))


class Conversions(_Resource):
    def create(
        self,
        click_id: str,
        *,
        value_cents: Optional[int] = None,
        name: Optional[str] = None,
        external_id: Optional[str] = None,
    ) -> Dict[str, Any]:
        """Report a sale. click_id is the tk value on the landing page URL."""
        body: Dict[str, Any] = {"click_id": click_id}
        if value_cents is not None:
            body["value_cents"] = value_cents
        if name is not None:
            body["name"] = name
        if external_id is not None:
            body["external_id"] = external_id
        return cast(Dict[str, Any], self._client._request("POST", "/conversions", body=body))

    def list(self) -> Dict[str, Any]:
        """The latest 100 conversions."""
        return cast(Dict[str, Any], self._client._request("GET", "/conversions", retryable=True))


class LookupResource(_Resource):
    def phone(self, phone_number: str) -> Lookup:
        """Carrier and line type for a number."""
        return cast(Lookup, self._client._request("GET", f"/lookup/{_quote(phone_number)}", retryable=True))


class Events(_Resource):
    def list(self, *, limit: Optional[int] = None, cursor: Optional[str] = None, type: Optional[str] = None) -> Page:
        q = _query({"limit": limit, "cursor": cursor, "type": type})
        return cast(Page, self._client._request("GET", f"/events{q}", retryable=True))

    def list_all(self, *, limit: Optional[int] = None, type: Optional[str] = None) -> Iterator[Event]:
        return _paginate(lambda c: self.list(limit=limit, cursor=c, type=type))

    def wait(self, *, cursor: Optional[str] = None, timeout: Optional[int] = None) -> EventWait:
        """Long-poll for new events. Call once with no cursor to get a cursor
        that means "from now", then keep calling with the cursor each answer
        hands back: the request is held until an event arrives or ``timeout``
        seconds pass (0-25, default 20). An event can be returned twice;
        de-duplicate by ``id``. Keep ``timeout`` below the client's own
        ``timeout`` (30 seconds by default)."""
        q = _query({"cursor": cursor, "timeout": timeout})
        return cast(EventWait, self._client._request("GET", f"/events/wait{q}", retryable=True))

    def track(
        self,
        event: str,
        *,
        user_id: Optional[str] = None,
        phone: Optional[str] = None,
        properties: Optional[Mapping[str, Any]] = None,
        idempotency_key: Optional[str] = None,
    ) -> TrackedEvent:
        """Tell TextKit something happened in your app. Automations listening
        for the event start (or move on) for that person. Pass ``phone``,
        ``user_id``, or both; a call with both links them, so later calls need
        only ``user_id``. Retries are safe: an Idempotency-Key is generated
        when you don't supply one."""
        payload = _compact(
            event=event, user_id=user_id, phone=phone, properties=dict(properties) if properties else None
        )
        return cast(
            TrackedEvent,
            self._client._request(
                "POST", "/track", body=payload, idempotency_key=idempotency_key or new_idempotency_key(), retryable=True
            ),
        )


class Webhooks:
    """Webhook endpoints (where events are POSTed), and signature verification.

    ``create`` returns the signing ``secret`` once; keep it, the API never
    shows it again (the console can). A restricted key needs the
    ``webhooks:write`` scope.
    """

    def __init__(self, client: Optional["TextKit"] = None) -> None:
        self._client = client

    @staticmethod
    def verify(
        payload: Union[str, bytes],
        signature: Any,
        secret: str,
        *,
        tolerance: int = 300,
        now: Optional[int] = None,
    ) -> Dict[str, Any]:
        """Same as the module-level ``verify_webhook``."""
        return verify_webhook(payload, signature, secret, tolerance=tolerance, now=now)

    def _c(self) -> "TextKit":
        if self._client is None:
            raise TextKitError("Call this on a client: TextKit(...).webhooks", code="invalid_request", status=0)
        return self._client

    def list(self) -> Page:
        return cast(Page, self._c()._request("GET", "/webhooks", retryable=True))

    def create(
        self, url: str, *, events: Union[str, List[str], None] = None, description: Optional[str] = None
    ) -> CreatedWebhookEndpoint:
        """Register an endpoint. ``events`` omitted (or ``"*"``) subscribes to everything."""
        payload = _compact(url=url, events=events, description=description)
        return cast(CreatedWebhookEndpoint, self._c()._request("POST", "/webhooks", body=payload))

    def get(self, id: str) -> WebhookEndpoint:
        return cast(WebhookEndpoint, self._c()._request("GET", f"/webhooks/{_quote(id)}", retryable=True))

    def update(
        self,
        id: str,
        *,
        url: Any = _UNSET,
        events: Any = _UNSET,
        active: Any = _UNSET,
        description: Any = _UNSET,
    ) -> WebhookEndpoint:
        """Change any of ``url``, ``events``, ``active`` (``False`` pauses
        delivery) or ``description`` (``None`` clears it)."""
        payload = {
            k: v
            for k, v in {"url": url, "events": events, "active": active, "description": description}.items()
            if v is not _UNSET
        }
        return cast(WebhookEndpoint, self._c()._request("PATCH", f"/webhooks/{_quote(id)}", body=payload))

    def delete(self, id: str) -> DeletedWebhookEndpoint:
        return cast(DeletedWebhookEndpoint, self._c()._request("DELETE", f"/webhooks/{_quote(id)}"))

    def rotate_secret(self, id: str, *, expire_previous_in: Optional[int] = None) -> Dict[str, Any]:
        """A new signing secret, returned once. ``expire_previous_in`` (seconds,
        up to 7 days) keeps the old secret signing alongside it, so you can
        deploy the new one without dropping events; ``verify`` accepts either."""
        payload = _compact(expire_previous_in=expire_previous_in)
        return cast(Dict[str, Any], self._c()._request("POST", f"/webhooks/{_quote(id)}/rotate_secret", body=payload))

    def test(self, id: str) -> Dict[str, Any]:
        """Send a signed ``test.ping`` to the endpoint now and return what it answered."""
        return cast(Dict[str, Any], self._c()._request("POST", f"/webhooks/{_quote(id)}/test"))

    def replay_failed(self, id: str, *, since: Optional[str] = None, until: Optional[str] = None) -> Dict[str, Any]:
        """Queue every event that failed to reach this endpoint between ``since``
        and ``until`` (default: the last 24 hours; up to 7 days, 50 events a
        call). ``more: True`` means call again."""
        payload = _compact(since=since, until=until)
        return cast(Dict[str, Any], self._c()._request("POST", f"/webhooks/{_quote(id)}/replay", body=payload))


class Consent(_Resource):
    def list(self, *, limit: Optional[int] = None, cursor: Optional[str] = None) -> Page:
        """Your suppression list: numbers currently opted out."""
        q = _query({"limit": limit, "cursor": cursor})
        return cast(Page, self._client._request("GET", f"/consent{q}", retryable=True))

    def list_all(self, *, limit: Optional[int] = None) -> Iterator[ConsentRecord]:
        return _paginate(lambda c: self.list(limit=limit, cursor=c))

    def get(self, phone: str) -> ConsentDetail:
        """Current status plus the append-only history for one number."""
        return cast(ConsentDetail, self._client._request("GET", f"/consent/{_quote(phone)}", retryable=True))

    def opt_out(self, phone: str, *, note: Optional[str] = None) -> ConsentUpdate:
        """Record an opt-out from your own system (CRM, web form, support tool)."""
        return cast(
            ConsentUpdate,
            self._client._request(
                "POST", f"/consent/{_quote(phone)}", body=_compact(status="opted_out", note=note), retryable=True
            ),
        )

    def opt_in(
        self,
        phone: str,
        *,
        note: Optional[str] = None,
        campaign_id: Optional[str] = None,
        proof: Optional[Dict[str, Any]] = None,
    ) -> ConsentUpdate:
        """Record a fresh opt-in. Only with the recipient's consent.

        ``campaign_id`` (a registration id) records it for that registration, which is what a
        marketing send from the registration's numbers looks for. An opt-in for a marketing or
        mixed registration must carry ``proof`` (see ``OptInProof``), and so must one for a
        number that opted out, collected at or after the opt-out (409 otherwise)."""
        return cast(
            ConsentUpdate,
            self._client._request(
                "POST",
                f"/consent/{_quote(phone)}",
                body=_compact(status="opted_in", note=note, campaign_id=campaign_id, proof=proof),
                retryable=True,
            ),
        )

    def import_(self, phone_numbers: List[str]) -> ConsentImport:
        """Bulk-import opt-outs (up to 500 per call). ``import`` is a keyword, hence the underscore."""
        return cast(
            ConsentImport,
            self._client._request("POST", "/consent/import", body={"phone_numbers": list(phone_numbers)}, retryable=True),
        )

    def export(self) -> str:
        """The whole suppression list as CSV text."""
        return cast(str, self._client._request("GET", "/consent/export", retryable=True, raw=True))


class Customers(_Resource):
    """The businesses you send on behalf of (for platforms). Entirely optional."""

    def create(
        self,
        *,
        name: Optional[str] = None,
        external_id: Optional[str] = None,
        metadata: Optional[Mapping[str, str]] = None,
    ) -> Customer:
        payload = _compact(name=name, external_id=external_id, metadata=dict(metadata) if metadata else None)
        return cast(Customer, self._client._request("POST", "/customers", body=payload))

    def get(self, id: str) -> Customer:
        return cast(Customer, self._client._request("GET", f"/customers/{_quote(id)}", retryable=True))

    def update(
        self,
        id: str,
        *,
        name: Optional[str] = _UNSET,
        external_id: Optional[str] = _UNSET,
        metadata: Optional[Mapping[str, str]] = _UNSET,
    ) -> Customer:
        """Change only the fields you pass; pass None to clear one. ``metadata`` replaces the whole object."""
        payload: Dict[str, Any] = {}
        if name is not _UNSET:
            payload["name"] = name
        if external_id is not _UNSET:
            payload["external_id"] = external_id
        if metadata is not _UNSET:
            payload["metadata"] = dict(metadata) if metadata is not None else None
        return cast(Customer, self._client._request("PATCH", f"/customers/{_quote(id)}", body=payload, retryable=True))

    def delete(self, id: str) -> DeletedCustomer:
        """Delete a customer. Its numbers stay yours, unassigned."""
        return cast(DeletedCustomer, self._client._request("DELETE", f"/customers/{_quote(id)}"))

    def list(
        self, *, limit: Optional[int] = None, cursor: Optional[str] = None, external_id: Optional[str] = None
    ) -> Page:
        q = _query({"limit": limit, "cursor": cursor, "external_id": external_id})
        return cast(Page, self._client._request("GET", f"/customers{q}", retryable=True))

    def list_all(self, *, limit: Optional[int] = None) -> Iterator[Customer]:
        return _paginate(lambda c: self.list(limit=limit, cursor=c))

    def usage(self, id: str, *, start: Optional[str] = None, end: Optional[str] = None) -> CustomerUsage:
        """Usage for a UTC date range (``YYYY-MM-DD``; default this month to date).
        Follows the key: test keys report sandbox traffic, live keys live."""
        q = _query({"start": start, "end": end})
        return cast(CustomerUsage, self._client._request("GET", f"/customers/{_quote(id)}/usage{q}", retryable=True))


class Contacts(_Resource):
    """The address book. One contact per phone number; tags double as broadcast audiences."""

    def upsert(
        self,
        phone_number: str,
        *,
        name: Optional[str] = None,
        tags: Optional[List[str]] = None,
        fields: Optional[Mapping[str, str]] = None,
        notes: Optional[str] = None,
    ) -> Contact:
        """Create a contact, or update the one that already has this number.
        Values you leave out are kept; tags are added, never removed."""
        payload = _compact(
            phone_number=phone_number, name=name, tags=tags, fields=dict(fields) if fields else None, notes=notes
        )
        return cast(Contact, self._client._request("POST", "/contacts", body=payload, retryable=True))

    def import_(self, contacts: List[Mapping[str, Any]]) -> ContactImport:
        """Upsert up to 500 contacts in one call. Each item is a dict with
        ``phone_number`` and optional ``name``, ``tags``, ``fields``, ``notes``."""
        body = {"contacts": [dict(c) for c in contacts]}
        return cast(ContactImport, self._client._request("POST", "/contacts/import", body=body, retryable=True))

    def consent(self, phone_number: str) -> ConsentDetail:
        """Consent for a phone number: whether you may text it, when and how it
        opted out, and its full history. Same as ``consent.get(phone_number)``."""
        return self._client.consent.get(phone_number)

    def bulk(self, action: str, ids: List[str], *, tags: Optional[List[str]] = None) -> ContactBulk:
        """Apply ``add_tags``, ``remove_tags`` or ``delete`` to up to 500 contact ids in one call."""
        payload = _compact(action=action, ids=list(ids), tags=tags)
        return cast(ContactBulk, self._client._request("POST", "/contacts/bulk", body=payload))

    def get(self, id: str) -> Contact:
        return cast(Contact, self._client._request("GET", f"/contacts/{_quote(id)}", retryable=True))

    def update(
        self,
        id: str,
        *,
        phone_number: str = _UNSET,
        name: Optional[str] = _UNSET,
        tags: List[str] = _UNSET,
        fields: Mapping[str, str] = _UNSET,
        notes: Optional[str] = _UNSET,
    ) -> Contact:
        """Change only the fields you pass. ``tags`` and ``fields`` replace what is
        stored; pass None to clear ``name`` or ``notes``."""
        payload: Dict[str, Any] = {}
        if phone_number is not _UNSET:
            payload["phone_number"] = phone_number
        if name is not _UNSET:
            payload["name"] = name
        if tags is not _UNSET:
            payload["tags"] = list(tags)
        if fields is not _UNSET:
            payload["fields"] = dict(fields)
        if notes is not _UNSET:
            payload["notes"] = notes
        return cast(Contact, self._client._request("PATCH", f"/contacts/{_quote(id)}", body=payload, retryable=True))

    def delete(self, id: str) -> DeletedContact:
        return cast(DeletedContact, self._client._request("DELETE", f"/contacts/{_quote(id)}"))

    def list(
        self,
        *,
        limit: Optional[int] = None,
        cursor: Optional[str] = None,
        tag: Optional[str] = None,
        phone_number: Optional[str] = None,
    ) -> Page:
        """Newest first. ``phone_number`` finds the one contact holding it."""
        q = _query({"limit": limit, "cursor": cursor, "tag": tag, "phone_number": phone_number})
        return cast(Page, self._client._request("GET", f"/contacts{q}", retryable=True))

    def list_all(self, *, limit: Optional[int] = None, tag: Optional[str] = None) -> Iterator[Contact]:
        return _paginate(lambda c: self.list(limit=limit, cursor=c, tag=tag))


class Automations(_Resource):
    """Event-driven flows: a trigger event, then send / wait / branch steps."""

    @staticmethod
    def _payload(name: Any, from_: Any, topic_id: Any, trigger: Any, steps: Any, category: Any = _UNSET) -> Dict[str, Any]:
        payload: Dict[str, Any] = {}
        if name is not _UNSET:
            payload["name"] = name
        if from_ is not _UNSET:
            payload["from"] = from_
        if topic_id is not _UNSET:
            payload["topic_id"] = topic_id
        if category is not _UNSET:
            payload["category"] = category
        if trigger is not _UNSET:
            payload["trigger"] = dict(trigger)
        if steps is not _UNSET:
            payload["steps"] = [dict(s) for s in steps]
        return payload

    def create(
        self,
        *,
        name: str,
        trigger: Mapping[str, Any],
        steps: List[Mapping[str, Any]],
        from_: Optional[str] = _UNSET,
        topic_id: Optional[str] = _UNSET,
        category: Optional[str] = _UNSET,
    ) -> Automation:
        """Create a flow as a draft. ``issues`` on the result lists what stops it from running."""
        payload = self._payload(name, from_, topic_id, trigger, steps, category)
        return cast(Automation, self._client._request("POST", "/automations", body=payload))

    def get(self, id: str) -> Automation:
        return cast(Automation, self._client._request("GET", f"/automations/{_quote(id)}", retryable=True))

    def list(self) -> Page:
        return cast(Page, self._client._request("GET", "/automations", retryable=True))

    def update(
        self,
        id: str,
        *,
        name: str = _UNSET,
        trigger: Mapping[str, Any] = _UNSET,
        steps: List[Mapping[str, Any]] = _UNSET,
        from_: Optional[str] = _UNSET,
        topic_id: Optional[str] = _UNSET,
        category: Optional[str] = _UNSET,
    ) -> Automation:
        """Change only the fields you pass. Editing an active flow publishes a new version."""
        payload = self._payload(name, from_, topic_id, trigger, steps, category)
        return cast(Automation, self._client._request("PATCH", f"/automations/{_quote(id)}", body=payload))

    def delete(self, id: str) -> DeletedAutomation:
        """Delete a flow. Runs in progress stop; nothing more is sent."""
        return cast(DeletedAutomation, self._client._request("DELETE", f"/automations/{_quote(id)}"))

    def activate(self, id: str) -> Automation:
        """Turn a flow on. Raises ``invalid_request`` when it is not ready."""
        return cast(Automation, self._client._request("POST", f"/automations/{_quote(id)}/activate", retryable=True))

    def pause(self, id: str) -> Automation:
        """Stop new runs and hold the ones in progress until it is activated again."""
        return cast(Automation, self._client._request("POST", f"/automations/{_quote(id)}/pause", retryable=True))

    def runs(self, id: str, *, limit: Optional[int] = None, cursor: Optional[str] = None) -> Page:
        """Runs of one flow, newest first."""
        q = _query({"limit": limit, "cursor": cursor})
        return cast(Page, self._client._request("GET", f"/automations/{_quote(id)}/runs{q}", retryable=True))

    def run(self, id: str, run_id: str) -> AutomationRun:
        return cast(
            AutomationRun,
            self._client._request("GET", f"/automations/{_quote(id)}/runs/{_quote(run_id)}", retryable=True),
        )

    def cancel_run(self, id: str, run_id: str) -> AutomationRun:
        """Cancel a run in progress."""
        return cast(
            AutomationRun, self._client._request("DELETE", f"/automations/{_quote(id)}/runs/{_quote(run_id)}")
        )


class Schedules(_Resource):
    """Recurring schedules: one message to one number on a repeating local time.

    Each occurrence is a normal send (opt-outs, quota and spend limit are
    checked when it fires) and a normal message with ``schedule_id``.
    """

    def create(
        self,
        to: str,
        body: str,
        repeat: Mapping[str, Any],
        *,
        from_: Optional[str] = None,
        start_date: Optional[str] = None,
        end_date: Optional[str] = None,
        max_occurrences: Optional[int] = None,
        idempotency_key: Optional[str] = None,
    ) -> Schedule:
        """Create a schedule.

        ``repeat`` is ``{"frequency": "daily" | "weekly" | "monthly", "time":
        "08:00", "timezone": "America/New_York"}`` plus ``days_of_week`` for
        weekly or ``day_of_month`` for monthly. ``from_`` falls back to the
        client's ``default_from``; left out entirely, the API uses your
        account's one number for the key's mode. Retries are safe: an
        Idempotency-Key is generated when you don't pass one.
        """
        sender = from_ or self._client._default_from
        payload = _compact(
            to=to,
            body=body,
            repeat=dict(repeat),
            start_date=start_date,
            end_date=end_date,
            max_occurrences=max_occurrences,
            **({"from": sender} if sender else {}),
        )
        return cast(
            Schedule,
            self._client._request(
                "POST",
                "/schedules",
                body=payload,
                idempotency_key=idempotency_key or new_idempotency_key(),
                retryable=True,
            ),
        )

    def get(self, id: str) -> Schedule:
        """One schedule, with its ``recent_occurrences``."""
        return cast(Schedule, self._client._request("GET", f"/schedules/{_quote(id)}", retryable=True))

    def list(self) -> Page:
        return cast(Page, self._client._request("GET", "/schedules", retryable=True))

    def update(
        self,
        id: str,
        *,
        to: Any = _UNSET,
        from_: Any = _UNSET,
        body: Any = _UNSET,
        repeat: Any = _UNSET,
        start_date: Any = _UNSET,
        end_date: Any = _UNSET,
        max_occurrences: Any = _UNSET,
        active: Any = _UNSET,
    ) -> Schedule:
        """Change a schedule. Pass ``None`` for ``start_date``, ``end_date`` or
        ``max_occurrences`` to clear it; ``repeat`` replaces the whole object."""
        fields = {
            "to": to,
            "from": from_,
            "body": body,
            "repeat": repeat,
            "start_date": start_date,
            "end_date": end_date,
            "max_occurrences": max_occurrences,
            "active": active,
        }
        payload = {k: v for k, v in fields.items() if v is not _UNSET}
        return cast(
            Schedule, self._client._request("PATCH", f"/schedules/{_quote(id)}", body=payload, retryable=True)
        )

    def pause(self, id: str) -> Schedule:
        """Stop sending until resumed."""
        return self.update(id, active=False)

    def resume(self, id: str) -> Schedule:
        """Start again from now: nothing that came due while paused is sent."""
        return self.update(id, active=True)

    def delete(self, id: str) -> DeletedSchedule:
        """Stop it for good. Messages it already sent stay in the message log."""
        return cast(DeletedSchedule, self._client._request("DELETE", f"/schedules/{_quote(id)}"))


class Registrations(_Resource):
    """Brand and campaign registrations (Compliance).

    ``create`` runs the website and example checks; ``recheck`` corrects and
    re-runs them; ``submit`` files a ready registration. The first submit for
    a business carries the attestation signed by someone authorized to act
    for it (``attestation={"signer_name": ..., "signer_title": ...,
    "accepted": True}``); without one on file the API answers
    ``attestation_required``.
    """

    def create(self, *, business_name: str, website: str, use_case: str, **fields: Any) -> Registration:
        """Create a registration. Runs the website check right away. Any other
        registration field (``opt_in_url``, ``sample_messages``, ``brand``, ...)
        goes in ``fields``."""
        payload = _compact(business_name=business_name, website=website, use_case=use_case, **fields)
        return cast(Registration, self._client._request("POST", "/registrations", body=payload))

    def get(self, id: str) -> Registration:
        return cast(Registration, self._client._request("GET", f"/registrations/{_quote(id)}", retryable=True))

    def list(self) -> Page:
        return cast(Page, self._client._request("GET", "/registrations", retryable=True))

    def recheck(self, id: str, **fields: Any) -> Registration:
        """Correct any field and re-run the checks (draft, checks_failed, ready or rejected)."""
        return cast(Registration, self._client._request("POST", f"/registrations/{_quote(id)}/recheck", body=dict(fields)))

    def submit(self, id: str, *, fees_acknowledged: bool, attestation: Optional[Mapping[str, Any]] = None) -> Registration:
        """Submit a ready registration (or resubmit after a rejection).

        ``fees_acknowledged`` must be ``True``: it confirms the registration
        fee terms (Terms §4.3): carrier registration fees are separate from
        the per-message rate and billed at the registry's charge, a campaign carries a 3-month
        minimum, and the fees are non-refundable even if the registration is
        rejected. Without it the API answers 400 ``invalid_request`` (param
        ``fees_acknowledged``); the acknowledgment is kept on the filed copy.

        Pass ``attestation`` the first time for a business, or after our team
        could not verify it; later submits for the same business need none.
        The submission is held while we verify the business, then filed.
        """
        payload = _compact(attestation=dict(attestation) if attestation else None)
        payload["fees_acknowledged"] = fees_acknowledged is True
        return cast(Registration, self._client._request("POST", f"/registrations/{_quote(id)}/submit", body=payload))

    def submissions(self, id: str) -> Page:
        """The filed copies, oldest first: exactly what each submission sent."""
        return cast(Page, self._client._request("GET", f"/registrations/{_quote(id)}/submissions", retryable=True))


__all__ = [
    "Automations",
    "Registrations",
    "Schedules",
    "Contacts",
    "Messages",
    "Verify",
    "Numbers",
    "BalanceResource",
    "LookupResource",
    "Links",
    "Conversions",
    "Events",
    "Consent",
    "Customers",
    "AvailableNumber",
]
