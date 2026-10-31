<?php

declare(strict_types=1);

namespace TextKit\Resources;

final class Consent extends Resource
{
    /**
     * One page of your suppression list: numbers currently opted out.
     *
     * @return array<string, mixed>
     */
    public function list(?int $limit = null, ?string $cursor = null): array
    {
        return $this->client->request('GET', '/consent', query: ['limit' => $limit, 'cursor' => $cursor], retryable: true);
    }

    /** @return \Generator<int, array<string, mixed>> */
    public function listAll(?int $limit = null): \Generator
    {
        return self::paginate(fn (?string $cursor) => $this->list(limit: $limit, cursor: $cursor));
    }

    /**
     * Current status plus the append-only history for one number.
     *
     * @return array<string, mixed>
     */
    public function get(string $phone): array
    {
        return $this->client->request('GET', '/consent/' . self::seg($phone), retryable: true);
    }

    /**
     * Record an opt-out from your own system (CRM, web form, support tool).
     *
     * @return array<string, mixed>
     */
    public function optOut(string $phone, ?string $note = null): array
    {
        return $this->client->request(
            'POST',
            '/consent/' . self::seg($phone),
            body: self::compact(['status' => 'opted_out', 'note' => $note]),
            retryable: true,
        );
    }

    /**
     * Record a fresh opt-in. Only with the recipient's consent.
     *
     * `campaignId` (a registration id) records it for that registration,
     * which is what a marketing send from the registration's numbers looks
     * for. An opt-in for a marketing or mixed registration must carry
     * `proof` (`source`, `collected_at`, and `page_url` for a web form or
     * `message_id` for a keyword), and so must one for a number that opted
     * out, collected at or after the opt-out (409 otherwise).
     *
     * @param array<string, string>|null $proof
     * @return array<string, mixed>
     */
    public function optIn(string $phone, ?string $note = null, ?string $campaignId = null, ?array $proof = null): array
    {
        return $this->client->request(
            'POST',
            '/consent/' . self::seg($phone),
            body: self::compact([
                'status' => 'opted_in',
                'note' => $note,
                'campaign_id' => $campaignId,
                'proof' => $proof,
            ]),
            retryable: true,
        );
    }

    /**
     * Bulk-import opt-outs (up to 500 per call).
     *
     * @param list<string> $phoneNumbers
     * @return array<string, mixed>
     */
    public function import(array $phoneNumbers): array
    {
        return $this->client->request(
            'POST',
            '/consent/import',
            body: ['phone_numbers' => array_values($phoneNumbers)],
            retryable: true,
        );
    }

    /** The whole suppression list as CSV text. */
    public function export(): string
    {
        $csv = $this->client->request('GET', '/consent/export', retryable: true, raw: true);
        return is_string($csv) ? $csv : '';
    }
}
