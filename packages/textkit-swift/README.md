# TextKit for Swift (server)

Official Swift client for the [TextKit](https://jointextkit.com) API: SMS,
phone verification, and phone numbers. For servers: Vapor, Hummingbird,
command-line tools and jobs, on Linux and macOS. Swift 5.9+, async/await.

**This package is for your server, not your app.** The API key is a secret
that can send texts and spend your balance. Never ship it inside an iOS or
macOS app: anyone can pull it out of the binary. Your app calls your server;
your server calls TextKit.

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/jointextkit/textkit-swift.git", from: "0.1.0"),
],
targets: [
    .target(name: "App", dependencies: [.product(name: "TextKit", package: "textkit-swift")]),
]
```

Not tagged in a public repository yet. Until it is, depend on a local
checkout: `.package(path: "../textkit-swift")`.

Get a free key (no card) at [the console](https://jointextkit.com/console).

## Send an SMS

```swift
import TextKit

let client = try TextKit() // reads TEXTKIT_API_KEY

let message = try await client.messages.send(to: "+15005550006", body: "Hello from TextKit")
print(message.id) // msg_...
```

`from` is optional while your account has one number (a sandbox account
does): the client looks it up once and reuses it. With several numbers, pass
`from:` or set `TEXTKIT_FROM`.

Retries are safe. An `Idempotency-Key` is generated for every send, so a
network blip can never double-send. Pass your own to control it:

```swift
try await client.messages.send(to: to, body: body, idempotencyKey: "order:\(orderID)")
```

## Phone verification

```swift
try await client.verify.send(to: "+14155550132")
let result = try await client.verify.check(to: "+14155550132", code: code)
if result.verified {
    // signed in
}
```

You don't store codes or own a number, and you're billed only when
`verified` comes back true.

## Everything else

```swift
try await client.messages.get("msg_...")
try await client.messages.list(limit: 25)                    // one page
for try await m in client.messages.listAll() { ... }         // every page, fetched as you iterate
try await client.messages.schedule(to: to, body: "Reminder", sendAt: Date().addingTimeInterval(3600))

try await client.numbers.available(areaCode: "415")
try await client.numbers.buy("+14155550132")
try await client.numbers.list()
try await client.numbers.release("+14155550132")

try await client.lookup.phone("+14155550132")                // carrier, line type
try await client.balance.get().balanceUsd                    // prepaid credit balance

try await client.events.list(limit: 25)
for try await e in client.events.listAll(type: "message.delivered") { ... }

// Long-poll for new events instead of hosting a webhook.
var cursor = try await client.events.wait().cursor
while true {
    let batch = try await client.events.wait(cursor: cursor)
    for event in batch.data { ... }                          // de-duplicate by event.id
    cursor = batch.cursor
}

// Automations: send events from your app; a flow sends, waits, and branches.
// The first call for a user links userId to their phone number.
try await client.events.track("trial_started", userId: "123", phone: "+14155550132")
try await client.events.track("subscription_created", userId: "123")
let flow = try await client.automations.create(
    name: "Trial reminder",
    trigger: ["event": "trial_started"],
    steps: [
        ["type": "wait", "seconds": 3600],
        ["type": "send_sms", "body": "Your trial is live. Reply STOP to opt out."],
    ],
    from: "+15005550100"
)
try await client.automations.activate(flow.id)
try await client.automations.runs(flow.id)                   // each run, with its timeline

try await client.consent.get("+14155550132")                 // status + history
try await client.consent.optOut("+14155550132", note: "CRM sync")
try await client.consent.optIn("+14155550132")
// For one registration (what marketing from its numbers looks for); proof is
// required when the registration is marketing or mixed.
try await client.consent.optIn(
    "+14155550132",
    campaignId: "reg_a1B2c3D4e5F6",
    proof: ["source": "web_form", "collected_at": "2026-10-01T15:04:05Z", "page_url": "https://acme.example/texts"]
)
try await client.consent.import(["+14155550132", "+14155550133"])
let csv = try await client.consent.export()
```

Any endpoint without a method yet is one call away:

```swift
let batches: JSONValue = try await client.request("GET", "/batches")
```

## Recurring schedules

One message to one number on a repeating local time. Each occurrence is a
normal send: opt-outs, quota and your spend limit are checked when it fires.

```swift
let schedule = try await client.schedules.create(
    to: "+14155550132",
    body: "Good morning. You have got this.",
    repeat: .daily(at: "08:00", timezone: "America/New_York")
)
schedule.nextRunAt                                   // the next 08:00 in New York, in UTC
try await client.schedules.pause(schedule.id)        // resume(_:) starts again from now
try await client.messages.list(scheduleId: schedule.id)
try await client.schedules.update(schedule.id, body: "New text", endDate: .clear)
try await client.schedules.delete(schedule.id)
```

`.weekly(on: ["mon", "fri"], at:timezone:)` and `.monthly(onDay: 1, at:timezone:)`
cover the other frequencies. The time is a wall-clock time and stays put
across daylight saving.

In an update, a parameter you leave out is not sent, and `.clear` sends null,
which removes the stored value. String and number literals work directly
(`name: "Acme"`); wrap a variable in `.set(value)`.

## Contacts

One contact per phone number. Tags double as broadcast audiences.

```swift
try await client.contacts.upsert(phoneNumber: "+14155550132", name: "Ada", tags: ["vip"])

// Sync from your own database, up to 500 per call.
try await client.contacts.import(users.map { ContactInput(phoneNumber: $0.phone, name: $0.name) })

for try await c in client.contacts.listAll(tag: "vip") {
    print(c.phoneNumber ?? "")
}
```

## Customers (for platforms)

If you send for other businesses, label the traffic so usage, messages, and
webhooks come back per customer. Entirely optional.

```swift
let acme = try await client.customers.create(name: "Acme Dental", externalId: "acct_42")
try await client.numbers.buy("+14155550132", customerId: acme.id)  // or numbers.update(...)

try await client.messages.send(to: to, body: "Your cleaning is tomorrow", from: "+14155550132")
// -> message.customerId == acme.id, inherited from the number

try await client.messages.list(customerId: acme.id)
try await client.customers.usage(acme.id, start: "2026-10-01", end: "2026-10-31")
```

## Registrations (business texting)

A US local number texts the public only once its registration is approved.
The first submit for a business carries an attestation signed by someone
authorized to act for it; we verify the business, then file. Every submit
carries `feesAcknowledged: true`: carrier registration fees are billed at
cost, a campaign carries a 3-month minimum, and they are non-refundable even
if the registration is rejected.

```swift
let reg = try await client.registrations.create(
    businessName: "Acme Plumbing LLC",
    website: "https://acmeplumbing.com",
    useCase: "customer_care",
    fields: [
        "opt_in_url": "https://acmeplumbing.com/text-updates",
        "sample_messages": [
            "Acme Plumbing: Hi Sam, your plumber Dana arrives tomorrow between 9 and 11 AM. Reply STOP to opt out.",
            "Acme Plumbing: Your job #4821 is done. Reply here with any questions.",
        ],
        "brand": ["legal_name": "Acme Plumbing LLC", "ein": "12-3456789" /* ... */],
    ]
)
if reg.status == "ready" {
    try await client.registrations.submit(
        reg.id, feesAcknowledged: true, attestation: Attestation(signerName: "Dana Smith", signerTitle: "Owner")
    )
}
```

## Webhooks

```swift
import TextKit
import Vapor

app.post("webhooks", "textkit") { req async throws -> HTTPStatus in
    let body = req.body.data.map { Data(buffer: $0) } ?? Data()   // raw bytes, not decoded JSON
    let event: Event
    do {
        event = try WebhookSignature.verify(
            payload: body,
            signature: req.headers.first(name: "textkit-signature"),
            secret: Environment.get("TEXTKIT_WEBHOOK_SECRET") ?? ""
        )
    } catch {
        return .badRequest
    }
    switch event.type {
    case "message.received": ...
    default: break
    }
    return .ok
}
```

Signatures older than 5 minutes are rejected (`tolerance: 300`) so a captured
request can't be replayed. The signature is also sent as `dsms-signature` and
`resms-signature` (older header names); `WebhookSignature.verify(payload:headers:secret:)`
takes a `[String: String]` of headers and reads whichever arrived.

Endpoints can be managed from code too:

```swift
let endpoint = try await client.webhooks.create(url: "https://example.com/webhooks/textkit", events: ["message.received"])
endpoint.secret // whsec_... returned once, here. Store it.

try await client.webhooks.list()
try await client.webhooks.update(endpoint.id, active: false) // pause
try await client.webhooks.delete(endpoint.id)
```

To receive webhooks on localhost without a tunnel, use the CLI that ships with
the Node package: `npx jointextkit login`, then
`npx jointextkit listen --forward-to http://localhost:8080/webhooks/textkit`.
It prints a signing secret; `WebhookSignature.verify` accepts its requests
unchanged.

## Errors

Every failure throws `TextKitError`:

```swift
do {
    try await client.verify.send(to: phone)
} catch let err as TextKitError {
    err.code         // "verification_blocked", "rate_limited", ...
    err.status       // HTTP status (0 when the API was unreachable)
    err.param        // which field was wrong, when known
    err.retryAfter   // seconds, on rate limits
    err.isRetryable  // whether trying again could work
}
```

Codes you will want to handle:

| Code | Status | Meaning |
| --- | --- | --- |
| `insufficient_credits` | 402 | Your prepaid balance cannot cover the call. Nothing was sent or charged. `balanceMicroUsd`, `requiredMicroUsd` and `topUpUrl` say how short you are and where to add credits. Not retried: top up, then send again. |
| `spend_limit_reached` | 403 | Your own monthly spend limit is reached. |
| `recipient_opted_out` | 403 | The recipient unsubscribed. Do not retry. |
| `sender_not_registered` | 403 | The sending number is not registered yet; it can text your verified numbers only. |
| `quiet_hours` | 403 | A marketing message outside 8:00am to 9:00pm in the recipient's local time. `sendAfter` is the next allowed time; `recipientLocalTime` and `timezone` say what we read. Send it then, or pass `quietHours: "defer"` to have it held. Mark marketing sends with `category: "marketing"`. |
| `quota_exceeded` | 429 | A free-tier or daily limit was reached. |
| `rate_limited` | 429 | Slow down; see `retryAfter`. |

429s, 5xx, timeouts, and connection errors are retried with exponential
backoff, honoring `Retry-After`. Two things are deliberately **not** retried:
a `POST` without an idempotency key (a verification send, a number purchase,
unless you pass `idempotencyKey:`), and a verification cooldown, which is
policy, not a blip.

## Testing

Test keys (`ssms_sk_test_...`) cost nothing and simulate: the message reaches
`delivered` with `simulated == true` and no text is sent, except to your own
verified phone. `client.isTestMode` tells you which you have. Magic numbers
and codes are in the [sandbox docs](https://jointextkit.com/docs/sandbox).

## Options

```swift
try TextKit(
    apiKey: key,                          // default: TEXTKIT_API_KEY
    defaultFrom: "+14155550100",          // default: TEXTKIT_FROM, else your only number
    baseURL: "https://api.jointextkit.com/v1",
    maxRetries: 2,
    timeout: 30,
    transport: myTransport                // any HTTPTransport
)
```

The client is `Sendable`: create one at startup and share it. Responses are
`Codable` structs. Fields the API may leave out are optionals, status fields
are plain strings so a new value never breaks decoding, and open-ended
objects (`data`, `metadata`, `brand`) are `JSONValue`.

The default transport is Foundation's `URLSession` (`FoundationNetworking` on
Linux). In a Vapor app you can route calls through its `AsyncHTTPClient`
instead by conforming a small adapter to `HTTPTransport`.

## Dependencies

One: [swift-crypto](https://github.com/apple/swift-crypto), Apple's
open-source CryptoKit, for the HMAC-SHA256 behind webhook verification. It
gives the same API on Linux, where CryptoKit does not exist, and compares
signatures in constant time.

MIT © Truelabel Inc
