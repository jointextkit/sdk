import Foundation
import XCTest

@testable import TextKit

final class ConstructionTests: XCTestCase {
    func testReadsKeyAndBaseURLFromEnvironment() throws {
        let c = try makeClient(MockTransport(), apiKey: nil, baseURL: nil,
                               environment: ["TEXTKIT_API_KEY": KEY, "TEXTKIT_BASE_URL": "http://localhost:3000/"])
        XCTAssertTrue(c.isTestMode)
        XCTAssertEqual(c.baseURL, "http://localhost:3000/v1")
    }

    func testDefaultBaseURLIsTheV1Host() throws {
        XCTAssertEqual(try makeClient(MockTransport(), baseURL: nil).baseURL, "https://api.jointextkit.com/v1")
        XCTAssertEqual(try makeClient(MockTransport(), baseURL: "https://api.test/v1/").baseURL, "https://api.test/v1")
    }

    func testMissingKeyThrows() {
        XCTAssertThrowsError(try makeClient(MockTransport(), apiKey: nil)) { error in
            XCTAssertEqual((error as? TextKitError)?.code, "invalid_api_key")
            XCTAssertEqual((error as? TextKitError)?.status, 0)
        }
    }

    func testKeyPrefixesSetTestMode() throws {
        for prefix in ["ssms", "dsms", "resms"] {
            XCTAssertTrue(try makeClient(MockTransport(), apiKey: "\(prefix)_sk_test_x").isTestMode, prefix)
            XCTAssertFalse(try makeClient(MockTransport(), apiKey: "\(prefix)_sk_live_x").isTestMode, prefix)
        }
    }

    func testPublicInitializer() throws {
        let c = try TextKit(apiKey: "ssms_sk_live_x", baseURL: "https://api.test", maxRetries: 0, transport: MockTransport())
        XCTAssertFalse(c.isTestMode)
        XCTAssertEqual(c.maxRetries, 0)
    }
}

final class RequestTests: XCTestCase {
    func testSendShapeAuthAndIdempotency() async throws {
        let t = MockTransport().reply(201, MSG)
        let c = try makeClient(t)
        let m = try await c.messages.send(to: "+15005550006", body: "hi", from: "+15005550100")
        XCTAssertEqual(m.id, "msg_1")
        XCTAssertEqual(m.object, "message")
        let call = t.calls[0]
        XCTAssertEqual(call.method, "POST")
        XCTAssertEqual(call.path, "/messages")
        XCTAssertEqual(call.body, j(#"{"to":"+15005550006","body":"hi","from":"+15005550100"}"#))
        XCTAssertEqual(call.headers["authorization"], "Bearer \(KEY)")
        XCTAssertTrue(call.headers["idempotency-key"]!.hasPrefix("sdk_"))
        XCTAssertEqual(call.headers["user-agent"], "jointextkit-swift/\(TextKit.version)")
        XCTAssertEqual(call.headers["content-type"], "application/json")
    }

    func testSendWithEveryOption() async throws {
        let t = MockTransport().reply(201, MSG)
        let c = try makeClient(t)
        _ = try await c.messages.send(
            to: "+15005550006", body: "hi", from: "+15005550100", customerId: "cus_x", category: "marketing",
            quietHours: "defer", consent: ["source": "checkout", "collected_at": "2026-10-01T00:00:00Z"],
            media: ["https://example.com/a.png"], idempotencyKey: "order:1"
        )
        XCTAssertEqual(t.calls[0].body, j(#"""
            {"to":"+15005550006","body":"hi","from":"+15005550100","customer_id":"cus_x","category":"marketing",
             "quiet_hours":"defer","consent":{"source":"checkout","collected_at":"2026-10-01T00:00:00Z"},
             "media":["https://example.com/a.png"]}
            """#))
        XCTAssertEqual(t.calls[0].headers["idempotency-key"], "order:1")
    }

    func testDeferredSendDecodesAsScheduled() async throws {
        let t = MockTransport().reply(202, #"{"id":"job_1","object":"scheduled_message","scheduled_at":"2026-10-02T12:00:00Z","status":"queued"}"#)
        let m = try await makeClient(t).messages.send(to: "+15005550006", body: "hi", from: "+15005550100")
        XCTAssertEqual(m.object, "scheduled_message")
        XCTAssertEqual(m.scheduledAt, "2026-10-02T12:00:00Z")
    }

    func testRetries5xxWithTheSameIdempotencyKey() async throws {
        let t = MockTransport().reply(502, err("carrier_error")).reply(201, MSG)
        let sleeps = Sleeps()
        let c = try makeClient(t, sleeps: sleeps)
        _ = try await c.messages.send(to: "+15005550006", body: "hi", from: "+15005550100")
        XCTAssertEqual(t.calls.count, 2)
        XCTAssertEqual(t.calls[0].headers["idempotency-key"], t.calls[1].headers["idempotency-key"])
        XCTAssertEqual(sleeps.all.count, 1)
        XCTAssertTrue((0.5..<0.625).contains(sleeps.all[0]), "\(sleeps.all[0])")
    }

    func testHonorsRetryAfterHeaderAndBody() async throws {
        let t = MockTransport()
            .reply(429, err("rate_limited"), headers: ["Retry-After": "7"]).ok(EMPTY_PAGE)
            .reply(429, err("rate_limited", "slow", #""retry_after":3"#)).ok(MSG)
        let sleeps = Sleeps()
        let c = try makeClient(t, sleeps: sleeps)
        _ = try await c.messages.list()
        _ = try await c.messages.get("msg_1")
        XCTAssertEqual(sleeps.all, [7, 3])
    }

    func testGivesUpAfterMaxRetries() async throws {
        let t = MockTransport().reply(503, err("internal_error")).reply(503, err("internal_error")).reply(503, err("internal_error"))
        let sleeps = Sleeps()
        let c = try makeClient(t, maxRetries: 2, sleeps: sleeps)
        let e = await assertThrowsAsync(try await c.messages.get("msg_1"))
        XCTAssertEqual(e?.status, 503)
        XCTAssertEqual(t.calls.count, 3)
        XCTAssertEqual(sleeps.all.count, 2)
    }

    func testFourHundredsAreNotRetriedAndTheEnvelopeIsParsed() async throws {
        let t = MockTransport().reply(400, err("invalid_request", "`to` is bad", #""param":"to""#))
        let c = try makeClient(t)
        let e = await assertThrowsAsync(try await c.messages.send(to: "nope", body: "hi", from: "+15005550100"))
        XCTAssertEqual(e?.code, "invalid_request")
        XCTAssertEqual(e?.status, 400)
        XCTAssertEqual(e?.param, "to")
        XCTAssertEqual(e?.message, "`to` is bad")
        XCTAssertEqual(e?.isRetryable, false)
        XCTAssertEqual(t.calls.count, 1)
    }

    func testInsufficientCreditsAndQuietHoursFields() async throws {
        let t = MockTransport()
            .reply(402, err("insufficient_credits", "Add credits",
                            #""balance_micro_usd":1000,"required_micro_usd":8000,"top_up_url":"https://jointextkit.com/console/billing""#))
            .reply(403, err("quiet_hours", "Too late",
                            #""send_after":"2026-10-02T12:00:00Z","recipient_local_time":"22:10","timezone":"America/New_York","message_id":"msg_9""#))
        let c = try makeClient(t)
        let credits = await assertThrowsAsync(try await c.messages.send(to: "+15005550006", body: "hi", from: "+15005550100"))
        XCTAssertEqual(credits?.balanceMicroUsd, 1000)
        XCTAssertEqual(credits?.requiredMicroUsd, 8000)
        XCTAssertEqual(credits?.topUpUrl, "https://jointextkit.com/console/billing")
        let quiet = await assertThrowsAsync(try await c.messages.send(to: "+15005550006", body: "hi", from: "+15005550100"))
        XCTAssertEqual(quiet?.sendAfter, "2026-10-02T12:00:00Z")
        XCTAssertEqual(quiet?.recipientLocalTime, "22:10")
        XCTAssertEqual(quiet?.timezone, "America/New_York")
        XCTAssertEqual(quiet?.messageId, "msg_9")
    }

    func testNonJSONErrorBody() async throws {
        let t = MockTransport().reply(500, "<html>bad gateway</html>")
        let e = await assertThrowsAsync(try await makeClient(t, maxRetries: 0).messages.get("msg_1"))
        XCTAssertEqual(e?.code, "internal_error")
        XCTAssertEqual(e?.message, "Request failed with status 500")
    }

    func testConnectionErrorsAreRetriedForGets() async throws {
        let t = MockTransport().fail(URLError(.timedOut)).fail(URLError(.networkConnectionLost)).reply(200, MSG)
        let m = try await makeClient(t).messages.get("msg_1")
        XCTAssertEqual(m.id, "msg_1")
        XCTAssertEqual(t.calls.count, 3)
    }

    func testConnectionErrorSurfaces() async throws {
        let t = MockTransport().fail(URLError(.cannotConnectToHost)).fail(URLError(.cannotConnectToHost)).fail(URLError(.cannotConnectToHost))
        let e = await assertThrowsAsync(try await makeClient(t).messages.get("msg_1"))
        XCTAssertEqual(e?.code, "connection_error")
        XCTAssertEqual(e?.status, 0)
        XCTAssertEqual(e?.isRetryable, true)
    }

    func testPostWithoutIdempotencyKeyIsNeverResent() async throws {
        let t = MockTransport().fail(URLError(.networkConnectionLost))
        _ = await assertThrowsAsync(try await makeClient(t).verify.send(to: "+14155550132"))
        XCTAssertEqual(t.calls.count, 1)
    }

    func testDefaultFromIsLookedUpOnce() async throws {
        let t = MockTransport()
            .ok(#"{"data":[{"id":"num_1","phone_number":"+15005550100","status":"active"}],"has_more":false}"#)
            .reply(201, MSG).reply(201, MSG)
        let c = try makeClient(t)
        _ = try await c.messages.send(to: "+15005550006", body: "a")
        _ = try await c.messages.send(to: "+15005550006", body: "b")
        XCTAssertEqual(t.calls.filter { $0.path == "/numbers" }.count, 1)
        XCTAssertEqual(t.calls[2].body?["from"], "+15005550100")
    }

    func testDefaultFromRefusesToGuess() async throws {
        let t = MockTransport().ok(#"""
            {"data":[{"id":"n1","phone_number":"+15005550100","status":"active"},
                     {"id":"n2","phone_number":"+15005550101","status":"active"}],"has_more":false}
            """#)
        let e = await assertThrowsAsync(try await makeClient(t).messages.send(to: "+15005550006", body: "a"))
        XCTAssertEqual(e?.param, "from")
    }

    func testDefaultFromFromEnvironment() async throws {
        let t = MockTransport().reply(201, MSG)
        let c = try makeClient(t, environment: ["TEXTKIT_FROM": "+15005550199"])
        _ = try await c.messages.send(to: "+15005550006", body: "a")
        XCTAssertEqual(t.calls.count, 1)
        XCTAssertEqual(t.calls[0].body?["from"], "+15005550199")
    }

    func testListAllFollowsCursors() async throws {
        let t = MockTransport()
            .ok(#"{"data":[{"id":"m3"},{"id":"m2"}],"has_more":true,"next_cursor":"k2"}"#)
            .ok(#"{"data":[{"id":"m1"}],"has_more":false,"next_cursor":null}"#)
        let c = try makeClient(t)
        let ids = try await c.messages.listAll(limit: 2, customerId: "cus_x").collect().map(\.id)
        XCTAssertEqual(ids, ["m3", "m2", "m1"])
        XCTAssertEqual(t.calls[0].path, "/messages?limit=2&customer_id=cus_x")
        XCTAssertEqual(t.calls[1].path, "/messages?limit=2&cursor=k2&customer_id=cus_x")
    }

    func testListAllIsLazy() async throws {
        let t = MockTransport().ok(#"{"data":[{"id":"m3"}],"has_more":true,"next_cursor":"k2"}"#)
        var iterator = try makeClient(t).messages.listAll().makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first?.id, "m3")
        XCTAssertEqual(t.calls.count, 1)
    }

    func testScheduleSerializesDateAsUTC() async throws {
        let t = MockTransport().reply(201, #"{"id":"job_1","object":"scheduled_message","status":"queued"}"#)
        let c = try makeClient(t, defaultFrom: "+15005550100")
        let job = try await c.messages.schedule(to: "+15005550006", body: "later", sendAt: Date(timeIntervalSince1970: 1_790_933_400))
        XCTAssertEqual(job.id, "job_1")
        XCTAssertEqual(t.calls[0].body, j(#"{"to":"+15005550006","body":"later","scheduled_at":"2026-10-02T09:30:00Z","from":"+15005550100"}"#))
        XCTAssertNil(t.calls[0].headers["idempotency-key"])
    }

    func testRawRequestEscapeHatch() async throws {
        let t = MockTransport().ok(#"{"data":[{"id":"bat_1"}],"has_more":false}"#).reply(201, #"{"id":"tpl_1"}"#)
        let c = try makeClient(t)
        let page = try await c.request("GET", "/batches")
        XCTAssertEqual(page["data"]?[0]?["id"], "bat_1")
        try await c.request("post", "/templates", body: ["name": "Welcome", "body": "Hi"], idempotencyKey: "tpl:1")
        XCTAssertEqual(t.calls[1].method, "POST")
        XCTAssertEqual(t.calls[1].body, j(#"{"name":"Welcome","body":"Hi"}"#))
        XCTAssertEqual(t.calls[1].headers["idempotency-key"], "tpl:1")
    }

    func testUnknownFieldsAndNullsAreTolerated() async throws {
        let t = MockTransport().ok(#"{"id":"msg_1","object":"message","status":"delivered","brand_new_field":{"x":1},"customer_id":null}"#)
        let m = try await makeClient(t).messages.get("msg_1")
        XCTAssertEqual(m.status, "delivered")
        XCTAssertNil(m.customerId)
    }
}
