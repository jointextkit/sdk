package com.jointextkit

import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import java.io.IOException
import java.net.http.HttpTimeoutException
import java.time.Duration
import java.util.UUID
import java.util.concurrent.ThreadLocalRandom
import kotlin.math.min
import kotlin.math.pow

/**
 * The TextKit client. Thread-safe: create one and share it.
 *
 * ```kotlin
 * val client = TextKit()                       // reads TEXTKIT_API_KEY
 * client.messages.send("+15005550006", "Hello from TextKit")
 * ```
 *
 * ```java
 * TextKit client = new TextKit();            // reads TEXTKIT_API_KEY
 * client.messages().send("+15005550006", "Hello from TextKit");
 * ```
 *
 * Use [builder] for the other options.
 */
class TextKit private constructor(
    apiKey: String?,
    defaultFrom: String?,
    baseUrl: String?,
    /** Retries for transient failures (429, 5xx, network). */
    val maxRetries: Int,
    /** Per-request timeout. */
    val timeout: Duration,
    transport: Transport?,
    internal val sleeper: (Long) -> Unit,
    env: (String) -> String?,
) {
    /** Reads the key from `TEXTKIT_API_KEY` when [apiKey] is null. */
    @JvmOverloads
    constructor(apiKey: String? = null) : this(
        apiKey, null, null, 2, Duration.ofSeconds(30), null, ::defaultSleep, System::getenv,
    )

    // The SIMPLESMS_ names are from before the 2026-10-28 rename; read when the TEXTKIT_ one is unset.
    private val apiKey: String = apiKey?.takeIf { it.isNotEmpty() } ?: env("TEXTKIT_API_KEY")?.takeIf { it.isNotEmpty() }
        ?: env("SIMPLESMS_API_KEY")?.takeIf { it.isNotEmpty() }
        ?: throw TextKitException(
            "No TextKit key. Pass one to TextKit(...) or set TEXTKIT_API_KEY. Get one free at https://jointextkit.com/console",
            code = "invalid_api_key",
            status = 0,
        )

    /** Where requests go, ending in `/v1`. */
    val baseUrl: String = normalizeBaseUrl(baseUrl ?: env("TEXTKIT_BASE_URL")?.takeIf { it.isNotEmpty() }
        ?: env("SIMPLESMS_BASE_URL")?.takeIf { it.isNotEmpty() } ?: DEFAULT_BASE_URL)

    private val transport: Transport = transport ?: JavaHttpTransport()

    @Volatile
    private var defaultFrom: String? = defaultFrom ?: env("TEXTKIT_FROM")?.takeIf { it.isNotEmpty() } ?: env("SIMPLESMS_FROM")?.takeIf { it.isNotEmpty() }
    private val fromLock = Any()

    /** True when this client is using a sandbox (test) key. */
    val isTestMode: Boolean
        get() = TEST_KEY_PREFIXES.any { apiKey.startsWith(it) }

    @get:JvmName("messages") val messages = Messages(this)
    @get:JvmName("verify") val verify = Verify(this)
    @get:JvmName("numbers") val numbers = Numbers(this)
    @get:JvmName("balance") val balance = BalanceResource(this)
    @get:JvmName("lookup") val lookup = LookupResource(this)
    @get:JvmName("links") val links = Links(this)
    @get:JvmName("conversions") val conversions = Conversions(this)
    @get:JvmName("events") val events = Events(this)
    @get:JvmName("webhooks") val webhooks = Webhooks(this)
    @get:JvmName("consent") val consent = Consent(this)
    @get:JvmName("customers") val customers = Customers(this)
    @get:JvmName("contacts") val contacts = Contacts(this)
    @get:JvmName("automations") val automations = Automations(this)
    @get:JvmName("schedules") val schedules = Schedules(this)
    @get:JvmName("registrations") val registrations = Registrations(this)

    /**
     * Call any endpoint this SDK has no method for yet. [path] is relative to
     * `/v1` (e.g. `"/batches"`); [body] is a map, a list, a [Params] or a
     * [JsonElement]. GETs, and calls with an [idempotencyKey], are retried.
     */
    @JvmOverloads
    fun request(method: String, path: String, body: Any? = null, idempotencyKey: String? = null): JsonElement {
        val m = method.uppercase()
        val text = send(m, path, body?.let { toJson(it) }, idempotencyKey, retryable = m == "GET" || idempotencyKey != null)
        return if (text.isEmpty()) JsonObject(emptyMap()) else json.parseToJsonElement(text)
    }

    internal fun <T> call(
        method: String,
        path: String,
        deserializer: DeserializationStrategy<T>,
        body: JsonElement? = null,
        idempotencyKey: String? = null,
        retryable: Boolean = false,
    ): T {
        val text = send(method, path, body, idempotencyKey, retryable)
        return json.decodeFromString(deserializer, text.ifEmpty { "{}" })
    }

    internal fun callText(method: String, path: String, retryable: Boolean): String =
        send(method, path, null, null, retryable)

    private fun send(method: String, path: String, body: JsonElement?, idempotencyKey: String?, retryable: Boolean): String {
        val headers = linkedMapOf(
            "Authorization" to "Bearer $apiKey",
            "User-Agent" to "jointextkit-kotlin/$VERSION",
            "Accept" to "application/json",
        )
        val bytes = body?.let {
            headers["Content-Type"] = "application/json"
            json.encodeToString(JsonElement.serializer(), it).toByteArray(Charsets.UTF_8)
        }
        if (!idempotencyKey.isNullOrEmpty()) headers["Idempotency-Key"] = idempotencyKey
        val url = baseUrl + path

        var last: TextKitException? = null
        for (attempt in 0..maxRetries) {
            if (attempt > 0 && last != null) sleeper(backoffMillis(attempt, last))
            last = try {
                val res = transport.execute(TransportRequest(method, url, headers.toMap(), bytes, timeout))
                if (res.status in 200..299) return String(res.body, Charsets.UTF_8)
                errorFrom(res)
            } catch (e: HttpTimeoutException) {
                TextKitException("Request timed out after ${timeout.toMillis() / 1000.0}s", code = "connection_error", status = 0, cause = e)
            } catch (e: IOException) {
                TextKitException("Could not reach the TextKit API: ${e.message}", code = "connection_error", status = 0, cause = e)
            }
            // Retry only what is safe: a POST without an idempotency key is
            // never resent, and a verification cooldown is policy, not a blip.
            if (!retryable || !last.isRetryable) break
            if (last.code == "rate_limited" && path.startsWith("/verify")) break
        }
        throw last!!
    }

    internal fun resolveFrom(): String {
        defaultFrom?.let { return it }
        synchronized(fromLock) {
            defaultFrom?.let { return it }
            val active = numbers.list().data.filter { it.status == "active" }.mapNotNull { it.phoneNumber }
            if (active.size != 1) {
                throw TextKitException(
                    "Pass from (or set TEXTKIT_FROM): your account has " +
                        if (active.isEmpty()) "no numbers yet." else "${active.size} numbers.",
                    code = "invalid_request",
                    status = 0,
                    param = "from",
                )
            }
            defaultFrom = active[0]
            return active[0]
        }
    }

    internal val configuredFrom: String? get() = defaultFrom

    /** Every option. `build()` reads `TEXTKIT_API_KEY`, `TEXTKIT_BASE_URL` and `TEXTKIT_FROM` for what you leave unset. */
    class Builder internal constructor() {
        private var apiKey: String? = null
        private var defaultFrom: String? = null
        private var baseUrl: String? = null
        private var maxRetries = 2
        private var timeout: Duration = Duration.ofSeconds(30)
        private var transport: Transport? = null
        internal var sleeper: (Long) -> Unit = ::defaultSleep
        internal var env: (String) -> String? = System::getenv

        /** Default: `TEXTKIT_API_KEY`. */
        fun apiKey(value: String?) = apply { apiKey = value }

        /** The number `messages.send` uses when you don't pass one. Default: `TEXTKIT_FROM`, else your account's only number. */
        fun defaultFrom(value: String?) = apply { defaultFrom = value }

        /** Default: `TEXTKIT_BASE_URL`, else `https://api.jointextkit.com/v1`. `/v1` is added when missing. */
        fun baseUrl(value: String?) = apply { baseUrl = value }

        /** Retries for transient failures (429, 5xx, network). Default 2. */
        fun maxRetries(value: Int) = apply {
            require(value >= 0) { "maxRetries must be 0 or more" }
            maxRetries = value
        }

        /** Per-request timeout. Default 30 seconds. */
        fun timeout(value: Duration) = apply { timeout = value }

        /** Swap the HTTP layer (tests, tracing, proxies). Default: [JavaHttpTransport]. */
        fun transport(value: Transport?) = apply { transport = value }

        fun build(): TextKit = TextKit(apiKey, defaultFrom, baseUrl, maxRetries, timeout, transport, sleeper, env)
    }

    companion object {
        const val VERSION = "0.1.0"
        const val DEFAULT_BASE_URL = "https://api.jointextkit.com/v1"
        private val TEST_KEY_PREFIXES = listOf("tk_sk_test_", "ssms_sk_test_", "dsms_sk_test_", "resms_sk_test_")

        @JvmStatic fun builder(): Builder = Builder()

        /** A fresh `sdk_...` Idempotency-Key. */
        @JvmStatic fun newIdempotencyKey(): String = "sdk_" + UUID.randomUUID().toString().replace("-", "")

        internal fun normalizeBaseUrl(raw: String): String {
            val trimmed = raw.trimEnd('/')
            return if (trimmed.endsWith("/v1")) trimmed else "$trimmed/v1"
        }

        internal fun backoffMillis(attempt: Int, err: TextKitException): Long {
            val retryAfter = err.retryAfter
            if (retryAfter != null && retryAfter >= 0) return (retryAfter * 1000).toLong()
            val base = min(0.25 * 2.0.pow(attempt), 4.0)
            return ((base + ThreadLocalRandom.current().nextDouble(0.0, base / 4)) * 1000).toLong()
        }

        internal fun errorFrom(res: TransportResponse): TextKitException {
            val payload = try {
                if (res.body.isEmpty()) null else json.parseToJsonElement(String(res.body, Charsets.UTF_8))
            } catch (_: Exception) {
                null
            }
            val err = (payload as? JsonObject)?.get("error") as? JsonObject ?: JsonObject(emptyMap())
            fun str(name: String) = (err[name] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
            fun long(name: String) = (err[name] as? JsonPrimitive)?.longOrNull
            val retryAfter = (err["retry_after"] as? JsonPrimitive)?.doubleOrNull
                ?: res.headers["retry-after"]?.trim()?.toDoubleOrNull()
            return TextKitException(
                str("message") ?: "Request failed with status ${res.status}",
                code = str("code") ?: if (res.status >= 500) "internal_error" else "invalid_request",
                status = res.status,
                param = str("param"),
                retryAfter = retryAfter,
                reason = str("reason"),
                balanceMicroUsd = long("balance_micro_usd"),
                requiredMicroUsd = long("required_micro_usd"),
                topUpUrl = str("top_up_url"),
                sendAfter = str("send_after"),
                recipientLocalTime = str("recipient_local_time"),
                timezone = str("timezone"),
                messageId = str("message_id"),
            )
        }
    }
}

private fun defaultSleep(millis: Long) {
    try {
        Thread.sleep(millis)
    } catch (e: InterruptedException) {
        Thread.currentThread().interrupt()
        throw TextKitException("Interrupted while waiting to retry", code = "connection_error", status = 0, cause = e)
    }
}
