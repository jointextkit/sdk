<?php

declare(strict_types=1);

namespace TextKit\Resources;

use TextKit\Client;

/** @internal */
abstract class Resource
{
    public function __construct(protected readonly Client $client)
    {
    }

    /**
     * Drop null values: for create calls, where leaving a field out and
     * passing null mean the same thing.
     *
     * @param array<string, mixed> $fields
     * @return array<string, mixed>
     */
    protected static function compact(array $fields): array
    {
        return array_filter($fields, static fn ($v) => $v !== null);
    }

    /**
     * Walk every page of a list, yielding items.
     *
     * @param callable(?string): array<string, mixed> $fetch
     * @return \Generator<int, array<string, mixed>>
     */
    protected static function paginate(callable $fetch): \Generator
    {
        $cursor = null;
        while (true) {
            $page = $fetch($cursor);
            foreach ($page['data'] ?? [] as $item) {
                yield $item;
            }
            if (empty($page['has_more']) || empty($page['next_cursor'])) {
                return;
            }
            $cursor = (string) $page['next_cursor'];
        }
    }

    /**
     * An empty associative array encodes as JSON [] in PHP; the API wants {}
     * for a map such as metadata or fields.
     *
     * @param array<string, mixed>|null $map
     */
    protected static function map(?array $map): array|\stdClass|null
    {
        return $map === [] ? new \stdClass() : $map;
    }

    protected static function seg(string $value): string
    {
        return Client::segment($value);
    }
}
