package textkit

import (
	"context"
	"encoding/json"
)

// Response shapes. Timestamps are ISO 8601 strings as the API sends them;
// a nullable field is a pointer. Fields marked "optional" are only present
// when the API has a value for them.

// Message is an SMS, sent or received.
type Message struct {
	ID        string `json:"id"`
	Object    string `json:"object"` // "message", or "scheduled_message" when quiet_hours "defer" held it
	To        string `json:"to"`
	From      string `json:"from"`
	Body      string `json:"body"`
	Direction string `json:"direction"` // "outbound" | "inbound"
	// Status is queued, sent, delivered, failed, blocked or received.
	// "blocked": refused by a send check before any carrier saw it; never charged.
	Status    string `json:"status"`
	Test      bool   `json:"test"`
	Simulated bool   `json:"simulated"`
	CreatedAt string `json:"created_at"`

	Media         []string       `json:"media,omitempty"`
	SentBy        string         `json:"sent_by,omitempty"`
	FailureReason string         `json:"failure_reason,omitempty"`
	CustomerID    string         `json:"customer_id,omitempty"`
	ScheduleID    string         `json:"schedule_id,omitempty"`
	Category      string         `json:"category,omitempty"`
	Deferred      map[string]any `json:"deferred,omitempty"`
	// Notice is set only on a send's answer: a test-key send was simulated.
	Notice string `json:"notice,omitempty"`
	// ScheduledAt is set when Object is "scheduled_message".
	ScheduledAt string `json:"scheduled_at,omitempty"`
}

// ScheduledMessage is a message queued for later by Messages.Schedule.
type ScheduledMessage struct {
	ID          string `json:"id"`
	Object      string `json:"object"` // "scheduled_message"
	To          string `json:"to"`
	From        string `json:"from,omitempty"`
	Body        string `json:"body"`
	ScheduledAt string `json:"scheduled_at"`
	Status      string `json:"status"` // "queued"
	CustomerID  string `json:"customer_id,omitempty"`
}

// ScheduleRepeat is when a recurring schedule fires.
type ScheduleRepeat struct {
	Frequency  string   `json:"frequency"` // daily | weekly | monthly
	Time       string   `json:"time"`      // 24-hour local "HH:MM"
	Timezone   string   `json:"timezone"`  // IANA zone
	DaysOfWeek []string `json:"days_of_week,omitempty"`
	DayOfMonth int      `json:"day_of_month,omitempty"`
}

// Schedule is a recurring message to one number.
type Schedule struct {
	ID             string         `json:"id"`
	Object         string         `json:"object"` // "schedule"
	To             string         `json:"to"`
	From           string         `json:"from"`
	Body           string         `json:"body"`
	Repeat         ScheduleRepeat `json:"repeat"`
	StartDate      *string        `json:"start_date"`
	EndDate        *string        `json:"end_date"`
	MaxOccurrences *int           `json:"max_occurrences"`
	Active         bool           `json:"active"`
	Status         string         `json:"status"` // active | paused | completed
	PausedReason   *string        `json:"paused_reason"`
	NextRunAt      *string        `json:"next_run_at"`
	LastRunAt      *string        `json:"last_run_at"`
	LastStatus     *string        `json:"last_status"`
	LastError      *string        `json:"last_error"`
	LastMessageID  *string        `json:"last_message_id"`
	Counts         map[string]int `json:"counts"`
	Test           bool           `json:"test"`
	CreatedAt      string         `json:"created_at"`
	UpdatedAt      string         `json:"updated_at"`
	// RecentOccurrences is set only by Schedules.Get: the last 10, newest first.
	RecentOccurrences []map[string]any `json:"recent_occurrences,omitempty"`
}

// Deleted is the answer to every delete call.
type Deleted struct {
	ID      string `json:"id"`
	Object  string `json:"object"`
	Deleted bool   `json:"deleted"`
}

// Verification is a one-time code sent to a phone.
type Verification struct {
	ID                string `json:"id"`
	Object            string `json:"object"` // "verification"
	Phone             string `json:"phone"`
	Status            string `json:"status"` // pending | approved | expired | max_attempts | blocked
	Attempts          int    `json:"attempts"`
	AttemptsRemaining int    `json:"attempts_remaining"`
	MaxAttempts       int    `json:"max_attempts"`
	Test              bool   `json:"test"`
	CreatedAt         string `json:"created_at"`
	ExpiresAt         string `json:"expires_at"`
	ExpiresIn         int    `json:"expires_in"`
	CustomerID        string `json:"customer_id,omitempty"`
	Charged           bool   `json:"charged,omitempty"`
}

// VerificationCheck is the answer to Verify.Check. You are billed only when
// Verified is true.
type VerificationCheck struct {
	Verified          bool   `json:"verified"`
	Status            string `json:"status"`
	Attempts          int    `json:"attempts"`
	AttemptsRemaining int    `json:"attempts_remaining"`
	MaxAttempts       int    `json:"max_attempts"`
	Charged           bool   `json:"charged"`
}

// PhoneNumber is a number on your account.
type PhoneNumber struct {
	ID          string  `json:"id"`
	Object      string  `json:"object"` // "number"
	PhoneNumber string  `json:"phone_number"`
	Status      string  `json:"status"` // active | released
	Mode        string  `json:"mode"`   // test | live
	CreatedAt   string  `json:"created_at"`
	CustomerID  *string `json:"customer_id"`
}

// AvailableNumber is a number you can buy.
type AvailableNumber struct {
	Object      string `json:"object"` // "available_number"
	PhoneNumber string `json:"phone_number"`
	Locality    string `json:"locality"`
	Region      string `json:"region"`
}

// CreateLinkParams are the inputs to Links.Create.
type CreateLinkParams struct {
	URL  string `json:"url"`
	Name string `json:"name,omitempty"`
}

// TrackedLink is a tracked destination with its clicks and conversions.
type TrackedLink struct {
	Object      string  `json:"object"` // "link"
	URL         string  `json:"url"`
	Name        *string `json:"name"`
	ShortURL    *string `json:"short_url"`
	ClickID     *string `json:"click_id"`
	Texts       int     `json:"texts"`
	Clicks      int     `json:"clicks"`
	Conversions int     `json:"conversions"`
	ValueCents  int64   `json:"value_cents"`
	Test        bool    `json:"test"`
}

// CreateConversionParams are the inputs to Conversions.Create.
type CreateConversionParams struct {
	ClickID    string `json:"click_id"`
	ValueCents int64  `json:"value_cents,omitempty"`
	Name       string `json:"name,omitempty"`
	ExternalID string `json:"external_id,omitempty"`
}

// Conversion is a sale or sign-up reported against a click.
type Conversion struct {
	ID         string  `json:"id"`
	Object     string  `json:"object"` // "conversion"
	ClickID    string  `json:"click_id"`
	URL        string  `json:"url"`
	Name       *string `json:"name"`
	ExternalID *string `json:"external_id"`
	ValueCents int64   `json:"value_cents"`
	Duplicate  bool    `json:"duplicate"`
	Test       bool    `json:"test"`
	CreatedAt  string  `json:"created_at"`
}

// Lookup is carrier and line type for a number.
type Lookup struct {
	PhoneNumber string             `json:"phone_number"`
	Valid       bool               `json:"valid"`
	LineType    *string            `json:"line_type"`
	Carrier     map[string]*string `json:"carrier"`
	CallerName  *string            `json:"caller_name"`
}

// Balance is your prepaid credit balance and auto-recharge setting.
type Balance struct {
	Object          string  `json:"object"` // "balance"
	BalanceMicroUSD int64   `json:"balance_micro_usd"`
	BalanceUSD      float64 `json:"balance_usd"`
	Currency        string  `json:"currency"`
	LowBalanceUSD   float64 `json:"low_balance_usd"`
	AutoRecharge    struct {
		Enabled      bool    `json:"enabled"`
		ThresholdUSD float64 `json:"threshold_usd"`
		AmountUSD    float64 `json:"amount_usd"`
	} `json:"auto_recharge"`
	TopUpURL string `json:"top_up_url"`
}

// Event is something that happened on your account; also the body of every webhook.
type Event struct {
	ID        string         `json:"id"`
	Object    string         `json:"object"` // "event"
	Type      string         `json:"type"`
	CreatedAt string         `json:"created_at"`
	Data      map[string]any `json:"data"`
}

// EventWait is the answer to Events.Wait. Data is oldest first and may
// repeat an event already returned (de-duplicate by ID); pass Cursor back.
type EventWait struct {
	Object  string  `json:"object"` // "event_wait"
	Data    []Event `json:"data"`
	Cursor  string  `json:"cursor"`
	HasMore bool    `json:"has_more"`
}

// TrackedEvent is the answer to Events.Track: the event, and what it did.
type TrackedEvent struct {
	ID           string         `json:"id"`
	Object       string         `json:"object"` // "tracked_event"
	Event        string         `json:"event"`
	UserID       *string        `json:"user_id"`
	Phone        *string        `json:"phone"`
	Properties   map[string]any `json:"properties"`
	Test         bool           `json:"test"`
	RunsStarted  []string       `json:"runs_started"`
	RunsNotified int            `json:"runs_notified"`
	CreatedAt    string         `json:"created_at"`
}

// WebhookEndpoint is where events are POSTed.
type WebhookEndpoint struct {
	ID     string `json:"id"`
	Object string `json:"object"` // "webhook_endpoint"
	URL    string `json:"url"`
	// Events is "*" for every event, or a list of event types.
	Events      json.RawMessage `json:"events"`
	Active      bool            `json:"active"`
	Description *string         `json:"description"`
	CreatedAt   string          `json:"created_at"`
	// Secret is returned once, by Webhooks.Create. Store it.
	Secret string `json:"secret,omitempty"`
}

// EventTypes is the subscribed event types; nil means every event ("*").
func (w *WebhookEndpoint) EventTypes() []string {
	var list []string
	if json.Unmarshal(w.Events, &list) == nil {
		return list
	}
	return nil
}

// ConsentRecord is one opted-out number on your suppression list.
type ConsentRecord struct {
	Object     string  `json:"object"` // "consent"
	Phone      string  `json:"phone"`
	Status     string  `json:"status"` // "opted_out"
	UpdatedAt  string  `json:"updated_at"`
	Via        string  `json:"via"`
	Method     string  `json:"method,omitempty"`
	Detected   string  `json:"detected,omitempty"`
	Confidence float64 `json:"confidence,omitempty"`
}

// ConsentDetail is the current status plus the append-only history for one number.
type ConsentDetail struct {
	Object         string           `json:"object"` // "consent"
	Phone          string           `json:"phone"`
	Status         string           `json:"status"` // opted_out | opted_in | none
	History        []map[string]any `json:"history"`
	OptedOutAt     string           `json:"opted_out_at,omitempty"`
	OptedOutVia    string           `json:"opted_out_via,omitempty"`
	OptedOutMethod string           `json:"opted_out_method,omitempty"`
	BlockedSends   int              `json:"blocked_sends,omitempty"`
	LastBlockedAt  *string          `json:"last_blocked_at,omitempty"`
}

// ConsentUpdate is the answer to Consent.OptOut and Consent.OptIn.
type ConsentUpdate struct {
	Object     string         `json:"object"` // "consent"
	Phone      string         `json:"phone"`
	Status     string         `json:"status"` // opted_out | opted_in
	CampaignID string         `json:"campaign_id,omitempty"`
	Proof      map[string]any `json:"proof,omitempty"`
}

// OptInProof is opt-in evidence. Required for an opt-in recorded for a
// marketing or mixed registration: Source, CollectedAt, and PageURL
// (web_form) or MessageID (keyword).
type OptInProof struct {
	Source      string `json:"source,omitempty"` // web_form | keyword | paper | checkout | verbal
	CollectedAt string `json:"collected_at,omitempty"`
	PageURL     string `json:"page_url,omitempty"`
	Disclosure  string `json:"disclosure,omitempty"`
	IP          string `json:"ip,omitempty"`
	UserAgent   string `json:"user_agent,omitempty"`
	MessageID   string `json:"message_id,omitempty"`
}

// ConsentImport is the answer to Consent.Import.
type ConsentImport struct {
	Object   string              `json:"object"` // "consent_import"
	Imported int                 `json:"imported"`
	Skipped  []map[string]string `json:"skipped"`
}

// Customer is a business you send on behalf of (for platforms).
type Customer struct {
	ID           string            `json:"id"`
	Object       string            `json:"object"` // "customer"
	Name         *string           `json:"name"`
	ExternalID   *string           `json:"external_id"`
	Metadata     map[string]string `json:"metadata"`
	CreatedAt    string            `json:"created_at"`
	UpdatedAt    string            `json:"updated_at"`
	PhoneNumbers []string          `json:"phone_numbers,omitempty"`
}

// CustomerUsageDay is one UTC day of a customer's usage.
type CustomerUsageDay struct {
	Date                  string `json:"date"`
	MessagesSent          int    `json:"messages_sent"`
	MessagesFailed        int    `json:"messages_failed"`
	MessagesReceived      int    `json:"messages_received"`
	VerificationsSent     int    `json:"verifications_sent"`
	VerificationsApproved int    `json:"verifications_approved"`
}

// CustomerUsage is a customer's usage over a date range.
type CustomerUsage struct {
	Object                string             `json:"object"` // "customer_usage"
	CustomerID            string             `json:"customer_id"`
	Mode                  string             `json:"mode"`
	Start                 string             `json:"start"`
	End                   string             `json:"end"`
	MessagesSent          int                `json:"messages_sent"`
	MessagesFailed        int                `json:"messages_failed"`
	MessagesReceived      int                `json:"messages_received"`
	VerificationsSent     int                `json:"verifications_sent"`
	VerificationsApproved int                `json:"verifications_approved"`
	Numbers               int                `json:"numbers"`
	PhoneNumbers          []string           `json:"phone_numbers"`
	Daily                 []CustomerUsageDay `json:"daily"`
}

// Contact is one entry in the address book (one per phone number).
type Contact struct {
	ID          string            `json:"id"`
	Object      string            `json:"object"` // "contact"
	PhoneNumber string            `json:"phone_number"`
	Name        *string           `json:"name"`
	Tags        []string          `json:"tags"`
	Fields      map[string]string `json:"fields"`
	Notes       *string           `json:"notes"`
	CreatedAt   string            `json:"created_at"`
	UpdatedAt   string            `json:"updated_at"`
}

// ContactImport is the answer to Contacts.Import.
type ContactImport struct {
	Object  string `json:"object"` // "contact_import"
	Created int    `json:"created"`
	Updated int    `json:"updated"`
	Skipped []struct {
		Index  int    `json:"index"`
		Value  string `json:"value"`
		Reason string `json:"reason"`
	} `json:"skipped"`
}

// ContactBulk is the answer to Contacts.Bulk.
type ContactBulk struct {
	Object  string `json:"object"` // "contact_bulk"
	Action  string `json:"action"`
	Updated int    `json:"updated"`
	Deleted int    `json:"deleted"`
	Missing int    `json:"missing"`
}

// Automation is an event-driven flow: a trigger event, then send / wait / branch steps.
type Automation struct {
	ID                 string              `json:"id"`
	Object             string              `json:"object"` // "automation"
	Name               string              `json:"name"`
	Status             string              `json:"status"` // draft | active | paused
	From               *string             `json:"from"`
	TopicID            *string             `json:"topic_id"`
	Trigger            map[string]any      `json:"trigger"`
	Steps              []map[string]any    `json:"steps"`
	Test               *bool               `json:"test"`
	Version            int                 `json:"version"`
	UnpublishedChanges bool                `json:"unpublished_changes"`
	Stats              map[string]any      `json:"stats"`
	Issues             []map[string]string `json:"issues"`
	CreatedAt          string              `json:"created_at"`
	UpdatedAt          string              `json:"updated_at"`
}

// AutomationRun is one person's way through a flow.
type AutomationRun struct {
	ID                string           `json:"id"`
	Object            string           `json:"object"` // "automation_run"
	AutomationID      string           `json:"automation_id"`
	AutomationVersion int              `json:"automation_version"`
	Status            string           `json:"status"` // running | waiting | completed | failed
	To                string           `json:"to"`
	UserID            *string          `json:"user_id"`
	Test              bool             `json:"test"`
	TriggerEvent      string           `json:"trigger_event"`
	Step              int              `json:"step"`
	WaitingUntil      *string          `json:"waiting_until"`
	WaitingForEvent   *string          `json:"waiting_for_event"`
	EndReason         *string          `json:"end_reason"`
	MessagesSent      int              `json:"messages_sent"`
	MessagesFailed    int              `json:"messages_failed"`
	Timeline          []map[string]any `json:"timeline"`
	StartedAt         string           `json:"started_at"`
	EndedAt           *string          `json:"ended_at"`
}

// Registration is a brand and campaign registration. Brand holds the
// business as the carriers register it.
type Registration struct {
	ID             string           `json:"id"`
	Object         string           `json:"object"` // "registration"
	Status         string           `json:"status"` // draft | checks_failed | ready | submitted | in_review | approved | rejected
	BusinessName   string           `json:"business_name"`
	Website        string           `json:"website"`
	UseCase        string           `json:"use_case"`
	Brand          map[string]any   `json:"brand"`
	SampleMessages []string         `json:"sample_messages"`
	SamplesSource  string           `json:"samples_source"`
	Guidance       map[string]any   `json:"guidance"`
	Check          map[string]any   `json:"check"`
	SampleCheck    map[string]any   `json:"sample_check"`
	Rejection      map[string]any   `json:"rejection"`
	Generated      map[string]any   `json:"generated"`
	Submissions    int              `json:"submissions"`
	History        []map[string]any `json:"history"`
	CreatedAt      string           `json:"created_at"`
	UpdatedAt      string           `json:"updated_at"`
}

// Page is one page of a list. Pass NextCursor back as Cursor for the next
// page, or use the resource's ListAll iterator and skip the bookkeeping.
type Page[T any] struct {
	Data       []T     `json:"data"`
	HasMore    bool    `json:"has_more"`
	NextCursor *string `json:"next_cursor"`
}

// Iter walks every item of a list, fetching pages as it goes:
//
//	it := client.Messages.ListAll(ctx, nil)
//	for it.Next() {
//		msg := it.Current()
//	}
//	if err := it.Err(); err != nil { ... }
type Iter[T any] struct {
	ctx    context.Context
	fetch  func(ctx context.Context, cursor string) (*Page[T], error)
	buf    []T
	cur    T
	cursor string
	done   bool
	err    error
}

func newIter[T any](ctx context.Context, fetch func(ctx context.Context, cursor string) (*Page[T], error)) *Iter[T] {
	return &Iter[T]{ctx: ctx, fetch: fetch}
}

// Next advances to the next item. It returns false when the list is
// exhausted or a page failed to load (see Err).
func (it *Iter[T]) Next() bool {
	for len(it.buf) == 0 {
		if it.done || it.err != nil {
			return false
		}
		page, err := it.fetch(it.ctx, it.cursor)
		if err != nil {
			it.err = err
			return false
		}
		it.buf = page.Data
		if !page.HasMore || page.NextCursor == nil || *page.NextCursor == "" {
			it.done = true
		} else {
			it.cursor = *page.NextCursor
		}
	}
	it.cur, it.buf = it.buf[0], it.buf[1:]
	return true
}

// Current is the item Next moved to.
func (it *Iter[T]) Current() T { return it.cur }

// Err is the error that stopped the iteration, if any.
func (it *Iter[T]) Err() error { return it.err }

// Optional is a field in an update call that can be left out, set, or
// cleared (sent as JSON null). The zero value is "left out".
type Optional[T any] struct {
	set   bool
	null  bool
	value T
}

// Set returns an Optional holding v.
func Set[T any](v T) Optional[T] { return Optional[T]{set: true, value: v} }

// Null returns an Optional that clears the field (sends null).
func Null[T any]() Optional[T] { return Optional[T]{set: true, null: true} }

// IsSet reports whether the field will be sent.
func (o Optional[T]) IsSet() bool { return o.set }

func (o Optional[T]) put(m map[string]any, key string) {
	if !o.set {
		return
	}
	if o.null {
		m[key] = nil
	} else {
		m[key] = o.value
	}
}
