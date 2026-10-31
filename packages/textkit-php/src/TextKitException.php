<?php

declare(strict_types=1);

namespace TextKit;

/**
 * Every failure the client throws.
 *
 * `$code` is the API's machine-readable error code ("rate_limited",
 * "invalid_request", ...), plus two the client adds itself:
 * "connection_error" (the API was unreachable or timed out) and
 * "invalid_signature" (a webhook failed verification).
 *
 * The code is a string, so it lives in `$errorCode` (read it with
 * `getErrorCode()`); PHP's own `getCode()` returns the HTTP status.
 */
class TextKitException extends \RuntimeException
{
    /** @param array<string, mixed> $details */
    public function __construct(
        string $message,
        public readonly string $errorCode,
        public readonly int $status = 0,
        /** Which request field was wrong, when the API could tell. */
        public readonly ?string $param = null,
        /** Seconds to wait, on rate limits. */
        public readonly ?float $retryAfter = null,
        /** Why a verification was blocked. */
        public readonly ?string $reason = null,
        /** insufficient_credits only: your balance, in millionths of a dollar. */
        public readonly ?int $balanceMicroUsd = null,
        /** insufficient_credits only: what the call costs, in millionths of a dollar. */
        public readonly ?int $requiredMicroUsd = null,
        /** insufficient_credits only: where to add credits. */
        public readonly ?string $topUpUrl = null,
        /** quiet_hours only: when the message may be sent (ISO timestamp). */
        public readonly ?string $sendAfter = null,
        /** quiet_hours only: the recipient's local time, 24-hour "HH:MM". */
        public readonly ?string $recipientLocalTime = null,
        /** quiet_hours only: the IANA time zone read from the number's area code. */
        public readonly ?string $timezone = null,
        /** The blocked message stored in your log for this refusal, when there is one. */
        public readonly ?string $messageId = null,
        ?\Throwable $previous = null,
    ) {
        parent::__construct($message, $status, $previous);
    }

    public function getErrorCode(): string
    {
        return $this->errorCode;
    }

    /** True when retrying the same call later could plausibly succeed. */
    public function isRetryable(): bool
    {
        return $this->status >= 500
            || in_array($this->errorCode, ['rate_limited', 'carrier_error', 'connection_error'], true);
    }

    /** Builds the exception from an API error answer. */
    public static function fromResponse(Response $res): self
    {
        $payload = null;
        if ($res->body !== '') {
            try {
                $payload = json_decode($res->body, true, 512, JSON_THROW_ON_ERROR);
            } catch (\JsonException) {
                $payload = null; // a proxy's HTML page
            }
        }
        $err = is_array($payload) && is_array($payload['error'] ?? null) ? $payload['error'] : [];

        $retryAfter = null;
        if (isset($err['retry_after']) && is_numeric($err['retry_after'])) {
            $retryAfter = (float) $err['retry_after'];
        } elseif (isset($res->headers['retry-after']) && is_numeric($res->headers['retry-after'])) {
            $retryAfter = (float) $res->headers['retry-after'];
        }
        $str = static fn (string $k): ?string => isset($err[$k]) && is_scalar($err[$k]) ? (string) $err[$k] : null;
        $int = static fn (string $k): ?int => isset($err[$k]) && is_numeric($err[$k]) ? (int) $err[$k] : null;

        return new self(
            $str('message') ?: "Request failed with status {$res->status}",
            $str('code') ?: ($res->status >= 500 ? 'internal_error' : 'invalid_request'),
            $res->status,
            param: $str('param'),
            retryAfter: $retryAfter,
            reason: $str('reason'),
            balanceMicroUsd: $int('balance_micro_usd'),
            requiredMicroUsd: $int('required_micro_usd'),
            topUpUrl: $str('top_up_url'),
            sendAfter: $str('send_after'),
            recipientLocalTime: $str('recipient_local_time'),
            timezone: $str('timezone'),
            messageId: $str('message_id'),
        );
    }
}
