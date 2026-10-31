import Foundation

/// Every failure the client throws.
///
/// `code` is the API's machine-readable error code (`"rate_limited"`,
/// `"invalid_request"`, ...), plus two the client adds itself:
/// `"connection_error"` (the API was unreachable or timed out) and
/// `"invalid_signature"` (a webhook failed verification).
public struct TextKitError: Error, Sendable, CustomStringConvertible, LocalizedError {
    public let message: String
    /// The API's error code, e.g. `"insufficient_credits"`.
    public let code: String
    /// HTTP status; 0 when the API was never reached (or the client refused the call itself).
    public let status: Int
    /// Which request field was wrong, when the API could tell.
    public var param: String?
    /// Seconds to wait, on rate limits.
    public var retryAfter: Double?
    /// Why a verification was blocked.
    public var reason: String?
    /// `insufficient_credits` only: your balance, in millionths of a dollar.
    public var balanceMicroUsd: Int64?
    /// `insufficient_credits` only: what the call costs, in millionths of a dollar.
    public var requiredMicroUsd: Int64?
    /// `insufficient_credits` only: where to add credits.
    public var topUpUrl: String?
    /// `quiet_hours` only: when the message may be sent (ISO timestamp).
    public var sendAfter: String?
    /// `quiet_hours` only: the recipient's local time, 24-hour "HH:MM".
    public var recipientLocalTime: String?
    /// `quiet_hours` only: the IANA time zone read from the number's area code.
    public var timezone: String?
    /// The blocked message stored in your log for this refusal, when there is one.
    public var messageId: String?

    public init(_ message: String, code: String, status: Int, param: String? = nil) {
        self.message = message
        self.code = code
        self.status = status
        self.param = param
    }

    /// True when retrying the same call later could plausibly succeed.
    public var isRetryable: Bool {
        status >= 500 || code == "rate_limited" || code == "carrier_error" || code == "connection_error"
    }

    public var description: String { "TextKitError(code: \(code), status: \(status), message: \(message))" }
    public var errorDescription: String? { message }
}
