<?php

declare(strict_types=1);

namespace TextKit\Resources;

use TextKit\Client;

final class Events extends Resource
{
    /** @return array<string, mixed> one page of events, newest first */
    public function list(?int $limit = null, ?string $cursor = null, ?string $type = null): array
    {
        return $this->client->request('GET', '/events', query: [
            'limit' => $limit,
            'cursor' => $cursor,
            'type' => $type,
        ], retryable: true);
    }

    /** @return \Generator<int, array<string, mixed>> */
    public function listAll(?int $limit = null, ?string $type = null): \Generator
    {
        return self::paginate(fn (?string $cursor) => $this->list(limit: $limit, cursor: $cursor, type: $type));
    }

    /**
     * Long-poll for new events. Call once with no cursor to get a cursor that
     * means "from now", then keep calling with the cursor each answer hands
     * back: the request is held until an event arrives or `timeout` seconds
     * pass (0-25, default 20). An event can be returned twice; de-duplicate
     * by `id`. Keep `timeout` below the client's own timeout (30 seconds by
     * default).
     *
     * @return array<string, mixed>
     */
    public function wait(?string $cursor = null, ?int $timeout = null): array
    {
        return $this->client->request('GET', '/events/wait', query: [
            'cursor' => $cursor,
            'timeout' => $timeout,
        ], retryable: true);
    }

    /**
     * Tell TextKit something happened in your app. Automations listening
     * for the event start (or move on) for that person. Pass `phone`,
     * `userId`, or both; a call with both links them, so later calls need
     * only `userId`. Retries are safe: an Idempotency-Key is generated when
     * you don't supply one.
     *
     * @param array<string, mixed>|null $properties
     * @return array<string, mixed>
     */
    public function track(
        string $event,
        ?string $userId = null,
        ?string $phone = null,
        ?array $properties = null,
        ?string $idempotencyKey = null,
    ): array {
        return $this->client->request('POST', '/track', body: self::compact([
            'event' => $event,
            'user_id' => $userId,
            'phone' => $phone,
            'properties' => $properties ?: null,
        ]), idempotencyKey: $idempotencyKey ?: Client::newIdempotencyKey(), retryable: true);
    }
}
