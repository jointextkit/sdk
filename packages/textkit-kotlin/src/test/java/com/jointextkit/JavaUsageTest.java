package com.jointextkit;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;

/** The SDK as plain Java sees it: builders, fluent params, overloads, static verify. */
class JavaUsageTest {
    private final StubServer server = new StubServer();

    @AfterEach
    void stop() {
        server.close();
    }

    private TextKit client() {
        return TextKit.builder()
                .apiKey("ssms_sk_test_java")
                .baseUrl(server.getBaseUrl())
                .defaultFrom("+15005550100")
                .maxRetries(0)
                .timeout(Duration.ofSeconds(5))
                .build();
    }

    @Test
    void sendAndReadBack() {
        server.reply(201, "{\"id\":\"msg_1\",\"status\":\"queued\"}", Map.of());
        server.reply(201, "{\"id\":\"msg_2\",\"status\":\"queued\"}", Map.of());
        TextKit client = client();
        Message m = client.messages().send("+15005550006", "Hello from Java");
        assertEquals("msg_1", m.getId());
        assertEquals("queued", m.getStatus());
        client.messages().send(new SendMessageParams("+15005550006", "Hi").customerId("cus_x").idempotencyKey("order:7"));
        assertEquals("order:7", server.getCalls().get(1).getHeaders().get("idempotency-key"));
        assertTrue(client.isTestMode());
    }

    @Test
    void paginationIsAnIterable() {
        server.reply(200, "{\"data\":[{\"id\":\"m2\"}],\"has_more\":true,\"next_cursor\":\"k\"}", Map.of());
        server.reply(200, "{\"data\":[{\"id\":\"m1\"}],\"has_more\":false}", Map.of());
        List<String> ids = new ArrayList<>();
        for (Message m : client().messages().listAll(new ListMessagesParams().limit(1))) {
            ids.add(m.getId());
        }
        assertEquals(List.of("m2", "m1"), ids);
    }

    @Test
    void overloadsAndParams() {
        server.reply(201, "{\"id\":\"job_1\"}", Map.of());
        server.reply(200, "{\"id\":\"sch_1\"}", Map.of());
        server.reply(200, "{\"object\":\"consent_import\",\"imported\":2,\"skipped\":[]}", Map.of());
        server.reply(201, "{\"id\":\"ver_1\",\"status\":\"pending\"}", Map.of());
        TextKit client = client();
        client.messages().schedule("+15005550006", "later", Instant.parse("2026-10-02T09:30:00Z"));
        client.schedules().update("sch_1", new UpdateScheduleParams().body("new").endDate(null));
        ConsentImport result = client.consent().importNumbers(List.of("+14155550132", "+14155550133"));
        assertEquals(2, result.getImported());
        client.verify().send("+14155550132", "Acme");
        server.reply(200, "{\"object\":\"event_wait\",\"data\":[],\"cursor\":\"c1\",\"has_more\":false}", Map.of());
        assertEquals("c1", client.events().waitForEvents(null, 5).getCursor());
        assertEquals("/events/wait?timeout=5", server.getCalls().get(4).getPath());
        assertEquals("{\"body\":\"new\",\"end_date\":null}", server.getCalls().get(1).getRawBody());
    }

    @Test
    void errorsAreUnchecked() {
        server.reply(403, "{\"error\":{\"code\":\"recipient_opted_out\",\"message\":\"Opted out\"}}", Map.of());
        TextKitException e = assertThrows(TextKitException.class, () -> client().messages().send("+15005550006", "hi"));
        assertEquals("recipient_opted_out", e.getCode());
        assertEquals(403, e.getStatus());
        assertEquals(false, e.isRetryable());
    }

    @Test
    void webhookVerifyIsStatic() {
        String payload = "{\"id\":\"evt_a1B2c3D4e5F6g7H8\",\"object\":\"event\",\"type\":\"message.sent\",\"created_at\":\"2026-10-01T12:00:00.000Z\",\"data\":{\"message_id\":\"msg_a1B2c3D4e5F6g7H8\",\"to\":\"+15005550006\",\"customer_id\":\"cus_a1B2c3D4e5F6g7\"}}";
        String signature = "t=1790000000,v1=ff81f219437ed9a2a4ba740e9531e86a63b163507d803b21259b4f89d90b29b2";
        Event event = WebhookSignature.verify(payload, Map.of("TextKit-Signature", signature),
                "whsec_vectorsecret0123456789abcdefABCD", 300L, 1790000000L);
        assertEquals("message.sent", event.getType());
        assertThrows(TextKitException.class,
                () -> WebhookSignature.verify(payload, signature, "whsec_vectorsecret0123456789abcdefABCD"));
    }
}
