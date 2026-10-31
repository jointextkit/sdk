/**
 * jointextkit - the official TextKit client.
 *
 * TextKit was called SimpleSMS until 2026-10-28 (npm `joinsimplesms`), and
 * Delivered before that (npm `deliveredsms`). Code from both eras keeps
 * working: `SimpleSMS` and `Delivered` (and their errors) are exported as
 * deprecated aliases, SIMPLESMS_API_KEY and DELIVERED_API_KEY are still read,
 * ssms_sk_ and dsms_sk_ keys still authenticate. The old host
 * api.deliveredsms.com is retired (410); this SDK defaults to
 * api.jointextkit.com.
 *
 * Zero dependencies. Uses the platform `fetch`, so it runs on Node 18+, Bun,
 * Deno, Cloudflare Workers and Vercel Edge without a polyfill.
 */

export const VERSION = '2.10.0';
const DEFAULT_BASE_URL = 'https://api.jointextkit.com';

// ── errors ──────────────────────────────────────────────────────────────────

export type TextKitErrorCode =
  | 'invalid_api_key'
  | 'key_paused'
  | 'number_purchase_held'
  | 'tenant_suspended'
  | 'account_closed'
  | 'email_unconfirmed'
  | 'live_access_required'
  | 'test_mode_only'
  | 'forbidden'
  | 'not_found'
  | 'method_not_allowed'
  | 'invalid_request'
  | 'rate_limited'
  | 'quota_exceeded'
  | 'recipient_not_verified'
  | 'verification_blocked'
  | 'verification_not_found'
  | 'verification_already_approved'
  | 'channel_unavailable'
  | 'idempotency_conflict'
  | 'idempotency_in_progress'
  | 'carrier_error'
  | 'mms_not_enabled'
  | 'endpoint_retired'
  | 'spend_limit_reached'
  | 'insufficient_credits'
  | 'sender_not_registered'
  | 'recipient_opted_out'
  | 'quiet_hours'
  | 'consent_required'
  | 'campaign_paused'
  | 'invalid_state'
  | 'callback_secret_required'
  | 'insufficient_scope'
  | 'billing_required'
  | 'attestation_required'
  | 'link_domain_required'
  | 'internal_error'
  | 'connection_error'
  | 'invalid_signature';

export class TextKitError extends Error {
  readonly code: TextKitErrorCode;
  readonly status: number;
  /** Which request field was wrong, when the API could tell. */
  readonly param?: string;
  /** Seconds to wait, on rate limits. */
  readonly retryAfter?: number;
  /** Why Shield blocked a verification. */
  readonly reason?: string;
  /** `insufficient_credits` only: your balance, in millionths of a dollar. */
  readonly balanceMicroUsd?: number;
  /** `insufficient_credits` only: what the call costs, in millionths of a dollar. */
  readonly requiredMicroUsd?: number;
  /** `insufficient_credits` only: where to add credits. */
  readonly topUpUrl?: string;
  /** `quiet_hours` only: when the message may be sent (ISO timestamp). */
  readonly sendAfter?: string;
  /** `quiet_hours` only: the recipient's local time, 24-hour "HH:MM". */
  readonly recipientLocalTime?: string;
  /** `quiet_hours` only: the IANA time zone read from the number's area code. */
  readonly timezone?: string;
  /** The blocked message stored in your log for this refusal, when there is one. */
  readonly messageId?: string;

  constructor(
    message: string,
    opts: {
      code: TextKitErrorCode;
      status: number;
      param?: string;
      retryAfter?: number;
      reason?: string;
      balanceMicroUsd?: number;
      requiredMicroUsd?: number;
      topUpUrl?: string;
      sendAfter?: string;
      recipientLocalTime?: string;
      timezone?: string;
      messageId?: string;
    }
  ) {
    super(message);
    this.name = 'TextKitError';
    this.code = opts.code;
    this.status = opts.status;
    this.param = opts.param;
    this.retryAfter = opts.retryAfter;
    this.reason = opts.reason;
    this.balanceMicroUsd = opts.balanceMicroUsd;
    this.requiredMicroUsd = opts.requiredMicroUsd;
    this.topUpUrl = opts.topUpUrl;
    this.sendAfter = opts.sendAfter;
    this.recipientLocalTime = opts.recipientLocalTime;
    this.timezone = opts.timezone;
    this.messageId = opts.messageId;
  }

  /** True when retrying the same call later could plausibly succeed. */
  get retryable(): boolean {
    return (
      this.status >= 500 ||
      this.code === 'rate_limited' ||
      // The same idempotent request, still running server-side (after a timeout retry).
      this.code === 'idempotency_in_progress' ||
      this.code === 'carrier_error' ||
      this.code === 'connection_error'
    );
  }
}

// ── types ───────────────────────────────────────────────────────────────────

/** `blocked`: refused by a send check before any carrier saw it. Never charged; `failure` says why. */
export type MessageStatus = 'queued' | 'sent' | 'delivered' | 'failed' | 'blocked' | 'received';

/** What a message is, for quiet hours. Only `marketing` is held or refused at night. */
export type MessageCategory = 'marketing' | 'transactional' | 'otp';
/** What to do with a marketing message in the recipient's quiet hours. */
export type QuietHoursAction = 'block' | 'defer';

export interface Message {
  id: string;
  object: 'message';
  to: string;
  from: string;
  body: string;
  direction: 'outbound' | 'inbound';
  status: MessageStatus;
  test: boolean;
  /**
   * True when nothing was handed to a carrier: every test-key message except
   * one sent to your own verified phone. Always false on live messages. A
   * simulated message still reaches `delivered`.
   */
  simulated: boolean;
  /** Only on the response to `messages.send`: says a test-key send to a real-looking number was simulated. */
  notice?: string;
  /** Present when the message is an occurrence of a recurring schedule. */
  schedule_id?: string;
  /** The labels it was sent with (`tags` on `messages.send`), lowercased. */
  tags?: string[];
  created_at: string;
  media?: string[];
  sent_by?: string;
  /** Raw carrier text for a failed send; prefer `failure`. */
  failure_reason?: string;
  /** Present when the message is attributed to one of your customers. */
  customer_id?: string;
  /** Every status transition, oldest first. */
  timeline: Array<{ status: TimelineStatus; at: string; attempt?: number }>;
  /** Parts the body is split into on the handset. */
  segments: number;
  encoding: 'gsm7' | 'ucs2';
  /** USD. Null on messages sent before prices were recorded. */
  price: MessagePrice | null;
  /** The recipient's mobile carrier, when a recent lookup knows it. */
  destination_carrier: string | null;
  /** Why it failed, in plain words; null unless status is 'failed'. */
  failure: MessageFailure | null;
}

export type TimelineStatus =
  | 'accepted'
  | 'validated'
  | 'queued'
  | 'sent_to_carrier'
  | 'carrier_accepted'
  | 'retry_scheduled'
  | 'delivered'
  | 'failed'
  | 'received';

export interface MessagePrice {
  total: number;
  currency: 'usd';
  breakdown: Array<{ label: string; amount: number }>;
}

export type FailureCode =
  | 'carrier_filtered'
  | 'unreachable'
  | 'invalid_number'
  | 'opted_out'
  | 'content_blocked'
  | 'rate_limited'
  | 'landline'
  | 'carrier_rejected'
  | 'spend_limit_reached'
  | 'insufficient_credits'
  | 'sender_not_registered'
  | 'quiet_hours'
  | 'recipient_not_verified'
  | 'quota_exceeded'
  | 'destination_not_allowed'
  | 'topic_unsubscribed'
  | 'unknown';

export interface MessageFailure {
  code: FailureCode;
  title: string;
  explanation: string;
  action: string;
  /** The carrier's own error code, when it sent one. */
  carrier_code: string | null;
}

/** What `events.wait()` answers: new events, oldest first, and where to resume. */
export interface EventWait {
  object: 'event_wait';
  /** May repeat an event already returned: de-duplicate by `id`. */
  data: SmsEvent[];
  /** Pass back as `cursor` on the next call. */
  cursor: string;
  /** More are already waiting: call again without pausing. */
  has_more: boolean;
}

export interface WebhookEndpoint {
  id: string;
  object: 'webhook_endpoint';
  url: string;
  /** `'*'` for every event, or the subscribed types. */
  events: '*' | string[];
  active: boolean;
  /** Which events it receives: the mode of the key that created it. */
  mode?: 'test' | 'live';
  description: string | null;
  created_at: string;
}

/** A just-created endpoint. `secret` is returned this once and never again. */
export interface CreatedWebhookEndpoint extends WebhookEndpoint {
  secret: string;
}

export interface ScheduledMessage {
  id: string;
  object: 'scheduled_message';
  to: string;
  from: string;
  body: string;
  /** When it will send. */
  scheduled_at: string;
  /** @deprecated The same value as `scheduled_at`, under its older name. */
  run_at: string;
  status: 'queued';
  /** Present when the message was held for quiet hours rather than scheduled by you. */
  deferred?: {
    reason: 'quiet_hours';
    recipient_local_time: string;
    timezone: string;
    send_after: string;
    category: MessageCategory;
    category_basis: 'request' | 'broadcast' | 'sender_registration' | 'default';
  };
}

export type ScheduleWeekday = 'sun' | 'mon' | 'tue' | 'wed' | 'thu' | 'fri' | 'sat';

export interface ScheduleRepeat {
  frequency: 'daily' | 'weekly' | 'monthly';
  /** 24-hour local time, "HH:MM". */
  time: string;
  /** IANA time zone, e.g. "America/New_York". */
  timezone: string;
  /** Weekly only (required). */
  days_of_week?: ScheduleWeekday[];
  /** Monthly only (required), 1-31. Shorter months run on their last day. */
  day_of_month?: number;
}

export type ScheduleRunStatus = 'sent' | 'skipped_opted_out' | 'skipped_missed' | 'failed';

/** A recurring schedule (POST /v1/schedules). */
export interface Schedule {
  id: string;
  object: 'schedule';
  to: string;
  from: string;
  body: string;
  repeat: ScheduleRepeat;
  start_date: string | null;
  end_date: string | null;
  max_occurrences: number | null;
  active: boolean;
  status: 'active' | 'paused' | 'completed';
  paused_reason: 'manual' | 'recipient_opted_out' | 'repeated_failures' | 'sender_unavailable' | null;
  next_run_at: string | null;
  last_run_at: string | null;
  last_status: ScheduleRunStatus | null;
  last_error: string | null;
  last_message_id: string | null;
  counts: { sent: number; skipped: number; failed: number };
  test: boolean;
  created_at: string;
  updated_at: string;
  /** Only on `schedules.get`: the last 10 occurrences, newest first. */
  recent_occurrences?: Array<{
    date: string;
    due_at: string | null;
    status: ScheduleRunStatus;
    message_id: string | null;
    error: string | null;
  }>;
}

export interface ScheduleParams {
  to?: string;
  /** Optional when the account has one number for the key's mode. */
  from?: string;
  body?: string;
  repeat?: ScheduleRepeat;
  /** Local calendar dates, "YYYY-MM-DD". null clears on update. */
  startDate?: string | null;
  endDate?: string | null;
  maxOccurrences?: number | null;
}

export interface ListMessagesParams {
  limit?: number;
  cursor?: string;
  /** To or from this number. */
  number?: string;
  to?: string;
  from?: string;
  status?: MessageStatus;
  direction?: 'outbound' | 'inbound';
  /** Inclusive; ISO timestamp or epoch ms. */
  created_after?: string | number;
  /** Exclusive; ISO timestamp or epoch ms. */
  created_before?: string | number;
  customerId?: string;
  /** Only the occurrences of this recurring schedule (sch_...). */
  scheduleId?: string;
  /** Only messages sent with this tag. */
  tag?: string;
  /** Only blocked messages with this reason, e.g. "quiet_hours". */
  blockedReason?: FailureCode;
  /** Failed or blocked messages with this `failure.code`. */
  failureCode?: FailureCode;
}

export type VerificationStatus =
  | 'pending'
  | 'approved'
  | 'expired'
  | 'max_attempts'
  | 'blocked';

/** How a code goes out: a text, or an email. */
export type VerificationChannel = 'sms' | 'email';

/**
 * A verification started by text (`verify.send({ to: phone })`). `phone` is
 * always set, also after `verify.fallback` moves it to email (then `channel`
 * is `'email'` and `email` is set). An email-started verification is an
 * `EmailVerification`, whose `phone` is null.
 */
export interface Verification {
  id: string;
  object: 'verification';
  /** The channel the current code went out on; `check` accepts that code only. */
  channel: VerificationChannel;
  phone: string;
  /** null until a code is emailed. */
  email: string | null;
  status: VerificationStatus;
  attempts: number;
  attempts_remaining: number;
  max_attempts: number;
  test: boolean;
  charged: boolean;
  created_at: string;
  expires_at: string;
  expires_in: number;
  /** When the verification moved from text to email (`verify.fallback`). Present only then. */
  fallback_at?: string;
  customer_id?: string;
}

/** A verification started by email (`verify.send({ channel: 'email' })`). */
export type EmailVerification = Omit<Verification, 'channel' | 'phone' | 'email'> & {
  channel: 'email';
  phone: null;
  email: string;
};

export interface VerificationCheck {
  verified: boolean;
  /** The channel of the code checked. */
  channel: VerificationChannel;
  /**
   * What the code proved: the phone (channel sms) or the email address
   * (channel email). After a fallback it is the email, never the phone.
   */
  phone?: string | null;
  email?: string | null;
  status: VerificationStatus;
  attempts: number;
  attempts_remaining: number;
  max_attempts: number;
  charged: boolean;
}

export interface PhoneNumber {
  id: string;
  object: 'number';
  phone_number: string;
  status: 'active' | 'released';
  mode: 'test' | 'live';
  created_at: string;
  /** The customer this number is assigned to, or null. */
  customer_id: string | null;
  /**
   * How the number stands with the carriers. `null` on sandbox numbers and
   * on numbers that need no registration. Anything but `active` can text
   * only your verified numbers.
   */
  sender?: NumberSender | null;
}

export interface NumberSender {
  state: 'test_only' | 'pending' | 'active' | 'action_needed';
  registration_id: string | null;
  /** What to do, in plain words, when `state` is `action_needed`. */
  reason: string | null;
  updated_at: string;
}

export interface AvailableNumber {
  object: 'available_number';
  phone_number: string;
  locality: string;
  region: string;
}

export interface Lookup {
  phone_number: string;
  valid: boolean;
  line_type: string | null;
  carrier: { name: string | null; type: string | null };
  caller_name: string | null;
}

/** @deprecated Spam scores were retired on 2026-09-30. */
export interface SpamLookup {
  phone_number: string;
  spam_score: number;
  spam_type: string | null;
  severity: string | null;
  last_reported_at: string | null;
  reports: number;
}

export interface SmsEvent {
  id: string;
  object: 'event';
  type: string;
  /** Sandbox (`test`) or live traffic. On a live account a key sees only its own mode's events. */
  mode?: 'test' | 'live';
  created_at: string;
  data: Record<string, unknown>;
}

export interface ScheduledMessage {
  id: string;
  object: 'scheduled_message';
  to: string;
  from: string;
  body: string;
  run_at: string;
  status: 'queued';
  customer_id?: string;
}

export type ConsentStatus = 'opted_out' | 'opted_in' | 'none';

/** Opt-in evidence (Messaging Policy 1.4). Required for an opt-in recorded for a marketing or mixed registration. */
export interface OptInProof {
  source: 'web_form' | 'keyword' | 'paper' | 'checkout' | 'verbal';
  /** When the person consented (ISO or epoch ms). Required for a marketing registration. */
  collectedAt?: string | number;
  /** Required for web_form. */
  pageUrl?: string;
  /** Exact disclosure wording shown. */
  disclosure?: string;
  ip?: string;
  userAgent?: string;
  /** The inbound message that was the opt-in. Required for a keyword opt-in recorded for a marketing registration. */
  messageId?: string;
}

/** A registration this number has an opt-in on file for. */
export interface ConsentCampaign {
  campaign_id: string;
  opted_in_at: string;
  via: string;
  proof_source?: OptInProof['source'];
}

export interface ConsentRecord {
  object: 'consent';
  phone: string;
  status: 'opted_out';
  updated_at: string;
  via: string;
  method?: string;
  detected?: string;
  confidence?: number;
}

export interface ConsentDetail {
  object: 'consent';
  phone: string;
  status: ConsentStatus;
  /** While opted out: when and how. */
  opted_out_at?: string;
  opted_out_via?: string;
  opted_out_method?: string;
  /** While opted out: sends to this number refused since the opt-out. */
  blocked_sends?: number;
  last_blocked_at?: string | null;
  /** The registrations the number is opted in to (empty while opted out). */
  campaigns: ConsentCampaign[];
  history: Array<{
    at: string;
    type: string;
    via: string;
    method?: string;
    detected?: string;
    confidence?: number;
    note?: string;
    /** The registration an opt-in was given for. */
    campaign_id?: string;
    proof?: Record<string, unknown>;
  }>;
}

export interface ConsentImport {
  object: 'consent_import';
  imported: number;
  skipped: Array<{ value: string; reason: string }>;
}

export interface Customer {
  id: string;
  object: 'customer';
  name: string | null;
  external_id: string | null;
  metadata: Record<string, string>;
  created_at: string;
  updated_at: string;
  /** Only on `customers.get()`. */
  phone_numbers?: string[];
}

// ── Registrations (brand + campaign) ───────────────────────────────────────

export type RegistrationStatus = 'draft' | 'checks_failed' | 'ready' | 'submitted' | 'in_review' | 'approved' | 'rejected';

/** The business as the carriers register it. `contact_*` is the authorized representative. */
export interface RegistrationBrand {
  legal_name?: string;
  entity_type?: 'PRIVATE_PROFIT' | 'PUBLIC_PROFIT' | 'NON_PROFIT' | 'GOVERNMENT' | 'SOLE_PROPRIETOR';
  ein?: string;
  /** A street address, never a P.O. box. */
  street?: string;
  city?: string;
  /** 2-letter US state or territory code. */
  state?: string;
  postal_code?: string;
  country?: string;
  vertical?: string;
  /** A person who works for the business and can act for it. */
  contact_name?: string;
  /** Their job title, like Owner or Operations Manager. */
  contact_title?: string;
  /** Their own email at the business's domain: a free mailbox or a shared inbox (info@) is refused. */
  contact_email?: string;
  /** A 10-digit US number they answer. */
  contact_phone?: string;
}

export interface RegistrationParams {
  business_name?: string;
  website?: string;
  use_case?: string;
  opt_in_url?: string;
  privacy_url?: string;
  terms_url?: string;
  support_email?: string;
  /** 2 to 5 real examples of what you send. */
  sample_messages?: string[] | null;
  samples_confirmed?: boolean;
  description?: string | null;
  opt_in_flow?: string | null;
  stop_reply?: string | null;
  help_reply?: string | null;
  includes_links?: boolean;
  includes_phone_numbers?: boolean;
  age_gated?: boolean;
  direct_lending?: boolean;
  brand?: RegistrationBrand;
}

/**
 * Signed by someone authorized to act for the business, once per business,
 * with the first submit: that they are authorized, that the details match
 * the business's IRS records, and that the business will text only people
 * who agreed to it. Kept as signed (wording, key, IP, user agent, date).
 */
export interface BusinessAttestation {
  /** The full name of the person signing. */
  signer_name: string;
  /** Their job title. */
  signer_title: string;
  /** Must be true: the person signing agrees to the statement. */
  accepted: true;
}

export interface RegistrationGuidance {
  what_happened: string;
  why: string;
  next_actor: 'you' | 'textkit' | 'carriers' | 'nobody';
  next_step: string;
  after: string;
}

export interface Registration {
  id: string;
  object: 'registration';
  status: RegistrationStatus;
  business_name: string;
  website: string;
  use_case: string;
  opt_in_url: string | null;
  privacy_url: string | null;
  terms_url: string | null;
  support_email: string | null;
  brand: RegistrationBrand;
  sample_messages: string[];
  samples_source: 'starter' | 'customer';
  description: string | null;
  opt_in_flow: string | null;
  stop_reply: string | null;
  help_reply: string | null;
  guidance: RegistrationGuidance;
  check: { checked_at: string; passed: number; failed: number; warnings: number; findings: Array<Record<string, unknown>> } | null;
  sample_check: { passed: number; failed: number; warnings: number; findings: Array<Record<string, unknown>> };
  rejection: { code: string; title: string; explanation: string; fix: string; note: string | null; rejected_at: string } | null;
  generated: Record<string, unknown>;
  submissions: number;
  review_stalled: boolean;
  history: Array<{ at: string; status: RegistrationStatus; actor: string; label?: string; reason_code?: string; note?: string }>;
  created_at: string;
  updated_at: string;
}

/** Exactly what one submission filed. Written once, never changed. */
export interface RegistrationSubmission {
  object: 'registration_submission';
  registration_id: string;
  number: number;
  submitted_at: string;
  filed_by: string;
  reference: string;
  brand: Record<string, unknown>;
  campaign: Record<string, unknown>;
  sample_messages: string[];
  samples_source: 'starter' | 'customer';
  [key: string]: unknown;
}

export interface Contact {
  id: string;
  object: 'contact';
  phone_number: string;
  name: string | null;
  /** Free-form labels; they double as broadcast audiences. */
  tags: string[];
  /** Custom key/values, usable in merge fields as `{{field:key}}`. */
  fields: Record<string, string>;
  notes: string | null;
  created_at: string;
  updated_at: string;
}

export interface ContactParams {
  phoneNumber: string;
  name?: string;
  tags?: string[];
  fields?: Record<string, string>;
  notes?: string;
}

export interface ContactImport {
  object: 'contact_import';
  created: number;
  updated: number;
  /** Rows that were not imported, by their index in the request. */
  skipped: Array<{ index: number; value: string; reason: string }>;
}

export interface ContactBulk {
  object: 'contact_bulk';
  action: 'add_tags' | 'remove_tags' | 'delete';
  updated: number;
  deleted: number;
  /** Ids that did not exist. */
  missing: number;
}

export interface CustomerUsageCounts {
  messages_sent: number;
  messages_failed: number;
  messages_received: number;
  verifications_sent: number;
  verifications_approved: number;
}

export interface CustomerUsage extends CustomerUsageCounts {
  object: 'customer_usage';
  customer_id: string;
  /** Usage follows the key: test keys report sandbox traffic, live keys live. */
  mode: 'test' | 'live';
  start: string;
  end: string;
  numbers: number;
  phone_numbers: string[];
  daily: Array<CustomerUsageCounts & { date: string }>;
}

/** What POST /v1/track answers: the event, and what it did. */
export interface TrackedEvent {
  id: string;
  object: 'tracked_event';
  event: string;
  user_id: string | null;
  /** Null when `user_id` is not linked to a phone number yet (nothing could start). */
  phone: string | null;
  properties: Record<string, string | number | boolean>;
  test: boolean;
  /** Ids of the automation runs this event started. */
  runs_started: string[];
  /** Runs in progress for this person that recorded the event. */
  runs_notified: number;
  created_at: string;
}

/** 'continue' | 'end' | 'goto:<id of a later step>' */
export type AutomationBranch = string;
export type AutomationCompareOp = 'eq' | 'neq' | 'contains' | 'gt' | 'lt' | 'exists' | 'not_exists';

export type AutomationCheck =
  | { kind: 'event_received'; event: string }
  | { kind: 'property'; property: string; op: AutomationCompareOp; value?: string | number | boolean }
  | { kind: 'contact_field'; field: string; op: AutomationCompareOp; value?: string | number | boolean };

export type AutomationStep =
  | { id?: string; type: 'send_sms'; body: string; from?: string }
  | { id?: string; type: 'wait'; seconds: number }
  | {
      id?: string;
      type: 'wait_for_event';
      event: string;
      timeout_seconds: number;
      on_received: AutomationBranch;
      on_timeout: AutomationBranch;
    }
  | { id?: string; type: 'condition'; check: AutomationCheck; on_met: AutomationBranch; on_not_met: AutomationBranch }
  | { id?: string; type: 'end' };

export interface AutomationTrigger {
  event: string;
  filters?: Array<{ property: string; op: AutomationCompareOp; value?: string | number | boolean }>;
}

export interface AutomationParams {
  name?: string;
  /** One of your numbers, to pin the flow to it. Leave it out and TextKit picks a number approved for `category`. */
  from?: string | null;
  /** What it sends. With no `from`, TextKit picks a number approved for this. */
  category?: 'marketing' | 'transactional' | 'otp' | null;
  topicId?: string | null;
  trigger?: AutomationTrigger;
  steps?: AutomationStep[];
}

export interface Automation {
  id: string;
  object: 'automation';
  name: string;
  status: 'draft' | 'active' | 'paused';
  trigger: AutomationTrigger;
  steps: AutomationStep[];
  from: string | null;
  /** Who it comes from: a fixed number, or the numbers TextKit picks from. */
  sender?: { automatic: boolean; category: 'marketing' | 'transactional' | 'otp' | null; numbers: string[]; blocked: string | null };
  category: 'marketing' | 'transactional' | 'otp' | null;
  topic_id: string | null;
  test: boolean | null;
  version: number;
  unpublished_changes: boolean;
  stats: {
    runs_started: number;
    runs_active: number;
    runs_completed: number;
    runs_failed: number;
    runs_opted_out: number;
    triggers_skipped: number;
    messages_sent: number;
    last_triggered_at: string | null;
  };
  /** What stops this flow from running; empty when it can be activated. */
  issues?: Array<{ where: string; field?: string; message: string }>;
  created_at: string;
  updated_at: string;
}

export interface AutomationRun {
  id: string;
  object: 'automation_run';
  automation_id: string;
  automation_version: number;
  status: 'running' | 'waiting' | 'completed' | 'failed';
  to: string;
  user_id: string | null;
  test: boolean;
  trigger_event: string;
  step: number;
  waiting_until: string | null;
  waiting_for_event: string | null;
  end_reason: string | null;
  messages_sent: number;
  messages_failed: number;
  timeline: Array<{ at: string; type: string; step_id?: string; detail?: string; message_id?: string }>;
  started_at: string;
  ended_at: string | null;
}

export interface Page<T> {
  data: T[];
  has_more: boolean;
  next_cursor: string | null;
}

export interface TextKitOptions {
  baseUrl?: string;
  /** Retries for transient failures. Default 2. */
  maxRetries?: number;
  /** Per-request timeout in ms. Default 30_000. */
  timeout?: number;
  fetch?: typeof globalThis.fetch;
}

interface RequestOptions {
  method: 'GET' | 'POST' | 'PATCH' | 'DELETE';
  path: string;
  body?: unknown;
  idempotencyKey?: string;
  /** Retry this call on transient failure. POSTs need an idempotency key. */
  retryable?: boolean;
  /** Return the response body as text instead of parsing JSON (CSV exports). */
  raw?: boolean;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function randomId(): string {
  const bytes = new Uint8Array(16);
  (globalThis.crypto || ({} as Crypto)).getRandomValues?.(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

// ── client ──────────────────────────────────────────────────────────────────

/** Deprecated env names for the API key, newest first. Read only when TEXTKIT_API_KEY is unset. */
const LEGACY_KEY_ENV = ['SIMPLESMS_API_KEY', 'DELIVERED_API_KEY', 'RESMS_API_KEY'] as const;
/** The names deployments set before a rename: read without a warning. */
const SILENT_LEGACY_KEY_ENV: readonly string[] = ['SIMPLESMS_API_KEY', 'DELIVERED_API_KEY'];

/** TEXTKIT_BASE_URL, else the deprecated SIMPLESMS_BASE_URL / DELIVERED_BASE_URL / RESMS_BASE_URL. */
function envBaseUrl(env: Record<string, string | undefined>): string | undefined {
  return env.TEXTKIT_BASE_URL || env.SIMPLESMS_BASE_URL || env.DELIVERED_BASE_URL || env.RESMS_BASE_URL || undefined;
}

export class TextKit {
  readonly messages: Messages;
  readonly verify: Verify;
  readonly numbers: Numbers;
  readonly lookup: LookupResource;
  readonly links: Links;
  readonly conversions: Conversions;
  readonly balance: BalanceResource;
  readonly events: Events;
  readonly consent: Consent;
  readonly customers: Customers;
  readonly contacts: Contacts;
  readonly automations: Automations;
  readonly schedules: Schedules;
  readonly registrations: Registrations;
  /** Webhook endpoints, and signature verification (`webhooks.verify`, also exported as `verifyWebhook`). */
  readonly webhooks: Webhooks;
  /** Brand and campaign registrations: the website check, the submit with the business attestation, the filed copies. */

  private readonly apiKey: string;
  private readonly baseUrl: string;
  private readonly maxRetries: number;
  private readonly timeout: number;
  private readonly fetchImpl: typeof globalThis.fetch;

  constructor(apiKey?: string, options: TextKitOptions = {}) {
    const env = (globalThis as any).process?.env ?? {};
    // TEXTKIT_API_KEY first; the names from before each rename still work.
    const legacyName = LEGACY_KEY_ENV.find((name) => env[name]);
    const key = apiKey ?? env.TEXTKIT_API_KEY ?? (legacyName ? env[legacyName] : undefined);
    // SIMPLESMS_API_KEY and DELIVERED_API_KEY are what deployments before each
    // rename set: read them silently. Only RESMS_API_KEY (deprecated even then) warns.
    if (!apiKey && !env.TEXTKIT_API_KEY && legacyName && !SILENT_LEGACY_KEY_ENV.includes(legacyName)) {
      console.error(`jointextkit: ${legacyName} is deprecated; rename it to TEXTKIT_API_KEY.`);
    }
    if (!key) {
      throw new Error(
        'No TextKit key. Pass one to new TextKit(...) or set TEXTKIT_API_KEY. Get one free at https://jointextkit.com/console'
      );
    }
    this.apiKey = key;
    this.baseUrl = (options.baseUrl ?? envBaseUrl(env) ?? DEFAULT_BASE_URL).replace(/\/$/, '');
    this.maxRetries = options.maxRetries ?? 2;
    this.timeout = options.timeout ?? 30_000;
    // Bound: Workers throw "Illegal invocation" when fetch is called with another `this`.
    this.fetchImpl = options.fetch ?? globalThis.fetch.bind(globalThis);

    this.messages = new Messages(this);
    this.verify = new Verify(this);
    this.numbers = new Numbers(this);
    this.lookup = new LookupResource(this);
    this.links = new Links(this);
    this.conversions = new Conversions(this);
    this.balance = new BalanceResource(this);
    this.events = new Events(this);
    this.consent = new Consent(this);
    this.customers = new Customers(this);
    this.contacts = new Contacts(this);
    this.automations = new Automations(this);
    this.schedules = new Schedules(this);
    this.registrations = new Registrations(this);
    this.webhooks = new Webhooks(this);
  }

  /** True when this client is using a sandbox key. */
  get isTestMode(): boolean {
    return /^(tk|ssms|dsms|resms)_sk_test_/.test(this.apiKey);
  }

  /** @internal */
  async request<T>(opts: RequestOptions): Promise<T> {
    let lastError: TextKitError | null = null;

    for (let attempt = 0; attempt <= this.maxRetries; attempt++) {
      if (attempt > 0) {
        const backoff = lastError?.retryAfter
          ? lastError.retryAfter * 1000
          : Math.min(2 ** attempt * 250, 4_000);
        await sleep(backoff);
      }

      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), this.timeout);
      try {
        const headers: Record<string, string> = {
          Authorization: `Bearer ${this.apiKey}`,
          'User-Agent': `jointextkit/${VERSION}`,
        };
        if (opts.body !== undefined) headers['Content-Type'] = 'application/json';
        if (opts.idempotencyKey) headers['Idempotency-Key'] = opts.idempotencyKey;

        const res = await this.fetchImpl(`${this.baseUrl}/v1${opts.path}`, {
          method: opts.method,
          headers,
          body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
          signal: controller.signal,
        });

        const text = await res.text();
        if (res.ok && opts.raw) return text as unknown as T;
        let json: any = {};
        try {
          json = text ? JSON.parse(text) : {};
        } catch {
          json = {};
        }

        if (res.ok) return json as T;

        const err = json?.error ?? {};
        lastError = new TextKitError(
          err.message || `Request failed with status ${res.status}`,
          {
            code: (err.code as TextKitErrorCode) || 'internal_error',
            status: res.status,
            param: err.param,
            reason: err.reason,
            balanceMicroUsd: err.balance_micro_usd,
            requiredMicroUsd: err.required_micro_usd,
            topUpUrl: err.top_up_url,
            sendAfter: err.send_after,
            recipientLocalTime: err.recipient_local_time,
            timezone: err.timezone,
            messageId: err.message_id,
            retryAfter:
              err.retry_after ??
              (res.headers.get('retry-after')
                ? Number(res.headers.get('retry-after'))
                : undefined),
          }
        );
      } catch (cause) {
        lastError = new TextKitError(
          cause instanceof Error && cause.name === 'AbortError'
            ? `Request timed out after ${this.timeout}ms`
            : `Could not reach the TextKit API: ${(cause as Error)?.message ?? cause}`,
          { code: 'connection_error', status: 0 }
        );
      } finally {
        clearTimeout(timer);
      }

      // Retry only when the caller marked it safe. A POST without an
      // idempotency key is never retried - resending an SMS because a response
      // was slow is worse than surfacing the error.
      if (!opts.retryable || !lastError.retryable) break;
      // A verify cooldown is a deliberate policy, not a transient failure.
      if (lastError.code === 'rate_limited' && opts.path.startsWith('/verify')) break;
    }

    throw lastError;
  }
}

// ── resources ───────────────────────────────────────────────────────────────

class Messages {
  constructor(private readonly client: TextKit) {}

  /**
   * Send an SMS. Retries are safe: an Idempotency-Key is generated
   * automatically when you don't supply one, so a network blip can never
   * double-send.
   *
   * `from` is optional when the account has one number for the key's mode
   * (your sandbox number with a test key, your one live number with a live
   * key). With a test key the message is simulated unless `to` is your own
   * verified phone: check `simulated` (and `notice`) on the result.
   */
  send(
    params: {
      from?: string;
      to: string;
      body: string;
      /** Attribute to one of your customers. Defaults to the from-number's customer. */
      customerId?: string;
      /**
       * Can make the message stricter (`'marketing'`), never looser: what a
       * message is comes from the from-number's registration and the
       * wording. A message outside its registration's use case throws
       * `campaign_mismatch`.
       */
      category?: MessageCategory;
      /**
       * Up to 10 labels of your own (a campaign, a flow), lowercased. On the
       * message, on its webhook events, and in deliverability by tag.
       */
      tags?: string[];
      /**
       * How the recipient agreed to your messages. A recurring
       * non-marketing message from a number linked to a registration needs
       * an opt-in on file for that registration; this records one when none
       * is. Never counts for marketing (use `consent.optIn` with proof).
       */
      consent?: { source: 'web_form' | 'keyword' | 'paper' | 'checkout' | 'verbal'; collectedAt: string | Date; pageUrl?: string };
      /**
       * For a marketing message in quiet hours: `'block'` throws
       * `quiet_hours` (with `sendAfter`); `'defer'` holds it until the
       * recipient's 8:00am and resolves with a `ScheduledMessage` (check
       * `object`). Omitted: your account default (refuse, unless changed).
       */
      quietHours?: QuietHoursAction;
    },
    options: { idempotencyKey?: string } = {}
  ): Promise<Message> {
    const { customerId, quietHours, consent, ...rest } = params;
    return this.client.request<Message>({
      method: 'POST',
      path: '/messages',
      body: {
        ...rest,
        customer_id: customerId,
        quiet_hours: quietHours,
        ...(consent
          ? {
              consent: {
                source: consent.source,
                collected_at: consent.collectedAt instanceof Date ? consent.collectedAt.toISOString() : consent.collectedAt,
                ...(consent.pageUrl ? { page_url: consent.pageUrl } : {}),
              },
            }
          : {}),
      },
      idempotencyKey: options.idempotencyKey ?? `sdk_${randomId()}`,
      retryable: true,
    });
  }

  get(id: string): Promise<Message> {
    return this.client.request({ method: 'GET', path: `/messages/${encodeURIComponent(id)}`, retryable: true });
  }

  /** Queue a message for later (up to 30 days ahead). */
  schedule(
    params: { from?: string; to: string; body: string; sendAt: Date | string; customerId?: string; category?: MessageCategory; quietHours?: QuietHoursAction; tags?: string[] }
  ): Promise<ScheduledMessage> {
    const { sendAt, customerId, quietHours, ...rest } = params;
    return this.client.request({
      method: 'POST',
      path: '/messages',
      body: { ...rest, scheduled_at: sendAt instanceof Date ? sendAt.toISOString() : sendAt, customer_id: customerId, quiet_hours: quietHours },
    });
  }

  list(params: ListMessagesParams = {}): Promise<Page<Message>> {
    const { customerId, scheduleId, blockedReason, failureCode, ...rest } = params;
    return this.client.request({
      method: 'GET',
      path: `/messages${query({ ...rest, customer_id: customerId, schedule_id: scheduleId, blocked_reason: blockedReason, failure_code: failureCode })}`,
      retryable: true,
    });
  }

  /** Every message, newest first, fetching pages as you iterate. */
  listAll(params: Omit<ListMessagesParams, 'cursor'> = {}): AsyncGenerator<Message> {
    return paginate((cursor) => this.list({ ...params, cursor }));
  }
}

interface VerifySendParams {
  /** The phone (E.164), or the email address with `channel: 'email'`. */
  to: string;
  appName?: string;
  /** Text only: send from a number you own. */
  from?: string;
  customerId?: string;
  /** Your end user's IP, as your server saw it: turns on the per-IP limit. */
  userIp?: string;
}

class Verify {
  constructor(private readonly client: TextKit) {}

  /**
   * Send a one-time code. You do not need to own a phone number; TextKit sends
   * from its own verification pool. With `channel: 'email'`, `to` is an email
   * address and the code goes by email.
   */
  send(params: VerifySendParams & { channel?: 'sms' }): Promise<Verification>;
  send(params: VerifySendParams & { channel: 'email' }): Promise<EmailVerification>;
  send(params: VerifySendParams & { channel?: VerificationChannel }): Promise<Verification | EmailVerification>;
  send(params: VerifySendParams & { channel?: VerificationChannel }): Promise<Verification | EmailVerification> {
    const email = params.channel === 'email';
    return this.client.request({
      method: 'POST',
      path: '/verify',
      body: {
        ...(email ? { channel: 'email', email: params.to } : { to: params.to }),
        app_name: params.appName,
        from: params.from,
        customer_id: params.customerId,
        user_ip: params.userIp,
      },
    });
  }

  /**
   * Check a code. `to` is where the code went: the phone for a texted code,
   * the email address for an emailed one. After `fallback` the code went by
   * email, so check it by the email address: a check by phone answers 409
   * `invalid_state`. You are billed only when `verified` is true.
   */
  check(params: { to: string; code: string }): Promise<VerificationCheck> {
    const body = params.to.includes('@') ? { email: params.to, code: params.code } : { to: params.to, code: params.code };
    return this.client.request({ method: 'POST', path: '/verify/check', body });
  }

  /**
   * The text didn't arrive: email a new code for the same verification (one
   * id, one charge). The emailed code replaces the texted one. Once per
   * verification, while it is pending.
   */
  fallback(id: string, params: { email: string; userIp?: string }): Promise<Verification> {
    return this.client.request({
      method: 'POST',
      path: `/verify/${encodeURIComponent(id)}/fallback`,
      body: { channel: 'email', email: params.email, user_ip: params.userIp },
    });
  }

  /** Typed as `Verification`; pass `EmailVerification` (or the union) for one you started by email. */
  get(id: string): Promise<Verification>;
  get<V extends Verification | EmailVerification>(id: string): Promise<V>;
  get(id: string): Promise<Verification | EmailVerification> {
    return this.client.request({ method: 'GET', path: `/verify/${encodeURIComponent(id)}`, retryable: true });
  }
}

/** A short-code or toll-free request filed with our team (`numbers.request`). */
export interface NumberRequest {
  object: 'number_request';
  id: string;
  type: 'short_code' | 'toll_free';
  business_name: string;
  monthly_volume: string;
  use_case: string;
  status: 'requested';
  created_at: string;
}

class Numbers {
  constructor(private readonly client: TextKit) {}

  /**
   * Ask our team for a short code (or a toll-free number they set up).
   * Provisions nothing by itself: carriers take 8-12 weeks to approve a short
   * code. One open request per type; asking again updates it.
   */
  request(params: {
    type: 'short_code' | 'toll_free';
    businessName: string;
    monthlyVolume: 'under_1k' | '1k_10k' | '10k_100k' | 'over_100k';
    useCase: string;
  }): Promise<NumberRequest> {
    return this.client.request({
      method: 'POST',
      path: '/numbers/requests',
      body: { type: params.type, business_name: params.businessName, monthly_volume: params.monthlyVolume, use_case: params.useCase },
    });
  }

  /** Open short-code and toll-free requests. */
  requests(): Promise<Page<NumberRequest>> {
    return this.client.request({ method: 'GET', path: '/numbers/requests', retryable: true });
  }

  available(params: { areaCode?: string } = {}): Promise<Page<AvailableNumber>> {
    return this.client.request({
      method: 'GET',
      path: `/numbers/available${query({ area_code: params.areaCode })}`,
      retryable: true,
    });
  }

  buy(phoneNumber: string, options: { customerId?: string } = {}): Promise<PhoneNumber> {
    return this.client.request({
      method: 'POST',
      path: '/numbers',
      body: { phone_number: phoneNumber, customer_id: options.customerId },
    });
  }

  list(params: { customerId?: string } = {}): Promise<Page<PhoneNumber>> {
    return this.client.request({
      method: 'GET',
      path: `/numbers${query({ customer_id: params.customerId })}`,
      retryable: true,
    });
  }

  /** Assign a number to a customer, or pass `customerId: null` to unassign it. */
  update(phoneNumber: string, params: { customerId: string | null }): Promise<PhoneNumber> {
    return this.client.request({
      method: 'PATCH',
      path: `/numbers/${encodeURIComponent(phoneNumber)}`,
      body: { customer_id: params.customerId },
      retryable: true,
    });
  }

  release(phoneNumber: string): Promise<PhoneNumber> {
    return this.client.request({ method: 'DELETE', path: `/numbers/${encodeURIComponent(phoneNumber)}` });
  }
}

export interface Balance {
  object: 'balance';
  /** Millionths of a dollar. */
  balance_micro_usd: number;
  balance_usd: number;
  currency: 'usd';
  low_balance_usd: number;
  auto_recharge: { enabled: boolean; threshold_usd: number; amount_usd: number };
  top_up_url: string;
}

class BalanceResource {
  constructor(private readonly client: TextKit) {}

  /** Your prepaid credit balance and auto-recharge setting. */
  get(): Promise<Balance> {
    return this.client.request({ method: 'GET', path: '/balance', retryable: true });
  }
}

export interface TrackedLink {
  object: 'link';
  url: string;
  name: string | null;
  short_url: string | null;
  click_id: string | null;
  texts: number;
  clicks: number;
  conversions: number;
  value_cents: number;
  test: boolean;
  created_at: string | null;
  last_activity_at: string | null;
}

export interface Conversion {
  id: string;
  object: 'conversion';
  click_id: string;
  url: string;
  name: string | null;
  external_id: string | null;
  value_cents: number;
  duplicate?: boolean;
  test: boolean;
  created_at: string;
}

/** Tracked links to copy anywhere, with their clicks and conversions. */
class Links {
  constructor(private readonly client: TextKit) {}

  /** The same url again returns the same link. */
  create(params: { url: string; name?: string }): Promise<TrackedLink> {
    return this.client.request({ method: 'POST', path: '/links', body: params });
  }

  list(): Promise<{ data: TrackedLink[]; has_more: boolean; next_cursor: string | null }> {
    return this.client.request({ method: 'GET', path: '/links', retryable: true });
  }
}

/** Sales and sign-ups from tracked links. */
class Conversions {
  constructor(private readonly client: TextKit) {}

  /** `click_id` is the `tk` value on the landing page URL. The same `external_id` counts once. */
  create(params: { click_id: string; value_cents?: number; name?: string; external_id?: string }): Promise<Conversion> {
    return this.client.request({ method: 'POST', path: '/conversions', body: params });
  }

  list(): Promise<{ data: Conversion[]; has_more: boolean; next_cursor: string | null }> {
    return this.client.request({ method: 'GET', path: '/conversions', retryable: true });
  }
}

class LookupResource {
  constructor(private readonly client: TextKit) {}

  phone(phoneNumber: string): Promise<Lookup> {
    return this.client.request({ method: 'GET', path: `/lookup/${encodeURIComponent(phoneNumber)}`, retryable: true });
  }

  /**
   * @deprecated Spam scores were retired on 2026-09-30. The endpoint now
   * answers 410, so this always throws a TextKitError with code
   * `endpoint_retired`. Use `phone()` for line type and carrier.
   */
  spam(phoneNumber: string): Promise<SpamLookup> {
    return this.client.request({
      method: 'GET',
      path: `/lookup/${encodeURIComponent(phoneNumber)}/spam`,
      retryable: true,
    });
  }
}

class Events {
  constructor(private readonly client: TextKit) {}

  list(params: { limit?: number; cursor?: string; type?: string } = {}): Promise<Page<SmsEvent>> {
    return this.client.request({ method: 'GET', path: `/events${query(params)}`, retryable: true });
  }

  listAll(params: { limit?: number; type?: string } = {}): AsyncGenerator<SmsEvent> {
    return paginate((cursor) => this.list({ ...params, cursor }));
  }

  /**
   * Long-poll for new events. Call once with no cursor to get a cursor that
   * means "from now", then keep calling with the cursor each answer hands
   * back: the request is held until an event arrives or `timeout` seconds
   * pass (0-25, default 20). An event can be returned twice; de-duplicate by
   * `id`. This is what `textkit listen` runs on.
   */
  wait(params: { cursor?: string; timeout?: number } = {}): Promise<EventWait> {
    return this.client.request({ method: 'GET', path: `/events/wait${query(params)}`, retryable: true });
  }

  /**
   * Tell TextKit something happened in your app. Automations listening for
   * the event start (or move on) for that person. Pass `phone`, `user_id`,
   * or both; a call with both links them, so later calls need only
   * `user_id`. Retries are safe: an Idempotency-Key is generated when you
   * don't supply one.
   */
  track(
    params: {
      event: string;
      user_id?: string;
      phone?: string;
      properties?: Record<string, string | number | boolean>;
    },
    options: { idempotencyKey?: string } = {}
  ): Promise<TrackedEvent> {
    return this.client.request<TrackedEvent>({
      method: 'POST',
      path: '/track',
      body: params,
      idempotencyKey: options.idempotencyKey ?? `sdk_${randomId()}`,
      retryable: true,
    });
  }
}

/**
 * Brand and campaign registrations (Compliance). `create` runs the website
 * and example checks; `recheck` corrects and re-runs them; `submit` files a
 * ready registration. The first submit for a business carries the
 * attestation signed by someone authorized to act for it; without one on
 * file the API answers `attestation_required`.
 */
class Registrations {
  constructor(private readonly client: TextKit) {}

  /** Create a registration. Runs the website check right away. */
  create(params: RegistrationParams & { business_name: string; website: string; use_case: string }): Promise<Registration> {
    return this.client.request({ method: 'POST', path: '/registrations', body: params });
  }

  get(id: string): Promise<Registration> {
    return this.client.request({ method: 'GET', path: `/registrations/${encodeURIComponent(id)}`, retryable: true });
  }

  list(): Promise<Page<Registration>> {
    return this.client.request({ method: 'GET', path: '/registrations', retryable: true });
  }

  /** Correct any field and re-run the checks (draft, checks_failed, ready or rejected). */
  recheck(id: string, params: RegistrationParams = {}): Promise<Registration> {
    return this.client.request({ method: 'POST', path: `/registrations/${encodeURIComponent(id)}/recheck`, body: params });
  }

  /**
   * Submit a ready registration (or resubmit after a rejection). Pass
   * `attestation` the first time for a business, or after our team could
   * not verify it; later submits for the same business need none. The
   * submission is held while we verify the business, then filed.
   *
   * `feesAcknowledged: true` is always required: it confirms the registration
   * fee terms (Terms §4.3): carrier registration fees are separate from the
   * per-message rate and billed at the registry's charge, a campaign carries a 3-month
   * minimum, and the fees are non-refundable even if the registration is
   * rejected. Without it the API answers 400 `invalid_request` (param
   * `fees_acknowledged`). The acknowledgment is kept on the filed copy.
   */
  submit(id: string, params: { attestation?: BusinessAttestation; feesAcknowledged: true }): Promise<Registration> {
    const { feesAcknowledged, ...rest } = params;
    return this.client.request({
      method: 'POST',
      path: `/registrations/${encodeURIComponent(id)}/submit`,
      body: { ...rest, fees_acknowledged: feesAcknowledged === true },
    });
  }

  /** The filed copies, oldest first: exactly what each submission sent. */
  submissions(id: string): Promise<Page<RegistrationSubmission>> {
    return this.client.request({ method: 'GET', path: `/registrations/${encodeURIComponent(id)}/submissions`, retryable: true });
  }
}

/**
 * Webhook endpoints: where events are POSTed. `create` returns the signing
 * secret once; keep it, the API never shows it again (the console can).
 * A restricted key needs the `webhooks:write` scope.
 */
class Webhooks {
  constructor(private readonly client: TextKit) {}

  /** Verify a delivery's signature and return the event. Same as the standalone `verifyWebhook`. */
  verify<T = SmsEvent>(opts: VerifyWebhookOptions): Promise<T> {
    return verifyWebhook<T>(opts);
  }

  list(): Promise<Page<WebhookEndpoint>> {
    return this.client.request({ method: 'GET', path: '/webhooks', retryable: true });
  }

  /** `events` omitted (or `'*'`) subscribes to everything. */
  create(params: { url: string; events?: '*' | string[]; description?: string }): Promise<CreatedWebhookEndpoint> {
    return this.client.request({ method: 'POST', path: '/webhooks', body: params });
  }

  get(id: string): Promise<WebhookEndpoint> {
    return this.client.request({ method: 'GET', path: `/webhooks/${encodeURIComponent(id)}`, retryable: true });
  }

  /** `active: false` pauses delivery without deleting the endpoint or its secret. */
  update(
    id: string,
    params: { url?: string; events?: '*' | string[]; active?: boolean; description?: string | null }
  ): Promise<WebhookEndpoint> {
    return this.client.request({ method: 'PATCH', path: `/webhooks/${encodeURIComponent(id)}`, body: params });
  }

  delete(id: string): Promise<{ id: string; object: 'webhook_endpoint'; deleted: true }> {
    return this.client.request({ method: 'DELETE', path: `/webhooks/${encodeURIComponent(id)}` });
  }

  /**
   * A new signing secret, returned once. `expirePreviousIn` (seconds, up to 7
   * days) keeps the old secret signing alongside it, so you can deploy the new
   * one without dropping events; `verify` accepts either.
   */
  rotateSecret(
    id: string,
    params: { expirePreviousIn?: number } = {}
  ): Promise<CreatedWebhookEndpoint & { previous_secret_expires_at: string | null }> {
    const body = params.expirePreviousIn !== undefined ? { expire_previous_in: params.expirePreviousIn } : {};
    return this.client.request({ method: 'POST', path: `/webhooks/${encodeURIComponent(id)}/rotate_secret`, body });
  }

  /** Send a signed `test.ping` to the endpoint now and return what it answered. */
  test(id: string): Promise<{
    object: 'webhook_test';
    endpoint_id: string;
    ok: boolean;
    status_code: number | null;
    error: string | null;
    latency_ms: number;
    response_body: string | null;
  }> {
    return this.client.request({ method: 'POST', path: `/webhooks/${encodeURIComponent(id)}/test` });
  }

  /**
   * Queue every event that failed to reach this endpoint between `since` and
   * `until` (default: the last 24 hours; up to 7 days, 50 events a call).
   * `more: true` means call again.
   */
  replayFailed(
    id: string,
    params: { since?: string | Date; until?: string | Date } = {}
  ): Promise<{ object: 'webhook_replay'; endpoint_id: string; since: string; until: string; queued: number; missing: string[]; more: boolean; limit: number }> {
    const iso = (d?: string | Date) => (d instanceof Date ? d.toISOString() : d);
    const body: Record<string, unknown> = {};
    if (params.since !== undefined) body.since = iso(params.since);
    if (params.until !== undefined) body.until = iso(params.until);
    return this.client.request({ method: 'POST', path: `/webhooks/${encodeURIComponent(id)}/replay`, body });
  }
}

function automationBody(params: AutomationParams): Record<string, unknown> {
  const body: Record<string, unknown> = {};
  if (params.name !== undefined) body.name = params.name;
  if (params.from !== undefined) body.from = params.from;
  if (params.topicId !== undefined) body.topic_id = params.topicId;
  if (params.category !== undefined) body.category = params.category;
  if (params.trigger !== undefined) body.trigger = params.trigger;
  if (params.steps !== undefined) body.steps = params.steps;
  return body;
}

function scheduleBody(params: ScheduleParams & { active?: boolean }): Record<string, unknown> {
  const body: Record<string, unknown> = {};
  if (params.to !== undefined) body.to = params.to;
  if (params.from !== undefined) body.from = params.from;
  if (params.body !== undefined) body.body = params.body;
  if (params.repeat !== undefined) body.repeat = params.repeat;
  if (params.startDate !== undefined) body.start_date = params.startDate;
  if (params.endDate !== undefined) body.end_date = params.endDate;
  if (params.maxOccurrences !== undefined) body.max_occurrences = params.maxOccurrences;
  if (params.active !== undefined) body.active = params.active;
  return body;
}

/**
 * Recurring schedules: one message to one number on a repeating local time.
 * Each occurrence is a normal send (opt-outs, quota and spend limit are
 * checked when it fires) and a normal message with `schedule_id`.
 */
class Schedules {
  constructor(private readonly client: TextKit) {}

  /** Create a schedule. Retries are safe: an Idempotency-Key is generated when you don't pass one. */
  create(
    params: ScheduleParams & { to: string; body: string; repeat: ScheduleRepeat },
    options: { idempotencyKey?: string } = {}
  ): Promise<Schedule> {
    return this.client.request({
      method: 'POST',
      path: '/schedules',
      body: scheduleBody(params),
      idempotencyKey: options.idempotencyKey ?? `sdk_${randomId()}`,
      retryable: true,
    });
  }

  /** One schedule, with its `recent_occurrences`. */
  get(id: string): Promise<Schedule> {
    return this.client.request({ method: 'GET', path: `/schedules/${encodeURIComponent(id)}`, retryable: true });
  }

  list(): Promise<Page<Schedule>> {
    return this.client.request({ method: 'GET', path: '/schedules', retryable: true });
  }

  /** Change any of to, from, body, repeat (send the whole object), startDate, endDate, maxOccurrences, active. */
  update(id: string, params: ScheduleParams & { active?: boolean }): Promise<Schedule> {
    return this.client.request({ method: 'PATCH', path: `/schedules/${encodeURIComponent(id)}`, body: scheduleBody(params), retryable: true });
  }

  /** Stop sending until resumed. */
  pause(id: string): Promise<Schedule> {
    return this.update(id, { active: false });
  }

  /** Start again from now: nothing that came due while paused is sent. */
  resume(id: string): Promise<Schedule> {
    return this.update(id, { active: true });
  }

  /** Stop it for good. Messages it already sent stay in the message log. */
  delete(id: string): Promise<{ id: string; object: 'schedule'; deleted: true }> {
    return this.client.request({ method: 'DELETE', path: `/schedules/${encodeURIComponent(id)}` });
  }
}


class Automations {
  constructor(private readonly client: TextKit) {}

  /** Create a flow as a draft. `issues` on the result lists what stops it from running. */
  create(params: AutomationParams & { name: string }): Promise<Automation> {
    return this.client.request({ method: 'POST', path: '/automations', body: automationBody(params) });
  }

  get(id: string): Promise<Automation> {
    return this.client.request({ method: 'GET', path: `/automations/${encodeURIComponent(id)}`, retryable: true });
  }

  list(): Promise<Page<Automation>> {
    return this.client.request({ method: 'GET', path: '/automations', retryable: true });
  }

  /** Change only the fields you pass. Editing an active flow publishes a new version. */
  update(id: string, params: AutomationParams): Promise<Automation> {
    return this.client.request({ method: 'PATCH', path: `/automations/${encodeURIComponent(id)}`, body: automationBody(params) });
  }

  /** Delete a flow. Runs in progress stop; nothing more is sent. */
  delete(id: string): Promise<{ id: string; object: 'automation'; deleted: true }> {
    return this.client.request({ method: 'DELETE', path: `/automations/${encodeURIComponent(id)}` });
  }

  /** Turn a flow on. Rejects with `invalid_request` when it is not ready. */
  activate(id: string): Promise<Automation> {
    return this.client.request({ method: 'POST', path: `/automations/${encodeURIComponent(id)}/activate`, retryable: true });
  }

  /** Stop new runs and hold the ones in progress until it is activated again. */
  pause(id: string): Promise<Automation> {
    return this.client.request({ method: 'POST', path: `/automations/${encodeURIComponent(id)}/pause`, retryable: true });
  }

  /** Runs of one flow, newest first. */
  runs(id: string, params: { limit?: number; cursor?: string } = {}): Promise<Page<AutomationRun>> {
    return this.client.request({
      method: 'GET',
      path: `/automations/${encodeURIComponent(id)}/runs${query(params)}`,
      retryable: true,
    });
  }

  run(id: string, runId: string): Promise<AutomationRun> {
    return this.client.request({
      method: 'GET',
      path: `/automations/${encodeURIComponent(id)}/runs/${encodeURIComponent(runId)}`,
      retryable: true,
    });
  }

  /** Cancel a run in progress. */
  cancelRun(id: string, runId: string): Promise<AutomationRun> {
    return this.client.request({
      method: 'DELETE',
      path: `/automations/${encodeURIComponent(id)}/runs/${encodeURIComponent(runId)}`,
    });
  }
}

class Consent {
  constructor(private readonly client: TextKit) {}

  /** Your suppression list: numbers currently opted out. */
  list(params: { limit?: number; cursor?: string } = {}): Promise<Page<ConsentRecord>> {
    return this.client.request({ method: 'GET', path: `/consent${query(params)}`, retryable: true });
  }

  listAll(params: { limit?: number } = {}): AsyncGenerator<ConsentRecord> {
    return paginate((cursor) => this.list({ ...params, cursor }));
  }

  /** Current status plus the append-only history for one number. */
  get(phone: string): Promise<ConsentDetail> {
    return this.client.request({ method: 'GET', path: `/consent/${encodeURIComponent(phone)}`, retryable: true });
  }

  /** Record an opt-out from your own system (CRM, web form, support tool). */
  optOut(phone: string, options: { note?: string } = {}): Promise<{ object: 'consent'; phone: string; status: 'opted_out' }> {
    return this.client.request({
      method: 'POST',
      path: `/consent/${encodeURIComponent(phone)}`,
      body: { status: 'opted_out', note: options.note },
      retryable: true,
    });
  }

  /**
   * Record a fresh opt-in. Only do this with the recipient's consent.
   * `campaignId` (a registration id) records it for that registration: what
   * a marketing send from the registration's numbers looks for. An opt-in
   * for a marketing or mixed registration must carry `proof`, and so must one
   * for a number that opted out, collected at or after the opt-out (409
   * otherwise).
   */
  optIn(
    phone: string,
    options: { note?: string; campaignId?: string; proof?: OptInProof } = {}
  ): Promise<{ object: 'consent'; phone: string; status: 'opted_in'; campaign_id?: string; proof?: Record<string, unknown> }> {
    const p = options.proof;
    return this.client.request({
      method: 'POST',
      path: `/consent/${encodeURIComponent(phone)}`,
      body: {
        status: 'opted_in',
        note: options.note,
        campaign_id: options.campaignId,
        proof: p
          ? {
              source: p.source,
              collected_at: p.collectedAt,
              page_url: p.pageUrl,
              disclosure: p.disclosure,
              ip: p.ip,
              user_agent: p.userAgent,
              message_id: p.messageId,
            }
          : undefined,
      },
      retryable: true,
    });
  }

  /** Bulk-import opt-outs (up to 500 per call). */
  import(phoneNumbers: string[]): Promise<ConsentImport> {
    return this.client.request({ method: 'POST', path: '/consent/import', body: { phone_numbers: phoneNumbers }, retryable: true });
  }

  /** The whole suppression list as CSV text. */
  export(): Promise<string> {
    return this.client.request({ method: 'GET', path: '/consent/export', retryable: true, raw: true });
  }
}

type CustomerParams = { name?: string | null; externalId?: string | null; metadata?: Record<string, string> | null };

function customerBody(params: CustomerParams): Record<string, unknown> {
  const body: Record<string, unknown> = {};
  if (params.name !== undefined) body.name = params.name;
  if (params.externalId !== undefined) body.external_id = params.externalId;
  if (params.metadata !== undefined) body.metadata = params.metadata;
  return body;
}

class Customers {
  constructor(private readonly client: TextKit) {}

  /** Create a customer: a business you send on behalf of. */
  create(params: CustomerParams = {}): Promise<Customer> {
    return this.client.request({ method: 'POST', path: '/customers', body: customerBody(params) });
  }

  get(id: string): Promise<Customer> {
    return this.client.request({ method: 'GET', path: `/customers/${encodeURIComponent(id)}`, retryable: true });
  }

  /** Change only the fields you pass. `metadata` replaces the whole object. */
  update(id: string, params: CustomerParams): Promise<Customer> {
    return this.client.request({
      method: 'PATCH',
      path: `/customers/${encodeURIComponent(id)}`,
      body: customerBody(params),
      retryable: true,
    });
  }

  /** Delete a customer. Its numbers stay yours, unassigned. */
  delete(id: string): Promise<{ id: string; object: 'customer'; deleted: true }> {
    return this.client.request({ method: 'DELETE', path: `/customers/${encodeURIComponent(id)}` });
  }

  list(params: { limit?: number; cursor?: string; externalId?: string } = {}): Promise<Page<Customer>> {
    const { externalId, ...rest } = params;
    return this.client.request({
      method: 'GET',
      path: `/customers${query({ ...rest, external_id: externalId })}`,
      retryable: true,
    });
  }

  listAll(params: { limit?: number } = {}): AsyncGenerator<Customer> {
    return paginate((cursor) => this.list({ ...params, cursor }));
  }

  /** Usage for a UTC date range (`YYYY-MM-DD`, default: this month to date). */
  usage(id: string, params: { start?: string; end?: string } = {}): Promise<CustomerUsage> {
    return this.client.request({
      method: 'GET',
      path: `/customers/${encodeURIComponent(id)}/usage${query(params)}`,
      retryable: true,
    });
  }
}

function contactBody(params: Partial<ContactParams> & { name?: string | null; notes?: string | null }): Record<string, unknown> {
  const body: Record<string, unknown> = {};
  if (params.phoneNumber !== undefined) body.phone_number = params.phoneNumber;
  if (params.name !== undefined) body.name = params.name;
  if (params.tags !== undefined) body.tags = params.tags;
  if (params.fields !== undefined) body.fields = params.fields;
  if (params.notes !== undefined) body.notes = params.notes;
  return body;
}

class Contacts {
  constructor(private readonly client: TextKit) {}

  /**
   * Create a contact, or update the one that already has this number (one
   * contact per number). Values you leave out are kept; tags are added.
   */
  upsert(params: ContactParams): Promise<Contact> {
    return this.client.request({ method: 'POST', path: '/contacts', body: contactBody(params), retryable: true });
  }

  /** Upsert up to 500 contacts in one call: the way to sync from your own database. */
  import(contacts: ContactParams[]): Promise<ContactImport> {
    return this.client.request({
      method: 'POST',
      path: '/contacts/import',
      body: { contacts: contacts.map(contactBody) },
      retryable: true,
    });
  }

  /** Add tags, remove tags, or delete, for up to 500 contact ids in one call. */
  bulk(params: { action: 'add_tags' | 'remove_tags' | 'delete'; ids: string[]; tags?: string[] }): Promise<ContactBulk> {
    return this.client.request({ method: 'POST', path: '/contacts/bulk', body: params });
  }

  /**
   * Consent for a phone number: whether you may text it, when and how it
   * opted out, and its full history. Same as `consent.get(phone)`; here
   * because it is where people look for it.
   */
  consent(phoneNumber: string): Promise<ConsentDetail> {
    return this.client.consent.get(phoneNumber);
  }

  get(id: string): Promise<Contact> {
    return this.client.request({ method: 'GET', path: `/contacts/${encodeURIComponent(id)}`, retryable: true });
  }

  /** Change only the fields you pass. `tags` and `fields` replace what is stored; `null` clears name or notes. */
  update(id: string, params: Partial<ContactParams> & { name?: string | null; notes?: string | null }): Promise<Contact> {
    return this.client.request({
      method: 'PATCH',
      path: `/contacts/${encodeURIComponent(id)}`,
      body: contactBody(params),
      retryable: true,
    });
  }

  delete(id: string): Promise<{ id: string; object: 'contact'; deleted: true }> {
    return this.client.request({ method: 'DELETE', path: `/contacts/${encodeURIComponent(id)}` });
  }

  /** Newest first. `phoneNumber` finds the one contact holding it; `tag` narrows to a tag. */
  list(params: { limit?: number; cursor?: string; tag?: string; phoneNumber?: string } = {}): Promise<Page<Contact>> {
    const { phoneNumber, ...rest } = params;
    return this.client.request({
      method: 'GET',
      path: `/contacts${query({ ...rest, phone_number: phoneNumber })}`,
      retryable: true,
    });
  }

  listAll(params: { limit?: number; tag?: string } = {}): AsyncGenerator<Contact> {
    return paginate((cursor) => this.list({ ...params, cursor }));
  }
}

async function* paginate<T>(fetchPage: (cursor?: string) => Promise<Page<T>>): AsyncGenerator<T> {
  let cursor: string | undefined;
  for (;;) {
    const page = await fetchPage(cursor);
    for (const item of page.data) yield item;
    if (!page.has_more || !page.next_cursor) return;
    cursor = page.next_cursor;
  }
}

// ── webhooks ────────────────────────────────────────────────────────────────

export interface VerifyWebhookOptions {
  /** The raw request body, exactly as received. Not re-serialized JSON. */
  payload: string | Uint8Array;
  /**
   * The `textkit-signature` header: `t=<unix seconds>,v1=<hex>`. The same
   * value is also sent as `dsms-signature` and `resms-signature`; any of them
   * verifies. Or pass `headers` and let the SDK find it.
   */
  signature?: string | null;
  /**
   * The request's headers (a `Headers`, or a plain object such as Node's
   * `req.headers`). Used when `signature` is not given: the first of
   * `textkit-signature`, `dsms-signature`, `resms-signature` present wins.
   */
  headers?: WebhookHeaders | null;
  /** Your endpoint's signing secret (`whsec_...`). */
  secret: string;
  /** Reject signatures older (or newer) than this many seconds. Default 300. 0 disables. */
  toleranceSec?: number;
  /** Clock override, unix seconds. For tests. */
  now?: number;
}

export type WebhookHeaders =
  | { get(name: string): string | null }
  | Record<string, string | string[] | undefined>;

/** Every header name the signature has been sent under, current first. */
export const SIGNATURE_HEADERS = ['textkit-signature', 'dsms-signature', 'resms-signature'] as const;
/** Every header name the event id has been sent under, current first. */
export const EVENT_ID_HEADERS = ['textkit-event-id', 'dsms-event-id', 'resms-event-id'] as const;

function headerValue(headers: WebhookHeaders | null | undefined, names: readonly string[]): string | null {
  if (!headers) return null;
  const viaGet = typeof (headers as any).get === 'function';
  const lower: Record<string, string | string[] | undefined> = {};
  if (!viaGet) for (const [k, v] of Object.entries(headers)) lower[k.toLowerCase()] = v as string | string[] | undefined;
  for (const name of names) {
    const v = viaGet ? (headers as { get(n: string): string | null }).get(name) : lower[name];
    const s = Array.isArray(v) ? v[0] : v;
    if (s) return s;
  }
  return null;
}

/** The webhook signature from a request's headers, under whichever name it arrived. */
export function signatureFromHeaders(headers: WebhookHeaders | null | undefined): string | null {
  return headerValue(headers, SIGNATURE_HEADERS);
}

/** The event id (`evt_...`, stable across retries) from a request's headers. */
export function eventIdFromHeaders(headers: WebhookHeaders | null | undefined): string | null {
  return headerValue(headers, EVENT_ID_HEADERS);
}

const encoder = new TextEncoder();

async function hmacSha256Hex(secret: string, message: Uint8Array): Promise<string> {
  let subtle: SubtleCrypto | undefined = (globalThis as any).crypto?.subtle;
  if (!subtle) {
    // Node 18 without the global: fall back to node:crypto's WebCrypto.
    const nodeCrypto: any = await import('node:crypto' as string);
    subtle = nodeCrypto.webcrypto.subtle as SubtleCrypto;
  }
  const key = await subtle.importKey('raw', encoder.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await subtle.sign('HMAC', key, message as BufferSource));
  return Array.from(sig, (b) => b.toString(16).padStart(2, '0')).join('');
}

function timingSafeEqualHex(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/**
 * Verify a webhook from TextKit and return the parsed event. Throws a
 * TextKitError with code `invalid_signature` when the signature is missing,
 * wrong, or outside the timestamp tolerance (replay protection).
 *
 * Scheme: `textkit-signature: t=<unix seconds>,v1=<hex>` where
 * v1 = HMAC-SHA256(secret, `${t}.${rawBody}`).
 */
export async function verifyWebhook<T = SmsEvent>(opts: VerifyWebhookOptions): Promise<T> {
  const fail = (message: string) => new TextKitError(message, { code: 'invalid_signature', status: 400 });
  if (!opts.secret) throw fail('No webhook secret given.');
  const signature = opts.signature || signatureFromHeaders(opts.headers);
  if (!signature) throw fail('Missing textkit-signature header.');

  let t: number | null = null;
  const v1: string[] = [];
  for (const part of signature.split(',')) {
    const i = part.indexOf('=');
    if (i < 0) continue;
    const k = part.slice(0, i).trim();
    const v = part.slice(i + 1).trim();
    if (k === 't' && /^\d+$/.test(v)) t = Number(v);
    else if (k === 'v1') v1.push(v.toLowerCase());
  }
  if (t === null || v1.length === 0) throw fail('Malformed textkit-signature header.');

  const tolerance = opts.toleranceSec ?? 300;
  const now = opts.now ?? Math.floor(Date.now() / 1000);
  if (tolerance > 0 && Math.abs(now - t) > tolerance) {
    throw fail('Webhook timestamp is outside the tolerance window.');
  }

  const raw = typeof opts.payload === 'string' ? encoder.encode(opts.payload) : opts.payload;
  const prefix = encoder.encode(`${t}.`);
  const signed = new Uint8Array(prefix.length + raw.length);
  signed.set(prefix);
  signed.set(raw, prefix.length);
  const expected = await hmacSha256Hex(opts.secret, signed);
  if (!v1.some((sig) => timingSafeEqualHex(sig, expected))) throw fail('Webhook signature does not match.');

  const text = typeof opts.payload === 'string' ? opts.payload : new TextDecoder().decode(opts.payload);
  return JSON.parse(text) as T;
}

/**
 * Sign a payload the way TextKit signs a delivery, and return the value of
 * the `textkit-signature` header. For testing a webhook handler without a
 * real delivery; `textkit listen` uses it to replay events to localhost.
 */
export async function signWebhook(opts: { payload: string; secret: string; timestamp?: number }): Promise<string> {
  const t = opts.timestamp ?? Math.floor(Date.now() / 1000);
  return `t=${t},v1=${await hmacSha256Hex(opts.secret, encoder.encode(`${t}.${opts.payload}`))}`;
}

/**
 * The exact request TextKit would POST for `event`: the JSON body and every
 * signature / event-id header a delivery carries (the current names and the
 * pre-rename ones, with identical values).
 */
export async function signedWebhookRequest(
  event: SmsEvent,
  secret: string,
  opts: { timestamp?: number } = {}
): Promise<{ body: string; headers: Record<string, string> }> {
  const body = JSON.stringify(event);
  const signature = await signWebhook({ payload: body, secret, timestamp: opts.timestamp });
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  SIGNATURE_HEADERS.forEach((name) => (headers[name] = signature));
  EVENT_ID_HEADERS.forEach((name) => (headers[name] = event.id));
  return { body, headers };
}

/** The API base URL the client would use with no `baseUrl` option. */
export function defaultBaseUrl(): string {
  const env = (globalThis as any).process?.env ?? {};
  return (envBaseUrl(env) ?? DEFAULT_BASE_URL).replace(/\/$/, '');
}

function query(params: Record<string, unknown>): string {
  const entries = Object.entries(params).filter(([, v]) => v !== undefined && v !== null);
  if (entries.length === 0) return '';
  return `?${entries.map(([k, v]) => `${k}=${encodeURIComponent(String(v))}`).join('&')}`;
}

/**
 * @deprecated TextKit was called Delivered until 2026-10. `Delivered` is the
 * same class as `TextKit`; existing imports keep working, new code should
 * use `TextKit`.
 */
export const Delivered = TextKit;
/** @deprecated Use `TextKit`. */
export type Delivered = TextKit;
/** @deprecated Use `TextKitError`. Same class, so `instanceof` works either way. */
export const DeliveredError = TextKitError;
/** @deprecated Use `TextKitError`. */
export type DeliveredError = TextKitError;
/** @deprecated Use `TextKitErrorCode`. */
export type DeliveredErrorCode = TextKitErrorCode;

/**
 * @deprecated TextKit was called SimpleSMS until 2026-10-28 (npm `joinsimplesms`).
 * `SimpleSMS` is the same class as `TextKit`; new code should use `TextKit`.
 */
export const SimpleSMS = TextKit;
/** @deprecated Use `TextKit`. */
export type SimpleSMS = TextKit;
/** @deprecated Use `TextKitError`. Same class, so `instanceof` works either way. */
export const SimpleSMSError = TextKitError;
/** @deprecated Use `TextKitError`. */
export type SimpleSMSError = TextKitError;
/** @deprecated Use `TextKitErrorCode`. */
export type SimpleSMSErrorCode = TextKitErrorCode;
/** @deprecated Use `TextKitOptions`. */
export type DeliveredOptions = TextKitOptions;

export default TextKit;
