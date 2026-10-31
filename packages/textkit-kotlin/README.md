# TextKit for Kotlin and Java

Official JVM client for the [TextKit](https://jointextkit.com) API: SMS,
phone verification, and phone numbers. Kotlin first, and every call works from
plain Java. Java 11+, one dependency.

```kotlin
// build.gradle.kts
dependencies {
    implementation("com.jointextkit:textkit:0.1.0")
}
```

```xml
<!-- pom.xml -->
<dependency>
  <groupId>com.jointextkit</groupId>
  <artifactId>textkit</artifactId>
  <version>0.1.0</version>
</dependency>
```

Not on Maven Central yet. Until it is, run `./gradlew publishToMavenLocal` in
this folder and add `mavenLocal()` to your repositories.

Get a free key (no card) at [the console](https://jointextkit.com/console).

## Send an SMS

```kotlin
import com.jointextkit.TextKit

val client = TextKit() // reads TEXTKIT_API_KEY

val message = client.messages.send("+15005550006", "Hello from TextKit")
println(message.id) // msg_...
```

```java
import com.jointextkit.TextKit;

TextKit client = new TextKit(); // reads TEXTKIT_API_KEY

Message message = client.messages().send("+15005550006", "Hello from TextKit");
System.out.println(message.getId()); // msg_...
```

`from` is optional while your account has one number (a sandbox account
does): the client looks it up once and reuses it. With several numbers, pass
`from` or set `TEXTKIT_FROM`.

Retries are safe. An `Idempotency-Key` is generated for every send, so a
network blip can never double-send. Pass your own to control it:

```kotlin
client.messages.send(to, body, idempotencyKey = "order:$orderId")
```

Every option goes through a params object. Its setters chain, so it reads
like a builder in Java too:

```kotlin
client.messages.send(
    SendMessageParams(to, "Your table is ready")
        .from("+14155550100")
        .customerId("cus_...")
        .category("transactional"),
)
```

## Phone verification

```kotlin
client.verify.send("+14155550132")
val result = client.verify.check("+14155550132", code)
if (result.verified) {
    // signed in
}
```

You don't store codes or own a number, and you're billed only when `verified`
comes back true.

## Everything else

```kotlin
client.messages.get("msg_...")
client.messages.list(ListMessagesParams().limit(25))          // one page
for (m in client.messages.listAll()) { /* ... */ }            // every page, fetched as you iterate
client.messages.schedule(to, "Reminder", Instant.parse("2026-11-01T15:00:00Z"))

client.numbers.available("415")
client.numbers.buy("+14155550132")
client.numbers.list()
client.numbers.release("+14155550132")

client.lookup.phone("+14155550132")                           // carrier, line type
client.balance.get().balanceUsd                               // prepaid credit balance

client.events.list(limit = 25)
for (e in client.events.listAll(type = "message.delivered")) { /* ... */ }

// Long-poll for new events instead of hosting a webhook.
var cursor = client.events.wait().cursor            // Java: waitForEvents()
while (true) {
    val batch = client.events.wait(cursor)
    batch.data.forEach { /* de-duplicate by it.id */ }
    cursor = batch.cursor
}

// Automations: send events from your app; a flow sends, waits, and branches.
// The first call for a user links userId to their phone number.
client.events.track("trial_started", userId = "123", phone = "+14155550132")
client.events.track("subscription_created", userId = "123")
val flow = client.automations.create(
    CreateAutomationParams(
        "Trial reminder",
        mapOf("event" to "trial_started"),
        listOf(
            mapOf("type" to "wait", "seconds" to 3600),
            mapOf("type" to "send_sms", "body" to "Your trial is live. Reply STOP to opt out."),
        ),
    ).from("+15005550100"),
)
client.automations.activate(flow.id)
client.automations.runs(flow.id)                              // each run, with its timeline

client.consent.get("+14155550132")                            // status + history
client.consent.optOut("+14155550132", note = "CRM sync")
client.consent.optIn("+14155550132")
// For one registration (what marketing from its numbers looks for); proof is
// required when the registration is marketing or mixed.
client.consent.optIn(
    "+14155550132",
    campaignId = "reg_a1B2c3D4e5F6",
    proof = mapOf("source" to "web_form", "collected_at" to "2026-10-01T15:04:05Z", "page_url" to "https://acme.example/texts"),
)
client.consent.import(listOf("+14155550132", "+14155550133")) // Java: importNumbers(...)
val csv = client.consent.export()
```

Any endpoint without a method yet is one call away:

```kotlin
val batches: JsonElement = client.request("GET", "/batches")
```

## Recurring schedules

One message to one number on a repeating local time. Each occurrence is a
normal send: opt-outs, quota and your spend limit are checked when it fires.

```kotlin
val schedule = client.schedules.create(
    "+14155550132",
    "Good morning. You have got this.",
    ScheduleRepeat.daily("08:00", "America/New_York"),
)
schedule.nextRunAt                                  // the next 08:00 in New York, in UTC
client.schedules.pause(schedule.id)                 // resume(id) starts again from now
client.messages.list(ListMessagesParams().scheduleId(schedule.id))
client.schedules.update(schedule.id, UpdateScheduleParams().body("New text").endDate(null)) // null clears
client.schedules.delete(schedule.id)
```

`ScheduleRepeat.weekly(listOf("mon", "fri"), ...)` and
`ScheduleRepeat.monthly(1, ...)` cover the other frequencies. The time is a
wall-clock time and stays put across daylight saving.

## Contacts

One contact per phone number. Tags double as broadcast audiences.

```kotlin
client.contacts.upsert("+14155550132", name = "Ada", tags = listOf("vip"))

// Sync from your own database, up to 500 per call.
client.contacts.import(users.map { ContactParams(it.phone).name(it.name) }) // Java: importContacts(...)

for (c in client.contacts.listAll(ListContactsParams().tag("vip"))) {
    println(c.phoneNumber)
}
```

## Customers (for platforms)

If you send for other businesses, label the traffic so usage, messages, and
webhooks come back per customer. Entirely optional.

```kotlin
val acme = client.customers.create(name = "Acme Dental", externalId = "acct_42")
client.numbers.buy("+14155550132", customerId = acme.id)  // or numbers.update(...)

client.messages.send(to, "Your cleaning is tomorrow", from = "+14155550132")
// -> message.customerId == acme.id, inherited from the number

client.messages.list(ListMessagesParams().customerId(acme.id))
client.customers.usage(acme.id, start = "2026-10-01", end = "2026-10-31")
```

## Registrations (business texting)

A US local number texts the public only once its registration is approved.
The first submit for a business carries an attestation signed by someone
authorized to act for it; we verify the business, then file. Every submit
carries `feesAcknowledged = true`: carrier registration fees are billed at
cost, a campaign carries a 3-month minimum, and they are non-refundable even
if the registration is rejected.

```kotlin
val reg = client.registrations.create(
    RegistrationParams()
        .businessName("Acme Plumbing LLC")
        .website("https://acmeplumbing.com")
        .useCase("customer_care")
        .optInUrl("https://acmeplumbing.com/text-updates")
        .sampleMessages(listOf(
            "Acme Plumbing: Hi Sam, your plumber Dana arrives tomorrow between 9 and 11 AM. Reply STOP to opt out.",
            "Acme Plumbing: Your job #4821 is done. Reply here with any questions.",
        ))
        .brand(mapOf("legal_name" to "Acme Plumbing LLC", "ein" to "12-3456789" /* ... */)),
)
if (reg.status == "ready") {
    client.registrations.submit(reg.id, feesAcknowledged = true, attestation = Attestation("Dana Smith", "Owner"))
}
```

## Webhooks

```kotlin
import com.jointextkit.WebhookSignature

// Spring: @PostMapping("/webhooks/textkit")
fun hook(@RequestBody body: ByteArray, @RequestHeader headers: Map<String, String>): ResponseEntity<Void> {
    val event = try {
        WebhookSignature.verify(body, headers, System.getenv("TEXTKIT_WEBHOOK_SECRET")) // raw bytes, not parsed JSON
    } catch (e: TextKitException) {
        return ResponseEntity.badRequest().build()
    }
    when (event.type) { /* "message.delivered", "message.received", ... */ }
    return ResponseEntity.ok().build()
}
```

```java
Event event = WebhookSignature.verify(body, request.getHeader("textkit-signature"), secret);
```

Signatures older than 5 minutes are rejected (`toleranceSeconds = 300`) so a
captured request can't be replayed. Pass the request's headers map and the
signature is read from `textkit-signature`, or the older `dsms-signature` /
`resms-signature`, in any casing.

Endpoints can be managed from code too:

```kotlin
val endpoint = client.webhooks.create("https://example.com/webhooks/textkit", listOf("message.received"))
endpoint.secret // whsec_... returned once, here. Store it.

client.webhooks.list()
client.webhooks.update(endpoint.id, UpdateWebhookParams().active(false)) // pause
client.webhooks.delete(endpoint.id)
```

To receive webhooks on localhost without a tunnel, use the CLI that ships with
the Node package: `npx jointextkit login`, then
`npx jointextkit listen --forward-to http://localhost:8080/webhooks`. It
prints a signing secret; `WebhookSignature.verify` accepts its requests
unchanged.

## Errors

Every failure throws `TextKitException` (unchecked):

```kotlin
try {
    client.verify.send(phone)
} catch (err: TextKitException) {
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
| `quiet_hours` | 403 | A marketing message outside 8:00am to 9:00pm in the recipient's local time. `sendAfter` is the next allowed time; `recipientLocalTime` and `timezone` say what we read. Send it then, or pass `quietHours("defer")` to have it held. Mark marketing sends with `category("marketing")`. |
| `quota_exceeded` | 429 | A free-tier or daily limit was reached. |
| `rate_limited` | 429 | Slow down; see `retryAfter`. |

429s, 5xx, timeouts, and connection errors are retried with exponential
backoff, honoring `Retry-After`. Two things are deliberately **not** retried:
a `POST` without an idempotency key (a verification send, a number purchase,
unless you pass `idempotencyKey`), and a verification cooldown, which is
policy, not a blip.

## Testing

Test keys (`ssms_sk_test_...`) cost nothing and simulate: the message reaches
`delivered` with `simulated = true` and no text is sent, except to your own
verified phone. `client.isTestMode` tells you which you have. Magic numbers
and codes are in the [sandbox docs](https://jointextkit.com/docs/sandbox).

## Options

```kotlin
TextKit.builder()
    .apiKey(key)                        // default: TEXTKIT_API_KEY
    .defaultFrom("+14155550100")        // default: TEXTKIT_FROM, else your only number
    .baseUrl("https://api.jointextkit.com/v1")
    .maxRetries(2)
    .timeout(Duration.ofSeconds(30))
    .transport(myTransport)             // (TransportRequest) -> TransportResponse
    .build()
```

The client is thread-safe; create one and share it. Calls block the calling
thread. From coroutines, wrap them in `withContext(Dispatchers.IO)`.

Responses are Kotlin data classes (getters from Java). Fields the API may
leave out are nullable, status fields are plain strings so a new value never
breaks you, and open-ended objects (`data`, `metadata`, `brand`) are kotlinx
`JsonObject`s, which are `Map<String, JsonElement>` from Java.

## Why kotlinx.serialization

The HTTP layer is the JDK's own `java.net.http.HttpClient`, so the only
dependency is `kotlinx-serialization-json` (plus the Kotlin standard
library). It generates the JSON code at compile time: no reflection, no
annotation processor in your build, nothing to configure for ProGuard or
GraalVM native images. It comes from JetBrains alongside the Kotlin compiler,
so it tracks Kotlin releases, and it handles nullable fields, defaults and
unknown keys the way an API client needs. Moshi would work too, but needs
either `kotlin-reflect` (about 3 MB) or a KSP code generator in your build.

If you want connection pooling settings, proxies, or tracing, pass your own
`HttpClient` to `JavaHttpTransport`, or implement `Transport`.

MIT © Truelabel Inc
