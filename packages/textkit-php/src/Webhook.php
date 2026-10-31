<?php

declare(strict_types=1);

namespace TextKit;

/**
 * Webhook signature verification.
 *
 * Every webhook carries `textkit-signature: t=<unix seconds>,v1=<hex>`
 * where `v1 = HMAC-SHA256(secret, "<t>.<raw body>")`. Verify against the raw
 * request body exactly as received (`file_get_contents('php://input')`);
 * re-encoded JSON will not match.
 *
 * The same value is also sent as `dsms-signature` and `resms-signature` (the
 * header names from before the product was renamed). `verify()` takes the
 * header value, or the request's whole headers array and finds it under any
 * of those names.
 */
final class Webhook
{
    public const DEFAULT_TOLERANCE = 300;

    /** Every header name the signature has been sent under, current first. */
    public const SIGNATURE_HEADERS = ['textkit-signature', 'dsms-signature', 'resms-signature'];

    /** Every header name the event id has been sent under, current first. */
    public const EVENT_ID_HEADERS = ['textkit-event-id', 'dsms-event-id', 'resms-event-id'];

    /**
     * Verify a webhook from TextKit and return the parsed event.
     *
     * @param string $payload the raw request body
     * @param string|array<string, mixed>|null $signature the `textkit-signature` header value, or the request's headers
     *        (`getallheaders()`, a PSR-7 `getHeaders()`, or `$_SERVER`)
     * @param string $secret your endpoint's signing secret (`whsec_...`)
     * @param int $tolerance max age, either direction, in seconds; 0 disables the check
     * @param int|null $now the current Unix time (tests)
     * @return array<string, mixed>
     * @throws TextKitException with error code "invalid_signature"
     */
    public static function verify(
        string $payload,
        string|array|null $signature,
        string $secret,
        int $tolerance = self::DEFAULT_TOLERANCE,
        ?int $now = null,
    ): array {
        if ($secret === '') {
            throw self::fail('No webhook secret given.');
        }
        if (is_array($signature)) {
            $signature = self::signatureFromHeaders($signature);
        }
        if ($signature === null || $signature === '') {
            throw self::fail('Missing textkit-signature header.');
        }

        $timestamp = null;
        $candidates = [];
        foreach (explode(',', $signature) as $part) {
            $kv = explode('=', $part, 2);
            if (count($kv) !== 2) {
                continue;
            }
            [$key, $value] = [trim($kv[0]), trim($kv[1])];
            if ($key === 't' && $value !== '' && ctype_digit($value)) {
                $timestamp = (int) $value;
            } elseif ($key === 'v1') {
                $candidates[] = strtolower($value);
            }
        }
        if ($timestamp === null || $candidates === []) {
            throw self::fail('Malformed textkit-signature header.');
        }

        $current = $now ?? time();
        if ($tolerance > 0 && abs($current - $timestamp) > $tolerance) {
            throw self::fail('Webhook timestamp is outside the tolerance window.');
        }

        $expected = hash_hmac('sha256', $timestamp . '.' . $payload, $secret);
        $matched = false;
        foreach ($candidates as $candidate) {
            if (hash_equals($expected, $candidate)) {
                $matched = true;
            }
        }
        if (!$matched) {
            throw self::fail('Webhook signature does not match.');
        }

        try {
            $event = json_decode($payload, true, 512, JSON_THROW_ON_ERROR);
        } catch (\JsonException $e) {
            throw new TextKitException('Webhook body is not valid JSON.', 'invalid_signature', 400, previous: $e);
        }
        if (!is_array($event)) {
            throw self::fail('Webhook body is not a JSON object.');
        }
        return $event;
    }

    /**
     * The webhook signature from a request's headers, whichever name it arrived under.
     *
     * @param array<string, mixed> $headers
     */
    public static function signatureFromHeaders(array $headers): ?string
    {
        return self::header($headers, self::SIGNATURE_HEADERS);
    }

    /**
     * The event id (`evt_...`, stable across retries) from a request's headers.
     *
     * @param array<string, mixed> $headers
     */
    public static function eventIdFromHeaders(array $headers): ?string
    {
        return self::header($headers, self::EVENT_ID_HEADERS);
    }

    /**
     * @param array<string, mixed> $headers
     * @param list<string> $names
     */
    private static function header(array $headers, array $names): ?string
    {
        $lowered = [];
        foreach ($headers as $key => $value) {
            $k = strtolower((string) $key);
            // $_SERVER spells them HTTP_TEXTKIT_SIGNATURE.
            if (str_starts_with($k, 'http_')) {
                $k = str_replace('_', '-', substr($k, 5));
            }
            if (is_array($value)) { // PSR-7 getHeaders(): name => list of values
                $value = $value[0] ?? null;
            }
            if (is_scalar($value) && (string) $value !== '' && !isset($lowered[$k])) {
                $lowered[$k] = (string) $value;
            }
        }
        foreach ($names as $name) {
            if (isset($lowered[$name])) {
                return $lowered[$name];
            }
        }
        return null;
    }

    private static function fail(string $message): TextKitException
    {
        return new TextKitException($message, 'invalid_signature', 400);
    }
}
