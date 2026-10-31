package textkit

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

// Client behaviour against a scripted local HTTP server. No real API calls.

const testKey = "ssms_sk_test_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

type reply struct {
	status  int
	body    any // map/slice -> JSON; string -> sent as is
	headers map[string]string
	hang    time.Duration // sleep before answering (timeouts)
}

type call struct {
	Method string
	URI    string // path + query, as sent (escaped)
	Header http.Header
	JSON   any
}

type stub struct {
	t       *testing.T
	mu      sync.Mutex
	replies []reply
	calls   []call
	srv     *httptest.Server
}

func newStub(t *testing.T, replies ...reply) *stub {
	t.Helper()
	s := &stub{t: t, replies: replies}
	s.srv = httptest.NewServer(http.HandlerFunc(s.serve))
	t.Cleanup(s.srv.Close)
	return s
}

func (s *stub) serve(w http.ResponseWriter, r *http.Request) {
	raw, _ := io.ReadAll(r.Body)
	var parsed any
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &parsed); err != nil {
			s.t.Errorf("request body is not JSON: %q", raw)
		}
	}
	s.mu.Lock()
	s.calls = append(s.calls, call{Method: r.Method, URI: r.URL.RequestURI(), Header: r.Header.Clone(), JSON: parsed})
	if len(s.replies) == 0 {
		s.mu.Unlock()
		s.t.Errorf("unexpected request %s %s", r.Method, r.URL)
		w.WriteHeader(599)
		return
	}
	rep := s.replies[0]
	s.replies = s.replies[1:]
	s.mu.Unlock()

	if rep.hang > 0 {
		select {
		case <-time.After(rep.hang):
		case <-r.Context().Done():
			return
		}
	}
	for k, v := range rep.headers {
		w.Header().Set(k, v)
	}
	w.WriteHeader(rep.status)
	switch b := rep.body.(type) {
	case nil:
	case string:
		_, _ = io.WriteString(w, b)
	default:
		_ = json.NewEncoder(w).Encode(b)
	}
}

func (s *stub) client(t *testing.T, opts ...Option) (*Client, *[]time.Duration) {
	t.Helper()
	c, err := NewClient(testKey, append([]Option{WithBaseURL(s.srv.URL), WithDefaultFrom("+15005550100")}, opts...)...)
	if err != nil {
		t.Fatal(err)
	}
	var sleeps []time.Duration
	c.sleep = func(_ context.Context, d time.Duration) error { sleeps = append(sleeps, d); return nil }
	return c, &sleeps
}

func ok(body any) reply      { return reply{status: 200, body: body} }
func created(body any) reply { return reply{status: 201, body: body} }
func fail(status int, code string, extra ...any) reply {
	e := map[string]any{"code": code, "message": "nope"}
	for i := 0; i+1 < len(extra); i += 2 {
		e[extra[i].(string)] = extra[i+1]
	}
	return reply{status: status, body: map[string]any{"error": e}}
}

var msg = map[string]any{"id": "msg_1", "object": "message", "to": "+15005550006", "from": "+15005550100", "body": "hi", "status": "queued"}

func emptyPage() map[string]any {
	return map[string]any{"data": []any{}, "has_more": false, "next_cursor": nil}
}

func jsonOf(t *testing.T, s string) any {
	t.Helper()
	var v any
	if err := json.Unmarshal([]byte(s), &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func assertJSON(t *testing.T, got any, want string) {
	t.Helper()
	if w := jsonOf(t, want); !reflect.DeepEqual(got, w) {
		g, _ := json.Marshal(got)
		t.Fatalf("body\n got %s\nwant %s", g, want)
	}
}

func asError(t *testing.T, err error) *Error {
	t.Helper()
	var e *Error
	if !errors.As(err, &e) {
		t.Fatalf("want *Error, got %v", err)
	}
	return e
}

var ctx = context.Background()

// ── construction ────────────────────────────────────────────────────────────

func clearEnv(t *testing.T) {
	for _, n := range append(append(append([]string{}, apiKeyEnv...), baseURLEnv...), fromEnv...) {
		t.Setenv(n, "")
	}
}

func TestReadsKeyFromEnv(t *testing.T) {
	clearEnv(t)
	t.Setenv("TEXTKIT_API_KEY", testKey)
	c, err := NewClient("")
	if err != nil || !c.IsTestMode() {
		t.Fatalf("got %v %v", c, err)
	}
}

func TestLegacyEnvNamesStillRead(t *testing.T) {
	for _, name := range []string{"SIMPLESMS_API_KEY", "DELIVERED_API_KEY", "RESMS_API_KEY"} {
		clearEnv(t)
		t.Setenv(name, testKey)
		if c, err := NewClient(""); err != nil || !c.IsTestMode() {
			t.Fatalf("%s: %v", name, err)
		}
	}
	clearEnv(t)
	t.Setenv("DELIVERED_BASE_URL", "https://old.test/")
	c, _ := NewClient(testKey)
	if c.BaseURL() != "https://old.test/v1" {
		t.Fatal(c.BaseURL())
	}
}

func TestNewEnvNameWins(t *testing.T) {
	clearEnv(t)
	t.Setenv("TEXTKIT_API_KEY", "ssms_sk_live_nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn")
	t.Setenv("DELIVERED_API_KEY", testKey)
	t.Setenv("TEXTKIT_BASE_URL", "https://new.test")
	t.Setenv("DELIVERED_BASE_URL", "https://old.test")
	c, _ := NewClient("")
	if c.IsTestMode() || c.BaseURL() != "https://new.test/v1" {
		t.Fatal(c.IsTestMode(), c.BaseURL())
	}
}

func TestDefaultBaseURL(t *testing.T) {
	clearEnv(t)
	c, _ := NewClient(testKey)
	if c.BaseURL() != "https://api.jointextkit.com/v1" {
		t.Fatal(c.BaseURL())
	}
	for _, in := range []string{"https://x.test", "https://x.test/", "https://x.test/v1", "https://x.test/v1/"} {
		c, _ := NewClient(testKey, WithBaseURL(in))
		if c.BaseURL() != "https://x.test/v1" {
			t.Fatal(in, c.BaseURL())
		}
	}
}

func TestKeyPrefixes(t *testing.T) {
	for _, p := range []string{"ssms", "dsms", "resms"} {
		test, _ := NewClient(p + "_sk_test_" + strings.Repeat("a", 32))
		live, _ := NewClient(p + "_sk_live_" + strings.Repeat("a", 32))
		if !test.IsTestMode() || live.IsTestMode() {
			t.Fatal(p)
		}
	}
}

func TestMissingKey(t *testing.T) {
	clearEnv(t)
	_, err := NewClient("")
	if e := asError(t, err); e.Code != CodeInvalidAPIKey {
		t.Fatal(e.Code)
	}
}

// ── messages ────────────────────────────────────────────────────────────────

func TestSendShapeAuthAndIdempotency(t *testing.T) {
	s := newStub(t, created(msg))
	c, _ := s.client(t)
	out, err := c.Messages.Send(ctx, &SendMessageParams{To: "+15005550006", Body: "hi", From: "+15005550199"})
	if err != nil || out.ID != "msg_1" || out.From != "+15005550100" {
		t.Fatal(out, err)
	}
	cl := s.calls[0]
	if cl.Method != "POST" || cl.URI != "/v1/messages" {
		t.Fatal(cl.Method, cl.URI)
	}
	assertJSON(t, cl.JSON, `{"to":"+15005550006","body":"hi","from":"+15005550199"}`)
	if cl.Header.Get("Authorization") != "Bearer "+testKey {
		t.Fatal(cl.Header.Get("Authorization"))
	}
	if !strings.HasPrefix(cl.Header.Get("Idempotency-Key"), "sdk_") {
		t.Fatal(cl.Header.Get("Idempotency-Key"))
	}
	if cl.Header.Get("User-Agent") != "jointextkit-go/"+Version || cl.Header.Get("Content-Type") != "application/json" {
		t.Fatal(cl.Header)
	}
}

func TestSendOptionalFields(t *testing.T) {
	s := newStub(t, created(msg))
	c, _ := s.client(t)
	_, err := c.Messages.Send(ctx, &SendMessageParams{
		To: "+15005550006", Body: "hi", CustomerID: "cus_x", Category: "marketing", QuietHours: "defer",
		Consent:        &SendConsent{Source: "checkout", CollectedAt: "2026-10-01T00:00:00Z"},
		IdempotencyKey: "order:1",
	})
	if err != nil {
		t.Fatal(err)
	}
	assertJSON(t, s.calls[0].JSON, `{"to":"+15005550006","body":"hi","from":"+15005550100","customer_id":"cus_x",
		"category":"marketing","quiet_hours":"defer","consent":{"source":"checkout","collected_at":"2026-10-01T00:00:00Z"}}`)
	if s.calls[0].Header.Get("Idempotency-Key") != "order:1" {
		t.Fatal("own key not sent")
	}
}

func TestSendRequiresBody(t *testing.T) {
	s := newStub(t)
	c, _ := s.client(t)
	_, err := c.Messages.Send(ctx, &SendMessageParams{To: "+15005550006"})
	if e := asError(t, err); e.Param != "body" || e.Status != 0 {
		t.Fatal(e)
	}
}

func TestSendRetries5xxWithSameKey(t *testing.T) {
	s := newStub(t, fail(502, "carrier_error"), created(msg))
	c, sleeps := s.client(t)
	if _, err := c.Messages.Send(ctx, &SendMessageParams{To: "+15005550006", Body: "hi"}); err != nil {
		t.Fatal(err)
	}
	if len(s.calls) != 2 || len(*sleeps) != 1 {
		t.Fatal(len(s.calls), *sleeps)
	}
	if s.calls[0].Header.Get("Idempotency-Key") != s.calls[1].Header.Get("Idempotency-Key") {
		t.Fatal("key changed between attempts")
	}
}

func TestRetryAfterHeaderAndBody(t *testing.T) {
	s := newStub(t, reply{status: 429, body: map[string]any{"error": map[string]any{"code": "rate_limited"}}, headers: map[string]string{"Retry-After": "7"}}, ok(emptyPage()))
	c, sleeps := s.client(t)
	if _, err := c.Messages.List(ctx, nil); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(*sleeps, []time.Duration{7 * time.Second}) {
		t.Fatal(*sleeps)
	}

	s2 := newStub(t, fail(429, "rate_limited", "retry_after", 3), ok(msg))
	c2, sleeps2 := s2.client(t)
	if _, err := c2.Messages.Get(ctx, "msg_1"); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(*sleeps2, []time.Duration{3 * time.Second}) {
		t.Fatal(*sleeps2)
	}
}

func TestBackoffGrowsAndCaps(t *testing.T) {
	for attempt, base := range map[int]float64{1: 0.5, 2: 1, 3: 2, 4: 4, 8: 4} {
		d := backoff(attempt, &Error{}).Seconds()
		if d < base || d > base*1.25 {
			t.Fatalf("attempt %d: %v", attempt, d)
		}
	}
}

func TestGivesUpAfterMaxRetries(t *testing.T) {
	s := newStub(t, fail(503, "internal_error"), fail(503, "internal_error"), fail(503, "internal_error"))
	c, sleeps := s.client(t, WithMaxRetries(2))
	_, err := c.Messages.Get(ctx, "msg_1")
	if e := asError(t, err); e.Status != 503 || len(s.calls) != 3 || len(*sleeps) != 2 {
		t.Fatal(e, len(s.calls), *sleeps)
	}
}

func TestTimeoutIsAConnectionErrorAndRetried(t *testing.T) {
	s := newStub(t, reply{status: 200, body: msg, hang: time.Second}, ok(msg))
	c, _ := s.client(t, WithTimeout(50*time.Millisecond))
	out, err := c.Messages.Get(ctx, "msg_1")
	if err != nil || out.ID != "msg_1" || len(s.calls) != 2 {
		t.Fatal(out, err, len(s.calls))
	}
}

func TestConnectionErrorSurfaces(t *testing.T) {
	s := newStub(t)
	c, _ := s.client(t)
	s.srv.Close()
	_, err := c.Messages.Get(ctx, "msg_1")
	e := asError(t, err)
	if e.Code != CodeConnectionError || e.Status != 0 || !e.Retryable() || e.Unwrap() == nil {
		t.Fatal(e)
	}
}

func TestCancelledContextStopsRetrying(t *testing.T) {
	s := newStub(t, fail(503, "internal_error"))
	c, _ := s.client(t)
	cctx, cancel := context.WithCancel(ctx)
	c.sleep = func(context.Context, time.Duration) error { cancel(); return context.Canceled }
	_, err := c.Messages.Get(cctx, "msg_1")
	if e := asError(t, err); e.Status != 503 || len(s.calls) != 1 {
		t.Fatal(e, len(s.calls))
	}
}

func TestErrorEnvelopeAnd4xxNotRetried(t *testing.T) {
	s := newStub(t, fail(400, "invalid_request", "message", "`to` is bad", "param", "to"))
	c, _ := s.client(t)
	_, err := c.Messages.Send(ctx, &SendMessageParams{To: "nope", Body: "hi"})
	e := asError(t, err)
	if e.Code != "invalid_request" || e.Status != 400 || e.Param != "to" || e.Message != "`to` is bad" || e.Retryable() || len(s.calls) != 1 {
		t.Fatal(e, len(s.calls))
	}
	if !strings.Contains(e.Error(), "`to` is bad") {
		t.Fatal(e.Error())
	}
}

func TestInsufficientCreditsAndQuietHoursFields(t *testing.T) {
	s := newStub(t,
		fail(402, "insufficient_credits", "balance_micro_usd", 100, "required_micro_usd", 800, "top_up_url", "https://x/billing"),
		fail(403, "quiet_hours", "send_after", "2026-10-02T12:00:00Z", "recipient_local_time", "22:15", "timezone", "America/New_York", "message_id", "msg_b"),
	)
	c, _ := s.client(t)
	_, err := c.Messages.Send(ctx, &SendMessageParams{To: "+15005550006", Body: "hi"})
	e := asError(t, err)
	if *e.BalanceMicroUSD != 100 || *e.RequiredMicroUSD != 800 || e.TopUpURL != "https://x/billing" || e.Retryable() {
		t.Fatal(e)
	}
	_, err = c.Messages.Send(ctx, &SendMessageParams{To: "+15005550006", Body: "hi"})
	e = asError(t, err)
	if e.SendAfter != "2026-10-02T12:00:00Z" || e.RecipientLocalTime != "22:15" || e.Timezone != "America/New_York" || e.MessageID != "msg_b" {
		t.Fatal(e)
	}
}

func TestNonJSONErrorBody(t *testing.T) {
	s := newStub(t, reply{status: 500, body: "<html>bad gateway</html>"})
	c, _ := s.client(t, WithMaxRetries(0))
	_, err := c.Messages.Get(ctx, "msg_1")
	if e := asError(t, err); e.Code != CodeInternalError {
		t.Fatal(e)
	}
}

func TestDefaultFromLookedUpOnce(t *testing.T) {
	clearEnv(t)
	numbers := map[string]any{"data": []any{map[string]any{"phone_number": "+15005550100", "status": "active"}, map[string]any{"phone_number": "+15005550109", "status": "released"}}, "has_more": false}
	s := newStub(t, ok(numbers), created(msg), created(msg))
	c, err := NewClient(testKey, WithBaseURL(s.srv.URL))
	if err != nil {
		t.Fatal(err)
	}
	for _, b := range []string{"a", "b"} {
		if _, err := c.Messages.Send(ctx, &SendMessageParams{To: "+15005550006", Body: b}); err != nil {
			t.Fatal(err)
		}
	}
	if s.calls[0].URI != "/v1/numbers" || len(s.calls) != 3 {
		t.Fatal(s.calls)
	}
	if s.calls[1].JSON.(map[string]any)["from"] != "+15005550100" {
		t.Fatal(s.calls[1].JSON)
	}
}

func TestDefaultFromRefusesToGuess(t *testing.T) {
	clearEnv(t)
	numbers := map[string]any{"data": []any{map[string]any{"phone_number": "+1", "status": "active"}, map[string]any{"phone_number": "+2", "status": "active"}}, "has_more": false}
	s := newStub(t, ok(numbers))
	c, _ := NewClient(testKey, WithBaseURL(s.srv.URL))
	_, err := c.Messages.Send(ctx, &SendMessageParams{To: "+15005550006", Body: "a"})
	if e := asError(t, err); e.Param != "from" || !strings.Contains(e.Message, "2 numbers") {
		t.Fatal(e)
	}
}

func TestListAllFollowsCursors(t *testing.T) {
	s := newStub(t,
		ok(map[string]any{"data": []any{map[string]any{"id": "m3"}, map[string]any{"id": "m2"}}, "has_more": true, "next_cursor": "k2"}),
		ok(map[string]any{"data": []any{map[string]any{"id": "m1"}}, "has_more": false, "next_cursor": nil}),
	)
	c, _ := s.client(t)
	it := c.Messages.ListAll(ctx, &ListMessagesParams{Limit: 2, CustomerID: "cus_x", Cursor: "ignored"})
	var ids []string
	for it.Next() {
		ids = append(ids, it.Current().ID)
	}
	if it.Err() != nil || !reflect.DeepEqual(ids, []string{"m3", "m2", "m1"}) {
		t.Fatal(ids, it.Err())
	}
	if s.calls[0].URI != "/v1/messages?customer_id=cus_x&limit=2" || s.calls[1].URI != "/v1/messages?cursor=k2&customer_id=cus_x&limit=2" {
		t.Fatal(s.calls[0].URI, s.calls[1].URI)
	}
}

func TestIterStopsOnError(t *testing.T) {
	s := newStub(t, ok(map[string]any{"data": []any{map[string]any{"id": "e1"}}, "has_more": true, "next_cursor": "k"}), fail(404, "not_found"))
	c, _ := s.client(t)
	it := c.Events.ListAll(ctx, nil)
	n := 0
	for it.Next() {
		n++
	}
	if n != 1 || asError(t, it.Err()).Code != "not_found" {
		t.Fatal(n, it.Err())
	}
}

func TestScheduleSerializesUTC(t *testing.T) {
	s := newStub(t, created(map[string]any{"id": "sm_1", "object": "scheduled_message", "scheduled_at": "2026-10-02T09:30:00Z"}))
	c, _ := s.client(t)
	ny, _ := time.LoadLocation("America/New_York")
	out, err := c.Messages.Schedule(ctx, &ScheduleMessageParams{To: "+15005550006", Body: "later", SendAt: time.Date(2026, 10, 2, 5, 30, 0, 0, ny)})
	if err != nil || out.ID != "sm_1" {
		t.Fatal(out, err)
	}
	assertJSON(t, s.calls[0].JSON, `{"to":"+15005550006","body":"later","from":"+15005550100","scheduled_at":"2026-10-02T09:30:00Z"}`)
	if s.calls[0].Header.Get("Idempotency-Key") != "" {
		t.Fatal("schedule should not carry a key")
	}
}

func TestMessagesListFilters(t *testing.T) {
	s := newStub(t, ok(emptyPage()))
	c, _ := s.client(t)
	_, _ = c.Messages.List(ctx, &ListMessagesParams{Status: "blocked", BlockedReason: "quiet hours", ScheduleID: "sch_1"})
	if s.calls[0].URI != "/v1/messages?blocked_reason=quiet+hours&schedule_id=sch_1&status=blocked" {
		t.Fatal(s.calls[0].URI)
	}
}

// ── verify ──────────────────────────────────────────────────────────────────

func TestVerifySendIsNotRetried(t *testing.T) {
	s := newStub(t, fail(503, "internal_error"))
	c, _ := s.client(t)
	_, err := c.Verify.Send(ctx, &SendVerificationParams{To: "+14155550132", AppName: "Acme", CustomerID: "cus_x"})
	if err == nil || len(s.calls) != 1 {
		t.Fatal(err, len(s.calls))
	}
	assertJSON(t, s.calls[0].JSON, `{"to":"+14155550132","app_name":"Acme","customer_id":"cus_x"}`)
}

func TestVerifyCooldownIsPolicy(t *testing.T) {
	s := newStub(t, fail(429, "rate_limited", "retry_after", 60))
	c, sleeps := s.client(t)
	// Even a retryable GET under /verify is not retried on a cooldown.
	_, err := c.Verify.Get(ctx, "ver_1")
	if e := asError(t, err); *e.RetryAfter != 60 || len(*sleeps) != 0 || len(s.calls) != 1 {
		t.Fatal(e, *sleeps)
	}
}

func TestVerifyCheck(t *testing.T) {
	s := newStub(t, ok(map[string]any{"verified": true, "status": "approved", "charged": true}))
	c, _ := s.client(t)
	r, err := c.Verify.Check(ctx, "+14155550132", "111111")
	if err != nil || !r.Verified || !r.Charged {
		t.Fatal(r, err)
	}
	assertJSON(t, s.calls[0].JSON, `{"to":"+14155550132","code":"111111"}`)
}

// ── numbers, lookup, balance ────────────────────────────────────────────────

func TestNumbers(t *testing.T) {
	s := newStub(t,
		ok(emptyPage()),
		created(map[string]any{"id": "num_1", "phone_number": "+15005550110", "customer_id": "cus_x"}),
		ok(emptyPage()),
		ok(map[string]any{"id": "num_1", "customer_id": nil}),
		fail(503, "internal_error"),
	)
	c, _ := s.client(t)
	_, _ = c.Numbers.Available(ctx, &AvailableNumbersParams{AreaCode: "415"})
	n, _ := c.Numbers.Buy(ctx, "+15005550110", &BuyNumberParams{CustomerID: "cus_x"})
	_, _ = c.Numbers.List(ctx, &ListNumbersParams{CustomerID: "cus_x"})
	u, _ := c.Numbers.Update(ctx, "+15005550100", &UpdateNumberParams{CustomerID: nil})
	_, err := c.Numbers.Release(ctx, "+15005550100")

	if s.calls[0].URI != "/v1/numbers/available?area_code=415" {
		t.Fatal(s.calls[0].URI)
	}
	assertJSON(t, s.calls[1].JSON, `{"phone_number":"+15005550110","customer_id":"cus_x"}`)
	if *n.CustomerID != "cus_x" || u.CustomerID != nil {
		t.Fatal(n, u)
	}
	if s.calls[2].URI != "/v1/numbers?customer_id=cus_x" {
		t.Fatal(s.calls[2].URI)
	}
	if s.calls[3].Method != "PATCH" || s.calls[3].URI != "/v1/numbers/%2B15005550100" {
		t.Fatal(s.calls[3])
	}
	assertJSON(t, s.calls[3].JSON, `{"customer_id":null}`)
	if err == nil || len(s.calls) != 5 || s.calls[4].Method != "DELETE" {
		t.Fatal("release must not be retried", err, len(s.calls))
	}
}

func TestLookupAndBalance(t *testing.T) {
	s := newStub(t,
		ok(map[string]any{"phone_number": "+14155550132", "valid": true, "line_type": "mobile", "carrier": map[string]any{"name": "X"}}),
		ok(map[string]any{"object": "balance", "balance_micro_usd": 2500000, "balance_usd": 2.5, "auto_recharge": map[string]any{"enabled": true}}),
	)
	c, _ := s.client(t)
	l, err := c.Lookup.Phone(ctx, "+14155550132")
	if err != nil || *l.LineType != "mobile" || *l.Carrier["name"] != "X" || s.calls[0].URI != "/v1/lookup/%2B14155550132" {
		t.Fatal(l, err)
	}
	b, err := c.Balance.Get(ctx)
	if err != nil || b.BalanceUSD != 2.5 || b.BalanceMicroUSD != 2500000 || !b.AutoRecharge.Enabled {
		t.Fatal(b, err)
	}
}

// ── events ──────────────────────────────────────────────────────────────────

func TestEventsWaitAndTrack(t *testing.T) {
	s := newStub(t,
		ok(map[string]any{"object": "event_wait", "data": []any{}, "cursor": "c1", "has_more": false}),
		ok(map[string]any{"object": "event_wait", "data": []any{map[string]any{"id": "evt_1", "type": "message.received", "data": map[string]any{"body": "hi"}}}, "cursor": "c2"}),
		created(map[string]any{"id": "tev_1", "runs_started": []string{"run_1"}}),
		created(map[string]any{"id": "tev_2"}),
	)
	c, _ := s.client(t)
	first, _ := c.Events.Wait(ctx, nil)
	timeout := 20
	second, err := c.Events.Wait(ctx, &WaitEventsParams{Cursor: first.Cursor, Timeout: &timeout})
	if err != nil || second.Data[0].ID != "evt_1" || second.Data[0].Data["body"] != "hi" {
		t.Fatal(second, err)
	}
	if s.calls[0].URI != "/v1/events/wait" || s.calls[1].URI != "/v1/events/wait?cursor=c1&timeout=20" {
		t.Fatal(s.calls[0].URI, s.calls[1].URI)
	}

	r, err := c.Events.Track(ctx, &TrackEventParams{Event: "trial_started", UserID: "123", Phone: "+14155550132", Properties: map[string]any{"plan": "pro"}})
	if err != nil || r.RunsStarted[0] != "run_1" {
		t.Fatal(r, err)
	}
	assertJSON(t, s.calls[2].JSON, `{"event":"trial_started","user_id":"123","phone":"+14155550132","properties":{"plan":"pro"}}`)
	if s.calls[2].URI != "/v1/track" || s.calls[2].Header.Get("Idempotency-Key") == "" {
		t.Fatal(s.calls[2])
	}
	_, _ = c.Events.Track(ctx, &TrackEventParams{Event: "subscription_created", UserID: "123", IdempotencyKey: "mine"})
	assertJSON(t, s.calls[3].JSON, `{"event":"subscription_created","user_id":"123"}`)
	if s.calls[3].Header.Get("Idempotency-Key") != "mine" {
		t.Fatal("own key")
	}
}

// ── webhooks CRUD ───────────────────────────────────────────────────────────

func TestWebhookCRUD(t *testing.T) {
	ep := map[string]any{"id": "we_1", "object": "webhook_endpoint", "url": "https://x.test/h", "events": []string{"message.received"}, "active": true}
	withSecret := map[string]any{"id": "we_1", "events": "*", "secret": "whsec_x"}
	s := newStub(t, created(withSecret), ok(map[string]any{"data": []any{ep}, "has_more": false}), ok(ep), ok(ep), ok(ep), ok(map[string]any{"id": "we_1", "deleted": true}))
	c, _ := s.client(t)
	cr, err := c.Webhooks.Create(ctx, &CreateWebhookParams{URL: "https://x.test/h", Events: []string{"message.received"}, Description: "prod"})
	if err != nil || cr.Secret != "whsec_x" || cr.EventTypes() != nil {
		t.Fatal(cr, err)
	}
	list, _ := c.Webhooks.List(ctx)
	if !reflect.DeepEqual(list.Data[0].EventTypes(), []string{"message.received"}) {
		t.Fatal(list.Data[0].EventTypes())
	}
	_, _ = c.Webhooks.Get(ctx, "we_1")
	_, _ = c.Webhooks.Update(ctx, "we_1", &UpdateWebhookParams{Active: Set(false)})
	_, _ = c.Webhooks.Update(ctx, "we_1", &UpdateWebhookParams{Events: Set([]string{}), Description: Null[string]()})
	d, _ := c.Webhooks.Delete(ctx, "we_1")

	assertJSON(t, s.calls[0].JSON, `{"url":"https://x.test/h","events":["message.received"],"description":"prod"}`)
	want := []string{"POST /v1/webhooks", "GET /v1/webhooks", "GET /v1/webhooks/we_1", "PATCH /v1/webhooks/we_1", "PATCH /v1/webhooks/we_1", "DELETE /v1/webhooks/we_1"}
	for i, w := range want {
		if got := s.calls[i].Method + " " + s.calls[i].URI; got != w {
			t.Fatal(i, got)
		}
	}
	assertJSON(t, s.calls[3].JSON, `{"active":false}`)
	assertJSON(t, s.calls[4].JSON, `{"events":"*","description":null}`)
	if !d.Deleted {
		t.Fatal(d)
	}
}

func TestWebhookCreateNotRetried(t *testing.T) {
	s := newStub(t, fail(503, "internal_error"))
	c, _ := s.client(t)
	if _, err := c.Webhooks.Create(ctx, &CreateWebhookParams{URL: "https://x.test/h"}); err == nil || len(s.calls) != 1 {
		t.Fatal(err, len(s.calls))
	}
	assertJSON(t, s.calls[0].JSON, `{"url":"https://x.test/h"}`)
}

// ── consent ─────────────────────────────────────────────────────────────────

func TestConsent(t *testing.T) {
	s := newStub(t,
		ok(map[string]any{"status": "opted_out"}),
		ok(map[string]any{"status": "opted_in"}),
		ok(map[string]any{"status": "opted_in", "campaign_id": "reg_1"}),
		ok(map[string]any{"imported": 1}),
		reply{status: 200, body: "phone,status\n+14155550132,opted_out\n", headers: map[string]string{"Content-Type": "text/csv"}},
		ok(map[string]any{"phone": "+14155550132", "status": "none", "history": []any{}}),
	)
	c, _ := s.client(t)
	_, _ = c.Consent.OptOut(ctx, "+14155550132", &OptOutParams{Note: "crm"})
	_, _ = c.Consent.OptIn(ctx, "+14155550132", nil)
	_, _ = c.Consent.OptIn(ctx, "+14155550132", &OptInParams{CampaignID: "reg_1", Proof: &OptInProof{Source: "web_form", CollectedAt: "2026-10-01T15:04:05Z", PageURL: "https://acme.example/texts"}})
	_, _ = c.Consent.Import(ctx, []string{"+14155550132"})
	csv, err := c.Consent.Export(ctx)
	d, _ := c.Contacts.Consent(ctx, "+14155550132")

	assertJSON(t, s.calls[0].JSON, `{"status":"opted_out","note":"crm"}`)
	assertJSON(t, s.calls[1].JSON, `{"status":"opted_in"}`)
	assertJSON(t, s.calls[2].JSON, `{"status":"opted_in","campaign_id":"reg_1","proof":{"source":"web_form","collected_at":"2026-10-01T15:04:05Z","page_url":"https://acme.example/texts"}}`)
	assertJSON(t, s.calls[3].JSON, `{"phone_numbers":["+14155550132"]}`)
	if err != nil || !strings.HasPrefix(csv, "phone,status") {
		t.Fatal(csv, err)
	}
	if s.calls[0].URI != "/v1/consent/%2B14155550132" || s.calls[5].URI != "/v1/consent/%2B14155550132" || d.Status != "none" {
		t.Fatal(s.calls[0].URI, s.calls[5].URI)
	}
}

// ── customers, contacts ─────────────────────────────────────────────────────

func TestCustomers(t *testing.T) {
	s := newStub(t, created(map[string]any{"id": "cus_x"}), ok(map[string]any{}), ok(map[string]any{}), ok(map[string]any{"customer_id": "cus_x"}), ok(emptyPage()), ok(map[string]any{"deleted": true}))
	c, _ := s.client(t)
	_, _ = c.Customers.Create(ctx, &CreateCustomerParams{Name: "Acme", ExternalID: "acct_1", Metadata: map[string]string{"plan": "pro"}})
	_, _ = c.Customers.Update(ctx, "cus_x", &UpdateCustomerParams{Name: Set("Acme")})
	_, _ = c.Customers.Update(ctx, "cus_x", &UpdateCustomerParams{ExternalID: Null[string](), Metadata: Set(map[string]string{"plan": "pro"})})
	_, _ = c.Customers.Usage(ctx, "cus_x", &CustomerUsageParams{Start: "2026-10-01", End: "2026-10-31"})
	_, _ = c.Customers.List(ctx, &ListCustomersParams{ExternalID: "acct 1"})
	_, _ = c.Customers.Delete(ctx, "cus_x")

	assertJSON(t, s.calls[0].JSON, `{"name":"Acme","external_id":"acct_1","metadata":{"plan":"pro"}}`)
	assertJSON(t, s.calls[1].JSON, `{"name":"Acme"}`)
	assertJSON(t, s.calls[2].JSON, `{"external_id":null,"metadata":{"plan":"pro"}}`)
	if s.calls[3].URI != "/v1/customers/cus_x/usage?end=2026-10-31&start=2026-10-01" || s.calls[4].URI != "/v1/customers?external_id=acct+1" {
		t.Fatal(s.calls[3].URI, s.calls[4].URI)
	}
	if s.calls[5].Method != "DELETE" {
		t.Fatal(s.calls[5])
	}
}

func TestContacts(t *testing.T) {
	s := newStub(t, ok(map[string]any{"id": "con_1", "tags": []string{"vip"}}), ok(map[string]any{"created": 1}), ok(map[string]any{"updated": 2}), ok(map[string]any{}), ok(map[string]any{}), ok(emptyPage()), ok(map[string]any{"deleted": true}))
	c, _ := s.client(t)
	ct, _ := c.Contacts.Upsert(ctx, &ContactParams{PhoneNumber: "+14155550132", Name: "Ada", Tags: []string{"vip"}})
	_, _ = c.Contacts.Import(ctx, []ContactParams{{PhoneNumber: "+14155550133"}})
	_, _ = c.Contacts.Bulk(ctx, &ContactBulkParams{Action: "add_tags", IDs: []string{"con_1", "con_2"}, Tags: []string{"vip"}})
	_, _ = c.Contacts.Get(ctx, "con_1")
	_, _ = c.Contacts.Update(ctx, "con_1", &UpdateContactParams{Tags: Set([]string{}), Notes: Null[string]()})
	_, _ = c.Contacts.List(ctx, &ListContactsParams{Tag: "vip", PhoneNumber: "+14155550132"})
	_, _ = c.Contacts.Delete(ctx, "con_1")

	if ct.Tags[0] != "vip" {
		t.Fatal(ct)
	}
	assertJSON(t, s.calls[0].JSON, `{"phone_number":"+14155550132","name":"Ada","tags":["vip"]}`)
	assertJSON(t, s.calls[1].JSON, `{"contacts":[{"phone_number":"+14155550133"}]}`)
	assertJSON(t, s.calls[2].JSON, `{"action":"add_tags","ids":["con_1","con_2"],"tags":["vip"]}`)
	assertJSON(t, s.calls[4].JSON, `{"tags":[],"notes":null}`)
	if s.calls[5].URI != "/v1/contacts?phone_number=%2B14155550132&tag=vip" || s.calls[6].URI != "/v1/contacts/con_1" {
		t.Fatal(s.calls[5].URI)
	}
}

// ── automations, schedules, registrations ───────────────────────────────────

func TestAutomationLifecycle(t *testing.T) {
	s := newStub(t, created(map[string]any{"id": "auto_x", "status": "draft"}), ok(map[string]any{}), ok(map[string]any{"status": "active"}), ok(map[string]any{}), ok(emptyPage()), ok(map[string]any{"id": "run_1"}), ok(map[string]any{"status": "failed"}), ok(map[string]any{"deleted": true}))
	c, _ := s.client(t)
	a, _ := c.Automations.Create(ctx, &CreateAutomationParams{
		Name:    "Trial reminder",
		From:    Set("+15005550100"),
		Trigger: map[string]any{"event": "trial_started"},
		Steps:   []map[string]any{{"type": "wait", "seconds": 3600}, {"type": "send_sms", "body": "Hi"}},
	})
	_, _ = c.Automations.Update(ctx, a.ID, &UpdateAutomationParams{TopicID: Null[string]()})
	_, _ = c.Automations.Activate(ctx, a.ID)
	_, _ = c.Automations.Pause(ctx, a.ID)
	_, _ = c.Automations.Runs(ctx, a.ID, &ListRunsParams{Limit: 5})
	_, _ = c.Automations.Run(ctx, a.ID, "run_1")
	_, _ = c.Automations.CancelRun(ctx, a.ID, "run_1")
	_, _ = c.Automations.Delete(ctx, a.ID)

	assertJSON(t, s.calls[0].JSON, `{"name":"Trial reminder","from":"+15005550100","trigger":{"event":"trial_started"},"steps":[{"type":"wait","seconds":3600},{"type":"send_sms","body":"Hi"}]}`)
	assertJSON(t, s.calls[1].JSON, `{"topic_id":null}`)
	want := []string{"POST /v1/automations", "PATCH /v1/automations/auto_x", "POST /v1/automations/auto_x/activate", "POST /v1/automations/auto_x/pause",
		"GET /v1/automations/auto_x/runs?limit=5", "GET /v1/automations/auto_x/runs/run_1", "DELETE /v1/automations/auto_x/runs/run_1", "DELETE /v1/automations/auto_x"}
	for i, w := range want {
		if got := s.calls[i].Method + " " + s.calls[i].URI; got != w {
			t.Fatal(i, got)
		}
	}
}

func TestSchedules(t *testing.T) {
	clearEnv(t)
	sch := map[string]any{"id": "sch_x", "repeat": map[string]any{"frequency": "daily", "time": "08:00", "timezone": "America/New_York"}, "next_run_at": "2026-10-25T12:00:00Z"}
	s := newStub(t, created(sch), created(sch), ok(sch), ok(emptyPage()), ok(sch), ok(sch), ok(sch), ok(map[string]any{"deleted": true}))
	c, err := NewClient(testKey, WithBaseURL(s.srv.URL))
	if err != nil {
		t.Fatal(err)
	}
	repeat := ScheduleRepeat{Frequency: "daily", Time: "08:00", Timezone: "America/New_York"}
	out, _ := c.Schedules.Create(ctx, &CreateScheduleParams{To: "+14155550132", Body: "Good morning", Repeat: repeat})
	five := 5
	_, _ = c.Schedules.Create(ctx, &CreateScheduleParams{To: "+14155550132", Body: "b", Repeat: repeat, From: "+15005550199", MaxOccurrences: &five, IdempotencyKey: "mine"})
	_, _ = c.Schedules.Get(ctx, "sch_x")
	_, _ = c.Schedules.List(ctx)
	_, _ = c.Schedules.Pause(ctx, "sch_x")
	_, _ = c.Schedules.Resume(ctx, "sch_x")
	_, _ = c.Schedules.Update(ctx, "sch_x", &UpdateScheduleParams{Body: Set("new"), EndDate: Null[string]()})
	_, _ = c.Schedules.Delete(ctx, "sch_x")

	if *out.NextRunAt != "2026-10-25T12:00:00Z" || out.Repeat.Time != "08:00" {
		t.Fatal(out)
	}
	// No default number configured: from is left for the API to pick.
	assertJSON(t, s.calls[0].JSON, `{"to":"+14155550132","body":"Good morning","repeat":{"frequency":"daily","time":"08:00","timezone":"America/New_York"}}`)
	if s.calls[0].Header.Get("Idempotency-Key") == "" || s.calls[1].Header.Get("Idempotency-Key") != "mine" {
		t.Fatal("keys")
	}
	assertJSON(t, s.calls[1].JSON, `{"to":"+14155550132","body":"b","from":"+15005550199","max_occurrences":5,"repeat":{"frequency":"daily","time":"08:00","timezone":"America/New_York"}}`)
	assertJSON(t, s.calls[4].JSON, `{"active":false}`)
	assertJSON(t, s.calls[5].JSON, `{"active":true}`)
	assertJSON(t, s.calls[6].JSON, `{"body":"new","end_date":null}`)
	if s.calls[7].Method != "DELETE" || s.calls[7].URI != "/v1/schedules/sch_x" {
		t.Fatal(s.calls[7])
	}
}

func TestRegistrations(t *testing.T) {
	s := newStub(t, created(map[string]any{"id": "reg_1", "status": "ready"}), ok(map[string]any{}), ok(map[string]any{"status": "submitted"}), ok(emptyPage()))
	c, _ := s.client(t)
	r, _ := c.Registrations.Create(ctx, map[string]any{"business_name": "Acme", "website": "https://acme.example", "use_case": "customer_care"})
	_, _ = c.Registrations.Recheck(ctx, r.ID, map[string]any{"website": "https://acme.example/"})
	_, _ = c.Registrations.Submit(ctx, r.ID, &SubmitRegistrationParams{FeesAcknowledged: true, Attestation: &Attestation{SignerName: "Dana", SignerTitle: "Owner", Accepted: true}})
	_, _ = c.Registrations.Submissions(ctx, r.ID)

	assertJSON(t, s.calls[2].JSON, `{"fees_acknowledged":true,"attestation":{"signer_name":"Dana","signer_title":"Owner","accepted":true}}`)
	want := []string{"POST /v1/registrations", "POST /v1/registrations/reg_1/recheck", "POST /v1/registrations/reg_1/submit", "GET /v1/registrations/reg_1/submissions"}
	for i, w := range want {
		if got := s.calls[i].Method + " " + s.calls[i].URI; got != w {
			t.Fatal(i, got)
		}
	}
}
