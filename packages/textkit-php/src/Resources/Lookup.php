<?php

declare(strict_types=1);

namespace TextKit\Resources;

final class Lookup extends Resource
{
    /**
     * Carrier and line type for a number.
     *
     * @return array<string, mixed>
     */
    public function phone(string $phoneNumber): array
    {
        return $this->client->request('GET', '/lookup/' . self::seg($phoneNumber), retryable: true);
    }
}
