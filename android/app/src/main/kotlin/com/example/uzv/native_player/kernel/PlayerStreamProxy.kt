package com.example.uzv.native_player.kernel

import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.net.URISyntaxException
import java.nio.charset.StandardCharsets
import java.util.Base64
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.zip.GZIPInputStream

/**
 * Loopback HTTP/1.1 stream & HLS proxy (`127.0.0.1:<port>`) shared by EXO, MPV, and MDK on Android:
 *  1. Terminates HTTPS via Android's system TLS 1.3 stack (bypassing libmpv's mbedTLS 1.2 blackholes on CMS CDNs).
 *  2. Rewrites HLS playlists and falls back dead cross-origin segment hosts (e.g. `kkzycdn.com:65`) to the playlist's
 *     own working origin (`bfikuncdn.com`), caching the fallback per session so later segments suffer zero retry delay.
 *  3. Strips disguised PNG/JPEG/GIF/BMP prefixes before 188-byte `0x47` MPEG-TS sync packets.
 *  4. Bounds connect timeouts to 5s and records root upstream failures so dead URLs fail fast instead of spinning.
 */
object PlayerStreamProxy {
    private const val CONNECT_TIMEOUT_MS = 5_000
    private const val READ_TIMEOUT_MS = 10_000
    private const val DEFAULT_UA =
        "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36"

    private val uriAttrRegex = Regex("""URI="([^"]+)"""")
    private val methodRegex = Regex("""METHOD="?([A-Za-z0-9_-]+)"?""", RegexOption.IGNORE_CASE)
    private val inlineHeaderKeyRegex = Regex("""^[A-Za-z][A-Za-z0-9_-]*=""")
    private val inlineHeaderSplitRegex = Regex(
        """&(?=(?:User-Agent|UA|Referer|Referrer|Cookie|Origin|Authorization|Host|Accept|X-[A-Za-z0-9_-]+|Sec-[A-Za-z0-9_-]+)=)""",
        RegexOption.IGNORE_CASE,
    )

    internal class Session(
        val token: String,
        val origin: String,
        val headers: Map<String, String>,
    ) {
        // Custom headers may carry credentials under provider-specific names.
        val crossOriginHeaders = buildMap {
            for ((name, value) in headers) {
                when (name.lowercase(Locale.ROOT)) {
                    "user-agent", "accept", "accept-language" -> put(name, value)
                    "origin", "referer" -> {
                        val headerOrigin = runCatching { originOf(URI(value)) }.getOrDefault("")
                        if (headerOrigin.isNotEmpty()) {
                            put(name, if (name.equals("referer", ignoreCase = true)) "$headerOrigin/" else headerOrigin)
                        } else if (name.equals("origin", ignoreCase = true) && value == "null") {
                            put(name, value)
                        }
                    }
                }
            }
        }
        val hostFallbacks = ConcurrentHashMap<String, String>()
        @Volatile var rootError: String? = null
    }

    private val lock = Any()
    private var server: ServerSocket? = null
    private var boundPort: Int = 0
    private val sessions = LinkedHashMap<String, Session>()
    private val executor = Executors.newCachedThreadPool { r ->
        Thread(r, "uzv-stream-proxy").apply { isDaemon = true }
    }

    data class WrappedSource(val url: String, val token: String?, val forwardedHeaders: Map<String, String>)

    fun wrap(rawUrl: String, headers: Map<String, String>): WrappedSource {
        val (cleanUrl, mergedHeaders) = normalizeUrlAndHeaders(rawUrl, headers)
        val uri = try { URI(cleanUrl) } catch (_: Exception) { return WrappedSource(rawUrl, null, headers) }
        val origin = originOf(uri)
        val host = uri.host?.lowercase(Locale.ROOT)
        if (origin.isEmpty() || host == "127.0.0.1" || host == "localhost" || host == "[::1]" || host == "::1") {
            return WrappedSource(cleanUrl, null, mergedHeaders)
        }
        val port = ensureStarted() ?: return WrappedSource(cleanUrl, null, mergedHeaders)
        val token = UUID.randomUUID().toString().replace("-", "").take(16)
        synchronized(lock) {
            sessions[token] = Session(token, origin, mergedHeaders)
            while (sessions.size > 16) {
                val eldest = sessions.keys.firstOrNull() ?: break
                sessions.remove(eldest)
            }
        }
        val pathLower = uri.path.orEmpty().lowercase(Locale.ROOT)
        val isHls = pathLower.endsWith(".m3u8") || pathLower.endsWith(".m3u")
        val kind = if (isHls) "hls" else "auto"
        val fileName = if (isHls) "index.m3u8" else inferredFileName(uri.path.orEmpty())
        val proxied = buildProxyUrl(port, token, fileName, cleanUrl, origin, kind, rawSeg = false, isRoot = true)
        return WrappedSource(proxied, token, emptyMap())
    }

    fun upstreamError(token: String?): String? {
        if (token.isNullOrEmpty()) return null
        return synchronized(lock) { sessions[token] }?.rootError
    }

    private fun getSession(token: String): Session? = synchronized(lock) { sessions[token] }

    internal fun ensureStarted(): Int? {
        synchronized(lock) {
            if (boundPort > 0 && server?.isClosed == false) return boundPort
            return try {
                val srv = ServerSocket(0, 64, InetAddress.getByName("127.0.0.1"))
                server = srv
                boundPort = srv.localPort
                executor.execute { acceptLoop(srv) }
                boundPort
            } catch (_: IOException) {
                null
            }
        }
    }

    private fun acceptLoop(srv: ServerSocket) {
        while (!srv.isClosed) {
            val client = try { srv.accept() } catch (_: IOException) { break }
            executor.execute { handleClient(client) }
        }
    }

    private fun handleClient(socket: Socket) {
        socket.use { sock ->
            sock.tcpNoDelay = true
            sock.soTimeout = 15_000
            val input = sock.getInputStream()
            val out = BufferedOutputStream(sock.getOutputStream(), 32 * 1024)
            val reqLine = readAsciiLine(input) ?: return
            val parts = reqLine.split(' ')
            if (parts.size < 2) return
            val method = parts[0].uppercase(Locale.ROOT)
            val target = parts[1]
            var clientRange: String? = null
            while (true) {
                val h = readAsciiLine(input) ?: break
                if (h.isEmpty()) break
                if (h.startsWith("Range:", ignoreCase = true)) {
                    clientRange = h.substringAfter(':').trim().takeIf { it.isNotEmpty() }
                }
            }
            if (method != "GET" && method != "HEAD") {
                writeSimpleStatus(out, 405, "Method Not Allowed")
                return
            }
            val reqUri = try { URI("http://127.0.0.1$target") } catch (_: Exception) {
                writeSimpleStatus(out, 400, "Bad Request")
                return
            }
            val segs = reqUri.path.orEmpty().trim('/').split('/')
            if (segs.size < 2 || segs[0] != "s") {
                writeSimpleStatus(out, 404, "Not Found")
                return
            }
            val session = getSession(segs[1])
            if (session == null) {
                writeSimpleStatus(out, 404, "Session Expired")
                return
            }
            val query = parseQuery(reqUri.rawQuery.orEmpty())
            val upstreamUrl = query["u"]?.let(::b64UrlDecode)
            if (upstreamUrl.isNullOrEmpty()) {
                writeSimpleStatus(out, 400, "Missing URL")
                return
            }
            val origin = query["o"]?.let(::b64UrlDecode).orEmpty()
            val kind = query["k"].orEmpty().ifEmpty { "auto" }
            val rawSeg = query["raw"] == "1"
            val isRoot = query["root"] == "1"
            serveProxyRequest(session, method, upstreamUrl, origin, kind, rawSeg, isRoot, clientRange, out)
        }
    }

    private fun serveProxyRequest(
        session: Session,
        method: String,
        rawTargetUrl: String,
        playlistOrigin: String,
        kind: String,
        rawSeg: Boolean,
        isRoot: Boolean,
        clientRange: String?,
        out: BufferedOutputStream,
    ) {
        val targetUri = try { URI(rawTargetUrl) } catch (_: Exception) {
            writeSimpleStatus(out, 400, "Bad Target")
            return
        }
        val origAuth = authorityKey(targetUri)
        val mappedOrigin = if (origAuth.isNotEmpty()) session.hostFallbacks[origAuth] else null
        val primaryUrl = if (mappedOrigin != null) replaceOrigin(targetUri, mappedOrigin) else rawTargetUrl

        var conn: HttpURLConnection? = null
        try {
            val wantIdentity = kind != "hls"
            val sendRange = if (kind == "hls" || kind == "ts" || kind == "key") null else clientRange
            val attempt = tryOpenUpstream(primaryUrl, method, session, sendRange, wantIdentity)
            val needOriginFallback = mappedOrigin == null &&
                playlistOrigin.isNotEmpty() &&
                !originOf(targetUri).equals(playlistOrigin, ignoreCase = true) &&
                (attempt.error != null || attempt.code >= 400)

            val resolved = if (needOriginFallback) {
                attempt.conn?.disconnect()
                val altUrl = replaceOrigin(targetUri, playlistOrigin)
                val second = tryOpenUpstream(altUrl, method, session, sendRange, wantIdentity)
                if (second.error == null && second.code in 200..399 && origAuth.isNotEmpty()) {
                    session.hostFallbacks[origAuth] = playlistOrigin
                }
                second
            } else {
                attempt
            }

            if (resolved.error != null || resolved.conn == null) {
                if (isRoot) session.rootError = "上游连接失败或超时，请尝试切换线路"
                writeSimpleStatus(out, 502, "Bad Gateway")
                return
            }
            conn = resolved.conn
            val code = resolved.code
            if (code >= 400) {
                if (isRoot) session.rootError = "上游返回 HTTP $code，请尝试切换线路"
                writeSimpleStatus(out, code, "Upstream Error")
                return
            }
            if (isRoot) session.rootError = null

            if (method == "HEAD") {
                val ct = conn.contentType ?: "application/octet-stream"
                val cl = conn.contentLengthLong
                val sb = StringBuilder()
                sb.append("HTTP/1.1 $code OK\r\n")
                sb.append("Content-Type: $ct\r\n")
                if (cl >= 0) sb.append("Content-Length: $cl\r\n")
                sb.append("Accept-Ranges: bytes\r\nConnection: close\r\n\r\n")
                out.write(sb.toString().toByteArray(StandardCharsets.US_ASCII))
                out.flush()
                return
            }

            val rawStream = wrapContentEncoding(conn.inputStream, conn.contentEncoding)
            rawStream.use { stream ->
                val ctLower = conn.contentType.orEmpty().lowercase(Locale.ROOT)
                val finalUrl = conn.url
                val finalPathLower = finalUrl.path.orEmpty().lowercase(Locale.ROOT)
                val definitelyHls = kind == "hls" || ctLower.contains("mpegurl") ||
                    finalPathLower.endsWith(".m3u8") || finalPathLower.endsWith(".m3u")

                if (definitelyHls) {
                    val text = stream.readBytes().toString(StandardCharsets.UTF_8)
                    val rewritten = rewriteHlsPlaylist(text, finalUrl.toURI(), boundPort, session.token)
                    writeBytesResponse(out, 200, "application/vnd.apple.mpegurl", rewritten.toByteArray(StandardCharsets.UTF_8))
                    return
                }

                if (kind == "auto" && (sendRange == null || sendRange.startsWith("bytes=0-"))) {
                    val peek = readUpTo(stream, 512)
                    if (looksLikeHlsPlaylist(peek) && sendRange == null) {
                        val rest = stream.readBytes()
                        val full = ByteArray(peek.size + rest.size)
                        System.arraycopy(peek, 0, full, 0, peek.size)
                        System.arraycopy(rest, 0, full, peek.size, rest.size)
                        val rewritten = rewriteHlsPlaylist(
                            full.toString(StandardCharsets.UTF_8),
                            finalUrl.toURI(),
                            boundPort,
                            session.token,
                        )
                        writeBytesResponse(out, 200, "application/vnd.apple.mpegurl", rewritten.toByteArray(StandardCharsets.UTF_8))
                        return
                    }
                    streamBinary(out, code, conn, peek, 0, stream)
                    return
                }

                if (kind == "ts" && !rawSeg) {
                    val peek = readUpTo(stream, 4096)
                    val syncOff = findMpegTsSyncOffset(peek) ?: 0
                    streamBinary(out, 200, conn, peek, syncOff, stream, overrideMime = "video/mp2t")
                    return
                }

                streamBinary(out, code, conn, ByteArray(0), 0, stream)
            }
        } catch (_: IOException) {
            // Client closed socket during seek / stop: normal.
        } finally {
            conn?.disconnect()
        }
    }

    private class UpstreamAttempt(val conn: HttpURLConnection?, val code: Int, val error: IOException?)

    private fun tryOpenUpstream(
        urlStr: String,
        method: String,
        session: Session,
        rangeHeader: String?,
        identityEncoding: Boolean,
    ): UpstreamAttempt {
        var currentUrl = urlStr
        var originHeadersAllowed = true
        var redirects = 0
        while (redirects <= 5) {
            var c: HttpURLConnection? = null
            try {
                val uri = URI(currentUrl)
                val origin = originOf(uri)
                if (origin.isEmpty()) return UpstreamAttempt(null, -1, IOException("Invalid upstream origin"))
                originHeadersAllowed = originHeadersAllowed && origin == session.origin
                val headers = if (originHeadersAllowed) session.headers else session.crossOriginHeaders
                c = (uri.toURL().openConnection() as HttpURLConnection).apply {
                    instanceFollowRedirects = false
                    requestMethod = method
                    connectTimeout = CONNECT_TIMEOUT_MS
                    readTimeout = READ_TIMEOUT_MS
                    useCaches = false
                    var hasUa = false
                    for ((k, v) in headers) {
                        if (k.equals("User-Agent", ignoreCase = true)) hasUa = true
                        setRequestProperty(k, v)
                    }
                    if (!hasUa) setRequestProperty("User-Agent", DEFAULT_UA)
                    if (rangeHeader != null) setRequestProperty("Range", rangeHeader)
                    if (identityEncoding) setRequestProperty("Accept-Encoding", "identity")
                }
                val code = c.responseCode
                if (code in intArrayOf(301, 302, 303, 307, 308)) {
                    val loc = c.getHeaderField("Location")?.trim()
                    c.disconnect()
                    if (loc.isNullOrEmpty()) return UpstreamAttempt(null, code, null)
                    currentUrl = uri.resolve(URI(sanitizePercentEncoding(loc))).toString()
                    redirects++
                    continue
                }
                return UpstreamAttempt(c, code, null)
            } catch (e: IOException) {
                c?.disconnect()
                return UpstreamAttempt(null, -1, e)
            } catch (e: URISyntaxException) {
                c?.disconnect()
                return UpstreamAttempt(null, -1, IOException("Invalid upstream URL", e))
            }
        }
        return UpstreamAttempt(null, 508, IOException("Too many redirects"))
    }

    private fun streamBinary(
        out: BufferedOutputStream,
        code: Int,
        conn: HttpURLConnection,
        prefix: ByteArray,
        prefixOffset: Int,
        rest: InputStream,
        overrideMime: String? = null,
    ) {
        val statusText = if (code == 206) "Partial Content" else "OK"
        val ct = overrideMime ?: conn.contentType ?: "application/octet-stream"
        val rawLen = if (conn.contentEncoding.isNullOrEmpty()) conn.contentLengthLong else -1L
        val adjustedLen = if (rawLen >= 0 && rawLen >= prefixOffset) rawLen - prefixOffset else -1L
        val contentRange = if (prefixOffset == 0) conn.getHeaderField("Content-Range") else null
        val sb = StringBuilder()
        sb.append("HTTP/1.1 $code $statusText\r\n")
        sb.append("Content-Type: $ct\r\n")
        if (adjustedLen >= 0) sb.append("Content-Length: $adjustedLen\r\n")
        if (!contentRange.isNullOrEmpty()) sb.append("Content-Range: $contentRange\r\n")
        sb.append("Accept-Ranges: bytes\r\nConnection: close\r\n\r\n")
        out.write(sb.toString().toByteArray(StandardCharsets.US_ASCII))
        if (prefix.size > prefixOffset) {
            out.write(prefix, prefixOffset, prefix.size - prefixOffset)
        }
        val buf = ByteArray(32 * 1024)
        while (true) {
            val n = rest.read(buf)
            if (n < 0) break
            if (n > 0) out.write(buf, 0, n)
        }
        out.flush()
    }

    private fun writeBytesResponse(out: BufferedOutputStream, code: Int, contentType: String, body: ByteArray) {
        val header = "HTTP/1.1 $code OK\r\n" +
            "Content-Type: $contentType\r\n" +
            "Content-Length: ${body.size}\r\n" +
            "Cache-Control: no-store\r\n" +
            "Connection: close\r\n\r\n"
        out.write(header.toByteArray(StandardCharsets.US_ASCII))
        out.write(body)
        out.flush()
    }

    private fun writeSimpleStatus(out: BufferedOutputStream, code: Int, msg: String) {
        val body = msg.toByteArray(StandardCharsets.UTF_8)
        val header = "HTTP/1.1 $code $msg\r\nContent-Type: text/plain\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n"
        try {
            out.write(header.toByteArray(StandardCharsets.US_ASCII))
            out.write(body)
            out.flush()
        } catch (_: IOException) {}
    }

    internal fun rewriteHlsPlaylist(
        playlist: String,
        baseUri: URI,
        port: Int,
        token: String,
    ): String {
        val origin = originOf(baseUri)
        val outLines = ArrayList<String>()
        var expectVariant = false
        var hasEncryption = false
        var hasByteRange = false

        for (rawLine in playlist.lineSequence()) {
            val line = rawLine.trim()
            if (line.isEmpty()) continue
            if (line.startsWith("#")) {
                val upper = line.uppercase(Locale.ROOT)
                when {
                    upper.startsWith("#EXT-X-STREAM-INF") -> expectVariant = true
                    upper.startsWith("#EXT-X-BYTERANGE") -> hasByteRange = true
                    upper.startsWith("#EXT-X-KEY") || upper.startsWith("#EXT-X-SESSION-KEY") -> {
                        val method = methodRegex.find(line)?.groupValues?.getOrNull(1)?.uppercase(Locale.ROOT)
                        if (method != null) hasEncryption = method != "NONE"
                    }
                }
                if (line.contains("URI=\"")) {
                    val isPlaylistAttr = upper.startsWith("#EXT-X-MEDIA:") || upper.startsWith("#EXT-X-I-FRAME-STREAM-INF:")
                    val isMapAttr = upper.startsWith("#EXT-X-MAP:")
                    val replaced = uriAttrRegex.replace(line) { m ->
                        val resolved = resolveHlsRef(m.groupValues[1], baseUri) ?: return@replace m.value
                        val proxied = when {
                            isPlaylistAttr -> buildProxyUrl(port, token, "sub.m3u8", resolved, origin, "hls", false, false)
                            isMapAttr -> buildProxyUrl(port, token, "init.mp4", resolved, origin, "raw", false, false)
                            else -> buildProxyUrl(port, token, "enc.key", resolved, origin, "key", false, false)
                        }
                        "URI=\"$proxied\""
                    }
                    outLines.add(replaced)
                } else {
                    outLines.add(line)
                }
                continue
            }

            val resolved = resolveHlsRef(line, baseUri)
            if (resolved == null) {
                outLines.add(line)
                expectVariant = false
                hasByteRange = false
                continue
            }
            val ext = try {
                URI(resolved).path.orEmpty().substringAfterLast('.', "").lowercase(Locale.ROOT)
            } catch (_: Exception) { "" }

            val proxied = when {
                expectVariant || ext == "m3u8" || ext == "m3u" ->
                    buildProxyUrl(port, token, "sub.m3u8", resolved, origin, "hls", false, false)
                ext in setOf("m4s", "mp4", "cmfv", "cmfa", "vtt", "webvtt", "aac", "mp3", "ac3", "ec3") ->
                    buildProxyUrl(port, token, "seg.$ext", resolved, origin, "raw", false, false)
                else ->
                    buildProxyUrl(port, token, "seg.ts", resolved, origin, "ts", hasEncryption || hasByteRange, false)
            }
            outLines.add(proxied)
            expectVariant = false
            hasByteRange = false
        }
        return outLines.joinToString("\n") + "\n"
    }

    internal fun findMpegTsSyncOffset(data: ByteArray): Int? {
        val n = data.size
        if (n <= 0) return null
        if (n < 189) return if (data[0] == 0x47.toByte()) 0 else null
        if (data[0] == 0x47.toByte() && data[188] == 0x47.toByte() && (n < 377 || data[376] == 0x47.toByte())) return 0
        val maxOff = minOf(n - 188, 3800)
        for (off in 1 until maxOff) {
            if (data[off] != 0x47.toByte()) continue
            if (off + 564 < n) {
                if (data[off + 188] == 0x47.toByte() && data[off + 376] == 0x47.toByte() && data[off + 564] == 0x47.toByte()) return off
            } else if (off + 376 < n) {
                if (data[off + 188] == 0x47.toByte() && data[off + 376] == 0x47.toByte()) return off
            }
        }
        return null
    }

    internal fun normalizeUrlAndHeaders(rawUrl: String, headers: Map<String, String>): Pair<String, Map<String, String>> {
        val cleaned = LinkedHashMap<String, String>()
        for ((k, v) in headers) {
            val ck = k.replace(Regex("[\\r\\n:]"), "").trim()
            val cv = v.replace(Regex("[\\r\\n]"), " ").trim()
            if (ck.isNotEmpty() && cv.isNotEmpty()) cleaned[canonicalHeaderName(ck)] = cv
        }
        val trimmed = rawUrl.trim()
        val schemeIdx = trimmed.indexOf("://")
        if (schemeIdx <= 0) return trimmed to cleaned
        val pipeIdx = trimmed.indexOf('|', schemeIdx + 3)
        if (pipeIdx > 0) {
            val urlPart = trimmed.substring(0, pipeIdx).trim()
            val tail = trimmed.substring(pipeIdx + 1).trim()
            if (inlineHeaderKeyRegex.containsMatchIn(tail)) {
                var parsed = false
                for (chunk in tail.split('|')) {
                    for (seg in inlineHeaderSplitRegex.split(chunk)) {
                        val eq = seg.indexOf('=')
                        if (eq <= 0) continue
                        val hk = seg.substring(0, eq).trim()
                        val hv = seg.substring(eq + 1).replace(Regex("[\\r\\n]"), " ").trim()
                        if (hk.isNotEmpty() && hv.isNotEmpty()) {
                            cleaned[canonicalHeaderName(hk)] = hv
                            parsed = true
                        }
                    }
                }
                if (parsed) return sanitizePercentEncoding(urlPart) to cleaned
            }
        }
        return sanitizePercentEncoding(trimmed) to cleaned
    }

    private fun canonicalHeaderName(name: String): String = when (name.lowercase(Locale.ROOT)) {
        "ua", "user-agent" -> "User-Agent"
        "referer", "referrer" -> "Referer"
        "cookie" -> "Cookie"
        "origin" -> "Origin"
        "authorization" -> "Authorization"
        else -> name
    }

    private fun resolveHlsRef(rawRef: String, baseUri: URI): String? {
        val trimmed = rawRef.trim()
        if (trimmed.isEmpty()) return null
        val lower = trimmed.lowercase(Locale.ROOT)
        if (lower.startsWith("data:") || lower.startsWith("skd:")) return null
        return try {
            baseUri.resolve(sanitizePercentEncoding(trimmed)).toString()
        } catch (_: Exception) {
            null
        }
    }

    private fun buildProxyUrl(
        port: Int,
        token: String,
        fileName: String,
        targetUrl: String,
        origin: String,
        kind: String,
        rawSeg: Boolean,
        isRoot: Boolean,
    ): String {
        val sb = StringBuilder("http://127.0.0.1:")
            .append(port).append("/s/").append(token).append('/').append(fileName)
            .append("?u=").append(b64UrlEncode(targetUrl))
            .append("&k=").append(kind)
        if (origin.isNotEmpty()) sb.append("&o=").append(b64UrlEncode(origin))
        if (rawSeg) sb.append("&raw=1")
        if (isRoot) sb.append("&root=1")
        return sb.toString()
    }

    private fun originOf(uri: URI): String {
        val scheme = uri.scheme?.lowercase(Locale.ROOT)
        val defaultPort = when (scheme) {
            "http" -> 80
            "https" -> 443
            else -> return ""
        }
        val host = uri.host?.lowercase(Locale.ROOT) ?: return ""
        val port = uri.port
        if (port !in -1..65535) return ""
        val suffix = if (port == -1 || port == defaultPort) "" else ":$port"
        return "$scheme://$host$suffix"
    }

    private fun authorityKey(uri: URI): String = uri.rawAuthority?.lowercase(Locale.ROOT).orEmpty()

    private fun replaceOrigin(targetUri: URI, newOrigin: String): String {
        val path = targetUri.rawPath?.ifEmpty { "/" } ?: "/"
        val q = targetUri.rawQuery?.let { "?$it" }.orEmpty()
        return "${newOrigin.trimEnd('/')}$path$q"
    }

    private fun inferredFileName(path: String): String {
        val ext = path.substringAfterLast('/', "").substringAfterLast('.', "").lowercase(Locale.ROOT)
        return if (ext in setOf("mp4", "m4v", "mov", "mkv", "webm", "flv", "avi", "ts", "mp3", "m4a", "aac")) "stream.$ext" else "stream"
    }

    private fun looksLikeHlsPlaylist(bytes: ByteArray): Boolean {
        var i = 0
        if (bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte()) i = 3
        while (i < bytes.size && (bytes[i] == ' '.code.toByte() || bytes[i] == '\t'.code.toByte() || bytes[i] == '\r'.code.toByte() || bytes[i] == '\n'.code.toByte())) i++
        if (bytes.size - i < 7) return false
        val head = String(bytes, i, 7, StandardCharsets.US_ASCII)
        return head.equals("#EXTM3U", ignoreCase = true)
    }

    private fun wrapContentEncoding(raw: InputStream, encoding: String?): InputStream =
        if (encoding != null && encoding.contains("gzip", ignoreCase = true)) GZIPInputStream(raw) else raw

    private fun readUpTo(stream: InputStream, maxBytes: Int): ByteArray {
        val out = ByteArrayOutputStream(minOf(maxBytes, 4096))
        val buf = ByteArray(minOf(maxBytes, 1024))
        while (out.size() < maxBytes) {
            val n = stream.read(buf, 0, minOf(buf.size, maxBytes - out.size()))
            if (n <= 0) break
            out.write(buf, 0, n)
        }
        return out.toByteArray()
    }

    private fun readAsciiLine(input: InputStream): String? {
        val sb = StringBuilder()
        var sawAny = false
        while (sb.length < 16_384) {
            val b = input.read()
            if (b < 0) return if (sawAny) sb.toString() else null
            sawAny = true
            if (b == '\n'.code) break
            if (b != '\r'.code) sb.append(b.toChar())
        }
        return sb.toString()
    }

    private fun parseQuery(rawQuery: String): Map<String, String> {
        if (rawQuery.isEmpty()) return emptyMap()
        val map = HashMap<String, String>()
        for (part in rawQuery.split('&')) {
            val eq = part.indexOf('=')
            if (eq > 0) map[part.substring(0, eq)] = part.substring(eq + 1)
        }
        return map
    }

    internal fun sanitizePercentEncoding(raw: String): String {
        val bytes = raw.trim().toByteArray(StandardCharsets.UTF_8)
        val sb = StringBuilder(bytes.size + 16)
        var i = 0
        while (i < bytes.size) {
            val b = bytes[i].toInt() and 0xFF
            if (b == 0x25) {
                if (i + 2 < bytes.size && isHex(bytes[i + 1]) && isHex(bytes[i + 2])) {
                    sb.append('%').append(bytes[i + 1].toInt().toChar()).append(bytes[i + 2].toInt().toChar())
                    i += 3
                    continue
                }
                sb.append("%25")
                i++
                continue
            }
            if (isSafeUriByte(b)) sb.append(b.toChar()) else sb.append(String.format(Locale.ROOT, "%%%02X", b))
            i++
        }
        return sb.toString()
    }

    private fun isHex(b: Byte): Boolean {
        val c = b.toInt() and 0xFF
        return (c in 0x30..0x39) || (c in 0x41..0x46) || (c in 0x61..0x66)
    }

    private fun isSafeUriByte(b: Int): Boolean =
        (b in 0x41..0x5A) || (b in 0x61..0x7A) || (b in 0x30..0x39) ||
            b in intArrayOf(
                0x2D, 0x2E, 0x5F, 0x7E, 0x3A, 0x2F, 0x3F, 0x23, 0x40,
                0x21, 0x24, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x3B, 0x3D, 0x5B, 0x5D,
            )

    private fun b64UrlEncode(s: String): String =
        Base64.getUrlEncoder().withoutPadding().encodeToString(s.toByteArray(StandardCharsets.UTF_8))

    private fun b64UrlDecode(s: String): String? = try {
        String(Base64.getUrlDecoder().decode(s), StandardCharsets.UTF_8)
    } catch (_: IllegalArgumentException) {
        null
    }
}
