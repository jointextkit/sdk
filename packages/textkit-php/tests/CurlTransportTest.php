<?php

declare(strict_types=1);

namespace TextKit\Tests;

use PHPUnit\Framework\TestCase;
use TextKit\Client;
use TextKit\CurlTransport;
use TextKit\TextKitException;

/**
 * The real curl transport against a local stub server (`php -S` with
 * tests/server/router.php). No real API calls.
 */
final class CurlTransportTest extends TestCase
{
    /** @var resource|null */
    private static $server = null;
    private static string $base = '';

    public static function setUpBeforeClass(): void
    {
        $sock = stream_socket_server('tcp://127.0.0.1:0');
        if ($sock === false) {
            return;
        }
        $port = (int) substr((string) strrchr((string) stream_socket_get_name($sock, false), ':'), 1);
        fclose($sock);

        $cmd = [PHP_BINARY, '-S', "127.0.0.1:{$port}", __DIR__ . '/server/router.php'];
        $proc = proc_open($cmd, [1 => ['file', '/dev/null', 'w'], 2 => ['file', '/dev/null', 'w']], $pipes);
        if (!is_resource($proc)) {
            return;
        }
        self::$server = $proc;
        self::$base = "http://127.0.0.1:{$port}";
        for ($i = 0; $i < 100; $i++) {
            $conn = @fsockopen('127.0.0.1', $port);
            if ($conn !== false) {
                fclose($conn);
                return;
            }
            usleep(50_000);
        }
    }

    public static function tearDownAfterClass(): void
    {
        if (self::$server !== null) {
            proc_terminate(self::$server);
            proc_close(self::$server);
        }
    }

    protected function setUp(): void
    {
        if (self::$server === null) {
            self::markTestSkipped('could not start the php -S stub server');
        }
    }

    private function client(float $timeout = 5.0, int $maxRetries = 0): Client
    {
        return new Client('ssms_sk_test_' . str_repeat('a', 32), baseUrl: self::$base, maxRetries: $maxRetries, timeout: $timeout, sleep: static function (): void {
        });
    }

    public function testPostSendsJsonHeadersAndPathEscapes(): void
    {
        $echo = $this->client()->request('POST', '/consent/' . Client::segment('+14155550132'), body: ['note' => 'Café ☕'], idempotencyKey: 'k1');
        self::assertSame('POST', $echo['method']);
        self::assertSame('/v1/consent/%2B14155550132', $echo['uri']);
        self::assertSame('{"note":"Café ☕"}', $echo['body']);
        self::assertSame('application/json', $echo['headers']['content-type']);
        self::assertSame('k1', $echo['headers']['idempotency-key']);
        self::assertStringStartsWith('Bearer ssms_sk_test_', $echo['headers']['authorization']);
        self::assertSame('jointextkit-php/' . Client::VERSION, $echo['headers']['user-agent']);
    }

    public function testGetWithQueryAndPatch(): void
    {
        $echo = $this->client()->request('GET', '/messages', query: ['limit' => 2, 'status' => 'blocked', 'cursor' => null]);
        self::assertSame('/v1/messages?limit=2&status=blocked', $echo['uri']);
        self::assertSame('', $echo['body']);

        $echo = $this->client()->request('PATCH', '/numbers/x', body: ['customer_id' => null]);
        self::assertSame(['PATCH', '{"customer_id":null}'], [$echo['method'], $echo['body']]);
    }

    public function testBodilessPostSendsAnEmptyBody(): void
    {
        $echo = $this->client()->request('POST', '/automations/a/activate');
        self::assertSame('POST', $echo['method']);
        self::assertSame('', $echo['body']);
        self::assertSame('0', $echo['headers']['content-length'] ?? '0');
        self::assertArrayNotHasKey('content-type', $echo['headers']);
    }

    public function testErrorStatusAndHeadersReachTheClient(): void
    {
        try {
            $this->client()->request('GET', '/rate-limited');
            self::fail('expected an error');
        } catch (TextKitException $e) {
            self::assertSame(['rate_limited', 429, 0.0, 'Slow down.'], [$e->errorCode, $e->status, $e->retryAfter, $e->getMessage()]);
        }
        $res = (new CurlTransport())->send('GET', self::$base . '/v1/x', [], null, 5.0);
        self::assertSame('yes', $res->headers['x-stub']);
    }

    public function testTimeoutIsAConnectionError(): void
    {
        try {
            $this->client(timeout: 0.3)->request('GET', '/slow');
            self::fail('expected a timeout');
        } catch (TextKitException $e) {
            self::assertSame('connection_error', $e->errorCode);
            self::assertStringContainsString('timed out', $e->getMessage());
        }
    }

    public function testConnectionRefused(): void
    {
        $sock = stream_socket_server('tcp://127.0.0.1:0');
        $name = (string) stream_socket_get_name($sock, false);
        fclose($sock); // nothing listens there now
        $client = new Client('ssms_sk_test_' . str_repeat('a', 32), baseUrl: "http://{$name}", maxRetries: 0);
        try {
            $client->messages->get('msg_1');
            self::fail('expected a connection error');
        } catch (TextKitException $e) {
            self::assertSame(['connection_error', 0], [$e->errorCode, $e->status]);
        }
    }
}
