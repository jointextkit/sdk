"""Response shapes. Every call returns plain JSON dicts; these TypedDicts give
your editor and type checker the keys. Optional keys are only present when the
API has a value for them (e.g. ``customer_id`` when a message is attributed)."""
from __future__ import annotations

from typing import Any, Dict, List, Literal, Optional, TypedDict, Union

# "blocked": refused by a send check before any carrier saw it; never charged.
MessageStatus = Literal["queued", "sent", "delivered", "failed", "blocked", "received"]
# What a message is, for quiet hours. Only "marketing" is held or refused at night.
MessageCategory = Literal["marketing", "transactional", "otp"]
QuietHoursAction = Literal["block", "defer"]
VerificationStatus = Literal["pending", "approved", "expired", "max_attempts", "blocked"]
VerificationChannel = Literal["sms", "email"]


class _MessageOptional(TypedDict, total=False):
    media: List[str]
    sent_by: str
    failure_reason: str
    customer_id: str
    # The recurring schedule this message is an occurrence of.
    schedule_id: str
    # The labels it was sent with (``tags`` on messages.send), lowercased.
    tags: List[str]
    # How the message was classified for quiet hours, when it was.
    category: str
    # Present when the message was held for quiet hours, then sent.
    deferred: Dict[str, Any]
    # Only on the response to messages.send: a test-key send to a real-looking
    # number was simulated.
    notice: str


class Message(_MessageOptional):
    id: str
    object: Literal["message"]
    to: str
    # "from" is a keyword in Python; read it as message["from"].
    body: str
    direction: Literal["outbound", "inbound"]
    status: MessageStatus
    test: bool
    # True when nothing was handed to a carrier: every test-key message except
    # one sent to your own verified phone. Always False on live messages.
    simulated: bool
    created_at: str


class _ScheduledOptional(TypedDict, total=False):
    customer_id: str


class ScheduledMessage(_ScheduledOptional):
    id: str
    object: Literal["scheduled_message"]
    to: str
    body: str
    # When it will send.
    scheduled_at: str
    # Deprecated: the same value as scheduled_at, under its older name.
    run_at: str
    status: Literal["queued"]


class _ScheduleRepeatOptional(TypedDict, total=False):
    days_of_week: List[str]
    day_of_month: int


class ScheduleRepeat(_ScheduleRepeatOptional):
    frequency: Literal["daily", "weekly", "monthly"]
    # 24-hour local time "HH:MM", in the IANA zone `timezone`.
    time: str
    timezone: str


class _ScheduleOptional(TypedDict, total=False):
    # Only on schedules.get: the last 10 occurrences, newest first.
    recent_occurrences: List[Dict[str, Any]]


class Schedule(_ScheduleOptional):
    """A recurring schedule (POST /v1/schedules)."""

    id: str
    object: Literal["schedule"]
    to: str
    # "from" is a keyword in Python; read it as schedule["from"].
    body: str
    repeat: ScheduleRepeat
    start_date: Optional[str]
    end_date: Optional[str]
    max_occurrences: Optional[int]
    active: bool
    status: Literal["active", "paused", "completed"]
    paused_reason: Optional[str]
    next_run_at: Optional[str]
    last_run_at: Optional[str]
    last_status: Optional[str]
    last_error: Optional[str]
    last_message_id: Optional[str]
    counts: Dict[str, int]
    test: bool
    created_at: str
    updated_at: str


class DeletedSchedule(TypedDict):
    id: str
    object: Literal["schedule"]
    deleted: bool


class _VerificationOptional(TypedDict, total=False):
    customer_id: str
    charged: bool
    # When the verification moved from text to email (``verify.fallback``).
    fallback_at: str


class Verification(_VerificationOptional):
    id: str
    object: Literal["verification"]
    # The channel the current code went out on; ``check`` accepts that code only.
    channel: VerificationChannel
    # Set on every verification started by text, also after a fallback to
    # email. None only on one started by email.
    phone: Optional[str]
    # None until a code is emailed.
    email: Optional[str]
    status: VerificationStatus
    attempts: int
    attempts_remaining: int
    max_attempts: int
    test: bool
    created_at: str
    expires_at: str
    expires_in: int


class VerificationCheck(TypedDict):
    verified: bool
    channel: VerificationChannel
    status: VerificationStatus
    attempts: int
    attempts_remaining: int
    max_attempts: int
    charged: bool


class PhoneNumber(TypedDict):
    id: str
    object: Literal["number"]
    phone_number: str
    status: Literal["active", "released"]
    mode: Literal["test", "live"]
    created_at: str
    customer_id: Optional[str]


class AvailableNumber(TypedDict):
    object: Literal["available_number"]
    phone_number: str
    locality: str
    region: str


class Lookup(TypedDict):
    phone_number: str
    valid: bool
    line_type: Optional[str]
    carrier: Dict[str, Optional[str]]
    caller_name: Optional[str]


class Event(TypedDict):
    id: str
    object: Literal["event"]
    type: str
    created_at: str
    data: Dict[str, Any]


class _ConsentRecordOptional(TypedDict, total=False):
    method: str
    detected: str
    confidence: float


class ConsentRecord(_ConsentRecordOptional):
    object: Literal["consent"]
    phone: str
    status: Literal["opted_out"]
    updated_at: str
    via: str


class _ConsentDetailOptional(TypedDict, total=False):
    # Present only while the number is opted out.
    opted_out_at: str
    opted_out_via: str
    opted_out_method: str
    blocked_sends: int
    last_blocked_at: Optional[str]


class ConsentDetail(_ConsentDetailOptional):
    object: Literal["consent"]
    phone: str
    status: Literal["opted_out", "opted_in", "none"]
    history: List[Dict[str, Any]]


class _ConsentUpdateOptional(TypedDict, total=False):
    campaign_id: str
    proof: Dict[str, Any]


class ConsentUpdate(_ConsentUpdateOptional):
    object: Literal["consent"]
    phone: str
    status: Literal["opted_out", "opted_in"]


class OptInProof(TypedDict, total=False):
    """Opt-in evidence. Required for an opt-in recorded for a marketing or mixed registration:
    ``source``, ``collected_at``, and ``page_url`` (web_form) or ``message_id`` (keyword)."""

    source: Literal["web_form", "keyword", "paper", "checkout", "verbal"]
    collected_at: str
    page_url: str
    disclosure: str
    ip: str
    user_agent: str
    message_id: str


class ConsentImport(TypedDict):
    object: Literal["consent_import"]
    imported: int
    skipped: List[Dict[str, str]]


class _CustomerOptional(TypedDict, total=False):
    phone_numbers: List[str]


class Customer(_CustomerOptional):
    id: str
    object: Literal["customer"]
    name: Optional[str]
    external_id: Optional[str]
    metadata: Dict[str, str]
    created_at: str
    updated_at: str


class Contact(TypedDict):
    id: str
    object: Literal["contact"]
    phone_number: str
    name: Optional[str]
    tags: List[str]
    fields: Dict[str, str]
    notes: Optional[str]
    created_at: str
    updated_at: str


class DeletedContact(TypedDict):
    id: str
    object: Literal["contact"]
    deleted: bool


class ContactImportSkipped(TypedDict):
    index: int
    value: str
    reason: str


class ContactImport(TypedDict):
    object: Literal["contact_import"]
    created: int
    updated: int
    skipped: List[ContactImportSkipped]


class ContactBulk(TypedDict):
    object: Literal["contact_bulk"]
    action: Literal["add_tags", "remove_tags", "delete"]
    updated: int
    deleted: int
    missing: int


class DeletedCustomer(TypedDict):
    id: str
    object: Literal["customer"]
    deleted: bool


class CustomerUsageDay(TypedDict):
    date: str
    messages_sent: int
    messages_failed: int
    messages_received: int
    verifications_sent: int
    verifications_approved: int


class CustomerUsage(TypedDict):
    object: Literal["customer_usage"]
    customer_id: str
    mode: Literal["test", "live"]
    start: str
    end: str
    messages_sent: int
    messages_failed: int
    messages_received: int
    verifications_sent: int
    verifications_approved: int
    numbers: int
    phone_numbers: List[str]
    daily: List[CustomerUsageDay]


class EventWait(TypedDict):
    """What ``events.wait`` answers. ``data`` is oldest first and may repeat an
    event already returned (de-duplicate by ``id``); pass ``cursor`` back."""

    object: Literal["event_wait"]
    data: List[Event]
    cursor: str
    has_more: bool


class WebhookEndpoint(TypedDict):
    id: str
    object: Literal["webhook_endpoint"]
    url: str
    #: ``"*"`` for every event, or the subscribed types.
    events: Union[str, List[str]]
    active: bool
    description: Optional[str]
    created_at: str


class CreatedWebhookEndpoint(WebhookEndpoint):
    """A just-created endpoint. ``secret`` is returned this once and never again."""

    secret: str


class DeletedWebhookEndpoint(TypedDict):
    id: str
    object: Literal["webhook_endpoint"]
    deleted: bool


RegistrationStatus = Literal["draft", "checks_failed", "ready", "submitted", "in_review", "approved", "rejected"]


class RegistrationGuidance(TypedDict):
    what_happened: str
    why: str
    next_actor: Literal["you", "textkit", "carriers", "nobody"]
    next_step: str
    after: str


class Registration(TypedDict):
    """A brand and campaign registration. ``brand`` holds the business as the
    carriers register it, including the authorized representative
    (``contact_name``, ``contact_title``, ``contact_email``, ``contact_phone``)."""

    id: str
    object: Literal["registration"]
    status: RegistrationStatus
    business_name: str
    website: str
    use_case: str
    brand: Dict[str, Any]
    sample_messages: List[str]
    samples_source: Literal["starter", "customer"]
    guidance: RegistrationGuidance
    check: Optional[Dict[str, Any]]
    sample_check: Dict[str, Any]
    rejection: Optional[Dict[str, Any]]
    generated: Dict[str, Any]
    submissions: int
    history: List[Dict[str, Any]]
    created_at: str
    updated_at: str


class Page(TypedDict):
    """One page of a list. Pass ``next_cursor`` back as ``cursor`` for the next,
    or use the resource's ``list_all()`` iterator and skip the bookkeeping."""

    data: List[Any]
    has_more: bool
    next_cursor: Optional[str]


class TrackedEvent(TypedDict):
    """What ``events.track`` answers: the event, and what it did."""

    id: str
    object: Literal["tracked_event"]
    event: str
    user_id: Optional[str]
    phone: Optional[str]
    properties: Dict[str, Any]
    test: bool
    runs_started: List[str]
    runs_notified: int
    created_at: str


class Automation(TypedDict, total=False):
    id: str
    object: Literal["automation"]
    name: str
    status: Literal["draft", "active", "paused"]
    trigger: Dict[str, Any]
    steps: List[Dict[str, Any]]
    # "from" is a Python keyword, so it cannot be declared here; read it with automation["from"].
    topic_id: Optional[str]
    test: Optional[bool]
    version: int
    unpublished_changes: bool
    stats: Dict[str, Any]
    issues: List[Dict[str, str]]
    created_at: str
    updated_at: str


class DeletedAutomation(TypedDict):
    id: str
    object: Literal["automation"]
    deleted: bool


class AutomationRun(TypedDict):
    id: str
    object: Literal["automation_run"]
    automation_id: str
    automation_version: int
    status: Literal["running", "waiting", "completed", "failed"]
    to: str
    user_id: Optional[str]
    test: bool
    trigger_event: str
    step: int
    waiting_until: Optional[str]
    waiting_for_event: Optional[str]
    end_reason: Optional[str]
    messages_sent: int
    messages_failed: int
    timeline: List[Dict[str, Any]]
    started_at: str
    ended_at: Optional[str]
