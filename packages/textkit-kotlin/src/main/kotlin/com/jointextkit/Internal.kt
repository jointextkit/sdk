package com.jointextkit

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

internal val json = Json {
    ignoreUnknownKeys = true
    // An explicit null for a field with a default (e.g. a list) decodes to the default.
    coerceInputValues = true
    explicitNulls = false
    // Send `accepted: true` on an Attestation even though it is the default.
    encodeDefaults = true
}

/** Plain Kotlin/Java values (maps, lists, strings, numbers, booleans, nulls) to JSON. */
internal fun toJson(value: Any?): JsonElement = when (value) {
    null -> JsonNull
    is JsonElement -> value
    is String -> JsonPrimitive(value)
    is Boolean -> JsonPrimitive(value)
    is Number -> JsonPrimitive(value)
    is Enum<*> -> JsonPrimitive(value.name)
    is Instant -> JsonPrimitive(isoUtc(value))
    is OffsetDateTime -> JsonPrimitive(isoUtc(value.toInstant()))
    is ZonedDateTime -> JsonPrimitive(isoUtc(value.toInstant()))
    is ScheduleRepeat -> json.encodeToJsonElement(ScheduleRepeat.serializer(), value)
    is Attestation -> json.encodeToJsonElement(Attestation.serializer(), value)
    is Params -> JsonObject(value.toJsonFields())
    is Map<*, *> -> JsonObject(value.entries.associate { (k, v) -> k.toString() to toJson(v) })
    is Iterable<*> -> JsonArray(value.map { toJson(it) })
    is Array<*> -> JsonArray(value.map { toJson(it) })
    else -> throw IllegalArgumentException("Cannot send a ${value::class.java.name} as JSON; use maps, lists, strings, numbers and booleans.")
}

/** `2026-10-02T09:30:00Z`: UTC, whole seconds when there are no fractions. */
internal fun isoUtc(instant: Instant): String =
    DateTimeFormatter.ISO_INSTANT.format(if (instant.nano == 0) instant.truncatedTo(ChronoUnit.SECONDS) else instant)

internal fun encodeQueryComponent(value: String): String = URLEncoder.encode(value, StandardCharsets.UTF_8)

/** One path segment, `+` and `/` included, so `+14155550132` reaches the API as `%2B14155550132`. */
internal fun seg(value: String): String = URLEncoder.encode(value, StandardCharsets.UTF_8).replace("+", "%20")

/** `?a=1&b=two` from the non-null pairs, in order; "" when none are set. */
internal fun query(vararg pairs: Pair<String, Any?>): String {
    val parts = pairs.filter { it.second != null }.map { (k, v) ->
        "${encodeQueryComponent(k)}=${encodeQueryComponent(v.toString())}"
    }
    return if (parts.isEmpty()) "" else "?" + parts.joinToString("&")
}

/** Lazily walks every page, fetching the next one only when iteration reaches it. */
internal class PagedIterable<T>(private val fetch: (cursor: String?) -> Page<T>) : Iterable<T> {
    override fun iterator(): Iterator<T> = object : Iterator<T> {
        private var page: Page<T>? = null
        private var index = 0
        private var done = false

        private fun advance() {
            while (!done) {
                val current = page
                if (current != null && index < current.data.size) return
                if (current != null && (!current.hasMore || current.nextCursor.isNullOrEmpty())) {
                    done = true
                    return
                }
                page = fetch(current?.nextCursor)
                index = 0
            }
        }

        override fun hasNext(): Boolean {
            advance()
            return !done
        }

        override fun next(): T {
            if (!hasNext()) throw NoSuchElementException()
            return page!!.data[index++]
        }
    }
}
