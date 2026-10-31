from __future__ import annotations

from typing import Optional


class TextKitError(Exception):
    """Every failure the client raises.

    ``code`` is the API's machine-readable error code (``"rate_limited"``,
    ``"invalid_request"``, ...), plus two the client adds itself:
    ``"connection_error"`` (the API was unreachable or timed out) and
    ``"invalid_signature"`` (a webhook failed verification).
    """

    def __init__(
        self,
        message: str,
        *,
        code: str,
        status: int,
        param: Optional[str] = None,
        retry_after: Optional[float] = None,
        reason: Optional[str] = None,
        balance_micro_usd: Optional[int] = None,
        required_micro_usd: Optional[int] = None,
        top_up_url: Optional[str] = None,
        send_after: Optional[str] = None,
        recipient_local_time: Optional[str] = None,
        timezone: Optional[str] = None,
        message_id: Optional[str] = None,
    ) -> None:
        super().__init__(message)
        self.message = message
        self.code = code
        self.status = status
        #: Which request field was wrong, when the API could tell.
        self.param = param
        #: Seconds to wait, on rate limits.
        self.retry_after = retry_after
        #: Why a verification was blocked.
        self.reason = reason
        #: ``insufficient_credits`` only: your balance, in millionths of a dollar.
        self.balance_micro_usd = balance_micro_usd
        #: ``insufficient_credits`` only: what the call costs, in millionths of a dollar.
        self.required_micro_usd = required_micro_usd
        #: ``insufficient_credits`` only: where to add credits.
        self.top_up_url = top_up_url
        #: ``quiet_hours`` only: when the message may be sent (ISO timestamp).
        self.send_after = send_after
        #: ``quiet_hours`` only: the recipient's local time, 24-hour "HH:MM".
        self.recipient_local_time = recipient_local_time
        #: ``quiet_hours`` only: the IANA time zone read from the number's area code.
        self.timezone = timezone
        #: The blocked message stored in your log for this refusal, when there is one.
        self.message_id = message_id

    @property
    def retryable(self) -> bool:
        """True when retrying the same call later could plausibly succeed."""
        return (
            self.status >= 500
            or self.code in ("rate_limited", "idempotency_in_progress", "carrier_error", "connection_error")
        )

    def __repr__(self) -> str:
        return f"TextKitError(code={self.code!r}, status={self.status}, message={self.message!r})"
