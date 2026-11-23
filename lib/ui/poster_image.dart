import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A network image for posters that sends its request headers as they are and caches raw image bytes on disk.
///
/// Flutter's `NetworkImage` *adds* each header to a request that already carries dart:io's own
/// `User-Agent: Dart/x.y (dart:io)`, so the server receives `Dart/x.y (dart:io), Mozilla/5.0 …`. OBSERVED (2026-11-13,
/// 「荐」豆瓣): `img*.doubanio.com` answers 403 to that even with the right `Referer` (418 without it), and 200 to a
/// browser `User-Agent` alone, so every 豆瓣 poster showed the placeholder. This provider uses a client with no default
/// `User-Agent` and *sets* the headers.
@immutable
class PosterImage extends ImageProvider<PosterImage> {
  const PosterImage(this.url, {this.headers = const {}, this.scale = 1.0});

  final String url;
  final Map<String, String> headers;
  final double scale;

  /// Override directory used by disk-cache unit tests.
  @visibleForTesting
  static Directory? debugCacheDir;

  /// Active local CatPaw loopback server port; LAN URLs targeting this port rewrite to `127.0.0.1` so QR/proxy images
  /// work even when the script only bound `127.0.0.1` or a VPN intercepts LAN traffic.
  static int localCatpawPort = 0;

  static const int _maxCachedFiles = 600;
  static int _writesSincePrune = 0;
  static final Map<String, Future<Uint8List>> _inFlight = {};

  static bool _isLoopbackHost(String host) =>
      host == '127.0.0.1' || host == 'localhost' || host == '::1' || host == '[::1]';

  static bool isPrivateLanIpv4(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return false;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    if (a == null || b == null) return false;
    return a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31);
  }

  static String normalizeLocalUrl(String url, [int? catpawPort]) {
    final p = catpawPort ?? localCatpawPort;
    var out = url;
    final uri = Uri.tryParse(url);
    if (p > 0 && uri != null && uri.scheme == 'http' && uri.hasPort && uri.port == p && isPrivateLanIpv4(uri.host)) {
      out = uri.replace(host: '127.0.0.1').toString();
    }
    const proxySeg = '/spider/baseset/3/proxy/';
    final idx = out.indexOf(proxySeg);
    if (idx >= 0) {
      final tailStart = idx + proxySeg.length;
      final qIdx = out.indexOf('?', tailStart);
      final rawPayload = qIdx >= 0 ? out.substring(tailStart, qIdx) : out.substring(tailStart);
      if (rawPayload.contains('/')) {
        final encoded = rawPayload.replaceAll('/', '%2F').replaceAll('+', '%2B');
        out = out.substring(0, tailStart) + encoded + (qIdx >= 0 ? out.substring(qIdx) : '');
      }
    }
    return out;
  }

  static final HttpClient _client = HttpClient()
    ..userAgent = null
    ..autoUncompress = false
    ..maxConnectionsPerHost = 6
    ..connectionTimeout = const Duration(seconds: 12)
    ..findProxy = (uri) => (_isLoopbackHost(uri.host) || isPrivateLanIpv4(uri.host))
        ? 'DIRECT'
        : HttpClient.findProxyFromEnvironment(uri);

  static bool get _inFakeAsyncWidgetTest {
    try {
      return SchedulerBinding.instance.runtimeType.toString().contains('TestWidgetsFlutterBinding');
    } catch (_) {
      return false;
    }
  }

  static Future<Directory?> _resolveCacheDir() async {
    if (debugCacheDir != null) return debugCacheDir;
    if (_inFakeAsyncWidgetTest) return null;
    try {
      final tmp = await getTemporaryDirectory();
      return Directory(p.join(tmp.path, 'poster_cache'));
    } catch (_) {
      return null;
    }
  }

  static String _canonicalCacheUrl(String url) {
    final normalized = normalizeLocalUrl(url);
    final uri = Uri.tryParse(normalized);
    if (uri != null && _isLoopbackHost(uri.host) && uri.path == '/proxy/img') {
      final target = uri.queryParameters['u'];
      if (target != null && target.isNotEmpty) return target;
    }
    return normalized;
  }

  static bool _shouldSkipDiskCache(String url) {
    if (url.startsWith('data:')) return true;
    final uri = Uri.tryParse(normalizeLocalUrl(url));
    return uri != null && _isLoopbackHost(uri.host) && uri.path.contains('/spider/baseset/');
  }

  static String _cacheFileName(String cacheKey) => '${md5.convert(utf8.encode(cacheKey))}.img';

  /// Deletes the on-disk poster cache (`设置 → 数据清理 → 图片缓存`).
  static Future<void> clearDiskCache({Future<Directory> Function()? tempDir}) async {
    final dir = debugCacheDir ??
        (tempDir != null ? Directory(p.join((await tempDir()).path, 'poster_cache')) : await _resolveCacheDir());
    if (dir != null && await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  /// Downloads [url] with [headers] set as they are (no `Dart/x.y (dart:io)` user agent is added).
  static Future<Uint8List> fetchBytes(String url, Map<String, String> headers,
      {void Function(int received, int? total)? onBytesReceived}) async {
    final effectiveUrl = normalizeLocalUrl(url);
    if (effectiveUrl.startsWith('data:')) {
      final data = UriData.parse(effectiveUrl).contentAsBytes();
      if (data.isEmpty) throw Exception('PosterImage is an empty data URI');
      onBytesReceived?.call(data.length, data.length);
      return data;
    }
    final uri = Uri.parse(effectiveUrl);
    final req = await _client.getUrl(uri);
    headers.forEach(req.headers.set);
    final res = await req.close().timeout(const Duration(seconds: 25));
    if (res.statusCode != HttpStatus.ok) {
      await res.drain<void>();
      throw NetworkImageLoadException(statusCode: res.statusCode, uri: uri);
    }
    final bytes = await consolidateHttpClientResponseBytes(res, onBytesReceived: onBytesReceived);
    if (bytes.lengthInBytes == 0) throw Exception('PosterImage is an empty file: $effectiveUrl');
    return bytes;
  }

  /// Reads [url] from the disk cache when present, otherwise downloads once (deduplicating concurrent requests) and
  /// stores it atomically.
  static Future<Uint8List> loadBytesCached(String url, Map<String, String> headers,
      {void Function(int received, int? total)? onBytesReceived}) async {
    final skipDisk = _shouldSkipDiskCache(url);
    final cacheKey = _canonicalCacheUrl(url);
    final cacheDir = skipDisk ? null : await _resolveCacheDir();
    File? cacheFile;
    if (cacheDir != null) {
      cacheFile = File(p.join(cacheDir.path, _cacheFileName(cacheKey)));
      try {
        if (await cacheFile.exists()) {
          final bytes = await cacheFile.readAsBytes();
          if (bytes.isNotEmpty) return bytes;
        }
      } catch (e) {
        debugPrint('PosterImage cache read ignored: $e');
      }
    }

    final existing = _inFlight[cacheKey];
    if (existing != null) return existing;

    final task = () async {
      final bytes = await fetchBytes(url, headers, onBytesReceived: onBytesReceived);
      if (cacheDir != null && cacheFile != null) {
        await _persistToCache(cacheDir, cacheFile, bytes);
      }
      return bytes;
    }();
    _inFlight[cacheKey] = task;
    try {
      return await task;
    } finally {
      if (identical(_inFlight[cacheKey], task)) _inFlight.remove(cacheKey);
    }
  }

  static Future<void> _persistToCache(Directory dir, File target, Uint8List bytes) async {
    try {
      await dir.create(recursive: true);
      final tmp = File('${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
      await tmp.writeAsBytes(bytes, flush: false);
      await tmp.rename(target.path);
      if (++_writesSincePrune >= 50) {
        _writesSincePrune = 0;
        await _pruneIfNeeded(dir);
      }
    } catch (e) {
      debugPrint('PosterImage cache write ignored: $e');
    }
  }

  static Future<void> _pruneIfNeeded(Directory dir) async {
    final files = <File>[];
    await for (final ent in dir.list(followLinks: false)) {
      if (ent is File && ent.path.endsWith('.img')) files.add(ent);
    }
    if (files.length <= _maxCachedFiles) return;
    final stamped = <(File, DateTime)>[];
    for (final f in files) {
      try {
        stamped.add((f, await f.lastModified()));
      } catch (_) {
        // File removed concurrently.
      }
    }
    stamped.sort((a, b) => a.$2.compareTo(b.$2));
    final dropCount = stamped.length - (_maxCachedFiles - 50);
    for (var i = 0; i < dropCount && i < stamped.length; i++) {
      try {
        await stamped[i].$1.delete();
      } catch (_) {
        // File removed concurrently.
      }
    }
  }

  @override
  Future<PosterImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture<PosterImage>(this);

  @override
  ImageStreamCompleter loadImage(PosterImage key, ImageDecoderCallback decode) {
    final chunks = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _load(key, chunks, decode),
      chunkEvents: chunks.stream,
      scale: key.scale,
      debugLabel: key.url,
      informationCollector: () => [DiagnosticsProperty<ImageProvider>('Image provider', this)],
    );
  }

  Future<ui.Codec> _load(PosterImage key, StreamController<ImageChunkEvent> chunks, ImageDecoderCallback decode) async {
    try {
      final bytes = await loadBytesCached(key.url, key.headers, onBytesReceived: (received, total) {
        if (!chunks.isClosed) {
          chunks.add(ImageChunkEvent(cumulativeBytesLoaded: received, expectedTotalBytes: total));
        }
      });
      return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    } catch (e) {
      // Let the image cache drop the failed entry so the poster is asked again next time it shows.
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    } finally {
      unawaited(chunks.close());
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PosterImage && other.url == url && other.scale == scale && mapEquals(other.headers, headers);

  @override
  int get hashCode => Object.hash(url, scale, Object.hashAllUnordered(headers.entries.map((e) => '${e.key}=${e.value}')));

  @override
  String toString() => 'PosterImage("$url", scale: $scale)';
}
