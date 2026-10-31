<?php

declare(strict_types=1);

namespace TextKit\Resources;

/** The businesses you send on behalf of (for platforms). Entirely optional. */
final class Customers extends Resource
{
    /**
     * Not retried.
     *
     * @param array<string, string>|null $metadata
     * @return array<string, mixed>
     */
    public function create(?string $name = null, ?string $externalId = null, ?array $metadata = null): array
    {
        return $this->client->request('POST', '/customers', body: self::compact([
            'name' => $name,
            'external_id' => $externalId,
            'metadata' => $metadata ?: null,
        ]));
    }

    /** @return array<string, mixed> */
    public function get(string $id): array
    {
        return $this->client->request('GET', '/customers/' . self::seg($id), retryable: true);
    }

    /**
     * Change only the keys you pass; a null value clears one. `metadata`
     * replaces the whole object.
     *
     * @param array{name?: ?string, external_id?: ?string, metadata?: ?array<string, string>} $params
     * @return array<string, mixed>
     */
    public function update(string $id, array $params): array
    {
        if (array_key_exists('metadata', $params) && is_array($params['metadata'])) {
            $params['metadata'] = self::map($params['metadata']);
        }
        return $this->client->request('PATCH', '/customers/' . self::seg($id), body: $params, retryable: true);
    }

    /**
     * Delete a customer. Its numbers stay yours, unassigned.
     *
     * @return array<string, mixed>
     */
    public function delete(string $id): array
    {
        return $this->client->request('DELETE', '/customers/' . self::seg($id));
    }

    /** @return array<string, mixed> */
    public function list(?int $limit = null, ?string $cursor = null, ?string $externalId = null): array
    {
        return $this->client->request('GET', '/customers', query: [
            'limit' => $limit,
            'cursor' => $cursor,
            'external_id' => $externalId,
        ], retryable: true);
    }

    /** @return \Generator<int, array<string, mixed>> */
    public function listAll(?int $limit = null): \Generator
    {
        return self::paginate(fn (?string $cursor) => $this->list(limit: $limit, cursor: $cursor));
    }

    /**
     * Usage for a UTC date range (`YYYY-MM-DD`; default this month to date).
     * Follows the key: test keys report sandbox traffic, live keys live.
     *
     * @return array<string, mixed>
     */
    public function usage(string $id, ?string $start = null, ?string $end = null): array
    {
        return $this->client->request(
            'GET',
            '/customers/' . self::seg($id) . '/usage',
            query: ['start' => $start, 'end' => $end],
            retryable: true,
        );
    }
}
