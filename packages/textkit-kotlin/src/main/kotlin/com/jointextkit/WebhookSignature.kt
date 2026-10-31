package com.jointextkit

import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Webhook signature verification.
 *
 * Every webhook carries `textkit-signature: t=<unix seconds>,v1=<hex>` where
 * `v1 = HMAC-SHA256(secret, "<t>.<raw body>")`. Verify against the raw request
 * body exactly as received; re-serialized JSON will not match.
 *
 * The same value is also sent as `dsms-signature` and `resms-signature` (older
 * header names), so passing the whole headers map finds it under any of them.
 */
object WebhookSignature {
    const val DEFAULT_TOLERANCE_SECONDS = 300L

    /** Every header name the signature has been sent under, current first. */
    @JvmField val SIGNATURE_HEADERS = listOf("textkit-signature", "dsms-signature", "resms-signature")

    /** Every header name the event id has been sent under, current first. */
    @JvmField val EVENT_ID_HEADERS = listOf("textkit-event-id", "dsms-event-id", "resms-event-id")

    /**
     * The signature from a request's headers, whichever name it arrived under,
     * matched case-insensitively. Values may be strings or lists of strings
     * (as Spring's `HttpHeaders` and the Servlet API give them).
     */
    @JvmStatic fun signatureFromHeaders(headers: Map<String, *>?): String? = header(headers, SIGNATURE_HEADERS)

    /** The event id (`evt_...`, stable across retries) from a request's headers. */
    @JvmStatic fun eventIdFromHeaders(headers: Map<String, *>?): String? = header(headers, EVENT_ID_HEADERS)

    /**
     * Verify a webhook and return the parsed event.
     *
     * @param payload the raw request body bytes.
     * @param signature the `textkit-signature` header value.
     * @param secret your endpoint's signing secret (`whsec_...`).
     * @param toleranceSeconds max age, either direction; 0 disables the check. 300 stops replays of captured requests.
     * @param now the current Unix time in seconds (tests); defaults to the clock.
     * @throws TextKitException with code `invalid_signature`.
     */
    @JvmStatic @JvmOverloads
    fun verify(
        payload: ByteArray,
        signature: String?,
        secret: String,
        toleranceSeconds: Long = DEFAULT_TOLERANCE_SECONDS,
        now: Long? = null,
    ): Event {
        if (secret.isEmpty()) throw fail("No webhook secret given.")
        if (signature.isNullOrEmpty()) throw fail("Missing textkit-signature header.")

        var timestamp: Long? = null
        val candidates = mutableListOf<String>()
        for (part in signature.split(",")) {
            val eq = part.indexOf('=')
            if (eq < 0) continue
            val key = part.substring(0, eq).trim()
            val value = part.substring(eq + 1).trim()
            if (key == "t" && value.isNotEmpty() && value.all { it in '0'..'9' }) {
                timestamp = value.toLongOrNull()
            } else if (key == "v1") {
                candidates.add(value.lowercase())
            }
        }
        val t = timestamp
        if (t == null || candidates.isEmpty()) throw fail("Malformed textkit-signature header.")

        val current = now ?: (System.currentTimeMillis() / 1000)
        if (toleranceSeconds > 0 && kotlin.math.abs(current - t) > toleranceSeconds) {
            throw fail("Webhook timestamp is outside the tolerance window.")
        }

        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(secret.toByteArray(Charsets.UTF_8), "HmacSHA256"))
        mac.update("$t.".toByteArray(Charsets.US_ASCII))
        val expected = hex(mac.doFinal(payload)).toByteArray(Charsets.US_ASCII)
        // Constant-time comparison against every v1 (more than one during a secret rotation).
        val matched = candidates.fold(false) { ok, c -> MessageDigest.isEqual(expected, c.toByteArray(Charsets.US_ASCII)) || ok }
        if (!matched) throw fail("Webhook signature does not match.")

        return try {
            json.decodeFromString(Event.serializer(), String(payload, Charsets.UTF_8))
        } catch (e: Exception) {
            throw TextKitException("Webhook body is not a TextKit event.", code = "invalid_signature", status = 400, cause = e)
        }
    }

    /** [verify] with the body as a string (UTF-8). */
    @JvmStatic @JvmOverloads
    fun verify(
        payload: String,
        signature: String?,
        secret: String,
        toleranceSeconds: Long = DEFAULT_TOLERANCE_SECONDS,
        now: Long? = null,
    ): Event = verify(payload.toByteArray(Charsets.UTF_8), signature, secret, toleranceSeconds, now)

    /** [verify] reading the signature from the request's headers map. */
    @JvmStatic @JvmOverloads
    fun verify(
        payload: ByteArray,
        headers: Map<String, *>,
        secret: String,
        toleranceSeconds: Long = DEFAULT_TOLERANCE_SECONDS,
        now: Long? = null,
    ): Event = verify(payload, signatureFromHeaders(headers), secret, toleranceSeconds, now)

    /** [verify] with a string body, reading the signature from the request's headers map. */
    @JvmStatic @JvmOverloads
    fun verify(
        payload: String,
        headers: Map<String, *>,
        secret: String,
        toleranceSeconds: Long = DEFAULT_TOLERANCE_SECONDS,
        now: Long? = null,
    ): Event = verify(payload.toByteArray(Charsets.UTF_8), signatureFromHeaders(headers), secret, toleranceSeconds, now)

    private fun fail(message: String) = TextKitException(message, code = "invalid_signature", status = 400)

    private fun hex(bytes: ByteArray): String {
        val digits = "0123456789abcdef"
        val out = StringBuilder(bytes.size * 2)
        for (b in bytes) {
            val v = b.toInt() and 0xff
            out.append(digits[v ushr 4]).append(digits[v and 0x0f])
        }
        return out.toString()
    }

    private fun header(headers: Map<String, *>?, names: List<String>): String? {
        if (headers == null) return null
        val lowered = HashMap<String, Any?>()
        for ((k, v) in headers) {
            @Suppress("SENSELESS_COMPARISON")
            if (k != null) lowered.putIfAbsent(k.lowercase(), v)
        }
        for (name in names) {
            val value = when (val v = lowered[name]) {
                is String -> v
                is Iterable<*> -> v.firstOrNull()?.toString()
                is Array<*> -> v.firstOrNull()?.toString()
                null -> null
                else -> v.toString()
            }
            if (!value.isNullOrEmpty()) return value
        }
        return null
    }
}
