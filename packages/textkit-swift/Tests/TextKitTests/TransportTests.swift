import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import TextKit

/// Stands in for the network inside URLSession: answers every request with a
/// fixed reply and remembers what was asked. No sockets.
final class StubURLProtocol: URLProtocol {
    final class State: @unchecked Sendable {
        var lastRequest: URLRequest?
        var lastBody: Data?
        var reply: (Int, String) = (200, "{}")
    }

    static let state = State()
    static var lastRequest: URLRequest? { state.lastRequest }
    static var lastBody: Data? { state.lastBody }
    static var reply: (Int, String) {
        get { state.reply }
        set { state.reply = newValue }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubURLProtocol.state.lastRequest = request
        StubURLProtocol.state.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let (status, body) = StubURLProtocol.reply
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Retry-After": "2"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

final class TransportTests: XCTestCase {
    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testURLSessionTransportSendsTheRequest() async throws {
        StubURLProtocol.reply = (200, #"{"id":"num_1","customer_id":null}"#)
        let c = try TextKit(apiKey: KEY, baseURL: "https://api.test", transport: URLSessionTransport(session: stubbedSession()))
        let number = try await c.numbers.update("+15005550100", customerId: nil)
        XCTAssertEqual(number.id, "num_1")
        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.httpMethod, "PATCH")
        XCTAssertEqual(req.url?.absoluteString, "https://api.test/v1/numbers/%2B15005550100")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(KEY)")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: body), j(#"{"customer_id":null}"#))
    }

    func testURLSessionTransportReturnsErrorResponses() async throws {
        StubURLProtocol.reply = (429, #"{"error":{"code":"rate_limited","message":"Slow down"}}"#)
        let c = try TextKit(apiKey: KEY, baseURL: "https://api.test", maxRetries: 0, transport: URLSessionTransport(session: stubbedSession()))
        let e = await assertThrowsAsync(try await c.balance.get())
        XCTAssertEqual(e?.code, "rate_limited")
        XCTAssertEqual(e?.status, 429)
        XCTAssertEqual(e?.retryAfter, 2) // read from the lowercased Retry-After header
    }

    func testUnreachableHostIsAConnectionError() async throws {
        let c = try TextKit(apiKey: KEY, baseURL: "http://127.0.0.1:1", maxRetries: 0, timeout: 5)
        let e = await assertThrowsAsync(try await c.balance.get())
        XCTAssertEqual(e?.code, "connection_error")
        XCTAssertEqual(e?.status, 0)
    }
}
