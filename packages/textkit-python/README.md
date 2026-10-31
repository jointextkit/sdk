# jointextkit (Python)

Official Python client for the [TextKit](https://jointextkit.com) API:
SMS, phone verification, and phone numbers. No dependencies, Python 3.8+.

```bash
pip install jointextkit
```

Get a free key (no card) at [the console](https://jointextkit.com/console).

## Send an SMS

```python
from jointextkit import TextKit

client = TextKit()  # reads TEXTKIT_API_KEY

message = client.messages.send(to="+15005550006", text="Hello from TextKit")
print(message["id"])  # msg_...
```

`from_` is optional while your account has one number (a sandbox account
does): the client looks it up once and reuses it. With several numbers, pass
`from_="+1..."` or set `TEXTKIT_FROM`. `text` and `body` are the same thing.

Retries are safe. An `Idempotency-Key` is generated for every send, so a
network blip can never double-send. Pass your own to control it:

```python
client.messages.send(to=to, body=body, idempotency_key=f"order:{order_id}")
```

## Phone verification

```python
client.verify.send(to="+14155550132")
result = client.verify.check(to="+14155550132", code=code)
if result["verified"]:
    ...
```

You don't store codes or own a number, and you're billed only when
`verified` comes back true.

By email instead, or when the text doesn't arrive:

```python
client.verify.send("ada@example.com", channel="email")

# Same verification, same single charge; the emailed code replaces the texted one.
client.verify.fallback(v["id"], email="ada@example.com")
# The emailed code proves the address, not the phone: check it by email.
client.verify.check(to="ada@example.com", code=code)
```

## Everything else

```python
client.messages.get("msg_...")
client.messages.list(limit=25)                       # one page
for m in client.messages.list_all():                 # every page, lazily
    ...
client.messages.schedule(to, "Reminder", send_at=datetime(...))

client.numbers.available(area_code="415")
client.numbers.buy("+14155550132")
client.numbers.list()
client.numbers.release("+14155550132")

client.lookup.phone("+14155550132")                  # carrier, line type
client.links.create("https://example.com/sale")      # tracked link to copy
client.conversions.create("Ab3dEf9h", value_cents=4900)  # tk value from the landing URL

client.events.list(limit=25)
for e in client.events.list_all(type="message.delivered"):
    ...

# Automations: send events from your app; a flow sends, waits, and branches.
# The first call for a user links user_id to their phone number.
client.events.track("trial_started", user_id="123", phone="+14155550132")
client.events.track("subscription_created", user_id="123")
flow = client.automations.create(
    name="Trial reminder",
    from_="+15005550100",
    trigger={"event": "trial_started"},
    steps=[
        {"type": "wait", "seconds": 3600},
        {"type": "send_sms", "body": "Your trial is live. Reply STOP to opt out."},
    ],
)
client.automations.activate(flow["id"])
client.automations.runs(flow["id"])                  # each run, with its timeline

client.consent.get("+14155550132")                   # status + history
client.consent.opt_out("+14155550132", note="CRM sync")
client.consent.opt_in("+14155550132")
# For one registration (what marketing from its numbers looks for); proof is
# required when the registration is marketing or mixed.
client.consent.opt_in(
    "+14155550132",
    campaign_id="reg_a1B2c3D4e5F6",
    proof={"source": "web_form", "collected_at": "2026-10-01T15:04:05Z", "page_url": "https://acme.example/texts"},
)
client.consent.import_(["+14155550132", "+14155550133"])
csv_text = client.consent.export()
```

## Recurring schedules

One message to one number on a repeating local time. Each occurrence is a
normal send: opt-outs, quota and your spend limit are checked when it fires.

```python
schedule = client.schedules.create(
    to="+14155550132",
    body="Good morning. You have got this.",
    repeat={"frequency": "daily", "time": "08:00", "timezone": "America/New_York"},
)
schedule["next_run_at"]                      # the next 08:00 in New York, in UTC
client.schedules.pause(schedule["id"])       # resume(id) starts again from now
client.messages.list(schedule_id=schedule["id"])
client.schedules.delete(schedule["id"])
```

`frequency` is `daily`, `weekly` (with `days_of_week=["mon", "fri"]` inside
`repeat`) or `monthly` (with `day_of_month`). The time is a wall-clock time
and stays put across daylight saving.

## Contacts

One contact per phone number. Tags double as broadcast audiences.

```python
client.contacts.upsert("+14155550132", name="Ada", tags=["vip"])

# Sync from your own database, up to 500 per call.
client.contacts.import_([{"phone_number": u.phone, "name": u.name} for u in users])

for c in client.contacts.list_all(tag="vip"):
    print(c["phone_number"])
```

## Customers (for platforms)

If you send for other businesses, label the traffic so usage, messages, and
webhooks come back per customer. Entirely optional.

```python
acme = client.customers.create(name="Acme Dental", external_id="acct_42")
client.numbers.buy("+14155550132", customer_id=acme["id"])  # or numbers.update(...)

client.messages.send(to=to, text="Your cleaning is tomorrow", from_="+14155550132")
# -> message["customer_id"] == acme["id"], inherited from the number

client.messages.list(customer_id=acme["id"])
client.customers.usage(acme["id"], start="2026-10-01", end="2026-10-31")
```

## Registrations (business texting)

A US local number texts the public only once its registration is approved.
The first submit for a business carries an attestation signed by someone
authorized to act for it; we verify the business, then file. Every submit
carries `fees_acknowledged=True`: carrier registration fees are billed at
cost, a campaign carries a 3-month minimum, and they are non-refundable even
if the registration is rejected.

```python
reg = client.registrations.create(
    business_name="Acme Plumbing LLC",
    website="https://acmeplumbing.com",
    use_case="customer_care",
    opt_in_url="https://acmeplumbing.com/text-updates",
    sample_messages=["Acme Plumbing: Hi Sam, your plumber Dana arrives tomorrow between 9 and 11 AM. Reply STOP to opt out.",
                     "Acme Plumbing: Your job #4821 is done. Reply here with any questions."],
    brand={"legal_name": "Acme Plumbing LLC", "ein": "12-3456789", "entity_type": "PRIVATE_PROFIT",
           "street": "12 Main St", "city": "Springfield", "state": "IL", "postal_code": "62701", "vertical": "CONSTRUCTION",
           "contact_name": "Dana Smith", "contact_title": "Owner", "contact_email": "dana@acmeplumbing.com", "contact_phone": "217-555-0100"},
)
if reg["status"] == "ready":
    client.registrations.submit(reg["id"], attestation={"signer_name": "Dana Smith", "signer_title": "Owner", "accepted": True}, fees_acknowledged=True)
```

## Webhooks

```python
from jointextkit import verify_webhook, TextKitError

@app.post("/webhooks/textkit")
def hook(request):
    try:
        event = verify_webhook(
            request.body,                          # raw bytes, not parsed JSON
            request.headers["textkit-signature"],
            os.environ["TEXTKIT_WEBHOOK_SECRET"],
        )
    except TextKitError:
        return 400
    ...
```

Signatures older than 5 minutes are rejected (`tolerance=300`) so a captured
request can't be replayed. `client.webhooks.verify(...)` is the same function.

The signature is also sent as `dsms-signature` and `resms-signature` (the
header names from before the rename). Pass `request.headers` itself as the
second argument and the client reads whichever one arrived.

Endpoints can be managed from code too:

```python
endpoint = client.webhooks.create("https://example.com/webhooks/textkit", events=["message.received"])
endpoint["secret"]  # whsec_... returned once, here. Store it.

client.webhooks.list()
client.webhooks.update(endpoint["id"], active=False)  # pause
client.webhooks.delete(endpoint["id"])
```

To receive webhooks on localhost without a tunnel, use the CLI that ships with
the Node package: `npx jointextkit login`, then
`npx jointextkit listen --forward-to http://localhost:8000/webhooks`. It
prints a signing secret; `verify_webhook` accepts its requests unchanged.

## Errors

Every failure raises `TextKitError`:

```python
from jointextkit import TextKitError

try:
    client.verify.send(to=phone)
except TextKitError as err:
    err.code         # "verification_blocked", "rate_limited", ...
    err.status       # HTTP status (0 when the API was unreachable)
    err.param        # which field was wrong, when known
    err.retry_after  # seconds, on rate limits
    err.retryable    # whether trying again could work
```

Codes you will want to handle:

| Code | Status | Meaning |
| --- | --- | --- |
| `insufficient_credits` | 402 | Your prepaid balance cannot cover the call. Nothing was sent or charged. `err.balance_micro_usd`, `err.required_micro_usd` and `err.top_up_url` say how short you are and where to add credits. Not retried: top up, then send again. |
| `spend_limit_reached` | 403 | Your own monthly spend limit is reached. |
| `recipient_opted_out` | 403 | The recipient unsubscribed. Do not retry. |
| `sender_not_registered` | 403 | The sending number is not registered yet; it can text your verified numbers only. |
| `quiet_hours` | 403 | A marketing message outside 8:00am to 9:00pm in the recipient's local time. `err.send_after` is the next allowed time; `err.recipient_local_time` and `err.timezone` say what we read. Send it then, or pass `quiet_hours="defer"` to have it held. Mark marketing sends with `category="marketing"`. |
| `quota_exceeded` | 429 | A free-tier or daily limit was reached. |
| `rate_limited` | 429 | Slow down; see `err.retry_after`. |

```python
client.balance.get()["balance_usd"]  # prepaid credit balance
```

429s, 5xx, timeouts, and connection errors are retried with exponential
backoff, honoring `Retry-After`. Two things are deliberately **not** retried:
a `POST` without an idempotency key (a verification send, a number purchase),
and a verification cooldown, which is policy, not a blip.

## Testing

Test keys (`tk_sk_test_...`) cost nothing and simulate: the message reaches `delivered` with `"simulated": True` and no text is sent, except to your own verified phone.
`client.is_test_mode` tells you which you have. Magic numbers and codes are
in the [sandbox docs](https://jointextkit.com/docs/sandbox).

## Options

```python
TextKit(
    api_key,                      # default: TEXTKIT_API_KEY
    default_from="+14155550100",  # default: TEXTKIT_FROM, else your only number
    base_url="https://api.jointextkit.com",
    max_retries=2,
    timeout=30.0,
    transport=my_transport,       # (method, url, headers, body, timeout) -> Response
)
```

## Renamed from Delivered

TextKit was called Delivered until October 2026. `Delivered` and
`DeliveredError` are still exported as aliases of `TextKit` and
`TextKitError`; `DELIVERED_API_KEY`, `DELIVERED_BASE_URL` and
`DELIVERED_FROM` are still read when the `TEXTKIT_*` names are unset;
`dsms_sk_...` keys still authenticate. The old host `api.deliveredsms.com` is retired (410); this SDK defaults to `api.jointextkit.com`.

## Why no dependencies

The client uses only the standard library (`urllib`, `json`, `hmac`). The
API is plain JSON over HTTPS and every call is synchronous, so a third-party
HTTP stack would add install weight and version conflicts (the classic
`requests`/`urllib3` pin fight) without adding anything you'd notice. It
installs in any environment, including Lambda layers and locked-down CI. If
you want connection pooling, proxies, or tracing, pass a `transport`.

MIT © Truelabel Inc
