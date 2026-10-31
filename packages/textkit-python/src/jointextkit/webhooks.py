"""Webhook signature verification.

Every webhook carries ``textkit-signature: t=<unix seconds>,v1=<hex>`` where
``v1 = HMAC-SHA256(secret, f"{t}.{raw_body}")``. Verify against the raw
request body exactly as received; re-serialized JSON will not match.

The same value is also sent as ``dsms-signature`` and ``resms-signature`` (the
header names from before the product was renamed), so a handler written
against either keeps verifying. ``verify_webhook`` takes the header value, or
the request's whole headers mapping and finds it under any of those names.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import time
from typing import Any, Dict, Mapping, Optional, Sequence, Union

from ._errors import TextKitError

DEFAULT_TOLERANCE = 300

#: Every header name the signature has been sent under, current first.
SIGNATURE_HEADERS = ("textkit-signature", "dsms-signature", "resms-signature")
#: Every header name the event id has been sent under, current first.
EVENT_ID_HEADERS = ("textkit-event-id", "dsms-event-id", "resms-event-id")


def _header(headers: Any, names: Sequence[str]) -> Optional[str]:
    """First of ``names`` present in a headers mapping, case-insensitively."""
    if headers is None:
        return None
    for name in names:
        value = None
        try:
            value = headers.get(name)  # case-insensitive in every web framework
        except Exception:
            value = None
        if value:
            return str(value)
    try:
        lowered = {str(k).lower(): v for k, v in dict(headers).items()}
    except Exception:
        return None
    for name in names:
        if lowered.get(name):
            return str(lowered[name])
    return None


def signature_from_headers(headers: Any) -> Optional[str]:
    """The webhook signature from a request's headers, whichever name it arrived under."""
    return _header(headers, SIGNATURE_HEADERS)


def event_id_from_headers(headers: Any) -> Optional[str]:
    """The event id (``evt_...``, stable across retries) from a request's headers."""
    return _header(headers, EVENT_ID_HEADERS)


def _fail(message: str) -> TextKitError:
    return TextKitError(message, code="invalid_signature", status=400)


def verify_webhook(
    payload: Union[str, bytes],
    signature: Union[str, Mapping[str, Any], None],
    secret: str,
    *,
    tolerance: int = DEFAULT_TOLERANCE,
    now: Optional[int] = None,
) -> Dict[str, Any]:
    """Verify a webhook from TextKit and return the parsed event.

    :param payload: the raw request body (``request.body`` / ``request.data``).
    :param signature: the ``textkit-signature`` header value, or the
        request's headers mapping (``request.headers``): the signature is then
        read from ``textkit-signature``, ``dsms-signature`` or
        ``resms-signature``, whichever is present.
    :param secret: your endpoint's signing secret (``whsec_...``).
    :param tolerance: max age (either direction) in seconds; 0 disables the
        check. Defaults to 300, which stops replays of captured requests.
    :raises TextKitError: with ``code == "invalid_signature"``.
    """
    if not secret:
        raise _fail("No webhook secret given.")
    if signature is not None and not isinstance(signature, str):
        signature = signature_from_headers(signature)
    if not signature:
        raise _fail("Missing textkit-signature header.")

    timestamp: Optional[int] = None
    candidates = []
    for part in signature.split(","):
        key, sep, value = part.partition("=")
        if not sep:
            continue
        key, value = key.strip(), value.strip()
        if key == "t" and value.isdigit():
            timestamp = int(value)
        elif key == "v1":
            candidates.append(value.lower())
    if timestamp is None or not candidates:
        raise _fail("Malformed textkit-signature header.")

    current = int(time.time()) if now is None else now
    if tolerance > 0 and abs(current - timestamp) > tolerance:
        raise _fail("Webhook timestamp is outside the tolerance window.")

    raw = payload.encode("utf-8") if isinstance(payload, str) else bytes(payload)
    expected = hmac.new(
        secret.encode("utf-8"), str(timestamp).encode("ascii") + b"." + raw, hashlib.sha256
    ).hexdigest()
    if not any(hmac.compare_digest(expected, c) for c in candidates):
        raise _fail("Webhook signature does not match.")

    event: Dict[str, Any] = json.loads(raw.decode("utf-8"))
    return event
