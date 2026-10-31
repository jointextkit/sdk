package com.jointextkit

import com.sun.net.httpserver.HttpServer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import java.net.InetSocketAddress
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CopyOnWriteArrayList

/**
 * A local HTTP server that answers with scripted replies, in order, and
 * records every request. Tests drive the real JavaHttpTransport against it:
 * no network, no real keys.
 */
class StubServer : AutoCloseable {
    class Reply(val status: Int, val body: String, val headers: Map<String, String> = emptyMap())

    class Recorded(
        val method: String,
        /** Path after `/v1`, with the raw query string. */
        val path: String,
        /** Header names lowercased. */
        val headers: Map<String, String>,
        val rawBody: String,
    ) {
        val json: JsonElement? get() = if (rawBody.isEmpty()) null else Json.parseToJsonElement(rawBody)
    }

    private val replies = ConcurrentLinkedQueue<Reply>()
    val calls = CopyOnWriteArrayList<Recorded>()
    private val server: HttpServer = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)

    init {
        server.createContext("/") { exchange ->
            val uri = exchange.requestURI
            val full = uri.rawPath + (uri.rawQuery?.let { "?$it" } ?: "")
            val headers = exchange.requestHeaders.entries.associate { it.key.lowercase() to it.value.first() }
            val body = exchange.requestBody.readBytes().toString(Charsets.UTF_8)
            calls.add(Recorded(exchange.requestMethod, full.removePrefix("/v1"), headers, body))
            val reply = replies.poll() ?: Reply(599, """{"error":{"code":"stub_exhausted","message":"No scripted reply left"}}""")
            for ((k, v) in reply.headers) exchange.responseHeaders.add(k, v)
            exchange.responseHeaders.add("Content-Type", "application/json")
            val bytes = reply.body.toByteArray(Charsets.UTF_8)
            exchange.sendResponseHeaders(reply.status, if (bytes.isEmpty()) -1 else bytes.size.toLong())
            if (bytes.isNotEmpty()) exchange.responseBody.use { it.write(bytes) }
            exchange.close()
        }
        server.start()
    }

    val baseUrl: String get() = "http://127.0.0.1:${server.address.port}"

    fun reply(status: Int, body: String, headers: Map<String, String> = emptyMap()) = apply {
        replies.add(Reply(status, body, headers))
    }

    fun ok(body: String) = reply(200, body)

    override fun close() = server.stop(0)
}
