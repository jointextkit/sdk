<?php

declare(strict_types=1);

namespace TextKit\Resources;

/** Event-driven flows: a trigger event, then send / wait / branch steps. */
final class Automations extends Resource
{
    /**
     * Create a flow as a draft. `issues` on the result lists what stops it
     * from running. Not retried.
     *
     * @param array<string, mixed> $trigger e.g. ['event' => 'trial_started']
     * @param list<array<string, mixed>> $steps e.g. [['type' => 'wait', 'seconds' => 3600], ['type' => 'send_sms', 'body' => '...']]
     * @return array<string, mixed>
     */
    public function create(string $name, array $trigger, array $steps, ?string $from = null, ?string $topicId = null): array
    {
        return $this->client->request('POST', '/automations', body: self::compact([
            'name' => $name,
            'from' => $from,
            'topic_id' => $topicId,
            'trigger' => $trigger,
            'steps' => array_values($steps),
        ]));
    }

    /** @return array<string, mixed> */
    public function get(string $id): array
    {
        return $this->client->request('GET', '/automations/' . self::seg($id), retryable: true);
    }

    /** @return array<string, mixed> */
    public function list(): array
    {
        return $this->client->request('GET', '/automations', retryable: true);
    }

    /**
     * Change only the keys you pass (`name`, `trigger`, `steps`, `from`,
     * `topic_id`; null clears `from` or `topic_id`). Editing an active flow
     * publishes a new version. Not retried.
     *
     * @param array<string, mixed> $params
     * @return array<string, mixed>
     */
    public function update(string $id, array $params): array
    {
        return $this->client->request('PATCH', '/automations/' . self::seg($id), body: $params);
    }

    /**
     * Delete a flow. Runs in progress stop; nothing more is sent.
     *
     * @return array<string, mixed>
     */
    public function delete(string $id): array
    {
        return $this->client->request('DELETE', '/automations/' . self::seg($id));
    }

    /**
     * Turn a flow on. Throws `invalid_request` when it is not ready.
     *
     * @return array<string, mixed>
     */
    public function activate(string $id): array
    {
        return $this->client->request('POST', '/automations/' . self::seg($id) . '/activate', retryable: true);
    }

    /**
     * Stop new runs and hold the ones in progress until it is activated again.
     *
     * @return array<string, mixed>
     */
    public function pause(string $id): array
    {
        return $this->client->request('POST', '/automations/' . self::seg($id) . '/pause', retryable: true);
    }

    /**
     * Runs of one flow, newest first.
     *
     * @return array<string, mixed>
     */
    public function runs(string $id, ?int $limit = null, ?string $cursor = null): array
    {
        return $this->client->request(
            'GET',
            '/automations/' . self::seg($id) . '/runs',
            query: ['limit' => $limit, 'cursor' => $cursor],
            retryable: true,
        );
    }

    /** @return \Generator<int, array<string, mixed>> */
    public function listAllRuns(string $id, ?int $limit = null): \Generator
    {
        return self::paginate(fn (?string $cursor) => $this->runs($id, limit: $limit, cursor: $cursor));
    }

    /** @return array<string, mixed> */
    public function run(string $id, string $runId): array
    {
        return $this->client->request('GET', '/automations/' . self::seg($id) . '/runs/' . self::seg($runId), retryable: true);
    }

    /**
     * Cancel a run in progress.
     *
     * @return array<string, mixed>
     */
    public function cancelRun(string $id, string $runId): array
    {
        return $this->client->request('DELETE', '/automations/' . self::seg($id) . '/runs/' . self::seg($runId));
    }
}
