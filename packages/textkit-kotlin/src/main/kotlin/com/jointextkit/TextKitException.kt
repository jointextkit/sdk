package com.jointextkit

/**
 * Every failure the client throws.
 *
 * [code] is the API's machine-readable error code (`"rate_limited"`,
 * `"invalid_request"`, ...), plus two the client adds itself:
 * `"connection_error"` (the API was unreachable or timed out) and
 * `"invalid_signature"` (a webhook failed verification).
 *
 * Unchecked, so Java callers catch it only where they want to.
 */
class TextKitException @JvmOverloads constructor(
    message: String,
    /** The API's error code, e.g. `"insufficient_credits"`. */
    val code: String,
    /** HTTP status; 0 when the API was never reached (or the client refused the call itself). */
    val status: Int,
    /** Which request field was wrong, when the API could tell. */
    val param: String? = null,
    /** Seconds to wait, on rate limits. */
    val retryAfter: Double? = null,
    /** Why a verification was blocked. */
    val reason: String? = null,
    /** `insufficient_credits` only: your balance, in millionths of a dollar. */
    val balanceMicroUsd: Long? = null,
    /** `insufficient_credits` only: what the call costs, in millionths of a dollar. */
    val requiredMicroUsd: Long? = null,
    /** `insufficient_credits` only: where to add credits. */
    val topUpUrl: String? = null,
    /** `quiet_hours` only: when the message may be sent (ISO timestamp). */
    val sendAfter: String? = null,
    /** `quiet_hours` only: the recipient's local time, 24-hour "HH:MM". */
    val recipientLocalTime: String? = null,
    /** `quiet_hours` only: the IANA time zone read from the number's area code. */
    val timezone: String? = null,
    /** The blocked message stored in your log for this refusal, when there is one. */
    val messageId: String? = null,
    cause: Throwable? = null,
) : RuntimeException(message, cause) {

    /** True when retrying the same call later could plausibly succeed. */
    val isRetryable: Boolean
        get() = status >= 500 || code == "rate_limited" || code == "carrier_error" || code == "connection_error"

    override fun toString(): String = "TextKitException(code=$code, status=$status, message=$message)"
}
