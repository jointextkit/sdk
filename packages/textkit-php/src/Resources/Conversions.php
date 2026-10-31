<?php

declare(strict_types=1);

namespace TextKit\Resources;

final class Conversions extends Resource
{
    /**
     * Report a sale. $clickId is the tk value on the landing page URL.
     *
     * @return array<string, mixed>
     */
    public function create(string $clickId, ?int $valueCents = null, ?string $name = null, ?string $externalId = null): array
    {
        $body = ['click_id' => $clickId, 'value_cents' => $valueCents, 'name' => $name, 'external_id' => $externalId];
        return $this->client->request('POST', '/conversions', body: array_filter($body, static fn ($v) => $v !== null));
    }

    /**
     * The latest 100 conversions.
     *
     * @return array<string, mixed>
     */
    public function list(): array
    {
        return $this->client->request('GET', '/conversions', retryable: true);
    }
}
