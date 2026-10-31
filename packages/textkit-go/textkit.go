// Package textkit is the official Go client for the TextKit API
// (jointextkit.com): SMS, phone verification, and phone numbers.
//
// Standard library only. Every call takes a context.Context.
//
//	client, err := textkit.NewClient("") // reads TEXTKIT_API_KEY
//	if err != nil {
//		log.Fatal(err)
//	}
//	msg, err := client.Messages.Send(ctx, &textkit.SendMessageParams{
//		To:   "+15005550006",
//		Body: "Hello from TextKit",
//	})
//
// Every failure is a *Error; use errors.As to read its Code.
package textkit

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	mrand "math/rand"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Version is this package's version, sent in the User-Agent header.
const Version = "0.1.0"

// DefaultBaseURL is the API root used when neither WithBaseURL nor
// TEXTKIT_BASE_URL says otherwise.
const DefaultBaseURL = "https://api.jointextkit.com/v1"

// Environment variables, current name first. The later names are the ones
// from before each rename (SimpleSMS until 2026-10-28, Delivered before that);
// they are read only when the current one is unset.
var (
	apiKeyEnv  = []string{"TEXTKIT_API_KEY", "SIMPLESMS_API_KEY", "DELIVERED_API_KEY", "RESMS_API_KEY"}
	baseURLEnv = []string{"TEXTKIT_BASE_URL", "SIMPLESMS_BASE_URL", "DELIVERED_BASE_URL", "RESMS_BASE_URL"}
	fromEnv    = []string{"TEXTKIT_FROM", "SIMPLESMS_FROM", "DELIVERED_FROM"}
)

// Client talks to the TextKit API. It is safe for concurrent use.
type Client struct {
	Messages      *MessagesService
	Verify        *VerifyService
	Numbers       *NumbersService
	Lookup        *LookupService
	Links         *LinksService
	Conversions   *ConversionsService
	Balance       *BalanceService
	Events        *EventsService
	Webhooks      *WebhooksService
	Consent       *ConsentService
	Customers     *CustomersService
	Contacts      *ContactsService
	Automations   *AutomationsService
	Schedules     *SchedulesService
	Registrations *RegistrationsService

	apiKey     string
	baseURL    string
	maxRetries int
	timeout    time.Duration
	httpClient *http.Client
	sleep      func(context.Context, time.Duration) error

	fromMu      sync.Mutex
	defaultFrom string
}

// Option configures a Client.
type Option func(*Client)

// WithBaseURL points the client at another API root. "/v1" is appended when
// the URL does not already end with it, so both "https://api.example" and
// "https://api.example/v1" work.
func WithBaseURL(u string) Option { return func(c *Client) { c.baseURL = u } }

// WithMaxRetries sets how many times a transient failure (429, 5xx, network)
// is retried. Default 2.
func WithMaxRetries(n int) Option { return func(c *Client) { c.maxRetries = n } }

// WithTimeout sets the per-attempt timeout. Default 30 seconds.
func WithTimeout(d time.Duration) Option { return func(c *Client) { c.timeout = d } }

// WithHTTPClient swaps the HTTP layer (proxies, tracing, tests).
func WithHTTPClient(h *http.Client) Option { return func(c *Client) { c.httpClient = h } }

// WithDefaultFrom sets the number Messages.Send uses when From is empty.
// Defaults to TEXTKIT_FROM, else your account's only active number (looked
// up once; an error if you have several).
func WithDefaultFrom(number string) Option { return func(c *Client) { c.defaultFrom = number } }

// NewClient builds a client. An empty apiKey reads TEXTKIT_API_KEY.
func NewClient(apiKey string, opts ...Option) (*Client, error) {
	c := &Client{
		apiKey:     apiKey,
		maxRetries: 2,
		timeout:    30 * time.Second,
		httpClient: http.DefaultClient,
		sleep:      sleepCtx,
	}
	if c.apiKey == "" {
		c.apiKey = env(apiKeyEnv...)
	}
	for _, opt := range opts {
		opt(c)
	}
	if c.apiKey == "" {
		return nil, &Error{
			Message: "No TextKit key. Pass one to textkit.NewClient or set TEXTKIT_API_KEY. Get one free at https://jointextkit.com/console",
			Code:    CodeInvalidAPIKey,
		}
	}
	if c.baseURL == "" {
		c.baseURL = env(baseURLEnv...)
	}
	c.baseURL = normalizeBaseURL(c.baseURL)
	if c.defaultFrom == "" {
		c.defaultFrom = env(fromEnv...)
	}
	if c.httpClient == nil {
		c.httpClient = http.DefaultClient
	}
	if c.maxRetries < 0 {
		c.maxRetries = 0
	}

	c.Messages = &MessagesService{c}
	c.Verify = &VerifyService{c}
	c.Numbers = &NumbersService{c}
	c.Lookup = &LookupService{c}
	c.Links = &LinksService{c}
	c.Conversions = &ConversionsService{c}
	c.Balance = &BalanceService{c}
	c.Events = &EventsService{c}
	c.Webhooks = &WebhooksService{c}
	c.Consent = &ConsentService{c}
	c.Customers = &CustomersService{c}
	c.Contacts = &ContactsService{c}
	c.Automations = &AutomationsService{c}
	c.Schedules = &SchedulesService{c}
	c.Registrations = &RegistrationsService{c}
	return c, nil
}

// BaseURL is the API root this client sends to, ending in /v1.
func (c *Client) BaseURL() string { return c.baseURL }

// IsTestMode reports whether the client uses a sandbox (test) key.
func (c *Client) IsTestMode() bool {
	for _, p := range []string{"tk_sk_test_", "ssms_sk_test_", "dsms_sk_test_", "resms_sk_test_"} {
		if strings.HasPrefix(c.apiKey, p) {
			return true
		}
	}
	return false
}

func normalizeBaseURL(u string) string {
	if u == "" {
		return DefaultBaseURL
	}
	u = strings.TrimRight(u, "/")
	if !strings.HasSuffix(u, "/v1") {
		u += "/v1"
	}
	return u
}

func env(names ...string) string {
	for _, n := range names {
		if v := os.Getenv(n); v != "" {
			return v
		}
	}
	return ""
}

func sleepCtx(ctx context.Context, d time.Duration) error {
	if d <= 0 {
		return ctx.Err()
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// NewIdempotencyKey returns a fresh random key in the form the SDKs use.
func NewIdempotencyKey() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		// crypto/rand does not fail on supported platforms; fall back anyway.
		return fmt.Sprintf("sdk_%x", time.Now().UnixNano())
	}
	return "sdk_" + hex.EncodeToString(b[:])
}

type request struct {
	method         string
	path           string
	query          url.Values
	body           any
	idempotencyKey string
	// retryable: safe to resend. A POST is only marked so when it carries an
	// idempotency key; a verification cooldown is never retried.
	retryable bool
}

// do runs a request with retries and decodes a 2xx JSON answer into out
// (skipped when out is nil). It returns the raw body too.
func (c *Client) do(ctx context.Context, r request, out any) ([]byte, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	var payload []byte
	if r.body != nil {
		var err error
		payload, err = json.Marshal(r.body)
		if err != nil {
			return nil, &Error{Message: "Could not encode the request: " + err.Error(), Code: CodeInvalidRequest, cause: err}
		}
	}
	target := c.baseURL + r.path
	if q := encodeQuery(r.query); q != "" {
		target += "?" + q
	}

	var last *Error
	for attempt := 0; attempt <= c.maxRetries; attempt++ {
		if attempt > 0 {
			if err := c.sleep(ctx, backoff(attempt, last)); err != nil {
				return nil, last
			}
		}
		body, err := c.attempt(ctx, r, target, payload)
		if err == nil {
			if out != nil && len(body) > 0 {
				if jerr := json.Unmarshal(body, out); jerr != nil {
					return body, &Error{Message: "Could not decode the API's answer: " + jerr.Error(), Code: CodeInternalError, cause: jerr}
				}
			}
			return body, nil
		}
		last = err
		// The caller's own context ended: stop, whatever the error says.
		if ctx.Err() != nil {
			break
		}
		if !r.retryable || !last.Retryable() {
			break
		}
		if last.Code == CodeRateLimited && strings.HasPrefix(r.path, "/verify") {
			break
		}
	}
	return nil, last
}

func (c *Client) attempt(ctx context.Context, r request, target string, payload []byte) ([]byte, *Error) {
	actx := ctx
	if c.timeout > 0 {
		var cancel context.CancelFunc
		actx, cancel = context.WithTimeout(ctx, c.timeout)
		defer cancel()
	}
	var reader io.Reader
	if payload != nil {
		reader = bytes.NewReader(payload)
	}
	req, err := http.NewRequestWithContext(actx, r.method, target, reader)
	if err != nil {
		return nil, &Error{Message: "Could not build the request: " + err.Error(), Code: CodeInvalidRequest, cause: err}
	}
	req.Header.Set("Authorization", "Bearer "+c.apiKey)
	req.Header.Set("User-Agent", "jointextkit-go/"+Version)
	req.Header.Set("Accept", "application/json")
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if r.idempotencyKey != "" {
		req.Header.Set("Idempotency-Key", r.idempotencyKey)
	}

	res, err := c.httpClient.Do(req)
	if err != nil {
		msg := "Could not reach the TextKit API: " + err.Error()
		if errors.Is(err, context.DeadlineExceeded) && ctx.Err() == nil {
			msg = fmt.Sprintf("Request timed out after %s", c.timeout)
		}
		return nil, &Error{Message: msg, Code: CodeConnectionError, cause: err}
	}
	defer res.Body.Close()
	body, err := io.ReadAll(res.Body)
	if err != nil {
		return nil, &Error{Message: "Could not read the API's answer: " + err.Error(), Code: CodeConnectionError, cause: err}
	}
	if res.StatusCode >= 200 && res.StatusCode < 300 {
		return body, nil
	}
	return nil, errorFromResponse(res.StatusCode, res.Header, body)
}

func backoff(attempt int, last *Error) time.Duration {
	if last != nil && last.RetryAfter != nil && *last.RetryAfter >= 0 {
		return time.Duration(*last.RetryAfter * float64(time.Second))
	}
	base := math.Min(0.25*math.Pow(2, float64(attempt)), 4.0)
	jitter := mrand.Float64() * base / 4
	return time.Duration((base + jitter) * float64(time.Second))
}

// encodeQuery drops empty values and keeps a stable order.
func encodeQuery(q url.Values) string {
	if len(q) == 0 {
		return ""
	}
	keys := make([]string, 0, len(q))
	for k, vs := range q {
		if len(vs) > 0 && vs[0] != "" {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, url.QueryEscape(k)+"="+url.QueryEscape(q.Get(k)))
	}
	return strings.Join(parts, "&")
}

// pathEscape escapes one path segment, "+" included (phone numbers).
func pathEscape(s string) string {
	return strings.ReplaceAll(url.QueryEscape(s), "+", "%20")
}

func intString(n int) string {
	if n == 0 {
		return ""
	}
	return strconv.Itoa(n)
}

// resolveFrom returns the default sending number, looking up the account's
// only active number once when none was configured.
func (c *Client) resolveFrom(ctx context.Context) (string, error) {
	c.fromMu.Lock()
	defer c.fromMu.Unlock()
	if c.defaultFrom != "" {
		return c.defaultFrom, nil
	}
	page, err := c.Numbers.List(ctx, nil)
	if err != nil {
		return "", err
	}
	var active []string
	for _, n := range page.Data {
		if n.Status == "active" {
			active = append(active, n.PhoneNumber)
		}
	}
	if len(active) != 1 {
		what := "no numbers yet."
		if len(active) > 1 {
			what = fmt.Sprintf("%d numbers.", len(active))
		}
		return "", &Error{
			Message: "Set From (or TEXTKIT_FROM): your account has " + what,
			Code:    CodeInvalidRequest,
			Param:   "from",
		}
	}
	c.defaultFrom = active[0]
	return c.defaultFrom, nil
}
