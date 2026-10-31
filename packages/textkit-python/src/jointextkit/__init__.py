"""jointextkit - the official Python client for TextKit (jointextkit.com).

SMS, phone verification, and phone numbers. Standard library only.

    from jointextkit import TextKit

    client = TextKit()  # reads TEXTKIT_API_KEY
    client.messages.send(to="+15005550006", text="Hello from TextKit")

TextKit was called SimpleSMS until 2026-10-28 (PyPI ``joinsimplesms``), and
Delivered before that. ``SimpleSMS``/``SimpleSMSError`` and
``Delivered``/``DeliveredError`` are kept as deprecated aliases of ``TextKit``
and ``TextKitError``, and the ``SIMPLESMS_*`` and ``DELIVERED_*`` names
(``_API_KEY``, ``_BASE_URL``, ``_FROM``) are still read when the
``TEXTKIT_*`` names are unset.
"""
from __future__ import annotations

import os
import threading
import time
from typing import Any, Callable, Dict, Optional, Union

from ._client import BaseClient, Response, Transport, _env, urllib_transport
from ._errors import TextKitError
from ._resources import (
    Automations,
    BalanceResource,
    Consent,
    Contacts,
    Conversions,
    Customers,
    Events,
    Links,
    LookupResource,
    Messages,
    Numbers,
    Registrations,
    Schedules,
    Verify,
    Webhooks,
)
from ._version import VERSION
from .webhooks import EVENT_ID_HEADERS, SIGNATURE_HEADERS, event_id_from_headers, signature_from_headers, verify_webhook


class TextKit(BaseClient):
    """The TextKit client.

    :param api_key: defaults to the ``TEXTKIT_API_KEY`` environment variable.
    :param default_from: the number ``messages.send`` uses when you omit
        ``from_``. Defaults to ``TEXTKIT_FROM``, else your account's only
        active number (looked up once; an error if you have several).
    :param base_url: defaults to ``https://api.jointextkit.com``.
    :param max_retries: retries for transient failures (429, 5xx, network).
    :param timeout: per-request timeout, seconds.
    :param transport: swap the HTTP layer (tests, tracing, proxies).
    """

    #: ``TextKit.webhooks.verify(...)`` works without a client; an instance
    #: gets its own ``webhooks`` with the endpoint methods too.
    webhooks: Webhooks = Webhooks()

    def __init__(
        self,
        api_key: Optional[str] = None,
        *,
        default_from: Optional[str] = None,
        base_url: Optional[str] = None,
        max_retries: int = 2,
        timeout: float = 30.0,
        transport: Optional[Transport] = None,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        super().__init__(
            api_key, base_url=base_url, max_retries=max_retries, timeout=timeout, transport=transport, sleep=sleep
        )
        self._default_from = default_from or _env("TEXTKIT_FROM", "SIMPLESMS_FROM", "DELIVERED_FROM")
        self._from_lock = threading.Lock()
        self.messages = Messages(self)
        self.verify = Verify(self)
        self.numbers = Numbers(self)
        self.lookup = LookupResource(self)
        self.links = Links(self)
        self.conversions = Conversions(self)
        self.balance = BalanceResource(self)
        self.events = Events(self)
        self.consent = Consent(self)
        self.customers = Customers(self)
        self.contacts = Contacts(self)
        self.automations = Automations(self)
        self.schedules = Schedules(self)
        self.registrations = Registrations(self)
        self.webhooks = Webhooks(self)

    def _resolve_from(self) -> str:
        if self._default_from:
            return self._default_from
        with self._from_lock:
            if not self._default_from:
                active = [n["phone_number"] for n in self.numbers.list()["data"] if n.get("status") == "active"]
                if len(active) != 1:
                    raise TextKitError(
                        "Pass from_=... (or set TEXTKIT_FROM): your account has "
                        + (f"{len(active)} numbers." if active else "no numbers yet."),
                        code="invalid_request",
                        status=0,
                        param="from",
                    )
                self._default_from = active[0]
        return self._default_from


#: Deprecated alias of :class:`TextKit` (the product's name until 2026-10).
#: The same class, so existing ``from ... import Delivered`` code keeps working.
Delivered = TextKit
#: Deprecated alias of :class:`TextKitError`; ``except DeliveredError`` still catches.
DeliveredError = TextKitError
#: Deprecated alias of :class:`TextKit` (the product's name until 2026-10-28).
SimpleSMS = TextKit
#: Deprecated alias of :class:`TextKitError`; ``except SimpleSMSError`` still catches.
SimpleSMSError = TextKitError

__version__ = VERSION

__all__ = [
    "TextKit",
    "TextKitError",
    "Delivered",
    "DeliveredError",
    "SimpleSMS",
    "SimpleSMSError",
    "verify_webhook",
    "signature_from_headers",
    "event_id_from_headers",
    "SIGNATURE_HEADERS",
    "EVENT_ID_HEADERS",
    "Response",
    "Transport",
    "urllib_transport",
    "VERSION",
    "__version__",
]
