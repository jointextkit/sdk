import Foundation
import XCTest

@testable import TextKit

final class ResourceTests: XCTestCase {
    /// "METHOD /path" of every recorded call.
    private func lines(_ t: MockTransport) -> [String] { t.calls.map { "\($0.method) \($0.path)" } }

    func testVerify() async throws {
        let t = MockTransport()
            .reply(500, err("internal_error"))
            .reply(429, err("rate_limited", "wait", #""retry_after":60"#))
            .ok(#"{"verified":true,"status":"approved","charged":true}"#)
            .reply(503, err("internal_error")).reply(201, #"{"id":"ver_1","status":"pending"}"#)
        let sleeps = Sleeps()
        let c = try makeClient(t, sleeps: sleeps)
        _ = await assertThrowsAsync(try await c.verify.send(to: "+14155550132", appName: "Acme", customerId: "cus_x"))
        let cooldown = await assertThrowsAsync(try await c.verify.get("ver_1")) // GETs retry, never on /verify cooldowns
        XCTAssertEqual(cooldown?.retryAfter, 60)
        let check = try await c.verify.check(to: "+14155550132", code: "111111")
        XCTAssertTrue(check.verified)
        let retried = try await c.verify.send(to: "+14155550132", idempotencyKey: "signup:42")
        XCTAssertEqual(retried.status, "pending")
        XCTAssertEqual(sleeps.all.count, 1) // only the keyed send was retried
        XCTAssertEqual(t.calls[0].body, j(#"{"phone":"+14155550132","app_name":"Acme","customer_id":"cus_x"}"#))
        XCTAssertEqual(t.calls[1].path, "/verify/ver_1")
        XCTAssertEqual(t.calls[2].body, j(#"{"phone":"+14155550132","code":"111111"}"#))
        XCTAssertEqual(t.calls[4].headers["idempotency-key"], "signup:42")
        XCTAssertEqual(t.calls.count, 5)
    }

    func testNumbers() async throws {
        let t = MockTransport()
            .ok(#"{"data":[{"object":"available_number","phone_number":"+14155550100","locality":"San Francisco","region":"CA"}],"has_more":false}"#)
            .reply(201, #"{"id":"num_1","phone_number":"+15005550110","customer_id":"cus_x"}"#)
            .ok(EMPTY_PAGE)
            .ok(#"{"id":"num_1","customer_id":null}"#)
            .ok(#"{"id":"num_1","phone_number":"+15005550110"}"#)
            .reply(502, err("carrier_error"))
        let c = try makeClient(t)
        let available = try await c.numbers.available(areaCode: "415")
        XCTAssertEqual(available.data[0].locality, "San Francisco")
        _ = try await c.numbers.buy("+15005550110", customerId: "cus_x")
        _ = try await c.numbers.list(customerId: "cus_x", tag: "east")
        let unassigned = try await c.numbers.update("+15005550110", customerId: nil)
        XCTAssertNil(unassigned.customerId)
        _ = try await c.numbers.get("+15005550110")
        _ = await assertThrowsAsync(try await c.numbers.release("+15005550110")) // not retried
        XCTAssertEqual(lines(t), [
            "GET /numbers/available?area_code=415", "POST /numbers", "GET /numbers?customer_id=cus_x&tag=east",
            "PATCH /numbers/%2B15005550110", "GET /numbers/%2B15005550110", "DELETE /numbers/%2B15005550110",
        ])
        XCTAssertEqual(t.calls[1].body, j(#"{"phone_number":"+15005550110","customer_id":"cus_x"}"#))
        XCTAssertEqual(t.calls[3].body, j(#"{"customer_id":null}"#))
    }

    func testBalanceAndLookup() async throws {
        let t = MockTransport()
            .ok(#"{"object":"balance","balance_micro_usd":12340000,"balance_usd":12.34,"currency":"usd","auto_recharge":{"enabled":false}}"#)
            .ok(#"{"phone_number":"+14155550132","valid":true,"line_type":"mobile","carrier":{"name":"Example"},"caller_name":null}"#)
        let c = try makeClient(t)
        let b = try await c.balance.get()
        XCTAssertEqual(b.balanceUsd, 12.34)
        XCTAssertEqual(b.balanceMicroUsd, 12_340_000)
        XCTAssertEqual(b.autoRecharge?["enabled"], false)
        let lookup = try await c.lookup.phone("+14155550132")
        XCTAssertEqual(lookup.lineType, "mobile")
        XCTAssertEqual(t.calls[1].path, "/lookup/%2B14155550132")
    }

    func testEventsListWaitAndTrack() async throws {
        let t = MockTransport()
            .ok(#"{"data":[{"id":"evt_2","type":"message.delivered"}],"has_more":true,"next_cursor":"c2"}"#)
            .ok(#"{"data":[{"id":"evt_1","type":"message.delivered"}],"has_more":false,"next_cursor":null}"#)
            .ok(#"{"object":"event_wait","data":[],"cursor":"w1","has_more":false}"#)
            .ok(#"{"object":"event_wait","data":[{"id":"evt_3","data":{"message_id":"msg_1"}}],"cursor":"w2","has_more":false}"#)
            .reply(201, #"{"id":"tev_1","object":"tracked_event","runs_started":["run_1"]}"#)
            .reply(201, #"{"id":"tev_2","object":"tracked_event"}"#)
        let c = try makeClient(t)
        let ids = try await c.events.listAll(type: "message.delivered").collect().map(\.id)
        XCTAssertEqual(ids, ["evt_2", "evt_1"])
        let first = try await c.events.wait()
        let second = try await c.events.wait(cursor: first.cursor, timeout: 20)
        XCTAssertEqual(second.data[0].id, "evt_3")
        XCTAssertEqual(second.data[0].data?["message_id"], "msg_1")
        let r = try await c.events.track("trial_started", userId: "123", phone: "+15005550006", properties: ["plan": "pro"])
        try await c.events.track("subscription_created", userId: "123", idempotencyKey: "mine")
        XCTAssertEqual(r.runsStarted, ["run_1"])
        XCTAssertEqual(t.calls[0].path, "/events?type=message.delivered")
        XCTAssertEqual(t.calls[1].path, "/events?cursor=c2&type=message.delivered")
        XCTAssertEqual(t.calls[2].path, "/events/wait")
        XCTAssertEqual(t.calls[3].path, "/events/wait?cursor=w1&timeout=20")
        XCTAssertEqual(t.calls[4].body, j(#"{"event":"trial_started","user_id":"123","phone":"+15005550006","properties":{"plan":"pro"}}"#))
        XCTAssertTrue(t.calls[4].headers["idempotency-key"]!.hasPrefix("sdk_"))
        XCTAssertEqual(t.calls[5].body, j(#"{"event":"subscription_created","user_id":"123"}"#))
        XCTAssertEqual(t.calls[5].headers["idempotency-key"], "mine")
    }

    func testWebhookEndpoints() async throws {
        let ep = #"{"id":"we_1","object":"webhook_endpoint","url":"https://example.com/h","events":"*","active":true}"#
        let t = MockTransport()
            .reply(201, #"{"id":"we_1","url":"https://example.com/h","events":["message.received"],"secret":"whsec_x"}"#)
            .ok(#"{"data":[\#(ep)]}"#).ok(ep).ok(ep).ok(ep).ok(#"{"id":"we_1","object":"webhook_endpoint","deleted":true}"#)
            .reply(500, err("internal_error"))
        let c = try makeClient(t)
        let created = try await c.webhooks.create(url: "https://example.com/h", events: ["message.received"], description: "orders")
        XCTAssertEqual(created.secret, "whsec_x")
        XCTAssertEqual(created.events, ["message.received"])
        let listed = try await c.webhooks.list()
        XCTAssertEqual(listed.data[0].events, ["*"])
        _ = try await c.webhooks.get("we_1")
        _ = try await c.webhooks.update("we_1", active: false)
        _ = try await c.webhooks.update("we_1", events: ["*"], description: .clear)
        let deleted = try await c.webhooks.delete("we_1")
        XCTAssertEqual(deleted.deleted, true)
        _ = await assertThrowsAsync(try await c.webhooks.create(url: "https://example.com/h")) // not retried
        XCTAssertEqual(lines(t), [
            "POST /webhooks", "GET /webhooks", "GET /webhooks/we_1", "PATCH /webhooks/we_1", "PATCH /webhooks/we_1",
            "DELETE /webhooks/we_1", "POST /webhooks",
        ])
        XCTAssertEqual(t.calls[0].body, j(#"{"url":"https://example.com/h","events":["message.received"],"description":"orders"}"#))
        XCTAssertEqual(t.calls[3].body, j(#"{"active":false}"#))
        XCTAssertEqual(t.calls[4].body, j(#"{"events":"*","description":null}"#))
        XCTAssertEqual(t.calls[6].body, j(#"{"url":"https://example.com/h"}"#))
    }

    func testConsent() async throws {
        let t = MockTransport()
            .ok(#"{"object":"consent","phone":"+14155550132","status":"opted_out"}"#)
            .ok(#"{"object":"consent","phone":"+14155550132","status":"opted_in"}"#)
            .ok(#"{"object":"consent_import","imported":1,"skipped":[]}"#)
            .ok("phone,status\n+14155550132,opted_out\n")
            .ok(#"{"object":"consent","phone":"+14155550132","status":"none","history":[]}"#)
            .ok(#"{"data":[{"object":"consent","phone":"+14155550132","status":"opted_out"}],"has_more":false}"#)
        let c = try makeClient(t)
        try await c.consent.optOut("+14155550132", note: "crm")
        try await c.consent.optIn(
            "+14155550132", campaignId: "reg_1",
            proof: ["source": "web_form", "collected_at": "2026-10-01T15:04:05Z", "page_url": "https://acme.example/texts"]
        )
        let imported = try await c.consent.import(["+14155550132"])
        XCTAssertEqual(imported.imported, 1)
        let csv = try await c.consent.export()
        XCTAssertTrue(csv.hasPrefix("phone,status"))
        let detail = try await c.contacts.consent("+14155550132")
        XCTAssertEqual(detail.status, "none")
        let phones = try await c.consent.listAll().collect().map(\.phone)
        XCTAssertEqual(phones, ["+14155550132"])
        XCTAssertEqual(t.calls[0].path, "/consent/%2B14155550132")
        XCTAssertEqual(t.calls[0].body, j(#"{"status":"opted_out","note":"crm"}"#))
        XCTAssertEqual(t.calls[1].body, j(#"""
            {"status":"opted_in","campaign_id":"reg_1","proof":{"source":"web_form",
             "collected_at":"2026-10-01T15:04:05Z","page_url":"https://acme.example/texts"}}
            """#))
        XCTAssertEqual(t.calls[2].body, j(#"{"phone_numbers":["+14155550132"]}"#))
        XCTAssertEqual(lines(t).suffix(3), ["GET /consent/export", "GET /consent/%2B14155550132", "GET /consent"])
    }

    func testCustomers() async throws {
        let t = MockTransport()
            .reply(201, #"{"id":"cus_x","name":"Acme","metadata":{"plan":"pro"}}"#)
            .ok(#"{"object":"customer_usage","customer_id":"cus_x","messages_sent":3}"#)
            .ok(EMPTY_PAGE).ok(#"{"id":"cus_x"}"#).ok(#"{"id":"cus_x"}"#).ok(#"{"id":"cus_x","deleted":true}"#)
        let c = try makeClient(t)
        let created = try await c.customers.create(name: "Acme", externalId: "acct_1", metadata: ["plan": "pro"])
        XCTAssertEqual(created.metadata?["plan"], "pro")
        let usage = try await c.customers.usage("cus_x", start: "2026-10-01", end: "2026-10-31")
        XCTAssertEqual(usage.messagesSent, 3)
        _ = try await c.customers.list(externalId: "acct 1")
        _ = try await c.customers.update("cus_x", name: "Acme")
        _ = try await c.customers.update("cus_x", externalId: .clear, metadata: .set(["plan": "pro"]))
        try await c.customers.delete("cus_x")
        XCTAssertEqual(t.calls[0].body, j(#"{"name":"Acme","external_id":"acct_1","metadata":{"plan":"pro"}}"#))
        XCTAssertEqual(t.calls[1].path, "/customers/cus_x/usage?start=2026-10-01&end=2026-10-31")
        XCTAssertEqual(t.calls[2].path, "/customers?external_id=acct+1")
        XCTAssertEqual(t.calls[3].body, j(#"{"name":"Acme"}"#))
        XCTAssertEqual(t.calls[4].body, j(#"{"external_id":null,"metadata":{"plan":"pro"}}"#))
        XCTAssertEqual(lines(t).last, "DELETE /customers/cus_x")
    }

    func testContacts() async throws {
        let t = MockTransport()
            .ok(#"{"id":"con_1","phone_number":"+14155550132","tags":["vip"]}"#)
            .ok(#"{"object":"contact_import","created":1,"updated":1,"skipped":[]}"#)
            .ok(#"{"object":"contact_bulk","action":"add_tags","updated":2,"deleted":0,"missing":0}"#)
            .ok(#"{"id":"con_1"}"#).ok(#"{"id":"con_1"}"#).ok(#"{"id":"con_1","deleted":true}"#)
            .ok(#"{"data":[{"id":"con_2"}],"has_more":true,"next_cursor":"k"}"#).ok(#"{"data":[{"id":"con_1"}],"has_more":false}"#)
        let c = try makeClient(t)
        let contact = try await c.contacts.upsert(phoneNumber: "+14155550132", name: "Ada", tags: ["vip"])
        XCTAssertEqual(contact.tags, ["vip"])
        _ = try await c.contacts.import([
            ContactInput(phoneNumber: "+14155550132", name: "Ada"),
            ContactInput(phoneNumber: "+14155550133", fields: ["plan": "pro"]),
        ])
        let bulk = try await c.contacts.bulk(action: "add_tags", ids: ["con_1", "con_2"], tags: ["vip"])
        XCTAssertEqual(bulk.updated, 2)
        _ = try await c.contacts.get("con_1")
        _ = try await c.contacts.update("con_1", name: .clear, tags: ["a"])
        try await c.contacts.delete("con_1")
        let ids = try await c.contacts.listAll(tag: "vip").collect().map(\.id)
        XCTAssertEqual(ids, ["con_2", "con_1"])
        XCTAssertEqual(t.calls[0].body, j(#"{"phone_number":"+14155550132","name":"Ada","tags":["vip"]}"#))
        XCTAssertEqual(t.calls[1].body, j(#"{"contacts":[{"phone_number":"+14155550132","name":"Ada"},{"phone_number":"+14155550133","fields":{"plan":"pro"}}]}"#))
        XCTAssertEqual(t.calls[2].body, j(#"{"action":"add_tags","ids":["con_1","con_2"],"tags":["vip"]}"#))
        XCTAssertEqual(t.calls[4].body, j(#"{"name":null,"tags":["a"]}"#))
        XCTAssertEqual(lines(t), [
            "POST /contacts", "POST /contacts/import", "POST /contacts/bulk", "GET /contacts/con_1",
            "PATCH /contacts/con_1", "DELETE /contacts/con_1", "GET /contacts?tag=vip", "GET /contacts?cursor=k&tag=vip",
        ])
    }

    func testAutomations() async throws {
        let t = MockTransport().reply(201, #"{"id":"auto_x","status":"draft","issues":[]}"#)
        for _ in 0..<4 { t.ok(#"{"id":"auto_x"}"#) }
        t.ok(#"{"data":[{"id":"run_1","status":"waiting"}],"has_more":false}"#)
            .ok(#"{"id":"run_1"}"#).ok(#"{"id":"run_1","status":"failed"}"#).ok(#"{"id":"auto_x","deleted":true}"#)
            .ok(#"{"data":[{"id":"auto_x"}]}"#)
        let c = try makeClient(t)
        let steps: [JSONValue] = [["type": "wait", "seconds": 3600], ["type": "send_sms", "body": "hi"]]
        _ = try await c.automations.create(name: "Welcome", trigger: ["event": "user_signed_up"], steps: steps, from: "+15005550100")
        _ = try await c.automations.update("auto_x", topicId: .clear)
        _ = try await c.automations.get("auto_x")
        try await c.automations.activate("auto_x")
        try await c.automations.pause("auto_x")
        let runs = try await c.automations.runs("auto_x", limit: 5)
        XCTAssertEqual(runs.data[0].status, "waiting")
        _ = try await c.automations.run("auto_x", runId: "run_1")
        try await c.automations.cancelRun("auto_x", runId: "run_1")
        try await c.automations.delete("auto_x")
        let all = try await c.automations.list()
        XCTAssertEqual(all.data[0].id, "auto_x")
        XCTAssertEqual(t.calls[0].body, j(#"""
            {"name":"Welcome","trigger":{"event":"user_signed_up"},
             "steps":[{"type":"wait","seconds":3600},{"type":"send_sms","body":"hi"}],"from":"+15005550100"}
            """#))
        XCTAssertEqual(t.calls[1].body, j(#"{"topic_id":null}"#))
        XCTAssertEqual(Array(lines(t).dropFirst(2)), [
            "GET /automations/auto_x", "POST /automations/auto_x/activate", "POST /automations/auto_x/pause",
            "GET /automations/auto_x/runs?limit=5", "GET /automations/auto_x/runs/run_1",
            "DELETE /automations/auto_x/runs/run_1", "DELETE /automations/auto_x", "GET /automations",
        ])
    }

    func testSchedules() async throws {
        let t = MockTransport()
            .reply(201, #"{"id":"sch_x","object":"schedule","repeat":{"frequency":"daily","time":"08:00","timezone":"America/New_York"},"next_run_at":"2026-10-02T12:00:00Z"}"#)
            .reply(201, #"{"id":"sch_y"}"#)
            .ok(#"{"id":"sch_x"}"#).ok(EMPTY_PAGE)
        for _ in 0..<3 { t.ok(#"{"id":"sch_x"}"#) }
        t.ok(#"{"id":"sch_x","object":"schedule","deleted":true}"#).ok(EMPTY_PAGE)
        let c = try makeClient(t)
        let s = try await c.schedules.create(
            to: "+15005550006", body: "Good morning", repeat: .daily(at: "08:00", timezone: "America/New_York"), maxOccurrences: 30
        )
        XCTAssertEqual(s.repeat?.frequency, "daily")
        _ = try await c.schedules.create(
            to: "+15005550006", body: "a", repeat: .weekly(on: ["mon", "fri"], at: "09:00", timezone: "UTC"),
            from: "+15005550199", idempotencyKey: "mine"
        )
        _ = try await c.schedules.get("sch_x")
        _ = try await c.schedules.list()
        try await c.schedules.pause("sch_x")
        try await c.schedules.resume("sch_x")
        _ = try await c.schedules.update("sch_x", body: "new", endDate: .clear)
        try await c.schedules.delete("sch_x")
        _ = try await c.messages.list(scheduleId: "sch_x")
        // No `from`: the API picks the account's one number for the key's mode.
        XCTAssertEqual(t.calls[0].body, j(#"""
            {"to":"+15005550006","body":"Good morning","repeat":{"frequency":"daily","time":"08:00","timezone":"America/New_York"},"max_occurrences":30}
            """#))
        XCTAssertTrue(t.calls[0].headers["idempotency-key"]!.hasPrefix("sdk_"))
        XCTAssertEqual(t.calls[1].body, j(#"""
            {"to":"+15005550006","body":"a","repeat":{"frequency":"weekly","time":"09:00","timezone":"UTC","days_of_week":["mon","fri"]},"from":"+15005550199"}
            """#))
        XCTAssertEqual(t.calls[1].headers["idempotency-key"], "mine")
        XCTAssertEqual(t.calls[4].body, j(#"{"active":false}"#))
        XCTAssertEqual(t.calls[5].body, j(#"{"active":true}"#))
        XCTAssertEqual(t.calls[6].body, j(#"{"body":"new","end_date":null}"#))
        XCTAssertEqual(lines(t), [
            "POST /schedules", "POST /schedules", "GET /schedules/sch_x", "GET /schedules", "PATCH /schedules/sch_x",
            "PATCH /schedules/sch_x", "PATCH /schedules/sch_x", "DELETE /schedules/sch_x", "GET /messages?schedule_id=sch_x",
        ])
    }

    func testScheduleUsesDefaultFrom() async throws {
        let t = MockTransport().reply(201, #"{"id":"sch_x"}"#)
        let c = try makeClient(t, defaultFrom: "+15005550100")
        _ = try await c.schedules.create(to: "+15005550006", body: "a", repeat: .monthly(onDay: 1, at: "08:00", timezone: "UTC"))
        XCTAssertEqual(t.calls[0].body, j(#"""
            {"to":"+15005550006","body":"a","repeat":{"frequency":"monthly","time":"08:00","timezone":"UTC","day_of_month":1},"from":"+15005550100"}
            """#))
    }

    func testRegistrations() async throws {
        let t = MockTransport()
            .reply(201, #"{"id":"reg_1","status":"ready","guidance":{"next_actor":"you"}}"#)
            .ok(#"{"id":"reg_1","status":"ready"}"#).ok(#"{"id":"reg_1","status":"submitted"}"#)
            .ok(#"{"data":[{"object":"registration_submission","number":1}]}"#).ok(#"{"id":"reg_1"}"#).ok(#"{"data":[]}"#)
        let c = try makeClient(t)
        let reg = try await c.registrations.create(
            businessName: "Acme Plumbing LLC", website: "https://acmeplumbing.com", useCase: "customer_care",
            fields: [
                "sample_messages": ["Acme Plumbing: your plumber arrives tomorrow. Reply STOP to opt out."],
                "brand": ["legal_name": "Acme Plumbing LLC", "ein": "12-3456789"],
            ]
        )
        XCTAssertEqual(reg.status, "ready")
        XCTAssertEqual(reg.guidance?["next_actor"], "you")
        _ = try await c.registrations.recheck("reg_1", fields: ["opt_in_url": "https://acmeplumbing.com/text"])
        _ = try await c.registrations.submit("reg_1", feesAcknowledged: true, attestation: Attestation(signerName: "Dana Smith", signerTitle: "Owner"))
        let subs = try await c.registrations.submissions("reg_1")
        XCTAssertEqual(subs.data[0].number, 1)
        _ = try await c.registrations.get("reg_1")
        _ = try await c.registrations.list()
        XCTAssertEqual(t.calls[0].body, j(#"""
            {"business_name":"Acme Plumbing LLC","website":"https://acmeplumbing.com","use_case":"customer_care",
             "sample_messages":["Acme Plumbing: your plumber arrives tomorrow. Reply STOP to opt out."],
             "brand":{"legal_name":"Acme Plumbing LLC","ein":"12-3456789"}}
            """#))
        XCTAssertEqual(t.calls[1].body, j(#"{"opt_in_url":"https://acmeplumbing.com/text"}"#))
        XCTAssertEqual(t.calls[2].body, j(#"{"attestation":{"signer_name":"Dana Smith","signer_title":"Owner","accepted":true},"fees_acknowledged":true}"#))
        XCTAssertEqual(lines(t), [
            "POST /registrations", "POST /registrations/reg_1/recheck", "POST /registrations/reg_1/submit",
            "GET /registrations/reg_1/submissions", "GET /registrations/reg_1", "GET /registrations",
        ])
    }
}
