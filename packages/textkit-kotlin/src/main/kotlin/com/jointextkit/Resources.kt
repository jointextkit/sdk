package com.jointextkit

import kotlinx.serialization.json.JsonObject
import java.time.Instant

private fun body(vararg pairs: Pair<String, Any?>, keepNulls: Boolean = false): JsonObject =
    JsonObject(pairs.filter { keepNulls || it.second != null }.associate { (k, v) -> k to toJson(v) })

private fun Params.json(): JsonObject = JsonObject(toJsonFields())

private fun Params.queryString(): String =
    query(*fields.filter { it.value != null }.map { it.key to it.value }.toTypedArray())

/** Send and look up text messages. */
class Messages internal constructor(private val client: TextKit) {
    /**
     * Send an SMS. Retries are safe: an Idempotency-Key is generated when you
     * don't set one, so a network blip can never double-send.
     *
     * When the params carry no `from`, the client's `defaultFrom` is used,
     * else your account's only number (looked up once).
     *
     * With `quietHours("defer")`, a marketing message outside 8:00am-9:00pm in
     * the recipient's local time is held: the answer's `objectType` is then
     * `scheduled_message` and `scheduledAt` says when it will send.
     */
    fun send(params: SendMessageParams): Message {
        val fields = params.json().toMutableMap()
        if (fields["from"] == null) fields["from"] = toJson(client.resolveFrom())
        return client.call(
            "POST", "/messages", Message.serializer(), JsonObject(fields),
            idempotencyKey = params.idempotencyKey ?: TextKit.newIdempotencyKey(),
            retryable = true,
        )
    }

    /** Send an SMS. See [send] with [SendMessageParams] for every option. */
    @JvmOverloads
    fun send(to: String, body: String, from: String? = null, idempotencyKey: String? = null): Message =
        send(SendMessageParams(to, body).from(from).idempotencyKey(idempotencyKey))

    /** Queue a message for later (up to 30 days ahead). Not retried: there is no idempotency key on this call. */
    fun schedule(params: ScheduleMessageParams): ScheduledMessage {
        val fields = params.json().toMutableMap()
        if (fields["from"] == null) fields["from"] = toJson(client.resolveFrom())
        return client.call("POST", "/messages", ScheduledMessage.serializer(), JsonObject(fields))
    }

    /** Queue a message for [sendAt] (sent as UTC). */
    @JvmOverloads
    fun schedule(to: String, body: String, sendAt: Instant, from: String? = null): ScheduledMessage =
        schedule(ScheduleMessageParams(to, body, sendAt).from(from))

    fun get(id: String): Message = client.call("GET", "/messages/${seg(id)}", Message.serializer(), retryable = true)

    /** One page of messages, newest first. */
    @JvmOverloads
    fun list(params: ListMessagesParams = ListMessagesParams()): Page<Message> =
        client.call("GET", "/messages${params.queryString()}", Page.serializer(Message.serializer()), retryable = true)

    /** Every message matching [params], newest first, fetching pages as you iterate. */
    @JvmOverloads
    fun listAll(params: ListMessagesParams = ListMessagesParams()): Iterable<Message> =
        PagedIterable { cursor -> list(params.copyWithCursor(cursor)) }
}

/** Phone verification: send a one-time code, then check it. */
class Verify internal constructor(private val client: TextKit) {
    /**
     * Send a one-time code. You don't need to own a number. Not retried unless
     * you pass an [idempotencyKey]: a blind resend could text a second code.
     */
    @JvmOverloads
    fun send(
        to: String,
        appName: String? = null,
        from: String? = null,
        customerId: String? = null,
        idempotencyKey: String? = null,
    ): Verification = client.call(
        "POST", "/verify", Verification.serializer(),
        body("phone" to to, "app_name" to appName, "from" to from, "customer_id" to customerId),
        idempotencyKey = idempotencyKey,
        retryable = idempotencyKey != null,
    )

    /** Check a code. You are billed only when `verified` is true. */
    fun check(to: String, code: String): VerificationCheck =
        client.call("POST", "/verify/check", VerificationCheck.serializer(), body("phone" to to, "code" to code))

    fun get(id: String): Verification = client.call("GET", "/verify/${seg(id)}", Verification.serializer(), retryable = true)
}

/** Search, buy, assign and release phone numbers. */
class Numbers internal constructor(private val client: TextKit) {
    @JvmOverloads
    fun available(areaCode: String? = null): Page<AvailableNumber> = client.call(
        "GET", "/numbers/available${query("area_code" to areaCode)}",
        Page.serializer(AvailableNumber.serializer()), retryable = true,
    )

    /** Buy a number. Not retried unless you pass an [idempotencyKey]. */
    @JvmOverloads
    fun buy(
        phoneNumber: String,
        customerId: String? = null,
        registrationId: String? = null,
        idempotencyKey: String? = null,
    ): PhoneNumber = client.call(
        "POST", "/numbers", PhoneNumber.serializer(),
        body("phone_number" to phoneNumber, "customer_id" to customerId, "registration_id" to registrationId),
        idempotencyKey = idempotencyKey,
        retryable = idempotencyKey != null,
    )

    @JvmOverloads
    fun list(params: ListNumbersParams = ListNumbersParams()): Page<PhoneNumber> =
        client.call("GET", "/numbers${params.queryString()}", Page.serializer(PhoneNumber.serializer()), retryable = true)

    fun get(phoneNumber: String): PhoneNumber =
        client.call("GET", "/numbers/${seg(phoneNumber)}", PhoneNumber.serializer(), retryable = true)

    /** Assign a number to a customer, or pass null to unassign it. */
    fun update(phoneNumber: String, customerId: String?): PhoneNumber = client.call(
        "PATCH", "/numbers/${seg(phoneNumber)}", PhoneNumber.serializer(),
        body("customer_id" to customerId, keepNulls = true), retryable = true,
    )

    fun release(phoneNumber: String): PhoneNumber =
        client.call("DELETE", "/numbers/${seg(phoneNumber)}", PhoneNumber.serializer())
}

class BalanceResource internal constructor(private val client: TextKit) {
    /** Your prepaid credit balance and auto-recharge setting. */
    fun get(): Balance = client.call("GET", "/balance", Balance.serializer(), retryable = true)
}

/** Tracked links to copy anywhere. */
class Links internal constructor(private val client: TextKit) {
    /** The same url again returns the same link. */
    @JvmOverloads
    fun create(url: String, name: String? = null): TrackedLink =
        client.call("POST", "/links", TrackedLink.serializer(), body = body("url" to url, "name" to name))
}

/** Sales and sign-ups from tracked links. */
class Conversions internal constructor(private val client: TextKit) {
    /** [clickId] is the `tk` value on the landing page URL. */
    @JvmOverloads
    fun create(clickId: String, valueCents: Long? = null, name: String? = null, externalId: String? = null): Conversion =
        client.call(
            "POST", "/conversions", Conversion.serializer(),
            body = body("click_id" to clickId, "value_cents" to valueCents, "name" to name, "external_id" to externalId),
        )
}

class LookupResource internal constructor(private val client: TextKit) {
    /** Carrier and line type for a number. */
    fun phone(phoneNumber: String): Lookup =
        client.call("GET", "/lookup/${seg(phoneNumber)}", Lookup.serializer(), retryable = true)
}

/** The event log, the long-poll, and `track` for automations. */
class Events internal constructor(private val client: TextKit) {
    @JvmOverloads
    fun list(limit: Int? = null, cursor: String? = null, type: String? = null): Page<Event> = client.call(
        "GET", "/events${query("limit" to limit, "cursor" to cursor, "type" to type)}",
        Page.serializer(Event.serializer()), retryable = true,
    )

    @JvmOverloads
    fun listAll(limit: Int? = null, type: String? = null): Iterable<Event> =
        PagedIterable { cursor -> list(limit, cursor, type) }

    /**
     * Long-poll for new events. Call once with no cursor to get a cursor that
     * means "from now", then keep calling with the cursor each answer hands
     * back: the request is held until an event arrives or [timeout] seconds
     * pass (0-25, default 20). An event can be returned twice; de-duplicate by
     * `id`. Keep [timeout] below the client's own timeout (30 seconds by default).
     *
     * Java: `waitForEvents(...)` (`wait` belongs to `java.lang.Object`).
     */
    @JvmOverloads
    @JvmName("waitForEvents")
    fun wait(cursor: String? = null, timeout: Int? = null): EventWait = client.call(
        "GET", "/events/wait${query("cursor" to cursor, "timeout" to timeout)}",
        EventWait.serializer(), retryable = true,
    )

    /**
     * Tell TextKit something happened in your app. Automations listening for
     * [event] start (or move on) for that person. Pass [phone], [userId], or
     * both; a call with both links them, so later calls need only [userId].
     * Retries are safe: an Idempotency-Key is generated when you don't pass one.
     */
    @JvmOverloads
    fun track(
        event: String,
        userId: String? = null,
        phone: String? = null,
        properties: Map<String, Any?>? = null,
        idempotencyKey: String? = null,
    ): TrackedEvent = client.call(
        "POST", "/track", TrackedEvent.serializer(),
        body("event" to event, "user_id" to userId, "phone" to phone, "properties" to properties?.takeIf { it.isNotEmpty() }),
        idempotencyKey = idempotencyKey ?: TextKit.newIdempotencyKey(),
        retryable = true,
    )
}

/**
 * Webhook endpoints (where events are POSTed). Signature verification lives in
 * [WebhookSignature] and needs no client.
 *
 * [create] returns the signing `secret` once; keep it. A restricted key needs
 * the `webhooks:write` scope.
 */
class Webhooks internal constructor(private val client: TextKit) {
    fun list(): Page<WebhookEndpoint> =
        client.call("GET", "/webhooks", Page.serializer(WebhookEndpoint.serializer()), retryable = true)

    /** Register an endpoint. [events] null (or `listOf("*")`) subscribes to everything. Not retried. */
    @JvmOverloads
    fun create(url: String, events: List<String>? = null, description: String? = null): WebhookEndpoint = client.call(
        "POST", "/webhooks", WebhookEndpoint.serializer(),
        body("url" to url, "events" to events?.let { if (it == listOf("*")) "*" else it }, "description" to description),
    )

    fun get(id: String): WebhookEndpoint =
        client.call("GET", "/webhooks/${seg(id)}", WebhookEndpoint.serializer(), retryable = true)

    fun update(id: String, params: UpdateWebhookParams): WebhookEndpoint =
        client.call("PATCH", "/webhooks/${seg(id)}", WebhookEndpoint.serializer(), params.json())

    fun delete(id: String): Deleted = client.call("DELETE", "/webhooks/${seg(id)}", Deleted.serializer())
}

/** Opt-outs and opt-ins: your suppression list and each number's history. */
class Consent internal constructor(private val client: TextKit) {
    /** Your suppression list: numbers currently opted out. */
    @JvmOverloads
    fun list(limit: Int? = null, cursor: String? = null): Page<ConsentRecord> = client.call(
        "GET", "/consent${query("limit" to limit, "cursor" to cursor)}",
        Page.serializer(ConsentRecord.serializer()), retryable = true,
    )

    @JvmOverloads
    fun listAll(limit: Int? = null): Iterable<ConsentRecord> = PagedIterable { cursor -> list(limit, cursor) }

    /** Current status plus the append-only history for one number. */
    fun get(phone: String): ConsentDetail =
        client.call("GET", "/consent/${seg(phone)}", ConsentDetail.serializer(), retryable = true)

    /** Record an opt-out from your own system (CRM, web form, support tool). */
    @JvmOverloads
    fun optOut(phone: String, note: String? = null): ConsentRecord = client.call(
        "POST", "/consent/${seg(phone)}", ConsentRecord.serializer(),
        body("status" to "opted_out", "note" to note), retryable = true,
    )

    /**
     * Record a fresh opt-in. Only with the recipient's consent.
     *
     * [campaignId] (a registration id) records it for that registration. An
     * opt-in for a marketing or mixed registration must carry [proof]
     * (`source`, `collected_at`, and `page_url` or `message_id`), and so must
     * one for a number that opted out (409 otherwise).
     */
    @JvmOverloads
    fun optIn(phone: String, note: String? = null, campaignId: String? = null, proof: Map<String, Any?>? = null): ConsentRecord =
        client.call(
            "POST", "/consent/${seg(phone)}", ConsentRecord.serializer(),
            body("status" to "opted_in", "note" to note, "campaign_id" to campaignId, "proof" to proof),
            retryable = true,
        )

    /** Bulk-import opt-outs (up to 500 per call). Java: `importNumbers`. */
    @JvmName("importNumbers")
    fun import(phoneNumbers: List<String>): ConsentImport = client.call(
        "POST", "/consent/import", ConsentImport.serializer(), body("phone_numbers" to phoneNumbers), retryable = true,
    )

    /** The suppression list (or, with `type = "ledger"`, every consent change) as CSV text. */
    @JvmOverloads
    fun export(type: String? = null): String = client.callText("GET", "/consent/export${query("type" to type)}", retryable = true)
}

/** The businesses you send on behalf of (for platforms). Entirely optional. */
class Customers internal constructor(private val client: TextKit) {
    @JvmOverloads
    fun create(name: String? = null, externalId: String? = null, metadata: Map<String, String>? = null): Customer = client.call(
        "POST", "/customers", Customer.serializer(),
        body("name" to name, "external_id" to externalId, "metadata" to metadata?.takeIf { it.isNotEmpty() }),
    )

    fun get(id: String): Customer = client.call("GET", "/customers/${seg(id)}", Customer.serializer(), retryable = true)

    /** Change only the fields you set; null clears one. `metadata` replaces the whole object. */
    fun update(id: String, params: UpdateCustomerParams): Customer =
        client.call("PATCH", "/customers/${seg(id)}", Customer.serializer(), params.json(), retryable = true)

    /** Delete a customer. Its numbers stay yours, unassigned. */
    fun delete(id: String): Deleted = client.call("DELETE", "/customers/${seg(id)}", Deleted.serializer())

    @JvmOverloads
    fun list(limit: Int? = null, cursor: String? = null, externalId: String? = null): Page<Customer> = client.call(
        "GET", "/customers${query("limit" to limit, "cursor" to cursor, "external_id" to externalId)}",
        Page.serializer(Customer.serializer()), retryable = true,
    )

    @JvmOverloads
    fun listAll(limit: Int? = null): Iterable<Customer> = PagedIterable { cursor -> list(limit, cursor) }

    /**
     * Usage for a UTC date range (`YYYY-MM-DD`; default this month to date).
     * Follows the key: test keys report sandbox traffic, live keys live.
     */
    @JvmOverloads
    fun usage(id: String, start: String? = null, end: String? = null): CustomerUsage = client.call(
        "GET", "/customers/${seg(id)}/usage${query("start" to start, "end" to end)}",
        CustomerUsage.serializer(), retryable = true,
    )
}

/** The address book. One contact per phone number; tags double as broadcast audiences. */
class Contacts internal constructor(private val client: TextKit) {
    /** Create a contact, or update the one that already has this number. Values you leave out are kept; tags are added. */
    fun upsert(params: ContactParams): Contact =
        client.call("POST", "/contacts", Contact.serializer(), params.json(), retryable = true)

    @JvmOverloads
    fun upsert(phoneNumber: String, name: String? = null, tags: List<String>? = null): Contact =
        upsert(ContactParams(phoneNumber).name(name).tags(tags))

    /** Upsert up to 500 contacts in one call. Java: `importContacts`. */
    @JvmName("importContacts")
    fun import(contacts: List<ContactParams>): ContactImport = client.call(
        "POST", "/contacts/import", ContactImport.serializer(),
        body("contacts" to contacts.map { it.json() }), retryable = true,
    )

    /** Consent for a phone number. Same as `consent.get(phoneNumber)`. */
    fun consent(phoneNumber: String): ConsentDetail = client.consent.get(phoneNumber)

    /** Apply `add_tags`, `remove_tags` or `delete` to up to 500 contact ids in one call. */
    @JvmOverloads
    fun bulk(action: String, ids: List<String>, tags: List<String>? = null): ContactBulk = client.call(
        "POST", "/contacts/bulk", ContactBulk.serializer(), body("action" to action, "ids" to ids, "tags" to tags),
    )

    fun get(id: String): Contact = client.call("GET", "/contacts/${seg(id)}", Contact.serializer(), retryable = true)

    fun update(id: String, params: UpdateContactParams): Contact =
        client.call("PATCH", "/contacts/${seg(id)}", Contact.serializer(), params.json(), retryable = true)

    fun delete(id: String): Deleted = client.call("DELETE", "/contacts/${seg(id)}", Deleted.serializer())

    /** Newest first. */
    @JvmOverloads
    fun list(params: ListContactsParams = ListContactsParams()): Page<Contact> =
        client.call("GET", "/contacts${params.queryString()}", Page.serializer(Contact.serializer()), retryable = true)

    @JvmOverloads
    fun listAll(params: ListContactsParams = ListContactsParams()): Iterable<Contact> =
        PagedIterable { cursor -> list(params.copyWithCursor(cursor)) }
}

/** Event-driven flows: a trigger event, then send / wait / branch steps. */
class Automations internal constructor(private val client: TextKit) {
    /** Create a flow as a draft. `issues` on the result lists what stops it from running. */
    fun create(params: CreateAutomationParams): Automation =
        client.call("POST", "/automations", Automation.serializer(), params.json())

    fun get(id: String): Automation = client.call("GET", "/automations/${seg(id)}", Automation.serializer(), retryable = true)

    fun list(): Page<Automation> =
        client.call("GET", "/automations", Page.serializer(Automation.serializer()), retryable = true)

    /** Change only the fields you set. Editing an active flow publishes a new version. */
    fun update(id: String, params: UpdateAutomationParams): Automation =
        client.call("PATCH", "/automations/${seg(id)}", Automation.serializer(), params.json())

    /** Delete a flow. Runs in progress stop; nothing more is sent. */
    fun delete(id: String): Deleted = client.call("DELETE", "/automations/${seg(id)}", Deleted.serializer())

    /** Turn a flow on. Throws `invalid_request` when it is not ready. */
    fun activate(id: String): Automation =
        client.call("POST", "/automations/${seg(id)}/activate", Automation.serializer(), retryable = true)

    /** Stop new runs and hold the ones in progress until it is activated again. */
    fun pause(id: String): Automation =
        client.call("POST", "/automations/${seg(id)}/pause", Automation.serializer(), retryable = true)

    /** Runs of one flow, newest first. */
    @JvmOverloads
    fun runs(id: String, limit: Int? = null, cursor: String? = null): Page<AutomationRun> = client.call(
        "GET", "/automations/${seg(id)}/runs${query("limit" to limit, "cursor" to cursor)}",
        Page.serializer(AutomationRun.serializer()), retryable = true,
    )

    @JvmOverloads
    fun runsAll(id: String, limit: Int? = null): Iterable<AutomationRun> = PagedIterable { cursor -> runs(id, limit, cursor) }

    fun run(id: String, runId: String): AutomationRun =
        client.call("GET", "/automations/${seg(id)}/runs/${seg(runId)}", AutomationRun.serializer(), retryable = true)

    /** Cancel a run in progress. */
    fun cancelRun(id: String, runId: String): AutomationRun =
        client.call("DELETE", "/automations/${seg(id)}/runs/${seg(runId)}", AutomationRun.serializer())
}

/**
 * Recurring schedules: one message to one number on a repeating local time.
 * Each occurrence is a normal send (opt-outs, quota and spend limit are
 * checked when it fires) and a normal message with `scheduleId`.
 */
class Schedules internal constructor(private val client: TextKit) {
    /** Create a schedule. Retries are safe: an Idempotency-Key is generated when you don't set one. */
    fun create(params: CreateScheduleParams): Schedule {
        val fields = params.json().toMutableMap()
        if (fields["from"] == null) client.configuredFrom?.let { fields["from"] = toJson(it) }
        return client.call(
            "POST", "/schedules", Schedule.serializer(), JsonObject(fields),
            idempotencyKey = params.idempotencyKey ?: TextKit.newIdempotencyKey(),
            retryable = true,
        )
    }

    @JvmOverloads
    fun create(to: String, body: String, repeat: ScheduleRepeat, from: String? = null): Schedule =
        create(CreateScheduleParams(to, body, repeat).from(from))

    /** One schedule, with its `recentOccurrences`. */
    fun get(id: String): Schedule = client.call("GET", "/schedules/${seg(id)}", Schedule.serializer(), retryable = true)

    fun list(): Page<Schedule> = client.call("GET", "/schedules", Page.serializer(Schedule.serializer()), retryable = true)

    fun update(id: String, params: UpdateScheduleParams): Schedule =
        client.call("PATCH", "/schedules/${seg(id)}", Schedule.serializer(), params.json(), retryable = true)

    /** Stop sending until resumed. */
    fun pause(id: String): Schedule = update(id, UpdateScheduleParams().active(false))

    /** Start again from now: nothing that came due while paused is sent. */
    fun resume(id: String): Schedule = update(id, UpdateScheduleParams().active(true))

    /** Stop it for good. Messages it already sent stay in the message log. */
    fun delete(id: String): Deleted = client.call("DELETE", "/schedules/${seg(id)}", Deleted.serializer())
}

/**
 * Brand and campaign registrations (business texting).
 *
 * [create] runs the website and example checks; [recheck] corrects and re-runs
 * them; [submit] files a ready registration. The first submit for a business
 * carries the [Attestation] signed by someone authorized to act for it.
 */
class Registrations internal constructor(private val client: TextKit) {
    /** Needs `businessName`, `website` and `useCase`. Runs the website check right away. */
    fun create(params: RegistrationParams): Registration {
        for ((name, label) in listOf("business_name" to "businessName", "website" to "website", "use_case" to "useCase")) {
            if (params.fields[name] == null) {
                throw TextKitException("Set $label on the registration.", code = "invalid_request", status = 0, param = name)
            }
        }
        return client.call("POST", "/registrations", Registration.serializer(), params.json())
    }

    fun get(id: String): Registration =
        client.call("GET", "/registrations/${seg(id)}", Registration.serializer(), retryable = true)

    fun list(): Page<Registration> =
        client.call("GET", "/registrations", Page.serializer(Registration.serializer()), retryable = true)

    /** Correct any field and re-run the checks (draft, checks_failed, ready or rejected). */
    @JvmOverloads
    fun recheck(id: String, params: RegistrationParams = RegistrationParams()): Registration =
        client.call("POST", "/registrations/${seg(id)}/recheck", Registration.serializer(), params.json())

    /**
     * Submit a ready registration (or resubmit after a rejection).
     *
     * [feesAcknowledged] must be true: it confirms the registration fee terms
     * (carrier registration fees are billed at the registry's charge, a campaign carries a
     * 3-month minimum, and the fees are non-refundable even if the
     * registration is rejected). Pass [attestation] the first time for a business.
     */
    @JvmOverloads
    fun submit(id: String, feesAcknowledged: Boolean, attestation: Attestation? = null): Registration = client.call(
        "POST", "/registrations/${seg(id)}/submit", Registration.serializer(),
        body("attestation" to attestation, "fees_acknowledged" to feesAcknowledged),
    )

    /** The filed copies, oldest first: exactly what each submission sent. */
    fun submissions(id: String): Page<RegistrationSubmission> = client.call(
        "GET", "/registrations/${seg(id)}/submissions",
        Page.serializer(RegistrationSubmission.serializer()), retryable = true,
    )
}
