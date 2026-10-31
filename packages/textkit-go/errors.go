package textkit

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
)

// Error codes the API returns, plus two the client adds itself:
// CodeConnectionError (the API was unreachable or timed out) and
// CodeInvalidSignature (a webhook failed verification).
const (
	CodeInvalidAPIKey        = "invalid_api_key"
	CodeTenantSuspended      = "tenant_suspended"
	CodeLiveAccessRequired   = "live_access_required"
	CodeTestModeOnly         = "test_mode_only"
	CodeForbidden            = "forbidden"
	CodeNotFound             = "not_found"
	CodeInvalidRequest       = "invalid_request"
	CodeRateLimited          = "rate_limited"
	CodeQuotaExceeded        = "quota_exceeded"
	CodeRecipientNotVerified = "recipient_not_verified"
	CodeVerificationBlocked  = "verification_blocked"
	CodeVerificationNotFound = "verification_not_found"
	CodeIdempotencyConflict  = "idempotency_conflict"
	CodeIdempotencyInProgress = "idempotency_in_progress"
	CodeCarrierError         = "carrier_error"
	CodeMMSNotEnabled        = "mms_not_enabled"
	CodeEndpointRetired      = "endpoint_retired"
	CodeSpendLimitReached    = "spend_limit_reached"
	CodeInsufficientCredits  = "insufficient_credits"
	CodeSenderNotRegistered  = "sender_not_registered"
	CodeRecipientOptedOut    = "recipient_opted_out"
	CodeQuietHours           = "quiet_hours"
	CodeCampaignMismatch     = "campaign_mismatch"
	CodeAttestationRequired  = "attestation_required"
	CodeInternalError        = "internal_error"
	CodeConnectionError      = "connection_error"
	CodeInvalidSignature     = "invalid_signature"
)

// Error is every failure the client returns. Read it with errors.As:
//
//	var apiErr *textkit.Error
//	if errors.As(err, &apiErr) && apiErr.Code == textkit.CodeRateLimited { ... }
type Error struct {
	Message string
	// Code is the API's machine-readable error code ("rate_limited", ...).
	Code string
	// Status is the HTTP status; 0 when the API was unreachable or the
	// client refused the call before sending it.
	Status int
	// Param is the request field that was wrong, when the API could tell.
	Param string
	// RetryAfter is how many seconds to wait, on rate limits.
	RetryAfter *float64
	// Reason is why a verification was blocked.
	Reason string
	// BalanceMicroUSD (insufficient_credits only): your balance, in millionths of a dollar.
	BalanceMicroUSD *int64
	// RequiredMicroUSD (insufficient_credits only): what the call costs, in millionths of a dollar.
	RequiredMicroUSD *int64
	// TopUpURL (insufficient_credits only): where to add credits.
	TopUpURL string
	// SendAfter (quiet_hours only): when the message may be sent (ISO timestamp).
	SendAfter string
	// RecipientLocalTime (quiet_hours only): the recipient's local time, 24-hour "HH:MM".
	RecipientLocalTime string
	// Timezone (quiet_hours only): the IANA time zone read from the number's area code.
	Timezone string
	// MessageID is the blocked message stored in your log for this refusal, when there is one.
	MessageID string

	cause error
}

func (e *Error) Error() string {
	if e.Status > 0 {
		return fmt.Sprintf("textkit: %s (%s, %d)", e.Message, e.Code, e.Status)
	}
	return fmt.Sprintf("textkit: %s (%s)", e.Message, e.Code)
}

// Unwrap returns the underlying network or decoding error, if any.
func (e *Error) Unwrap() error { return e.cause }

// Retryable reports whether retrying the same call later could plausibly succeed.
func (e *Error) Retryable() bool {
	return e.Status >= 500 || e.Code == CodeRateLimited || e.Code == CodeIdempotencyInProgress || e.Code == CodeCarrierError || e.Code == CodeConnectionError
}

type errorEnvelope struct {
	Error *struct {
		Code               string   `json:"code"`
		Message            string   `json:"message"`
		Param              string   `json:"param"`
		RetryAfter         *float64 `json:"retry_after"`
		Reason             string   `json:"reason"`
		BalanceMicroUSD    *int64   `json:"balance_micro_usd"`
		RequiredMicroUSD   *int64   `json:"required_micro_usd"`
		TopUpURL           string   `json:"top_up_url"`
		SendAfter          string   `json:"send_after"`
		RecipientLocalTime string   `json:"recipient_local_time"`
		Timezone           string   `json:"timezone"`
		MessageID          string   `json:"message_id"`
	} `json:"error"`
}

func errorFromResponse(status int, header http.Header, body []byte) *Error {
	var env errorEnvelope
	_ = json.Unmarshal(body, &env) // a non-JSON body (a proxy's HTML page) leaves it empty

	e := &Error{Status: status}
	if env.Error != nil {
		p := env.Error
		e.Code, e.Message, e.Param, e.Reason = p.Code, p.Message, p.Param, p.Reason
		e.RetryAfter = p.RetryAfter
		e.BalanceMicroUSD, e.RequiredMicroUSD, e.TopUpURL = p.BalanceMicroUSD, p.RequiredMicroUSD, p.TopUpURL
		e.SendAfter, e.RecipientLocalTime, e.Timezone, e.MessageID = p.SendAfter, p.RecipientLocalTime, p.Timezone, p.MessageID
	}
	if e.Message == "" {
		e.Message = fmt.Sprintf("Request failed with status %d", status)
	}
	if e.Code == "" {
		if status >= 500 {
			e.Code = CodeInternalError
		} else {
			e.Code = CodeInvalidRequest
		}
	}
	if e.RetryAfter == nil {
		if h := header.Get("Retry-After"); h != "" {
			if f, err := strconv.ParseFloat(h, 64); err == nil {
				e.RetryAfter = &f
			}
		}
	}
	return e
}
