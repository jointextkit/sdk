package textkit

import (
	"context"
	"net/url"
	"time"
)

// MessagesService sends and lists SMS.
type MessagesService struct{ c *Client }

// SendConsent records how the recipient agreed to your messages, for a
// recurring non-marketing message from a registered number that has no
// opt-in on file yet. It never counts for marketing.
type SendConsent struct {
	Source      string `json:"source"` // web_form | keyword | paper | checkout | verbal
	CollectedAt string `json:"collected_at"`
	PageURL     string `json:"page_url,omitempty"`
}

// SendMessageParams is what Messages.Send takes.
type SendMessageParams struct {
	To   string
	Body string
	// From defaults to the client's default number (WithDefaultFrom,
	// TEXTKIT_FROM), else your account's only active number.
	From       string
	CustomerID string
	// Category ("marketing", "transactional" or "otp") can make the message
	// stricter, never looser: a message outside its registration's use case
	// fails with campaign_mismatch.
	Category string
	// QuietHours is what to do with a marketing message outside 8:00am-9:00pm
	// in the recipient's local time: "block" fails with quiet_hours (see
	// Error.SendAfter); "defer" holds it and the answer's Object is
	// "scheduled_message".
	QuietHours string
	Consent    *SendConsent
	// IdempotencyKey is generated when empty, so a retry never double-sends.
	IdempotencyKey string
}

// Send sends an SMS. Retries are safe: an Idempotency-Key is generated when
// you don't pass one, so a network blip can never double-send.
func (s *MessagesService) Send(ctx context.Context, p *SendMessageParams) (*Message, error) {
	if p == nil || p.Body == "" {
		return nil, &Error{Message: "Pass the message as Body.", Code: CodeInvalidRequest, Param: "body"}
	}
	from := p.From
	if from == "" {
		var err error
		if from, err = s.c.resolveFrom(ctx); err != nil {
			return nil, err
		}
	}
	body := map[string]any{"to": p.To, "body": p.Body, "from": from}
	putString(body, "customer_id", p.CustomerID)
	putString(body, "category", p.Category)
	putString(body, "quiet_hours", p.QuietHours)
	if p.Consent != nil {
		body["consent"] = p.Consent
	}
	key := p.IdempotencyKey
	if key == "" {
		key = NewIdempotencyKey()
	}
	out := new(Message)
	_, err := s.c.do(ctx, request{method: "POST", path: "/messages", body: body, idempotencyKey: key, retryable: true}, out)
	return result(out, err)
}

// ScheduleMessageParams is what Messages.Schedule takes.
type ScheduleMessageParams struct {
	To         string
	Body       string
	SendAt     time.Time // up to 30 days ahead
	From       string    // defaults like SendMessageParams.From
	CustomerID string
	Category   string
	QuietHours string
}

// Schedule queues a message for later (up to 30 days ahead). It is not
// retried: there is no idempotency key on a scheduled send.
func (s *MessagesService) Schedule(ctx context.Context, p *ScheduleMessageParams) (*ScheduledMessage, error) {
	if p == nil {
		return nil, &Error{Message: "Pass the message to schedule.", Code: CodeInvalidRequest}
	}
	from := p.From
	if from == "" {
		var err error
		if from, err = s.c.resolveFrom(ctx); err != nil {
			return nil, err
		}
	}
	body := map[string]any{
		"to":           p.To,
		"body":         p.Body,
		"from":         from,
		"scheduled_at": p.SendAt.UTC().Format(time.RFC3339Nano),
	}
	putString(body, "customer_id", p.CustomerID)
	putString(body, "category", p.Category)
	putString(body, "quiet_hours", p.QuietHours)
	out := new(ScheduledMessage)
	_, err := s.c.do(ctx, request{method: "POST", path: "/messages", body: body}, out)
	return result(out, err)
}

// Get fetches one message.
func (s *MessagesService) Get(ctx context.Context, id string) (*Message, error) {
	out := new(Message)
	_, err := s.c.do(ctx, request{method: "GET", path: "/messages/" + pathEscape(id), retryable: true}, out)
	return result(out, err)
}

// ListMessagesParams filters Messages.List. Every field is optional.
type ListMessagesParams struct {
	Limit      int
	Cursor     string
	Number     string
	CustomerID string
	// ScheduleID keeps only the occurrences of one recurring schedule.
	ScheduleID string
	// Status "blocked" lists the sends a check refused; BlockedReason narrows it.
	Status        string
	BlockedReason string
	FailureCode   string
}

// List returns one page of messages, newest first.
func (s *MessagesService) List(ctx context.Context, p *ListMessagesParams) (*Page[Message], error) {
	if p == nil {
		p = &ListMessagesParams{}
	}
	q := url.Values{
		"limit":          {intString(p.Limit)},
		"cursor":         {p.Cursor},
		"number":         {p.Number},
		"customer_id":    {p.CustomerID},
		"schedule_id":    {p.ScheduleID},
		"status":         {p.Status},
		"blocked_reason": {p.BlockedReason},
		"failure_code":   {p.FailureCode},
	}
	out := new(Page[Message])
	_, err := s.c.do(ctx, request{method: "GET", path: "/messages", query: q, retryable: true}, out)
	return result(out, err)
}

// ListAll walks every message, newest first, fetching pages as you iterate.
// p.Cursor is ignored.
func (s *MessagesService) ListAll(ctx context.Context, p *ListMessagesParams) *Iter[Message] {
	base := ListMessagesParams{}
	if p != nil {
		base = *p
	}
	return newIter(ctx, func(ctx context.Context, cursor string) (*Page[Message], error) {
		q := base
		q.Cursor = cursor
		return s.List(ctx, &q)
	})
}

func putString(m map[string]any, key, v string) {
	if v != "" {
		m[key] = v
	}
}

// result returns (nil, err) on failure so callers never see a half-filled value.
func result[T any](out *T, err error) (*T, error) {
	if err != nil {
		return nil, err
	}
	return out, nil
}
