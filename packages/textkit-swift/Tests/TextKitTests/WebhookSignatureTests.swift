import Crypto
import Foundation
import XCTest

@testable import TextKit

/// Verification against signatures produced by the server's own signer.
/// `Fixtures/webhook_vectors.json` is a copy of
/// packages/textkit-python/tests/fixtures/webhook_vectors.json (generated
/// from src/lib/api/webhook-signature.ts); the repo's Node suite fails if it drifts.
final class WebhookSignatureTests: XCTestCase {
    struct Vector: Decodable {
        let payload: String
        let timestamp: Int64
        let signature: String
    }

    struct Fixture: Decodable {
        let secret: String
        let vectors: [Vector]
    }

    var fixture: Fixture!
    var secret: String { fixture.secret }
    var vectors: [Vector] { fixture.vectors }

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "webhook_vectors", withExtension: "json", subdirectory: "Fixtures"))
        fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func at(_ t: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(t)) }

    private func assertInvalid(_ pattern: String, file: StaticString = #filePath, line: UInt = #line, _ block: () throws -> Event) {
        XCTAssertThrowsError(try block(), file: file, line: line) { error in
            guard let e = error as? TextKitError else { return XCTFail("\(error)", file: file, line: line) }
            XCTAssertEqual(e.code, "invalid_signature", file: file, line: line)
            XCTAssertTrue(e.message.contains(pattern), "'\(e.message)' should contain '\(pattern)'", file: file, line: line)
        }
    }

    func testServerVectorsVerifyAsStringAndData() throws {
        XCTAssertEqual(vectors.count, 2)
        for v in vectors {
            let event = try WebhookSignature.verify(payload: v.payload, signature: v.signature, secret: secret, now: at(v.timestamp))
            let parsed = j(v.payload)
            XCTAssertEqual(event.id, parsed["id"]?.stringValue)
            XCTAssertEqual(event.type, parsed["type"]?.stringValue)
            XCTAssertEqual(event.data, parsed["data"])
            let fromData = try WebhookSignature.verify(payload: Data(v.payload.utf8), signature: v.signature, secret: secret, now: at(v.timestamp))
            XCTAssertEqual(fromData, event)
        }
        // The second vector carries non-ASCII text; it must survive byte for byte.
        let v = vectors[1]
        let received = try WebhookSignature.verify(payload: v.payload, signature: v.signature, secret: secret, now: at(v.timestamp))
        XCTAssertEqual(received.data?["body"], "Café ☕ – ok? 👍")
    }

    func testAnyHeaderNameVerifies() throws {
        let v = vectors[0]
        for name in ["textkit-signature", "dsms-signature", "resms-signature", "TextKit-Signature", "Dsms-Signature"] {
            let event = try WebhookSignature.verify(
                payload: Data(v.payload.utf8), headers: [name: v.signature, "content-type": "application/json"],
                secret: secret, now: at(v.timestamp)
            )
            XCTAssertEqual(event.id, "evt_a1B2c3D4e5F6g7H8", name)
        }
        assertInvalid("Missing") {
            try WebhookSignature.verify(payload: Data(v.payload.utf8), headers: ["x-other": "1"], secret: secret, now: at(v.timestamp))
        }
    }

    func testHeaderHelpers() {
        XCTAssertEqual(WebhookSignature.signature(from: ["dsms-signature": "t=1,v1=aa"]), "t=1,v1=aa")
        XCTAssertEqual(WebhookSignature.signature(from: ["textkit-signature": "new", "dsms-signature": "old"]), "new")
        XCTAssertEqual(WebhookSignature.eventId(from: ["Resms-Event-Id": "evt_1"]), "evt_1")
        XCTAssertNil(WebhookSignature.eventId(from: [:]))
    }

    func testTamperedPayload() {
        let v = vectors[0]
        assertInvalid("does not match") {
            try WebhookSignature.verify(payload: v.payload.replacingOccurrences(of: "0006", with: "0007"), signature: v.signature, secret: secret, now: at(v.timestamp))
        }
    }

    func testReserializedJSONFails() {
        // Re-encoding with escaped non-ASCII changes the bytes, so the signature no longer matches.
        let v = vectors[1]
        let reserialized = v.payload.replacingOccurrences(of: "é", with: "\\u00e9")
        assertInvalid("does not match") {
            try WebhookSignature.verify(payload: reserialized, signature: v.signature, secret: secret, now: at(v.timestamp))
        }
    }

    func testWrongSecret() {
        let v = vectors[0]
        assertInvalid("does not match") {
            try WebhookSignature.verify(payload: v.payload, signature: v.signature, secret: "whsec_other", now: at(v.timestamp))
        }
    }

    func testToleranceBothDirections() throws {
        let v = vectors[0]
        let t = v.timestamp
        _ = try WebhookSignature.verify(payload: v.payload, signature: v.signature, secret: secret, now: at(t + 300))
        assertInvalid("tolerance") { try WebhookSignature.verify(payload: v.payload, signature: v.signature, secret: secret, now: at(t + 301)) }
        assertInvalid("tolerance") { try WebhookSignature.verify(payload: v.payload, signature: v.signature, secret: secret, now: at(t - 301)) }
        _ = try WebhookSignature.verify(payload: v.payload, signature: v.signature, secret: secret, tolerance: 0, now: at(t + 10_000))
        assertInvalid("tolerance") { try WebhookSignature.verify(payload: v.payload, signature: v.signature, secret: secret, now: at(t + 400)) }
    }

    func testForgedTimestamp() {
        let v = vectors[0]
        let sig = v.signature.components(separatedBy: "v1=")[1]
        assertInvalid("does not match") {
            try WebhookSignature.verify(payload: v.payload, signature: "t=\(v.timestamp + 5),v1=\(sig)", secret: secret, now: at(v.timestamp + 5))
        }
    }

    func testRotationAnyV1Matches() throws {
        let v = vectors[0]
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(v.timestamp).\(v.payload)".utf8), using: SymmetricKey(data: Data(secret.utf8)))
        let good = mac.map { String(format: "%02x", $0) }.joined()
        _ = try WebhookSignature.verify(
            payload: v.payload, signature: "t=\(v.timestamp),v1=\(String(repeating: "0", count: 64)),v1=\(good)",
            secret: secret, now: at(v.timestamp)
        )
        _ = try WebhookSignature.verify(payload: v.payload, signature: "t=\(v.timestamp),v1=\(good.uppercased())", secret: secret, now: at(v.timestamp))
    }

    func testMissingAndMalformed() {
        let v = vectors[0]
        assertInvalid("Missing") { try WebhookSignature.verify(payload: v.payload, signature: nil, secret: secret) }
        assertInvalid("Malformed") { try WebhookSignature.verify(payload: v.payload, signature: "v1=abc", secret: secret) }
        assertInvalid("Malformed") { try WebhookSignature.verify(payload: v.payload, signature: "t=\(v.timestamp)", secret: secret) }
        assertInvalid("Malformed") { try WebhookSignature.verify(payload: v.payload, signature: "garbage", secret: secret) }
        assertInvalid("Malformed") { try WebhookSignature.verify(payload: v.payload, signature: "t=-5,v1=abc", secret: secret) }
        assertInvalid("secret") { try WebhookSignature.verify(payload: v.payload, signature: v.signature, secret: "") }
    }
}
