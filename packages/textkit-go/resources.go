package textkit

import (
	"context"
	"net/url"
	"strconv"
)

// ── verify ──────────────────────────────────────────────────────────────────

// VerifyService sends and checks one-time codes. You don't need to own a number.
type VerifyService struct{ c *Client }

// SendVerificationParams is what Verify.Send takes.
type SendVerificationParams struct {
	To         string
	AppName    string
	From       string
	CustomerID string
}

// Send sends a one-time code. Not retried: a resend could text the code twice.
func (s *VerifyService) Send(ctx context.Context, p *SendVerificationParams) (*Verification, error) {
	if p == nil {
		p = &SendVerificationParams{}
	}
	body := map[string]any{"to": p.To}
	putString(body, "app_name", p.AppName)
	putString(body, "from", p.From)
	putString(body, "customer_id", p.CustomerID)
	out := new(Verification)
	_, err := s.c.do(ctx, request{method: "POST", path: "/verify", body: body}, out)
	return result(out, err)
}

// Check checks a code. You are billed only when Verified is true.
func (s *VerifyService) Check(ctx context.Context, to, code string) (*VerificationCheck, error) {
	out := new(VerificationCheck)
	_, err := s.c.do(ctx, request{method: "POST", path: "/verify/check", body: map[string]any{"to": to, "code": code}}, out)
	return result(out, err)
}

// Get fetches one verification.
func (s *VerifyService) Get(ctx context.Context, id string) (*Verification, error) {
	out := new(Verification)
	_, err := s.c.do(ctx, request{method: "GET", path: "/verify/" + pathEscape(id), retryable: true}, out)
	return result(out, err)
}

// ── numbers ─────────────────────────────────────────────────────────────────

// NumbersService searches, buys, assigns and releases phone numbers.
type NumbersService struct{ c *Client }

// AvailableNumbersParams filters Numbers.Available.
type AvailableNumbersParams struct {
	AreaCode string
}

// Available lists numbers you can buy.
func (s *NumbersService) Available(ctx context.Context, p *AvailableNumbersParams) (*Page[AvailableNumber], error) {
	q := url.Values{}
	if p != nil {
		q.Set("area_code", p.AreaCode)
	}
	out := new(Page[AvailableNumber])
	_, err := s.c.do(ctx, request{method: "GET", path: "/numbers/available", query: q, retryable: true}, out)
	return result(out, err)
}

// BuyNumberParams is what Numbers.Buy takes besides the number.
type BuyNumberParams struct {
	CustomerID string
}

// Buy buys a number. Not retried: a resend could buy twice.
func (s *NumbersService) Buy(ctx context.Context, phoneNumber string, p *BuyNumberParams) (*PhoneNumber, error) {
	body := map[string]any{"phone_number": phoneNumber}
	if p != nil {
		putString(body, "customer_id", p.CustomerID)
	}
	out := new(PhoneNumber)
	_, err := s.c.do(ctx, request{method: "POST", path: "/numbers", body: body}, out)
	return result(out, err)
}

// ListNumbersParams filters Numbers.List.
type ListNumbersParams struct {
	CustomerID string
}

// List returns your numbers.
func (s *NumbersService) List(ctx context.Context, p *ListNumbersParams) (*Page[PhoneNumber], error) {
	q := url.Values{}
	if p != nil {
		q.Set("customer_id", p.CustomerID)
	}
	out := new(Page[PhoneNumber])
	_, err := s.c.do(ctx, request{method: "GET", path: "/numbers", query: q, retryable: true}, out)
	return result(out, err)
}

// UpdateNumberParams is what Numbers.Update takes.
type UpdateNumberParams struct {
	// CustomerID assigns the number to a customer; nil unassigns it.
	CustomerID *string
}

// Update assigns a number to a customer, or unassigns it.
func (s *NumbersService) Update(ctx context.Context, phoneNumber string, p *UpdateNumberParams) (*PhoneNumber, error) {
	var customer *string
	if p != nil {
		customer = p.CustomerID
	}
	body := map[string]any{"customer_id": customer}
	out := new(PhoneNumber)
	_, err := s.c.do(ctx, request{method: "PATCH", path: "/numbers/" + pathEscape(phoneNumber), body: body, retryable: true}, out)
	return result(out, err)
}

// Release gives a number up. Not retried.
func (s *NumbersService) Release(ctx context.Context, phoneNumber string) (*PhoneNumber, error) {
	out := new(PhoneNumber)
	_, err := s.c.do(ctx, request{method: "DELETE", path: "/numbers/" + pathEscape(phoneNumber)}, out)
	return result(out, err)
}

// ── balance, lookup ─────────────────────────────────────────────────────────

// BalanceService reads your prepaid credit balance.
type BalanceService struct{ c *Client }

// Get returns your prepaid credit balance and auto-recharge setting.
func (s *BalanceService) Get(ctx context.Context) (*Balance, error) {
	out := new(Balance)
	_, err := s.c.do(ctx, request{method: "GET", path: "/balance", retryable: true}, out)
	return result(out, err)
}

// LookupService reads carrier data for a number.
type LookupService struct{ c *Client }

// Phone returns carrier and line type for a number.
func (s *LookupService) Phone(ctx context.Context, phoneNumber string) (*Lookup, error) {
	out := new(Lookup)
	_, err := s.c.do(ctx, request{method: "GET", path: "/lookup/" + pathEscape(phoneNumber), retryable: true}, out)
	return result(out, err)
}

// LinksService makes tracked links to copy anywhere.
type LinksService struct{ c *Client }

// Create makes a tracked link. The same URL again returns the same link.
func (s *LinksService) Create(ctx context.Context, params CreateLinkParams) (*TrackedLink, error) {
	out := new(TrackedLink)
	_, err := s.c.do(ctx, request{method: "POST", path: "/links", body: params}, out)
	return result(out, err)
}

// List returns every tracked destination with its clicks and conversions.
func (s *LinksService) List(ctx context.Context) ([]TrackedLink, error) {
	out := new(struct {
		Data []TrackedLink `json:"data"`
	})
	if _, err := s.c.do(ctx, request{method: "GET", path: "/links", retryable: true}, out); err != nil {
		return nil, err
	}
	return out.Data, nil
}

// ConversionsService reports sales and sign-ups from tracked links.
type ConversionsService struct{ c *Client }

// Create reports a conversion. ClickID is the tk value on the landing page URL.
func (s *ConversionsService) Create(ctx context.Context, params CreateConversionParams) (*Conversion, error) {
	out := new(Conversion)
	_, err := s.c.do(ctx, request{method: "POST", path: "/conversions", body: params}, out)
	return result(out, err)
}

// List returns the latest 100 conversions.
func (s *ConversionsService) List(ctx context.Context) ([]Conversion, error) {
	out := new(struct {
		Data []Conversion `json:"data"`
	})
	if _, err := s.c.do(ctx, request{method: "GET", path: "/conversions", retryable: true}, out); err != nil {
		return nil, err
	}
	return out.Data, nil
}

// ── events ──────────────────────────────────────────────────────────────────

// EventsService lists, long-polls and tracks events.
type EventsService struct{ c *Client }

// ListEventsParams filters Events.List.
type ListEventsParams struct {
	Limit  int
	Cursor string
	Type   string
}

// List returns one page of events, newest first.
func (s *EventsService) List(ctx context.Context, p *ListEventsParams) (*Page[Event], error) {
	if p == nil {
		p = &ListEventsParams{}
	}
	q := url.Values{"limit": {intString(p.Limit)}, "cursor": {p.Cursor}, "type": {p.Type}}
	out := new(Page[Event])
	_, err := s.c.do(ctx, request{method: "GET", path: "/events", query: q, retryable: true}, out)
	return result(out, err)
}

// ListAll walks every event, fetching pages as you iterate. p.Cursor is ignored.
func (s *EventsService) ListAll(ctx context.Context, p *ListEventsParams) *Iter[Event] {
	base := ListEventsParams{}
	if p != nil {
		base = *p
	}
	return newIter(ctx, func(ctx context.Context, cursor string) (*Page[Event], error) {
		q := base
		q.Cursor = cursor
		return s.List(ctx, &q)
	})
}

// WaitEventsParams is what Events.Wait takes.
type WaitEventsParams struct {
	// Cursor from the previous answer; empty means "from now".
	Cursor string
	// Timeout is how long the API holds the request, 0-25 seconds (default
	// 20). Keep it below the client's own timeout (30 seconds by default).
	Timeout *int
}

// Wait long-polls for new events. Call once with no cursor to get a cursor
// that means "from now", then keep calling with the cursor each answer hands
// back. An event can be returned twice; de-duplicate by ID.
func (s *EventsService) Wait(ctx context.Context, p *WaitEventsParams) (*EventWait, error) {
	q := url.Values{}
	if p != nil {
		q.Set("cursor", p.Cursor)
		if p.Timeout != nil {
			q.Set("timeout", strconv.Itoa(*p.Timeout))
		}
	}
	out := new(EventWait)
	_, err := s.c.do(ctx, request{method: "GET", path: "/events/wait", query: q, retryable: true}, out)
	return result(out, err)
}

// TrackEventParams is what Events.Track takes. Pass Phone, UserID, or both;
// a call with both links them, so later calls need only UserID.
type TrackEventParams struct {
	Event      string
	UserID     string
	Phone      string
	Properties map[string]any
	// IdempotencyKey is generated when empty, so retries are safe.
	IdempotencyKey string
}

// Track tells TextKit something happened in your app. Automations
// listening for the event start (or move on) for that person.
func (s *EventsService) Track(ctx context.Context, p *TrackEventParams) (*TrackedEvent, error) {
	if p == nil {
		p = &TrackEventParams{}
	}
	body := map[string]any{"event": p.Event}
	putString(body, "user_id", p.UserID)
	putString(body, "phone", p.Phone)
	if len(p.Properties) > 0 {
		body["properties"] = p.Properties
	}
	key := p.IdempotencyKey
	if key == "" {
		key = NewIdempotencyKey()
	}
	out := new(TrackedEvent)
	_, err := s.c.do(ctx, request{method: "POST", path: "/track", body: body, idempotencyKey: key, retryable: true}, out)
	return result(out, err)
}

// ── webhooks ────────────────────────────────────────────────────────────────

// WebhooksService manages webhook endpoints. A restricted key needs the
// webhooks:write scope. To check a delivery's signature, use VerifyWebhook.
type WebhooksService struct{ c *Client }

// List returns your webhook endpoints.
func (s *WebhooksService) List(ctx context.Context) (*Page[WebhookEndpoint], error) {
	out := new(Page[WebhookEndpoint])
	_, err := s.c.do(ctx, request{method: "GET", path: "/webhooks", retryable: true}, out)
	return result(out, err)
}

// CreateWebhookParams is what Webhooks.Create takes.
type CreateWebhookParams struct {
	URL string
	// Events to subscribe to; empty subscribes to every event.
	Events      []string
	Description string
}

// Create registers an endpoint. The answer's Secret is returned this once;
// store it. Not retried.
func (s *WebhooksService) Create(ctx context.Context, p *CreateWebhookParams) (*WebhookEndpoint, error) {
	if p == nil {
		p = &CreateWebhookParams{}
	}
	body := map[string]any{"url": p.URL}
	if len(p.Events) > 0 {
		body["events"] = p.Events
	}
	putString(body, "description", p.Description)
	out := new(WebhookEndpoint)
	_, err := s.c.do(ctx, request{method: "POST", path: "/webhooks", body: body}, out)
	return result(out, err)
}

// Get fetches one endpoint.
func (s *WebhooksService) Get(ctx context.Context, id string) (*WebhookEndpoint, error) {
	out := new(WebhookEndpoint)
	_, err := s.c.do(ctx, request{method: "GET", path: "/webhooks/" + pathEscape(id), retryable: true}, out)
	return result(out, err)
}

// UpdateWebhookParams changes only the fields that are Set.
type UpdateWebhookParams struct {
	URL Optional[string]
	// Events: Set(nil) or an empty list subscribes to every event.
	Events Optional[[]string]
	// Active: Set(false) pauses delivery.
	Active      Optional[bool]
	Description Optional[string] // Null clears it
}

// Update changes an endpoint.
func (s *WebhooksService) Update(ctx context.Context, id string, p *UpdateWebhookParams) (*WebhookEndpoint, error) {
	body := map[string]any{}
	if p != nil {
		p.URL.put(body, "url")
		if p.Events.set {
			if p.Events.null || len(p.Events.value) == 0 {
				body["events"] = "*"
			} else {
				body["events"] = p.Events.value
			}
		}
		p.Active.put(body, "active")
		p.Description.put(body, "description")
	}
	out := new(WebhookEndpoint)
	_, err := s.c.do(ctx, request{method: "PATCH", path: "/webhooks/" + pathEscape(id), body: body}, out)
	return result(out, err)
}

// Delete removes an endpoint.
func (s *WebhooksService) Delete(ctx context.Context, id string) (*Deleted, error) {
	out := new(Deleted)
	_, err := s.c.do(ctx, request{method: "DELETE", path: "/webhooks/" + pathEscape(id)}, out)
	return result(out, err)
}

// Verify is VerifyWebhook, here for discoverability.
func (s *WebhooksService) Verify(payload []byte, signature, secret string, opts ...VerifyOption) (*Event, error) {
	return VerifyWebhook(payload, signature, secret, opts...)
}

// ── consent ─────────────────────────────────────────────────────────────────

// ConsentService reads and records opt-outs and opt-ins.
type ConsentService struct{ c *Client }

// ListConsentParams pages Consent.List.
type ListConsentParams struct {
	Limit  int
	Cursor string
}

// List returns one page of your suppression list: numbers currently opted out.
func (s *ConsentService) List(ctx context.Context, p *ListConsentParams) (*Page[ConsentRecord], error) {
	if p == nil {
		p = &ListConsentParams{}
	}
	q := url.Values{"limit": {intString(p.Limit)}, "cursor": {p.Cursor}}
	out := new(Page[ConsentRecord])
	_, err := s.c.do(ctx, request{method: "GET", path: "/consent", query: q, retryable: true}, out)
	return result(out, err)
}

// ListAll walks the whole suppression list. p.Cursor is ignored.
func (s *ConsentService) ListAll(ctx context.Context, p *ListConsentParams) *Iter[ConsentRecord] {
	base := ListConsentParams{}
	if p != nil {
		base = *p
	}
	return newIter(ctx, func(ctx context.Context, cursor string) (*Page[ConsentRecord], error) {
		q := base
		q.Cursor = cursor
		return s.List(ctx, &q)
	})
}

// Get returns the current status plus the append-only history for one number.
func (s *ConsentService) Get(ctx context.Context, phone string) (*ConsentDetail, error) {
	out := new(ConsentDetail)
	_, err := s.c.do(ctx, request{method: "GET", path: "/consent/" + pathEscape(phone), retryable: true}, out)
	return result(out, err)
}

// OptOutParams is what Consent.OptOut takes besides the number.
type OptOutParams struct {
	Note string
}

// OptOut records an opt-out from your own system (CRM, web form, support tool).
func (s *ConsentService) OptOut(ctx context.Context, phone string, p *OptOutParams) (*ConsentUpdate, error) {
	body := map[string]any{"status": "opted_out"}
	if p != nil {
		putString(body, "note", p.Note)
	}
	out := new(ConsentUpdate)
	_, err := s.c.do(ctx, request{method: "POST", path: "/consent/" + pathEscape(phone), body: body, retryable: true}, out)
	return result(out, err)
}

// OptInParams is what Consent.OptIn takes besides the number.
type OptInParams struct {
	Note string
	// CampaignID (a registration id) records the opt-in for that registration,
	// which is what a marketing send from its numbers looks for.
	CampaignID string
	// Proof is required for a marketing or mixed registration, and for a
	// number that opted out (collected at or after the opt-out).
	Proof *OptInProof
}

// OptIn records a fresh opt-in. Only with the recipient's consent.
func (s *ConsentService) OptIn(ctx context.Context, phone string, p *OptInParams) (*ConsentUpdate, error) {
	body := map[string]any{"status": "opted_in"}
	if p != nil {
		putString(body, "note", p.Note)
		putString(body, "campaign_id", p.CampaignID)
		if p.Proof != nil {
			body["proof"] = p.Proof
		}
	}
	out := new(ConsentUpdate)
	_, err := s.c.do(ctx, request{method: "POST", path: "/consent/" + pathEscape(phone), body: body, retryable: true}, out)
	return result(out, err)
}

// Import bulk-imports opt-outs (up to 500 per call).
func (s *ConsentService) Import(ctx context.Context, phoneNumbers []string) (*ConsentImport, error) {
	if phoneNumbers == nil {
		phoneNumbers = []string{}
	}
	out := new(ConsentImport)
	_, err := s.c.do(ctx, request{method: "POST", path: "/consent/import", body: map[string]any{"phone_numbers": phoneNumbers}, retryable: true}, out)
	return result(out, err)
}

// Export returns the whole suppression list as CSV text.
func (s *ConsentService) Export(ctx context.Context) (string, error) {
	raw, err := s.c.do(ctx, request{method: "GET", path: "/consent/export", retryable: true}, nil)
	if err != nil {
		return "", err
	}
	return string(raw), nil
}
