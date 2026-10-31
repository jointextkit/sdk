<?php

declare(strict_types=1);

namespace TextKit;

/** One HTTP answer, as a Transport returns it. */
final class Response
{
    /** @param array<string, string> $headers names lowercased */
    public function __construct(
        public readonly int $status,
        public readonly array $headers,
        public readonly string $body,
    ) {
    }
}
