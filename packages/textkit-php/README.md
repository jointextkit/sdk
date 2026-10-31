# jointextkit/textkit (PHP)

Official PHP client for the [TextKit](https://jointextkit.com) API:
SMS, phone verification, and phone numbers. No dependencies beyond ext-curl
and ext-json, PHP 8.1+.

Version 0.1.0.

```bash
composer require jointextkit/textkit
```

Get a free key (no card) at [the console](https://jointextkit.com/console).

## Send an SMS

```php
use TextKit\Client;

$client = new Client(); // reads TEXTKIT_API_KEY

$message = $client->messages->send(to: '+15005550006', text: 'Hello from TextKit');
echo $message['id']; // msg_...
```

`from` is optional while your account has one number (a sandbox account
does): the client looks it up once and reuses it. With several numbers, pass
`from: '+1...'` or set `TEXTKIT_FROM`. `text` and `body` are the same thing.

Every call returns the API's JSON as an associative array.

Retries are safe. An `Idempotency-Key` is generated for every send, so a
network blip can never double-send. Pass your own to control it:

```php
$client->messages->send(to: $to, body: $body, idempotencyKey: "order:{$orderId}");
```

## Phone verification

```php
$client->verify->send(to: '+14155550132');
$result = $client->verify->check(to: '+14155550132', code: $code);
if ($result['verified']) {
    // ...
}
```

You don't store codes or own a number, and you're billed only when
`verified` comes back true.

## Everything else

```php
$client->messages->get('msg_...');
$client->messages->list(limit: 25);                  // one page
foreach ($client->messages->listAll() as $m) {       // every page, lazily
    // ...
}
$client->messages->schedule($to, 'Reminder', sendAt: new DateTimeImmutable('+1 hour'));

$client->numbers->available(areaCode: '415');
$client->numbers->buy('+14155550132');
$client->numbers->list();
$client->numbers->release('+14155550132');

$client->lookup->phone('+14155550132');              // carrier, line type

$client->events->list(limit: 25);
foreach ($client->events->listAll(type: 'message.delivered') as $e) {
    // ...
}

// Long-poll: the first call returns a cursor meaning "from now".
$wait = $client->events->wait();
$wait = $client->events->wait(cursor: $wait['cursor']);

// Automations: send events from your app; a flow sends, waits, and branches.
// The first call for a user links userId to their phone number.
$client->events->track('trial_started', userId: '123', phone: '+14155550132');
$client->events->track('subscription_created', userId: '123');
$flow = $client->automations->create(
    name: 'Trial reminder',
    from: '+15005550100',
    trigger: ['event' => 'trial_started'],
    steps: [
        ['type' => 'wait', 'seconds' => 3600],
        ['type' => 'send_sms', 'body' => 'Your trial is live. Reply STOP to opt out.'],
    ],
);
$client->automations->activate($flow['id']);
$client->automations->runs($flow['id']);             // each run, with its timeline

$client->consent->get('+14155550132');               // status + history
$client->consent->optOut('+14155550132', note: 'CRM sync');
$client->consent->optIn('+14155550132');
// For one registration (what marketing from its numbers looks for); proof is
// required when the registration is marketing or mixed.
$client->consent->optIn(
    '+14155550132',
    campaignId: 'reg_a1B2c3D4e5F6',
    proof: ['source' => 'web_form', 'collected_at' => '2026-10-01T15:04:05Z', 'page_url' => 'https://acme.example/texts'],
);
$client->consent->import(['+14155550132', '+14155550133']);
$csv = $client->consent->export();

$client->balance->get()['balance_usd'];              // prepaid credit balance
```

Update calls take an array and send only the keys you pass; a `null` value
clears that field:

```php
$client->customers->update($id, ['name' => 'Acme', 'external_id' => null]);
```

## Recurring schedules

One message to one number on a repeating local time. Each occurrence is a
normal send: opt-outs, quota and your spend limit are checked when it fires.

```php
$schedule = $client->schedules->create(
    to: '+14155550132',
    body: 'Good morning. You have got this.',
    repeat: ['frequency' => 'daily', 'time' => '08:00', 'timezone' => 'America/New_York'],
);
$schedule['next_run_at'];                    // the next 08:00 in New York, in UTC
$client->schedules->pause($schedule['id']);  // resume($id) starts again from now
$client->messages->list(scheduleId: $schedule['id']);
$client->schedules->delete($schedule['id']);
```

`frequency` is `daily`, `weekly` (with `'days_of_week' => ['mon', 'fri']`
inside `repeat`) or `monthly` (with `day_of_month`). The time is a wall-clock
time and stays put across daylight saving.

## Contacts

One contact per phone number. Tags double as broadcast audiences.

```php
$client->contacts->upsert('+14155550132', name: 'Ada', tags: ['vip']);

// Sync from your own database, up to 500 per call.
$client->contacts->import(array_map(fn ($u) => ['phone_number' => $u->phone, 'name' => $u->name], $users));

foreach ($client->contacts->listAll(tag: 'vip') as $c) {
    echo $c['phone_number'];
}
```

## Customers (for platforms)

If you send for other businesses, label the traffic so usage, messages, and
webhooks come back per customer. Entirely optional.

```php
$acme = $client->customers->create(name: 'Acme Dental', externalId: 'acct_42');
$client->numbers->buy('+14155550132', customerId: $acme['id']); // or numbers->update(...)

$client->messages->send(to: $to, text: 'Your cleaning is tomorrow', from: '+14155550132');
// -> $message['customer_id'] === $acme['id'], inherited from the number

$client->messages->list(customerId: $acme['id']);
$client->customers->usage($acme['id'], start: '2026-10-01', end: '2026-10-31');
```

## Registrations (business texting)

A US local number texts the public only once its registration is approved.
The first submit for a business carries an attestation signed by someone
authorized to act for it; we verify the business, then file. Every submit
carries `feesAcknowledged: true`: carrier registration fees are billed at
cost, a campaign carries a 3-month minimum, and they are non-refundable even
if the registration is rejected.

```php
$reg = $client->registrations->create(
    businessName: 'Acme Plumbing LLC',
    website: 'https://acmeplumbing.com',
    useCase: 'customer_care',
    fields: [
        'opt_in_url' => 'https://acmeplumbing.com/text-updates',
        'sample_messages' => [
            'Acme Plumbing: Hi Sam, your plumber Dana arrives tomorrow between 9 and 11 AM. Reply STOP to opt out.',
            'Acme Plumbing: Your job #4821 is done. Reply here with any questions.',
        ],
        'brand' => ['legal_name' => 'Acme Plumbing LLC', 'ein' => '12-3456789', 'entity_type' => 'PRIVATE_PROFIT' /* ... */],
    ],
);
if ($reg['status'] === 'ready') {
    $client->registrations->submit(
        $reg['id'],
        feesAcknowledged: true,
        attestation: ['signer_name' => 'Dana Smith', 'signer_title' => 'Owner', 'accepted' => true],
    );
}
```

## Webhooks

```php
use TextKit\TextKitException;
use TextKit\Webhook;

$payload = file_get_contents('php://input');    // raw body, not decoded JSON
try {
    $event = Webhook::verify($payload, getallheaders(), getenv('TEXTKIT_WEBHOOK_SECRET'));
} catch (TextKitException $e) {
    http_response_code(400);
    exit;
}
// $event['type'], $event['data'] ...
```

Signatures older than 5 minutes are rejected (`tolerance: 300`) so a
captured request can't be replayed. `$client->webhooks->verify(...)` is the
same function.

The second argument is the `textkit-signature` header value, or the
request's headers: `getallheaders()`, a PSR-7 `$request->getHeaders()`, or
`$_SERVER`. The signature is also sent as `dsms-signature` and
`resms-signature` (the header names from before the rename); a headers array
is searched for all three.

Endpoints can be managed from code too:

```php
$endpoint = $client->webhooks->create('https://example.com/webhooks/textkit', events: ['message.received']);
$endpoint['secret']; // whsec_... returned once, here. Store it.

$client->webhooks->list();
$client->webhooks->update($endpoint['id'], ['active' => false]); // pause
$client->webhooks->delete($endpoint['id']);
```

To receive webhooks on localhost without a tunnel, use the CLI that ships with
the Node package: `npx jointextkit login`, then
`npx jointextkit listen --forward-to http://localhost:8000/webhooks`. It
prints a signing secret; `Webhook::verify` accepts its requests unchanged.

## Errors

Every failure throws `TextKit\TextKitException`:

```php
use TextKit\TextKitException;

try {
    $client->verify->send(to: $phone);
} catch (TextKitException $e) {
    $e->errorCode;     // "verification_blocked", "rate_limited", ...
    $e->status;        // HTTP status (0 when the API was unreachable)
    $e->param;         // which field was wrong, when known
    $e->retryAfter;    // seconds, on rate limits
    $e->isRetryable(); // whether trying again could work
}
```

Codes you will want to handle:

| Code | Status | Meaning |
| --- | --- | --- |
| `insufficient_credits` | 402 | Your prepaid balance cannot cover the call. Nothing was sent or charged. `$e->balanceMicroUsd`, `$e->requiredMicroUsd` and `$e->topUpUrl` say how short you are and where to add credits. Not retried: top up, then send again. |
| `spend_limit_reached` | 403 | Your own monthly spend limit is reached. |
| `recipient_opted_out` | 403 | The recipient unsubscribed. Do not retry. |
| `sender_not_registered` | 403 | The sending number is not registered yet; it can text your verified numbers only. |
| `quiet_hours` | 403 | A marketing message outside 8:00am to 9:00pm in the recipient's local time. `$e->sendAfter` is the next allowed time; `$e->recipientLocalTime` and `$e->timezone` say what we read. Send it then, or pass `quietHours: 'defer'` to have it held. Mark marketing sends with `category: 'marketing'`. |
| `quota_exceeded` | 429 | A free-tier or daily limit was reached. |
| `rate_limited` | 429 | Slow down; see `$e->retryAfter`. |

429s, 5xx, timeouts, and connection errors are retried with exponential
backoff, honoring `Retry-After`. Two things are deliberately **not** retried:
a `POST` without an idempotency key (a verification send, a number purchase),
and a verification cooldown, which is policy, not a blip.

## Testing

Test keys (`ssms_sk_test_...`) cost nothing and simulate: the message reaches `delivered` with `'simulated' => true` and no text is sent, except to your own verified phone.
`$client->isTestMode()` tells you which you have. Magic numbers and codes are
in the [sandbox docs](https://jointextkit.com/docs/sandbox).

## Options

```php
new Client(
    $apiKey,                              // default: TEXTKIT_API_KEY
    defaultFrom: '+14155550100',          // default: TEXTKIT_FROM, else your only number
    baseUrl: 'https://api.jointextkit.com/v1',
    maxRetries: 2,
    timeout: 30.0,
    transport: $myTransport,              // TextKit\Transport: tests, tracing, proxies
);
```

`DELIVERED_API_KEY`, `DELIVERED_BASE_URL` and `DELIVERED_FROM` (the names
from before TextKit was renamed) are read when the `TEXTKIT_*` names are
unset.

## Why no dependencies

The client uses only ext-curl and ext-json, which nearly every PHP install
has. The API is plain JSON over HTTPS, so Guzzle or a PSR-18 stack would add
install weight and version conflicts without adding anything you'd notice.
If you want proxies or tracing, implement `TextKit\Transport`.

MIT © Truelabel Inc
