import Foundation

private func str(_ s: String?) -> JSONValue? { s.map(JSONValue.string) }
private func int(_ i: Int?) -> JSONValue? { i.map { .int(Int64($0)) } }
private func strings(_ a: [String]?) -> JSONValue? { a.map { JSONValue($0) } }

/// `2026-10-02T09:30:00Z`. A formatter per call: ISO8601DateFormatter is not Sendable.
private func isoUTC(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: date)
}

// MARK: - Messages

/// Send and look up text messages.
public struct Messages: Sendable {
    let client: TextKit

    /// Send an SMS.
    ///
    /// `from` defaults to the client's `defaultFrom`, else your account's only
    /// number (looked up once). Retries are safe: an Idempotency-Key is
    /// generated when you don't pass one, so a network blip can never double-send.
    ///
    /// `category` (`marketing`, `transactional`, `otp`) can make a message
    /// stricter, never looser. Only marketing messages are held or refused
    /// outside 8:00am-9:00pm in the recipient's local time; `quietHours` says
    /// which: `block` throws `quiet_hours` (with `sendAfter`), `defer` holds it
    /// and the answer's `object` is `scheduled_message`.
    ///
    /// `consent` (`["source": "checkout", "collected_at": "..."]`) records how
    /// the recipient agreed, for a recurring non-marketing message from a
    /// registered number with no opt-in on file yet.
    @discardableResult
    public func send(
        to: String,
        body: String,
        from: String? = nil,
        customerId: String? = nil,
        category: String? = nil,
        quietHours: String? = nil,
        consent: JSONValue? = nil,
        media: [String]? = nil,
        idempotencyKey: String? = nil
    ) async throws -> Message {
        var b = Body()
        b["to"] = .string(to)
        b["body"] = .string(body)
        let sender = try await resolvedFrom(from)
        b["from"] = .string(sender)
        b["customer_id"] = str(customerId)
        b["category"] = str(category)
        b["quiet_hours"] = str(quietHours)
        b["consent"] = consent
        b["media"] = strings(media)
        return try await client.call(
            "POST", "/messages", body: b.json,
            idempotencyKey: idempotencyKey ?? TextKit.newIdempotencyKey(), retryable: true
        )
    }

    /// Queue a message for later (up to 30 days ahead). Not retried: there is
    /// no idempotency key on this call.
    @discardableResult
    public func schedule(
        to: String,
        body: String,
        sendAt: Date,
        from: String? = nil,
        customerId: String? = nil,
        category: String? = nil,
        quietHours: String? = nil
    ) async throws -> ScheduledMessage {
        try await schedule(
            to: to, body: body, sendAt: isoUTC(sendAt), from: from,
            customerId: customerId, category: category, quietHours: quietHours
        )
    }

    /// Queue a message for `sendAt`, an ISO 8601 timestamp.
    @discardableResult
    public func schedule(
        to: String,
        body: String,
        sendAt: String,
        from: String? = nil,
        customerId: String? = nil,
        category: String? = nil,
        quietHours: String? = nil
    ) async throws -> ScheduledMessage {
        var b = Body()
        b["to"] = .string(to)
        b["body"] = .string(body)
        b["scheduled_at"] = .string(sendAt)
        let sender = try await resolvedFrom(from)
        b["from"] = .string(sender)
        b["customer_id"] = str(customerId)
        b["category"] = str(category)
        b["quiet_hours"] = str(quietHours)
        return try await client.call("POST", "/messages", body: b.json)
    }

    public func get(_ id: String) async throws -> Message {
        try await client.call("GET", "/messages/\(seg(id))", retryable: true)
    }

    /// One page of messages, newest first. `scheduleId` keeps only the
    /// occurrences of one recurring schedule; `status: "blocked"` lists the
    /// sends a check refused.
    public func list(
        limit: Int? = nil,
        cursor: String? = nil,
        number: String? = nil,
        to: String? = nil,
        from: String? = nil,
        status: String? = nil,
        blockedReason: String? = nil,
        failureCode: String? = nil,
        direction: String? = nil,
        createdAfter: String? = nil,
        createdBefore: String? = nil,
        customerId: String? = nil,
        scheduleId: String? = nil
    ) async throws -> Page<Message> {
        let q = query([
            ("limit", limit), ("cursor", cursor), ("number", number), ("to", to), ("from", from), ("status", status),
            ("blocked_reason", blockedReason), ("failure_code", failureCode), ("direction", direction),
            ("created_after", createdAfter), ("created_before", createdBefore), ("customer_id", customerId),
            ("schedule_id", scheduleId),
        ])
        return try await client.call("GET", "/messages\(q)", retryable: true)
    }

    /// Every message matching the filters, newest first, fetching pages as you iterate.
    public func listAll(
        limit: Int? = nil,
        number: String? = nil,
        status: String? = nil,
        customerId: String? = nil,
        scheduleId: String? = nil
    ) -> AutoPager<Message> {
        let s = self
        return AutoPager { cursor in
            try await s.list(limit: limit, cursor: cursor, number: number, status: status, customerId: customerId, scheduleId: scheduleId)
        }
    }

    private func resolvedFrom(_ from: String?) async throws -> String {
        if let from, !from.isEmpty { return from }
        return try await client.resolveFrom()
    }
}

// MARK: - Verify

/// Phone verification: send a one-time code, then check it.
public struct Verify: Sendable {
    let client: TextKit

    /// Send a one-time code. You don't need to own a number. Not retried unless
    /// you pass an `idempotencyKey`: a blind resend could text a second code.
    @discardableResult
    public func send(
        to: String,
        appName: String? = nil,
        from: String? = nil,
        customerId: String? = nil,
        idempotencyKey: String? = nil
    ) async throws -> Verification {
        var b = Body()
        b["phone"] = .string(to)
        b["app_name"] = str(appName)
        b["from"] = str(from)
        b["customer_id"] = str(customerId)
        return try await client.call(
            "POST", "/verify", body: b.json, idempotencyKey: idempotencyKey, retryable: idempotencyKey != nil
        )
    }

    /// Check a code. You are billed only when `verified` is true.
    public func check(to: String, code: String) async throws -> VerificationCheck {
        try await client.call("POST", "/verify/check", body: ["phone": .string(to), "code": .string(code)])
    }

    public func get(_ id: String) async throws -> Verification {
        try await client.call("GET", "/verify/\(seg(id))", retryable: true)
    }
}

// MARK: - Numbers

/// Search, buy, assign and release phone numbers.
public struct Numbers: Sendable {
    let client: TextKit

    public func available(areaCode: String? = nil) async throws -> Page<AvailableNumber> {
        try await client.call("GET", "/numbers/available\(query([("area_code", areaCode)]))", retryable: true)
    }

    /// Buy a number. Not retried unless you pass an `idempotencyKey`.
    @discardableResult
    public func buy(
        _ phoneNumber: String,
        customerId: String? = nil,
        registrationId: String? = nil,
        idempotencyKey: String? = nil
    ) async throws -> PhoneNumber {
        var b = Body()
        b["phone_number"] = .string(phoneNumber)
        b["customer_id"] = str(customerId)
        b["registration_id"] = str(registrationId)
        return try await client.call(
            "POST", "/numbers", body: b.json, idempotencyKey: idempotencyKey, retryable: idempotencyKey != nil
        )
    }

    public func list(
        customerId: String? = nil,
        tag: String? = nil,
        pool: String? = nil,
        mode: String? = nil,
        q search: String? = nil
    ) async throws -> Page<PhoneNumber> {
        let q = query([("customer_id", customerId), ("tag", tag), ("pool", pool), ("mode", mode), ("q", search)])
        return try await client.call("GET", "/numbers\(q)", retryable: true)
    }

    public func get(_ phoneNumber: String) async throws -> PhoneNumber {
        try await client.call("GET", "/numbers/\(seg(phoneNumber))", retryable: true)
    }

    /// Assign a number to a customer, or pass nil to unassign it.
    @discardableResult
    public func update(_ phoneNumber: String, customerId: String?) async throws -> PhoneNumber {
        try await client.call(
            "PATCH", "/numbers/\(seg(phoneNumber))", body: ["customer_id": customerId.map(JSONValue.string) ?? .null],
            retryable: true
        )
    }

    @discardableResult
    public func release(_ phoneNumber: String) async throws -> PhoneNumber {
        try await client.call("DELETE", "/numbers/\(seg(phoneNumber))")
    }
}

// MARK: - Balance and lookup

public struct BalanceResource: Sendable {
    let client: TextKit

    /// Your prepaid credit balance and auto-recharge setting.
    public func get() async throws -> Balance {
        try await client.call("GET", "/balance", retryable: true)
    }
}

/// Tracked links to copy anywhere.
public struct LinksResource: Sendable {
    let client: TextKit

    /// The same url again returns the same link.
    public func create(url: String, name: String? = nil) async throws -> TrackedLink {
        var b = Body()
        b["url"] = .string(url)
        b["name"] = str(name)
        return try await client.call("POST", "/links", body: b.json)
    }
}

/// Sales and sign-ups from tracked links.
public struct ConversionsResource: Sendable {
    let client: TextKit

    /// `clickId` is the `tk` value on the landing page URL.
    public func create(clickId: String, valueCents: Int? = nil, name: String? = nil, externalId: String? = nil) async throws -> Conversion {
        var b = Body()
        b["click_id"] = .string(clickId)
        b["value_cents"] = int(valueCents)
        b["name"] = str(name)
        b["external_id"] = str(externalId)
        return try await client.call("POST", "/conversions", body: b.json)
    }
}

public struct LookupResource: Sendable {
    let client: TextKit

    /// Carrier and line type for a number.
    public func phone(_ phoneNumber: String) async throws -> Lookup {
        try await client.call("GET", "/lookup/\(seg(phoneNumber))", retryable: true)
    }
}

// MARK: - Events

/// The event log, the long-poll, and `track` for automations.
public struct Events: Sendable {
    let client: TextKit

    public func list(limit: Int? = nil, cursor: String? = nil, type: String? = nil) async throws -> Page<Event> {
        try await client.call("GET", "/events\(query([("limit", limit), ("cursor", cursor), ("type", type)]))", retryable: true)
    }

    public func listAll(limit: Int? = nil, type: String? = nil) -> AutoPager<Event> {
        let s = self
        return AutoPager { cursor in try await s.list(limit: limit, cursor: cursor, type: type) }
    }

    /// Long-poll for new events. Call once with no cursor to get a cursor that
    /// means "from now", then keep calling with the cursor each answer hands
    /// back: the request is held until an event arrives or `timeout` seconds
    /// pass (0-25, default 20). An event can be returned twice; de-duplicate by
    /// `id`. Keep `timeout` below the client's own timeout (30 seconds by default).
    public func wait(cursor: String? = nil, timeout: Int? = nil) async throws -> EventWait {
        try await client.call("GET", "/events/wait\(query([("cursor", cursor), ("timeout", timeout)]))", retryable: true)
    }

    /// Tell TextKit something happened in your app. Automations listening for
    /// the event start (or move on) for that person. Pass `phone`, `userId`, or
    /// both; a call with both links them, so later calls need only `userId`.
    /// Retries are safe: an Idempotency-Key is generated when you don't pass one.
    @discardableResult
    public func track(
        _ event: String,
        userId: String? = nil,
        phone: String? = nil,
        properties: [String: JSONValue]? = nil,
        idempotencyKey: String? = nil
    ) async throws -> TrackedEvent {
        var b = Body()
        b["event"] = .string(event)
        b["user_id"] = str(userId)
        b["phone"] = str(phone)
        if let properties, !properties.isEmpty { b["properties"] = .object(properties) }
        return try await client.call(
            "POST", "/track", body: b.json, idempotencyKey: idempotencyKey ?? TextKit.newIdempotencyKey(), retryable: true
        )
    }
}

// MARK: - Webhooks

/// Webhook endpoints (where events are POSTed). Signature verification lives
/// in ``WebhookSignature`` and needs no client.
///
/// `create` returns the signing `secret` once; keep it. A restricted key needs
/// the `webhooks:write` scope.
public struct Webhooks: Sendable {
    let client: TextKit

    public func list() async throws -> Page<WebhookEndpoint> {
        try await client.call("GET", "/webhooks", retryable: true)
    }

    /// Register an endpoint. `events` nil (or `["*"]`) subscribes to everything. Not retried.
    public func create(url: String, events: [String]? = nil, description: String? = nil) async throws -> WebhookEndpoint {
        var b = Body()
        b["url"] = .string(url)
        b["events"] = events.map(Webhooks.eventsJSON)
        b["description"] = str(description)
        return try await client.call("POST", "/webhooks", body: b.json)
    }

    public func get(_ id: String) async throws -> WebhookEndpoint {
        try await client.call("GET", "/webhooks/\(seg(id))", retryable: true)
    }

    /// Change any of `url`, `events`, `active` (`false` pauses delivery) or
    /// `description` (`.clear` removes it). Only what you pass is sent.
    public func update(
        _ id: String,
        url: String? = nil,
        events: [String]? = nil,
        active: Bool? = nil,
        description: Clearable<String>? = nil
    ) async throws -> WebhookEndpoint {
        var b = Body()
        b["url"] = str(url)
        b["events"] = events.map(Webhooks.eventsJSON)
        b["active"] = active.map(JSONValue.bool)
        b.set("description", description, JSONValue.string)
        return try await client.call("PATCH", "/webhooks/\(seg(id))", body: b.json)
    }

    @discardableResult
    public func delete(_ id: String) async throws -> Deleted {
        try await client.call("DELETE", "/webhooks/\(seg(id))")
    }

    static func eventsJSON(_ events: [String]) -> JSONValue {
        events == ["*"] ? "*" : JSONValue(events)
    }
}

// MARK: - Consent

/// Opt-outs and opt-ins: your suppression list and each number's history.
public struct Consent: Sendable {
    let client: TextKit

    /// Your suppression list: numbers currently opted out.
    public func list(limit: Int? = nil, cursor: String? = nil) async throws -> Page<ConsentRecord> {
        try await client.call("GET", "/consent\(query([("limit", limit), ("cursor", cursor)]))", retryable: true)
    }

    public func listAll(limit: Int? = nil) -> AutoPager<ConsentRecord> {
        let s = self
        return AutoPager { cursor in try await s.list(limit: limit, cursor: cursor) }
    }

    /// Current status plus the append-only history for one number.
    public func get(_ phone: String) async throws -> ConsentDetail {
        try await client.call("GET", "/consent/\(seg(phone))", retryable: true)
    }

    /// Record an opt-out from your own system (CRM, web form, support tool).
    @discardableResult
    public func optOut(_ phone: String, note: String? = nil) async throws -> ConsentRecord {
        var b = Body()
        b["status"] = "opted_out"
        b["note"] = str(note)
        return try await client.call("POST", "/consent/\(seg(phone))", body: b.json, retryable: true)
    }

    /// Record a fresh opt-in. Only with the recipient's consent.
    ///
    /// `campaignId` (a registration id) records it for that registration. An
    /// opt-in for a marketing or mixed registration must carry `proof`
    /// (`source`, `collected_at`, and `page_url` or `message_id`), and so must
    /// one for a number that opted out (409 otherwise).
    @discardableResult
    public func optIn(
        _ phone: String,
        note: String? = nil,
        campaignId: String? = nil,
        proof: JSONValue? = nil
    ) async throws -> ConsentRecord {
        var b = Body()
        b["status"] = "opted_in"
        b["note"] = str(note)
        b["campaign_id"] = str(campaignId)
        b["proof"] = proof
        return try await client.call("POST", "/consent/\(seg(phone))", body: b.json, retryable: true)
    }

    /// Bulk-import opt-outs (up to 500 per call).
    @discardableResult
    public func `import`(_ phoneNumbers: [String]) async throws -> ConsentImport {
        try await client.call("POST", "/consent/import", body: ["phone_numbers": JSONValue(phoneNumbers)], retryable: true)
    }

    /// The suppression list (or, with `type: "ledger"`, every consent change) as CSV text.
    public func export(type: String? = nil) async throws -> String {
        try await client.callText("/consent/export\(query([("type", type)]))")
    }
}

// MARK: - Customers

/// The businesses you send on behalf of (for platforms). Entirely optional.
public struct Customers: Sendable {
    let client: TextKit

    public func create(name: String? = nil, externalId: String? = nil, metadata: [String: String]? = nil) async throws -> Customer {
        var b = Body()
        b["name"] = str(name)
        b["external_id"] = str(externalId)
        if let metadata, !metadata.isEmpty { b["metadata"] = JSONValue(metadata) }
        return try await client.call("POST", "/customers", body: b.json)
    }

    public func get(_ id: String) async throws -> Customer {
        try await client.call("GET", "/customers/\(seg(id))", retryable: true)
    }

    /// Change only what you pass; `.clear` removes a value. `metadata` replaces the whole object.
    public func update(
        _ id: String,
        name: Clearable<String>? = nil,
        externalId: Clearable<String>? = nil,
        metadata: Clearable<[String: String]>? = nil
    ) async throws -> Customer {
        var b = Body()
        b.set("name", name, JSONValue.string)
        b.set("external_id", externalId, JSONValue.string)
        b.set("metadata", metadata) { JSONValue($0) }
        return try await client.call("PATCH", "/customers/\(seg(id))", body: b.json, retryable: true)
    }

    /// Delete a customer. Its numbers stay yours, unassigned.
    @discardableResult
    public func delete(_ id: String) async throws -> Deleted {
        try await client.call("DELETE", "/customers/\(seg(id))")
    }

    public func list(limit: Int? = nil, cursor: String? = nil, externalId: String? = nil) async throws -> Page<Customer> {
        try await client.call(
            "GET", "/customers\(query([("limit", limit), ("cursor", cursor), ("external_id", externalId)]))", retryable: true
        )
    }

    public func listAll(limit: Int? = nil) -> AutoPager<Customer> {
        let s = self
        return AutoPager { cursor in try await s.list(limit: limit, cursor: cursor) }
    }

    /// Usage for a UTC date range (`YYYY-MM-DD`; default this month to date).
    /// Follows the key: test keys report sandbox traffic, live keys live.
    public func usage(_ id: String, start: String? = nil, end: String? = nil) async throws -> CustomerUsage {
        try await client.call("GET", "/customers/\(seg(id))/usage\(query([("start", start), ("end", end)]))", retryable: true)
    }
}

// MARK: - Contacts

/// The address book. One contact per phone number; tags double as broadcast audiences.
public struct Contacts: Sendable {
    let client: TextKit

    /// Create a contact, or update the one that already has this number.
    /// Values you leave out are kept; tags are added, never removed.
    @discardableResult
    public func upsert(_ contact: ContactInput) async throws -> Contact {
        try await client.call("POST", "/contacts", body: contact.json, retryable: true)
    }

    @discardableResult
    public func upsert(
        phoneNumber: String,
        name: String? = nil,
        tags: [String]? = nil,
        fields: [String: String]? = nil,
        notes: String? = nil
    ) async throws -> Contact {
        try await upsert(ContactInput(phoneNumber: phoneNumber, name: name, tags: tags, fields: fields, notes: notes))
    }

    /// Upsert up to 500 contacts in one call.
    @discardableResult
    public func `import`(_ contacts: [ContactInput]) async throws -> ContactImport {
        try await client.call("POST", "/contacts/import", body: ["contacts": .array(contacts.map(\.json))], retryable: true)
    }

    /// Consent for a phone number. Same as `consent.get(_:)`.
    public func consent(_ phoneNumber: String) async throws -> ConsentDetail {
        try await client.consent.get(phoneNumber)
    }

    /// Apply `add_tags`, `remove_tags` or `delete` to up to 500 contact ids in one call.
    public func bulk(action: String, ids: [String], tags: [String]? = nil) async throws -> ContactBulk {
        var b = Body()
        b["action"] = .string(action)
        b["ids"] = JSONValue(ids)
        b["tags"] = strings(tags)
        return try await client.call("POST", "/contacts/bulk", body: b.json)
    }

    public func get(_ id: String) async throws -> Contact {
        try await client.call("GET", "/contacts/\(seg(id))", retryable: true)
    }

    /// Change only what you pass. `tags` and `fields` replace what is stored;
    /// `.clear` removes `name`, `notes` and the other text fields.
    public func update(
        _ id: String,
        phoneNumber: String? = nil,
        name: Clearable<String>? = nil,
        firstName: Clearable<String>? = nil,
        lastName: Clearable<String>? = nil,
        email: Clearable<String>? = nil,
        company: Clearable<String>? = nil,
        tags: [String]? = nil,
        fields: [String: String]? = nil,
        notes: Clearable<String>? = nil
    ) async throws -> Contact {
        var b = Body()
        b["phone_number"] = str(phoneNumber)
        b.set("name", name, JSONValue.string)
        b.set("first_name", firstName, JSONValue.string)
        b.set("last_name", lastName, JSONValue.string)
        b.set("email", email, JSONValue.string)
        b.set("company", company, JSONValue.string)
        b["tags"] = strings(tags)
        b["fields"] = fields.map { JSONValue($0) }
        b.set("notes", notes, JSONValue.string)
        return try await client.call("PATCH", "/contacts/\(seg(id))", body: b.json, retryable: true)
    }

    @discardableResult
    public func delete(_ id: String) async throws -> Deleted {
        try await client.call("DELETE", "/contacts/\(seg(id))")
    }

    /// Newest first. `phoneNumber` finds the one contact holding it.
    public func list(
        limit: Int? = nil,
        cursor: String? = nil,
        tag: String? = nil,
        phoneNumber: String? = nil,
        segmentId: String? = nil,
        q search: String? = nil
    ) async throws -> Page<Contact> {
        let q = query([
            ("limit", limit), ("cursor", cursor), ("tag", tag), ("phone_number", phoneNumber),
            ("segment_id", segmentId), ("q", search),
        ])
        return try await client.call("GET", "/contacts\(q)", retryable: true)
    }

    public func listAll(limit: Int? = nil, tag: String? = nil, segmentId: String? = nil) -> AutoPager<Contact> {
        let s = self
        return AutoPager { cursor in try await s.list(limit: limit, cursor: cursor, tag: tag, segmentId: segmentId) }
    }
}

// MARK: - Automations

/// Event-driven flows: a trigger event, then send / wait / branch steps.
public struct Automations: Sendable {
    let client: TextKit

    /// Create a flow as a draft. `issues` on the result lists what stops it from running.
    public func create(
        name: String,
        trigger: JSONValue,
        steps: [JSONValue],
        from: String? = nil,
        topicId: String? = nil
    ) async throws -> Automation {
        var b = Body()
        b["name"] = .string(name)
        b["trigger"] = trigger
        b["steps"] = .array(steps)
        b["from"] = str(from)
        b["topic_id"] = str(topicId)
        return try await client.call("POST", "/automations", body: b.json)
    }

    public func get(_ id: String) async throws -> Automation {
        try await client.call("GET", "/automations/\(seg(id))", retryable: true)
    }

    public func list() async throws -> Page<Automation> {
        try await client.call("GET", "/automations", retryable: true)
    }

    /// Change only what you pass. Editing an active flow publishes a new version.
    public func update(
        _ id: String,
        name: String? = nil,
        trigger: JSONValue? = nil,
        steps: [JSONValue]? = nil,
        from: Clearable<String>? = nil,
        topicId: Clearable<String>? = nil
    ) async throws -> Automation {
        var b = Body()
        b["name"] = str(name)
        b["trigger"] = trigger
        b["steps"] = steps.map(JSONValue.array)
        b.set("from", from, JSONValue.string)
        b.set("topic_id", topicId, JSONValue.string)
        return try await client.call("PATCH", "/automations/\(seg(id))", body: b.json)
    }

    /// Delete a flow. Runs in progress stop; nothing more is sent.
    @discardableResult
    public func delete(_ id: String) async throws -> Deleted {
        try await client.call("DELETE", "/automations/\(seg(id))")
    }

    /// Turn a flow on. Throws `invalid_request` when it is not ready.
    @discardableResult
    public func activate(_ id: String) async throws -> Automation {
        try await client.call("POST", "/automations/\(seg(id))/activate", retryable: true)
    }

    /// Stop new runs and hold the ones in progress until it is activated again.
    @discardableResult
    public func pause(_ id: String) async throws -> Automation {
        try await client.call("POST", "/automations/\(seg(id))/pause", retryable: true)
    }

    /// Runs of one flow, newest first.
    public func runs(_ id: String, limit: Int? = nil, cursor: String? = nil) async throws -> Page<AutomationRun> {
        try await client.call("GET", "/automations/\(seg(id))/runs\(query([("limit", limit), ("cursor", cursor)]))", retryable: true)
    }

    public func runsAll(_ id: String, limit: Int? = nil) -> AutoPager<AutomationRun> {
        let s = self
        return AutoPager { cursor in try await s.runs(id, limit: limit, cursor: cursor) }
    }

    public func run(_ id: String, runId: String) async throws -> AutomationRun {
        try await client.call("GET", "/automations/\(seg(id))/runs/\(seg(runId))", retryable: true)
    }

    /// Cancel a run in progress.
    @discardableResult
    public func cancelRun(_ id: String, runId: String) async throws -> AutomationRun {
        try await client.call("DELETE", "/automations/\(seg(id))/runs/\(seg(runId))")
    }
}

// MARK: - Schedules

/// Recurring schedules: one message to one number on a repeating local time.
/// Each occurrence is a normal send (opt-outs, quota and spend limit are
/// checked when it fires) and a normal message with `scheduleId`.
public struct Schedules: Sendable {
    let client: TextKit

    /// Create a schedule. `from` falls back to the client's `defaultFrom`;
    /// left out entirely, the API uses your account's one number. Retries are
    /// safe: an Idempotency-Key is generated when you don't pass one.
    public func create(
        to: String,
        body: String,
        repeat: ScheduleRepeat,
        from: String? = nil,
        startDate: String? = nil,
        endDate: String? = nil,
        maxOccurrences: Int? = nil,
        category: String? = nil,
        quietHours: String? = nil,
        idempotencyKey: String? = nil
    ) async throws -> Schedule {
        var b = Body()
        b["to"] = .string(to)
        b["body"] = .string(body)
        b["repeat"] = `repeat`.json
        var sender = from
        if sender == nil { sender = await client.defaultFrom.current }
        b["from"] = str(sender)
        b["start_date"] = str(startDate)
        b["end_date"] = str(endDate)
        b["max_occurrences"] = int(maxOccurrences)
        b["category"] = str(category)
        b["quiet_hours"] = str(quietHours)
        return try await client.call(
            "POST", "/schedules", body: b.json,
            idempotencyKey: idempotencyKey ?? TextKit.newIdempotencyKey(), retryable: true
        )
    }

    /// One schedule, with its `recentOccurrences`.
    public func get(_ id: String) async throws -> Schedule {
        try await client.call("GET", "/schedules/\(seg(id))", retryable: true)
    }

    public func list() async throws -> Page<Schedule> {
        try await client.call("GET", "/schedules", retryable: true)
    }

    /// Change a schedule. `.clear` removes `startDate`, `endDate` or
    /// `maxOccurrences`; `repeat` replaces the whole object.
    public func update(
        _ id: String,
        to: String? = nil,
        from: Clearable<String>? = nil,
        body: String? = nil,
        repeat: ScheduleRepeat? = nil,
        startDate: Clearable<String>? = nil,
        endDate: Clearable<String>? = nil,
        maxOccurrences: Clearable<Int>? = nil,
        active: Bool? = nil,
        category: Clearable<String>? = nil,
        quietHours: Clearable<String>? = nil
    ) async throws -> Schedule {
        var b = Body()
        b["to"] = str(to)
        b.set("from", from, JSONValue.string)
        b["body"] = str(body)
        b["repeat"] = `repeat`?.json
        b.set("start_date", startDate, JSONValue.string)
        b.set("end_date", endDate, JSONValue.string)
        b.set("max_occurrences", maxOccurrences) { .int(Int64($0)) }
        b["active"] = active.map(JSONValue.bool)
        b.set("category", category, JSONValue.string)
        b.set("quiet_hours", quietHours, JSONValue.string)
        return try await client.call("PATCH", "/schedules/\(seg(id))", body: b.json, retryable: true)
    }

    /// Stop sending until resumed.
    @discardableResult
    public func pause(_ id: String) async throws -> Schedule {
        try await update(id, active: false)
    }

    /// Start again from now: nothing that came due while paused is sent.
    @discardableResult
    public func resume(_ id: String) async throws -> Schedule {
        try await update(id, active: true)
    }

    /// Stop it for good. Messages it already sent stay in the message log.
    @discardableResult
    public func delete(_ id: String) async throws -> Deleted {
        try await client.call("DELETE", "/schedules/\(seg(id))")
    }
}

// MARK: - Registrations

/// Brand and campaign registrations (business texting).
///
/// `create` runs the website and example checks; `recheck` corrects and
/// re-runs them; `submit` files a ready registration. The first submit for a
/// business carries the ``Attestation`` signed by someone authorized to act for it.
public struct Registrations: Sendable {
    let client: TextKit

    /// Create a registration. Runs the website check right away. Any other
    /// registration field (`opt_in_url`, `sample_messages`, `brand`, ...) goes
    /// in `fields`, by its API name.
    public func create(
        businessName: String,
        website: String,
        useCase: String,
        fields: [String: JSONValue] = [:]
    ) async throws -> Registration {
        var body = fields
        body["business_name"] = .string(businessName)
        body["website"] = .string(website)
        body["use_case"] = .string(useCase)
        return try await client.call("POST", "/registrations", body: .object(body))
    }

    public func get(_ id: String) async throws -> Registration {
        try await client.call("GET", "/registrations/\(seg(id))", retryable: true)
    }

    public func list() async throws -> Page<Registration> {
        try await client.call("GET", "/registrations", retryable: true)
    }

    /// Correct any field and re-run the checks (draft, checks_failed, ready or rejected).
    public func recheck(_ id: String, fields: [String: JSONValue] = [:]) async throws -> Registration {
        try await client.call("POST", "/registrations/\(seg(id))/recheck", body: .object(fields))
    }

    /// Submit a ready registration (or resubmit after a rejection).
    ///
    /// `feesAcknowledged` must be true: it confirms the registration fee terms
    /// (carrier registration fees are billed at the registry's charge, a campaign carries a
    /// 3-month minimum, and the fees are non-refundable even if the
    /// registration is rejected). Pass `attestation` the first time for a business.
    public func submit(_ id: String, feesAcknowledged: Bool, attestation: Attestation? = nil) async throws -> Registration {
        var b = Body()
        b["attestation"] = attestation?.json
        b["fees_acknowledged"] = .bool(feesAcknowledged)
        return try await client.call("POST", "/registrations/\(seg(id))/submit", body: b.json)
    }

    /// The filed copies, oldest first: exactly what each submission sent.
    public func submissions(_ id: String) async throws -> Page<RegistrationSubmission> {
        try await client.call("GET", "/registrations/\(seg(id))/submissions", retryable: true)
    }
}
