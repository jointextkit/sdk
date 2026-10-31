package textkit

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
)

// VerifyWebhook against signatures produced by the server's own signer.
// testdata/webhook_vectors.json is a copy of
// packages/textkit-python/tests/fixtures/webhook_vectors.json, generated
// from src/lib/api/webhook-signature.ts (npx tsx scripts/qa/webhook-vectors.ts).

type vector struct {
	Payload   string `json:"payload"`
	Timestamp int64  `json:"timestamp"`
	Signature string `json:"signature"`
}

func loadVectors(t *testing.T) (string, []vector) {
	t.Helper()
	raw, err := os.ReadFile("testdata/webhook_vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Secret  string   `json:"secret"`
		Vectors []vector `json:"vectors"`
	}
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	if len(f.Vectors) == 0 {
		t.Fatal("no vectors")
	}
	return f.Secret, f.Vectors
}

func at(ts int64) VerifyOption { return WithNow(time.Unix(ts, 0)) }

func assertInvalid(t *testing.T, err error, contains string) {
	t.Helper()
	e := asError(t, err)
	if e.Code != CodeInvalidSignature || !strings.Contains(e.Message, contains) {
		t.Fatalf("want invalid_signature %q, got %v", contains, e)
	}
}

func TestServerVectorsVerify(t *testing.T) {
	secret, vectors := loadVectors(t)
	for _, v := range vectors {
		event, err := VerifyWebhook([]byte(v.Payload), v.Signature, secret, at(v.Timestamp))
		if err != nil {
			t.Fatal(err)
		}
		var want Event
		_ = json.Unmarshal([]byte(v.Payload), &want)
		if !reflect.DeepEqual(*event, want) || !strings.HasPrefix(event.ID, "evt_") {
			t.Fatal(event)
		}
	}
	// Through the client namespace too.
	c, _ := NewClient(testKey)
	if e, err := c.Webhooks.Verify([]byte(vectors[0].Payload), vectors[0].Signature, secret, at(vectors[0].Timestamp)); err != nil || e.ID != "evt_a1B2c3D4e5F6g7H8" {
		t.Fatal(e, err)
	}
}

func TestUnicodeBodyVerifiesByteForByte(t *testing.T) {
	secret, vectors := loadVectors(t)
	v := vectors[1]
	event, err := VerifyWebhook([]byte(v.Payload), v.Signature, secret, at(v.Timestamp))
	if err != nil || !strings.Contains(event.Data["body"].(string), "☕") {
		t.Fatal(event, err)
	}
	// Re-encoding the JSON changes the bytes (key order, escapes): it must fail.
	var m map[string]any
	_ = json.Unmarshal([]byte(v.Payload), &m)
	reencoded, _ := json.Marshal(m)
	_, err = VerifyWebhook(reencoded, v.Signature, secret, at(v.Timestamp))
	assertInvalid(t, err, "does not match")
}

func TestAnyHeaderNameVerifies(t *testing.T) {
	secret, vectors := loadVectors(t)
	v := vectors[0]
	for _, name := range []string{"textkit-signature", "dsms-signature", "resms-signature", "TextKit-Signature", "Dsms-Signature"} {
		h := http.Header{}
		h.Set(name, v.Signature)
		h.Set("content-type", "application/json")
		if e, err := VerifyWebhookRequest([]byte(v.Payload), h, secret, at(v.Timestamp)); err != nil || e.ID != "evt_a1B2c3D4e5F6g7H8" {
			t.Fatal(name, err)
		}
	}
	// A hand-built map with non-canonical keys.
	if _, err := VerifyWebhookRequest([]byte(v.Payload), http.Header{"textkit-signature": {v.Signature}}, secret, at(v.Timestamp)); err != nil {
		t.Fatal(err)
	}
	_, err := VerifyWebhookRequest([]byte(v.Payload), http.Header{"X-Other": {"1"}}, secret, at(v.Timestamp))
	assertInvalid(t, err, "Missing")
}

func TestHeaderHelpers(t *testing.T) {
	h := http.Header{}
	h.Set("dsms-signature", "t=1,v1=aa")
	if SignatureFromHeaders(h) != "t=1,v1=aa" {
		t.Fatal()
	}
	h.Set("textkit-signature", "new")
	if SignatureFromHeaders(h) != "new" {
		t.Fatal()
	}
	if EventIDFromHeaders(http.Header{"Resms-Event-Id": {"evt_1"}}) != "evt_1" || EventIDFromHeaders(http.Header{}) != "" {
		t.Fatal()
	}
}

func TestTamperedPayloadAndWrongSecret(t *testing.T) {
	secret, vectors := loadVectors(t)
	v := vectors[0]
	_, err := VerifyWebhook([]byte(strings.Replace(v.Payload, "0006", "0007", 1)), v.Signature, secret, at(v.Timestamp))
	assertInvalid(t, err, "does not match")
	_, err = VerifyWebhook([]byte(v.Payload), v.Signature, "whsec_other", at(v.Timestamp))
	assertInvalid(t, err, "does not match")
}

func TestToleranceBothDirections(t *testing.T) {
	secret, vectors := loadVectors(t)
	v := vectors[0]
	p := []byte(v.Payload)
	if _, err := VerifyWebhook(p, v.Signature, secret, at(v.Timestamp+300)); err != nil {
		t.Fatal(err)
	}
	_, err := VerifyWebhook(p, v.Signature, secret, at(v.Timestamp+301))
	assertInvalid(t, err, "tolerance")
	_, err = VerifyWebhook(p, v.Signature, secret, at(v.Timestamp-301))
	assertInvalid(t, err, "tolerance")
	if _, err := VerifyWebhook(p, v.Signature, secret, at(v.Timestamp+10000), WithTolerance(0)); err != nil {
		t.Fatal(err)
	}
	// Real clock: the 2026 vector is far outside 5 minutes.
	_, err = VerifyWebhook(p, v.Signature, secret)
	assertInvalid(t, err, "tolerance")
}

func TestForgedTimestamp(t *testing.T) {
	secret, vectors := loadVectors(t)
	v := vectors[0]
	sig := strings.SplitN(v.Signature, "v1=", 2)[1]
	forged := fmt.Sprintf("t=%d,v1=%s", v.Timestamp+5, sig)
	_, err := VerifyWebhook([]byte(v.Payload), forged, secret, at(v.Timestamp+5))
	assertInvalid(t, err, "does not match")
}

func TestRotationAnyV1Matches(t *testing.T) {
	secret, vectors := loadVectors(t)
	v := vectors[0]
	mac := hmac.New(sha256.New, []byte(secret))
	fmt.Fprintf(mac, "%d.%s", v.Timestamp, v.Payload)
	good := hex.EncodeToString(mac.Sum(nil))
	header := fmt.Sprintf("t=%d,v1=%s,v1=%s", v.Timestamp, strings.Repeat("0", 64), strings.ToUpper(good))
	if _, err := VerifyWebhook([]byte(v.Payload), header, secret, at(v.Timestamp)); err != nil {
		t.Fatal(err)
	}
}

func TestMissingAndMalformed(t *testing.T) {
	secret, vectors := loadVectors(t)
	v := vectors[0]
	p := []byte(v.Payload)
	_, err := VerifyWebhook(p, "", secret)
	assertInvalid(t, err, "Missing")
	for _, bad := range []string{"v1=abc", fmt.Sprintf("t=%d", v.Timestamp), "garbage", "t=-1,v1=aa", "t=12a,v1=aa"} {
		_, err = VerifyWebhook(p, bad, secret)
		assertInvalid(t, err, "Malformed")
	}
	_, err = VerifyWebhook(p, v.Signature, "")
	assertInvalid(t, err, "secret")
	if asError(t, err).Status != 400 {
		t.Fatal("status")
	}
}
