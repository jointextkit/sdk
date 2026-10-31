<?php

declare(strict_types=1);

namespace TextKit;

use TextKit\Resources\Automations;
use TextKit\Resources\Balance;
use TextKit\Resources\Consent;
use TextKit\Resources\Conversions;
use TextKit\Resources\Links;
use TextKit\Resources\Contacts;
use TextKit\Resources\Customers;
use TextKit\Resources\Events;
use TextKit\Resources\Lookup;
use TextKit\Resources\Messages;
use TextKit\Resources\Numbers;
use TextKit\Resources\Registrations;
use TextKit\Resources\Schedules;
use TextKit\Resources\Verify;
use TextKit\Resources\Webhooks;

/**
 * The TextKit client.
 *
 *     $client = new \TextKit\Client(); // reads TEXTKIT_API_KEY
 *     $client->messages->send(to: '+15005550006', body: 'Hello from TextKit');
 *
 * Every call returns the API's JSON as an associative array, and every
 * failure throws TextKitException.
 */
final class Client
{
    public const VERSION = '0.1.0';
    public const DEFAULT_BASE_URL = 'https://api.jointextkit.com/v1';

    /** Environment variables, current name first; the rest are from before the rename. */
    private const KEY_ENV = ['TEXTKIT_API_KEY', 'SIMPLESMS_API_KEY', 'DELIVERED_API_KEY', 'RESMS_API_KEY'];
    private const BASE_URL_ENV = ['TEXTKIT_BASE_URL', 'SIMPLESMS_BASE_URL', 'DELIVERED_BASE_URL', 'RESMS_BASE_URL'];
    private const FROM_ENV = ['TEXTKIT_FROM', 'SIMPLESMS_FROM', 'DELIVERED_FROM'];

    public readonly Messages $messages;
    public readonly Verify $verify;
    public readonly Numbers $numbers;
    public readonly Lookup $lookup;
    public readonly Links $links;
    public readonly Conversions $conversions;
    public readonly Balance $balance;
    public readonly Events $events;
    public readonly Webhooks $webhooks;
    public readonly Consent $consent;
    public readonly Customers $customers;
    public readonly Contacts $contacts;
    public readonly Automations $automations;
    public readonly Schedules $schedules;
    public readonly Registrations $registrations;

    /** The API root this client sends to, ending in /v1. */
    public readonly string $baseUrl;

    private readonly string $apiKey;
    private readonly Transport $transport;
    /** @var callable(float): void */
    private $sleep;
    private ?string $defaultFrom;

    /**
     * @param string|null $apiKey defaults to TEXTKIT_API_KEY
     * @param string|null $defaultFrom the number messages->send uses when you omit `from`.
     *        Defaults to TEXTKIT_FROM, else your account's only active number (looked up once).
     * @param string|null $baseUrl defaults to https://api.jointextkit.com/v1; "/v1" is added when missing
     * @param int $maxRetries retries for transient failures (429, 5xx, network)
     * @param float $timeout per-request timeout, seconds
     * @param Transport|null $transport swap the HTTP layer (tests, tracing, proxies)
     * @param callable(float): void|null $sleep how to wait between retries (tests)
     */
    public function __construct(
        ?string $apiKey = null,
        ?string $defaultFrom = null,
        ?string $baseUrl = null,
        public readonly int $maxRetries = 2,
        public readonly float $timeout = 30.0,
        ?Transport $transport = null,
        ?callable $sleep = null,
    ) {
        $key = $apiKey ?: self::env(self::KEY_ENV);
        if ($key === null || $key === '') {
            throw new TextKitException(
                'No TextKit key. Pass one to new Client(...) or set TEXTKIT_API_KEY. Get one free at https://jointextkit.com/console',
                'invalid_api_key',
            );
        }
        $this->apiKey = $key;
        $this->baseUrl = self::normalizeBaseUrl($baseUrl ?: self::env(self::BASE_URL_ENV));
        $this->defaultFrom = $defaultFrom ?: self::env(self::FROM_ENV);
        $this->transport = $transport ?? new CurlTransport();
        $this->sleep = $sleep ?? static function (float $seconds): void {
            usleep((int) round($seconds * 1_000_000));
        };

        $this->messages = new Messages($this);
        $this->verify = new Verify($this);
        $this->numbers = new Numbers($this);
        $this->lookup = new Lookup($this);
        $this->links = new Links($this);
        $this->conversions = new Conversions($this);
        $this->balance = new Balance($this);
        $this->events = new Events($this);
        $this->webhooks = new Webhooks($this);
        $this->consent = new Consent($this);
        $this->customers = new Customers($this);
        $this->contacts = new Contacts($this);
        $this->automations = new Automations($this);
        $this->schedules = new Schedules($this);
        $this->registrations = new Registrations($this);
    }

    /** True when this client is using a sandbox key. */
    public function isTestMode(): bool
    {
        return (bool) preg_match('/^(tk|ssms|dsms|resms)_sk_test_/', $this->apiKey);
    }

    /** A fresh random idempotency key in the form the SDKs use. */
    public static function newIdempotencyKey(): string
    {
        return 'sdk_' . bin2hex(random_bytes(16));
    }

    /**
     * Send one request, with retries. Resources call this; you can too, for an
     * endpoint this client has no method for yet.
     *
     * @param array<string, mixed>|null $query null values are dropped
     * @param array<string, mixed>|null $body sent as given (null values included)
     * @param bool $retryable resend on a transient failure. A POST is only
     *        safe to resend with an idempotency key.
     * @param bool $raw return the body as a string instead of decoding JSON
     * @return array<string, mixed>|string
     */
    public function request(
        string $method,
        string $path,
        ?array $query = null,
        ?array $body = null,
        ?string $idempotencyKey = null,
        bool $retryable = false,
        bool $raw = false,
    ): array|string {
        $headers = [
            'Authorization' => 'Bearer ' . $this->apiKey,
            'User-Agent' => 'jointextkit-php/' . self::VERSION,
            'Accept' => 'application/json',
        ];
        $payload = null;
        if ($body !== null) {
            $headers['Content-Type'] = 'application/json';
            $payload = json_encode(
                $body === [] ? new \stdClass() : $body,
                JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRESERVE_ZERO_FRACTION | JSON_THROW_ON_ERROR,
            );
        }
        if ($idempotencyKey !== null && $idempotencyKey !== '') {
            $headers['Idempotency-Key'] = $idempotencyKey;
        }
        $url = $this->baseUrl . $path . self::query($query ?? []);

        $last = null;
        for ($attempt = 0; $attempt <= max(0, $this->maxRetries); $attempt++) {
            if ($attempt > 0 && $last !== null) {
                ($this->sleep)(self::backoff($attempt, $last));
            }
            try {
                $res = $this->transport->send($method, $url, $headers, $payload, $this->timeout);
            } catch (TransportException $e) {
                $last = new TextKitException(
                    $e->timedOut
                        ? "Request timed out after {$this->timeout}s"
                        : 'Could not reach the TextKit API: ' . $e->getMessage(),
                    'connection_error',
                    previous: $e,
                );
                $res = null;
            }
            if ($res !== null) {
                if ($res->status >= 200 && $res->status < 300) {
                    if ($raw) {
                        return $res->body;
                    }
                    if ($res->body === '') {
                        return [];
                    }
                    try {
                        $decoded = json_decode($res->body, true, 512, JSON_THROW_ON_ERROR);
                    } catch (\JsonException $e) {
                        throw new TextKitException("Could not decode the API's answer.", 'internal_error', $res->status, previous: $e);
                    }
                    return is_array($decoded) ? $decoded : [];
                }
                $last = TextKitException::fromResponse($res);
            }

            // Retry only what is safe: a POST without an idempotency key is
            // never resent, and a verification cooldown is policy, not a blip.
            if (!$retryable || !$last->isRetryable()) {
                break;
            }
            if ($last->errorCode === 'rate_limited' && str_starts_with($path, '/verify')) {
                break;
            }
        }
        throw $last;
    }

    /**
     * The default sending number: configured, else the account's only
     * active number, looked up once.
     *
     * @internal
     */
    public function resolveFrom(): string
    {
        if ($this->defaultFrom !== null && $this->defaultFrom !== '') {
            return $this->defaultFrom;
        }
        $active = [];
        foreach ($this->numbers->list()['data'] ?? [] as $n) {
            if (($n['status'] ?? null) === 'active') {
                $active[] = $n['phone_number'];
            }
        }
        if (count($active) !== 1) {
            throw new TextKitException(
                'Pass from: ... (or set TEXTKIT_FROM): your account has '
                    . ($active ? count($active) . ' numbers.' : 'no numbers yet.'),
                'invalid_request',
                param: 'from',
            );
        }
        return $this->defaultFrom = $active[0];
    }

    /** @internal */
    public function defaultFrom(): ?string
    {
        return $this->defaultFrom;
    }

    private static function backoff(int $attempt, TextKitException $err): float
    {
        if ($err->retryAfter !== null && $err->retryAfter >= 0) {
            return $err->retryAfter;
        }
        $base = min(0.25 * (2 ** $attempt), 4.0);
        return $base + (mt_rand() / mt_getrandmax()) * $base / 4;
    }

    /** @param array<string, mixed> $params */
    private static function query(array $params): string
    {
        $pairs = [];
        foreach ($params as $k => $v) {
            if ($v === null) {
                continue;
            }
            $pairs[$k] = is_bool($v) ? ($v ? 'true' : 'false') : (string) $v;
        }
        return $pairs === [] ? '' : '?' . http_build_query($pairs, '', '&', PHP_QUERY_RFC1738);
    }

    /** One URL path segment, "+" included (phone numbers). */
    public static function segment(string $value): string
    {
        return rawurlencode($value);
    }

    private static function normalizeBaseUrl(?string $url): string
    {
        if ($url === null || $url === '') {
            return self::DEFAULT_BASE_URL;
        }
        $url = rtrim($url, '/');
        return str_ends_with($url, '/v1') ? $url : $url . '/v1';
    }

    /** @param list<string> $names */
    private static function env(array $names): ?string
    {
        foreach ($names as $name) {
            $value = getenv($name);
            if (is_string($value) && $value !== '') {
                return $value;
            }
            if (isset($_ENV[$name]) && is_string($_ENV[$name]) && $_ENV[$name] !== '') {
                return $_ENV[$name];
            }
        }
        return null;
    }
}
