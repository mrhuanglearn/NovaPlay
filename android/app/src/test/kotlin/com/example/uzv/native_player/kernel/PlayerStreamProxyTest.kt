package com.example.uzv.native_player.kernel

import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.ServerSocket
import java.net.URI
import java.net.URL
import java.nio.charset.StandardCharsets
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

class PlayerStreamProxyTest {
    private lateinit var upstream: ServerSocket
    private var upstreamPort = 0
    private val routes = ConcurrentHashMap<String, Pair<String, ByteArray>>()
    private val redirects = ConcurrentHashMap<String, String>()
    private val requestHeaders = ConcurrentHashMap<String, Map<String, String>>()

    @Before
    fun setUp() {
        upstream = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))
        upstreamPort = upstream.localPort
        Thread({
            while (!upstream.isClosed) {
                val sock = try { upstream.accept() } catch (_: Exception) { break }
                Thread({
                    sock.use { s ->
                        val reader = BufferedReader(InputStreamReader(s.getInputStream(), StandardCharsets.US_ASCII))
                        val line = reader.readLine() ?: return@use
                        val headers = mutableMapOf<String, String>()
                        while (true) {
                            val h = reader.readLine() ?: break
                            if (h.isEmpty()) break
                            headers[h.substringBefore(':').lowercase(Locale.ROOT)] = h.substringAfter(':').trim()
                        }
                        val path = line.split(' ').getOrNull(1)?.substringBefore('?').orEmpty()
                        requestHeaders[path] = headers
                        val hit = routes[path]
                        val location = redirects[path]
                        val out = s.getOutputStream()
                        if (location != null) {
                            val response = "HTTP/1.1 302 Found\r\nLocation: $location\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                            out.write(response.toByteArray(StandardCharsets.US_ASCII))
                        } else if (hit == null) {
                            out.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                        } else {
                            val (ct, body) = hit
                            val hdr = "HTTP/1.1 200 OK\r\nContent-Type: $ct\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n"
                            out.write(hdr.toByteArray(StandardCharsets.US_ASCII))
                            out.write(body)
                        }
                        out.flush()
                    }
                }).apply { isDaemon = true }.start()
            }
        }).apply { isDaemon = true }.start()
    }

    @After
    fun tearDown() {
        upstream.close()
    }

    @Test
    fun syncOffsetSkipsFakePngHeaderBeforeMpegTsPackets() {
        val fakePng = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x11, 0x22, 0x33)
        val ts = ByteArray(188 * 4)
        for (i in 0 until 4) ts[i * 188] = 0x47
        val combined = fakePng + ts
        assertEquals(fakePng.size, PlayerStreamProxy.findMpegTsSyncOffset(combined))
        assertEquals(0, PlayerStreamProxy.findMpegTsSyncOffset(ts))
    }

    @Test
    fun crossOriginDeadSegmentFallsBackToPlaylistOriginAndStripsFakeImageHeader() {
        val deadPort = ServerSocket(0).use { it.localPort }
        val fakeHeader = "PNGFAKE!".toByteArray(StandardCharsets.US_ASCII)
        val tsPayload = ByteArray(188 * 4) { idx -> if (idx % 188 == 0) 0x47 else (idx and 0x7F).toByte() }

        routes["/20261117/abc/index.m3u8"] =
            "application/vnd.apple.mpegURL" to "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\n/20261117/abc/hls/index.m3u8\n".toByteArray()
        routes["/20261117/abc/hls/index.m3u8"] =
            "application/vnd.apple.mpegURL" to ("#EXTM3U\n#EXTINF:2.0,\nhttp://127.0.0.1:$deadPort/20261117/abc/hls/seg0.jpg\n#EXT-X-ENDLIST\n").toByteArray()
        routes["/20261117/abc/hls/seg0.jpg"] = "image/jpeg" to (fakeHeader + tsPayload)

        val proxyPort = PlayerStreamProxy.ensureStarted()!!
        val wrapped = PlayerStreamProxy.wrap("http://127.0.0.2:$upstreamPort/x.m3u8", emptyMap())
        assertNotNull(wrapped.token)
        val masterRewritten = PlayerStreamProxy.rewriteHlsPlaylist(
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\n/20261117/abc/hls/index.m3u8\n",
            URI("http://127.0.0.1:$upstreamPort/20261117/abc/index.m3u8"),
            proxyPort,
            wrapped.token!!,
        )
        val subProxyUrl = masterRewritten.lines().first { it.startsWith("http://127.0.0.1:$proxyPort/") }
        val subText = URL(subProxyUrl).readText()
        assertTrue(subText.contains("/seg.ts?"))
        val segProxyUrl = subText.lines().first { it.startsWith("http://127.0.0.1:$proxyPort/") }
        val conn = URL(segProxyUrl).openConnection() as HttpURLConnection
        assertEquals(200, conn.responseCode)
        val segBytes = conn.inputStream.use { it.readBytes() }
        assertArrayEquals(tsPayload, segBytes)
        assertNull(PlayerStreamProxy.upstreamError(wrapped.token))
    }

    @Test
    fun crossOriginHlsSegmentKeepsUserAgentAndOmitsOriginOnlyMetadata() {
        routes["/segment.m4s"] = "video/mp4" to "segment".toByteArray()
        // Same host, different port: the playlist's headers belong to its full origin.
        val source = URI("http://127.000.000.001:80/playlist.m3u8")
        val wrapped = PlayerStreamProxy.wrap(
            source.toString(),
            mapOf("User-Agent" to "Test Player", "X-Playback-Context" to "fixture"),
        )
        val playlist = PlayerStreamProxy.rewriteHlsPlaylist(
            "#EXTM3U\n#EXTINF:2,\nhttp://127.000.000.001:$upstreamPort/segment.m4s\n#EXT-X-ENDLIST\n",
            source,
            URI(wrapped.url).port,
            requireNotNull(wrapped.token),
        )
        val segmentUrl = playlist.lines().first { it.startsWith("http://") }
        assertEquals("segment", URL(segmentUrl).readText())
        val headers = requestHeaders.getValue("/segment.m4s")
        assertEquals("Test Player", headers["user-agent"])
        assertNull(headers["x-playback-context"])
    }

    @Test
    fun redirectChainStopsSendingOriginOnlyMetadataAfterLeavingSource() {
        // Dotted IPv4 with zero padding still connects to the JVM fixture's loopback address.
        val sourceOrigin = "http://127.000.000.001:$upstreamPort"
        redirects["/start.mp4"] = "/same-origin.mp4"
        redirects["/same-origin.mp4"] = "http://127.0.0.1:$upstreamPort/cdn.mp4"
        redirects["/cdn.mp4"] = "$sourceOrigin/return.mp4"
        routes["/return.mp4"] = "video/mp4" to "video".toByteArray()
        val referer = "https://example.test:443/watch?view=fixture"
        val wrapped = PlayerStreamProxy.wrap(
            "$sourceOrigin/start.mp4",
            mapOf("X-Playback-Context" to "fixture", "Referer" to referer, "User-Agent" to "Test Player"),
        )
        assertNotNull(wrapped.token)
        assertEquals("video", URL(wrapped.url).readText())
        for (path in listOf("/start.mp4", "/same-origin.mp4")) {
            assertEquals("fixture", requestHeaders.getValue(path)["x-playback-context"])
            assertEquals(referer, requestHeaders.getValue(path)["referer"])
        }
        for (path in listOf("/cdn.mp4", "/return.mp4")) {
            assertNull(requestHeaders.getValue(path)["x-playback-context"])
            assertEquals("https://example.test/", requestHeaders.getValue(path)["referer"])
            assertEquals("Test Player", requestHeaders.getValue(path)["user-agent"])
        }
    }

    @Test
    fun normalizeExtractsInlinePipeHeadersAndLeavesLoopbackUnwrapped() {
        val (u, h) = PlayerStreamProxy.normalizeUrlAndHeaders(
            "https://vip.example.com/a/index.m3u8|User-Agent=CustomUA&Referer=https://ref.example/",
            mapOf("Cookie" to "sid=1"),
        )
        assertEquals("https://vip.example.com/a/index.m3u8", u)
        assertEquals("CustomUA", h["User-Agent"])
        assertEquals("https://ref.example/", h["Referer"])
        assertEquals("sid=1", h["Cookie"])

        val local = PlayerStreamProxy.wrap("http://127.0.0.1:2333/proxy/x", mapOf("X-Test" to "1"))
        assertNull(local.token)
        assertEquals("http://127.0.0.1:2333/proxy/x", local.url)
        assertEquals("1", local.forwardedHeaders["X-Test"])
    }
}
