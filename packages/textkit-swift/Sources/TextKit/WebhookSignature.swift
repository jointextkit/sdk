import Crypto
import Foundation

/// Webhook signature verification.
///
/// Every webhook carries `textkit-signature: t=<unix seconds>,v1=<hex>` where
/// `v1 = HMAC-SHA256(secret, "<t>.<raw body>")`. Verify against the raw request
/// body exactly as received; re-serialized JSON will not match.
///
/// The same value is also sent as `dsms-signature` and `resms-signature` (older
/// header names), so passing the whole headers dictionary finds it under any of them.
///
/// ```swift
/// // Vapor
/// app.post("webhooks", "textkit") { req async throws -> HTTPStatus in
///     let body = req.body.data.map { Data(buffer: $0) } ?? Data()
///     let event = try WebhookSignature.verify(
///         payload: body,
///         signature: req.headers.first(name: "textkit-signature"),
///         secret: Environment.get("TEXTKIT_WEBHOOK_SECRET")!
///     )
///     ...
/// }
/// ```
public enum WebhookSignature {
    public static let defaultTolerance: TimeInterval = 300

    /// Every header name the signature has been sent under, current first.
    public static let signatureHeaders = ["textkit-signature", "dsms-signature", "resms-signature"]
    /// Every header name the event id has been sent under, current first.
    public static let eventIdHeaders = ["textkit-event-id", "dsms-event-id", "resms-event-id"]

    /// The signature from a request's headers, whichever name it arrived under, matched case-insensitively.
    public static func signature(from headers: [String: String]) -> String? { header(headers, signatureHeaders) }

    /// The event id (`evt_...`, stable across retries) from a request's headers.
    public static func eventId(from headers: [String: String]) -> String? { header(headers, eventIdHeaders) }

    /// Verify a webhook and return the parsed event.
    ///
    /// - Parameters:
    ///   - payload: the raw request body.
    ///   - signature: the `textkit-signature` header value.
    ///   - secret: your endpoint's signing secret (`whsec_...`).
    ///   - tolerance: max age in seconds, either direction; 0 disables the check.
    ///     300 stops replays of captured requests.
    ///   - now: the current time (tests); defaults to the clock.
    /// - Throws: ``TextKitError`` with code `invalid_signature`.
    public static func verify(
        payload: Data,
        signature: String?,
        secret: String,
        tolerance: TimeInterval = defaultTolerance,
        now: Date = Date()
    ) throws -> Event {
        guard !secret.isEmpty else { throw fail("No webhook secret given.") }
        guard let signature, !signature.isEmpty else { throw fail("Missing textkit-signature header.") }

        var timestamp: Int64?
        var candidates: [String] = []
        for part in signature.split(separator: ",", omittingEmptySubsequences: false) {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = part[..<eq].trimmingCharacters(in: .whitespaces)
            let value = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if key == "t", !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) {
                timestamp = Int64(value)
            } else if key == "v1" {
                candidates.append(value.lowercased())
            }
        }
        guard let t = timestamp, !candidates.isEmpty else { throw fail("Malformed textkit-signature header.") }

        let current = Int64(now.timeIntervalSince1970.rounded(.down))
        if tolerance > 0 && Double(abs(current - t)) > tolerance {
            throw fail("Webhook timestamp is outside the tolerance window.")
        }

        let key = SymmetricKey(data: Data(secret.utf8))
        var signed = Data("\(t).".utf8)
        signed.append(payload)
        // isValidAuthenticationCode compares in constant time. Any v1 may match
        // (there are two during a secret rotation).
        var matched = false
        for candidate in candidates {
            if let mac = hexBytes(candidate), HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: signed, using: key) {
                matched = true
            }
        }
        guard matched else { throw fail("Webhook signature does not match.") }

        do {
            return try JSONDecoder().decode(Event.self, from: payload)
        } catch {
            throw TextKitError("Webhook body is not a TextKit event.", code: "invalid_signature", status: 400)
        }
    }

    /// ``verify(payload:signature:secret:tolerance:now:)`` with the body as a string (UTF-8).
    public static func verify(
        payload: String,
        signature: String?,
        secret: String,
        tolerance: TimeInterval = defaultTolerance,
        now: Date = Date()
    ) throws -> Event {
        try verify(payload: Data(payload.utf8), signature: signature, secret: secret, tolerance: tolerance, now: now)
    }

    /// ``verify(payload:signature:secret:tolerance:now:)`` reading the signature from the request's headers.
    public static func verify(
        payload: Data,
        headers: [String: String],
        secret: String,
        tolerance: TimeInterval = defaultTolerance,
        now: Date = Date()
    ) throws -> Event {
        try verify(payload: payload, signature: signature(from: headers), secret: secret, tolerance: tolerance, now: now)
    }

    private static func fail(_ message: String) -> TextKitError {
        TextKitError(message, code: "invalid_signature", status: 400)
    }

    private static func hexBytes(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    private static func header(_ headers: [String: String], _ names: [String]) -> String? {
        var lowered: [String: String] = [:]
        for (k, v) in headers where lowered[k.lowercased()] == nil { lowered[k.lowercased()] = v }
        for name in names {
            if let v = lowered[name], !v.isEmpty { return v }
        }
        return nil
    }
}
