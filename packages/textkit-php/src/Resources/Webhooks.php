<?php

declare(strict_types=1);

namespace TextKit\Resources;

use TextKit\Webhook;

/**
 * Webhook endpoints (where events are POSTed), and signature verification.
 *
 * `create` returns the signing `secret` once; keep it, the API never shows
 * it again (the console can). A restricted key needs the `webhooks:write`
 * scope.
 */
final class Webhooks extends Resource
{
    /**
     * Same as Webhook::verify().
     *
     * @param string|array<string, mixed>|null $signature
     * @return array<string, mixed>
     */
    public function verify(
        string $payload,
        string|array|null $signature,
        string $secret,
        int $tolerance = Webhook::DEFAULT_TOLERANCE,
        ?int $now = null,
    ): array {
        return Webhook::verify($payload, $signature, $secret, $tolerance, $now);
    }

    /** @return array<string, mixed> */
    public function list(): array
    {
        return $this->client->request('GET', '/webhooks', retryable: true);
    }

    /**
     * Register an endpoint. `events` omitted (or "*") subscribes to everything.
     * Not retried.
     *
     * @param string|list<string>|null $events
     * @return array<string, mixed>
     */
    public function create(string $url, string|array|null $events = null, ?string $description = null): array
    {
        return $this->client->request('POST', '/webhooks', body: self::compact([
            'url' => $url,
            'events' => $events,
            'description' => $description,
        ]));
    }

    /** @return array<string, mixed> */
    public function get(string $id): array
    {
        return $this->client->request('GET', '/webhooks/' . self::seg($id), retryable: true);
    }

    /**
     * Change any of `url`, `events`, `active` (false pauses delivery) or
     * `description` (null clears it). Only the keys you pass are sent.
     *
     * @param array{url?: string, events?: string|list<string>, active?: bool, description?: ?string} $params
     * @return array<string, mixed>
     */
    public function update(string $id, array $params): array
    {
        return $this->client->request('PATCH', '/webhooks/' . self::seg($id), body: $params);
    }

    /** @return array<string, mixed> */
    public function delete(string $id): array
    {
        return $this->client->request('DELETE', '/webhooks/' . self::seg($id));
    }
}
