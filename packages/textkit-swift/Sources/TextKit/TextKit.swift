import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The TextKit client, for servers (Vapor, Hummingbird, scripts, jobs).
///
/// ```swift
/// let client = try TextKit()                       // reads TEXTKIT_API_KEY
/// let message = try await client.messages.send(to: "+15005550006", body: "Hello from TextKit")
/// ```
///
/// The API key is a secret. Keep it on your server; never ship it in an iOS
/// or macOS app, where anyone can extract it.
///
/// Safe to share across tasks: create one and reuse it.
public final class TextKit: @unchecked Sendable {
    public static let version = "0.1.0"
    public static let defaultBaseURL = "https://api.jointextkit.com/v1"
    static let testKeyPrefixes = ["tk_sk_test_", "ssms_sk_test_", "dsms_sk_test_", "resms_sk_test_"]

    /// Where requests go, ending in `/v1`.
    public let baseURL: String
    /// Retries for transient failures (429, 5xx, network).
    public let maxRetries: Int
    /// Per-request timeout, in seconds.
    public let timeout: TimeInterval

    private let apiKey: String
    private let transport: HTTPTransport
    private let sleeper: @Sendable (Double) async -> Void
    let defaultFrom: DefaultFrom

    /// - Parameters:
    ///   - apiKey: defaults to the `TEXTKIT_API_KEY` environment variable.
    ///   - defaultFrom: the number `messages.send` uses when you pass no `from`.
    ///     Defaults to `TEXTKIT_FROM`, else your account's only active number
    ///     (looked up once; an error if you have several).
    ///   - baseURL: defaults to `TEXTKIT_BASE_URL`, else `https://api.jointextkit.com/v1`.
    ///     `/v1` is added when missing.
    ///   - maxRetries: retries for transient failures (429, 5xx, network).
    ///   - timeout: per-request timeout, seconds.
    ///   - transport: swap the HTTP layer (tests, tracing, proxies).
    /// - Throws: ``TextKitError`` `invalid_api_key` when there is no key.
    public convenience init(
        apiKey: String? = nil,
        defaultFrom: String? = nil,
        baseURL: String? = nil,
        maxRetries: Int = 2,
        timeout: TimeInterval = 30,
        transport: HTTPTransport? = nil
    ) throws {
        try self.init(
            apiKey: apiKey, defaultFrom: defaultFrom, baseURL: baseURL, maxRetries: maxRetries, timeout: timeout,
            transport: transport, environment: ProcessInfo.processInfo.environment,
            sleeper: { seconds in try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
        )
    }

    init(
        apiKey: String?,
        defaultFrom: String?,
        baseURL: String?,
        maxRetries: Int,
        timeout: TimeInterval,
        transport: HTTPTransport?,
        environment: [String: String],
        sleeper: @escaping @Sendable (Double) async -> Void
    ) throws {
        func env(_ name: String) -> String? {
            guard let v = environment[name], !v.isEmpty else { return nil }
            return v
        }
        // The SIMPLESMS_ names are from before the 2026-10-28 rename; read when the TEXTKIT_ one is unset.
        guard let key = (apiKey?.isEmpty == false ? apiKey : nil) ?? env("TEXTKIT_API_KEY") ?? env("SIMPLESMS_API_KEY") else {
            throw TextKitError(
                "No TextKit key. Pass one to TextKit(apiKey:) or set TEXTKIT_API_KEY. Get one free at https://jointextkit.com/console",
                code: "invalid_api_key", status: 0
            )
        }
        self.apiKey = key
        self.baseURL = TextKit.normalize(baseURL ?? env("TEXTKIT_BASE_URL") ?? env("SIMPLESMS_BASE_URL") ?? TextKit.defaultBaseURL)
        self.maxRetries = max(0, maxRetries)
        self.timeout = timeout
        self.transport = transport ?? URLSessionTransport()
        self.sleeper = sleeper
        self.defaultFrom = DefaultFrom(defaultFrom ?? env("TEXTKIT_FROM") ?? env("SIMPLESMS_FROM"))
    }

    /// True when this client is using a sandbox (test) key.
    public var isTestMode: Bool { TextKit.testKeyPrefixes.contains { apiKey.hasPrefix($0) } }

    public var messages: Messages { Messages(client: self) }
    public var verify: Verify { Verify(client: self) }
    public var numbers: Numbers { Numbers(client: self) }
    public var balance: BalanceResource { BalanceResource(client: self) }
    public var lookup: LookupResource { LookupResource(client: self) }
    public var links: LinksResource { LinksResource(client: self) }
    public var conversions: ConversionsResource { ConversionsResource(client: self) }
    public var events: Events { Events(client: self) }
    public var webhooks: Webhooks { Webhooks(client: self) }
    public var consent: Consent { Consent(client: self) }
    public var customers: Customers { Customers(client: self) }
    public var contacts: Contacts { Contacts(client: self) }
    public var automations: Automations { Automations(client: self) }
    public var schedules: Schedules { Schedules(client: self) }
    public var registrations: Registrations { Registrations(client: self) }

    /// Call any endpoint this SDK has no method for yet. `path` is relative to
    /// `/v1` (e.g. `"/batches"`). GETs, and calls with an `idempotencyKey`, are retried.
    @discardableResult
    public func request(_ method: String, _ path: String, body: JSONValue? = nil, idempotencyKey: String? = nil) async throws -> JSONValue {
        let m = method.uppercased()
        let data = try await send(m, path, body: body, idempotencyKey: idempotencyKey, retryable: m == "GET" || idempotencyKey != nil)
        if data.isEmpty { return .object([:]) }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw TextKitError("The API answered with something that is not JSON.", code: "invalid_response", status: 200)
        }
    }

    /// A fresh `sdk_...` Idempotency-Key.
    public static func newIdempotencyKey() -> String {
        "sdk_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    // MARK: - Internals

    func call<T: Decodable>(
        _ method: String,
        _ path: String,
        body: JSONValue? = nil,
        idempotencyKey: String? = nil,
        retryable: Bool = false,
        as type: T.Type = T.self
    ) async throws -> T {
        let data = try await send(method, path, body: body, idempotencyKey: idempotencyKey, retryable: retryable)
        do {
            return try JSONDecoder().decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
        } catch {
            throw TextKitError(
                "Could not read the API's answer as \(T.self): \(error)", code: "invalid_response", status: 200
            )
        }
    }

    func callText(_ path: String) async throws -> String {
        let data = try await send("GET", path, body: nil, idempotencyKey: nil, retryable: true)
        return String(decoding: data, as: UTF8.self)
    }

    private func send(_ method: String, _ path: String, body: JSONValue?, idempotencyKey: String?, retryable: Bool) async throws -> Data {
        var headers = [
            "Authorization": "Bearer \(apiKey)",
            "User-Agent": "jointextkit-swift/\(TextKit.version)",
            "Accept": "application/json",
        ]
        var bytes: Data?
        if let body {
            headers["Content-Type"] = "application/json"
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            bytes = try encoder.encode(body)
        }
        if let idempotencyKey, !idempotencyKey.isEmpty { headers["Idempotency-Key"] = idempotencyKey }
        guard let url = URL(string: baseURL + path) else {
            throw TextKitError("Bad request URL: \(baseURL + path)", code: "invalid_request", status: 0)
        }
        let request = HTTPRequest(method: method, url: url, headers: headers, body: bytes, timeout: timeout)

        var last: TextKitError?
        for attempt in 0...maxRetries {
            if attempt > 0, let last { await sleeper(TextKit.backoff(attempt: attempt, error: last)) }
            let failure: TextKitError
            do {
                let res = try await transport.send(request)
                if (200..<300).contains(res.status) { return res.body }
                failure = TextKit.error(from: res)
            } catch let error as TextKitError {
                failure = error
            } catch let error as URLError where error.code == .timedOut {
                failure = TextKitError("Request timed out after \(timeout)s", code: "connection_error", status: 0)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = TextKitError("Could not reach the TextKit API: \(error.localizedDescription)", code: "connection_error", status: 0)
            }
            last = failure
            // Retry only what is safe: a POST without an idempotency key is
            // never resent, and a verification cooldown is policy, not a blip.
            if !retryable || !failure.isRetryable { break }
            if failure.code == "rate_limited" && path.hasPrefix("/verify") { break }
            if Task.isCancelled { break }
        }
        throw last!
    }

    func resolveFrom() async throws -> String {
        try await defaultFrom.resolve {
            let active = try await self.numbers.list().data.filter { $0.status == "active" }.compactMap(\.phoneNumber)
            guard active.count == 1 else {
                throw TextKitError(
                    "Pass from: (or set TEXTKIT_FROM): your account has " + (active.isEmpty ? "no numbers yet." : "\(active.count) numbers."),
                    code: "invalid_request", status: 0, param: "from"
                )
            }
            return active[0]
        }
    }

    static func normalize(_ raw: String) -> String {
        var s = raw
        while s.hasSuffix("/") { s.removeLast() }
        return s.hasSuffix("/v1") ? s : s + "/v1"
    }

    static func backoff(attempt: Int, error: TextKitError) -> Double {
        if let retryAfter = error.retryAfter, retryAfter >= 0 { return retryAfter }
        let base = min(0.25 * pow(2.0, Double(attempt)), 4.0)
        return base + Double.random(in: 0..<(base / 4))
    }

    static func error(from res: HTTPResponse) -> TextKitError {
        let payload = try? JSONDecoder().decode(JSONValue.self, from: res.body)
        let err = payload?["error"]?.objectValue ?? [:]
        func str(_ k: String) -> String? { err[k]?.stringValue }
        var e = TextKitError(
            str("message") ?? "Request failed with status \(res.status)",
            code: str("code") ?? (res.status >= 500 ? "internal_error" : "invalid_request"),
            status: res.status,
            param: str("param")
        )
        e.retryAfter = err["retry_after"]?.doubleValue ?? res.headers["retry-after"].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        e.reason = str("reason")
        e.balanceMicroUsd = err["balance_micro_usd"]?.intValue
        e.requiredMicroUsd = err["required_micro_usd"]?.intValue
        e.topUpUrl = str("top_up_url")
        e.sendAfter = str("send_after")
        e.recipientLocalTime = str("recipient_local_time")
        e.timezone = str("timezone")
        e.messageId = str("message_id")
        return e
    }
}

/// The default sending number: configured, or looked up once and shared by
/// concurrent sends.
actor DefaultFrom {
    private var value: String?
    private var inflight: Task<String, Error>?

    init(_ value: String?) { self.value = value }

    var current: String? { value }

    func resolve(_ fetch: @escaping @Sendable () async throws -> String) async throws -> String {
        if let value { return value }
        if let inflight { return try await inflight.value }
        let task = Task { try await fetch() }
        inflight = task
        defer { inflight = nil }
        let v = try await task.value
        value = v
        return v
    }
}

/// A request body under construction: assigning nil leaves a field out;
/// `.null` sends JSON null.
struct Body {
    private(set) var fields: [String: JSONValue] = [:]

    subscript(key: String) -> JSONValue? {
        get { fields[key] }
        set { if let newValue { fields[key] = newValue } }
    }

    mutating func set<T>(_ key: String, _ value: Clearable<T>?, _ transform: (T) -> JSONValue) {
        switch value {
        case .none: break
        case .some(.clear): fields[key] = .null
        case .some(.set(let v)): fields[key] = transform(v)
        }
    }

    var json: JSONValue { .object(fields) }
}

// MARK: - URL helpers

private let unreserved: CharacterSet = {
    var s = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
    s.insert(charactersIn: "-._~")
    return s
}()

/// One path segment: `+14155550132` becomes `%2B14155550132`.
func seg(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
}

/// `?a=1&b=two` from the non-nil pairs, in order (form encoding: a space is `+`); "" when none.
func query(_ pairs: [(String, Any?)]) -> String {
    let parts: [String] = pairs.compactMap { key, value in
        guard let value else { return nil }
        let text: String
        switch value {
        case let b as Bool: text = b ? "true" : "false"
        default: text = "\(value)"
        }
        let encoded = text.split(separator: " ", omittingEmptySubsequences: false)
            .map { seg(String($0)) }.joined(separator: "+")
        return "\(seg(key))=\(encoded)"
    }
    return parts.isEmpty ? "" : "?" + parts.joined(separator: "&")
}
