import 'dart:convert';

import 'package:dio/dio.dart';

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
  DanmuClient(String baseUrl, {Dio? dio}) : _base = baseUrl.replaceAll(RegExp(r'/+$'), ''), _dio = dio ?? Dio();
  final String _base;
  final Dio _dio;

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
