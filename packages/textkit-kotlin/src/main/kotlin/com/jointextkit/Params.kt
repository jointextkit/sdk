package com.jointextkit

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import java.time.Instant

/**
 * Request parameters. Every setter returns the params object, so they chain
 * like a builder in Java (`new SendMessageParams(to, body).from(number)`) and
 * read naturally in Kotlin (`SendMessageParams(to, body).from(number)`).
 *
 * Create and list params drop a field set to null. Update params
 * ([UpdateParams]) send only the fields you set, and a field set to null
 * reaches the API as JSON null, which clears it.
 */
abstract class Params internal constructor() {
    internal val fields = LinkedHashMap<String, Any?>()

    /** Set any field by its API name, for fields this SDK version does not have a setter for yet. */
    protected fun put(name: String, value: Any?) {
        fields[name] = value
    }

    internal open val sendsNulls: Boolean get() = false

    internal fun toJsonFields(): Map<String, JsonElement> {
        val out = LinkedHashMap<String, JsonElement>()
        for ((k, v) in fields) {
            if (v == null && !sendsNulls) continue
            out[k] = toJson(v)
        }
        return out
    }

    internal fun has(name: String) = fields.containsKey(name)
}

/** Params for a PATCH: only the fields you set are sent; null clears a field. */
abstract class UpdateParams internal constructor() : Params() {
    override val sendsNulls: Boolean get() = true
}

/** The signed business attestation the first registration submit carries. */
@Serializable
data class Attestation @JvmOverloads constructor(
    @SerialName("signer_name") val signerName: String,
    @SerialName("signer_title") val signerTitle: String,
    val accepted: Boolean = true,
)

// --- Messages ---------------------------------------------------------------

/** `messages.send`. [to] and [body] are required; everything else is optional. */
class SendMessageParams(to: String, body: String) : Params() {
    internal var idempotencyKey: String? = null

    init {
        put("to", to)
        put("body", body)
    }

    /** The sending number. Defaults to the client's `defaultFrom`, else your account's only number. */
    fun from(value: String?) = apply { put("from", value) }
    fun customerId(value: String?) = apply { put("customer_id", value) }

    /** `marketing`, `transactional` or `otp`. Can make a message stricter, never looser. */
    fun category(value: String?) = apply { put("category", value) }

    /** `block` (throws `quiet_hours`) or `defer` (holds a marketing message until 8:00am local). */
    fun quietHours(value: String?) = apply { put("quiet_hours", value) }

    /** How the recipient agreed: `{"source": "checkout", "collected_at": "..."}` (plus `page_url` for a web form). */
    fun consent(value: Map<String, Any?>?) = apply { put("consent", value) }

    /** Media URLs (MMS). */
    fun media(value: List<String>?) = apply { put("media", value) }

    /** Your own Idempotency-Key. One is generated when you don't set it. */
    fun idempotencyKey(value: String?) = apply { idempotencyKey = value }

    /** Any other field, by its API name. */
    fun set(name: String, value: Any?) = apply { put(name, value) }
}

/** `messages.schedule`: queue a message for later (up to 30 days ahead). */
class ScheduleMessageParams private constructor(to: String, body: String, sendAt: String) : Params() {
    /** [sendAt] is sent as UTC ISO 8601. */
    constructor(to: String, body: String, sendAt: Instant) : this(to, body, isoUtc(sendAt))

    companion object {
        /** [sendAt] as an ISO 8601 timestamp you already formatted. */
        @JvmStatic fun at(to: String, body: String, sendAt: String) = ScheduleMessageParams(to, body, sendAt)
    }

    init {
        put("to", to)
        put("body", body)
        put("scheduled_at", sendAt)
    }

    fun from(value: String?) = apply { put("from", value) }
    fun customerId(value: String?) = apply { put("customer_id", value) }
    fun category(value: String?) = apply { put("category", value) }
    fun quietHours(value: String?) = apply { put("quiet_hours", value) }
    fun set(name: String, value: Any?) = apply { put(name, value) }
}

/** `messages.list` filters. All optional. */
class ListMessagesParams : Params() {
    fun limit(value: Int?) = apply { put("limit", value) }
    fun cursor(value: String?) = apply { put("cursor", value) }

    /** Messages to or from one of your numbers. */
    fun number(value: String?) = apply { put("number", value) }
    fun to(value: String?) = apply { put("to", value) }
    fun from(value: String?) = apply { put("from", value) }

    /** `blocked` lists the sends a check refused. */
    fun status(value: String?) = apply { put("status", value) }
    fun blockedReason(value: String?) = apply { put("blocked_reason", value) }
    fun failureCode(value: String?) = apply { put("failure_code", value) }
    fun direction(value: String?) = apply { put("direction", value) }
    fun createdAfter(value: String?) = apply { put("created_after", value) }
    fun createdBefore(value: String?) = apply { put("created_before", value) }
    fun customerId(value: String?) = apply { put("customer_id", value) }

    /** Only the occurrences of one recurring schedule. */
    fun scheduleId(value: String?) = apply { put("schedule_id", value) }

    internal fun copyWithCursor(cursor: String?): ListMessagesParams {
        val copy = ListMessagesParams()
        copy.fields.putAll(fields)
        copy.fields["cursor"] = cursor
        return copy
    }
}

// --- Numbers ----------------------------------------------------------------

class ListNumbersParams : Params() {
    fun customerId(value: String?) = apply { put("customer_id", value) }
    fun tag(value: String?) = apply { put("tag", value) }
    fun pool(value: String?) = apply { put("pool", value) }

    /** `test` or `live`. */
    fun mode(value: String?) = apply { put("mode", value) }

    /** Search text. */
    fun q(value: String?) = apply { put("q", value) }
}

// --- Webhooks ---------------------------------------------------------------

class UpdateWebhookParams : UpdateParams() {
    fun url(value: String) = apply { put("url", value) }

    /** Event types; `listOf("*")` subscribes to everything. */
    fun events(value: List<String>) = apply { put("events", if (value == listOf("*")) "*" else value) }

    /** `false` pauses delivery. */
    fun active(value: Boolean) = apply { put("active", value) }

    /** null clears it. */
    fun description(value: String?) = apply { put("description", value) }
}

// --- Customers --------------------------------------------------------------

class UpdateCustomerParams : UpdateParams() {
    fun name(value: String?) = apply { put("name", value) }
    fun externalId(value: String?) = apply { put("external_id", value) }

    /** Replaces the whole object; null clears it. */
    fun metadata(value: Map<String, String>?) = apply { put("metadata", value) }
}

// --- Contacts ---------------------------------------------------------------

/** A contact to upsert (`contacts.upsert`, `contacts.import`). Values you leave out are kept; tags are added, never removed. */
class ContactParams(phoneNumber: String) : Params() {
    init {
        put("phone_number", phoneNumber)
    }

    fun name(value: String?) = apply { put("name", value) }
    fun firstName(value: String?) = apply { put("first_name", value) }
    fun lastName(value: String?) = apply { put("last_name", value) }
    fun email(value: String?) = apply { put("email", value) }
    fun company(value: String?) = apply { put("company", value) }
    fun state(value: String?) = apply { put("state", value) }
    fun source(value: String?) = apply { put("source", value) }
    fun tags(value: List<String>?) = apply { put("tags", value) }
    fun fields(value: Map<String, String>?) = apply { put("fields", value) }
    fun notes(value: String?) = apply { put("notes", value) }

    /** Opt-in evidence recorded with the contact. */
    fun optIn(value: Map<String, Any?>?) = apply { put("opt_in", value) }
    fun set(name: String, value: Any?) = apply { put(name, value) }
}

/** `contacts.update`: `tags` and `fields` replace what is stored; null clears `name` or `notes`. */
class UpdateContactParams : UpdateParams() {
    fun phoneNumber(value: String) = apply { put("phone_number", value) }
    fun name(value: String?) = apply { put("name", value) }
    fun firstName(value: String?) = apply { put("first_name", value) }
    fun lastName(value: String?) = apply { put("last_name", value) }
    fun email(value: String?) = apply { put("email", value) }
    fun company(value: String?) = apply { put("company", value) }
    fun state(value: String?) = apply { put("state", value) }
    fun source(value: String?) = apply { put("source", value) }
    fun tags(value: List<String>) = apply { put("tags", value) }
    fun fields(value: Map<String, String>) = apply { put("fields", value) }
    fun notes(value: String?) = apply { put("notes", value) }
}

class ListContactsParams : Params() {
    fun limit(value: Int?) = apply { put("limit", value) }
    fun cursor(value: String?) = apply { put("cursor", value) }
    fun tag(value: String?) = apply { put("tag", value) }

    /** Finds the one contact holding this number. */
    fun phoneNumber(value: String?) = apply { put("phone_number", value) }
    fun segmentId(value: String?) = apply { put("segment_id", value) }
    fun q(value: String?) = apply { put("q", value) }

    internal fun copyWithCursor(cursor: String?): ListContactsParams {
        val copy = ListContactsParams()
        copy.fields.putAll(fields)
        copy.fields["cursor"] = cursor
        return copy
    }
}

// --- Automations ------------------------------------------------------------

/**
 * `automations.create`. [trigger] is e.g. `mapOf("event" to "trial_started")`;
 * [steps] are maps like `mapOf("type" to "send_sms", "body" to "...")`.
 */
class CreateAutomationParams(name: String, trigger: Map<String, Any?>, steps: List<Map<String, Any?>>) : Params() {
    init {
        put("name", name)
        put("trigger", trigger)
        put("steps", steps)
    }

    fun from(value: String?) = apply { put("from", value) }
    fun topicId(value: String?) = apply { put("topic_id", value) }
}

/** `automations.update`: only what you set. Editing an active flow publishes a new version. */
class UpdateAutomationParams : UpdateParams() {
    fun name(value: String) = apply { put("name", value) }
    fun trigger(value: Map<String, Any?>) = apply { put("trigger", value) }
    fun steps(value: List<Map<String, Any?>>) = apply { put("steps", value) }
    fun from(value: String?) = apply { put("from", value) }
    fun topicId(value: String?) = apply { put("topic_id", value) }
}

// --- Schedules --------------------------------------------------------------

/** `schedules.create`: one message to one number on a repeating local time. */
class CreateScheduleParams(to: String, body: String, repeat: ScheduleRepeat) : Params() {
    internal var idempotencyKey: String? = null

    init {
        put("to", to)
        put("body", body)
        put("repeat", repeat)
    }

    /** Falls back to the client's `defaultFrom`; left out entirely, the API uses your account's one number. */
    fun from(value: String?) = apply { put("from", value) }

    /** `YYYY-MM-DD`. */
    fun startDate(value: String?) = apply { put("start_date", value) }
    fun endDate(value: String?) = apply { put("end_date", value) }
    fun maxOccurrences(value: Int?) = apply { put("max_occurrences", value) }
    fun category(value: String?) = apply { put("category", value) }
    fun quietHours(value: String?) = apply { put("quiet_hours", value) }

    /** Your own Idempotency-Key. One is generated when you don't set it. */
    fun idempotencyKey(value: String?) = apply { idempotencyKey = value }
}

/** `schedules.update`. Null clears `startDate`, `endDate` or `maxOccurrences`; `repeat` replaces the whole object. */
class UpdateScheduleParams : UpdateParams() {
    fun to(value: String) = apply { put("to", value) }
    fun from(value: String?) = apply { put("from", value) }
    fun body(value: String) = apply { put("body", value) }
    fun repeat(value: ScheduleRepeat) = apply { put("repeat", value) }
    fun startDate(value: String?) = apply { put("start_date", value) }
    fun endDate(value: String?) = apply { put("end_date", value) }
    fun maxOccurrences(value: Int?) = apply { put("max_occurrences", value) }
    fun active(value: Boolean) = apply { put("active", value) }
    fun category(value: String?) = apply { put("category", value) }
    fun quietHours(value: String?) = apply { put("quiet_hours", value) }
}

// --- Registrations ----------------------------------------------------------

/**
 * Registration fields for `registrations.create` (which needs [businessName],
 * [website] and [useCase]) and `registrations.recheck` (any subset).
 */
class RegistrationParams : Params() {
    fun businessName(value: String) = apply { put("business_name", value) }
    fun website(value: String) = apply { put("website", value) }

    /** e.g. `customer_care`, `account_notifications`, `marketing`. */
    fun useCase(value: String) = apply { put("use_case", value) }
    fun optInUrl(value: String?) = apply { put("opt_in_url", value) }
    fun privacyUrl(value: String?) = apply { put("privacy_url", value) }
    fun termsUrl(value: String?) = apply { put("terms_url", value) }
    fun supportEmail(value: String?) = apply { put("support_email", value) }
    fun sampleMessages(value: List<String>?) = apply { put("sample_messages", value) }
    fun description(value: String?) = apply { put("description", value) }
    fun optInFlow(value: String?) = apply { put("opt_in_flow", value) }

    /** The business as the carriers register it (legal name, EIN, address, authorized representative). */
    fun brand(value: Map<String, Any?>?) = apply { put("brand", value) }

    /** Any other registration field, by its API name. */
    fun set(name: String, value: Any?) = apply { put(name, value) }
}
