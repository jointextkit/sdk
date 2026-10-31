<?php

declare(strict_types=1);

namespace TextKit\Resources;

/**
 * Brand and campaign registrations (Compliance).
 *
 * `create` runs the website and example checks; `recheck` corrects and
 * re-runs them; `submit` files a ready registration. The first submit for a
 * business carries the attestation signed by someone authorized to act for
 * it (`['signer_name' => ..., 'signer_title' => ..., 'accepted' => true]`);
 * without one on file the API answers `attestation_required`.
 */
final class Registrations extends Resource
{
    /**
     * Create a registration. Runs the website check right away. Any other
     * registration field (`opt_in_url`, `sample_messages`, `brand`, ...) goes
     * in `fields`. Not retried.
     *
     * @param array<string, mixed> $fields
     * @return array<string, mixed>
     */
    public function create(string $businessName, string $website, string $useCase, array $fields = []): array
    {
        return $this->client->request('POST', '/registrations', body: self::compact([
            'business_name' => $businessName,
            'website' => $website,
            'use_case' => $useCase,
        ] + $fields));
    }

    /** @return array<string, mixed> */
    public function get(string $id): array
    {
        return $this->client->request('GET', '/registrations/' . self::seg($id), retryable: true);
    }

    /** @return array<string, mixed> */
    public function list(): array
    {
        return $this->client->request('GET', '/registrations', retryable: true);
    }

    /**
     * Correct any field and re-run the checks (draft, checks_failed, ready or
     * rejected). Not retried.
     *
     * @param array<string, mixed> $fields
     * @return array<string, mixed>
     */
    public function recheck(string $id, array $fields = []): array
    {
        return $this->client->request('POST', '/registrations/' . self::seg($id) . '/recheck', body: $fields);
    }

    /**
     * Submit a ready registration (or resubmit after a rejection). Not retried.
     *
     * `feesAcknowledged` must be true: it confirms the registration fee terms
     * (Terms §4.3): carrier registration fees are separate from the
     * per-message rate and billed at the registry's charge, a campaign carries a 3-month
     * minimum, and the fees are non-refundable even if the registration is
     * rejected. Without it the API answers 400 `invalid_request` (param
     * `fees_acknowledged`); the acknowledgment is kept on the filed copy.
     *
     * Pass `attestation` the first time for a business, or after our team
     * could not verify it; later submits for the same business need none.
     * The submission is held while we verify the business, then filed.
     *
     * @param array<string, mixed>|null $attestation
     * @return array<string, mixed>
     */
    public function submit(string $id, bool $feesAcknowledged, ?array $attestation = null): array
    {
        $body = self::compact(['attestation' => $attestation ?: null]);
        $body['fees_acknowledged'] = $feesAcknowledged;
        return $this->client->request('POST', '/registrations/' . self::seg($id) . '/submit', body: $body);
    }

    /**
     * The filed copies, oldest first: exactly what each submission sent.
     *
     * @return array<string, mixed>
     */
    public function submissions(string $id): array
    {
        return $this->client->request('GET', '/registrations/' . self::seg($id) . '/submissions', retryable: true);
    }
}
