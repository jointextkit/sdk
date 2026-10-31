<?php

declare(strict_types=1);

namespace TextKit\Resources;

use TextKit\Client;
use TextKit\TextKitException;

final class Messages extends Resource
{
    /**
     * Send an SMS.
     *
     * `text` is an alias for `body`. `from` defaults to the client's
     * `defaultFrom`, else your account's only number (looked up once).
     * Retries are safe: an Idempotency-Key is generated when you don't pass
     * one, so a network blip can never double-send.
     *
     * `category` ("marketing", "transactional" or "otp") can make the message
     * stricter, never looser; one outside its registration's use case throws
     * `campaign_mismatch`. For a marketing message outside 8:00am-9:00pm in
     * the recipient's local time, `quietHours` "block" throws `quiet_hours`
     * (with `sendAfter`) and "defer" holds it and returns a scheduled message
     * (check `['object']`).
     *
     * `consent` (`['source' => 'checkout', 'collected_at' => '...']`, plus
     * `page_url` for a web form) records how the recipient agreed, for a
     * recurring non-marketing message from a registered number with no
     * opt-in on file yet. It never counts for marketing.
     *
     * @param array<string, string>|null $consent
     * @return array<string, mixed>
     */
    public function send(
        string $to,
        ?string $body = null,
        ?string $from = null,
        ?string $text = null,
        ?string $customerId = null,
        ?string $category = null,
        ?string $quietHours = null,
        ?array $consent = null,
        ?string $idempotencyKey = null,
    ): array {
        $content = $body ?? $text;
        if ($content === null) {
            throw new TextKitException('Pass the message as `body` (or `text`).', 'invalid_request', param: 'body');
        }
        $payload = self::compact([
            'to' => $to,
            'body' => $content,
            'from' => $from ?: $this->client->resolveFrom(),
            'customer_id' => $customerId,
            'category' => $category,
            'quiet_hours' => $quietHours,
            'consent' => $consent,
        ]);
        return $this->client->request(
            'POST',
            '/messages',
            body: $payload,
            idempotencyKey: $idempotencyKey ?: Client::newIdempotencyKey(),
            retryable: true,
        );
    }

    /**
     * Queue a message for later (up to 30 days ahead). Not retried.
     *
     * @return array<string, mixed>
     */
    public function schedule(
        string $to,
        string $body,
        \DateTimeInterface|string $sendAt,
        ?string $from = null,
        ?string $customerId = null,
        ?string $category = null,
        ?string $quietHours = null,
    ): array {
        if ($sendAt instanceof \DateTimeInterface) {
            $sendAt = \DateTimeImmutable::createFromInterface($sendAt)
                ->setTimezone(new \DateTimeZone('UTC'))
                ->format('Y-m-d\TH:i:s\Z');
        }
        return $this->client->request('POST', '/messages', body: self::compact([
            'to' => $to,
            'body' => $body,
            'scheduled_at' => $sendAt,
            'from' => $from ?: $this->client->resolveFrom(),
            'customer_id' => $customerId,
            'category' => $category,
            'quiet_hours' => $quietHours,
        ]));
    }

    /** @return array<string, mixed> */
    public function get(string $id): array
    {
        return $this->client->request('GET', '/messages/' . self::seg($id), retryable: true);
    }

    /**
     * One page of messages, newest first. `scheduleId` keeps only the
     * occurrences of one recurring schedule. `status: 'blocked'` lists the
     * sends a check refused; `blockedReason` narrows to one reason.
     *
     * @return array{data: list<array<string, mixed>>, has_more: bool, next_cursor: ?string}
     */
    public function list(
        ?int $limit = null,
        ?string $cursor = null,
        ?string $number = null,
        ?string $customerId = null,
        ?string $scheduleId = null,
        ?string $status = null,
        ?string $blockedReason = null,
        ?string $failureCode = null,
    ): array {
        return $this->client->request('GET', '/messages', query: [
            'limit' => $limit,
            'cursor' => $cursor,
            'number' => $number,
            'customer_id' => $customerId,
            'schedule_id' => $scheduleId,
            'status' => $status,
            'blocked_reason' => $blockedReason,
            'failure_code' => $failureCode,
        ], retryable: true);
    }

    /**
     * Every message, newest first, fetching pages as you iterate.
     *
     * @return \Generator<int, array<string, mixed>>
     */
    public function listAll(
        ?int $limit = null,
        ?string $number = null,
        ?string $customerId = null,
        ?string $scheduleId = null,
        ?string $status = null,
    ): \Generator {
        return self::paginate(fn (?string $cursor) => $this->list(
            limit: $limit,
            cursor: $cursor,
            number: $number,
            customerId: $customerId,
            scheduleId: $scheduleId,
            status: $status,
        ));
    }
}
