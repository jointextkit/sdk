<?php

declare(strict_types=1);

namespace TextKit\Resources;

final class Verify extends Resource
{
    /**
     * Send a one-time code. You don't need to own a number. Not retried: a
     * resend could text the code twice.
     *
     * @return array<string, mixed>
     */
    public function send(string $to, ?string $appName = null, ?string $from = null, ?string $customerId = null): array
    {
        return $this->client->request('POST', '/verify', body: self::compact([
            'to' => $to,
            'app_name' => $appName,
            'from' => $from,
            'customer_id' => $customerId,
        ]));
    }

    /**
     * Check a code. You are billed only when `verified` is true.
     *
     * @return array<string, mixed>
     */
    public function check(string $to, string $code): array
    {
        return $this->client->request('POST', '/verify/check', body: ['to' => $to, 'code' => $code]);
    }

    /** @return array<string, mixed> */
    public function get(string $id): array
    {
        return $this->client->request('GET', '/verify/' . self::seg($id), retryable: true);
    }
}
