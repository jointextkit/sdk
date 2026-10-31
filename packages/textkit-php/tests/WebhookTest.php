<?php

declare(strict_types=1);

namespace TextKit\Tests;

use PHPUnit\Framework\TestCase;
use TextKit\Client;
use TextKit\TextKitException;
use TextKit\Webhook;

/**
 * Webhook::verify against signatures produced by the server's own signer.
 *
 * fixtures/webhook_vectors.json is a copy of
 * packages/textkit-python/tests/fixtures/webhook_vectors.json, generated
 * from src/lib/api/webhook-signature.ts (npx tsx scripts/qa/webhook-vectors.ts).
 */
final class WebhookTest extends TestCase
{
    private static string $secret;
    /** @var list<array{payload: string, timestamp: int, signature: string}> */
    private static array $vectors;

    public static function setUpBeforeClass(): void
    {
        $fixture = json_decode((string) file_get_contents(__DIR__ . '/fixtures/webhook_vectors.json'), true, 512, JSON_THROW_ON_ERROR);
        self::$secret = $fixture['secret'];
        self::$vectors = $fixture['vectors'];
    }

    private function assertInvalid(callable $fn, string $contains): void
    {
        try {
            $fn();
        } catch (TextKitException $e) {
            self::assertSame('invalid_signature', $e->errorCode);
            self::assertSame(400, $e->status);
            self::assertStringContainsString($contains, $e->getMessage());
            return;
        }
        self::fail("expected invalid_signature ({$contains})");
    }

    public function testServerVectorsVerify(): void
    {
        self::assertNotEmpty(self::$vectors);
        foreach (self::$vectors as $v) {
            $event = Webhook::verify($v['payload'], $v['signature'], self::$secret, now: $v['timestamp']);
            self::assertSame(json_decode($v['payload'], true), $event);
        }
        self::assertStringContainsString('☕', Webhook::verify(self::$vectors[1]['payload'], self::$vectors[1]['signature'], self::$secret, now: self::$vectors[1]['timestamp'])['data']['body']);
    }

    public function testClientNamespace(): void
    {
        $v = self::$vectors[0];
        $client = new Client('ssms_sk_test_' . str_repeat('a', 32), transport: new FakeTransport());
        self::assertSame('evt_a1B2c3D4e5F6g7H8', $client->webhooks->verify($v['payload'], $v['signature'], self::$secret, now: $v['timestamp'])['id']);
    }

    public function testAnyHeaderNameVerifies(): void
    {
        $v = self::$vectors[0];
        foreach (['textkit-signature', 'dsms-signature', 'resms-signature', 'TextKit-Signature', 'Dsms-Signature'] as $name) {
            $event = Webhook::verify($v['payload'], [$name => $v['signature'], 'content-type' => 'application/json'], self::$secret, now: $v['timestamp']);
            self::assertSame('evt_a1B2c3D4e5F6g7H8', $event['id'], $name);
        }
        // PSR-7 getHeaders() and $_SERVER shapes.
        self::assertSame('evt_a1B2c3D4e5F6g7H8', Webhook::verify($v['payload'], ['Textkit-Signature' => [$v['signature']]], self::$secret, now: $v['timestamp'])['id']);
        self::assertSame('evt_a1B2c3D4e5F6g7H8', Webhook::verify($v['payload'], ['HTTP_TEXTKIT_SIGNATURE' => $v['signature']], self::$secret, now: $v['timestamp'])['id']);
        $this->assertInvalid(fn () => Webhook::verify($v['payload'], ['x-other' => '1'], self::$secret, now: $v['timestamp']), 'Missing');
    }

    public function testHeaderHelpers(): void
    {
        self::assertSame('t=1,v1=aa', Webhook::signatureFromHeaders(['dsms-signature' => 't=1,v1=aa']));
        self::assertSame('new', Webhook::signatureFromHeaders(['dsms-signature' => 'old', 'textkit-signature' => 'new']));
        self::assertSame('evt_1', Webhook::eventIdFromHeaders(['Resms-Event-Id' => 'evt_1']));
        self::assertNull(Webhook::eventIdFromHeaders([]));
    }

    public function testTamperedPayload(): void
    {
        $v = self::$vectors[0];
        $this->assertInvalid(fn () => Webhook::verify(str_replace('0006', '0007', $v['payload']), $v['signature'], self::$secret, now: $v['timestamp']), 'does not match');
    }

    public function testReencodedJsonFails(): void
    {
        $v = self::$vectors[1];
        $reencoded = json_encode(json_decode($v['payload'], true)); // escapes unicode: different bytes
        $this->assertInvalid(fn () => Webhook::verify($reencoded, $v['signature'], self::$secret, now: $v['timestamp']), 'does not match');
    }

    public function testWrongSecret(): void
    {
        $v = self::$vectors[0];
        $this->assertInvalid(fn () => Webhook::verify($v['payload'], $v['signature'], 'whsec_other', now: $v['timestamp']), 'does not match');
    }

    public function testToleranceBothDirections(): void
    {
        $v = self::$vectors[0];
        $t = $v['timestamp'];
        Webhook::verify($v['payload'], $v['signature'], self::$secret, now: $t + 300);
        $this->assertInvalid(fn () => Webhook::verify($v['payload'], $v['signature'], self::$secret, now: $t + 301), 'tolerance');
        $this->assertInvalid(fn () => Webhook::verify($v['payload'], $v['signature'], self::$secret, now: $t - 301), 'tolerance');
        self::assertSame('evt_a1B2c3D4e5F6g7H8', Webhook::verify($v['payload'], $v['signature'], self::$secret, tolerance: 0, now: $t + 10_000)['id']);
        // Real clock: the 2026 vector is far outside 5 minutes.
        $this->assertInvalid(fn () => Webhook::verify($v['payload'], $v['signature'], self::$secret), 'tolerance');
    }

    public function testForgedTimestamp(): void
    {
        $v = self::$vectors[0];
        $sig = explode('v1=', $v['signature'])[1];
        $forged = 't=' . ($v['timestamp'] + 5) . ",v1={$sig}";
        $this->assertInvalid(fn () => Webhook::verify($v['payload'], $forged, self::$secret, now: $v['timestamp'] + 5), 'does not match');
    }

    public function testRotationAnyV1Matches(): void
    {
        $v = self::$vectors[0];
        $good = hash_hmac('sha256', $v['timestamp'] . '.' . $v['payload'], self::$secret);
        $header = "t={$v['timestamp']},v1=" . str_repeat('0', 64) . ',v1=' . strtoupper($good);
        self::assertSame('evt_a1B2c3D4e5F6g7H8', Webhook::verify($v['payload'], $header, self::$secret, now: $v['timestamp'])['id']);
    }

    public function testMissingAndMalformed(): void
    {
        $v = self::$vectors[0];
        $this->assertInvalid(fn () => Webhook::verify($v['payload'], null, self::$secret), 'Missing');
        $this->assertInvalid(fn () => Webhook::verify($v['payload'], '', self::$secret), 'Missing');
        foreach (['v1=abc', "t={$v['timestamp']}", 'garbage', 't=-1,v1=aa', 't=12a,v1=aa'] as $bad) {
            $this->assertInvalid(fn () => Webhook::verify($v['payload'], $bad, self::$secret), 'Malformed');
        }
        $this->assertInvalid(fn () => Webhook::verify($v['payload'], $v['signature'], ''), 'secret');
    }
}
