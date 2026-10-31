<?php

declare(strict_types=1);

namespace TextKit\Resources;

/** The address book. One contact per phone number; tags double as broadcast audiences. */
final class Contacts extends Resource
{
    /**
     * Create a contact, or update the one that already has this number.
     * Values you leave out are kept; tags are added, never removed.
     *
     * @param list<string>|null $tags
     * @param array<string, string>|null $fields
     * @return array<string, mixed>
     */
    public function upsert(
        string $phoneNumber,
        ?string $name = null,
        ?array $tags = null,
        ?array $fields = null,
        ?string $notes = null,
    ): array {
        return $this->client->request('POST', '/contacts', body: self::compact([
            'phone_number' => $phoneNumber,
            'name' => $name,
            'tags' => $tags,
            'fields' => $fields ?: null,
            'notes' => $notes,
        ]), retryable: true);
    }

    /**
     * Upsert up to 500 contacts in one call. Each item has `phone_number` and
     * optional `name`, `tags`, `fields`, `notes`.
     *
     * @param list<array<string, mixed>> $contacts
     * @return array<string, mixed>
     */
    public function import(array $contacts): array
    {
        return $this->client->request('POST', '/contacts/import', body: ['contacts' => array_values($contacts)], retryable: true);
    }

    /**
     * Consent for a phone number: whether you may text it, when and how it
     * opted out, and its full history. Same as `consent->get($phoneNumber)`.
     *
     * @return array<string, mixed>
     */
    public function consent(string $phoneNumber): array
    {
        return $this->client->consent->get($phoneNumber);
    }

    /**
     * Apply "add_tags", "remove_tags" or "delete" to up to 500 contact ids in
     * one call. Not retried.
     *
     * @param list<string> $ids
     * @param list<string>|null $tags
     * @return array<string, mixed>
     */
    public function bulk(string $action, array $ids, ?array $tags = null): array
    {
        return $this->client->request('POST', '/contacts/bulk', body: self::compact([
            'action' => $action,
            'ids' => array_values($ids),
            'tags' => $tags,
        ]));
    }

    /** @return array<string, mixed> */
    public function get(string $id): array
    {
        return $this->client->request('GET', '/contacts/' . self::seg($id), retryable: true);
    }

    /**
     * Change only the keys you pass. `tags` and `fields` replace what is
     * stored; a null `name` or `notes` clears it.
     *
     * @param array{phone_number?: string, name?: ?string, tags?: list<string>, fields?: array<string, string>, notes?: ?string} $params
     * @return array<string, mixed>
     */
    public function update(string $id, array $params): array
    {
        if (array_key_exists('fields', $params) && is_array($params['fields'])) {
            $params['fields'] = self::map($params['fields']);
        }
        if (array_key_exists('tags', $params) && is_array($params['tags'])) {
            $params['tags'] = array_values($params['tags']);
        }
        return $this->client->request('PATCH', '/contacts/' . self::seg($id), body: $params, retryable: true);
    }

    /** @return array<string, mixed> */
    public function delete(string $id): array
    {
        return $this->client->request('DELETE', '/contacts/' . self::seg($id));
    }

    /**
     * Newest first. `phoneNumber` finds the one contact holding it.
     *
     * @return array<string, mixed>
     */
    public function list(?int $limit = null, ?string $cursor = null, ?string $tag = null, ?string $phoneNumber = null): array
    {
        return $this->client->request('GET', '/contacts', query: [
            'limit' => $limit,
            'cursor' => $cursor,
            'tag' => $tag,
            'phone_number' => $phoneNumber,
        ], retryable: true);
    }

    /** @return \Generator<int, array<string, mixed>> */
    public function listAll(?int $limit = null, ?string $tag = null): \Generator
    {
        return self::paginate(fn (?string $cursor) => $this->list(limit: $limit, cursor: $cursor, tag: $tag));
    }
}
