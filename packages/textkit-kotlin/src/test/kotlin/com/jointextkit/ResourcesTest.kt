package com.jointextkit

import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows

class ResourcesTest {
    private val server = StubServer()

    @AfterEach fun stop() = server.close()

    /** (method, path, body) of every recorded call. */
    private fun calls() = server.calls.map { Triple(it.method, it.path, it.json) }

    @Test fun verify() {
        server.reply(500, err("internal_error"))
        server.reply(429, err("rate_limited", extra = "\"retry_after\":60"))
        server.ok("""{"verified":true,"status":"approved","charged":true}""")
        val (c, sleeps) = stubClient(server)
        assertThrows<TextKitException> { c.verify.send("+14155550132", appName = "Acme", customerId = "cus_x") }
        val cooldown = assertThrows<TextKitException> { c.verify.get("ver_1") } // GETs retry, never on /verify cooldowns
        assertEquals(60.0, cooldown.retryAfter)
        assertEquals(emptyList<Long>(), sleeps)
        assertTrue(c.verify.check("+14155550132", "111111").verified)
        val calls = calls()
        assertEquals(Triple("POST", "/verify", j("""{"phone":"+14155550132","app_name":"Acme","customer_id":"cus_x"}""")), calls[0])
        assertEquals("/verify/ver_1", calls[1].second)
        assertEquals(Triple("POST", "/verify/check", j("""{"phone":"+14155550132","code":"111111"}""")), calls[2])
    }

    @Test fun verifySendWithIdempotencyKeyIsRetried() {
        server.reply(503, err("internal_error")).reply(201, """{"id":"ver_1","status":"pending"}""")
        val (c, _) = stubClient(server)
        assertEquals("pending", c.verify.send("+14155550132", idempotencyKey = "signup:42").status)
        assertEquals(2, server.calls.size)
        assertEquals("signup:42", server.calls[1].headers["idempotency-key"])
    }

    @Test fun numbers() {
        server.ok("""{"data":[{"object":"available_number","phone_number":"+14155550100","locality":"San Francisco","region":"CA"}],"has_more":false}""")
        server.reply(201, """{"id":"num_1","phone_number":"+15005550110","customer_id":"cus_x"}""")
        server.ok(EMPTY_PAGE)
        server.ok("""{"id":"num_1","customer_id":null}""")
        server.ok("""{"id":"num_1","phone_number":"+15005550110"}""")
        server.reply(502, err("carrier_error"))
        val (c, _) = stubClient(server)
        assertEquals("San Francisco", c.numbers.available("415").data[0].locality)
        c.numbers.buy("+15005550110", customerId = "cus_x")
        c.numbers.list(ListNumbersParams().customerId("cus_x").tag("east"))
        assertNull(c.numbers.update("+15005550110", null).customerId)
        c.numbers.get("+15005550110")
        assertThrows<TextKitException> { c.numbers.release("+15005550110") } // not retried
        val calls = calls()
        assertEquals("/numbers/available?area_code=415", calls[0].second)
        assertEquals(Triple("POST", "/numbers", j("""{"phone_number":"+15005550110","customer_id":"cus_x"}""")), calls[1])
        assertEquals("/numbers?customer_id=cus_x&tag=east", calls[2].second)
        assertEquals(Triple("PATCH", "/numbers/%2B15005550110", j("""{"customer_id":null}""")), calls[3])
        assertEquals(Triple("GET", "/numbers/%2B15005550110", null), calls[4])
        assertEquals(Triple("DELETE", "/numbers/%2B15005550110", null), calls[5])
        assertEquals(6, calls.size)
    }

    @Test fun balanceAndLookup() {
        server.ok("""{"object":"balance","balance_micro_usd":12340000,"balance_usd":12.34,"currency":"usd","auto_recharge":{"enabled":false}}""")
        server.ok("""{"phone_number":"+14155550132","valid":true,"line_type":"mobile","carrier":{"name":"Example"},"caller_name":null}""")
        val (c, _) = stubClient(server)
        val b = c.balance.get()
        assertEquals(12.34, b.balanceUsd)
        assertEquals(12340000L, b.balanceMicroUsd)
        assertEquals("mobile", c.lookup.phone("+14155550132").lineType)
        assertEquals("/lookup/%2B14155550132", server.calls[1].path)
    }

    @Test fun eventsListWaitAndTrack() {
        server.ok("""{"data":[{"id":"evt_2","type":"message.delivered"}],"has_more":true,"next_cursor":"c2"}""")
        server.ok("""{"data":[{"id":"evt_1","type":"message.delivered"}],"has_more":false,"next_cursor":null}""")
        server.ok("""{"object":"event_wait","data":[],"cursor":"w1","has_more":false}""")
        server.ok("""{"object":"event_wait","data":[{"id":"evt_3","data":{"message_id":"msg_1"}}],"cursor":"w2","has_more":false}""")
        server.reply(201, """{"id":"tev_1","object":"tracked_event","runs_started":["run_1"]}""")
        server.reply(201, """{"id":"tev_2","object":"tracked_event"}""")
        val (c, _) = stubClient(server)
        assertEquals(listOf("evt_2", "evt_1"), c.events.listAll(type = "message.delivered").map { it.id })
        val first = c.events.wait()
        val second = c.events.wait(first.cursor, 20)
        assertEquals("evt_3", second.data[0].id)
        assertEquals("\"msg_1\"", second.data[0].data!!["message_id"].toString())
        val r = c.events.track("trial_started", userId = "123", phone = "+15005550006", properties = mapOf("plan" to "pro"))
        c.events.track("subscription_created", userId = "123", idempotencyKey = "mine")
        assertEquals(listOf("run_1"), r.runsStarted)
        val calls = server.calls
        assertEquals("/events?type=message.delivered", calls[0].path)
        assertEquals("/events?cursor=c2&type=message.delivered", calls[1].path)
        assertEquals("/events/wait", calls[2].path)
        assertEquals("/events/wait?cursor=w1&timeout=20", calls[3].path)
        assertEquals(j("""{"event":"trial_started","user_id":"123","phone":"+15005550006","properties":{"plan":"pro"}}"""), calls[4].json)
        assertTrue(calls[4].headers["idempotency-key"]!!.startsWith("sdk_"))
        assertEquals(j("""{"event":"subscription_created","user_id":"123"}"""), calls[5].json)
        assertEquals("mine", calls[5].headers["idempotency-key"])
    }

    @Test fun webhookEndpoints() {
        val ep = """{"id":"we_1","object":"webhook_endpoint","url":"https://example.com/h","events":"*","active":true}"""
        server.reply(201, """{"id":"we_1","url":"https://example.com/h","events":["message.received"],"secret":"whsec_x"}""")
        server.ok("""{"data":[$ep]}""").ok(ep).ok(ep).ok(ep).ok("""{"id":"we_1","object":"webhook_endpoint","deleted":true}""")
        server.reply(500, err("internal_error"))
        val (c, _) = stubClient(server)
        val created = c.webhooks.create("https://example.com/h", listOf("message.received"), "orders")
        assertEquals("whsec_x", created.secret)
        assertEquals(listOf("message.received"), created.events)
        assertEquals(listOf("*"), c.webhooks.list().data[0].events)
        c.webhooks.get("we_1")
        c.webhooks.update("we_1", UpdateWebhookParams().active(false))
        c.webhooks.update("we_1", UpdateWebhookParams().description(null).events(listOf("*")))
        assertTrue(c.webhooks.delete("we_1").deleted)
        assertThrows<TextKitException> { c.webhooks.create("https://example.com/h") } // not retried
        val calls = calls()
        assertEquals(
            Triple("POST", "/webhooks", j("""{"url":"https://example.com/h","events":["message.received"],"description":"orders"}""")),
            calls[0],
        )
        assertEquals(Triple("GET", "/webhooks", null), calls[1])
        assertEquals(Triple("GET", "/webhooks/we_1", null), calls[2])
        assertEquals(Triple("PATCH", "/webhooks/we_1", j("""{"active":false}""")), calls[3])
        assertEquals(Triple("PATCH", "/webhooks/we_1", j("""{"description":null,"events":"*"}""")), calls[4])
        assertEquals(Triple("DELETE", "/webhooks/we_1", null), calls[5])
        assertEquals(Triple("POST", "/webhooks", j("""{"url":"https://example.com/h"}""")), calls[6])
        assertEquals(7, calls.size)
    }

    @Test fun consent() {
        server.ok("""{"object":"consent","phone":"+14155550132","status":"opted_out"}""")
        server.ok("""{"object":"consent","phone":"+14155550132","status":"opted_in"}""")
        server.ok("""{"object":"consent_import","imported":1,"skipped":[]}""")
        server.ok("phone,status\n+14155550132,opted_out\n")
        server.ok("""{"object":"consent","phone":"+14155550132","status":"none","history":[]}""")
        server.ok("""{"data":[{"object":"consent","phone":"+14155550132","status":"opted_out"}],"has_more":false}""")
        val (c, _) = stubClient(server)
        c.consent.optOut("+14155550132", note = "crm")
        c.consent.optIn(
            "+14155550132",
            campaignId = "reg_1",
            proof = mapOf("source" to "web_form", "collected_at" to "2026-10-01T15:04:05Z", "page_url" to "https://acme.example/texts"),
        )
        assertEquals(1, c.consent.import(listOf("+14155550132")).imported)
        assertTrue(c.consent.export().startsWith("phone,status"))
        assertEquals("none", c.contacts.consent("+14155550132").status)
        assertEquals(listOf("+14155550132"), c.consent.listAll().map { it.phone })
        val calls = calls()
        assertEquals(Triple("POST", "/consent/%2B14155550132", j("""{"status":"opted_out","note":"crm"}""")), calls[0])
        assertEquals(
            j(
                """{"status":"opted_in","campaign_id":"reg_1","proof":{"source":"web_form",
                "collected_at":"2026-10-01T15:04:05Z","page_url":"https://acme.example/texts"}}""",
            ),
            calls[1].third,
        )
        assertEquals(Triple("POST", "/consent/import", j("""{"phone_numbers":["+14155550132"]}""")), calls[2])
        assertEquals("/consent/export", calls[3].second)
        assertEquals("/consent/%2B14155550132", calls[4].second)
        assertEquals("/consent", calls[5].second)
    }

    @Test fun customers() {
        server.reply(201, """{"id":"cus_x","name":"Acme","metadata":{"plan":"pro"}}""")
        server.ok("""{"object":"customer_usage","customer_id":"cus_x","messages_sent":3}""")
        server.ok(EMPTY_PAGE).ok("""{"id":"cus_x"}""").ok("""{"id":"cus_x"}""").ok("""{"id":"cus_x","deleted":true}""")
        val (c, _) = stubClient(server)
        c.customers.create("Acme", "acct_1", mapOf("plan" to "pro"))
        assertEquals(3, c.customers.usage("cus_x", "2026-10-01", "2026-10-31").messagesSent)
        c.customers.list(externalId = "acct 1")
        c.customers.update("cus_x", UpdateCustomerParams().name("Acme"))
        c.customers.update("cus_x", UpdateCustomerParams().externalId(null).metadata(mapOf("plan" to "pro")))
        c.customers.delete("cus_x")
        val calls = calls()
        assertEquals(j("""{"name":"Acme","external_id":"acct_1","metadata":{"plan":"pro"}}"""), calls[0].third)
        assertEquals("/customers/cus_x/usage?start=2026-10-01&end=2026-10-31", calls[1].second)
        assertEquals("/customers?external_id=acct+1", calls[2].second)
        assertEquals(Triple("PATCH", "/customers/cus_x", j("""{"name":"Acme"}""")), calls[3])
        assertEquals(j("""{"external_id":null,"metadata":{"plan":"pro"}}"""), calls[4].third)
        assertEquals(Triple("DELETE", "/customers/cus_x", null), calls[5])
    }

    @Test fun contacts() {
        server.ok("""{"id":"con_1","phone_number":"+14155550132","tags":["vip"]}""")
        server.ok("""{"object":"contact_import","created":1,"updated":1,"skipped":[]}""")
        server.ok("""{"object":"contact_bulk","action":"add_tags","updated":2,"deleted":0,"missing":0}""")
        server.ok("""{"id":"con_1"}""").ok("""{"id":"con_1"}""").ok("""{"id":"con_1","deleted":true}""")
        server.ok("""{"data":[{"id":"con_2"}],"has_more":true,"next_cursor":"k"}""").ok("""{"data":[{"id":"con_1"}],"has_more":false}""")
        val (c, _) = stubClient(server)
        assertEquals(listOf("vip"), c.contacts.upsert("+14155550132", "Ada", listOf("vip")).tags)
        c.contacts.import(listOf(ContactParams("+14155550132").name("Ada"), ContactParams("+14155550133").fields(mapOf("plan" to "pro"))))
        assertEquals(2, c.contacts.bulk("add_tags", listOf("con_1", "con_2"), listOf("vip")).updated)
        c.contacts.get("con_1")
        c.contacts.update("con_1", UpdateContactParams().name(null).tags(listOf("a")))
        c.contacts.delete("con_1")
        assertEquals(listOf("con_2", "con_1"), c.contacts.listAll(ListContactsParams().tag("vip")).map { it.id })
        val calls = calls()
        assertEquals(Triple("POST", "/contacts", j("""{"phone_number":"+14155550132","name":"Ada","tags":["vip"]}""")), calls[0])
        assertEquals(
            j("""{"contacts":[{"phone_number":"+14155550132","name":"Ada"},{"phone_number":"+14155550133","fields":{"plan":"pro"}}]}"""),
            calls[1].third,
        )
        assertEquals(Triple("POST", "/contacts/bulk", j("""{"action":"add_tags","ids":["con_1","con_2"],"tags":["vip"]}""")), calls[2])
        assertEquals(Triple("GET", "/contacts/con_1", null), calls[3])
        assertEquals(Triple("PATCH", "/contacts/con_1", j("""{"name":null,"tags":["a"]}""")), calls[4])
        assertEquals(Triple("DELETE", "/contacts/con_1", null), calls[5])
        assertEquals("/contacts?tag=vip", calls[6].second)
        assertEquals("/contacts?tag=vip&cursor=k", calls[7].second)
    }

    @Test fun automations() {
        server.reply(201, """{"id":"auto_x","status":"draft","issues":[]}""")
        repeat(4) { server.ok("""{"id":"auto_x"}""") }
        server.ok("""{"data":[{"id":"run_1","status":"waiting"}],"has_more":false}""")
        server.ok("""{"id":"run_1"}""").ok("""{"id":"run_1","status":"failed"}""").ok("""{"id":"auto_x","deleted":true}""")
        server.ok("""{"data":[{"id":"auto_x"}]}""")
        val (c, _) = stubClient(server)
        val steps = listOf(mapOf("type" to "wait", "seconds" to 3600), mapOf("type" to "send_sms", "body" to "hi"))
        c.automations.create(CreateAutomationParams("Welcome", mapOf("event" to "user_signed_up"), steps).from("+15005550100"))
        c.automations.update("auto_x", UpdateAutomationParams().topicId(null))
        c.automations.get("auto_x")
        c.automations.activate("auto_x")
        c.automations.pause("auto_x")
        assertEquals("waiting", c.automations.runs("auto_x", limit = 5).data[0].status)
        c.automations.run("auto_x", "run_1")
        c.automations.cancelRun("auto_x", "run_1")
        c.automations.delete("auto_x")
        assertEquals("auto_x", c.automations.list().data[0].id)
        val calls = calls()
        assertEquals(
            Triple(
                "POST", "/automations",
                j(
                    """{"name":"Welcome","trigger":{"event":"user_signed_up"},
                    "steps":[{"type":"wait","seconds":3600},{"type":"send_sms","body":"hi"}],"from":"+15005550100"}""",
                ),
            ),
            calls[0],
        )
        assertEquals(Triple("PATCH", "/automations/auto_x", j("""{"topic_id":null}""")), calls[1])
        assertEquals(
            listOf(
                "GET /automations/auto_x", "POST /automations/auto_x/activate", "POST /automations/auto_x/pause",
                "GET /automations/auto_x/runs?limit=5", "GET /automations/auto_x/runs/run_1",
                "DELETE /automations/auto_x/runs/run_1", "DELETE /automations/auto_x", "GET /automations",
            ),
            calls.drop(2).map { "${it.first} ${it.second}" },
        )
    }

    @Test fun schedules() {
        val repeat = ScheduleRepeat.daily("08:00", "America/New_York")
        server.reply(201, """{"id":"sch_x","object":"schedule","repeat":{"frequency":"daily","time":"08:00","timezone":"America/New_York"},"next_run_at":"2026-10-02T12:00:00Z"}""")
        server.reply(201, """{"id":"sch_y"}""")
        server.ok("""{"id":"sch_x"}""").ok(EMPTY_PAGE)
        repeat(3) { server.ok("""{"id":"sch_x"}""") }
        server.ok("""{"id":"sch_x","object":"schedule","deleted":true}""").ok(EMPTY_PAGE)
        val (c, _) = stubClient(server)
        val s = c.schedules.create(CreateScheduleParams("+15005550006", "Good morning", repeat).maxOccurrences(30))
        assertEquals("daily", s.repeat!!.frequency)
        c.schedules.create(
            CreateScheduleParams("+15005550006", "a", ScheduleRepeat.weekly(listOf("mon", "fri"), "09:00", "UTC"))
                .from("+15005550199").idempotencyKey("mine"),
        )
        c.schedules.get("sch_x")
        c.schedules.list()
        c.schedules.pause("sch_x")
        c.schedules.resume("sch_x")
        c.schedules.update("sch_x", UpdateScheduleParams().body("new").endDate(null))
        c.schedules.delete("sch_x")
        c.messages.list(ListMessagesParams().scheduleId("sch_x"))
        val calls = calls()
        // No `from`: the API picks the account's one number for the key's mode.
        assertEquals(
            Triple(
                "POST", "/schedules",
                j("""{"to":"+15005550006","body":"Good morning","repeat":{"frequency":"daily","time":"08:00","timezone":"America/New_York"},"max_occurrences":30}"""),
            ),
            calls[0],
        )
        assertTrue(server.calls[0].headers["idempotency-key"]!!.startsWith("sdk_"))
        assertEquals(
            j("""{"to":"+15005550006","body":"a","repeat":{"frequency":"weekly","time":"09:00","timezone":"UTC","days_of_week":["mon","fri"]},"from":"+15005550199"}"""),
            calls[1].third,
        )
        assertEquals("mine", server.calls[1].headers["idempotency-key"])
        assertEquals(Triple("GET", "/schedules/sch_x", null), calls[2])
        assertEquals(Triple("GET", "/schedules", null), calls[3])
        assertEquals(Triple("PATCH", "/schedules/sch_x", j("""{"active":false}""")), calls[4])
        assertEquals(Triple("PATCH", "/schedules/sch_x", j("""{"active":true}""")), calls[5])
        assertEquals(Triple("PATCH", "/schedules/sch_x", j("""{"body":"new","end_date":null}""")), calls[6])
        assertEquals(Triple("DELETE", "/schedules/sch_x", null), calls[7])
        assertEquals("/messages?schedule_id=sch_x", calls[8].second)
    }

    @Test fun scheduleUsesDefaultFrom() {
        server.reply(201, """{"id":"sch_x"}""")
        val (c, _) = stubClient(server) { defaultFrom("+15005550100") }
        c.schedules.create("+15005550006", "a", ScheduleRepeat.monthly(1, "08:00", "UTC"))
        assertEquals(
            j("""{"to":"+15005550006","body":"a","repeat":{"frequency":"monthly","time":"08:00","timezone":"UTC","day_of_month":1},"from":"+15005550100"}"""),
            server.calls[0].json,
        )
    }

    @Test fun registrations() {
        server.reply(201, """{"id":"reg_1","status":"ready","guidance":{"next_actor":"you"}}""")
        server.ok("""{"id":"reg_1","status":"ready"}""").ok("""{"id":"reg_1","status":"submitted"}""")
        server.ok("""{"data":[{"object":"registration_submission","number":1}]}""").ok("""{"id":"reg_1"}""").ok("""{"data":[]}""")
        val (c, _) = stubClient(server)
        val missing = assertThrows<TextKitException> { c.registrations.create(RegistrationParams().businessName("Acme")) }
        assertEquals("website", missing.param)
        val reg = c.registrations.create(
            RegistrationParams()
                .businessName("Acme Plumbing LLC")
                .website("https://acmeplumbing.com")
                .useCase("customer_care")
                .sampleMessages(listOf("Acme Plumbing: your plumber arrives tomorrow. Reply STOP to opt out."))
                .brand(mapOf("legal_name" to "Acme Plumbing LLC", "ein" to "12-3456789")),
        )
        assertEquals("ready", reg.status)
        c.registrations.recheck("reg_1", RegistrationParams().optInUrl("https://acmeplumbing.com/text"))
        c.registrations.submit("reg_1", true, Attestation("Dana Smith", "Owner"))
        assertEquals(1, c.registrations.submissions("reg_1").data[0].number)
        c.registrations.get("reg_1")
        c.registrations.list()
        val calls = calls()
        assertEquals(
            j(
                """{"business_name":"Acme Plumbing LLC","website":"https://acmeplumbing.com","use_case":"customer_care",
                "sample_messages":["Acme Plumbing: your plumber arrives tomorrow. Reply STOP to opt out."],
                "brand":{"legal_name":"Acme Plumbing LLC","ein":"12-3456789"}}""",
            ),
            calls[0].third,
        )
        assertEquals(Triple("POST", "/registrations/reg_1/recheck", j("""{"opt_in_url":"https://acmeplumbing.com/text"}""")), calls[1])
        assertEquals(
            Triple(
                "POST", "/registrations/reg_1/submit",
                j("""{"attestation":{"signer_name":"Dana Smith","signer_title":"Owner","accepted":true},"fees_acknowledged":true}"""),
            ),
            calls[2],
        )
        assertEquals("/registrations/reg_1/submissions", calls[3].second)
        assertEquals("/registrations/reg_1", calls[4].second)
        assertEquals("/registrations", calls[5].second)
    }

    @Test fun unknownFieldsAndNullsAreTolerated() {
        server.ok("""{"id":"msg_1","object":"message","status":"delivered","brand_new_field":{"x":1},"customer_id":null,"tags":null}""")
        val (c, _) = stubClient(server)
        val m = c.messages.get("msg_1")
        assertEquals("delivered", m.status)
        assertNull(m.customerId)
    }
}
