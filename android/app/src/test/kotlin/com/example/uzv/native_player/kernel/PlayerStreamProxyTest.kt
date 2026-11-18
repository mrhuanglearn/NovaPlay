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

class PlayerStreamProxyTest {
    private lateinit var upstream: ServerSocket
    private var upstreamPort = 0
    private val routes = HashMap<String, Pair<String, ByteArray>>()

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
                        while (true) {
                            val h = reader.readLine() ?: break
                            if (h.isEmpty()) break
                        }
                        val path = line.split(' ').getOrNull(1)?.substringBefore('?').orEmpty()
                        val hit = routes[path]
                        val out = s.getOutputStream()
                        if (hit == null) {
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
