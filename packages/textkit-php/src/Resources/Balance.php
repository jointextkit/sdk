<?php

declare(strict_types=1);

namespace TextKit\Resources;

final class Balance extends Resource
{
    /**
     * Your prepaid credit balance and auto-recharge setting.
     *
     * @return array<string, mixed>
     */
    public function get(): array
    {
        return $this->client->request('GET', '/balance', retryable: true);
    }
}
