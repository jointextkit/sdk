import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One HTTP request, as the client hands it to an ``HTTPTransport``.
public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    /// Header names as sent (`Authorization`, `Idempotency-Key`, ...).
    public var headers: [String: String]
    /// JSON bytes, or nil for a request without a body.
    public var body: Data?
    public var timeout: TimeInterval

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 30) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

/// One HTTP response. 4xx and 5xx are responses too: return them, don't throw.
public struct HTTPResponse: Sendable {
    public var status: Int
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.body = body
    }
}

/// The HTTP layer. Swap it for tests, tracing, or your framework's client
/// (an `AsyncHTTPClient` adapter in a Vapor app, for example). Throw when the
/// request could not be completed; the client turns that into a
/// `connection_error` and retries where that is safe.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// The default transport: Foundation's `URLSession` (FoundationNetworking on Linux).
public struct URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var req = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout)
        req.httpMethod = request.method
        for (name, value) in request.headers { req.setValue(value, forHTTPHeaderField: name) }
        req.httpBody = request.body
        // dataTask + continuation rather than `data(for:)`: it works on every
        // Foundation this package supports, Linux included.
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: req) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    headers[String(describing: key).lowercased()] = String(describing: value)
                }
                continuation.resume(returning: HTTPResponse(status: http.statusCode, headers: headers, body: data ?? Data()))
            }
            task.resume()
        }
    }
}
