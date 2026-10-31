<?php

declare(strict_types=1);

namespace TextKit\Resources;

final class Links extends Resource
{
    /**
     * A tracked link to copy anywhere. The same url again returns the same link.
     *
     * @return array<string, mixed>
     */
    public function create(string $url, ?string $name = null): array
    {
        return $this->client->request('POST', '/links', body: array_filter(['url' => $url, 'name' => $name], static fn ($v) => $v !== null));
    }

    /**
     * Every tracked destination with its clicks and conversions.
     *
     * @return array<string, mixed>
     */
    public function list(): array
    {
        return $this->client->request('GET', '/links', retryable: true);
    }
}
