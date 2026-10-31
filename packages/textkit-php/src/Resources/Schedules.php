<?php

declare(strict_types=1);

namespace TextKit\Resources;

use TextKit\Client;

/**
 * Recurring schedules: one message to one number on a repeating local time.
 *
 * Each occurrence is a normal send (opt-outs, quota and spend limit are
 * checked when it fires) and a normal message with `schedule_id`.
 */
final class Schedules extends Resource
{
    /**
     * Create a schedule.
     *
     * `repeat` is `['frequency' => 'daily'|'weekly'|'monthly', 'time' =>
     * '08:00', 'timezone' => 'America/New_York']` plus `days_of_week` for
     * weekly or `day_of_month` for monthly. `from` falls back to the client's
     * `defaultFrom`; left out entirely, the API uses your account's one number
     * for the key's mode. Retries are safe: an Idempotency-Key is generated
     * when you don't pass one.
     *
     * @param array<string, mixed> $repeat
     * @return array<string, mixed>
     */
    public function create(
        string $to,
        string $body,
        array $repeat,
        ?string $from = null,
        ?string $startDate = null,
        ?string $endDate = null,
        ?int $maxOccurrences = null,
        ?string $idempotencyKey = null,
    ): array {
        return $this->client->request('POST', '/schedules', body: self::compact([
            'to' => $to,
            'body' => $body,
            'repeat' => $repeat,
            'from' => $from ?: $this->client->defaultFrom(),
            'start_date' => $startDate,
            'end_date' => $endDate,
            'max_occurrences' => $maxOccurrences,
        ]), idempotencyKey: $idempotencyKey ?: Client::newIdempotencyKey(), retryable: true);
    }

    /**
     * One schedule, with its `recent_occurrences`.
     *
     * @return array<string, mixed>
     */
    public function get(string $id): array
    {
        return $this->client->request('GET', '/schedules/' . self::seg($id), retryable: true);
    }

    /** @return array<string, mixed> */
    public function list(): array
    {
        return $this->client->request('GET', '/schedules', retryable: true);
    }

    /**
     * Change a schedule: any of `to`, `from`, `body`, `repeat`, `start_date`,
     * `end_date`, `max_occurrences`, `active`. A null `start_date`,
     * `end_date` or `max_occurrences` clears it; `repeat` replaces the whole
     * object.
     *
     * @param array<string, mixed> $params
     * @return array<string, mixed>
     */
    public function update(string $id, array $params): array
    {
        return $this->client->request('PATCH', '/schedules/' . self::seg($id), body: $params, retryable: true);
    }

    /**
     * Stop sending until resumed.
     *
     * @return array<string, mixed>
     */
    public function pause(string $id): array
    {
        return $this->update($id, ['active' => false]);
    }

    /**
     * Start again from now: nothing that came due while paused is sent.
     *
     * @return array<string, mixed>
     */
    public function resume(string $id): array
    {
        return $this->update($id, ['active' => true]);
    }

    /**
     * Stop it for good. Messages it already sent stay in the message log.
     *
     * @return array<string, mixed>
     */
    public function delete(string $id): array
    {
        return $this->client->request('DELETE', '/schedules/' . self::seg($id));
    }
}
