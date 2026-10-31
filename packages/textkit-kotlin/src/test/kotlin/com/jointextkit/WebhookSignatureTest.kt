package com.jointextkit

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Verification against signatures produced by the server's own signer.
 * `webhook_vectors.json` is a copy of packages/textkit-python/tests/fixtures/webhook_vectors.json
 * (generated from src/lib/api/webhook-signature.ts); the repo's Node suite fails if it drifts.
 */
class WebhookSignatureTest {
    private class Vector(val payload: String, val timestamp: Long, val signature: String)

    private val fixture = Json.parseToJsonElement(
        javaClass.getResource("/webhook_vectors.json")!!.readText(Charsets.UTF_8),
    ).jsonObject
    private val secret = fixture["secret"]!!.jsonPrimitive.content
    private val vectors = fixture["vectors"]!!.jsonArray.map {
        val o = it.jsonObject
        Vector(o["payload"]!!.jsonPrimitive.content, o["timestamp"]!!.jsonPrimitive.long, o["signature"]!!.jsonPrimitive.content)
    }

    private fun invalid(pattern: String, block: () -> Unit) {
        val e = assertThrows<TextKitException> { block() }
        assertEquals("invalid_signature", e.code)
        assertTrue(Regex(pattern).containsMatchIn(e.message!!), "'${e.message}' should match $pattern")
    }

    @Test fun serverVectorsVerifyAsStringAndBytes() {
        assertEquals(2, vectors.size)
        for (v in vectors) {
            val event = WebhookSignature.verify(v.payload, v.signature, secret, now = v.timestamp)
            val parsed = Json.parseToJsonElement(v.payload).jsonObject
            assertEquals(parsed["id"]!!.jsonPrimitive.content, event.id)
            assertEquals(parsed["type"]!!.jsonPrimitive.content, event.type)
            assertEquals(parsed["data"] as JsonObject, event.data)
            val fromBytes = WebhookSignature.verify(v.payload.toByteArray(Charsets.UTF_8), v.signature, secret, now = v.timestamp)
            assertEquals(event, fromBytes)
        }
        // The second vector carries non-ASCII text; it must survive byte-for-byte.
        val received = WebhookSignature.verify(vectors[1].payload, vectors[1].signature, secret, now = vectors[1].timestamp)
        assertEquals("Café ☕ – ok? 👍", received.data!!["body"]!!.jsonPrimitive.content)
    }

    @Test fun anyHeaderNameVerifies() {
        val v = vectors[0]
        for (name in listOf("textkit-signature", "dsms-signature", "resms-signature", "TextKit-Signature", "Dsms-Signature")) {
            val event = WebhookSignature.verify(v.payload, mapOf(name to v.signature, "content-type" to "application/json"), secret, now = v.timestamp)
            assertEquals("evt_a1B2c3D4e5F6g7H8", event.id, name)
        }
        // Multi-valued header maps (Spring, Servlet) work too.
        val event = WebhookSignature.verify(v.payload, mapOf("Textkit-Signature" to listOf(v.signature)), secret, now = v.timestamp)
        assertEquals("evt_a1B2c3D4e5F6g7H8", event.id)
        invalid("Missing") { WebhookSignature.verify(v.payload, mapOf("x-other" to "1"), secret, now = v.timestamp) }
    }

    @Test fun headerHelpers() {
        assertEquals("t=1,v1=aa", WebhookSignature.signatureFromHeaders(mapOf("dsms-signature" to "t=1,v1=aa")))
        assertEquals("new", WebhookSignature.signatureFromHeaders(mapOf("textkit-signature" to "new", "dsms-signature" to "old")))
        assertEquals("evt_1", WebhookSignature.eventIdFromHeaders(mapOf("Resms-Event-Id" to "evt_1")))
        assertNull(WebhookSignature.eventIdFromHeaders(emptyMap<String, String>()))
    }

    @Test fun tamperedPayload() {
        val v = vectors[0]
        invalid("does not match") { WebhookSignature.verify(v.payload.replace("0006", "0007"), v.signature, secret, now = v.timestamp) }
    }

    @Test fun reserializedJsonFails() {
        // Re-encoding with escaped non-ASCII changes the bytes, so the signature no longer matches.
        val v = vectors[1]
        val reserialized = v.payload.replace("é", "\\u00e9")
        invalid("does not match") { WebhookSignature.verify(reserialized, v.signature, secret, now = v.timestamp) }
    }

    @Test fun wrongSecret() {
        val v = vectors[0]
        invalid("does not match") { WebhookSignature.verify(v.payload, v.signature, "whsec_other", now = v.timestamp) }
    }

    @Test fun toleranceBothDirections() {
        val v = vectors[0]
        val t = v.timestamp
        WebhookSignature.verify(v.payload, v.signature, secret, now = t + 300)
        invalid("tolerance") { WebhookSignature.verify(v.payload, v.signature, secret, now = t + 301) }
        invalid("tolerance") { WebhookSignature.verify(v.payload, v.signature, secret, now = t - 301) }
        WebhookSignature.verify(v.payload, v.signature, secret, toleranceSeconds = 0, now = t + 10_000)
        invalid("tolerance") { WebhookSignature.verify(v.payload, v.signature, secret, toleranceSeconds = 1, now = t + 2) }
    }

    @Test fun forgedTimestamp() {
        val v = vectors[0]
        val sig = v.signature.substringAfter("v1=")
        invalid("does not match") { WebhookSignature.verify(v.payload, "t=${v.timestamp + 5},v1=$sig", secret, now = v.timestamp + 5) }
    }

    @Test fun rotationAnyV1Matches() {
        val v = vectors[0]
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(secret.toByteArray(), "HmacSHA256")) }
        val good = mac.doFinal("${v.timestamp}.${v.payload}".toByteArray()).joinToString("") { "%02x".format(it) }
        WebhookSignature.verify(v.payload, "t=${v.timestamp},v1=${"0".repeat(64)},v1=$good", secret, now = v.timestamp)
        // Uppercase hex is accepted too.
        WebhookSignature.verify(v.payload, "t=${v.timestamp},v1=${good.uppercase()}", secret, now = v.timestamp)
    }

    @Test fun missingAndMalformed() {
        val v = vectors[0]
        invalid("Missing") { WebhookSignature.verify(v.payload, null as String?, secret) }
        invalid("Malformed") { WebhookSignature.verify(v.payload, "v1=abc", secret) }
        invalid("Malformed") { WebhookSignature.verify(v.payload, "t=${v.timestamp}", secret) }
        invalid("Malformed") { WebhookSignature.verify(v.payload, "garbage", secret) }
        invalid("Malformed") { WebhookSignature.verify(v.payload, "t=-5,v1=abc", secret) }
        invalid("secret") { WebhookSignature.verify(v.payload, v.signature, "") }
    }
}
