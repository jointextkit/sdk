package textkit

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// Webhook signature verification.
//
// Every webhook carries "textkit-signature: t=<unix seconds>,v1=<hex>"
// where v1 = HMAC-SHA256(secret, "<t>.<raw body>"). Verify against the raw
// request body exactly as received; re-encoded JSON will not match.
//
// The same value is also sent as dsms-signature and resms-signature (the
// header names from before the product was renamed).

// DefaultTolerance is the maximum age, either direction, of a signature.
const DefaultTolerance = 300 * time.Second

// SignatureHeaders is every header name the signature is sent under, current first.
var SignatureHeaders = []string{"textkit-signature", "dsms-signature", "resms-signature"}

// EventIDHeaders is every header name the event id is sent under, current first.
var EventIDHeaders = []string{"textkit-event-id", "dsms-event-id", "resms-event-id"}

type verifyConfig struct {
	tolerance time.Duration
	now       time.Time
}

// VerifyOption tunes VerifyWebhook.
type VerifyOption func(*verifyConfig)

// WithTolerance sets the maximum signature age; 0 disables the check.
func WithTolerance(d time.Duration) VerifyOption { return func(c *verifyConfig) { c.tolerance = d } }

// WithNow sets the clock used for the tolerance check (tests).
func WithNow(t time.Time) VerifyOption { return func(c *verifyConfig) { c.now = t } }

func sigError(msg string) *Error {
	return &Error{Message: msg, Code: CodeInvalidSignature, Status: 400}
}

// VerifyWebhook checks a webhook from TextKit and returns the parsed event.
//
// payload is the raw request body; signature is the textkit-signature
// header value; secret is your endpoint's signing secret (whsec_...).
// Signatures older than 5 minutes are rejected so a captured request can't be
// replayed. Every failure is an *Error with Code CodeInvalidSignature.
func VerifyWebhook(payload []byte, signature, secret string, opts ...VerifyOption) (*Event, error) {
	cfg := verifyConfig{tolerance: DefaultTolerance}
	for _, o := range opts {
		o(&cfg)
	}
	if secret == "" {
		return nil, sigError("No webhook secret given.")
	}
	if signature == "" {
		return nil, sigError("Missing textkit-signature header.")
	}

	var timestamp int64
	haveTimestamp := false
	var candidates []string
	for _, part := range strings.Split(signature, ",") {
		key, value, ok := strings.Cut(part, "=")
		if !ok {
			continue
		}
		key, value = strings.TrimSpace(key), strings.TrimSpace(value)
		switch key {
		case "t":
			if isDigits(value) {
				if n, err := strconv.ParseInt(value, 10, 64); err == nil {
					timestamp, haveTimestamp = n, true
				}
			}
		case "v1":
			candidates = append(candidates, strings.ToLower(value))
		}
	}
	if !haveTimestamp || len(candidates) == 0 {
		return nil, sigError("Malformed textkit-signature header.")
	}

	now := cfg.now
	if now.IsZero() {
		now = time.Now()
	}
	if cfg.tolerance > 0 && math.Abs(float64(now.Unix()-timestamp)) > cfg.tolerance.Seconds() {
		return nil, sigError("Webhook timestamp is outside the tolerance window.")
	}

	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(strconv.FormatInt(timestamp, 10)))
	mac.Write([]byte("."))
	mac.Write(payload)
	expected := hex.EncodeToString(mac.Sum(nil))
	matched := false
	for _, c := range candidates {
		if hmac.Equal([]byte(expected), []byte(c)) {
			matched = true
		}
	}
	if !matched {
		return nil, sigError("Webhook signature does not match.")
	}

	event := new(Event)
	if err := json.Unmarshal(payload, event); err != nil {
		e := sigError("Webhook body is not valid JSON.")
		e.cause = err
		return nil, e
	}
	return event, nil
}

// VerifyWebhookRequest is VerifyWebhook with the signature read from the
// request's headers, under whichever name it arrived.
func VerifyWebhookRequest(payload []byte, header http.Header, secret string, opts ...VerifyOption) (*Event, error) {
	return VerifyWebhook(payload, SignatureFromHeaders(header), secret, opts...)
}

// SignatureFromHeaders returns the webhook signature, whichever name it arrived under.
func SignatureFromHeaders(h http.Header) string { return firstHeader(h, SignatureHeaders) }

// EventIDFromHeaders returns the event id (evt_..., stable across retries).
func EventIDFromHeaders(h http.Header) string { return firstHeader(h, EventIDHeaders) }

func firstHeader(h http.Header, names []string) string {
	for _, n := range names {
		if v := h.Get(n); v != "" {
			return v
		}
	}
	// A map built by hand may not use canonical keys.
	for _, n := range names {
		for k, vs := range h {
			if strings.EqualFold(k, n) && len(vs) > 0 && vs[0] != "" {
				return vs[0]
			}
		}
	}
	return ""
}

func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}
