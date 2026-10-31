<?php

declare(strict_types=1);

namespace TextKit\Tests;

use TextKit\Response;
use TextKit\Transport;
use TextKit\TransportException;

/** Pops one scripted reply per call and records every request. No network. */
final class FakeTransport implements Transport
{
    /** @var list<array{method: string, url: string, path: string, headers: array<string, string>, json: mixed, timeout: float}> */
    public array $calls = [];

    /** @var list<array{0: int, 1: mixed, 2?: array<string, string>}|\Throwable> */
    private array $replies;

    /** @param array{0: int, 1: mixed, 2?: array<string, string>}|\Throwable ...$replies */
    public function __construct(array|\Throwable ...$replies)
    {
        $this->replies = array_values($replies);
    }

    public function send(string $method, string $url, array $headers, ?string $body, float $timeout): Response
    {
        $parts = parse_url($url);
        $path = ($parts['path'] ?? '') . (isset($parts['query']) ? '?' . $parts['query'] : '');
        $this->calls[] = [
            'method' => $method,
            'url' => $url,
            'path' => substr($path, strlen('/v1')),
            'headers' => $headers,
            'json' => $body === null ? null : json_decode($body, true, 512, JSON_THROW_ON_ERROR),
            'raw' => $body,
            'timeout' => $timeout,
        ];
        if ($this->replies === []) {
            throw new \LogicException("unexpected request {$method} {$url}");
        }
        $reply = array_shift($this->replies);
        if ($reply instanceof \Throwable) {
            throw $reply;
        }
        [$status, $payload] = $reply;
        $raw = is_string($payload) ? $payload : json_encode($payload, JSON_THROW_ON_ERROR);
        return new Response($status, $reply[2] ?? [], $raw);
    }

    public static function down(string $message = 'down', bool $timedOut = false): TransportException
    {
        return new TransportException($message, $timedOut);
    }
}
