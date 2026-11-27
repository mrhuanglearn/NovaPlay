import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

typedef VideoDimensions = ({int width, int height});

bool _isLoopbackHost(String host) =>
    host == '127.0.0.1' || host == 'localhost' || host == '::1' || host == '[::1]';

const _directMediaExtensions = {
  'm3u8',
  'mp4',
  'm4v',
  'mov',
  'mkv',
  'webm',
  'flv',
  'ts',
  'mpd',
};

const _skipProbeExtensions = {
  'iso',
  'm2ts',
  'mts',
  'vob',
  'rmvb',
  'rm',
  'wmv',
  'asf',
  'divx',
  'mpg',
  'mpeg',
};

final bool _inFlutterTest = Platform.environment.containsKey('FLUTTER_TEST');

/// Ultra-lightweight stream header / manifest inspector that extracts display `(width, height)` (including container
/// rotation and SAR) in a single small HTTP Range / playlist read (<= 64 KB) without initializing a playback decoder.
class VideoFormatProbe {
  VideoFormatProbe({
    HttpClient Function()? httpClientFactory,
    this.maxCacheEntries = 128,
    this.sliceTimeout = const Duration(milliseconds: 2500),
  })  : _hasCustomClientFactory = httpClientFactory != null,
        _httpClientFactory = httpClientFactory ?? _defaultHttpClient;

  static final VideoFormatProbe shared = VideoFormatProbe();

  static const int _initialRangeBytes = 65536;
  static const int _tailMoovRangeBytes = 262144;
  static const int _manifestMaxBytes = 262144;

  final bool _hasCustomClientFactory;
  final HttpClient Function() _httpClientFactory;
  final int maxCacheEntries;
  final Duration sliceTimeout;
  HttpClient? _client;
  final LinkedHashMap<String, VideoDimensions> _cache = LinkedHashMap<String, VideoDimensions>();
  final LinkedHashMap<String, VideoDimensions> _vodCache = LinkedHashMap<String, VideoDimensions>();
  final Map<String, Future<VideoDimensions?>> _inflight = <String, Future<VideoDimensions?>>{};

  static final RegExp _inlineHeaderSplitRe = RegExp(
    r'&(?=(?:User-Agent|UA|Referer|Referrer|Cookie|Origin|Authorization|Host|Accept|X-[A-Za-z0-9_-]+|Sec-[A-Za-z0-9_-]+)=)',
    caseSensitive: false,
  );

  /// Splits TVBox/CatVod `url|Key=Val&Key2=Val2` inline pipe headers into `(cleanUrl, mergedHeaders)`.
  static ({String url, Map<String, String> headers}) normalizeUrlAndHeaders(
    String rawUrl, [
    Map<String, String> baseHeaders = const {},
  ]) {
    final trimmed = rawUrl.trim();
    final pipe = trimmed.indexOf('|');
    if (pipe < 0) return (url: trimmed, headers: baseHeaders);
    final cleanUrl = trimmed.substring(0, pipe).trim();
    final rawTail = trimmed.substring(pipe + 1).trim();
    if (rawTail.isEmpty) return (url: cleanUrl, headers: baseHeaders);
    final merged = <String, String>{...baseHeaders};
    for (final line in rawTail.split(RegExp(r'[\r\n]+'))) {
      for (final part in line.split(_inlineHeaderSplitRe)) {
        final eq = part.indexOf('=');
        if (eq <= 0) continue;
        var k = part.substring(0, eq).trim();
        final v = part.substring(eq + 1).trim();
        if (k.isEmpty || v.isEmpty) continue;
        if (k.toLowerCase() == 'ua') k = 'User-Agent';
        merged[k] = v;
      }
    }
    return (url: cleanUrl, headers: merged);
  }

  static HttpClient _defaultHttpClient() {
    final client = HttpClient();
    client.connectionTimeout = const Duration(milliseconds: 1500);
    client.idleTimeout = const Duration(seconds: 12);
    client.badCertificateCallback = (_, __, ___) => true;
    client.findProxy = (uri) => _isLoopbackHost(uri.host) ? 'DIRECT' : HttpClient.findProxyFromEnvironment(uri);
    return client;
  }

  HttpClient _obtainClient() {
    final existing = _client;
    if (existing != null) return existing;
    final created = _httpClientFactory();
    try {
      created.idleTimeout = const Duration(seconds: 12);
    } catch (_) {}
    _client = created;
    return created;
  }

  /// Closes any pooled idle HTTP connections (e.g. in test teardowns). Subsequent probes lazily reopen a client.
  void close({bool force = true}) {
    final c = _client;
    _client = null;
    c?.close(force: force);
  }

  static VideoDimensions? _validDims(int width, int height) {
    if (width < 16 || height < 16 || width > 16384 || height > 16384) return null;
    return (width: width, height: height);
  }

  static String _cacheKey(String rawUrl) => rawUrl.trim();

  VideoDimensions? cached(String rawUrl) {
    final key = _cacheKey(rawUrl);
    if (key.isEmpty) return null;
    final hit = _cache.remove(key);
    if (hit != null) {
      _cache[key] = hit;
      return hit;
    }
    final clean = normalizeUrlAndHeaders(key).url;
    if (clean != key && clean.isNotEmpty) {
      final cleanHit = _cache.remove(clean);
      if (cleanHit != null) {
        _cache[clean] = cleanHit;
        return cleanHit;
      }
    }
    return null;
  }

  void remember(String rawUrl, VideoDimensions dims) {
    final key = _cacheKey(rawUrl);
    if (key.isEmpty || _validDims(dims.width, dims.height) == null) return;
    void put(String k) {
      if (k.isEmpty) return;
      _cache.remove(k);
      _cache[k] = dims;
      while (_cache.length > maxCacheEntries) {
        _cache.remove(_cache.keys.first);
      }
    }

    put(key);
    final clean = normalizeUrlAndHeaders(key).url;
    if (clean != key) put(clean);
  }

  /// Known display dimensions for one specific VOD / media item (`siteKey|vodId` or `emby|accountId|itemId`),
  /// never keyed by bare site.
  VideoDimensions? cachedVod(String? memoryKey) {
    final key = memoryKey?.trim() ?? '';
    if (key.isEmpty) return null;
    final hit = _vodCache.remove(key);
    if (hit != null) _vodCache[key] = hit;
    return hit;
  }

  void rememberVod(String? memoryKey, VideoDimensions dims) {
    final key = memoryKey?.trim() ?? '';
    if (key.isEmpty || _validDims(dims.width, dims.height) == null) return;
    _vodCache.remove(key);
    _vodCache[key] = dims;
    while (_vodCache.length > maxCacheEntries) {
      _vodCache.remove(_vodCache.keys.first);
    }
  }

  /// True when [rawUrl] is already a direct playable media URL (not an opaque spider episode id or loopback proxy)
  /// whose container/playlist header can be safely peeked while the detail screen is visible.
  static bool isDirectWarmupCandidate(String rawUrl) {
    final clean = normalizeUrlAndHeaders(rawUrl).url;
    if (clean.isEmpty) return false;
    final uri = Uri.tryParse(clean);
    if (uri == null) return false;
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'file') return true;
    if (scheme != 'http' && scheme != 'https') return false;
    if (_isLoopbackHost(uri.host.toLowerCase())) return false;
    final path = uri.path.toLowerCase();
    final slash = path.lastIndexOf('/');
    final tail = slash >= 0 ? path.substring(slash + 1) : path;
    final dot = tail.lastIndexOf('.');
    if (dot < 0) return false;
    final ext = tail.substring(dot + 1);
    return _directMediaExtensions.contains(ext);
  }

  void warmUpIfDirectMediaUrl(String rawUrl, {Map<String, String> headers = const {}}) {
    if (!isDirectWarmupCandidate(rawUrl) || cached(rawUrl) != null) return;
    unawaited(probe(rawUrl, headers: headers, timeout: const Duration(milliseconds: 1500)));
  }

  static bool shouldSkipProbe(String rawUrl) {
    final clean = normalizeUrlAndHeaders(rawUrl).url;
    if (clean.isEmpty) return true;
    if (clean.contains('/uzv-iso/')) return true;
    final uri = Uri.tryParse(clean);
    if (uri == null) return true;
    final scheme = uri.scheme.toLowerCase();
    if (scheme.isNotEmpty && scheme != 'http' && scheme != 'https' && scheme != 'file') return true;
    final cleanPath = clean.split('#').first.split('?').first.toLowerCase();
    final slash = cleanPath.lastIndexOf('/');
    final tail = slash >= 0 ? cleanPath.substring(slash + 1) : cleanPath;
    final dot = tail.lastIndexOf('.');
    if (dot >= 0 && _skipProbeExtensions.contains(tail.substring(dot + 1))) return true;
    return false;
  }

  static String _inflightKey(String cleanUrl, Map<String, String> headers) {
    if (headers.isEmpty) return cleanUrl;
    final entries = headers.entries
        .map((e) => MapEntry(e.key.trim().toLowerCase(), e.value.trim()))
        .where((e) => e.key.isNotEmpty && e.value.isNotEmpty)
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    if (entries.isEmpty) return cleanUrl;
    final buf = StringBuffer(cleanUrl);
    for (final e in entries) {
      buf
        ..write('\x00')
        ..write(e.key)
        ..write('=')
        ..write(e.value);
    }
    return buf.toString();
  }

  Future<VideoDimensions?> probe(
    String rawUrl, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(milliseconds: 1200),
  }) async {
    final trimmed = rawUrl.trim();
    if (shouldSkipProbe(trimmed)) return null;
    final hit = cached(trimmed);
    if (hit != null) return hit;

    final normalized = normalizeUrlAndHeaders(trimmed, headers);
    final inflightKey = _inflightKey(normalized.url, normalized.headers);
    final existing = _inflight[inflightKey];
    if (existing != null) {
      return existing.timeout(timeout, onTimeout: () => null);
    }

    final future = _runProbe(normalized.url, normalized.headers).then((dims) {
      if (dims != null) remember(trimmed, dims);
      return dims;
    }).catchError((Object _) => null).whenComplete(() {
      _inflight.remove(inflightKey);
    });
    _inflight[inflightKey] = future;
    return future.timeout(timeout, onTimeout: () => null);
  }

  Future<VideoDimensions?> _runProbe(String url, Map<String, String> headers) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    if (uri.scheme.isEmpty || uri.scheme.toLowerCase() == 'file') {
      final path = uri.scheme.isEmpty ? url : uri.toFilePath();
      return _probeLocalFile(path, depth: 0);
    }
    if (_inFlutterTest && !_hasCustomClientFactory && !_isLoopbackHost(uri.host.toLowerCase())) {
      return null;
    }
    return _probeHttp(uri, headers, depth: 0);
  }

  Future<VideoDimensions?> _probeLocalFile(
    String path, {
    required int depth,
    int startOffset = 0,
    int? maxBytes,
  }) async {
    if (depth > 2) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    final raf = await file.open();
    Uint8List head;
    int total;
    try {
      total = await raf.length();
      if (total <= 0 || startOffset >= total) return null;
      if (startOffset > 0) await raf.setPosition(startOffset);
      final readLen = math.min(total - startOffset, maxBytes ?? _initialRangeBytes);
      head = await raf.read(readLen);
      if (startOffset > 0 || !_startsWithAscii(head, '#EXTM3U', skipBomAndSpace: true)) {
        if (startOffset == 0) {
          final textDims = _tryParseTextManifest(head);
          if (textDims != null) return textDims;
        }
        var parsed = parseContainerBytes(head, totalFileBytes: total, baseOffset: startOffset);
        if (parsed.dimensions != null) return parsed.dimensions;
        var curStart = startOffset;
        var moovOffset = parsed.deferredMoovOffset;
        for (var hop = 0; hop < 4 && moovOffset != null && moovOffset > curStart && moovOffset < total; hop++) {
          curStart = moovOffset;
          await raf.setPosition(curStart);
          final slice = await raf.read(math.min(total - curStart, _tailMoovRangeBytes));
          parsed = parseContainerBytes(slice, totalFileBytes: total, baseOffset: curStart);
          if (parsed.dimensions != null) return parsed.dimensions;
          moovOffset = parsed.deferredMoovOffset;
        }
        return null;
      }
    } finally {
      await raf.close();
    }
    return _probeHlsManifest(
      file.uri,
      utf8.decode(head, allowMalformed: true),
      const {},
      depth: depth,
    );
  }

  Future<VideoDimensions?> _probeResolvedUri(
    Uri target,
    Map<String, String> headers, {
    required int depth,
    int start = 0,
    int maxBytes = _initialRangeBytes,
    bool explicitByteRange = false,
  }) async {
    final scheme = target.scheme.toLowerCase();
    if (scheme == 'file' || scheme.isEmpty) {
      final path = scheme.isEmpty ? target.path : target.toFilePath();
      return _probeLocalFile(path, depth: depth, startOffset: start, maxBytes: maxBytes);
    }
    if (start > 0 || explicitByteRange || maxBytes != _initialRangeBytes) {
      final slice = await _fetchSlice(
        target,
        headers,
        start: start,
        maxBytes: maxBytes,
        explicitByteRange: true,
      );
      if (slice == null) return null;
      if (slice.earlyDimensions != null) return slice.earlyDimensions;
      if (slice.bytes.isEmpty) return null;
      return parseContainerBytes(slice.bytes, totalFileBytes: slice.totalBytes, baseOffset: start).dimensions;
    }
    return _probeHttp(target, headers, depth: depth);
  }

  static bool _hasEncryptedHlsSegments(List<String> lines) {
    for (final raw in lines) {
      final line = raw.trim();
      if (!line.startsWith('#EXT-X-KEY:')) continue;
      final m = RegExp(r'METHOD="?([A-Za-z0-9_-]+)"?', caseSensitive: false).firstMatch(line);
      final method = m?.group(1)?.toUpperCase() ?? '';
      if (method.isNotEmpty && method != 'NONE') return true;
    }
    return false;
  }

  Future<VideoDimensions?> _probeHttp(Uri uri, Map<String, String> headers, {required int depth}) async {
    if (depth > 2) return null;
    final slice = await _fetchSlice(uri, headers, start: 0, maxBytes: _initialRangeBytes);
    if (slice == null) return null;
    if (slice.earlyDimensions != null) return slice.earlyDimensions;
    if (slice.bytes.isEmpty) return null;

    if (_looksLikeHls(uri, slice.contentType, slice.bytes)) {
      return _probeHlsManifest(slice.finalUri, utf8.decode(slice.bytes, allowMalformed: true), headers, depth: depth);
    }
    if (_looksLikeDash(uri, slice.contentType, slice.bytes)) {
      return parseDashMpd(utf8.decode(slice.bytes, allowMalformed: true));
    }

    var parsed = slice.earlyDeferredMoovOffset != null
        ? (dimensions: null, deferredMoovOffset: slice.earlyDeferredMoovOffset)
        : parseContainerBytes(slice.bytes, totalFileBytes: slice.totalBytes, baseOffset: 0);
    if (parsed.dimensions != null) return parsed.dimensions;

    var curStart = 0;
    var moovOffset = parsed.deferredMoovOffset;
    final total = slice.totalBytes;
    if (total != null && slice.statusCode == HttpStatus.partialContent) {
      for (var hop = 0; hop < 4 && moovOffset != null && moovOffset > curStart && moovOffset < total; hop++) {
        curStart = moovOffset;
        final nextSlice = await _fetchSlice(
          slice.finalUri,
          headers,
          start: curStart,
          maxBytes: math.min(total - curStart, _tailMoovRangeBytes),
          explicitByteRange: true,
        );
        if (nextSlice == null) break;
        if (nextSlice.earlyDimensions != null) return nextSlice.earlyDimensions;
        if (nextSlice.bytes.isEmpty) break;
        parsed = nextSlice.earlyDeferredMoovOffset != null
            ? (dimensions: null, deferredMoovOffset: nextSlice.earlyDeferredMoovOffset)
            : parseContainerBytes(nextSlice.bytes, totalFileBytes: total, baseOffset: curStart);
        if (parsed.dimensions != null) return parsed.dimensions;
        moovOffset = parsed.deferredMoovOffset;
      }
    }
    return null;
  }

  Future<VideoDimensions?> _probeHlsManifest(
    Uri baseUri,
    String text,
    Map<String, String> headers, {
    required int depth,
  }) async {
    final direct = parseHlsMasterResolution(text);
    if (direct != null) return direct;

    final lines = const LineSplitter().convert(text);
    // Variant playlist without RESOLUTION attribute: follow the first variant .m3u8.
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        for (var j = i + 1; j < lines.length; j++) {
          final next = lines[j].trim();
          if (next.isEmpty || next.startsWith('#')) continue;
          return _probeResolvedUri(baseUri.resolve(next), headers, depth: depth + 1);
        }
      }
    }

    // fMP4 HLS init segment: #EXT-X-MAP:URI="init.mp4"[,BYTERANGE="len[@offset]"]
    for (final raw in lines) {
      final line = raw.trim();
      if (!line.startsWith('#EXT-X-MAP:')) continue;
      final uriMatch = RegExp(r'URI="([^"]+)"', caseSensitive: false).firstMatch(line);
      if (uriMatch == null) continue;
      final mapUri = baseUri.resolve(uriMatch.group(1)!);
      var start = 0;
      var len = _initialRangeBytes;
      final rangeMatch = RegExp(r'BYTERANGE="(\d+)(?:@(\d+))?"', caseSensitive: false).firstMatch(line);
      if (rangeMatch != null) {
        len = math.min(int.tryParse(rangeMatch.group(1)!) ?? _initialRangeBytes, _tailMoovRangeBytes);
        start = int.tryParse(rangeMatch.group(2) ?? '0') ?? 0;
      }
      final dims = await _probeResolvedUri(
        mapUri,
        headers,
        depth: depth + 1,
        start: start,
        maxBytes: len,
        explicitByteRange: rangeMatch != null,
      );
      if (dims != null) return dims;
      break;
    }

    // Encrypted TS segments cannot be parsed without decrypting; skip wasted segment fetch and let decoder report size.
    if (_hasEncryptedHlsSegments(lines)) return null;

    // Standard TS / fMP4 media playlist: inspect the first segment.
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final segUri = baseUri.resolve(line);
      return _probeResolvedUri(segUri, headers, depth: depth + 1);
    }
    return null;
  }

  static bool _isManifestUri(Uri uri) {
    final p = uri.path.toLowerCase();
    return p.endsWith('.m3u8') || p.endsWith('.m3u') || p.endsWith('.mpd');
  }

  /// True when a streaming `.m3u8` media playlist (no `#EXT-X-STREAM-INF`) already contains its first complete media
  /// segment line (after any `#EXT-X-MAP` / `#EXT-X-KEY` headers), so multi-hundred-KB VOD playlists stop early.
  static bool _canStopHlsMediaPlaylistEarly(Uint8List bytes) {
    if (!_startsWithAscii(bytes, '#EXTM3U', skipBomAndSpace: true)) return false;
    final text = utf8.decode(bytes, allowMalformed: true);
    final lastNl = text.lastIndexOf('\n');
    if (lastNl <= 0) return false;
    final completeText = text.substring(0, lastNl);
    if (completeText.toUpperCase().contains('#EXT-X-STREAM-INF:')) return false;
    for (final raw in const LineSplitter().convert(completeText)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (!line.startsWith('#')) return true;
    }
    return false;
  }

  static bool _isPresignedStorageUri(Uri uri) {
    final q = uri.query.toLowerCase();
    return q.contains('x-amz-signature=') ||
        q.contains('x-oss-signature=') ||
        q.contains('ossaccesskeyid=') ||
        q.contains('q-signature=') ||
        (q.contains('sig=') && q.contains('se='));
  }

  static String _registrableDomain(String host) {
    final h = host.trim().toLowerCase();
    if (h.isEmpty || _isLoopbackHost(h) || InternetAddress.tryParse(h) != null) return h;
    final parts = h.split('.');
    if (parts.length <= 2) return h;
    final last2 = '${parts[parts.length - 2]}.${parts.last}';
    const multiPartTlds = {
      'com.cn',
      'net.cn',
      'org.cn',
      'gov.cn',
      'com.hk',
      'com.tw',
      'co.jp',
      'co.uk',
      'co.kr',
      'com.au',
    };
    if (multiPartTlds.contains(last2) && parts.length >= 3) {
      return '${parts[parts.length - 3]}.$last2';
    }
    return last2;
  }

  static Map<String, String> _sanitizeHeadersForRedirect(
    Uri fromUri,
    Uri toUri,
    Map<String, String> headers,
  ) {
    if (headers.isEmpty) return headers;
    final crossDomain = _registrableDomain(fromUri.host) != _registrableDomain(toUri.host) ||
        (fromUri.scheme.toLowerCase() == 'https' && toUri.scheme.toLowerCase() == 'http');
    final presigned = _isPresignedStorageUri(toUri);
    if (!crossDomain && !presigned) return headers;
    final next = <String, String>{};
    headers.forEach((k, v) {
      final lower = k.trim().toLowerCase();
      if (crossDomain && (lower == 'authorization' || lower == 'cookie' || lower == 'origin')) {
        return;
      }
      if (presigned && lower == 'authorization') {
        return;
      }
      next[k] = v;
    });
    return next;
  }

  Future<_FetchedSlice?> _fetchSlice(
    Uri uri,
    Map<String, String> headers, {
    required int start,
    required int maxBytes,
    bool explicitByteRange = false,
    bool omitRangeRetry = false,
    int redirectHops = 0,
  }) async {
    if (maxBytes <= 0) return null;
    final isManifest = start == 0 && !explicitByteRange && _isManifestUri(uri);
    final effectiveMaxBytes = isManifest ? math.max(maxBytes, _manifestMaxBytes) : maxBytes;
    final sendRange = !isManifest && !omitRangeRetry;

    final client = _obtainClient();
    HttpClientRequest? req;
    StreamSubscription<List<int>>? sub;
    try {
      req = await client.getUrl(uri).timeout(sliceTimeout);
      req.followRedirects = false;
      var hasUa = false;
      headers.forEach((k, v) {
        final lower = k.trim().toLowerCase();
        if (lower.isEmpty || lower == 'range' || lower == 'host' || lower == 'accept-encoding') return;
        if (lower == 'user-agent') hasUa = true;
        req!.headers.set(k.trim(), v);
      });
      if (!hasUa) {
        req.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36');
      }
      if (sendRange) {
        final end = start + effectiveMaxBytes - 1;
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
      }

      final res = await req.close().timeout(sliceTimeout);
      if (res.statusCode == HttpStatus.movedPermanently ||
          res.statusCode == HttpStatus.found ||
          res.statusCode == HttpStatus.seeOther ||
          res.statusCode == HttpStatus.temporaryRedirect ||
          res.statusCode == HttpStatus.permanentRedirect) {
        final location = res.headers.value(HttpHeaders.locationHeader)?.trim() ?? '';
        await res.drain<void>().timeout(sliceTimeout).catchError((Object _) {});
        if (location.isEmpty || redirectHops >= 5) return null;
        final nextUri = uri.resolve(location);
        final nextHeaders = _sanitizeHeadersForRedirect(uri, nextUri, headers);
        return await _fetchSlice(
          nextUri,
          nextHeaders,
          start: start,
          maxBytes: maxBytes,
          explicitByteRange: explicitByteRange,
          omitRangeRetry: omitRangeRetry,
          redirectHops: redirectHops + 1,
        );
      }
      if ((res.statusCode == HttpStatus.requestedRangeNotSatisfiable ||
              res.statusCode == HttpStatus.badRequest ||
              res.statusCode == HttpStatus.forbidden ||
              res.statusCode == HttpStatus.notImplemented) &&
          sendRange &&
          start == 0 &&
          !explicitByteRange) {
        await res.drain<void>().timeout(sliceTimeout).catchError((Object _) {});
        return await _fetchSlice(
          uri,
          headers,
          start: 0,
          maxBytes: maxBytes,
          omitRangeRetry: true,
          redirectHops: redirectHops,
        );
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        await res.drain<void>().timeout(sliceTimeout).catchError((Object _) {});
        return null;
      }

      final totalBytes = _parseTotalBytes(res, start);
      final contentType = res.headers.contentType?.mimeType.toLowerCase() ?? '';
      final isMpegUrlContent = start == 0 && !explicitByteRange && contentType.contains('mpegurl');
      final streamCapBytes = (isManifest || isMpegUrlContent) ? math.max(effectiveMaxBytes, _manifestMaxBytes) : effectiveMaxBytes;
      final builder = BytesBuilder(copy: false);
      final done = Completer<void>();
      VideoDimensions? earlyDimensions;
      int? earlyDeferredMoovOffset;
      var lastIncrementalCheck = 0;

      sub = res.listen(
        (chunk) {
          if (done.isCompleted) return;
          final remaining = streamCapBytes - builder.length;
          if (remaining <= 0) return;
          if (chunk.length <= remaining) {
            builder.add(chunk);
          } else {
            builder.add(chunk.sublist(0, remaining));
          }
          if (builder.length >= streamCapBytes) {
            done.complete();
            unawaited(sub?.cancel().catchError((Object _) {}) ?? Future<void>.value());
            return;
          }

          // Early exit for huge HLS VOD media playlists (> 16 KB or chunked) once first segment is complete;
          // let <= 16 KB playlists finish naturally so their keep-alive socket stays pooled for the segment fetch.
          if ((isManifest || isMpegUrlContent || builder.length >= 4096) &&
              (res.contentLength < 0 ? builder.length >= 4096 : res.contentLength > 16384)) {
            if (_canStopHlsMediaPlaylistEarly(builder.toBytes())) {
              done.complete();
              unawaited(sub?.cancel().catchError((Object _) {}) ?? Future<void>.value());
              return;
            }
          }

          // Incremental early exit for binary streams (.ts / .mp4 / .mkv / .flv): return as soon as dimensions are known
          // without waiting for the rest of the 64 KB Range window.
          if (!isManifest &&
              !isMpegUrlContent &&
              !contentType.contains('dash+xml') &&
              builder.length >= 188 &&
              (builder.length - lastIncrementalCheck >= 512 || builder.length <= 2048)) {
            lastIncrementalCheck = builder.length;
            final snapshot = builder.toBytes();
            if (!_startsWithAscii(snapshot, '#EXTM3U', skipBomAndSpace: true) &&
                !_startsWithAscii(snapshot, '<?xml', skipBomAndSpace: true) &&
                !_startsWithAscii(snapshot, '<MPD', skipBomAndSpace: true)) {
              final inc = parseContainerBytes(
                snapshot,
                totalFileBytes: totalBytes,
                baseOffset: start,
                streamingPartial: true,
              );
              if (inc.dimensions != null) {
                earlyDimensions = inc.dimensions;
                done.complete();
                unawaited(sub?.cancel().catchError((Object _) {}) ?? Future<void>.value());
                return;
              }
              if (inc.deferredMoovOffset != null &&
                  res.statusCode == HttpStatus.partialContent &&
                  inc.deferredMoovOffset! > start + streamCapBytes) {
                earlyDeferredMoovOffset = inc.deferredMoovOffset;
                done.complete();
                unawaited(sub?.cancel().catchError((Object _) {}) ?? Future<void>.value());
                return;
              }
            }
          }
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object _) {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );
      await done.future.timeout(sliceTimeout);

      Uri finalUri = uri;
      for (final r in res.redirects) {
        finalUri = finalUri.resolveUri(r.location);
      }
      return _FetchedSlice(
        bytes: builder.takeBytes(),
        statusCode: res.statusCode,
        totalBytes: totalBytes,
        contentType: contentType,
        finalUri: finalUri,
        earlyDimensions: earlyDimensions,
        earlyDeferredMoovOffset: earlyDeferredMoovOffset,
      );
    } catch (_) {
      unawaited(sub?.cancel().catchError((Object _) {}) ?? Future<void>.value());
      try {
        req?.abort();
      } catch (_) {}
      return null;
    }
  }

  static int? _parseTotalBytes(HttpClientResponse res, int start) {
    final cr = res.headers.value(HttpHeaders.contentRangeHeader);
    if (cr != null) {
      final m = RegExp(r'bytes\s+\d+-\d+/(\d+)', caseSensitive: false).firstMatch(cr);
      if (m != null) return int.tryParse(m.group(1)!);
    }
    if (res.statusCode == 200 && start == 0 && res.contentLength > 0) {
      return res.contentLength;
    }
    return null;
  }

  static bool _looksLikeHls(Uri uri, String contentType, Uint8List bytes) {
    if (contentType.contains('mpegurl')) return true;
    final path = uri.path.toLowerCase();
    if (path.endsWith('.m3u8') || path.endsWith('.m3u')) {
      return _startsWithAscii(bytes, '#EXTM3U', skipBomAndSpace: true);
    }
    return _startsWithAscii(bytes, '#EXTM3U', skipBomAndSpace: true);
  }

  static bool _looksLikeDash(Uri uri, String contentType, Uint8List bytes) {
    if (contentType.contains('dash+xml')) return true;
    if (uri.path.toLowerCase().endsWith('.mpd')) return true;
    if (!_startsWithAscii(bytes, '<?xml', skipBomAndSpace: true) &&
        !_startsWithAscii(bytes, '<MPD', skipBomAndSpace: true)) {
      return false;
    }
    final head = utf8.decode(bytes.sublist(0, math.min(bytes.length, 1024)), allowMalformed: true);
    return head.contains('<MPD');
  }

  static VideoDimensions? _tryParseTextManifest(Uint8List bytes) {
    if (_startsWithAscii(bytes, '#EXTM3U', skipBomAndSpace: true)) {
      return parseHlsMasterResolution(utf8.decode(bytes, allowMalformed: true));
    }
    if (_startsWithAscii(bytes, '<?xml', skipBomAndSpace: true) ||
        _startsWithAscii(bytes, '<MPD', skipBomAndSpace: true)) {
      return parseDashMpd(utf8.decode(bytes, allowMalformed: true));
    }
    return null;
  }

  static bool _startsWithAscii(Uint8List bytes, String prefix, {bool skipBomAndSpace = false}) {
    var i = 0;
    if (skipBomAndSpace) {
      if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) i = 3;
      while (i < bytes.length && (bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A || bytes[i] == 0x0D)) {
        i++;
      }
    }
    if (i + prefix.length > bytes.length) return false;
    for (var j = 0; j < prefix.length; j++) {
      final a = bytes[i + j];
      final b = prefix.codeUnitAt(j);
      if (a != b && (a | 0x20) != (b | 0x20)) return false;
    }
    return true;
  }

  // -- Manifest parsers -------------------------------------------------------------------------

  /// Extracts the highest-pixel-count `#EXT-X-STREAM-INF` `RESOLUTION=WxH` from an HLS master playlist.
  static VideoDimensions? parseHlsMasterResolution(String playlist) {
    VideoDimensions? best;
    var bestArea = 0;
    final streamInfRe = RegExp(r'^#EXT-X-STREAM-INF:(.*)$', multiLine: true, caseSensitive: false);
    final resRe = RegExp(r'RESOLUTION="?(\d+)x(\d+)"?', caseSensitive: false);
    for (final m in streamInfRe.allMatches(playlist)) {
      final attrs = m.group(1) ?? '';
      final rm = resRe.firstMatch(attrs);
      if (rm == null) continue;
      final w = int.tryParse(rm.group(1)!) ?? 0;
      final h = int.tryParse(rm.group(2)!) ?? 0;
      final valid = _validDims(w, h);
      if (valid == null) continue;
      final area = valid.width * valid.height;
      if (area > bestArea) {
        bestArea = area;
        best = valid;
      }
    }
    return best;
  }

  /// Extracts the largest `<Representation ... width="W" height="H">` from a DASH MPD document.
  static VideoDimensions? parseDashMpd(String xml) {
    VideoDimensions? best;
    var bestArea = 0;
    final tagRe = RegExp(r'<Representation\b([^>]*)>', caseSensitive: false);
    final wRe = RegExp(r'\bwidth="(\d+)"', caseSensitive: false);
    final hRe = RegExp(r'\bheight="(\d+)"', caseSensitive: false);
    for (final m in tagRe.allMatches(xml)) {
      final attrs = m.group(1) ?? '';
      final wm = wRe.firstMatch(attrs);
      final hm = hRe.firstMatch(attrs);
      if (wm == null || hm == null) continue;
      final valid = _validDims(int.tryParse(wm.group(1)!) ?? 0, int.tryParse(hm.group(1)!) ?? 0);
      if (valid == null) continue;
      final area = valid.width * valid.height;
      if (area > bestArea) {
        bestArea = area;
        best = valid;
      }
    }
    return best;
  }

  // -- Binary container parsers -----------------------------------------------------------------

  static ({VideoDimensions? dimensions, int? deferredMoovOffset}) parseContainerBytes(
    Uint8List bytes, {
    int? totalFileBytes,
    int baseOffset = 0,
    bool streamingPartial = false,
  }) {
    if (bytes.length < 12) return (dimensions: null, deferredMoovOffset: null);

    // 1. EBML (Matroska / WebM): 1A 45 DF A3
    if (baseOffset == 0 && bytes[0] == 0x1A && bytes[1] == 0x45 && bytes[2] == 0xDF && bytes[3] == 0xA3) {
      return (dimensions: _parseEbmlMkv(bytes, streamingPartial: streamingPartial), deferredMoovOffset: null);
    }

    // 2. FLV: 'F' 'L' 'V' 0x01
    if (baseOffset == 0 && bytes[0] == 0x46 && bytes[1] == 0x4C && bytes[2] == 0x56 && bytes[3] == 0x01) {
      return (dimensions: _parseFlv(bytes, streamingPartial: streamingPartial), deferredMoovOffset: null);
    }

    // 3. ISO BMFF (MP4 / M4V / MOV / fMP4, including seeked moov/trak slices)
    if (_looksLikeIsoBmff(bytes)) {
      return _parseMp4(
        bytes,
        totalFileBytes: totalFileBytes,
        baseOffset: baseOffset,
        streamingPartial: streamingPartial,
      );
    }

    // 4. MPEG-TS / M2TS (including segments prefixed with fake PNG/GIF/BMP header bytes)
    if (baseOffset == 0) {
      final tsDims = _parseMpegTs(bytes, streamingPartial: streamingPartial);
      if (tsDims != null) return (dimensions: tsDims, deferredMoovOffset: null);
    }

    return (dimensions: null, deferredMoovOffset: null);
  }

  // -- MP4 / MOV --------------------------------------------------------------------------------

  static const _bmffTopBoxes = {
    'ftyp',
    'moov',
    'mdat',
    'free',
    'skip',
    'wide',
    'styp',
    'sidx',
    'moof',
    'uuid',
    'meta',
    'trak',
    'mvhd',
    'udta',
    'mvex',
    'edts',
  };

  static bool _looksLikeIsoBmff(Uint8List bytes) {
    if (bytes.length < 8) return false;
    final type = String.fromCharCodes(bytes.sublist(4, 8));
    return _bmffTopBoxes.contains(type);
  }

  static ({VideoDimensions? dimensions, int? deferredMoovOffset}) _parseMp4(
    Uint8List bytes, {
    int? totalFileBytes,
    int baseOffset = 0,
    bool streamingPartial = false,
  }) {
    final bd = ByteData.sublistView(bytes);
    final relativeTotal = totalFileBytes != null ? math.max(bytes.length, totalFileBytes - baseOffset) : bytes.length;
    var offset = 0;
    int? deferredRelativeOffset;
    var sawBmffStructure = baseOffset > 0;

    while (offset + 8 <= bytes.length) {
      final header = _readBmffHeader(bd, bytes, offset, relativeTotal);
      if (header == null) {
        if (sawBmffStructure && totalFileBytes != null && offset > 0 && baseOffset + offset < totalFileBytes) {
          deferredRelativeOffset ??= offset;
        }
        break;
      }
      if (header.type == 'ftyp' || header.type == 'mdat' || header.type == 'moov' || header.type == 'styp') {
        sawBmffStructure = true;
      }
      if (header.type == 'moov') {
        final clampedEnd = math.min(header.boxEnd, bytes.length);
        final moovRes = _parseMoovDetailed(
          bd,
          bytes,
          offset + header.headerSize,
          clampedEnd,
          moovBoxOffset: offset,
          moovBoxEnd: header.boxEnd,
          streamingPartial: streamingPartial,
        );
        if (moovRes.dims != null) return (dimensions: moovRes.dims, deferredMoovOffset: null);
        if (header.boxEnd > bytes.length && moovRes.nextOffset != null && moovRes.nextOffset! > 0) {
          if (totalFileBytes == null || baseOffset + moovRes.nextOffset! < totalFileBytes) {
            deferredRelativeOffset = moovRes.nextOffset;
          }
        }
      } else if (header.type == 'trak') {
        final clampedEnd = math.min(header.boxEnd, bytes.length);
        final track = _parseTrak(
          bd,
          bytes,
          offset + header.headerSize,
          clampedEnd,
          trakTruncated: header.boxEnd > bytes.length,
          streamingPartial: streamingPartial,
        );
        if (track.dims != null && (track.isVideo == true || (!streamingPartial && header.boxEnd <= bytes.length))) {
          return (dimensions: track.dims, deferredMoovOffset: null);
        }
        if (header.boxEnd > bytes.length) {
          if (track.isVideo == false) {
            deferredRelativeOffset = header.boxEnd;
          } else if (offset > 0) {
            deferredRelativeOffset = offset;
          }
        }
      } else if (header.type == 'mdat') {
        if (totalFileBytes != null && header.boxEnd > bytes.length && baseOffset + header.boxEnd < totalFileBytes) {
          deferredRelativeOffset = header.boxEnd;
        }
      } else if (baseOffset > 0 && header.boxEnd > bytes.length) {
        deferredRelativeOffset = header.boxEnd;
      }
      if (header.boxEnd <= offset || header.boxEnd > bytes.length) break;
      offset = header.boxEnd;
    }

    final absDeferred = (sawBmffStructure && deferredRelativeOffset != null && deferredRelativeOffset > 0)
        ? baseOffset + deferredRelativeOffset
        : null;
    return (dimensions: null, deferredMoovOffset: absDeferred);
  }

  static ({String type, int headerSize, int boxEnd})? _readBmffHeader(
    ByteData bd,
    Uint8List bytes,
    int offset,
    int fallbackEnd,
  ) {
    if (offset + 8 > bytes.length) return null;
    for (var i = 4; i < 8; i++) {
      final c = bytes[offset + i];
      if (c < 0x20 || c > 0x7E) return null;
    }
    final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
    final size32 = bd.getUint32(offset);
    if (size32 == 1) {
      if (offset + 16 > bytes.length) return null;
      final hi = bd.getUint32(offset + 8);
      final lo = bd.getUint32(offset + 12);
      final size64 = (hi * 0x100000000) + lo;
      if (size64 < 16) return null;
      return (type: type, headerSize: 16, boxEnd: offset + size64);
    }
    if (size32 == 0) {
      return (type: type, headerSize: 8, boxEnd: math.max(offset + 8, fallbackEnd));
    }
    if (size32 < 8) return null;
    return (type: type, headerSize: 8, boxEnd: offset + size32);
  }

  static ({VideoDimensions? dims, int? nextOffset}) _parseMoovDetailed(
    ByteData bd,
    Uint8List bytes,
    int start,
    int end, {
    required int moovBoxOffset,
    required int moovBoxEnd,
    required bool streamingPartial,
  }) {
    if (start + 8 > end) {
      return (dims: null, nextOffset: moovBoxEnd > end && moovBoxOffset > 0 ? moovBoxOffset : null);
    }
    var pos = start;
    VideoDimensions? fallbackCandidate;
    int? nextOffset;
    while (pos + 8 <= end) {
      final h = _readBmffHeader(bd, bytes, pos, moovBoxEnd);
      if (h == null) {
        if (moovBoxEnd > end && pos > 0) nextOffset = pos;
        break;
      }
      final childEnd = math.min(h.boxEnd, end);
      final childTruncated = h.boxEnd > end;
      if (h.type == 'trak') {
        final track = _parseTrak(
          bd,
          bytes,
          pos + h.headerSize,
          childEnd,
          trakTruncated: childTruncated,
          streamingPartial: streamingPartial,
        );
        if (track.dims != null) {
          if (track.isVideo == true) return (dims: track.dims, nextOffset: null);
          if (!streamingPartial && !childTruncated) fallbackCandidate ??= track.dims;
        }
        if (childTruncated) {
          if (track.isVideo == false && h.boxEnd < moovBoxEnd) {
            nextOffset = h.boxEnd;
          } else if (pos > 0) {
            nextOffset = pos;
          }
        }
      } else if (childTruncated && h.boxEnd < moovBoxEnd) {
        nextOffset = h.boxEnd;
      }
      if (h.boxEnd <= pos || childTruncated) break;
      pos = h.boxEnd;
    }
    if (fallbackCandidate != null) return (dims: fallbackCandidate, nextOffset: null);
    if (nextOffset == null && moovBoxEnd > end && pos < moovBoxEnd && pos > 0) {
      nextOffset = pos;
    }
    return (dims: null, nextOffset: nextOffset);
  }

  static ({VideoDimensions? dims, bool? isVideo}) _parseTrak(
    ByteData bd,
    Uint8List bytes,
    int start,
    int end, {
    bool trakTruncated = false,
    bool streamingPartial = false,
  }) {
    int tkhdW = 0;
    int tkhdH = 0;
    bool sawTkhd = false;
    bool rotated90 = false;
    bool? isVideoHandler;
    VideoDimensions? stsdDims;

    var pos = start;
    while (pos + 8 <= end) {
      final h = _readBmffHeader(bd, bytes, pos, end);
      if (h == null) break;
      final bodyStart = pos + h.headerSize;
      final childEnd = math.min(h.boxEnd, end);
      if (h.type == 'tkhd') {
        final tkhd = _parseTkhd(bd, bodyStart, childEnd);
        if (tkhd != null) {
          sawTkhd = true;
          tkhdW = tkhd.width;
          tkhdH = tkhd.height;
          rotated90 = tkhd.rotated90;
        }
      } else if (h.type == 'mdia') {
        final mdia = _parseMdia(bd, bytes, bodyStart, childEnd);
        isVideoHandler = mdia.isVideo;
        stsdDims = mdia.stsdDims;
      }
      if (h.boxEnd <= pos || h.boxEnd > end) break;
      pos = h.boxEnd;
    }

    if (isVideoHandler == false) return (dims: null, isVideo: false);
    if (streamingPartial) {
      // Wait until both tkhd (for rotation + presentation size) and hdlr=='vide' are read, unless the trak is complete.
      final readyInStream = !trakTruncated || (isVideoHandler == true && sawTkhd);
      if (!readyInStream) return (dims: null, isVideo: isVideoHandler);
    }
    var w = stsdDims?.width ?? tkhdW;
    var ht = stsdDims?.height ?? tkhdH;
    // tkhd carries the presentation width after clean-aperture / pixel aspect scaling when non-zero.
    if (tkhdW > 0 && tkhdH > 0) {
      w = tkhdW;
      ht = tkhdH;
    }
    if (rotated90) {
      final tmp = w;
      w = ht;
      ht = tmp;
    }
    final valid = _validDims(w, ht);
    if (valid == null) return (dims: null, isVideo: isVideoHandler);
    final confirmedVideo = isVideoHandler ?? (!streamingPartial && !trakTruncated);
    return (dims: valid, isVideo: confirmedVideo);
  }

  static ({int width, int height, bool rotated90})? _parseTkhd(ByteData bd, int start, int end) {
    if (start + 4 > end) return null;
    final version = bd.getUint8(start);
    final matrixOffset = start + (version == 1 ? 52 : 40);
    final widthOffset = matrixOffset + 36;
    if (widthOffset + 8 > end) return null;
    final a = bd.getInt32(matrixOffset);
    final b = bd.getInt32(matrixOffset + 4);
    final c = bd.getInt32(matrixOffset + 12);
    final d = bd.getInt32(matrixOffset + 16);
    final rotated90 = a.abs() < b.abs() && d.abs() < c.abs();
    final w = (bd.getUint32(widthOffset) / 65536.0).round();
    final h = (bd.getUint32(widthOffset + 4) / 65536.0).round();
    return (width: w, height: h, rotated90: rotated90);
  }

  static ({bool? isVideo, VideoDimensions? stsdDims}) _parseMdia(ByteData bd, Uint8List bytes, int start, int end) {
    bool? isVideo;
    VideoDimensions? stsdDims;
    var pos = start;
    while (pos + 8 <= end) {
      final h = _readBmffHeader(bd, bytes, pos, end);
      if (h == null) break;
      final bodyStart = pos + h.headerSize;
      final childEnd = math.min(h.boxEnd, end);
      if (h.type == 'hdlr' && bodyStart + 12 <= childEnd) {
        final handler = String.fromCharCodes(bytes.sublist(bodyStart + 8, bodyStart + 12));
        isVideo = handler == 'vide';
      } else if (h.type == 'minf') {
        stsdDims ??= _parseMinf(bd, bytes, bodyStart, childEnd);
      }
      if (h.boxEnd <= pos || h.boxEnd > end) break;
      pos = h.boxEnd;
    }
    return (isVideo: isVideo, stsdDims: stsdDims);
  }

  static VideoDimensions? _parseMinf(ByteData bd, Uint8List bytes, int start, int end) {
    var pos = start;
    while (pos + 8 <= end) {
      final h = _readBmffHeader(bd, bytes, pos, end);
      if (h == null) break;
      final childEnd = math.min(h.boxEnd, end);
      if (h.type == 'stbl') {
        final d = _parseStbl(bd, bytes, pos + h.headerSize, childEnd);
        if (d != null) return d;
      }
      if (h.boxEnd <= pos || h.boxEnd > end) break;
      pos = h.boxEnd;
    }
    return null;
  }

  static VideoDimensions? _parseStbl(ByteData bd, Uint8List bytes, int start, int end) {
    var pos = start;
    while (pos + 8 <= end) {
      final h = _readBmffHeader(bd, bytes, pos, end);
      if (h == null) break;
      final childEnd = math.min(h.boxEnd, end);
      if (h.type == 'stsd') {
        return _parseStsd(bd, bytes, pos + h.headerSize, childEnd);
      }
      if (h.boxEnd <= pos || h.boxEnd > end) break;
      pos = h.boxEnd;
    }
    return null;
  }

  static const _visualSampleEntries = {'avc1', 'avc3', 'hvc1', 'hev1', 'vp08', 'vp09', 'av01', 'mp4v', 'encv', 'dvhe', 'dvh1'};

  static VideoDimensions? _parseStsd(ByteData bd, Uint8List bytes, int start, int end) {
    if (start + 8 > end) return null;
    final entryCount = bd.getUint32(start + 4);
    var pos = start + 8;
    for (var i = 0; i < entryCount && pos + 8 <= end; i++) {
      final h = _readBmffHeader(bd, bytes, pos, end);
      if (h == null) break;
      final body = pos + h.headerSize;
      final entryEnd = math.min(h.boxEnd, end);
      if (_visualSampleEntries.contains(h.type) && body + 78 <= entryEnd) {
        var w = bd.getUint16(body + 24);
        final ht = bd.getUint16(body + 26);
        var subPos = body + 78;
        VideoDimensions? codecDims;
        int? paspH;
        int? paspV;
        while (subPos + 8 <= entryEnd) {
          final sh = _readBmffHeader(bd, bytes, subPos, entryEnd);
          if (sh == null) break;
          final sBody = subPos + sh.headerSize;
          final sEnd = math.min(sh.boxEnd, entryEnd);
          if (sh.type == 'pasp' && sBody + 8 <= sEnd) {
            paspH = bd.getUint32(sBody);
            paspV = bd.getUint32(sBody + 4);
          } else if (sh.type == 'avcC') {
            codecDims ??= _parseAvcDecoderConfigRecord(bytes, sBody, sEnd);
          } else if (sh.type == 'hvcC') {
            codecDims ??= _parseHevcDecoderConfigRecord(bytes, sBody, sEnd);
          }
          if (sh.boxEnd <= subPos || sh.boxEnd > entryEnd) break;
          subPos = sh.boxEnd;
        }
        if ((w <= 0 || ht <= 0) && codecDims != null) return codecDims;
        if (paspH != null && paspV != null && paspH > 0 && paspV > 0 && paspH != paspV) {
          w = (w * paspH / paspV).round();
        }
        final valid = _validDims(w, ht);
        if (valid != null) return valid;
      }
      if (h.boxEnd <= pos || h.boxEnd > end) break;
      pos = h.boxEnd;
    }
    return null;
  }

  // -- Matroska / WebM (EBML) -------------------------------------------------------------------

  static VideoDimensions? _parseEbmlMkv(Uint8List bytes, {bool streamingPartial = false}) {
    // Skip EBML header element (0x1A45DFA3) to reach Segment (0x18538067).
    final head = _readEbmlElement(bytes, 0, bytes.length);
    if (head == null) return null;
    var pos = head.dataEnd;
    while (pos < bytes.length) {
      final el = _readEbmlElement(bytes, pos, bytes.length);
      if (el == null) break;
      if (el.id == 0x18538067) {
        return _parseMkvSegment(
          bytes,
          el.dataStart,
          math.min(el.dataEnd, bytes.length),
          streamingPartial: streamingPartial,
        );
      }
      if (el.dataEnd <= pos) break;
      pos = el.dataEnd;
    }
    return null;
  }

  static VideoDimensions? _parseMkvSegment(Uint8List bytes, int start, int end, {bool streamingPartial = false}) {
    var pos = start;
    while (pos < end) {
      final el = _readEbmlElement(bytes, pos, end);
      if (el == null) break;
      if (el.id == 0x1654AE6B) {
        return _parseMkvTracks(bytes, el.dataStart, math.min(el.dataEnd, end), streamingPartial: streamingPartial);
      }
      if (el.dataEnd <= pos) break;
      pos = el.dataEnd;
    }
    return null;
  }

  static VideoDimensions? _parseMkvTracks(Uint8List bytes, int start, int end, {bool streamingPartial = false}) {
    var pos = start;
    while (pos < end) {
      final el = _readEbmlElement(bytes, pos, end);
      if (el == null) break;
      if (el.id == 0xAE) {
        final d = _parseMkvTrackEntry(
          bytes,
          el.dataStart,
          math.min(el.dataEnd, end),
          entryTruncated: el.dataEnd > end,
          streamingPartial: streamingPartial,
        );
        if (d != null) return d;
      }
      if (el.dataEnd <= pos) break;
      pos = el.dataEnd;
    }
    return null;
  }

  static VideoDimensions? _parseMkvTrackEntry(
    Uint8List bytes,
    int start,
    int end, {
    bool entryTruncated = false,
    bool streamingPartial = false,
  }) {
    int? trackType;
    VideoDimensions? videoDims;
    bool videoElementComplete = false;
    var pos = start;
    while (pos < end) {
      final el = _readEbmlElement(bytes, pos, end);
      if (el == null) break;
      final cEnd = math.min(el.dataEnd, end);
      if (el.id == 0x83) {
        trackType = _readEbmlUint(bytes, el.dataStart, cEnd);
      } else if (el.id == 0xE0) {
        videoElementComplete = el.dataEnd <= end;
        videoDims = _parseMkvVideo(bytes, el.dataStart, cEnd);
      }
      if (el.dataEnd <= pos) break;
      pos = el.dataEnd;
    }
    if (trackType != null && trackType != 1) return null;
    if (streamingPartial && ( !videoElementComplete || (trackType == null && entryTruncated))) return null;
    return videoDims;
  }

  static VideoDimensions? _parseMkvVideo(Uint8List bytes, int start, int end) {
    int pixelW = 0;
    int pixelH = 0;
    int displayW = 0;
    int displayH = 0;
    int displayUnit = 0;
    var pos = start;
    while (pos < end) {
      final el = _readEbmlElement(bytes, pos, end);
      if (el == null) break;
      final cEnd = math.min(el.dataEnd, end);
      switch (el.id) {
        case 0xB0:
          pixelW = _readEbmlUint(bytes, el.dataStart, cEnd);
        case 0xBA:
          pixelH = _readEbmlUint(bytes, el.dataStart, cEnd);
        case 0x54B0:
          displayW = _readEbmlUint(bytes, el.dataStart, cEnd);
        case 0x54BA:
          displayH = _readEbmlUint(bytes, el.dataStart, cEnd);
        case 0x54B2:
          displayUnit = _readEbmlUint(bytes, el.dataStart, cEnd);
      }
      if (el.dataEnd <= pos) break;
      pos = el.dataEnd;
    }
    if (displayUnit == 0 && displayW > 0 && displayH > 0) {
      return _validDims(displayW, displayH) ?? _validDims(pixelW, pixelH);
    }
    if (displayUnit == 3 && displayW > 0 && displayH > 0 && pixelH > 0) {
      return _validDims((pixelH * displayW / displayH).round(), pixelH) ?? _validDims(pixelW, pixelH);
    }
    return _validDims(pixelW, pixelH);
  }

  static ({int id, int dataStart, int dataEnd})? _readEbmlElement(Uint8List bytes, int pos, int limit) {
    if (pos >= limit) return null;
    final idVint = _readVint(bytes, pos, limit, keepMarkerBit: true);
    if (idVint == null) return null;
    final sizeVint = _readVint(bytes, idVint.nextPos, limit, keepMarkerBit: false);
    if (sizeVint == null) return null;
    final dataStart = sizeVint.nextPos;
    final dataEnd = sizeVint.unknownSize ? limit : dataStart + sizeVint.value;
    return (id: idVint.value, dataStart: dataStart, dataEnd: dataEnd);
  }

  static ({int value, int nextPos, bool unknownSize})? _readVint(
    Uint8List bytes,
    int pos,
    int limit, {
    required bool keepMarkerBit,
  }) {
    if (pos >= limit) return null;
    final first = bytes[pos];
    if (first == 0) return null;
    var length = 1;
    var mask = 0x80;
    while (length <= 8 && (first & mask) == 0) {
      length++;
      mask >>= 1;
    }
    if (length > 8 || pos + length > limit) return null;
    var value = keepMarkerBit ? first : (first & (mask - 1));
    var allOnes = !keepMarkerBit && value == (mask - 1);
    for (var i = 1; i < length; i++) {
      final b = bytes[pos + i];
      if (b != 0xFF) allOnes = false;
      value = (value << 8) | b;
    }
    return (value: value, nextPos: pos + length, unknownSize: allOnes);
  }

  static int _readEbmlUint(Uint8List bytes, int start, int end) {
    final len = end - start;
    if (len <= 0 || len > 8) return 0;
    var v = 0;
    for (var i = start; i < end; i++) {
      v = (v << 8) | bytes[i];
    }
    return v;
  }

  // -- FLV --------------------------------------------------------------------------------------

  static VideoDimensions? _parseFlv(Uint8List bytes, {bool streamingPartial = false}) {
    if (bytes.length < 13) return null;
    final bd = ByteData.sublistView(bytes);
    final dataOffset = bd.getUint32(5);
    var pos = dataOffset + 4; // skip PreviousTagSize0
    while (pos + 11 <= bytes.length) {
      final tagType = bytes[pos];
      final dataSize = (bytes[pos + 1] << 16) | (bytes[pos + 2] << 8) | bytes[pos + 3];
      final bodyStart = pos + 11;
      if (streamingPartial && bodyStart + dataSize > bytes.length) break;
      final bodyEnd = math.min(bodyStart + dataSize, bytes.length);
      if (tagType == 18 && bodyEnd > bodyStart) {
        final w = _findAmf0Number(bytes, bodyStart, bodyEnd, 'width');
        final h = _findAmf0Number(bytes, bodyStart, bodyEnd, 'height');
        if (w != null && h != null) {
          final valid = _validDims(w.round(), h.round());
          if (valid != null) return valid;
        }
      } else if (tagType == 9 && bodyStart + 5 < bodyEnd) {
        final headerByte = bytes[bodyStart];
        final isExHeader = (headerByte & 0x80) != 0;
        if (isExHeader && bodyStart + 5 <= bodyEnd) {
          final pktType = headerByte & 0x0F;
          final fourcc = String.fromCharCodes(bytes.sublist(bodyStart + 1, bodyStart + 5));
          if (pktType == 0 && (fourcc == 'hvc1' || fourcc == 'hev1')) {
            final d = _parseHevcDecoderConfigRecord(bytes, bodyStart + 5, bodyEnd);
            if (d != null) return d;
          } else if (pktType == 0 && fourcc == 'avc1') {
            final d = _parseAvcDecoderConfigRecord(bytes, bodyStart + 5, bodyEnd);
            if (d != null) return d;
          }
        } else {
          final codecId = headerByte & 0x0F;
          final avcPacketType = bytes[bodyStart + 1];
          if (codecId == 7 && avcPacketType == 0) {
            final d = _parseAvcDecoderConfigRecord(bytes, bodyStart + 5, bodyEnd);
            if (d != null) return d;
          } else if (codecId == 12 && avcPacketType == 0) {
            final d = _parseHevcDecoderConfigRecord(bytes, bodyStart + 5, bodyEnd);
            if (d != null) return d;
          }
        }
      }
      final nextPos = bodyStart + dataSize + 4;
      if (nextPos <= pos) break;
      pos = nextPos;
    }
    return null;
  }

  static double? _findAmf0Number(Uint8List bytes, int start, int end, String key) {
    final keyBytes = key.codeUnits;
    final limit = end - (2 + keyBytes.length + 9);
    for (var i = start; i <= limit; i++) {
      final strLen = (bytes[i] << 8) | bytes[i + 1];
      if (strLen != keyBytes.length) continue;
      var match = true;
      for (var j = 0; j < keyBytes.length; j++) {
        if (bytes[i + 2 + j] != keyBytes[j]) {
          match = false;
          break;
        }
      }
      if (!match) continue;
      final typeOffset = i + 2 + keyBytes.length;
      if (bytes[typeOffset] != 0x00) continue; // AMF0 Number marker
      final val = ByteData.sublistView(bytes, typeOffset + 1, typeOffset + 9).getFloat64(0);
      if (val.isFinite && val > 0) return val;
    }
    return null;
  }

  // -- MPEG-TS / M2TS + H.264 / HEVC SPS --------------------------------------------------------

  static VideoDimensions? _parseMpegTs(Uint8List bytes, {bool streamingPartial = false}) {
    final sync = _findTsSync(bytes);
    if (sync == null) return null;
    final packetSize = sync.packetSize;
    final tsPayloadOffset = packetSize == 192 ? 4 : 0;

    int? pmtPid;
    int? videoPid;
    int? videoStreamType; // 0x1B = H.264, 0x24 = HEVC
    final videoPes = BytesBuilder(copy: false);

    for (var pkt = sync.offset; pkt + packetSize <= bytes.length; pkt += packetSize) {
      final p = pkt + tsPayloadOffset;
      if (bytes[p] != 0x47) continue;
      final pusi = (bytes[p + 1] & 0x40) != 0;
      final pid = ((bytes[p + 1] & 0x1F) << 8) | bytes[p + 2];
      final afc = (bytes[p + 3] >> 4) & 0x03;
      if (afc == 0 || afc == 2) continue; // no payload
      var payloadStart = p + 4;
      if (afc == 3) {
        if (payloadStart >= pkt + packetSize) continue;
        payloadStart += 1 + bytes[payloadStart];
      }
      final pktEnd = pkt + packetSize;
      if (payloadStart >= pktEnd) continue;

      if (pid == 0 && pmtPid == null) {
        var sec = payloadStart;
        if (pusi) sec += 1 + bytes[sec];
        if (sec + 12 <= pktEnd && bytes[sec] == 0x00) {
          final secLen = ((bytes[sec + 1] & 0x0F) << 8) | bytes[sec + 2];
          final entriesEnd = math.min(sec + 3 + secLen - 4, pktEnd);
          for (var e = sec + 8; e + 4 <= entriesEnd; e += 4) {
            final progNum = (bytes[e] << 8) | bytes[e + 1];
            final candPid = ((bytes[e + 2] & 0x1F) << 8) | bytes[e + 3];
            if (progNum != 0) {
              pmtPid = candPid;
              break;
            }
          }
        }
      } else if (pmtPid != null && pid == pmtPid && videoPid == null) {
        var sec = payloadStart;
        if (pusi) sec += 1 + bytes[sec];
        if (sec + 12 <= pktEnd && bytes[sec] == 0x02) {
          final secLen = ((bytes[sec + 1] & 0x0F) << 8) | bytes[sec + 2];
          final progInfoLen = ((bytes[sec + 10] & 0x0F) << 8) | bytes[sec + 11];
          final streamsEnd = math.min(sec + 3 + secLen - 4, pktEnd);
          var es = sec + 12 + progInfoLen;
          while (es + 5 <= streamsEnd) {
            final st = bytes[es];
            final elemPid = ((bytes[es + 1] & 0x1F) << 8) | bytes[es + 2];
            final esInfoLen = ((bytes[es + 3] & 0x0F) << 8) | bytes[es + 4];
            if (st == 0x1B || st == 0x24) {
              videoPid = elemPid;
              videoStreamType = st;
              break;
            }
            es += 5 + esInfoLen;
          }
        }
      } else if (videoPid != null && pid == videoPid) {
        var esStart = payloadStart;
        if (pusi &&
            esStart + 9 <= pktEnd &&
            bytes[esStart] == 0x00 &&
            bytes[esStart + 1] == 0x00 &&
            bytes[esStart + 2] == 0x01) {
          final pesHeaderLen = bytes[esStart + 8];
          esStart = math.min(esStart + 9 + pesHeaderLen, pktEnd);
        }
        if (esStart < pktEnd) {
          videoPes.add(Uint8List.sublistView(bytes, esStart, pktEnd));
          if (videoPes.length >= 128) {
            final d = _parseAnnexBSps(
              videoPes.toBytes(),
              isHevc: videoStreamType == 0x24,
              allowTrailingNal: !streamingPartial,
            );
            if (d != null) return d;
          }
        }
      }
    }

    if (videoPes.length > 0 && videoStreamType != null) {
      return _parseAnnexBSps(
        videoPes.toBytes(),
        isHevc: videoStreamType == 0x24,
        allowTrailingNal: !streamingPartial,
      );
    }
    return null;
  }

  static ({int offset, int packetSize})? _findTsSync(Uint8List bytes) {
    final maxScan = math.min(bytes.length, 32768);
    for (final packetSize in const [188, 192]) {
      final syncOff = packetSize == 192 ? 4 : 0;
      if (bytes.length < packetSize * 2 + syncOff + 1) continue;
      final limit = math.min(maxScan, bytes.length - packetSize * 2 - syncOff - 1);
      for (var i = 0; i <= limit; i++) {
        if (bytes[i + syncOff] == 0x47 &&
            bytes[i + packetSize + syncOff] == 0x47 &&
            bytes[i + packetSize * 2 + syncOff] == 0x47) {
          return (offset: i, packetSize: packetSize);
        }
      }
    }
    return null;
  }

  static VideoDimensions? _parseAvcDecoderConfigRecord(Uint8List bytes, int start, int end) {
    if (start + 8 > end) return null;
    final numSps = bytes[start + 5] & 0x1F;
    var pos = start + 6;
    for (var i = 0; i < numSps && pos + 2 <= end; i++) {
      final spsLen = (bytes[pos] << 8) | bytes[pos + 1];
      pos += 2;
      if (pos + spsLen > end) break;
      if (spsLen > 1) {
        final d = parseH264SpsNal(Uint8List.sublistView(bytes, pos, pos + spsLen));
        if (d != null) return d;
      }
      pos += spsLen;
    }
    return null;
  }

  static VideoDimensions? _parseHevcDecoderConfigRecord(Uint8List bytes, int start, int end) {
    if (start + 23 > end) return null;
    final numArrays = bytes[start + 22];
    var pos = start + 23;
    for (var i = 0; i < numArrays && pos + 3 <= end; i++) {
      final nalType = bytes[pos] & 0x3F;
      final numNalus = (bytes[pos + 1] << 8) | bytes[pos + 2];
      pos += 3;
      for (var j = 0; j < numNalus && pos + 2 <= end; j++) {
        final naluLen = (bytes[pos] << 8) | bytes[pos + 1];
        pos += 2;
        if (pos + naluLen > end) return null;
        if (nalType == 33 && naluLen > 2) {
          final d = parseHevcSpsNal(Uint8List.sublistView(bytes, pos, pos + naluLen));
          if (d != null) return d;
        }
        pos += naluLen;
      }
    }
    return null;
  }

  static VideoDimensions? _parseAnnexBSps(Uint8List data, {required bool isHevc, bool allowTrailingNal = true}) {
    var i = 0;
    int? nalStart;
    while (i + 3 <= data.length) {
      int prefix = 0;
      if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) {
        prefix = 3;
      } else if (i + 4 <= data.length && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1) {
        prefix = 4;
      }
      if (prefix > 0) {
        if (nalStart != null && i > nalStart) {
          final d = _tryParseSingleNal(Uint8List.sublistView(data, nalStart, i), isHevc: isHevc);
          if (d != null) return d;
        }
        nalStart = i + prefix;
        i += prefix;
      } else {
        i++;
      }
    }
    if (allowTrailingNal && nalStart != null && nalStart < data.length) {
      return _tryParseSingleNal(Uint8List.sublistView(data, nalStart, data.length), isHevc: isHevc);
    }
    return null;
  }

  static VideoDimensions? _tryParseSingleNal(Uint8List nal, {required bool isHevc}) {
    if (nal.isEmpty) return null;
    if (isHevc) {
      if (nal.length < 3) return null;
      final nalType = (nal[0] >> 1) & 0x3F;
      return nalType == 33 ? parseHevcSpsNal(nal) : null;
    }
    final nalType = nal[0] & 0x1F;
    return nalType == 7 ? parseH264SpsNal(nal) : null;
  }

  static Uint8List _unescapeRbsp(Uint8List nal, int headerBytes) {
    final out = BytesBuilder(copy: false);
    var zeros = 0;
    for (var i = headerBytes; i < nal.length; i++) {
      final b = nal[i];
      if (zeros >= 2 && b == 0x03) {
        zeros = 0;
        continue;
      }
      out.addByte(b);
      zeros = b == 0 ? zeros + 1 : 0;
    }
    return out.takeBytes();
  }

  static const _sarTable = <int, (int, int)>{
    1: (1, 1),
    2: (12, 11),
    3: (10, 11),
    4: (16, 11),
    5: (40, 33),
    6: (24, 11),
    7: (20, 11),
    8: (32, 11),
    9: (80, 33),
    10: (18, 11),
    11: (15, 11),
    12: (64, 33),
    13: (160, 99),
    14: (4, 3),
    15: (3, 2),
    16: (2, 1),
  };

  static int _applySar(_BitReader br, int width) {
    final aspectPresent = br.readBit();
    if (aspectPresent != 1) return width;
    final idc = br.readBits(8);
    if (idc == null) return width;
    int sarW = 1;
    int sarH = 1;
    if (idc == 255) {
      final w = br.readBits(16);
      final h = br.readBits(16);
      if (w != null && h != null && w > 0 && h > 0) {
        sarW = w;
        sarH = h;
      }
    } else if (_sarTable.containsKey(idc)) {
      final pair = _sarTable[idc]!;
      sarW = pair.$1;
      sarH = pair.$2;
    }
    return (sarW > 0 && sarH > 0 && sarW != sarH) ? (width * sarW / sarH).round() : width;
  }

  /// Parses an H.264 SPS NAL unit (starting at the 1-byte `nal_unit_type == 7` header).
  static VideoDimensions? parseH264SpsNal(Uint8List nal) {
    if (nal.length < 4 || (nal[0] & 0x1F) != 7) return null;
    final rbsp = _unescapeRbsp(nal, 1);
    final br = _BitReader(rbsp);

    final profileIdc = br.readBits(8);
    br.skipBits(16); // constraint flags + level_idc
    if (profileIdc == null || br.readUe() == null) return null; // seq_parameter_set_id

    var chromaFormatIdc = 1;
    var separateColourPlane = false;
    const highProfiles = {100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135};
    if (highProfiles.contains(profileIdc)) {
      final cf = br.readUe();
      if (cf == null) return null;
      chromaFormatIdc = cf;
      if (chromaFormatIdc == 3) separateColourPlane = br.readBit() == 1;
      if (br.readUe() == null || br.readUe() == null) return null; // bit_depth_luma/chroma
      if (br.readBit() == null) return null; // qpprime_y_zero_transform_bypass_flag
      final scalingPresent = br.readBit();
      if (scalingPresent == null) return null;
      if (scalingPresent == 1) {
        final count = chromaFormatIdc != 3 ? 8 : 12;
        for (var i = 0; i < count; i++) {
          final listPresent = br.readBit();
          if (listPresent == null) return null;
          if (listPresent == 1 && !_skipH264ScalingList(br, i < 6 ? 16 : 64)) return null;
        }
      }
    }

    if (br.readUe() == null) return null; // log2_max_frame_num_minus4
    final pocType = br.readUe();
    if (pocType == null) return null;
    if (pocType == 0) {
      if (br.readUe() == null) return null;
    } else if (pocType == 1) {
      if (br.readBit() == null || br.readSe() == null || br.readSe() == null) return null;
      final cycle = br.readUe();
      if (cycle == null || cycle > 256) return null;
      for (var i = 0; i < cycle; i++) {
        if (br.readSe() == null) return null;
      }
    }

    if (br.readUe() == null || br.readBit() == null) return null; // max_num_ref_frames, gaps_in_frame_num
    final picWidthMbsMinus1 = br.readUe();
    final picHeightMapUnitsMinus1 = br.readUe();
    final frameMbsOnly = br.readBit();
    if (picWidthMbsMinus1 == null || picHeightMapUnitsMinus1 == null || frameMbsOnly == null) return null;
    if (frameMbsOnly == 0 && br.readBit() == null) return null; // mb_adaptive_frame_field_flag
    if (br.readBit() == null) return null; // direct_8x8_inference_flag

    var cropLeft = 0, cropRight = 0, cropTop = 0, cropBottom = 0;
    final frameCropping = br.readBit();
    if (frameCropping == null) return null;
    if (frameCropping == 1) {
      final cl = br.readUe(), cr = br.readUe(), ct = br.readUe(), cb = br.readUe();
      if (cl == null || cr == null || ct == null || cb == null) return null;
      cropLeft = cl;
      cropRight = cr;
      cropTop = ct;
      cropBottom = cb;
    }

    final chromaArrayType = separateColourPlane ? 0 : chromaFormatIdc;
    final subWidthC = (chromaArrayType == 1 || chromaArrayType == 2) ? 2 : 1;
    final subHeightC = chromaArrayType == 1 ? 2 : 1;
    final cropUnitX = chromaArrayType == 0 ? 1 : subWidthC;
    final cropUnitY = (chromaArrayType == 0 ? 1 : subHeightC) * (2 - frameMbsOnly);

    var width = (picWidthMbsMinus1 + 1) * 16 - cropUnitX * (cropLeft + cropRight);
    final height = (2 - frameMbsOnly) * (picHeightMapUnitsMinus1 + 1) * 16 - cropUnitY * (cropTop + cropBottom);

    final vuiPresent = br.readBit();
    if (vuiPresent == null) return null;
    if (vuiPresent == 1) {
      width = _applySar(br, width);
    }
    return _validDims(width, height);
  }

  static bool _skipH264ScalingList(_BitReader br, int size) {
    var lastScale = 8;
    var nextScale = 8;
    for (var j = 0; j < size; j++) {
      if (nextScale != 0) {
        final delta = br.readSe();
        if (delta == null) return false;
        nextScale = (lastScale + delta + 256) % 256;
      }
      lastScale = nextScale == 0 ? lastScale : nextScale;
    }
    return true;
  }

  /// Parses an HEVC (H.265) SPS NAL unit (starting at the 2-byte `nal_unit_type == 33` header).
  static VideoDimensions? parseHevcSpsNal(Uint8List nal) {
    if (nal.length < 15 || ((nal[0] >> 1) & 0x3F) != 33) return null;
    final rbsp = _unescapeRbsp(nal, 2);
    final br = _BitReader(rbsp);

    br.skipBits(4); // sps_video_parameter_set_id
    final maxSubLayersMinus1 = br.readBits(3);
    if (maxSubLayersMinus1 == null || br.readBit() == null) return null;

    // profile_tier_level(1, maxSubLayersMinus1)
    if (!br.skipBits(96)) return null;
    final subProfilePresent = List<bool>.filled(maxSubLayersMinus1, false);
    final subLevelPresent = List<bool>.filled(maxSubLayersMinus1, false);
    for (var i = 0; i < maxSubLayersMinus1; i++) {
      final p = br.readBit(), l = br.readBit();
      if (p == null || l == null) return null;
      subProfilePresent[i] = p == 1;
      subLevelPresent[i] = l == 1;
    }
    if (maxSubLayersMinus1 > 0) {
      for (var i = maxSubLayersMinus1; i < 8; i++) {
        if (!br.skipBits(2)) return null;
      }
    }
    for (var i = 0; i < maxSubLayersMinus1; i++) {
      if (subProfilePresent[i] && !br.skipBits(88)) return null;
      if (subLevelPresent[i] && !br.skipBits(8)) return null;
    }

    if (br.readUe() == null) return null; // sps_seq_parameter_set_id
    final chromaFormatIdc = br.readUe();
    if (chromaFormatIdc == null) return null;
    var separateColourPlane = false;
    if (chromaFormatIdc == 3) {
      final f = br.readBit();
      if (f == null) return null;
      separateColourPlane = f == 1;
    }

    final picW = br.readUe();
    final picH = br.readUe();
    final confFlag = br.readBit();
    if (picW == null || picH == null || confFlag == null) return null;

    var confL = 0, confR = 0, confT = 0, confB = 0;
    if (confFlag == 1) {
      final l = br.readUe(), r = br.readUe(), t = br.readUe(), b = br.readUe();
      if (l == null || r == null || t == null || b == null) return null;
      confL = l;
      confR = r;
      confT = t;
      confB = b;
    }

    final subWidthC = separateColourPlane ? 1 : ((chromaFormatIdc == 1 || chromaFormatIdc == 2) ? 2 : 1);
    final subHeightC = separateColourPlane ? 1 : (chromaFormatIdc == 1 ? 2 : 1);
    final width = picW - subWidthC * (confL + confR);
    final height = picH - subHeightC * (confT + confB);
    return _validDims(width, height);
  }
}

class _FetchedSlice {
  const _FetchedSlice({
    required this.bytes,
    required this.statusCode,
    required this.totalBytes,
    required this.contentType,
    required this.finalUri,
    this.earlyDimensions,
    this.earlyDeferredMoovOffset,
  });

  final Uint8List bytes;
  final int statusCode;
  final int? totalBytes;
  final String contentType;
  final Uri finalUri;
  final VideoDimensions? earlyDimensions;
  final int? earlyDeferredMoovOffset;
}

class _BitReader {
  _BitReader(this._data);
  final Uint8List _data;
  int _bitOffset = 0;

  int get _totalBits => _data.length * 8;

  bool skipBits(int n) {
    if (n < 0 || _bitOffset + n > _totalBits) return false;
    _bitOffset += n;
    return true;
  }

  int? readBit() {
    if (_bitOffset >= _totalBits) return null;
    final b = (_data[_bitOffset >> 3] >> (7 - (_bitOffset & 7))) & 1;
    _bitOffset++;
    return b;
  }

  int? readBits(int n) {
    if (n < 0 || n > 32 || _bitOffset + n > _totalBits) return null;
    var v = 0;
    for (var i = 0; i < n; i++) {
      v = (v << 1) | ((_data[_bitOffset >> 3] >> (7 - (_bitOffset & 7))) & 1);
      _bitOffset++;
    }
    return v;
  }

  int? readUe() {
    var zeros = 0;
    while (true) {
      final bit = readBit();
      if (bit == null) return null;
      if (bit == 1) break;
      zeros++;
      if (zeros > 30) return null;
    }
    if (zeros == 0) return 0;
    final tail = readBits(zeros);
    if (tail == null) return null;
    return ((1 << zeros) - 1) + tail;
  }

  int? readSe() {
    final codeNum = readUe();
    if (codeNum == null) return null;
    final mag = (codeNum + 1) >> 1;
    return (codeNum & 1) != 0 ? mag : -mag;
  }
}
