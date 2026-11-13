import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// A network image for posters that sends its request headers as they are.
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

  static final HttpClient _client = HttpClient()
    ..userAgent = null
    ..autoUncompress = false;

  /// Downloads [url] with [headers] set as they are (no `Dart/x.y (dart:io)` user agent is added).
  static Future<Uint8List> fetchBytes(String url, Map<String, String> headers,
      {void Function(int received, int? total)? onBytesReceived}) async {
    final uri = Uri.parse(url);
    final req = await _client.getUrl(uri);
    headers.forEach(req.headers.set);
    final res = await req.close();
    if (res.statusCode != HttpStatus.ok) {
      await res.drain<void>();
      throw NetworkImageLoadException(statusCode: res.statusCode, uri: uri);
    }
    final bytes = await consolidateHttpClientResponseBytes(res, onBytesReceived: onBytesReceived);
    if (bytes.lengthInBytes == 0) throw Exception('PosterImage is an empty file: $url');
    return bytes;
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
      final bytes = await fetchBytes(key.url, key.headers, onBytesReceived: (received, total) {
        chunks.add(ImageChunkEvent(cumulativeBytesLoaded: received, expectedTotalBytes: total));
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
