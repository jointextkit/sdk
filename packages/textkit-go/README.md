# textkit-go

Official Go client for the [TextKit](https://jointextkit.com) API:
SMS, phone verification, and phone numbers. No dependencies, Go 1.21+.

Version 0.1.0.

```bash
go get github.com/jointextkit/textkit-go
```

Get a free key (no card) at [the console](https://jointextkit.com/console).

## Send an SMS

```go
import textkit "github.com/jointextkit/textkit-go"

client, err := textkit.NewClient("") // reads TEXTKIT_API_KEY
if err != nil {
	log.Fatal(err)
}

msg, err := client.Messages.Send(ctx, &textkit.SendMessageParams{
	To:   "+15005550006",
	Body: "Hello from TextKit",
})
fmt.Println(msg.ID) // msg_...
```

`From` is optional while your account has one number (a sandbox account
does): the client looks it up once and reuses it. With several numbers, set
`From: "+1..."`, pass `textkit.WithDefaultFrom(...)`, or set `TEXTKIT_FROM`.

Every call takes a `context.Context`. Cancel it and the call stops, retries
included.

Retries are safe. An `Idempotency-Key` is generated for every send, so a
network blip can never double-send. Pass your own to control it:

```go
client.Messages.Send(ctx, &textkit.SendMessageParams{To: to, Body: body, IdempotencyKey: "order:" + orderID})
```

## Phone verification

```go
client.Verify.Send(ctx, &textkit.SendVerificationParams{To: "+14155550132"})
result, err := client.Verify.Check(ctx, "+14155550132", code)
if err == nil && result.Verified {
	// ...
}
```

You don't store codes or own a number, and you're billed only when
`Verified` comes back true.

## Everything else

```go
client.Messages.Get(ctx, "msg_...")
client.Messages.List(ctx, &textkit.ListMessagesParams{Limit: 25}) // one page
it := client.Messages.ListAll(ctx, nil)                            // every page, lazily
for it.Next() {
	m := it.Current()
}
if err := it.Err(); err != nil { /* ... */ }
client.Messages.Schedule(ctx, &textkit.ScheduleMessageParams{To: to, Body: "Reminder", SendAt: time.Now().Add(time.Hour)})

client.Numbers.Available(ctx, &textkit.AvailableNumbersParams{AreaCode: "415"})
client.Numbers.Buy(ctx, "+14155550132", nil)
client.Numbers.List(ctx, nil)
client.Numbers.Release(ctx, "+14155550132")

client.Lookup.Phone(ctx, "+14155550132") // carrier, line type
client.Links.Create(ctx, textkit.CreateLinkParams{URL: "https://example.com/sale"}) // tracked link to copy
client.Conversions.Create(ctx, textkit.CreateConversionParams{ClickID: "Ab3dEf9h", ValueCents: 4900})

client.Events.List(ctx, &textkit.ListEventsParams{Limit: 25})
events := client.Events.ListAll(ctx, &textkit.ListEventsParams{Type: "message.delivered"})

// Long-poll: the first call returns a cursor meaning "from now".
wait, _ := client.Events.Wait(ctx, nil)
wait, _ = client.Events.Wait(ctx, &textkit.WaitEventsParams{Cursor: wait.Cursor})

// Automations: send events from your app; a flow sends, waits, and branches.
// The first call for a user links UserID to their phone number.
client.Events.Track(ctx, &textkit.TrackEventParams{Event: "trial_started", UserID: "123", Phone: "+14155550132"})
client.Events.Track(ctx, &textkit.TrackEventParams{Event: "subscription_created", UserID: "123"})
flow, _ := client.Automations.Create(ctx, &textkit.CreateAutomationParams{
	Name:    "Trial reminder",
	From:    textkit.Set("+15005550100"),
	Trigger: map[string]any{"event": "trial_started"},
	Steps: []map[string]any{
		{"type": "wait", "seconds": 3600},
		{"type": "send_sms", "body": "Your trial is live. Reply STOP to opt out."},
	},
})
client.Automations.Activate(ctx, flow.ID)
client.Automations.Runs(ctx, flow.ID, nil) // each run, with its timeline

client.Consent.Get(ctx, "+14155550132") // status + history
client.Consent.OptOut(ctx, "+14155550132", &textkit.OptOutParams{Note: "CRM sync"})
client.Consent.OptIn(ctx, "+14155550132", nil)
// For one registration (what marketing from its numbers looks for); proof is
// required when the registration is marketing or mixed.
client.Consent.OptIn(ctx, "+14155550132", &textkit.OptInParams{
	CampaignID: "reg_a1B2c3D4e5F6",
	Proof:      &textkit.OptInProof{Source: "web_form", CollectedAt: "2026-10-01T15:04:05Z", PageURL: "https://acme.example/texts"},
})
client.Consent.Import(ctx, []string{"+14155550132", "+14155550133"})
csv, _ := client.Consent.Export(ctx)

client.Balance.Get(ctx) // prepaid credit balance
```

Update calls change only the fields you set. `textkit.Set(v)` sends a
value and `textkit.Null[T]()` clears one:

```go
client.Customers.Update(ctx, id, &textkit.UpdateCustomerParams{
	Name:       textkit.Set("Acme"),
	ExternalID: textkit.Null[string](),
})
```

## Recurring schedules

One message to one number on a repeating local time. Each occurrence is a
normal send: opt-outs, quota and your spend limit are checked when it fires.

```go
schedule, _ := client.Schedules.Create(ctx, &textkit.CreateScheduleParams{
	To:     "+14155550132",
	Body:   "Good morning. You have got this.",
	Repeat: textkit.ScheduleRepeat{Frequency: "daily", Time: "08:00", Timezone: "America/New_York"},
})
schedule.NextRunAt                    // the next 08:00 in New York, in UTC
client.Schedules.Pause(ctx, schedule.ID) // Resume starts again from now
client.Messages.List(ctx, &textkit.ListMessagesParams{ScheduleID: schedule.ID})
client.Schedules.Delete(ctx, schedule.ID)
```

`Frequency` is `daily`, `weekly` (with `DaysOfWeek: []string{"mon", "fri"}`)
or `monthly` (with `DayOfMonth`). The time is a wall-clock time and stays put
across daylight saving.

## Contacts

One contact per phone number. Tags double as broadcast audiences.

```go
client.Contacts.Upsert(ctx, &textkit.ContactParams{PhoneNumber: "+14155550132", Name: "Ada", Tags: []string{"vip"}})

// Sync from your own database, up to 500 per call.
client.Contacts.Import(ctx, []textkit.ContactParams{{PhoneNumber: u.Phone, Name: u.Name}})

it := client.Contacts.ListAll(ctx, &textkit.ListContactsParams{Tag: "vip"})
for it.Next() {
	fmt.Println(it.Current().PhoneNumber)
}
```

## Customers (for platforms)

If you send for other businesses, label the traffic so usage, messages, and
webhooks come back per customer. Entirely optional.

```go
acme, _ := client.Customers.Create(ctx, &textkit.CreateCustomerParams{Name: "Acme Dental", ExternalID: "acct_42"})
client.Numbers.Buy(ctx, "+14155550132", &textkit.BuyNumberParams{CustomerID: acme.ID})

client.Messages.Send(ctx, &textkit.SendMessageParams{To: to, Body: "Your cleaning is tomorrow", From: "+14155550132"})
// -> msg.CustomerID == acme.ID, inherited from the number

client.Messages.List(ctx, &textkit.ListMessagesParams{CustomerID: acme.ID})
client.Customers.Usage(ctx, acme.ID, &textkit.CustomerUsageParams{Start: "2026-10-01", End: "2026-10-31"})
```

## Registrations (business texting)

A US local number texts the public only once its registration is approved.
The first submit for a business carries an attestation signed by someone
authorized to act for it; we verify the business, then file. Every submit
carries `FeesAcknowledged: true`: carrier registration fees are billed at
cost, a campaign carries a 3-month minimum, and they are non-refundable even
if the registration is rejected.

```go
reg, _ := client.Registrations.Create(ctx, map[string]any{
	"business_name":   "Acme Plumbing LLC",
	"website":         "https://acmeplumbing.com",
	"use_case":        "customer_care",
	"opt_in_url":      "https://acmeplumbing.com/text-updates",
	"sample_messages": []string{"Acme Plumbing: Hi Sam, your plumber Dana arrives tomorrow between 9 and 11 AM. Reply STOP to opt out."},
	"brand":           map[string]any{"legal_name": "Acme Plumbing LLC", "ein": "12-3456789" /* ... */},
})
if reg.Status == "ready" {
	client.Registrations.Submit(ctx, reg.ID, &textkit.SubmitRegistrationParams{
		FeesAcknowledged: true,
		Attestation:      &textkit.Attestation{SignerName: "Dana Smith", SignerTitle: "Owner", Accepted: true},
	})
}
```

## Webhooks

```go
http.HandleFunc("/webhooks/textkit", func(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body) // raw bytes, not re-encoded JSON
	event, err := textkit.VerifyWebhookRequest(body, r.Header, os.Getenv("TEXTKIT_WEBHOOK_SECRET"))
	if err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	switch event.Type {
	case "message.received":
		// event.Data["body"]
	}
})
```

Signatures older than 5 minutes are rejected (`textkit.WithTolerance`
changes that) so a captured request can't be replayed.
`textkit.VerifyWebhook(body, signature, secret)` takes the header value
instead of the request's headers; `client.Webhooks.Verify` is the same.

The signature is also sent as `dsms-signature` and `resms-signature` (the
header names from before the rename). `VerifyWebhookRequest` reads whichever
one arrived.

Endpoints can be managed from code too:

```go
endpoint, _ := client.Webhooks.Create(ctx, &textkit.CreateWebhookParams{
	URL:    "https://example.com/webhooks/textkit",
	Events: []string{"message.received"},
})
endpoint.Secret // whsec_... returned once, here. Store it.

client.Webhooks.List(ctx)
client.Webhooks.Update(ctx, endpoint.ID, &textkit.UpdateWebhookParams{Active: textkit.Set(false)}) // pause
client.Webhooks.Delete(ctx, endpoint.ID)
```

To receive webhooks on localhost without a tunnel, use the CLI that ships with
the Node package: `npx jointextkit login`, then
`npx jointextkit listen --forward-to http://localhost:8000/webhooks`. It
prints a signing secret; `VerifyWebhook` accepts its requests unchanged.

## Errors

Every failure is a `*textkit.Error`:

```go
_, err := client.Verify.Send(ctx, &textkit.SendVerificationParams{To: phone})
var apiErr *textkit.Error
if errors.As(err, &apiErr) {
	apiErr.Code        // "verification_blocked", "rate_limited", ...
	apiErr.Status      // HTTP status (0 when the API was unreachable)
	apiErr.Param       // which field was wrong, when known
	apiErr.RetryAfter  // seconds, on rate limits
	apiErr.Retryable() // whether trying again could work
}
```

Codes you will want to handle (each has a `textkit.Code...` constant):

| Code | Status | Meaning |
| --- | --- | --- |
| `insufficient_credits` | 402 | Your prepaid balance cannot cover the call. Nothing was sent or charged. `BalanceMicroUSD`, `RequiredMicroUSD` and `TopUpURL` say how short you are and where to add credits. Not retried: top up, then send again. |
| `spend_limit_reached` | 403 | Your own monthly spend limit is reached. |
| `recipient_opted_out` | 403 | The recipient unsubscribed. Do not retry. |
| `sender_not_registered` | 403 | The sending number is not registered yet; it can text your verified numbers only. |
| `quiet_hours` | 403 | A marketing message outside 8:00am to 9:00pm in the recipient's local time. `SendAfter` is the next allowed time; `RecipientLocalTime` and `Timezone` say what we read. Send it then, or set `QuietHours: "defer"` to have it held. Mark marketing sends with `Category: "marketing"`. |
| `quota_exceeded` | 429 | A free-tier or daily limit was reached. |
| `rate_limited` | 429 | Slow down; see `RetryAfter`. |

429s, 5xx, timeouts, and connection errors are retried with exponential
backoff, honoring `Retry-After`. Two things are deliberately **not** retried:
a `POST` without an idempotency key (a verification send, a number purchase),
and a verification cooldown, which is policy, not a blip.

## Testing

Test keys (`ssms_sk_test_...`) cost nothing and simulate: the message reaches `delivered` with `Simulated: true` and no text is sent, except to your own verified phone.
`client.IsTestMode()` tells you which you have. Magic numbers and codes are
in the [sandbox docs](https://jointextkit.com/docs/sandbox).

## Options

```go
textkit.NewClient(apiKey, // "" reads TEXTKIT_API_KEY
	textkit.WithDefaultFrom("+14155550100"),         // default: TEXTKIT_FROM, else your only number
	textkit.WithBaseURL("https://api.jointextkit.com/v1"), // default; TEXTKIT_BASE_URL also works
	textkit.WithMaxRetries(2),
	textkit.WithTimeout(30*time.Second),             // per attempt
	textkit.WithHTTPClient(myHTTPClient),            // proxies, tracing, tests
)
```

`DELIVERED_API_KEY`, `DELIVERED_BASE_URL` and `DELIVERED_FROM` (the names
from before TextKit was renamed) are read when the `TEXTKIT_*` names are
unset.

## Why no dependencies

The client uses only the standard library (`net/http`, `encoding/json`,
`crypto/hmac`). The API is plain JSON over HTTPS, so a third-party HTTP stack
would add module weight without adding anything you'd notice. If you want
connection pooling, proxies, or tracing, pass your own `*http.Client`.

MIT © Truelabel Inc
