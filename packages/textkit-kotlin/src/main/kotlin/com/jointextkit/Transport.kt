package com.jointextkit

import java.io.IOException
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.time.Duration

/** One HTTP request, as the client hands it to a [Transport]. */
class TransportRequest(
    val method: String,
    val url: String,
    /** Header names as sent (`Authorization`, `Idempotency-Key`, ...). */
    val headers: Map<String, String>,
    /** JSON bytes, or null for a request without a body. */
    val body: ByteArray?,
    val timeout: Duration,
)

/** One HTTP response. 4xx and 5xx are responses too: return them, don't throw. */
class TransportResponse(
    val status: Int,
    /** Header names lowercased. */
    val headers: Map<String, String>,
    val body: ByteArray,
)

/**
 * The HTTP layer. Swap it for tests, tracing or proxies.
 * Throw an [IOException] when the request could not be completed (the client
 * turns it into a `connection_error` and retries where that is safe).
 */
fun interface Transport {
    @Throws(IOException::class)
    fun execute(request: TransportRequest): TransportResponse
}

/** The default transport: `java.net.http.HttpClient`, nothing to install. */
class JavaHttpTransport @JvmOverloads constructor(
    private val http: HttpClient = HttpClient.newBuilder()
        .connectTimeout(Duration.ofSeconds(10))
        .followRedirects(HttpClient.Redirect.NEVER)
        .build(),
) : Transport {
    override fun execute(request: TransportRequest): TransportResponse {
        val builder = HttpRequest.newBuilder(URI.create(request.url)).timeout(request.timeout)
        for ((name, value) in request.headers) builder.header(name, value)
        val publisher = request.body?.let { HttpRequest.BodyPublishers.ofByteArray(it) }
            ?: HttpRequest.BodyPublishers.noBody()
        builder.method(request.method, publisher)
        val response = try {
            http.send(builder.build(), HttpResponse.BodyHandlers.ofByteArray())
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            throw IOException("Interrupted", e)
        }
        val headers = response.headers().map().entries
            .filter { it.value.isNotEmpty() }
            .associate { it.key.lowercase() to it.value.first() }
        return TransportResponse(response.statusCode(), headers, response.body() ?: ByteArray(0))
    }
}
