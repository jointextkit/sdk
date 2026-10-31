@file:Suppress("unused")

package com.jointextkit

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive

// Response shapes. Every field except `id` is nullable: the API leaves a field
// out when it has no value (e.g. `customerId` on an unattributed message), and
// a field added to the API later is ignored rather than breaking the decode.
// Status-like fields are plain strings so a new value never throws. Open-ended
// objects (`data`, `metadata`, `brand`, ...) are kotlinx `JsonObject`s, which
// are `Map<String, JsonElement>` to Java.

/**
 * One page of a list. Pass [nextCursor] back as `cursor` for the next page,
 * or use the resource's `listAll(...)`, which fetches pages as you iterate.
 */
@Serializable
data class Page<T>(
    val data: List<T> = emptyList(),
    @SerialName("has_more") val hasMore: Boolean = false,
    @SerialName("next_cursor") val nextCursor: String? = null,
)

@Serializable
data class Message(
    val id: String,
    /** `"message"`, or `"scheduled_message"` when `quietHours = "defer"` held the send. */
    @SerialName("object") val objectType: String? = null,
    val to: String? = null,
    val from: String? = null,
    val body: String? = null,
    /** `outbound` or `inbound`. */
    val direction: String? = null,
    /** `queued`, `sent`, `delivered`, `failed`, `blocked` (refused by a send check, never charged) or `received`. */
    val status: String? = null,
    val test: Boolean? = null,
    /** True when nothing was handed to a carrier (test keys). Always false on live messages. */
    val simulated: Boolean? = null,
    /** Only on the response to `messages.send`, e.g. when a test-key send was simulated. */
    val notice: String? = null,
    @SerialName("schedule_id") val scheduleId: String? = null,
    /** `marketing`, `transactional` or `otp`, when the message was classified. */
    val category: String? = null,
    @SerialName("disclosures_added") val disclosuresAdded: List<String>? = null,
    /** Present when the message was held for quiet hours. */
    val deferred: JsonObject? = null,
    /** When a held message will send (only when [objectType] is `scheduled_message`). */
    @SerialName("scheduled_at") val scheduledAt: String? = null,
    val media: List<String>? = null,
    @SerialName("sent_by") val sentBy: String? = null,
    @SerialName("failure_reason") val failureReason: String? = null,
    /** Why it failed: `code`, `title`, `explanation`, `action`, `carrier_code`. */
    val failure: JsonObject? = null,
    val attempts: Int? = null,
    @SerialName("next_attempt_at") val nextAttemptAt: String? = null,
    @SerialName("receipt_status") val receiptStatus: String? = null,
    @SerialName("customer_id") val customerId: String? = null,
    val timeline: List<JsonObject>? = null,
    val segments: Int? = null,
    val encoding: String? = null,
    val price: JsonObject? = null,
    @SerialName("destination_carrier") val destinationCarrier: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
)

/** A message queued for later (`messages.schedule`). */
@Serializable
data class ScheduledMessage(
    val id: String,
    @SerialName("object") val objectType: String? = null,
    val to: String? = null,
    val from: String? = null,
    val body: String? = null,
    /** When it will send. */
    @SerialName("scheduled_at") val scheduledAt: String? = null,
    val status: String? = null,
    @SerialName("customer_id") val customerId: String? = null,
    val deferred: JsonObject? = null,
    @SerialName("batch_id") val batchId: String? = null,
)

@Serializable
data class Verification(
    val id: String,
    @SerialName("object") val objectType: String? = null,
    val phone: String? = null,
    /** `pending`, `approved`, `expired`, `max_attempts` or `blocked`. */
    val status: String? = null,
    val attempts: Int? = null,
    @SerialName("attempts_remaining") val attemptsRemaining: Int? = null,
    @SerialName("max_attempts") val maxAttempts: Int? = null,
    val test: Boolean? = null,
    val charged: Boolean? = null,
    @SerialName("customer_id") val customerId: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("expires_at") val expiresAt: String? = null,
    @SerialName("expires_in") val expiresIn: Int? = null,
)

@Serializable
data class VerificationCheck(
    /** True when the code was right. You are billed only then. */
    val verified: Boolean = false,
    val status: String? = null,
    val attempts: Int? = null,
    @SerialName("attempts_remaining") val attemptsRemaining: Int? = null,
    @SerialName("max_attempts") val maxAttempts: Int? = null,
    val charged: Boolean? = null,
)

/** A phone number on your account. */
@Serializable
data class PhoneNumber(
    val id: String,
    @SerialName("object") val objectType: String? = null,
    @SerialName("phone_number") val phoneNumber: String? = null,
    /** `active` or `released`. */
    val status: String? = null,
    /** `test` or `live`. */
    val mode: String? = null,
    @SerialName("customer_id") val customerId: String? = null,
    val label: String? = null,
    val tags: List<String>? = null,
    val pools: List<String>? = null,
    val sender: JsonObject? = null,
    @SerialName("toll_free") val tollFree: JsonObject? = null,
    @SerialName("created_at") val createdAt: String? = null,
)

@Serializable
data class AvailableNumber(
    @SerialName("object") val objectType: String? = null,
    @SerialName("phone_number") val phoneNumber: String,
    val locality: String? = null,
    val region: String? = null,
)

@Serializable
data class Balance(
    @SerialName("object") val objectType: String? = null,
    @SerialName("balance_micro_usd") val balanceMicroUsd: Long? = null,
    @SerialName("balance_usd") val balanceUsd: Double? = null,
    val currency: String? = null,
    /** `credits.low` fires when the balance falls below this. */
    @SerialName("low_balance_usd") val lowBalanceUsd: Double? = null,
    /** `enabled`, `threshold_usd`, `amount_usd`. */
    @SerialName("auto_recharge") val autoRecharge: JsonObject? = null,
    @SerialName("top_up_url") val topUpUrl: String? = null,
)

/** A tracked destination with its clicks and conversions. */
@Serializable
data class TrackedLink(
    val url: String,
    val name: String? = null,
    @SerialName("short_url") val shortUrl: String? = null,
    @SerialName("click_id") val clickId: String? = null,
    val texts: Int = 0,
    val clicks: Int = 0,
    val conversions: Int = 0,
    @SerialName("value_cents") val valueCents: Long = 0,
    val test: Boolean = false,
)

/** A sale or sign-up reported against a click. */
@Serializable
data class Conversion(
    val id: String,
    @SerialName("click_id") val clickId: String,
    val url: String,
    val name: String? = null,
    @SerialName("external_id") val externalId: String? = null,
    @SerialName("value_cents") val valueCents: Long = 0,
    val duplicate: Boolean = false,
    val test: Boolean = false,
    @SerialName("created_at") val createdAt: String? = null,
)

@Serializable
data class Lookup(
    @SerialName("phone_number") val phoneNumber: String? = null,
    val valid: Boolean? = null,
    /** `mobile`, `landline`, `voip`, ... */
    @SerialName("line_type") val lineType: String? = null,
    val carrier: JsonObject? = null,
    @SerialName("caller_name") val callerName: String? = null,
)

/** An event from `events.list`, `events.wait`, or a verified webhook. */
@Serializable
data class Event(
    val id: String,
    @SerialName("object") val objectType: String? = null,
    /** `message.delivered`, `message.received`, ... */
    val type: String? = null,
    val mode: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
    val data: JsonObject? = null,
)

/**
 * What `events.wait` answers. [data] is oldest first and may repeat an event
 * already returned (de-duplicate by `id`); pass [cursor] back on the next call.
 */
@Serializable
data class EventWait(
    @SerialName("object") val objectType: String? = null,
    val data: List<Event> = emptyList(),
    val cursor: String? = null,
    @SerialName("has_more") val hasMore: Boolean = false,
)

/** What `events.track` answers: the event, and what it did. */
@Serializable
data class TrackedEvent(
    val id: String,
    @SerialName("object") val objectType: String? = null,
    val event: String? = null,
    @SerialName("user_id") val userId: String? = null,
    val phone: String? = null,
    val properties: JsonObject? = null,
    val test: Boolean? = null,
    @SerialName("runs_started") val runsStarted: List<String>? = null,
    @SerialName("runs_notified") val runsNotified: Int? = null,
    @SerialName("created_at") val createdAt: String? = null,
)

/** The API sends `events` as `"*"` (everything) or a list; both decode to a list (`["*"]`). */
internal object EventsListSerializer : KSerializer<List<String>> {
    override val descriptor: SerialDescriptor = ListSerializer(String.serializer()).descriptor

    override fun deserialize(decoder: Decoder): List<String> {
        val element = (decoder as JsonDecoder).decodeJsonElement()
        return when (element) {
            is JsonArray -> element.mapNotNull { it.jsonPrimitive.contentOrNull }
            is JsonPrimitive -> listOfNotNull(element.contentOrNull)
            else -> emptyList()
        }
    }

    override fun serialize(encoder: Encoder, value: List<String>) {
        val json = encoder as JsonEncoder
        json.encodeJsonElement(if (value == listOf("*")) JsonPrimitive("*") else JsonArray(value.map { JsonPrimitive(it) }))
    }
}

@Serializable
data class WebhookEndpoint(
    val id: String,
    @SerialName("object") val objectType: String? = null,
    val url: String? = null,
    /** Subscribed event types; `["*"]` means every event. */
    @Serializable(with = EventsListSerializer::class) val events: List<String>? = null,
    val active: Boolean? = null,
    val mode: String? = null,
    val description: String? = null,
    /** Only on the response to `webhooks.create`: the signing secret, returned this once. */
    val secret: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
)

/** What a delete answers. */
@Serializable
data class Deleted(
    val id: String,
    @SerialName("object") val objectType: String? = null,
    val deleted: Boolean = false,
)

/** One number on the suppression list (`consent.list`) or a consent change (`consent.optOut` / `optIn`). */
@Serializable
data class ConsentRecord(
    @SerialName("object") val objectType: String? = null,
    val phone: String? = null,
    /** `opted_out` or `opted_in`. */
    val status: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
    val via: String? = null,
    val method: String? = null,
    val detected: String? = null,
    val confidence: Double? = null,
    @SerialName("campaign_id") val campaignId: String? = null,
    val proof: JsonObject? = null,
)

/** Current status plus the append-only history for one number (`consent.get`). */
@Serializable
data class ConsentDetail(
    @SerialName("object") val objectType: String? = null,
    val phone: String? = null,
    /** `opted_out`, `opted_in` or `none`. */
    val status: String? = null,
    val history: List<JsonObject>? = null,
    @SerialName("opted_out_at") val optedOutAt: String? = null,
    @SerialName("opted_out_via") val optedOutVia: String? = null,
    @SerialName("opted_out_method") val optedOutMethod: String? = null,
    @SerialName("blocked_sends") val blockedSends: Int? = null,
    @SerialName("last_blocked_at") val lastBlockedAt: String? = null,
)

@Serializable
data class ConsentImport(
    @SerialName("object") val objectType: String? = null,
    val imported: Int = 0,
    val skipped: List<JsonObject> = emptyList(),
)

/** A business you send on behalf of (for platforms). */
@Serializable
data class Customer(
    val id: String,
    @SerialName("object") val objectType: String? = null,
    val name: String? = null,
    @SerialName("external_id") val externalId: String? = null,
    val metadata: JsonObject? = null,
    @SerialName("phone_numbers") val phoneNumbers: List<String>? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
)

@Serializable
data class CustomerUsage(
    @SerialName("object") val objectType: String? = null,
    @SerialName("customer_id") val customerId: String? = null,
    val mode: String? = null,
    val start: String? = null,
    val end: String? = null,
    @SerialName("messages_sent") val messagesSent: Int = 0,
    @SerialName("messages_failed") val messagesFailed: Int = 0,
    @SerialName("messages_received") val messagesReceived: Int = 0,
    @SerialName("verifications_sent") val verificationsSent: Int = 0,
    @SerialName("verifications_approved") val verificationsApproved: Int = 0,
    val numbers: Int = 0,
    @SerialName("phone_numbers") val phoneNumbers: List<String>? = null,
    val daily: List<JsonObject>? = null,
)

@Serializable
data class Contact(
    val id: String,
    @SerialName("object") val objectType: String? = null,
    @SerialName("phone_number") val phoneNumber: String? = null,
    val name: String? = null,
    @SerialName("first_name") val firstName: String? = null,
    @SerialName("last_name") val lastName: String? = null,
    val email: String? = null,
    val company: String? = null,
    val state: String? = null,
    val source: String? = null,
    val tags: List<String>? = null,
    val fields: JsonObject? = null,
    val notes: String? = null,
    @SerialName("consent_status") val consentStatus: String? = null,
    @SerialName("opt_in") val optIn: JsonObject? = null,
    @SerialName("import_id") val importId: String? = null,
    val topics: List<JsonObject>? = null,
    val segments: List<JsonElement>? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
)

@Serializable
data class ContactImport(
    /** `contact_import`, or `contact_import_preview` for a dry run. */
    @SerialName("object") val objectType: String? = null,
    val created: Int = 0,
    val updated: Int = 0,
    /** Each with `index`, `value` and `reason`. */
    val skipped: List<JsonObject> = emptyList(),
)

@Serializable
data class ContactBulk(
    @SerialName("object") val objectType: String? = null,
    val action: String? = null,
    val updated: Int = 0,
    val deleted: Int = 0,
    val missing: Int = 0,
)

/** When a schedule fires: `frequency` (`daily`, `weekly`, `monthly`) at a wall-clock `time` in `timezone`. */
@Serializable
data class ScheduleRepeat @JvmOverloads constructor(
    val frequency: String,
    /** 24-hour local time, "HH:MM". */
    val time: String,
    /** IANA zone, e.g. `America/New_York`. */
    val timezone: String,
    /** Weekly only: `["mon", "fri"]`. */
    @SerialName("days_of_week") val daysOfWeek: List<String>? = null,
    /** Monthly only: 1-31. */
    @SerialName("day_of_month") val dayOfMonth: Int? = null,
) {
    companion object {
        @JvmStatic fun daily(time: String, timezone: String) = ScheduleRepeat("daily", time, timezone)

        @JvmStatic fun weekly(daysOfWeek: List<String>, time: String, timezone: String) =
            ScheduleRepeat("weekly", time, timezone, daysOfWeek = daysOfWeek)

        @JvmStatic fun monthly(dayOfMonth: Int, time: String, timezone: String) =
            ScheduleRepeat("monthly", time, timezone, dayOfMonth = dayOfMonth)
    }
}

/** A recurring schedule: one message to one number on a repeating local time. */
@Serializable
data class Schedule(
    val id: String,
    @SerialName("object") val objectType: String? = null,
    val to: String? = null,
    val from: String? = null,
    val body: String? = null,
    val repeat: ScheduleRepeat? = null,
    @SerialName("start_date") val startDate: String? = null,
    @SerialName("end_date") val endDate: String? = null,
    @SerialName("max_occurrences") val maxOccurrences: Int? = null,
    val category: String? = null,
    @SerialName("quiet_hours") val quietHours: String? = null,
    val active: Boolean? = null,
    /** `active`, `paused` or `completed`. */
    val status: String? = null,
    @SerialName("paused_reason") val pausedReason: String? = null,
    @SerialName("next_run_at") val nextRunAt: String? = null,
    @SerialName("last_run_at") val lastRunAt: String? = null,
    @SerialName("last_status") val lastStatus: String? = null,
    @SerialName("last_error") val lastError: String? = null,
    @SerialName("last_message_id") val lastMessageId: String? = null,
    val counts: JsonObject? = null,
    val test: Boolean? = null,
    /** Only on `schedules.get`: the last 10 occurrences, newest first. */
    @SerialName("recent_occurrences") val recentOccurrences: List<JsonObject>? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
)

/** An event-driven flow: a trigger event, then send / wait / branch steps. */
@Serializable
data class Automation(
    val id: String,
    @SerialName("object") val objectType: String? = null,
    val name: String? = null,
    /** `draft`, `active` or `paused`. */
    val status: String? = null,
    val trigger: JsonObject? = null,
    val steps: List<JsonObject>? = null,
    val from: String? = null,
    @SerialName("topic_id") val topicId: String? = null,
    val test: Boolean? = null,
    val version: Int? = null,
    @SerialName("unpublished_changes") val unpublishedChanges: Boolean? = null,
    val stats: JsonObject? = null,
    /** What stops the flow from running, if anything. */
    val issues: List<JsonObject>? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
)

@Serializable
data class AutomationRun(
    val id: String,
    @SerialName("object") val objectType: String? = null,
    @SerialName("automation_id") val automationId: String? = null,
    @SerialName("automation_version") val automationVersion: Int? = null,
    /** `running`, `waiting`, `completed` or `failed`. */
    val status: String? = null,
    val to: String? = null,
    @SerialName("user_id") val userId: String? = null,
    val test: Boolean? = null,
    @SerialName("trigger_event") val triggerEvent: String? = null,
    val step: Int? = null,
    @SerialName("waiting_until") val waitingUntil: String? = null,
    @SerialName("waiting_for_event") val waitingForEvent: String? = null,
    @SerialName("end_reason") val endReason: String? = null,
    @SerialName("messages_sent") val messagesSent: Int? = null,
    @SerialName("messages_failed") val messagesFailed: Int? = null,
    val timeline: List<JsonObject>? = null,
    @SerialName("started_at") val startedAt: String? = null,
    @SerialName("ended_at") val endedAt: String? = null,
)

/** A brand and campaign registration (business texting). */
@Serializable
data class Registration(
    val id: String,
    @SerialName("object") val objectType: String? = null,
    /** `draft`, `checks_failed`, `ready`, `submitted`, `in_review`, `approved` or `rejected`. */
    val status: String? = null,
    @SerialName("business_name") val businessName: String? = null,
    val website: String? = null,
    @SerialName("use_case") val useCase: String? = null,
    @SerialName("opt_in_url") val optInUrl: String? = null,
    @SerialName("privacy_url") val privacyUrl: String? = null,
    @SerialName("terms_url") val termsUrl: String? = null,
    @SerialName("support_email") val supportEmail: String? = null,
    val brand: JsonObject? = null,
    @SerialName("sample_messages") val sampleMessages: List<String>? = null,
    @SerialName("samples_source") val samplesSource: String? = null,
    val description: String? = null,
    /** What happened, why, and who acts next. */
    val guidance: JsonObject? = null,
    val check: JsonObject? = null,
    @SerialName("sample_check") val sampleCheck: JsonObject? = null,
    val rejection: JsonObject? = null,
    val generated: JsonObject? = null,
    @SerialName("marketing_paused") val marketingPaused: JsonObject? = null,
    val submissions: Int? = null,
    val history: List<JsonObject>? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
)

/** A filed copy of a registration: exactly what one submission sent. */
@Serializable
data class RegistrationSubmission(
    @SerialName("object") val objectType: String? = null,
    @SerialName("registration_id") val registrationId: String? = null,
    val number: Int? = null,
    @SerialName("submitted_at") val submittedAt: String? = null,
    @SerialName("filed_by") val filedBy: String? = null,
    val reference: String? = null,
    @SerialName("sample_messages") val sampleMessages: List<String>? = null,
    val description: String? = null,
    val brand: JsonObject? = null,
    val campaign: JsonObject? = null,
    @SerialName("fee_acknowledgment") val feeAcknowledgment: JsonObject? = null,
)
