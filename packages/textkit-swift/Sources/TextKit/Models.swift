import Foundation

// Response shapes. Every field except `id` is optional: the API leaves a field
// out when it has no value (e.g. `customerId` on an unattributed message), and
// a field the API adds later is ignored rather than breaking the decode.
// Status-like fields are plain strings so a new value never throws. Open-ended
// objects (`data`, `metadata`, `brand`, ...) are ``JSONValue``.

/// One page of a list. Pass `nextCursor` back as `cursor`, or use the
/// resource's `listAll(...)`, which fetches pages as you iterate.
public struct Page<Item: Decodable & Sendable>: Decodable, Sendable {
    public let data: [Item]
    public let hasMore: Bool
    public let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = try c.decodeIfPresent([Item].self, forKey: .data) ?? []
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

public struct Message: Codable, Sendable, Identifiable {
    public let id: String
    /// `"message"`, or `"scheduled_message"` when `quietHours: "defer"` held the send.
    public let object: String?
    public let to: String?
    public let from: String?
    public let body: String?
    /// `outbound` or `inbound`.
    public let direction: String?
    /// `queued`, `sent`, `delivered`, `failed`, `blocked` (refused by a send check, never charged) or `received`.
    public let status: String?
    public let test: Bool?
    /// True when nothing was handed to a carrier (test keys). Always false on live messages.
    public let simulated: Bool?
    /// Only on the response to `messages.send`, e.g. when a test-key send was simulated.
    public let notice: String?
    public let scheduleId: String?
    /// `marketing`, `transactional` or `otp`, when the message was classified.
    public let category: String?
    public let disclosuresAdded: [String]?
    /// Present when the message was held for quiet hours.
    public let deferred: JSONValue?
    /// When a held message will send (only when `object` is `scheduled_message`).
    public let scheduledAt: String?
    public let media: [String]?
    public let sentBy: String?
    public let failureReason: String?
    /// Why it failed: `code`, `title`, `explanation`, `action`, `carrier_code`.
    public let failure: JSONValue?
    public let attempts: Int?
    public let nextAttemptAt: String?
    public let receiptStatus: String?
    public let customerId: String?
    public let timeline: [JSONValue]?
    public let segments: Int?
    public let encoding: String?
    public let price: JSONValue?
    public let destinationCarrier: String?
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, object, to, from, body, direction, status, test, simulated, notice, category, deferred, media
        case failure, attempts, timeline, segments, encoding, price
        case scheduleId = "schedule_id"
        case disclosuresAdded = "disclosures_added"
        case scheduledAt = "scheduled_at"
        case sentBy = "sent_by"
        case failureReason = "failure_reason"
        case nextAttemptAt = "next_attempt_at"
        case receiptStatus = "receipt_status"
        case customerId = "customer_id"
        case destinationCarrier = "destination_carrier"
        case createdAt = "created_at"
    }
}

/// A message queued for later (`messages.schedule`).
public struct ScheduledMessage: Codable, Sendable, Identifiable {
    public let id: String
    public let object: String?
    public let to: String?
    public let from: String?
    public let body: String?
    /// When it will send.
    public let scheduledAt: String?
    public let status: String?
    public let customerId: String?
    public let deferred: JSONValue?
    public let batchId: String?

    enum CodingKeys: String, CodingKey {
        case id, object, to, from, body, status, deferred
        case scheduledAt = "scheduled_at"
        case customerId = "customer_id"
        case batchId = "batch_id"
    }
}

public struct Verification: Codable, Sendable, Identifiable {
    public let id: String
    public let object: String?
    public let phone: String?
    /// `pending`, `approved`, `expired`, `max_attempts` or `blocked`.
    public let status: String?
    public let attempts: Int?
    public let attemptsRemaining: Int?
    public let maxAttempts: Int?
    public let test: Bool?
    public let charged: Bool?
    public let customerId: String?
    public let createdAt: String?
    public let expiresAt: String?
    public let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case id, object, phone, status, attempts, test, charged
        case attemptsRemaining = "attempts_remaining"
        case maxAttempts = "max_attempts"
        case customerId = "customer_id"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case expiresIn = "expires_in"
    }
}

public struct VerificationCheck: Codable, Sendable {
    /// True when the code was right. You are billed only then.
    public let verified: Bool
    public let status: String?
    public let attempts: Int?
    public let attemptsRemaining: Int?
    public let maxAttempts: Int?
    public let charged: Bool?

    enum CodingKeys: String, CodingKey {
        case verified, status, attempts, charged
        case attemptsRemaining = "attempts_remaining"
        case maxAttempts = "max_attempts"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verified = try c.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        status = try c.decodeIfPresent(String.self, forKey: .status)
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts)
        attemptsRemaining = try c.decodeIfPresent(Int.self, forKey: .attemptsRemaining)
        maxAttempts = try c.decodeIfPresent(Int.self, forKey: .maxAttempts)
        charged = try c.decodeIfPresent(Bool.self, forKey: .charged)
    }
}

/// A phone number on your account.
public struct PhoneNumber: Codable, Sendable, Identifiable {
    public let id: String
    public let object: String?
    public let phoneNumber: String?
    /// `active` or `released`.
    public let status: String?
    /// `test` or `live`.
    public let mode: String?
    public let customerId: String?
    public let label: String?
    public let tags: [String]?
    public let pools: [String]?
    public let sender: JSONValue?
    public let tollFree: JSONValue?
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, object, status, mode, label, tags, pools, sender
        case phoneNumber = "phone_number"
        case customerId = "customer_id"
        case tollFree = "toll_free"
        case createdAt = "created_at"
    }
}

public struct AvailableNumber: Codable, Sendable {
    public let object: String?
    public let phoneNumber: String
    public let locality: String?
    public let region: String?

    enum CodingKeys: String, CodingKey {
        case object, locality, region
        case phoneNumber = "phone_number"
    }
}

public struct Balance: Codable, Sendable {
    public let object: String?
    public let balanceMicroUsd: Int64?
    public let balanceUsd: Double?
    public let currency: String?
    /// `credits.low` fires when the balance falls below this.
    public let lowBalanceUsd: Double?
    /// `enabled`, `threshold_usd`, `amount_usd`.
    public let autoRecharge: JSONValue?
    public let topUpUrl: String?

    enum CodingKeys: String, CodingKey {
        case object, currency
        case balanceMicroUsd = "balance_micro_usd"
        case balanceUsd = "balance_usd"
        case lowBalanceUsd = "low_balance_usd"
        case autoRecharge = "auto_recharge"
        case topUpUrl = "top_up_url"
    }
}

/// A tracked destination with its clicks and conversions.
public struct TrackedLink: Codable, Sendable {
    public let url: String
    public let name: String?
    public let shortUrl: String?
    public let clickId: String?
    public let texts: Int
    public let clicks: Int
    public let conversions: Int
    public let valueCents: Int64
    public let test: Bool

    enum CodingKeys: String, CodingKey {
        case url, name, texts, clicks, conversions, test
        case shortUrl = "short_url"
        case clickId = "click_id"
        case valueCents = "value_cents"
    }
}

/// A sale or sign-up reported against a click.
public struct Conversion: Codable, Sendable {
    public let id: String
    public let clickId: String
    public let url: String
    public let name: String?
    public let externalId: String?
    public let valueCents: Int64
    public let duplicate: Bool?
    public let test: Bool

    enum CodingKeys: String, CodingKey {
        case id, url, name, duplicate, test
        case clickId = "click_id"
        case externalId = "external_id"
        case valueCents = "value_cents"
    }
}

public struct Lookup: Codable, Sendable {
    public let phoneNumber: String?
    public let valid: Bool?
    /// `mobile`, `landline`, `voip`, ...
    public let lineType: String?
    public let carrier: JSONValue?
    public let callerName: String?

    enum CodingKeys: String, CodingKey {
        case valid, carrier
        case phoneNumber = "phone_number"
        case lineType = "line_type"
        case callerName = "caller_name"
    }
}

/// An event from `events.list`, `events.wait`, or a verified webhook.
public struct Event: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let object: String?
    /// `message.delivered`, `message.received`, ...
    public let type: String?
    public let mode: String?
    public let createdAt: String?
    public let data: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id, object, type, mode, data
        case createdAt = "created_at"
    }
}

/// What `events.wait` answers. `data` is oldest first and may repeat an event
/// already returned (de-duplicate by `id`); pass `cursor` back on the next call.
public struct EventWait: Codable, Sendable {
    public let object: String?
    public let data: [Event]
    public let cursor: String?
    public let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case object, data, cursor
        case hasMore = "has_more"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        object = try c.decodeIfPresent(String.self, forKey: .object)
        data = try c.decodeIfPresent([Event].self, forKey: .data) ?? []
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }
}

/// What `events.track` answers: the event, and what it did.
public struct TrackedEvent: Codable, Sendable, Identifiable {
    public let id: String
    public let object: String?
    public let event: String?
    public let userId: String?
    public let phone: String?
    public let properties: JSONValue?
    public let test: Bool?
    public let runsStarted: [String]?
    public let runsNotified: Int?
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, object, event, phone, properties, test
        case userId = "user_id"
        case runsStarted = "runs_started"
        case runsNotified = "runs_notified"
        case createdAt = "created_at"
    }
}

public struct WebhookEndpoint: Codable, Sendable, Identifiable {
    public let id: String
    public let object: String?
    public let url: String?
    /// Subscribed event types; `["*"]` means every event.
    public let events: [String]?
    public let active: Bool?
    public let mode: String?
    public let description: String?
    /// Only on the response to `webhooks.create`: the signing secret, returned this once.
    public let secret: String?
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, object, url, events, active, mode, description, secret
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        object = try c.decodeIfPresent(String.self, forKey: .object)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        // The API sends `"*"` (everything) or a list.
        if let all = try? c.decodeIfPresent(String.self, forKey: .events) {
            events = [all]
        } else {
            events = try c.decodeIfPresent([String].self, forKey: .events)
        }
        active = try c.decodeIfPresent(Bool.self, forKey: .active)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        secret = try c.decodeIfPresent(String.self, forKey: .secret)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    }
}

/// What a delete answers.
public struct Deleted: Codable, Sendable, Identifiable {
    public let id: String
    public let object: String?
    public let deleted: Bool?
}

/// One number on the suppression list (`consent.list`) or a consent change (`optOut` / `optIn`).
public struct ConsentRecord: Codable, Sendable {
    public let object: String?
    public let phone: String?
    /// `opted_out` or `opted_in`.
    public let status: String?
    public let updatedAt: String?
    public let via: String?
    public let method: String?
    public let detected: String?
    public let confidence: Double?
    public let campaignId: String?
    public let proof: JSONValue?

    enum CodingKeys: String, CodingKey {
        case object, phone, status, via, method, detected, confidence, proof
        case updatedAt = "updated_at"
        case campaignId = "campaign_id"
    }
}

/// Current status plus the append-only history for one number (`consent.get`).
public struct ConsentDetail: Codable, Sendable {
    public let object: String?
    public let phone: String?
    /// `opted_out`, `opted_in` or `none`.
    public let status: String?
    public let history: [JSONValue]?
    public let optedOutAt: String?
    public let optedOutVia: String?
    public let optedOutMethod: String?
    public let blockedSends: Int?
    public let lastBlockedAt: String?

    enum CodingKeys: String, CodingKey {
        case object, phone, status, history
        case optedOutAt = "opted_out_at"
        case optedOutVia = "opted_out_via"
        case optedOutMethod = "opted_out_method"
        case blockedSends = "blocked_sends"
        case lastBlockedAt = "last_blocked_at"
    }
}

public struct ConsentImport: Codable, Sendable {
    public let object: String?
    public let imported: Int?
    public let skipped: [JSONValue]?
}

/// A business you send on behalf of (for platforms).
public struct Customer: Codable, Sendable, Identifiable {
    public let id: String
    public let object: String?
    public let name: String?
    public let externalId: String?
    public let metadata: JSONValue?
    public let phoneNumbers: [String]?
    public let createdAt: String?
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, object, name, metadata
        case externalId = "external_id"
        case phoneNumbers = "phone_numbers"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct CustomerUsage: Codable, Sendable {
    public let object: String?
    public let customerId: String?
    public let mode: String?
    public let start: String?
    public let end: String?
    public let messagesSent: Int?
    public let messagesFailed: Int?
    public let messagesReceived: Int?
    public let verificationsSent: Int?
    public let verificationsApproved: Int?
    public let numbers: Int?
    public let phoneNumbers: [String]?
    public let daily: [JSONValue]?

    enum CodingKeys: String, CodingKey {
        case object, mode, start, end, numbers, daily
        case customerId = "customer_id"
        case messagesSent = "messages_sent"
        case messagesFailed = "messages_failed"
        case messagesReceived = "messages_received"
        case verificationsSent = "verifications_sent"
        case verificationsApproved = "verifications_approved"
        case phoneNumbers = "phone_numbers"
    }
}

public struct Contact: Codable, Sendable, Identifiable {
    public let id: String
    public let object: String?
    public let phoneNumber: String?
    public let name: String?
    public let firstName: String?
    public let lastName: String?
    public let email: String?
    public let company: String?
    public let state: String?
    public let source: String?
    public let tags: [String]?
    public let fields: JSONValue?
    public let notes: String?
    public let consentStatus: String?
    public let optIn: JSONValue?
    public let importId: String?
    public let topics: [JSONValue]?
    public let segments: [JSONValue]?
    public let createdAt: String?
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, object, name, email, company, state, source, tags, fields, notes, topics, segments
        case phoneNumber = "phone_number"
        case firstName = "first_name"
        case lastName = "last_name"
        case consentStatus = "consent_status"
        case optIn = "opt_in"
        case importId = "import_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct ContactImport: Codable, Sendable {
    /// `contact_import`, or `contact_import_preview` for a dry run.
    public let object: String?
    public let created: Int?
    public let updated: Int?
    /// Each with `index`, `value` and `reason`.
    public let skipped: [JSONValue]?
}

public struct ContactBulk: Codable, Sendable {
    public let object: String?
    public let action: String?
    public let updated: Int?
    public let deleted: Int?
    public let missing: Int?
}

/// When a schedule fires: `frequency` (`daily`, `weekly`, `monthly`) at a wall-clock `time` in `timezone`.
public struct ScheduleRepeat: Codable, Sendable, Equatable {
    public var frequency: String
    /// 24-hour local time, "HH:MM".
    public var time: String
    /// IANA zone, e.g. `America/New_York`.
    public var timezone: String
    /// Weekly only: `["mon", "fri"]`.
    public var daysOfWeek: [String]?
    /// Monthly only: 1-31.
    public var dayOfMonth: Int?

    enum CodingKeys: String, CodingKey {
        case frequency, time, timezone
        case daysOfWeek = "days_of_week"
        case dayOfMonth = "day_of_month"
    }

    public init(frequency: String, time: String, timezone: String, daysOfWeek: [String]? = nil, dayOfMonth: Int? = nil) {
        self.frequency = frequency
        self.time = time
        self.timezone = timezone
        self.daysOfWeek = daysOfWeek
        self.dayOfMonth = dayOfMonth
    }

    public static func daily(at time: String, timezone: String) -> ScheduleRepeat {
        ScheduleRepeat(frequency: "daily", time: time, timezone: timezone)
    }

    public static func weekly(on days: [String], at time: String, timezone: String) -> ScheduleRepeat {
        ScheduleRepeat(frequency: "weekly", time: time, timezone: timezone, daysOfWeek: days)
    }

    public static func monthly(onDay day: Int, at time: String, timezone: String) -> ScheduleRepeat {
        ScheduleRepeat(frequency: "monthly", time: time, timezone: timezone, dayOfMonth: day)
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["frequency": .string(frequency), "time": .string(time), "timezone": .string(timezone)]
        if let daysOfWeek { o["days_of_week"] = JSONValue(daysOfWeek) }
        if let dayOfMonth { o["day_of_month"] = .int(Int64(dayOfMonth)) }
        return .object(o)
    }
}

/// A recurring schedule: one message to one number on a repeating local time.
public struct Schedule: Codable, Sendable, Identifiable {
    public let id: String
    public let object: String?
    public let to: String?
    public let from: String?
    public let body: String?
    public let `repeat`: ScheduleRepeat?
    public let startDate: String?
    public let endDate: String?
    public let maxOccurrences: Int?
    public let category: String?
    public let quietHours: String?
    public let active: Bool?
    /// `active`, `paused` or `completed`.
    public let status: String?
    public let pausedReason: String?
    public let nextRunAt: String?
    public let lastRunAt: String?
    public let lastStatus: String?
    public let lastError: String?
    public let lastMessageId: String?
    public let counts: JSONValue?
    public let test: Bool?
    /// Only on `schedules.get`: the last 10 occurrences, newest first.
    public let recentOccurrences: [JSONValue]?
    public let createdAt: String?
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, object, to, from, body, `repeat`, category, active, status, counts, test
        case startDate = "start_date"
        case endDate = "end_date"
        case maxOccurrences = "max_occurrences"
        case quietHours = "quiet_hours"
        case pausedReason = "paused_reason"
        case nextRunAt = "next_run_at"
        case lastRunAt = "last_run_at"
        case lastStatus = "last_status"
        case lastError = "last_error"
        case lastMessageId = "last_message_id"
        case recentOccurrences = "recent_occurrences"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// An event-driven flow: a trigger event, then send / wait / branch steps.
public struct Automation: Codable, Sendable, Identifiable {
    public let id: String
    public let object: String?
    public let name: String?
    /// `draft`, `active` or `paused`.
    public let status: String?
    public let trigger: JSONValue?
    public let steps: [JSONValue]?
    public let from: String?
    public let topicId: String?
    public let test: Bool?
    public let version: Int?
    public let unpublishedChanges: Bool?
    public let stats: JSONValue?
    /// What stops the flow from running, if anything.
    public let issues: [JSONValue]?
    public let createdAt: String?
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, object, name, status, trigger, steps, from, test, version, stats, issues
        case topicId = "topic_id"
        case unpublishedChanges = "unpublished_changes"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct AutomationRun: Codable, Sendable, Identifiable {
    public let id: String
    public let object: String?
    public let automationId: String?
    public let automationVersion: Int?
    /// `running`, `waiting`, `completed` or `failed`.
    public let status: String?
    public let to: String?
    public let userId: String?
    public let test: Bool?
    public let triggerEvent: String?
    public let step: Int?
    public let waitingUntil: String?
    public let waitingForEvent: String?
    public let endReason: String?
    public let messagesSent: Int?
    public let messagesFailed: Int?
    public let timeline: [JSONValue]?
    public let startedAt: String?
    public let endedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, object, status, to, test, step, timeline
        case automationId = "automation_id"
        case automationVersion = "automation_version"
        case userId = "user_id"
        case triggerEvent = "trigger_event"
        case waitingUntil = "waiting_until"
        case waitingForEvent = "waiting_for_event"
        case endReason = "end_reason"
        case messagesSent = "messages_sent"
        case messagesFailed = "messages_failed"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }
}

/// A brand and campaign registration (business texting).
public struct Registration: Codable, Sendable, Identifiable {
    public let id: String
    public let object: String?
    /// `draft`, `checks_failed`, `ready`, `submitted`, `in_review`, `approved` or `rejected`.
    public let status: String?
    public let businessName: String?
    public let website: String?
    public let useCase: String?
    public let optInUrl: String?
    public let privacyUrl: String?
    public let termsUrl: String?
    public let supportEmail: String?
    public let brand: JSONValue?
    public let sampleMessages: [String]?
    public let samplesSource: String?
    public let description: String?
    /// What happened, why, and who acts next.
    public let guidance: JSONValue?
    public let check: JSONValue?
    public let sampleCheck: JSONValue?
    public let rejection: JSONValue?
    public let generated: JSONValue?
    public let marketingPaused: JSONValue?
    public let submissions: Int?
    public let history: [JSONValue]?
    public let createdAt: String?
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, object, status, website, brand, description, guidance, check, rejection, generated, submissions, history
        case businessName = "business_name"
        case useCase = "use_case"
        case optInUrl = "opt_in_url"
        case privacyUrl = "privacy_url"
        case termsUrl = "terms_url"
        case supportEmail = "support_email"
        case sampleMessages = "sample_messages"
        case samplesSource = "samples_source"
        case sampleCheck = "sample_check"
        case marketingPaused = "marketing_paused"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// A filed copy of a registration: exactly what one submission sent.
public struct RegistrationSubmission: Codable, Sendable {
    public let object: String?
    public let registrationId: String?
    public let number: Int?
    public let submittedAt: String?
    public let filedBy: String?
    public let reference: String?
    public let sampleMessages: [String]?
    public let description: String?
    public let brand: JSONValue?
    public let campaign: JSONValue?
    public let feeAcknowledgment: JSONValue?

    enum CodingKeys: String, CodingKey {
        case object, number, reference, description, brand, campaign
        case registrationId = "registration_id"
        case submittedAt = "submitted_at"
        case filedBy = "filed_by"
        case sampleMessages = "sample_messages"
        case feeAcknowledgment = "fee_acknowledgment"
    }
}

/// The signed business attestation the first registration submit carries.
public struct Attestation: Sendable, Equatable {
    public var signerName: String
    public var signerTitle: String
    public var accepted: Bool

    public init(signerName: String, signerTitle: String, accepted: Bool = true) {
        self.signerName = signerName
        self.signerTitle = signerTitle
        self.accepted = accepted
    }

    var json: JSONValue {
        ["signer_name": .string(signerName), "signer_title": .string(signerTitle), "accepted": .bool(accepted)]
    }
}

/// A contact to upsert (`contacts.upsert`, `contacts.import`). Values you leave
/// nil are kept; tags are added, never removed.
public struct ContactInput: Sendable {
    public var phoneNumber: String
    public var name: String?
    public var firstName: String?
    public var lastName: String?
    public var email: String?
    public var company: String?
    public var state: String?
    public var source: String?
    public var tags: [String]?
    public var fields: [String: String]?
    public var notes: String?
    /// Opt-in evidence recorded with the contact.
    public var optIn: JSONValue?

    public init(
        phoneNumber: String,
        name: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil,
        email: String? = nil,
        company: String? = nil,
        state: String? = nil,
        source: String? = nil,
        tags: [String]? = nil,
        fields: [String: String]? = nil,
        notes: String? = nil,
        optIn: JSONValue? = nil
    ) {
        self.phoneNumber = phoneNumber
        self.name = name
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.company = company
        self.state = state
        self.source = source
        self.tags = tags
        self.fields = fields
        self.notes = notes
        self.optIn = optIn
    }

    var json: JSONValue {
        var b = Body()
        b["phone_number"] = .string(phoneNumber)
        b["name"] = name.map(JSONValue.string)
        b["first_name"] = firstName.map(JSONValue.string)
        b["last_name"] = lastName.map(JSONValue.string)
        b["email"] = email.map(JSONValue.string)
        b["company"] = company.map(JSONValue.string)
        b["state"] = state.map(JSONValue.string)
        b["source"] = source.map(JSONValue.string)
        b["tags"] = tags.map(JSONValue.init)
        b["fields"] = fields.map(JSONValue.init)
        b["notes"] = notes.map(JSONValue.string)
        b["opt_in"] = optIn
        return b.json
    }
}
