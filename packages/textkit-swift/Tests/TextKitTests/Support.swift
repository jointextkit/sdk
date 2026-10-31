import Foundation
import XCTest

@testable import TextKit

let KEY = "ssms_sk_test_" + String(repeating: "a", count: 32)
let MSG = #"{"id":"msg_1","object":"message","to":"+15005550006","from":"+15005550100","body":"hi","status":"queued"}"#
let EMPTY_PAGE = #"{"data":[],"has_more":false,"next_cursor":null}"#

func err(_ code: String, _ message: String = "nope", _ extra: String = "") -> String {
    #"{"error":{"code":"\#(code)","message":"\#(message)""# + (extra.isEmpty ? "" : ",\(extra)") + "}}"
}

func j(_ text: String) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

/// Answers with scripted replies, in order, and records every request. No network.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    enum Step {
        case reply(Int, String, [String: String])
        case fail(Error)
    }

    struct Recorded {
        let method: String
        /// Path after `/v1`, with the query string.
        let path: String
        let headers: [String: String]
        let body: JSONValue?
    }

    private let lock = NSLock()
    private var steps: [Step] = []
    private var recorded: [Recorded] = []

    @discardableResult
    func reply(_ status: Int, _ body: String, headers: [String: String] = [:]) -> MockTransport {
        lock.lock(); defer { lock.unlock() }
        steps.append(.reply(status, body, headers))
        return self
    }

    @discardableResult
    func ok(_ body: String) -> MockTransport { reply(200, body) }

    @discardableResult
    func fail(_ error: Error) -> MockTransport {
        lock.lock(); defer { lock.unlock() }
        steps.append(.fail(error))
        return self
    }

    var calls: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let step: Step = {
            lock.lock(); defer { lock.unlock() }
            var path = request.url.absoluteString
            if let range = path.range(of: "/v1") { path = String(path[range.upperBound...]) }
            let body = request.body.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            let headers = Dictionary(request.headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
            recorded.append(Recorded(method: request.method, path: path, headers: headers, body: body))
            return steps.isEmpty ? .reply(599, err("stub_exhausted"), [:]) : steps.removeFirst()
        }()
        switch step {
        case .reply(let status, let body, let headers):
            return HTTPResponse(status: status, headers: headers, body: Data(body.utf8))
        case .fail(let error):
            throw error
        }
    }
}

/// Records the requested sleeps instead of sleeping.
final class Sleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
    var all: [Double] { lock.lock(); defer { lock.unlock() }; return values }
}

func makeClient(
    _ transport: MockTransport,
    apiKey: String? = KEY,
    defaultFrom: String? = nil,
    baseURL: String? = "https://api.test",
    maxRetries: Int = 2,
    environment: [String: String] = [:],
    sleeps: Sleeps = Sleeps()
) throws -> TextKit {
    try TextKit(
        apiKey: apiKey, defaultFrom: defaultFrom, baseURL: baseURL, maxRetries: maxRetries, timeout: 30,
        transport: transport, environment: environment, sleeper: { sleeps.add($0) }
    )
}

func assertThrowsAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async -> TextKitError? {
    do {
        _ = try await expression()
        XCTFail("Expected a TextKitError", file: file, line: line)
        return nil
    } catch let e as TextKitError {
        return e
    } catch {
        XCTFail("Expected a TextKitError, got \(error)", file: file, line: line)
        return nil
    }
}
