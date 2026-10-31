<?php

declare(strict_types=1);

namespace TextKit;

/**
 * The HTTP layer. Swap it for tests, tracing or proxies.
 *
 * Return any HTTP answer, 4xx and 5xx included. Throw TransportException
 * when no answer arrived (connection refused, DNS, timeout).
 */
interface Transport
{
    /** @param array<string, string> $headers */
    public function send(string $method, string $url, array $headers, ?string $body, float $timeout): Response;
}
