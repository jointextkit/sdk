<?php

declare(strict_types=1);

namespace TextKit;

/** The default transport: ext-curl, nothing to install. */
final class CurlTransport implements Transport
{
    public function send(string $method, string $url, array $headers, ?string $body, float $timeout): Response
    {
        $ch = curl_init($url);
        if ($ch === false) {
            throw new TransportException('Could not start a curl request.');
        }
        $lines = ['Expect:']; // no 100-continue round trip on larger bodies
        foreach ($headers as $name => $value) {
            $lines[] = "{$name}: {$value}";
        }
        if ($body === null && $method !== 'GET' && $method !== 'DELETE') {
            // A bodiless POST still sends Content-Length: 0, without curl's
            // default form content type.
            $body = '';
            $lines[] = 'Content-Type:';
        }
        $received = [];
        curl_setopt_array($ch, [
            CURLOPT_CUSTOMREQUEST => $method,
            CURLOPT_HTTPHEADER => $lines,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_TIMEOUT_MS => (int) round($timeout * 1000),
            CURLOPT_CONNECTTIMEOUT_MS => (int) round(min($timeout, 10.0) * 1000),
            CURLOPT_HEADERFUNCTION => static function ($_, string $line) use (&$received): int {
                $parts = explode(':', $line, 2);
                if (count($parts) === 2) {
                    $received[strtolower(trim($parts[0]))] = trim($parts[1]);
                }
                return strlen($line);
            },
        ]);
        if ($body !== null) {
            curl_setopt($ch, CURLOPT_POSTFIELDS, $body);
        }

        $out = curl_exec($ch);
        if ($out === false) {
            $errno = curl_errno($ch);
            $error = curl_error($ch);
            curl_close($ch);
            throw new TransportException($error !== '' ? $error : "curl error {$errno}", $errno === CURLE_OPERATION_TIMEDOUT);
        }
        $status = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        curl_close($ch);

        return new Response($status, $received, (string) $out);
    }
}
