import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

import '../core/app_http.dart';

/// Danmaku (bullet comments) client.
///
/// OBSERVED: three service modes (embedded `danmu_api` script run by the Node runtime, the subscription's own
/// service, "custom remote" self-hosted danmu_api URL - changelog 1.1.4), env var `DANMU_API_PORT`, config file
/// danmu_service_config.json, default local address http://127.0.0.1:9321 with optional `/TOKEN` path prefix,
/// manual search + episode picker, per-show memory of the chosen match (danmu_refs), and the `/api/v2/` prefix.
/// INFERRED: dandanplay-compatible routes (`/api/v2/search/anime`, `/api/v2/bangumi/{id}`,
/// `/api/v2/comment/{episodeId}`), which is what danmu_api implements.
class DanmuAnime {
  const DanmuAnime({required this.animeId, required this.title, required this.episodeCount, this.imageUrl});
  final int animeId;
  final String title;
  final int episodeCount;
  final String? imageUrl;
}

class DanmuEpisode {
  const DanmuEpisode({required this.episodeId, required this.title, this.number});
  final int episodeId;
  final String title;
  final int? number;
}

class DanmuComment {
  const DanmuComment({required this.time, required this.mode, required this.color, required this.text});
  final double time; // seconds
  final int mode; // 1 scroll, 4 bottom, 5 top (dandanplay)
  final int color; // 0xRRGGBB
  final String text;
  Map<String, Object> toJson() => {'t': time, 'm': mode, 'c': color, 'x': text};
}

class DanmuClient {
  DanmuClient(String baseUrl, {Dio? dio})
      : _base = baseUrl.replaceAll(RegExp(r'/+$'), ''),
        _dio = dio ?? createAppDio(connectTimeout: const Duration(seconds: 6), receiveTimeout: const Duration(seconds: 15));
  final String _base;
  final Dio _dio;

  String get baseUrl => _base;

  Future<List<DanmuAnime>> searchAnime(String keyword) async {
    final res = await _dio.get<Map<String, dynamic>>('$_base/api/v2/search/anime', queryParameters: {'keyword': keyword});
    return ((res.data?['animes'] as List?) ?? const [])
        .whereType<Map>()
        .map((a) => DanmuAnime(
              animeId: (a['animeId'] as num).toInt(),
              title: '${a['animeTitle']}',
              episodeCount: (a['episodeCount'] as num?)?.toInt() ?? 0,
              imageUrl: a['imageUrl'] as String?,
            ))
        .toList();
  }

  Future<List<DanmuEpisode>> episodes(int animeId) async {
    final res = await _dio.get<Map<String, dynamic>>('$_base/api/v2/bangumi/$animeId');
    final bangumi = (res.data?['bangumi'] as Map?)?.cast<String, dynamic>();
    return ((bangumi?['episodes'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => DanmuEpisode(
              episodeId: (e['episodeId'] as num).toInt(),
              title: '${e['episodeTitle']}',
              number: int.tryParse('${e['episodeNumber']}'),
            ))
        .toList();
  }

  Future<List<DanmuComment>> comments(int episodeId) async {
    final res = await _dio.get<Map<String, dynamic>>('$_base/api/v2/comment/$episodeId',
        queryParameters: {'withRelated': true, 'chConvert': 0});
    return parseDandanComments(res.data?['comments'] as List? ?? const []);
  }
}

/// `p` = "time,mode,color,userId".
List<DanmuComment> parseDandanComments(List<dynamic> raw) {
  final out = <DanmuComment>[];
  for (final c in raw.whereType<Map>()) {
    final parts = '${c['p']}'.split(',');
    if (parts.length < 3) continue;
    out.add(DanmuComment(
      time: double.tryParse(parts[0]) ?? 0,
      mode: int.tryParse(parts[1]) ?? 1,
      color: int.tryParse(parts[2]) ?? 0xFFFFFF,
      text: '${c['m']}',
    ));
  }
  out.sort((a, b) => a.time.compareTo(b.time));
  return out;
}

/// Comments pushed by a script: dandanplay objects (`{"p":"time,mode,color,uid","m":"text"}`) or plain
/// `{"time":..,"mode":..,"color":..,"text":..}` objects. Shape is inferred, so both are accepted.
List<DanmuComment> parseDanmuPush(List<dynamic> raw) {
  final plain = <DanmuComment>[];
  final dandan = <Map>[];
  for (final c in raw.whereType<Map>()) {
    if (c.containsKey('p')) {
      dandan.add(c);
    } else if (c['text'] != null || c['m'] != null) {
      plain.add(DanmuComment(
        time: (c['time'] as num?)?.toDouble() ?? (c['t'] as num?)?.toDouble() ?? 0,
        mode: (c['mode'] as num?)?.toInt() ?? 1,
        color: (c['color'] as num?)?.toInt() ?? 0xFFFFFF,
        text: '${c['text'] ?? c['m']}',
      ));
    }
  }
  return [...parseDandanComments(dandan), ...plain]..sort((a, b) => a.time.compareTo(b.time));
}

String danmuCommentsToJson(List<DanmuComment> list) => jsonEncode(list.map((c) => c.toJson()).toList());

/// Applies the user's blacklist and the "top/bottom fixed" visibility switches (changelog 1.1.6).
List<DanmuComment> filterDanmu(List<DanmuComment> src, {required List<String> blackList, bool showTop = true, bool showBottom = true}) {
  return src.where((c) {
    if (c.mode == 5 && !showTop) return false;
    if (c.mode == 4 && !showBottom) return false;
    return !blackList.any((w) => w.isNotEmpty && c.text.contains(w));
  }).toList();
}

/// Parses video-returned danmaku payloads: Bilibili XML (`<d p="time,mode,size,color,...">text</d>`),
/// DPlayer/ArtPlayer JSON (`{"danmuku": [[time, pos, color, author, text], ...]}` or `{"data": [...]}`),
/// or dandanplay / plain comment lists.
List<DanmuComment> parseVideoDanmakuPayload(Object? raw) {
  if (raw == null) return const [];
  if (raw is List) return _parseDanmuArray(raw);
  if (raw is Map) {
    final list = raw['comments'] ?? raw['danmuku'] ?? raw['danmaku'] ?? raw['danmu'] ?? raw['data'] ?? raw['list'];
    return list is List ? _parseDanmuArray(list) : const [];
  }
  final text = '$raw'.trim();
  if (text.isEmpty) return const [];
  if (text.startsWith('{') || text.startsWith('[')) {
    try {
      return parseVideoDanmakuPayload(jsonDecode(text));
    } catch (_) {
      return const [];
    }
  }
  if (text.contains('<d ') || text.contains('<d>')) {
    try {
      final doc = XmlDocument.parse(text);
      final out = <DanmuComment>[];
      for (final d in doc.findAllElements('d')) {
        final content = d.innerText;
        if (content.isEmpty) continue;
        final pAttr = (d.getAttribute('p') ?? '').split(',');
        if (pAttr.length < 4) continue;
        out.add(DanmuComment(
          time: double.tryParse(pAttr[0]) ?? 0,
          mode: int.tryParse(pAttr[1]) ?? 1,
          color: int.tryParse(pAttr[3]) ?? 0xFFFFFF,
          text: content,
        ));
      }
      out.sort((a, b) => a.time.compareTo(b.time));
      return out;
    } catch (_) {
      return const [];
    }
  }
  return const [];
}

List<DanmuComment> _parseDanmuArray(List<dynamic> list) {
  if (list.isEmpty) return const [];
  if (list.first is List) {
    final out = <DanmuComment>[];
    for (final row in list.whereType<List>()) {
      if (row.length < 5) continue;
      final time = row[0] is num ? (row[0] as num).toDouble() : (double.tryParse('${row[0]}') ?? 0);
      final rawMode = '${row[1]}';
      final mode = switch (rawMode) {
        'top' || '5' => 5,
        'bottom' || '4' => 4,
        _ => 1,
      };
      final rawColor = row[2];
      final color = rawColor is num
          ? rawColor.toInt()
          : (int.tryParse('$rawColor'.replaceFirst('#', '').replaceFirst('0x', ''), radix: '$rawColor'.startsWith('#') || '$rawColor'.startsWith('0x') ? 16 : 10) ??
              0xFFFFFF);
      final text = '${row[4]}';
      if (text.isNotEmpty) out.add(DanmuComment(time: time, mode: mode, color: color & 0xFFFFFF, text: text));
    }
    out.sort((a, b) => a.time.compareTo(b.time));
    return out;
  }
  return parseDanmuPush(list);
}

Future<List<DanmuComment>> fetchVideoDanmakuUrl(
  String url, {
  Map<String, String> headers = const {},
  Dio? dio,
}) async {
  final client = dio ?? createAppDio(connectTimeout: const Duration(seconds: 8), receiveTimeout: const Duration(seconds: 15));
  final res = await client.get<String>(
    url,
    options: Options(responseType: ResponseType.plain, headers: headers.isEmpty ? null : headers),
  );
  return parseVideoDanmakuPayload(res.data);
}
