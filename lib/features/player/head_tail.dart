import 'dart:convert';

import '../../core/json_store.dart';

/// 片头片尾: where a video's intro ends and where its outro starts, set with 记片头 / 记片尾 in the player and applied to
/// every episode of that video.
///
/// OBSERVED: UZN 1.1.7 shows 记片头 in the player's bottom bar early in an episode, has the strings 记片尾, 跳过片头,
/// 跳过片尾, 片头结束（秒） and 无片头片尾记录, and keeps the data in `video_head_tail.json` (a backup item of its own).
/// INFERRED: the file's layout (`{videoKey: {"intro": seconds, "outro": seconds}}`) and that the outro is kept as
/// seconds before the end, so episodes of different lengths skip the same credits.
class HeadTailRepository {
  HeadTailRepository({JsonStore? store}) : _store = store ?? JsonStore('video_head_tail.json');
  final JsonStore _store;

  Future<Map<String, dynamic>> _all() async => Map<String, dynamic>.of(await _store.read<Map<String, dynamic>>({}));

  static double _seconds(Object? v) => v is num && v > 0 ? v.toDouble() : 0;

  /// (intro end in seconds from the start, outro length in seconds before the end); 0 = not set.
  Future<(double, double)> get(String key) async {
    final e = (await _all())[key];
    return e is Map ? (_seconds(e['intro']), _seconds(e['outro'])) : (0.0, 0.0);
  }

  /// Returns (intro, outro, ranges) for [key].
  Future<({double intro, double outro, List<(double, double)> ranges})> getAll(String key) async {
    final e = (await _all())[key];
    if (e is! Map) return (intro: 0.0, outro: 0.0, ranges: const <(double, double)>[]);
    final rawRanges = e['ranges'];
    final ranges = <(double, double)>[];
    if (rawRanges is List) {
      for (final r in rawRanges) {
        if (r is Map) {
          final s = _seconds(r['start']);
          final end = _seconds(r['end']);
          if (end > s) ranges.add((s, end));
        }
      }
    }
    return (intro: _seconds(e['intro']), outro: _seconds(e['outro']), ranges: ranges);
  }

  /// [type] 'intro' or 'outro'; [seconds] <= 0 forgets that mark.
  Future<void> mark(String key, String type, double seconds) async {
    if (type != 'intro' && type != 'outro') return;
    final all = await _all();
    final e = Map<String, dynamic>.of(all[key] is Map ? (all[key] as Map).cast<String, dynamic>() : const {});
    if (seconds > 0) {
      e[type] = seconds;
    } else {
      e.remove(type);
    }
    if (e.isEmpty) {
      all.remove(key);
    } else {
      all[key] = e;
    }
    await _store.write(all);
  }

  Future<void> addRange(String key, double startSec, double endSec) async {
    if (endSec <= startSec || startSec < 0) return;
    final all = await _all();
    final e = Map<String, dynamic>.of(all[key] is Map ? (all[key] as Map).cast<String, dynamic>() : const {});
    final list = <Map<String, dynamic>>[
      if (e['ranges'] is List)
        for (final r in e['ranges'] as List)
          if (r is Map) {'start': _seconds(r['start']), 'end': _seconds(r['end'])},
      {'start': startSec, 'end': endSec},
    ];
    e['ranges'] = list;
    all[key] = e;
    await _store.write(all);
  }

  Future<void> removeRange(String key, int index) async {
    final all = await _all();
    final e = Map<String, dynamic>.of(all[key] is Map ? (all[key] as Map).cast<String, dynamic>() : const {});
    final raw = e['ranges'];
    if (raw is! List || index < 0 || index >= raw.length) return;
    final next = [...raw]..removeAt(index);
    if (next.isEmpty) {
      e.remove('ranges');
    } else {
      e['ranges'] = next;
    }
    if (e.isEmpty) {
      all.remove(key);
    } else {
      all[key] = e;
    }
    await _store.write(all);
  }

  /// The marks as the native player reads them (OpenPlayerRequest.headTailSectionsJson); null when there are none.
  Future<String?> sectionsJson(String key) async {
    final data = await getAll(key);
    if (data.intro <= 0 && data.outro <= 0 && data.ranges.isEmpty) return null;
    return jsonEncode([
      if (data.intro > 0) {'type': 'intro', 'endMs': (data.intro * 1000).round()},
      if (data.outro > 0) {'type': 'outro', 'beforeEndMs': (data.outro * 1000).round()},
      for (final (s, e) in data.ranges) {'type': 'range', 'startMs': (s * 1000).round(), 'endMs': (e * 1000).round()},
    ]);
  }
}
