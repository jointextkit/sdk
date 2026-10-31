from __future__ import annotations

import json
import os
import random
import socket
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Any, Callable, Dict, Mapping, NamedTuple, Optional

from ._errors import TextKitError
from ._version import VERSION

DEFAULT_BASE_URL = "https://api.jointextkit.com"


class Response(NamedTuple):
    status: int
    #: Header names lowercased.
    headers: Mapping[str, str]
    body: bytes


#: (method, url, headers, body, timeout) -> Response. Raise on network failure.
Transport = Callable[[str, str, Dict[str, str], Optional[bytes], float], Response]


def urllib_transport(
    method: str, url: str, headers: Dict[str, str], body: Optional[bytes], timeout: float
) -> Response:
    """The default transport: the standard library, nothing to install."""
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:  # noqa: S310 (https by default)
            return Response(res.status, {k.lower(): v for k, v in res.headers.items()}, res.read())
    except urllib.error.HTTPError as err:
        # 4xx/5xx still carry the API's JSON error body.
        return Response(err.code, {k.lower(): v for k, v in err.headers.items()}, err.read())


def _query(params: Mapping[str, Any]) -> str:
    pairs = {k: v for k, v in params.items() if v is not None}
    if not pairs:
        return ""
    return "?" + urllib.parse.urlencode({k: str(v).lower() if isinstance(v, bool) else v for k, v in pairs.items()})


def _quote(segment: str) -> str:
    return urllib.parse.quote(segment, safe="")


def _env(*names: str) -> Optional[str]:
    """The first of these environment variables that is set and non-empty.

    The first name is the current one; the rest are deprecated names kept so
    that deployments configured before a rename keep working.
    """
    for name in names:
        value = os.environ.get(name)
        if value:
            return value
    return None


class BaseClient:
    def __init__(
        self,
        api_key: Optional[str] = None,
        *,
        base_url: Optional[str] = None,
        max_retries: int = 2,
        timeout: float = 30.0,
        transport: Optional[Transport] = None,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        # TEXTKIT_API_KEY first; names from before each rename still work.
        key = api_key or _env("TEXTKIT_API_KEY", "SIMPLESMS_API_KEY", "DELIVERED_API_KEY", "RESMS_API_KEY")
        if not key:
            raise TextKitError(
                "No TextKit key. Pass one to TextKit(...) or set TEXTKIT_API_KEY. "
                "Get one free at https://jointextkit.com/console",
                code="invalid_api_key",
                status=0,
            )
        self._api_key = key
        self.base_url = (
            base_url or _env("TEXTKIT_BASE_URL", "SIMPLESMS_BASE_URL", "DELIVERED_BASE_URL", "RESMS_BASE_URL") or DEFAULT_BASE_URL
        ).rstrip("/")
        self.max_retries = max_retries
        self.timeout = timeout
        self._transport: Transport = transport or urllib_transport
        self._sleep = sleep

    @property
    def is_test_mode(self) -> bool:
        """True when this client is using a sandbox key."""
        return self._api_key.startswith((
            ("tk_sk_test_", "ssms_sk_test_", "dsms_sk_test_", "resms_sk_test_")
        ))

    def _request(
        self,
        method: str,
        path: str,
        *,
        body: Optional[Mapping[str, Any]] = None,
        idempotency_key: Optional[str] = None,
        retryable: bool = False,
        raw: bool = False,
    ) -> Any:
        headers = {
            "Authorization": f"Bearer {self._api_key}",
            "User-Agent": f"jointextkit-python/{VERSION}",
            "Accept": "application/json",
        }
        data: Optional[bytes] = None
        if body is not None:
            headers["Content-Type"] = "application/json"
            # Sent as given: resources omit unset fields themselves, so an
            # explicit None (e.g. unassigning a number) reaches the API as null.
            data = json.dumps(dict(body)).encode("utf-8")
        if idempotency_key:
            headers["Idempotency-Key"] = idempotency_key
        url = f"{self.base_url}/v1{path}"

        last: Optional[TextKitError] = None
        for attempt in range(self.max_retries + 1):
            if attempt > 0 and last is not None:
                self._sleep(self._backoff(attempt, last))
            try:
                res = self._transport(method, url, dict(headers), data, self.timeout)
            except (socket.timeout, TimeoutError) as exc:
                last = TextKitError(f"Request timed out after {self.timeout}s", code="connection_error", status=0)
                last.__cause__ = exc
            except (urllib.error.URLError, OSError, ConnectionError) as exc:
                last = TextKitError(f"Could not reach the TextKit API: {exc}", code="connection_error", status=0)
                last.__cause__ = exc
            else:
                if 200 <= res.status < 300:
                    if raw:
                        return res.body.decode("utf-8")
                    return json.loads(res.body.decode("utf-8")) if res.body else {}
                last = self._error_from(res)

            # Retry only what is safe: a POST without an idempotency key is
            # never resent, and a verification cooldown is policy, not a blip.
            if not retryable or not last.retryable:
                break
            if last.code == "rate_limited" and path.startswith("/verify"):
                break
        assert last is not None
        raise last

    @staticmethod
    def _backoff(attempt: int, err: TextKitError) -> float:
        if err.retry_after is not None and err.retry_after >= 0:
            return float(err.retry_after)
        base: float = min(0.25 * float(2**attempt), 4.0)
        return base + random.uniform(0, base / 4)

    @staticmethod
    def _error_from(res: Response) -> TextKitError:
        try:
            payload = json.loads(res.body.decode("utf-8")) if res.body else {}
        except ValueError:
            payload = {}
        err = payload.get("error") if isinstance(payload, dict) else None
        err = err if isinstance(err, dict) else {}
        retry_after: Optional[float] = None
        if err.get("retry_after") is not None:
            retry_after = float(err["retry_after"])
        elif res.headers.get("retry-after"):
            try:
                retry_after = float(res.headers["retry-after"])
            except ValueError:
                retry_after = None
        return TextKitError(
            err.get("message") or f"Request failed with status {res.status}",
            code=err.get("code") or ("internal_error" if res.status >= 500 else "invalid_request"),
            status=res.status,
            param=err.get("param"),
            retry_after=retry_after,
            reason=err.get("reason"),
            balance_micro_usd=err.get("balance_micro_usd"),
            required_micro_usd=err.get("required_micro_usd"),
            top_up_url=err.get("top_up_url"),
            send_after=err.get("send_after"),
            recipient_local_time=err.get("recipient_local_time"),
            timezone=err.get("timezone"),
            message_id=err.get("message_id"),
        )


def new_idempotency_key() -> str:
    return f"sdk_{uuid.uuid4().hex}"


__all__ = ["BaseClient", "Response", "Transport", "urllib_transport", "new_idempotency_key", "_query", "_quote"]
