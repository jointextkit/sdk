# jointextkit

Official client for the [TextKit](https://jointextkit.com) API:
SMS, phone verification, and phone numbers. Zero dependencies, works
anywhere `fetch` does.

```bash
npm install jointextkit
```

Sign up free (no card) at [the console](https://jointextkit.com/console),
then log this machine in and receive webhooks locally:

```bash
npx jointextkit login      # approve in the browser; stores a test key
npx jointextkit listen --forward-to http://localhost:3000/webhooks
```

See [CLI](#cli).

## Phone verification

```js
import { TextKit } from 'jointextkit';

const sms = new TextKit(process.env.TEXTKIT_API_KEY);

await sms.verify.send({ to: '+14155550132' });
const { verified } = await sms.verify.check({ to: '+14155550132', code });
```

That's the whole integration. You don't store codes, you don't own a phone
number, and you're billed only when `verified` comes back true.

The response carries what a UI needs, so you don't track state yourself:

```js
const v = await sms.verify.send({ to: phone });
v.expires_in;         // 600  - for a countdown
v.attempts_remaining; // 5    - for "2 tries left"
```

By email instead, or when the text doesn't arrive:

```js
await sms.verify.send({ to: 'ada@example.com', channel: 'email' });

// Same verification, same single charge; the emailed code replaces the texted one.
await sms.verify.fallback(v.id, { email: 'ada@example.com' });
// The emailed code proves the address, not the phone: check it by email.
await sms.verify.check({ to: 'ada@example.com', code });
```

## Send an SMS

```js
const message = await sms.messages.send({
  to: '+16285550107',
  body: 'Your table is ready.',
});
```

Retries are safe. An `Idempotency-Key` is generated automatically, so a network
blip can never double-send. Pass your own if you'd rather control it:

```js
await sms.messages.send({ from, to, body }, { idempotencyKey: `order:${orderId}` });
```

Every message carries its `timeline`, `segments`, `encoding`, `price`, and, when
it failed, a readable `failure`:

```js
const m = await sms.messages.get(message.id);
m.timeline;  // [{ status: 'accepted', at }, ..., { status: 'delivered', at }]
m.failure;   // null, or { code: 'carrier_filtered', title, explanation, action, carrier_code }

await sms.messages.list({ status: 'failed', created_after: '2026-10-01' });
```

## Numbers, lookup, events

```js
await sms.numbers.available({ areaCode: '415' });
await sms.numbers.buy('+14155550132');
await sms.numbers.list();
await sms.numbers.release('+14155550132');

await sms.lookup.phone('+14155550132');   // carrier, line type
await sms.links.create({ url: 'https://example.com/sale' });   // tracked link to copy
await sms.conversions.create({ click_id: 'Ab3dEf9h', value_cents: 4900 });   // tk value from the landing URL

await sms.events.list({ limit: 25 });

// Every list has a listAll() that pages for you:
for await (const m of sms.messages.listAll()) console.log(m.id);
```

## Recurring schedules

One message to one number on a repeating local time. Each occurrence is a
normal send: opt-outs, quota and your spend limit are checked when it fires.

```js
const schedule = await sms.schedules.create({
  to: '+14155550132',
  body: 'Good morning. You have got this.',
  repeat: { frequency: 'daily', time: '08:00', timezone: 'America/New_York' },
});
schedule.next_run_at;                    // the next 08:00 in New York, in UTC
await sms.schedules.pause(schedule.id);  // resume(id) starts again from now
await sms.messages.list({ scheduleId: schedule.id });
await sms.schedules.delete(schedule.id);
```

`frequency` is `daily`, `weekly` (with `days_of_week: ['mon', 'fri']`) or
`monthly` (with `day_of_month`). The time is a wall-clock time and stays put
across daylight saving.

## Automations

Send events from your app; a flow sends, waits, and branches for you.

```js
// The first call for a user links user_id to their phone number.
await sms.events.track({ user_id: '123', phone: '+14155550132', event: 'trial_started' });
await sms.events.track({ user_id: '123', event: 'subscription_created' });

const flow = await sms.automations.create({
  name: 'Trial reminder',
  from: '+15005550100',
  trigger: { event: 'trial_started' },
  steps: [
    { type: 'wait', seconds: 3600 },
    { type: 'send_sms', body: 'Your trial is live. Reply STOP to opt out.' },
    { type: 'wait_for_event', event: 'subscription_created', timeout_seconds: 259200, on_received: 'end', on_timeout: 'continue' },
    { type: 'send_sms', body: 'Your trial ends soon.' },
  ],
});
await sms.automations.activate(flow.id);
await sms.automations.runs(flow.id);   // each run, with its timeline
```

## Consent

```js
await sms.consent.get('+14155550132');      // status + history
await sms.consent.optOut('+14155550132', { note: 'CRM sync' });
await sms.consent.optIn('+14155550132');
// For one registration (what marketing from its numbers looks for); proof is
// required when the registration is marketing or mixed.
await sms.consent.optIn('+14155550132', {
  campaignId: 'reg_a1B2c3D4e5F6',
  proof: { source: 'web_form', collectedAt: '2026-10-01T15:04:05Z', pageUrl: 'https://acme.example/texts' },
});
await sms.consent.list({ limit: 100 });     // your suppression list
await sms.consent.import(['+14155550132', '+14155550133']);
const csv = await sms.consent.export();
```

## Contacts

One contact per phone number. Tags double as broadcast audiences.

```js
await sms.contacts.upsert({ phoneNumber: '+14155550132', name: 'Ada', tags: ['vip'] });

// Sync from your own database, up to 500 per call.
await sms.contacts.import(users.map((u) => ({ phoneNumber: u.phone, name: u.name })));

for await (const c of sms.contacts.listAll({ tag: 'vip' })) console.log(c.phone_number);
```

## Customers (for platforms)

If you send for other businesses, label the traffic so usage, messages, and
webhooks come back per customer. Entirely optional.

```js
const acme = await sms.customers.create({ name: 'Acme Dental', externalId: 'acct_42' });
await sms.numbers.buy('+14155550132', { customerId: acme.id });
// or: await sms.numbers.update('+14155550132', { customerId: acme.id });

const msg = await sms.messages.send({ from: '+14155550132', to, body });
msg.customer_id; // acme.id, inherited from the number

await sms.messages.list({ customerId: acme.id });
await sms.customers.usage(acme.id, { start: '2026-10-01', end: '2026-10-31' });
```

## Registrations (business texting)

A US local number texts the public only once its registration is approved.
The first submit for a business carries an attestation signed by someone
authorized to act for it; we verify the business, then file. Every submit
carries `feesAcknowledged: true`: carrier registration fees are billed at
cost, a campaign carries a 3-month minimum, and they are non-refundable even
if the registration is rejected.

```js
const reg = await sms.registrations.create({
  business_name: 'Acme Plumbing LLC',
  website: 'https://acmeplumbing.com',
  opt_in_url: 'https://acmeplumbing.com/text-updates',
  use_case: 'customer_care',
  sample_messages: ['Acme Plumbing: Hi Sam, your plumber Dana arrives tomorrow between 9 and 11 AM. Reply STOP to opt out.', 'Acme Plumbing: Your job #4821 is done. Reply here with any questions.'],
  brand: { legal_name: 'Acme Plumbing LLC', ein: '12-3456789', entity_type: 'PRIVATE_PROFIT', street: '12 Main St', city: 'Springfield', state: 'IL', postal_code: '62701', vertical: 'CONSTRUCTION',
    contact_name: 'Dana Smith', contact_title: 'Owner', contact_email: 'dana@acmeplumbing.com', contact_phone: '217-555-0100' },
});
if (reg.status === 'ready') {
  await sms.registrations.submit(reg.id, { attestation: { signer_name: 'Dana Smith', signer_title: 'Owner', accepted: true }, feesAcknowledged: true });
}
```

## Webhooks

```js
import { verifyWebhook } from 'jointextkit';

app.post('/webhooks/textkit', express.raw({ type: 'application/json' }), async (req, res) => {
  try {
    const event = await verifyWebhook({
      payload: req.body,                         // raw body, not parsed JSON
      signature: req.headers['textkit-signature'],
      secret: process.env.TEXTKIT_WEBHOOK_SECRET,
    });
    // event.type, event.data ...
    res.sendStatus(200);
  } catch {
    res.sendStatus(400);
  }
});
```

Signatures older than 5 minutes are rejected (`toleranceSec: 300`) so a
captured request can't be replayed. Uses Web Crypto, so it runs on Node,
Bun, Deno, and edge runtimes. Also available as `sms.webhooks.verify`.

The signature is also sent as `dsms-signature` and `resms-signature` (the
header names from before the rename), and any of them verifies. Pass
`headers: req.headers` instead of `signature` and the SDK finds whichever one
arrived; `eventIdFromHeaders(req.headers)` does the same for the event id.

### Endpoints

```js
const endpoint = await sms.webhooks.create({
  url: 'https://example.com/webhooks/textkit',
  events: ['message.received', 'message.delivered'], // omit for everything
});
endpoint.secret; // whsec_... returned once, here. Store it.

await sms.webhooks.list();
await sms.webhooks.get(endpoint.id);
await sms.webhooks.update(endpoint.id, { active: false }); // pause
await sms.webhooks.delete(endpoint.id);
```

URLs must be `https` and publicly reachable. A restricted key needs the
`webhooks:write` scope.

### On localhost

No tunnel. `listen` replays your account's events to a local server with the
body and `textkit-signature` header real deliveries carry, signed with a
secret it prints at startup:

```bash
npx jointextkit listen --forward-to http://localhost:3000/webhooks
# Webhook signing secret for this session: whsec_local_...
npx jointextkit trigger message.received   # in another terminal
```

Set your handler's webhook secret to the printed value and `verifyWebhook`
passes unchanged. Only events that happen while it runs are forwarded, and
your configured endpoints are not affected. To sign a payload yourself in a
test, `signWebhook({ payload, secret })` returns the header value.

## CLI

The package's bin. `npx jointextkit <command>`, or `textkit <command>`
once installed globally. Every command takes `--json`.

| Command | Does |
| --- | --- |
| `login` | Prints a URL and a code; you approve in the console and a new **test** key is stored in `~/.textkit.json`. Prints your sandbox number. Live keys are not issued this way |
| `login --key <key>` | Stores a key you already have (or pipe it on stdin) |
| `listen [--forward-to <url>]` | Streams events; with a URL, replays each to your server signed like a webhook. `--events a,b`, `--secret whsec_...` |
| `trigger <event>` | Fires a sandbox event: `message.received`, `message.delivered`, `message.sent`, `message.failed` |
| `send`, `verify`, `numbers`, `lookup`, `links`, `messages`, `events` | The API from the terminal |

Key order: `--key`, then `TEXTKIT_API_KEY`, then the stored file.

## Errors

Every failure throws a `TextKitError` with a machine-readable code:

```js
import { TextKitError } from 'jointextkit';

try {
  await sms.verify.send({ to: phone });
} catch (err) {
  if (err instanceof TextKitError) {
    err.code;       // 'verification_blocked' | 'rate_limited' | …
    err.status;     // HTTP status
    err.retryable;  // whether trying again could work
    err.retryAfter; // seconds to wait, on rate limits
    err.reason;     // why Shield blocked it
  }
}
```

Codes you will want to handle:

| Code | Status | Meaning |
| --- | --- | --- |
| `insufficient_credits` | 402 | Your prepaid balance cannot cover the call. Nothing was sent or charged. `err.balanceMicroUsd`, `err.requiredMicroUsd` and `err.topUpUrl` say how short you are and where to add credits. Not retried: top up, then send again. |
| `spend_limit_reached` | 403 | Your own monthly spend limit is reached. |
| `recipient_opted_out` | 403 | The recipient unsubscribed. Do not retry. |
| `sender_not_registered` | 403 | The sending number is not registered yet; it can text your verified numbers only. |
| `quiet_hours` | 403 | A marketing message outside 8:00am to 9:00pm in the recipient's local time. `err.sendAfter` is the next allowed time; `err.recipientLocalTime` and `err.timezone` say what we read. Send it then, or pass `quietHours: 'defer'` to have it held. |
| `quota_exceeded` | 429 | A free-tier or daily limit was reached. |
| `rate_limited` | 429 | Slow down; see `err.retryAfter`. |

Every refused send is also stored in your log as a message with
`status: 'blocked'` (`err.messageId`), so
`sms.messages.list({ status: 'blocked', blockedReason: 'quiet_hours' })`
shows what was not sent and why.

```js
// Marketing: say so, and choose what happens at night.
const r = await sms.messages.send({ to, body, category: 'marketing', quietHours: 'defer' });
if (r.object === 'scheduled_message') console.log('held until', r.scheduled_at);

const { balance_usd } = await sms.balance.get(); // prepaid credit balance
```

Transient failures (5xx, timeouts, connection errors) are retried
automatically. Two things deliberately are **not** retried: a `POST` without an
idempotency key, and a verification cooldown; that's a policy, not a blip, so
it's surfaced to you with `retryAfter`.

## Testing

Test keys (`ssms_sk_test_…`) cost nothing and simulate: the message reaches `delivered` with `simulated: true` and no text is sent, except to your own verified phone.

```js
sms.isTestMode; // true
```

| Send to | Result |
| --- | --- |
| `+15005550006` | delivered |
| `+15005550013` | delivered after a real delay (5s+) |
| `+15005550001` | stays queued |
| `+15005550002` | failed (`failure.code` `unknown`) |
| `+15005550007` | failed: `carrier_filtered` |
| `+15005550008` | failed: `carrier_rejected` |
| `+15005550009` | failed: `invalid_number` |
| `+15005550010` | failed: `landline` |
| `+15005550014` | failed: `unreachable` |
| `+15005550011` | opted out (403) |
| `+15005550012` | rate limited (429) |
| `+15005550003` | verification cooldown (429) |

| Verification code | Result |
| --- | --- |
| `111111` | approved |
| `000000` | invalid |
| `222222` | expired |
| `333333` | max attempts |

## Options

```js
new TextKit(apiKey, {
  baseUrl: 'https://api.jointextkit.com',
  maxRetries: 2,
  timeout: 30_000,
  fetch: myFetch, // bring your own, e.g. for tracing
});
```

## Renamed from Delivered

TextKit was called Delivered until October 2026, and this package was
`deliveredsms`. Nothing from then stops working:

| Then | Now | Still works? |
| --- | --- | --- |
| `npm install deliveredsms` | `npm install jointextkit` | Yes: `deliveredsms` 1.1+ re-exports this package |
| `import { Delivered }` | `import { TextKit }` | Yes: `Delivered` / `DeliveredError` are aliases of the same classes |
| `DELIVERED_API_KEY`, `DELIVERED_BASE_URL` | `TEXTKIT_API_KEY`, `TEXTKIT_BASE_URL` | Yes: read when the new names are unset (so are `RESMS_*`) |
| `dsms_sk_...` keys | `ssms_sk_...` keys | Yes: old keys authenticate forever |
| `https://api.deliveredsms.com` | `https://api.jointextkit.com` | No: the old host is retired and answers 410. This SDK defaults to the new one; only a hard-coded `baseUrl` needs changing |
| `dsms-signature` header | `textkit-signature` header | Yes: every webhook carries both |
| `deliveredsms` / `dsms` commands | `textkit` command | Yes, with the `deliveredsms` package installed |
| `~/.deliveredsms.json` | `~/.textkit.json` | Yes: read as a fallback |

## Migrating from Twilio

See the [migration guide](https://jointextkit.com/docs/migrate-from-twilio).
`to` works as a parameter name everywhere, so most Twilio Verify code needs
only the client swapped.

MIT © Truelabel Inc
