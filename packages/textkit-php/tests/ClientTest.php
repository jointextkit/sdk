<?php

declare(strict_types=1);

namespace TextKit\Tests;

use PHPUnit\Framework\TestCase;
use TextKit\Client;
use TextKit\TextKitException;

/** Client behaviour against a scripted in-memory transport. No network. */
final class ClientTest extends TestCase
{
    private const KEY = 'ssms_sk_test_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    private const MSG = ['id' => 'msg_1', 'object' => 'message', 'to' => '+15005550006', 'from' => '+15005550100', 'body' => 'hi'];
    private const ENV = [
        'TEXTKIT_API_KEY', 'SIMPLESMS_API_KEY', 'DELIVERED_API_KEY', 'RESMS_API_KEY',
        'TEXTKIT_BASE_URL', 'SIMPLESMS_BASE_URL', 'DELIVERED_BASE_URL', 'RESMS_BASE_URL',
        'TEXTKIT_FROM', 'SIMPLESMS_FROM', 'DELIVERED_FROM',
    ];

    /** @var list<float> */
    private array $sleeps = [];

    protected function setUp(): void
    {
        $this->clearEnv();
    }

    protected function tearDown(): void
    {
        $this->clearEnv();
    }

    private function clearEnv(): void
    {
        foreach (self::ENV as $name) {
            putenv($name);
            unset($_ENV[$name]);
        }
    }

    private function client(FakeTransport $t, ?string $defaultFrom = '+15005550100', int $maxRetries = 2): Client
    {
        $this->sleeps = [];
        return new Client(
            self::KEY,
            defaultFrom: $defaultFrom,
            baseUrl: 'https://api.test',
            maxRetries: $maxRetries,
            transport: $t,
            sleep: function (float $s): void {
                $this->sleeps[] = $s;
            },
        );
    }

    /** @param array<string, mixed> $extra */
    private static function err(int $status, string $code, array $extra = [], array $headers = []): array
    {
        return [$status, ['error' => ['code' => $code, 'message' => 'nope'] + $extra], $headers];
    }

    private static function page(array $data = [], bool $hasMore = false, ?string $next = null): array
    {
        return ['data' => $data, 'has_more' => $hasMore, 'next_cursor' => $next];
    }

    private function expectApiError(callable $fn): TextKitException
    {
        try {
            $fn();
        } catch (TextKitException $e) {
            return $e;
        }
        self::fail('expected TextKitException');
    }

    // ── construction ────────────────────────────────────────────────────

    public function testReadsEnvKey(): void
    {
        putenv('TEXTKIT_API_KEY=' . self::KEY);
        self::assertTrue((new Client(transport: new FakeTransport()))->isTestMode());
    }

    public function testLegacyEnvNamesStillRead(): void
    {
        foreach (['SIMPLESMS_API_KEY', 'DELIVERED_API_KEY', 'RESMS_API_KEY'] as $name) {
            $this->clearEnv();
            putenv("{$name}=" . self::KEY);
            self::assertTrue((new Client(transport: new FakeTransport()))->isTestMode(), $name);
        }
        $this->clearEnv();
        putenv('DELIVERED_BASE_URL=https://old.test/');
        self::assertSame('https://old.test/v1', (new Client(self::KEY, transport: new FakeTransport()))->baseUrl);
    }

    public function testNewEnvNameWins(): void
    {
        putenv('TEXTKIT_API_KEY=ssms_sk_live_' . str_repeat('n', 32));
        putenv('DELIVERED_API_KEY=' . self::KEY);
        putenv('TEXTKIT_BASE_URL=https://new.test');
        putenv('DELIVERED_BASE_URL=https://old.test');
        $c = new Client(transport: new FakeTransport());
        self::assertFalse($c->isTestMode());
        self::assertSame('https://new.test/v1', $c->baseUrl);
    }

    public function testDefaultBaseUrlAndNormalization(): void
    {
        self::assertSame('https://api.jointextkit.com/v1', (new Client(self::KEY))->baseUrl);
        foreach (['https://x.test', 'https://x.test/', 'https://x.test/v1', 'https://x.test/v1/'] as $in) {
            self::assertSame('https://x.test/v1', (new Client(self::KEY, baseUrl: $in))->baseUrl, $in);
        }
    }

    public function testEveryKeyPrefixIsRecognised(): void
    {
        foreach (['ssms', 'dsms', 'resms'] as $p) {
            self::assertTrue((new Client("{$p}_sk_test_" . str_repeat('a', 32)))->isTestMode(), $p);
            self::assertFalse((new Client("{$p}_sk_live_" . str_repeat('a', 32)))->isTestMode(), $p);
        }
    }

    public function testMissingKeyThrows(): void
    {
        $e = $this->expectApiError(fn () => new Client());
        self::assertSame('invalid_api_key', $e->errorCode);
        self::assertSame(0, $e->status);
    }

    // ── messages ────────────────────────────────────────────────────────

    public function testSendShapeAuthAndIdempotency(): void
    {
        $t = new FakeTransport([201, self::MSG]);
        $out = $this->client($t)->messages->send(to: '+15005550006', text: 'hi', from: '+15005550199');
        self::assertSame('msg_1', $out['id']);
        $call = $t->calls[0];
        self::assertSame(['POST', 'https://api.test/v1/messages'], [$call['method'], $call['url']]);
        self::assertSame(['to' => '+15005550006', 'body' => 'hi', 'from' => '+15005550199'], $call['json']);
        self::assertSame('Bearer ' . self::KEY, $call['headers']['Authorization']);
        self::assertStringStartsWith('sdk_', $call['headers']['Idempotency-Key']);
        self::assertSame('jointextkit-php/' . Client::VERSION, $call['headers']['User-Agent']);
        self::assertSame('application/json', $call['headers']['Content-Type']);
        self::assertSame(30.0, $call['timeout']);
    }

    public function testSendOptionalFieldsAndOwnKey(): void
    {
        $t = new FakeTransport([201, self::MSG]);
        $this->client($t)->messages->send(
            '+15005550006',
            'hi',
            customerId: 'cus_x',
            category: 'marketing',
            quietHours: 'defer',
            consent: ['source' => 'checkout', 'collected_at' => '2026-10-01T00:00:00Z'],
            idempotencyKey: 'order:1',
        );
        self::assertSame([
            'to' => '+15005550006',
            'body' => 'hi',
            'from' => '+15005550100',
            'customer_id' => 'cus_x',
            'category' => 'marketing',
            'quiet_hours' => 'defer',
            'consent' => ['source' => 'checkout', 'collected_at' => '2026-10-01T00:00:00Z'],
        ], $t->calls[0]['json']);
        self::assertSame('order:1', $t->calls[0]['headers']['Idempotency-Key']);
    }

    public function testUnicodeIsSentUnescaped(): void
    {
        $t = new FakeTransport([201, self::MSG]);
        $this->client($t)->messages->send('+15005550006', 'Café ☕ https://x.test/a');
        self::assertStringContainsString('"Café ☕ https://x.test/a"', $t->calls[0]['raw']);
    }

    public function testSendRequiresABody(): void
    {
        $e = $this->expectApiError(fn () => $this->client(new FakeTransport())->messages->send(to: '+15005550006'));
        self::assertSame('body', $e->param);
    }

    public function testSendRetries5xxWithTheSameKey(): void
    {
        $t = new FakeTransport(self::err(502, 'carrier_error'), [201, self::MSG]);
        $this->client($t)->messages->send(to: '+15005550006', body: 'hi');
        self::assertCount(2, $t->calls);
        self::assertSame($t->calls[0]['headers']['Idempotency-Key'], $t->calls[1]['headers']['Idempotency-Key']);
        self::assertCount(1, $this->sleeps);
    }

    public function test429HonorsRetryAfterHeaderAndBody(): void
    {
        $t = new FakeTransport(self::err(429, 'rate_limited', [], ['retry-after' => '7']), [200, self::page()]);
        $this->client($t)->messages->list();
        self::assertSame([7.0], $this->sleeps);

        $t = new FakeTransport(self::err(429, 'rate_limited', ['retry_after' => 3]), [200, self::MSG]);
        $this->client($t)->messages->get('msg_1');
        self::assertSame([3.0], $this->sleeps);
    }

    public function testBackoffGrows(): void
    {
        $t = new FakeTransport(self::err(503, 'internal_error'), self::err(503, 'internal_error'), self::err(503, 'internal_error'), [200, self::MSG]);
        $this->client($t, maxRetries: 3)->messages->get('msg_1');
        self::assertCount(3, $this->sleeps);
        foreach ([0.5, 1.0, 2.0] as $i => $base) {
            self::assertGreaterThanOrEqual($base, $this->sleeps[$i]);
            self::assertLessThanOrEqual($base * 1.25, $this->sleeps[$i]);
        }
    }

    public function testGivesUpAfterMaxRetries(): void
    {
        $t = new FakeTransport(...array_fill(0, 3, self::err(503, 'internal_error')));
        $e = $this->expectApiError(fn () => $this->client($t)->messages->get('msg_1'));
        self::assertSame(503, $e->status);
        self::assertSame(503, $e->getCode());
        self::assertCount(3, $t->calls);
        self::assertCount(2, $this->sleeps);
    }

    public function testConnectionErrorsAreRetriedForGets(): void
    {
        $t = new FakeTransport(FakeTransport::down('slow', true), FakeTransport::down('reset'), [200, self::MSG]);
        self::assertSame('msg_1', $this->client($t)->messages->get('msg_1')['id']);
    }

    public function testConnectionErrorSurfaces(): void
    {
        $t = new FakeTransport(...array_fill(0, 3, FakeTransport::down('refused')));
        $e = $this->expectApiError(fn () => $this->client($t)->messages->get('msg_1'));
        self::assertSame(['connection_error', 0], [$e->errorCode, $e->status]);
        self::assertTrue($e->isRetryable());
        self::assertInstanceOf(\TextKit\TransportException::class, $e->getPrevious());

        $t = new FakeTransport(FakeTransport::down('slow', true));
        $e = $this->expectApiError(fn () => $this->client($t, maxRetries: 0)->messages->get('msg_1'));
        self::assertStringContainsString('timed out', $e->getMessage());
    }

    public function test4xxIsNotRetriedAndParsesTheEnvelope(): void
    {
        $t = new FakeTransport([400, ['error' => ['code' => 'invalid_request', 'message' => '`to` is bad', 'param' => 'to']]]);
        $e = $this->expectApiError(fn () => $this->client($t)->messages->send(to: 'nope', body: 'hi'));
        self::assertSame(['invalid_request', 400, 'to', '`to` is bad'], [$e->errorCode, $e->status, $e->param, $e->getMessage()]);
        self::assertFalse($e->isRetryable());
        self::assertCount(1, $t->calls);
    }

    public function testInsufficientCreditsAndQuietHoursFields(): void
    {
        $t = new FakeTransport(
            self::err(402, 'insufficient_credits', ['balance_micro_usd' => 100, 'required_micro_usd' => 800, 'top_up_url' => 'https://x/billing']),
            self::err(403, 'quiet_hours', ['send_after' => '2026-10-02T12:00:00Z', 'recipient_local_time' => '22:15', 'timezone' => 'America/New_York', 'message_id' => 'msg_b']),
        );
        $c = $this->client($t);
        $e = $this->expectApiError(fn () => $c->messages->send('+15005550006', 'hi'));
        self::assertSame([100, 800, 'https://x/billing'], [$e->balanceMicroUsd, $e->requiredMicroUsd, $e->topUpUrl]);
        self::assertFalse($e->isRetryable());
        $e = $this->expectApiError(fn () => $c->messages->send('+15005550006', 'hi'));
        self::assertSame(['2026-10-02T12:00:00Z', '22:15', 'America/New_York', 'msg_b'], [$e->sendAfter, $e->recipientLocalTime, $e->timezone, $e->messageId]);
    }

    public function testNonJsonErrorBody(): void
    {
        $t = new FakeTransport([500, '<html>bad gateway</html>']);
        $e = $this->expectApiError(fn () => $this->client($t, maxRetries: 0)->messages->get('msg_1'));
        self::assertSame('internal_error', $e->errorCode);
    }

    public function testDefaultFromIsLookedUpOnce(): void
    {
        $numbers = self::page([['phone_number' => '+15005550100', 'status' => 'active'], ['phone_number' => '+15005550109', 'status' => 'released']]);
        $t = new FakeTransport([200, $numbers], [201, self::MSG], [201, self::MSG]);
        $c = $this->client($t, defaultFrom: null);
        $c->messages->send(to: '+15005550006', text: 'a');
        $c->messages->send(to: '+15005550006', text: 'b');
        self::assertSame(1, count(array_filter($t->calls, fn ($x) => $x['url'] === 'https://api.test/v1/numbers')));
        self::assertSame('+15005550100', $t->calls[1]['json']['from']);
    }

    public function testDefaultFromRefusesToGuess(): void
    {
        $numbers = self::page([['phone_number' => '+1', 'status' => 'active'], ['phone_number' => '+2', 'status' => 'active']]);
        $t = new FakeTransport([200, $numbers]);
        $e = $this->expectApiError(fn () => $this->client($t, defaultFrom: null)->messages->send(to: '+15005550006', text: 'a'));
        self::assertSame('from', $e->param);
        self::assertStringContainsString('2 numbers', $e->getMessage());
    }

    public function testListAllFollowsCursors(): void
    {
        $t = new FakeTransport(
            [200, self::page([['id' => 'm3'], ['id' => 'm2']], true, 'k2')],
            [200, self::page([['id' => 'm1']])],
        );
        $ids = [];
        foreach ($this->client($t)->messages->listAll(limit: 2, customerId: 'cus_x') as $m) {
            $ids[] = $m['id'];
        }
        self::assertSame(['m3', 'm2', 'm1'], $ids);
        self::assertSame('/messages?limit=2&customer_id=cus_x', $t->calls[0]['path']);
        self::assertSame('/messages?limit=2&cursor=k2&customer_id=cus_x', $t->calls[1]['path']);
    }

    public function testScheduleSerializesDatetimeAsUtc(): void
    {
        $t = new FakeTransport([201, ['id' => 'sm_1', 'object' => 'scheduled_message']]);
        $when = new \DateTimeImmutable('2026-10-02 05:30:00', new \DateTimeZone('America/New_York'));
        $this->client($t)->messages->schedule('+15005550006', 'later', $when);
        self::assertSame('2026-10-02T09:30:00Z', $t->calls[0]['json']['scheduled_at']);
        self::assertArrayNotHasKey('Idempotency-Key', $t->calls[0]['headers']);
    }

    public function testListFilters(): void
    {
        $t = new FakeTransport([200, self::page()]);
        $this->client($t)->messages->list(status: 'blocked', blockedReason: 'quiet hours', scheduleId: 'sch_1');
        self::assertSame('/messages?schedule_id=sch_1&status=blocked&blocked_reason=quiet+hours', $t->calls[0]['path']);
    }

    // ── verify ──────────────────────────────────────────────────────────

    public function testVerifySendIsNotRetried(): void
    {
        $t = new FakeTransport(self::err(503, 'internal_error'));
        $this->expectApiError(fn () => $this->client($t)->verify->send('+14155550132', appName: 'Acme', customerId: 'cus_x'));
        self::assertCount(1, $t->calls);
        self::assertSame(['to' => '+14155550132', 'app_name' => 'Acme', 'customer_id' => 'cus_x'], $t->calls[0]['json']);
    }

    public function testVerifyCooldownIsPolicyNotRetried(): void
    {
        $t = new FakeTransport(self::err(429, 'rate_limited', ['retry_after' => 60]));
        $e = $this->expectApiError(fn () => $this->client($t)->verify->get('ver_1'));
        self::assertSame(60.0, $e->retryAfter);
        self::assertSame([], $this->sleeps);
    }

    public function testVerifyCheck(): void
    {
        $t = new FakeTransport([200, ['verified' => true, 'status' => 'approved']]);
        self::assertTrue($this->client($t)->verify->check('+14155550132', '111111')['verified']);
        self::assertSame(['to' => '+14155550132', 'code' => '111111'], $t->calls[0]['json']);
    }

    // ── numbers, lookup, balance ────────────────────────────────────────

    public function testNumbers(): void
    {
        $t = new FakeTransport([200, self::page()], [201, ['id' => 'num_1']], [200, self::page()], [200, ['id' => 'num_1']], self::err(503, 'internal_error'));
        $c = $this->client($t);
        $c->numbers->available(areaCode: '415');
        $c->numbers->buy('+15005550110', customerId: 'cus_x');
        $c->numbers->list(customerId: 'cus_x');
        $c->numbers->update('+15005550100', customerId: null);
        $this->expectApiError(fn () => $c->numbers->release('+15005550100'));

        self::assertSame('/numbers/available?area_code=415', $t->calls[0]['path']);
        self::assertSame(['phone_number' => '+15005550110', 'customer_id' => 'cus_x'], $t->calls[1]['json']);
        self::assertSame('/numbers?customer_id=cus_x', $t->calls[2]['path']);
        self::assertSame(['PATCH', 'https://api.test/v1/numbers/%2B15005550100'], [$t->calls[3]['method'], $t->calls[3]['url']]);
        self::assertSame('{"customer_id":null}', $t->calls[3]['raw']);
        self::assertCount(5, $t->calls, 'release is not retried');
        self::assertSame('DELETE', $t->calls[4]['method']);
    }

    public function testLookupAndBalance(): void
    {
        $t = new FakeTransport([200, ['line_type' => 'mobile']], [200, ['balance_usd' => 2.5]]);
        $c = $this->client($t);
        self::assertSame('mobile', $c->lookup->phone('+14155550132')['line_type']);
        self::assertSame(2.5, $c->balance->get()['balance_usd']);
        self::assertSame('/lookup/%2B14155550132', $t->calls[0]['path']);
        self::assertSame('/balance', $t->calls[1]['path']);
    }

    // ── events ──────────────────────────────────────────────────────────

    public function testEventsWaitAndTrack(): void
    {
        $t = new FakeTransport(
            [200, ['object' => 'event_wait', 'data' => [], 'cursor' => 'c1', 'has_more' => false]],
            [200, ['object' => 'event_wait', 'data' => [['id' => 'evt_1']], 'cursor' => 'c2', 'has_more' => false]],
            [201, ['id' => 'tev_1', 'runs_started' => ['run_1']]],
            [201, ['id' => 'tev_2']],
        );
        $c = $this->client($t);
        $first = $c->events->wait();
        $second = $c->events->wait(cursor: $first['cursor'], timeout: 20);
        self::assertSame('evt_1', $second['data'][0]['id']);
        self::assertSame('/events/wait', $t->calls[0]['path']);
        self::assertSame('/events/wait?cursor=c1&timeout=20', $t->calls[1]['path']);

        $r = $c->events->track('trial_started', userId: '123', phone: '+14155550132', properties: ['plan' => 'pro']);
        self::assertSame(['run_1'], $r['runs_started']);
        self::assertSame('/track', $t->calls[2]['path']);
        self::assertSame(['event' => 'trial_started', 'user_id' => '123', 'phone' => '+14155550132', 'properties' => ['plan' => 'pro']], $t->calls[2]['json']);
        self::assertNotEmpty($t->calls[2]['headers']['Idempotency-Key']);
        $c->events->track('subscription_created', userId: '123', idempotencyKey: 'mine');
        self::assertSame(['event' => 'subscription_created', 'user_id' => '123'], $t->calls[3]['json']);
        self::assertSame('mine', $t->calls[3]['headers']['Idempotency-Key']);
    }

    public function testEventsListAllStopsOnError(): void
    {
        $t = new FakeTransport([200, self::page([['id' => 'e1']], true, 'k')], self::err(404, 'not_found'));
        $seen = [];
        $e = $this->expectApiError(function () use ($t, &$seen) {
            foreach ($this->client($t)->events->listAll(type: 'message.delivered') as $ev) {
                $seen[] = $ev['id'];
            }
        });
        self::assertSame(['e1'], $seen);
        self::assertSame('not_found', $e->errorCode);
        self::assertSame('/events?cursor=k&type=message.delivered', $t->calls[1]['path']);
    }

    // ── webhooks CRUD ───────────────────────────────────────────────────

    public function testWebhookCrud(): void
    {
        $ep = ['id' => 'we_1', 'object' => 'webhook_endpoint', 'url' => 'https://x.test/h', 'events' => ['message.received'], 'active' => true];
        $t = new FakeTransport([201, $ep + ['secret' => 'whsec_x']], [200, self::page([$ep])], [200, $ep], [200, $ep], [200, $ep], [200, ['id' => 'we_1', 'deleted' => true]]);
        $c = $this->client($t);
        $created = $c->webhooks->create('https://x.test/h', events: ['message.received'], description: 'prod');
        self::assertSame('whsec_x', $created['secret']);
        $c->webhooks->list();
        $c->webhooks->get('we_1');
        $c->webhooks->update('we_1', ['active' => false]);
        $c->webhooks->update('we_1', ['events' => '*', 'description' => null]);
        self::assertTrue($c->webhooks->delete('we_1')['deleted']);

        $calls = array_map(fn ($x) => [$x['method'], $x['path'], $x['json']], $t->calls);
        self::assertSame(['POST', '/webhooks', ['url' => 'https://x.test/h', 'events' => ['message.received'], 'description' => 'prod']], $calls[0]);
        self::assertSame(['GET', '/webhooks', null], $calls[1]);
        self::assertSame(['GET', '/webhooks/we_1', null], $calls[2]);
        self::assertSame(['PATCH', '/webhooks/we_1', ['active' => false]], $calls[3]);
        self::assertSame(['PATCH', '/webhooks/we_1', ['events' => '*', 'description' => null]], $calls[4]);
        self::assertSame(['DELETE', '/webhooks/we_1', null], $calls[5]);
    }

    public function testWebhookCreateIsNotRetried(): void
    {
        $t = new FakeTransport(self::err(503, 'internal_error'));
        $this->expectApiError(fn () => $this->client($t)->webhooks->create('https://x.test/h'));
        self::assertCount(1, $t->calls);
        self::assertSame(['url' => 'https://x.test/h'], $t->calls[0]['json']);
    }

    // ── consent ─────────────────────────────────────────────────────────

    public function testConsentCalls(): void
    {
        $t = new FakeTransport(
            [200, ['status' => 'opted_out']],
            [200, ['status' => 'opted_in']],
            [200, ['status' => 'opted_in']],
            [200, ['imported' => 1, 'skipped' => []]],
            [200, "phone,status\n+14155550132,opted_out\n"],
            [200, ['status' => 'none', 'history' => []]],
        );
        $c = $this->client($t);
        $c->consent->optOut('+14155550132', note: 'crm');
        $c->consent->optIn('+14155550132');
        $c->consent->optIn('+14155550132', campaignId: 'reg_1', proof: ['source' => 'web_form', 'collected_at' => '2026-10-01T15:04:05Z', 'page_url' => 'https://acme.example/texts']);
        $c->consent->import(['+14155550132']);
        $csv = $c->consent->export();
        $c->contacts->consent('+14155550132');

        self::assertSame(['status' => 'opted_out', 'note' => 'crm'], $t->calls[0]['json']);
        self::assertSame(['status' => 'opted_in'], $t->calls[1]['json']);
        self::assertSame(['status' => 'opted_in', 'campaign_id' => 'reg_1', 'proof' => ['source' => 'web_form', 'collected_at' => '2026-10-01T15:04:05Z', 'page_url' => 'https://acme.example/texts']], $t->calls[2]['json']);
        self::assertSame(['phone_numbers' => ['+14155550132']], $t->calls[3]['json']);
        self::assertStringStartsWith('phone,status', $csv);
        self::assertSame('/consent/%2B14155550132', $t->calls[0]['path']);
        self::assertSame(['GET', '/consent/%2B14155550132'], [$t->calls[5]['method'], $t->calls[5]['path']]);
    }

    // ── customers, contacts ─────────────────────────────────────────────

    public function testCustomers(): void
    {
        $t = new FakeTransport([201, ['id' => 'cus_x']], [200, []], [200, []], [200, []], [200, self::page()], [200, ['deleted' => true]]);
        $c = $this->client($t);
        $c->customers->create(name: 'Acme', externalId: 'acct_1', metadata: ['plan' => 'pro']);
        $c->customers->update('cus_x', ['name' => 'Acme']);
        $c->customers->update('cus_x', ['external_id' => null, 'metadata' => []]);
        $c->customers->usage('cus_x', start: '2026-10-01', end: '2026-10-31');
        $c->customers->list(externalId: 'acct 1');
        $c->customers->delete('cus_x');

        self::assertSame(['name' => 'Acme', 'external_id' => 'acct_1', 'metadata' => ['plan' => 'pro']], $t->calls[0]['json']);
        self::assertSame('{"name":"Acme"}', $t->calls[1]['raw']);
        self::assertSame('{"external_id":null,"metadata":{}}', $t->calls[2]['raw']);
        self::assertSame('/customers/cus_x/usage?start=2026-10-01&end=2026-10-31', $t->calls[3]['path']);
        self::assertSame('/customers?external_id=acct+1', $t->calls[4]['path']);
        self::assertSame('DELETE', $t->calls[5]['method']);
    }

    public function testContacts(): void
    {
        $t = new FakeTransport([200, ['id' => 'con_1']], [200, ['created' => 1]], [200, ['updated' => 2]], [200, []], [200, []], [200, self::page()], [200, ['deleted' => true]]);
        $c = $this->client($t);
        $c->contacts->upsert('+14155550132', name: 'Ada', tags: ['vip']);
        $c->contacts->import([['phone_number' => '+14155550133', 'name' => 'Bo']]);
        $c->contacts->bulk('add_tags', ['con_1', 'con_2'], tags: ['vip']);
        $c->contacts->get('con_1');
        $c->contacts->update('con_1', ['tags' => [], 'fields' => [], 'notes' => null]);
        $c->contacts->list(tag: 'vip', phoneNumber: '+14155550132');
        $c->contacts->delete('con_1');

        self::assertSame(['phone_number' => '+14155550132', 'name' => 'Ada', 'tags' => ['vip']], $t->calls[0]['json']);
        self::assertSame(['contacts' => [['phone_number' => '+14155550133', 'name' => 'Bo']]], $t->calls[1]['json']);
        self::assertSame(['action' => 'add_tags', 'ids' => ['con_1', 'con_2'], 'tags' => ['vip']], $t->calls[2]['json']);
        self::assertSame('{"tags":[],"fields":{},"notes":null}', $t->calls[4]['raw']);
        self::assertSame('/contacts?tag=vip&phone_number=%2B14155550132', $t->calls[5]['path']);
        self::assertSame(['DELETE', '/contacts/con_1'], [$t->calls[6]['method'], $t->calls[6]['path']]);
    }

    // ── automations, schedules, registrations ───────────────────────────

    public function testAutomationLifecycle(): void
    {
        $t = new FakeTransport(...array_fill(0, 8, [200, ['id' => 'auto_x']]));
        $c = $this->client($t);
        $c->automations->create(
            name: 'Trial reminder',
            from: '+15005550100',
            trigger: ['event' => 'trial_started'],
            steps: [['type' => 'wait', 'seconds' => 3600], ['type' => 'send_sms', 'body' => 'Hi']],
        );
        $c->automations->update('auto_x', ['topic_id' => null]);
        $c->automations->activate('auto_x');
        $c->automations->pause('auto_x');
        $c->automations->runs('auto_x', limit: 5);
        $c->automations->run('auto_x', 'run_1');
        $c->automations->cancelRun('auto_x', 'run_1');
        $c->automations->delete('auto_x');

        self::assertSame([
            'name' => 'Trial reminder',
            'from' => '+15005550100',
            'trigger' => ['event' => 'trial_started'],
            'steps' => [['type' => 'wait', 'seconds' => 3600], ['type' => 'send_sms', 'body' => 'Hi']],
        ], $t->calls[0]['json']);
        self::assertSame(['topic_id' => null], $t->calls[1]['json']);
        $paths = array_map(fn ($x) => $x['method'] . ' ' . $x['path'], $t->calls);
        self::assertSame([
            'POST /automations',
            'PATCH /automations/auto_x',
            'POST /automations/auto_x/activate',
            'POST /automations/auto_x/pause',
            'GET /automations/auto_x/runs?limit=5',
            'GET /automations/auto_x/runs/run_1',
            'DELETE /automations/auto_x/runs/run_1',
            'DELETE /automations/auto_x',
        ], $paths);
        self::assertNull($t->calls[2]['raw'], 'activate sends no body');
    }

    public function testSchedules(): void
    {
        $sch = ['id' => 'sch_x', 'next_run_at' => '2026-10-25T12:00:00Z'];
        $t = new FakeTransport(...array_fill(0, 8, [200, $sch]));
        $c = $this->client($t, defaultFrom: null);
        $repeat = ['frequency' => 'daily', 'time' => '08:00', 'timezone' => 'America/New_York'];
        $out = $c->schedules->create('+14155550132', 'Good morning', $repeat);
        $c->schedules->create('+14155550132', 'b', $repeat, from: '+15005550199', maxOccurrences: 5, idempotencyKey: 'mine');
        $c->schedules->get('sch_x');
        $c->schedules->list();
        $c->schedules->pause('sch_x');
        $c->schedules->resume('sch_x');
        $c->schedules->update('sch_x', ['body' => 'new', 'end_date' => null]);
        $c->schedules->delete('sch_x');

        self::assertSame('2026-10-25T12:00:00Z', $out['next_run_at']);
        // No default number configured: from is left for the API to pick.
        self::assertSame(['to' => '+14155550132', 'body' => 'Good morning', 'repeat' => $repeat], $t->calls[0]['json']);
        self::assertNotEmpty($t->calls[0]['headers']['Idempotency-Key']);
        self::assertSame('+15005550199', $t->calls[1]['json']['from']);
        self::assertSame(5, $t->calls[1]['json']['max_occurrences']);
        self::assertSame('mine', $t->calls[1]['headers']['Idempotency-Key']);
        $calls = array_map(fn ($x) => [$x['method'], $x['path'], $x['json']], array_slice($t->calls, 2));
        self::assertSame([
            ['GET', '/schedules/sch_x', null],
            ['GET', '/schedules', null],
            ['PATCH', '/schedules/sch_x', ['active' => false]],
            ['PATCH', '/schedules/sch_x', ['active' => true]],
            ['PATCH', '/schedules/sch_x', ['body' => 'new', 'end_date' => null]],
            ['DELETE', '/schedules/sch_x', null],
        ], $calls);
    }

    public function testScheduleUsesDefaultFrom(): void
    {
        $t = new FakeTransport([201, ['id' => 'sch_x']]);
        $this->client($t)->schedules->create('+14155550132', 'b', ['frequency' => 'daily', 'time' => '08:00', 'timezone' => 'UTC']);
        self::assertSame('+15005550100', $t->calls[0]['json']['from']);
    }

    public function testRegistrations(): void
    {
        $t = new FakeTransport(...array_fill(0, 4, [200, ['id' => 'reg_1', 'status' => 'ready']]));
        $c = $this->client($t);
        $reg = $c->registrations->create('Acme', 'https://acme.example', 'customer_care', ['opt_in_url' => 'https://acme.example/texts']);
        $c->registrations->recheck($reg['id'], ['website' => 'https://acme.example/']);
        $c->registrations->submit($reg['id'], feesAcknowledged: true, attestation: ['signer_name' => 'Dana', 'signer_title' => 'Owner', 'accepted' => true]);
        $c->registrations->submissions($reg['id']);

        self::assertSame(['business_name' => 'Acme', 'website' => 'https://acme.example', 'use_case' => 'customer_care', 'opt_in_url' => 'https://acme.example/texts'], $t->calls[0]['json']);
        self::assertSame(['attestation' => ['signer_name' => 'Dana', 'signer_title' => 'Owner', 'accepted' => true], 'fees_acknowledged' => true], $t->calls[2]['json']);
        $paths = array_map(fn ($x) => $x['method'] . ' ' . $x['path'], $t->calls);
        self::assertSame([
            'POST /registrations',
            'POST /registrations/reg_1/recheck',
            'POST /registrations/reg_1/submit',
            'GET /registrations/reg_1/submissions',
        ], $paths);
    }
}
