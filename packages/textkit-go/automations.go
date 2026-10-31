package textkit

import (
	"context"
	"net/url"
)

// ── automations ─────────────────────────────────────────────────────────────

// AutomationsService manages event-driven flows: a trigger event, then
// send / wait / branch steps.
type AutomationsService struct{ c *Client }

// CreateAutomationParams is what Automations.Create takes.
type CreateAutomationParams struct {
	Name string
	// Trigger, e.g. {"event": "trial_started"}.
	Trigger map[string]any
	// Steps, e.g. {"type": "wait", "seconds": 3600}, {"type": "send_sms", "body": "..."}.
	Steps   []map[string]any
	From    Optional[string]
	// Category is what it sends: marketing, transactional or otp. With no From,
	// TextKit picks a number approved for it.
	Category Optional[string]
	TopicID  Optional[string]
}

// Create makes a flow as a draft. Issues on the answer lists what stops it
// from running. Not retried.
func (s *AutomationsService) Create(ctx context.Context, p *CreateAutomationParams) (*Automation, error) {
	if p == nil {
		p = &CreateAutomationParams{}
	}
	steps := p.Steps
	if steps == nil {
		steps = []map[string]any{}
	}
	body := map[string]any{"name": p.Name, "trigger": p.Trigger, "steps": steps}
	p.From.put(body, "from")
	p.TopicID.put(body, "topic_id")
	p.Category.put(body, "category")
	out := new(Automation)
	_, err := s.c.do(ctx, request{method: "POST", path: "/automations", body: body}, out)
	return result(out, err)
}

// Get fetches one flow.
func (s *AutomationsService) Get(ctx context.Context, id string) (*Automation, error) {
	out := new(Automation)
	_, err := s.c.do(ctx, request{method: "GET", path: "/automations/" + pathEscape(id), retryable: true}, out)
	return result(out, err)
}

// List returns your flows.
func (s *AutomationsService) List(ctx context.Context) (*Page[Automation], error) {
	out := new(Page[Automation])
	_, err := s.c.do(ctx, request{method: "GET", path: "/automations", retryable: true}, out)
	return result(out, err)
}

// UpdateAutomationParams changes only the fields that are Set.
type UpdateAutomationParams struct {
	Name    Optional[string]
	Trigger Optional[map[string]any]
	Steps   Optional[[]map[string]any]
	From    Optional[string]
	// Category is what it sends: marketing, transactional or otp. With no From,
	// TextKit picks a number approved for it.
	Category Optional[string]
	TopicID  Optional[string]
}

// Update changes a flow. Editing an active flow publishes a new version. Not retried.
func (s *AutomationsService) Update(ctx context.Context, id string, p *UpdateAutomationParams) (*Automation, error) {
	body := map[string]any{}
	if p != nil {
		p.Name.put(body, "name")
		p.From.put(body, "from")
		p.TopicID.put(body, "topic_id")
		p.Category.put(body, "category")
		p.Trigger.put(body, "trigger")
		p.Steps.put(body, "steps")
	}
	out := new(Automation)
	_, err := s.c.do(ctx, request{method: "PATCH", path: "/automations/" + pathEscape(id), body: body}, out)
	return result(out, err)
}

// Delete removes a flow. Runs in progress stop; nothing more is sent.
func (s *AutomationsService) Delete(ctx context.Context, id string) (*Deleted, error) {
	out := new(Deleted)
	_, err := s.c.do(ctx, request{method: "DELETE", path: "/automations/" + pathEscape(id)}, out)
	return result(out, err)
}

// Activate turns a flow on. Fails with invalid_request when it is not ready.
func (s *AutomationsService) Activate(ctx context.Context, id string) (*Automation, error) {
	out := new(Automation)
	_, err := s.c.do(ctx, request{method: "POST", path: "/automations/" + pathEscape(id) + "/activate", retryable: true}, out)
	return result(out, err)
}

// Pause stops new runs and holds the ones in progress until it is activated again.
func (s *AutomationsService) Pause(ctx context.Context, id string) (*Automation, error) {
	out := new(Automation)
	_, err := s.c.do(ctx, request{method: "POST", path: "/automations/" + pathEscape(id) + "/pause", retryable: true}, out)
	return result(out, err)
}

// ListRunsParams pages Automations.Runs.
type ListRunsParams struct {
	Limit  int
	Cursor string
}

// Runs returns one page of a flow's runs, newest first.
func (s *AutomationsService) Runs(ctx context.Context, id string, p *ListRunsParams) (*Page[AutomationRun], error) {
	if p == nil {
		p = &ListRunsParams{}
	}
	q := url.Values{"limit": {intString(p.Limit)}, "cursor": {p.Cursor}}
	out := new(Page[AutomationRun])
	_, err := s.c.do(ctx, request{method: "GET", path: "/automations/" + pathEscape(id) + "/runs", query: q, retryable: true}, out)
	return result(out, err)
}

// ListAllRuns walks every run of a flow. p.Cursor is ignored.
func (s *AutomationsService) ListAllRuns(ctx context.Context, id string, p *ListRunsParams) *Iter[AutomationRun] {
	base := ListRunsParams{}
	if p != nil {
		base = *p
	}
	return newIter(ctx, func(ctx context.Context, cursor string) (*Page[AutomationRun], error) {
		q := base
		q.Cursor = cursor
		return s.Runs(ctx, id, &q)
	})
}

// Run fetches one run, with its timeline.
func (s *AutomationsService) Run(ctx context.Context, id, runID string) (*AutomationRun, error) {
	out := new(AutomationRun)
	_, err := s.c.do(ctx, request{method: "GET", path: "/automations/" + pathEscape(id) + "/runs/" + pathEscape(runID), retryable: true}, out)
	return result(out, err)
}

// CancelRun cancels a run in progress.
func (s *AutomationsService) CancelRun(ctx context.Context, id, runID string) (*AutomationRun, error) {
	out := new(AutomationRun)
	_, err := s.c.do(ctx, request{method: "DELETE", path: "/automations/" + pathEscape(id) + "/runs/" + pathEscape(runID)}, out)
	return result(out, err)
}

// ── schedules ───────────────────────────────────────────────────────────────

// SchedulesService manages recurring schedules: one message to one number on
// a repeating local time. Each occurrence is a normal send (opt-outs, quota
// and spend limit are checked when it fires) and a normal message with
// ScheduleID set.
type SchedulesService struct{ c *Client }

// CreateScheduleParams is what Schedules.Create takes.
type CreateScheduleParams struct {
	To   string
	Body string
	// Repeat: Frequency "daily", "weekly" (with DaysOfWeek) or "monthly"
	// (with DayOfMonth), at a wall-clock Time in Timezone.
	Repeat ScheduleRepeat
	// From falls back to the client's default number; left out entirely, the
	// API uses your account's one number for the key's mode.
	From           string
	StartDate      string
	EndDate        string
	MaxOccurrences *int
	// IdempotencyKey is generated when empty, so retries are safe.
	IdempotencyKey string
}

// Create makes a schedule.
func (s *SchedulesService) Create(ctx context.Context, p *CreateScheduleParams) (*Schedule, error) {
	if p == nil {
		p = &CreateScheduleParams{}
	}
	body := map[string]any{"to": p.To, "body": p.Body, "repeat": p.Repeat}
	from := p.From
	if from == "" {
		s.c.fromMu.Lock()
		from = s.c.defaultFrom
		s.c.fromMu.Unlock()
	}
	putString(body, "from", from)
	putString(body, "start_date", p.StartDate)
	putString(body, "end_date", p.EndDate)
	if p.MaxOccurrences != nil {
		body["max_occurrences"] = *p.MaxOccurrences
	}
	key := p.IdempotencyKey
	if key == "" {
		key = NewIdempotencyKey()
	}
	out := new(Schedule)
	_, err := s.c.do(ctx, request{method: "POST", path: "/schedules", body: body, idempotencyKey: key, retryable: true}, out)
	return result(out, err)
}

// Get fetches one schedule, with its RecentOccurrences.
func (s *SchedulesService) Get(ctx context.Context, id string) (*Schedule, error) {
	out := new(Schedule)
	_, err := s.c.do(ctx, request{method: "GET", path: "/schedules/" + pathEscape(id), retryable: true}, out)
	return result(out, err)
}

// List returns your schedules.
func (s *SchedulesService) List(ctx context.Context) (*Page[Schedule], error) {
	out := new(Page[Schedule])
	_, err := s.c.do(ctx, request{method: "GET", path: "/schedules", retryable: true}, out)
	return result(out, err)
}

// UpdateScheduleParams changes only the fields that are Set. Null clears
// StartDate, EndDate or MaxOccurrences; Repeat replaces the whole object.
type UpdateScheduleParams struct {
	To             Optional[string]
	From           Optional[string]
	Body           Optional[string]
	Repeat         Optional[ScheduleRepeat]
	StartDate      Optional[string]
	EndDate        Optional[string]
	MaxOccurrences Optional[int]
	Active         Optional[bool]
}

// Update changes a schedule.
func (s *SchedulesService) Update(ctx context.Context, id string, p *UpdateScheduleParams) (*Schedule, error) {
	body := map[string]any{}
	if p != nil {
		p.To.put(body, "to")
		p.From.put(body, "from")
		p.Body.put(body, "body")
		p.Repeat.put(body, "repeat")
		p.StartDate.put(body, "start_date")
		p.EndDate.put(body, "end_date")
		p.MaxOccurrences.put(body, "max_occurrences")
		p.Active.put(body, "active")
	}
	out := new(Schedule)
	_, err := s.c.do(ctx, request{method: "PATCH", path: "/schedules/" + pathEscape(id), body: body, retryable: true}, out)
	return result(out, err)
}

// Pause stops sending until resumed.
func (s *SchedulesService) Pause(ctx context.Context, id string) (*Schedule, error) {
	return s.Update(ctx, id, &UpdateScheduleParams{Active: Set(false)})
}

// Resume starts again from now: nothing that came due while paused is sent.
func (s *SchedulesService) Resume(ctx context.Context, id string) (*Schedule, error) {
	return s.Update(ctx, id, &UpdateScheduleParams{Active: Set(true)})
}

// Delete stops a schedule for good. Messages it already sent stay in the log.
func (s *SchedulesService) Delete(ctx context.Context, id string) (*Deleted, error) {
	out := new(Deleted)
	_, err := s.c.do(ctx, request{method: "DELETE", path: "/schedules/" + pathEscape(id)}, out)
	return result(out, err)
}

// ── registrations ───────────────────────────────────────────────────────────

// RegistrationsService files brand and campaign registrations. Create runs
// the website and example checks; Recheck corrects and re-runs them; Submit
// files a ready registration.
type RegistrationsService struct{ c *Client }

// Create makes a registration and runs the website check right away. fields
// must carry business_name, website and use_case, plus any other
// registration field (opt_in_url, sample_messages, brand, ...). Not retried.
func (s *RegistrationsService) Create(ctx context.Context, fields map[string]any) (*Registration, error) {
	if fields == nil {
		fields = map[string]any{}
	}
	out := new(Registration)
	_, err := s.c.do(ctx, request{method: "POST", path: "/registrations", body: fields}, out)
	return result(out, err)
}

// Get fetches one registration.
func (s *RegistrationsService) Get(ctx context.Context, id string) (*Registration, error) {
	out := new(Registration)
	_, err := s.c.do(ctx, request{method: "GET", path: "/registrations/" + pathEscape(id), retryable: true}, out)
	return result(out, err)
}

// List returns your registrations.
func (s *RegistrationsService) List(ctx context.Context) (*Page[Registration], error) {
	out := new(Page[Registration])
	_, err := s.c.do(ctx, request{method: "GET", path: "/registrations", retryable: true}, out)
	return result(out, err)
}

// Recheck corrects any field and re-runs the checks (draft, checks_failed,
// ready or rejected). Not retried.
func (s *RegistrationsService) Recheck(ctx context.Context, id string, fields map[string]any) (*Registration, error) {
	if fields == nil {
		fields = map[string]any{}
	}
	out := new(Registration)
	_, err := s.c.do(ctx, request{method: "POST", path: "/registrations/" + pathEscape(id) + "/recheck", body: fields}, out)
	return result(out, err)
}

// Attestation is signed by someone authorized to act for the business.
type Attestation struct {
	SignerName  string `json:"signer_name"`
	SignerTitle string `json:"signer_title"`
	Accepted    bool   `json:"accepted"`
}

// SubmitRegistrationParams is what Registrations.Submit takes.
type SubmitRegistrationParams struct {
	// FeesAcknowledged must be true: it confirms the registration fee terms.
	// Carrier registration fees are billed at the registry's charge, a campaign carries a
	// 3-month minimum, and the fees are non-refundable even if the
	// registration is rejected. Without it the API answers invalid_request.
	FeesAcknowledged bool
	// Attestation is needed the first time for a business, or after the
	// business could not be verified; later submits need none.
	Attestation *Attestation
}

// Submit files a ready registration (or resubmits after a rejection). The
// submission is held while the business is verified, then filed. Not retried.
func (s *RegistrationsService) Submit(ctx context.Context, id string, p *SubmitRegistrationParams) (*Registration, error) {
	if p == nil {
		p = &SubmitRegistrationParams{}
	}
	body := map[string]any{"fees_acknowledged": p.FeesAcknowledged}
	if p.Attestation != nil {
		body["attestation"] = p.Attestation
	}
	out := new(Registration)
	_, err := s.c.do(ctx, request{method: "POST", path: "/registrations/" + pathEscape(id) + "/submit", body: body}, out)
	return result(out, err)
}

// Submissions returns the filed copies, oldest first: exactly what each
// submission sent.
func (s *RegistrationsService) Submissions(ctx context.Context, id string) (*Page[map[string]any], error) {
	out := new(Page[map[string]any])
	_, err := s.c.do(ctx, request{method: "GET", path: "/registrations/" + pathEscape(id) + "/submissions", retryable: true}, out)
	return result(out, err)
}
