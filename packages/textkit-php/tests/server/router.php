<?php

// A stub API for CurlTransportTest, served by `php -S`. It echoes the
// request back as JSON, or answers the status a test asks for. No real API.

$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
$headers = [];
foreach ($_SERVER as $key => $value) {
    if (str_starts_with($key, 'HTTP_')) {
        $headers[strtolower(str_replace('_', '-', substr($key, 5)))] = $value;
    }
}
if (isset($_SERVER['CONTENT_TYPE'])) {
    $headers['content-type'] = $_SERVER['CONTENT_TYPE'];
}
if (isset($_SERVER['CONTENT_LENGTH'])) {
    $headers['content-length'] = $_SERVER['CONTENT_LENGTH'];
}

if ($path === '/v1/slow') {
    sleep(2);
}
if ($path === '/v1/rate-limited') {
    http_response_code(429);
    header('Content-Type: application/json');
    header('Retry-After: 0');
    echo json_encode(['error' => ['code' => 'rate_limited', 'message' => 'Slow down.']]);
    return true;
}

header('Content-Type: application/json');
header('X-Stub: yes');
echo json_encode([
    'method' => $_SERVER['REQUEST_METHOD'],
    'uri' => $_SERVER['REQUEST_URI'],
    'headers' => $headers,
    'body' => file_get_contents('php://input'),
], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
return true;
