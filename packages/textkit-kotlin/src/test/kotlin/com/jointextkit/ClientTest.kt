package com.jointextkit

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import java.io.IOException
import java.net.http.HttpTimeoutException
import java.time.Instant

const val KEY = "ssms_sk_test_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const val MSG = """{"id":"msg_1","object":"message","to":"+15005550006","from":"+15005550100","body":"hi","status":"queued"}"""
const val EMPTY_PAGE = """{"data":[],"has_more":false,"next_cursor":null}"""

fun err(code: String, message: String = "nope", extra: String = "") =
    """{"error":{"code":"$code","message":"$message"${if (extra.isEmpty()) "" else ",$extra"}}}"""

fun j(text: String): JsonElement = Json.parseToJsonElement(text)

/** A client pointed at [server], with sleeps recorded instead of slept and no environment. */
fun stubClient(
    server: StubServer,
    env: Map<String, String> = emptyMap(),
    configure: TextKit.Builder.() -> Unit = {},
): Pair<TextKit, MutableList<Long>> {
    val sleeps = mutableListOf<Long>()
    val builder = TextKit.builder().apiKey(KEY).baseUrl(server.baseUrl)
    builder.sleeper = { sleeps.add(it) }
    builder.env = { env[it] }
    builder.configure()
    return builder.build() to sleeps
}

class ConstructionTest {
    private fun build(env: Map<String, String>, configure: TextKit.Builder.() -> Unit = {}): TextKit {
        val b = TextKit.builder()
        b.env = { env[it] }
        b.configure()
        return b.build()
    }

    @Test fun readsKeyAndBaseUrlFromEnv() {
        val c = build(mapOf("TEXTKIT_API_KEY" to KEY, "TEXTKIT_BASE_URL" to "http://localhost:3000/"))
        assertTrue(c.isTestMode)
        assertEquals("http://localhost:3000/v1", c.baseUrl)
    }

    @Test fun defaultBaseUrlIsTheV1Host() {
        assertEquals("https://api.jointextkit.com/v1", build(mapOf("TEXTKIT_API_KEY" to KEY)).baseUrl)
        assertEquals("https://api.test/v1", build(emptyMap()) { apiKey(KEY).baseUrl("https://api.test/v1/") }.baseUrl)
    }

    @Test fun missingKeyThrows() {
        val e = assertThrows<TextKitException> { build(emptyMap()) }
        assertEquals("invalid_api_key", e.code)
        assertEquals(0, e.status)
    }

    @Test fun keyPrefixesSetTestMode() {
        for (prefix in listOf("ssms", "dsms", "resms")) {
            assertTrue(build(emptyMap()) { apiKey("${prefix}_sk_test_x") }.isTestMode, prefix)
            assertFalse(build(emptyMap()) { apiKey("${prefix}_sk_live_x") }.isTestMode, prefix)
        }
    }

    @Test fun explicitKeyBeatsEnv() {
        assertFalse(build(mapOf("TEXTKIT_API_KEY" to KEY)) { apiKey("ssms_sk_live_x") }.isTestMode)
    }
}

class RequestTest {
    private val server = StubServer()

    @AfterEach fun stop() = server.close()

    @Test fun sendShapeAuthAndIdempotency() {
        server.reply(201, MSG)
        val (c, _) = stubClient(server)
        val out = c.messages.send("+15005550006", "hi", from = "+15005550100")
        assertEquals("msg_1", out.id)
        assertEquals("message", out.objectType)
        val call = server.calls[0]
        assertEquals("POST", call.method)
        assertEquals("/messages", call.path)
        assertEquals(j("""{"to":"+15005550006","body":"hi","from":"+15005550100"}"""), call.json)
        assertEquals("Bearer $KEY", call.headers["authorization"])
        assertTrue(call.headers["idempotency-key"]!!.startsWith("sdk_"))
        assertEquals("jointextkit-kotlin/${TextKit.VERSION}", call.headers["user-agent"])
        assertEquals("application/json", call.headers["content-type"])
    }

    @Test fun sendWithEveryOption() {
        server.reply(201, MSG)
        val (c, _) = stubClient(server)
        c.messages.send(
            SendMessageParams("+15005550006", "hi")
                .from("+15005550100")
                .customerId("cus_x")
                .category("marketing")
                .quietHours("defer")
                .consent(mapOf("source" to "checkout", "collected_at" to "2026-10-01T00:00:00Z"))
                .media(listOf("https://example.com/a.png"))
                .idempotencyKey("order:1"),
        )
        val call = server.calls[0]
        assertEquals(
            j(
                """{"to":"+15005550006","body":"hi","from":"+15005550100","customer_id":"cus_x","category":"marketing",
                "quiet_hours":"defer","consent":{"source":"checkout","collected_at":"2026-10-01T00:00:00Z"},
                "media":["https://example.com/a.png"]}""",
            ),
            call.json,
        )
        assertEquals("order:1", call.headers["idempotency-key"])
    }

    @Test fun deferredSendDecodesAsScheduled() {
        server.reply(202, """{"id":"job_1","object":"scheduled_message","to":"+15005550006","body":"hi","scheduled_at":"2026-10-02T12:00:00Z","status":"queued"}""")
        val (c, _) = stubClient(server)
        val m = c.messages.send("+15005550006", "hi", "+15005550100")
        assertEquals("scheduled_message", m.objectType)
        assertEquals("2026-10-02T12:00:00Z", m.scheduledAt)
    }

    @Test fun retries5xxWithTheSameIdempotencyKey() {
        server.reply(502, err("carrier_error")).reply(201, MSG)
        val (c, sleeps) = stubClient(server)
        c.messages.send("+15005550006", "hi", "+15005550100")
        assertEquals(2, server.calls.size)
        assertEquals(server.calls[0].headers["idempotency-key"], server.calls[1].headers["idempotency-key"])
        assertEquals(1, sleeps.size)
        assertTrue(sleeps[0] in 500L..625L, "backoff ${sleeps[0]}")
    }

    @Test fun honorsRetryAfterHeader() {
        server.reply(429, err("rate_limited"), mapOf("Retry-After" to "7")).ok(EMPTY_PAGE)
        val (c, sleeps) = stubClient(server)
        c.messages.list()
        assertEquals(listOf(7000L), sleeps)
    }

    @Test fun honorsRetryAfterInBody() {
        server.reply(429, err("rate_limited", extra = "\"retry_after\":3")).ok(MSG)
        val (c, sleeps) = stubClient(server)
        c.messages.get("msg_1")
        assertEquals(listOf(3000L), sleeps)
    }

    @Test fun givesUpAfterMaxRetries() {
        repeat(3) { server.reply(503, err("internal_error")) }
        val (c, sleeps) = stubClient(server) { maxRetries(2) }
        val e = assertThrows<TextKitException> { c.messages.get("msg_1") }
        assertEquals(503, e.status)
        assertEquals(3, server.calls.size)
        assertEquals(2, sleeps.size)
    }

    @Test fun fourHundredsAreNotRetriedAndTheEnvelopeIsParsed() {
        server.reply(400, err("invalid_request", "`to` is bad", "\"param\":\"to\""))
        val (c, _) = stubClient(server)
        val e = assertThrows<TextKitException> { c.messages.send("nope", "hi", "+15005550100") }
        assertEquals("invalid_request", e.code)
        assertEquals(400, e.status)
        assertEquals("to", e.param)
        assertEquals("`to` is bad", e.message)
        assertFalse(e.isRetryable)
        assertEquals(1, server.calls.size)
    }

    @Test fun insufficientCreditsAndQuietHoursFields() {
        server.reply(
            402,
            err(
                "insufficient_credits", "Add credits",
                "\"balance_micro_usd\":1000,\"required_micro_usd\":8000,\"top_up_url\":\"https://jointextkit.com/console/billing\"",
            ),
        )
        server.reply(
            403,
            err(
                "quiet_hours", "Too late",
                "\"send_after\":\"2026-10-02T12:00:00Z\",\"recipient_local_time\":\"22:10\",\"timezone\":\"America/New_York\",\"message_id\":\"msg_9\"",
            ),
        )
        val (c, _) = stubClient(server)
        val credits = assertThrows<TextKitException> { c.messages.send("+15005550006", "hi", "+15005550100") }
        assertEquals(1000L, credits.balanceMicroUsd)
        assertEquals(8000L, credits.requiredMicroUsd)
        assertEquals("https://jointextkit.com/console/billing", credits.topUpUrl)
        val quiet = assertThrows<TextKitException> { c.messages.send("+15005550006", "hi", "+15005550100") }
        assertEquals("2026-10-02T12:00:00Z", quiet.sendAfter)
        assertEquals("22:10", quiet.recipientLocalTime)
        assertEquals("America/New_York", quiet.timezone)
        assertEquals("msg_9", quiet.messageId)
    }

    @Test fun nonJsonErrorBody() {
        server.reply(500, "<html>bad gateway</html>")
        val (c, _) = stubClient(server) { maxRetries(0) }
        val e = assertThrows<TextKitException> { c.messages.get("msg_1") }
        assertEquals("internal_error", e.code)
        assertEquals("Request failed with status 500", e.message)
    }

    @Test fun defaultFromIsLookedUpOnce() {
        server.ok("""{"data":[{"id":"num_1","phone_number":"+15005550100","status":"active"}],"has_more":false}""")
        server.reply(201, MSG).reply(201, MSG)
        val (c, _) = stubClient(server)
        c.messages.send("+15005550006", "a")
        c.messages.send("+15005550006", "b")
        assertEquals(1, server.calls.count { it.path == "/numbers" })
        assertEquals(j("\"+15005550100\""), (server.calls[2].json as kotlinx.serialization.json.JsonObject)["from"])
    }

    @Test fun defaultFromRefusesToGuess() {
        server.ok(
            """{"data":[{"id":"n1","phone_number":"+15005550100","status":"active"},
            {"id":"n2","phone_number":"+15005550101","status":"active"}],"has_more":false}""",
        )
        val (c, _) = stubClient(server)
        val e = assertThrows<TextKitException> { c.messages.send("+15005550006", "a") }
        assertEquals("from", e.param)
    }

    @Test fun defaultFromFromEnv() {
        server.reply(201, MSG)
        val (c, _) = stubClient(server, env = mapOf("TEXTKIT_FROM" to "+15005550199"))
        c.messages.send("+15005550006", "a")
        assertEquals(1, server.calls.size)
        assertEquals(j("\"+15005550199\""), (server.calls[0].json as kotlinx.serialization.json.JsonObject)["from"])
    }

    @Test fun listAllFollowsCursors() {
        server.ok("""{"data":[{"id":"m3"},{"id":"m2"}],"has_more":true,"next_cursor":"k2"}""")
        server.ok("""{"data":[{"id":"m1"}],"has_more":false,"next_cursor":null}""")
        val (c, _) = stubClient(server)
        val ids = c.messages.listAll(ListMessagesParams().limit(2).customerId("cus_x")).map { it.id }
        assertEquals(listOf("m3", "m2", "m1"), ids)
        assertEquals("/messages?limit=2&customer_id=cus_x", server.calls[0].path)
        assertEquals("/messages?limit=2&customer_id=cus_x&cursor=k2", server.calls[1].path)
    }

    @Test fun listAllIsLazy() {
        server.ok("""{"data":[{"id":"m3"}],"has_more":true,"next_cursor":"k2"}""")
        val (c, _) = stubClient(server)
        val first = c.messages.listAll().iterator().next()
        assertEquals("m3", first.id)
        assertEquals(1, server.calls.size)
    }

    @Test fun scheduleSerializesInstantAsUtc() {
        server.reply(201, """{"id":"job_1","object":"scheduled_message","scheduled_at":"2026-10-02T09:30:00Z","status":"queued"}""")
        val (c, _) = stubClient(server) { defaultFrom("+15005550100") }
        val job = c.messages.schedule("+15005550006", "later", Instant.parse("2026-10-02T09:30:00Z"))
        assertEquals("job_1", job.id)
        assertEquals(
            j("""{"to":"+15005550006","body":"later","scheduled_at":"2026-10-02T09:30:00Z","from":"+15005550100"}"""),
            server.calls[0].json,
        )
        assertNull(server.calls[0].headers["idempotency-key"])
    }

    @Test fun rawRequestEscapeHatch() {
        server.ok("""{"data":[{"id":"bat_1"}],"has_more":false}""")
        server.reply(201, """{"id":"tpl_1"}""")
        val (c, _) = stubClient(server)
        val page = c.request("GET", "/batches")
        assertEquals(j("""{"data":[{"id":"bat_1"}],"has_more":false}"""), page)
        c.request("post", "/templates", mapOf("name" to "Welcome", "body" to "Hi"), "tpl:1")
        assertEquals("POST", server.calls[1].method)
        assertEquals(j("""{"name":"Welcome","body":"Hi"}"""), server.calls[1].json)
        assertEquals("tpl:1", server.calls[1].headers["idempotency-key"])
    }
}

/** Network failures come from the transport; a scripted one stands in for a dropped connection. */
class ConnectionTest {
    private class ScriptedTransport(vararg steps: Any) : Transport {
        val steps = ArrayDeque(steps.toList())
        var calls = 0

        override fun execute(request: TransportRequest): TransportResponse {
            calls++
            return when (val step = steps.removeFirst()) {
                is IOException -> throw step
                is TransportResponse -> step
                else -> error("bad step")
            }
        }
    }

    private fun client(t: Transport): TextKit {
        val b = TextKit.builder().apiKey(KEY).transport(t)
        b.sleeper = {}
        b.env = { null }
        return b.build()
    }

    @Test fun connectionErrorsAreRetriedForGets() {
        val t = ScriptedTransport(
            HttpTimeoutException("slow"),
            IOException("reset"),
            TransportResponse(200, emptyMap(), MSG.toByteArray()),
        )
        assertEquals("msg_1", client(t).messages.get("msg_1").id)
        assertEquals(3, t.calls)
    }

    @Test fun connectionErrorSurfaces() {
        val t = ScriptedTransport(IOException("down"), IOException("down"), IOException("down"))
        val e = assertThrows<TextKitException> { client(t).messages.get("msg_1") }
        assertEquals("connection_error", e.code)
        assertEquals(0, e.status)
        assertTrue(e.isRetryable)
        assertTrue(e.cause is IOException)
    }

    @Test fun postWithoutIdempotencyKeyIsNeverResent() {
        val t = ScriptedTransport(IOException("reset"))
        assertThrows<TextKitException> { client(t).verify.send("+14155550132") }
        assertEquals(1, t.calls)
    }

    @Test fun realTransportReportsAnUnreachableHost() {
        val b = TextKit.builder().apiKey(KEY).baseUrl("http://127.0.0.1:1").maxRetries(0)
        b.env = { null }
        val e = assertThrows<TextKitException> { b.build().balance.get() }
        assertEquals("connection_error", e.code)
    }
}
