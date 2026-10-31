<?php

declare(strict_types=1);

namespace TextKit\Resources;

final class Numbers extends Resource
{
    /** @return array<string, mixed> one page of numbers you can buy */
    public function available(?string $areaCode = null): array
    {
        return $this->client->request('GET', '/numbers/available', query: ['area_code' => $areaCode], retryable: true);
    }

    /**
     * Buy a number. Not retried: a resend could buy twice.
     *
     * @return array<string, mixed>
     */
    public function buy(string $phoneNumber, ?string $customerId = null): array
    {
        return $this->client->request('POST', '/numbers', body: self::compact([
            'phone_number' => $phoneNumber,
            'customer_id' => $customerId,
        ]));
    }

    /** @return array<string, mixed> */
    public function list(?string $customerId = null): array
    {
        return $this->client->request('GET', '/numbers', query: ['customer_id' => $customerId], retryable: true);
    }

    /**
     * Assign a number to a customer, or pass `customerId: null` to unassign it.
     *
     * @return array<string, mixed>
     */
    public function update(string $phoneNumber, ?string $customerId): array
    {
        return $this->client->request(
            'PATCH',
            '/numbers/' . self::seg($phoneNumber),
            body: ['customer_id' => $customerId],
            retryable: true,
        );
    }

    /**
     * Give a number up. Not retried.
     *
     * @return array<string, mixed>
     */
    public function release(string $phoneNumber): array
    {
        return $this->client->request('DELETE', '/numbers/' . self::seg($phoneNumber));
    }
}
