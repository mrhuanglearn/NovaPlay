/// MacCMS / CatVod style VOD models.
///
/// OBSERVED field names in the Dart string pool: vod_id, vod_name, vod_pic, vod_remarks, vod_play_from,
/// vod_play_url, vod_actor, vod_director, vod_area, vod_lang, vod_time, vod_content, vod_tag, vod_sub,
/// type_id, type_name, pagecount, filters.
class VodItem {
  const VodItem({
    required this.id,
    required this.name,
    this.pic,
    this.remarks,
    this.year,
    this.siteKey,
  });

  factory VodItem.fromJson(Map<String, dynamic> j, {String? siteKey}) => VodItem(
        id: '${j['vod_id'] ?? ''}',
        name: '${j['vod_name'] ?? ''}',
        pic: j['vod_pic'] as String?,
        remarks: j['vod_remarks'] as String?,
        year: j['vod_year']?.toString(),
        siteKey: siteKey,
      );

  final String id;
  final String name;
  final String? pic;
  final String? remarks;
  final String? year;
  final String? siteKey;

  VodItem copyWith({String? id}) =>
      VodItem(id: id ?? this.id, name: name, pic: pic, remarks: remarks, year: year, siteKey: siteKey);

  Map<String, dynamic> toJson() => {
        'vod_id': id,
        'vod_name': name,
        if (pic != null) 'vod_pic': pic,
        if (remarks != null) 'vod_remarks': remarks,
        if (year != null) 'vod_year': year,
        if (siteKey != null) 'siteKey': siteKey,
      };
}

class VodCategory {
  const VodCategory({required this.id, required this.name, this.filters = const []});

  factory VodCategory.fromJson(Map<String, dynamic> j, {Map<String, dynamic>? filterMap}) {
    final id = '${j['type_id']}';
    final raw = filterMap?[id];
    return VodCategory(
      id: id,
      name: '${j['type_name'] ?? id}',
      filters: raw is List
          ? raw.whereType<Map>().map((e) => VodFilter.fromJson(e.cast<String, dynamic>())).toList()
          : const [],
    );
  }

  final String id;
  final String name;
  final List<VodFilter> filters;
}

class VodFilter {
  const VodFilter({required this.key, required this.name, required this.values, this.init = ''});

  factory VodFilter.fromJson(Map<String, dynamic> j) => VodFilter(
        key: '${j['key']}',
        name: '${j['name'] ?? j['key']}',
        init: '${j['init'] ?? ''}',
        values: ((j['value'] as List?) ?? const [])
            .whereType<Map>()
            .map((v) => MapEntry('${v['n']}', '${v['v']}'))
            .toList(),
      );

  final String key;
  final String name;
  final List<MapEntry<String, String>> values;

  /// The value shown as selected before the user picks one (OBSERVED: it is not sent with the request).
  final String init;
}

class PlayEpisode {
  const PlayEpisode(this.name, this.url);
  final String name;
  final String url;
}

class PlayLine {
  const PlayLine(this.name, this.episodes);
  final String name;
  final List<PlayEpisode> episodes;
}

/// `vod_play_from` = "lineA$$$lineB", `vod_play_url` = "ep1$url1#ep2$url2$$$ep1$url1#...".
List<PlayLine> parsePlayLines(String? playFrom, String? playUrl) {
  if (playUrl == null || playUrl.isEmpty) return const [];
  final names = (playFrom ?? '').split(r'$$$');
  final groups = playUrl.split(r'$$$');
  final lines = <PlayLine>[];
  for (var i = 0; i < groups.length; i++) {
    final eps = <PlayEpisode>[];
    for (final part in groups[i].split('#')) {
      if (part.trim().isEmpty) continue;
      final cut = part.indexOf(r'$');
      eps.add(cut < 0
          ? PlayEpisode('${eps.length + 1}', part)
          : PlayEpisode(part.substring(0, cut), part.substring(cut + 1)));
    }
    if (eps.isEmpty) continue;
    final label = i < names.length && names[i].isNotEmpty ? names[i] : 'Line ${i + 1}';
    lines.add(PlayLine(label, eps));
  }
  return lines;
}

class VodDetail {
  const VodDetail({
    required this.item,
    required this.lines,
    this.actor,
    this.director,
    this.area,
    this.lang,
    this.content,
    this.typeName,
    this.responseId,
  });

  factory VodDetail.fromJson(Map<String, dynamic> j, {String? siteKey}) => VodDetail(
        item: VodItem.fromJson(j, siteKey: siteKey),
        lines: parsePlayLines(j['vod_play_from'] as String?, j['vod_play_url'] as String?),
        actor: j['vod_actor'] as String?,
        director: j['vod_director'] as String?,
        area: j['vod_area'] as String?,
        lang: j['vod_lang'] as String?,
        content: j['vod_content'] as String?,
        typeName: j['type_name'] as String?,
      );

  final VodItem item;
  final List<PlayLine> lines;
  final String? actor;
  final String? director;
  final String? area;
  final String? lang;
  final String? content;
  final String? typeName;

  /// The `vod_id` of the detail answer when it is not the id the detail was asked with (see [withRequestedId]).
  final String? responseId;

  /// The detail as asked for [id]: history, favourites and 继续播放 key on the id the video was opened with. INFERRED
  /// (the CatVod convention; the original's own code was not traced): a spider need not echo `vod_id` back.
  /// OBSERVED 2026-11-10: 「盘」玩偶 answers every detail with one id, so its videos replaced each other in 观看历史 and
  /// asking for the detail with that id fails (`Cannot read properties of undefined (reading 'children')`).
  VodDetail withRequestedId(String id) => item.id == id
      ? this
      : VodDetail(
          item: item.copyWith(id: id),
          lines: lines,
          actor: actor,
          director: director,
          area: area,
          lang: lang,
          content: content,
          typeName: typeName,
          responseId: item.id,
        );
}

class PagedVods {
  const PagedVods({required this.items, required this.page, required this.pageCount});

  factory PagedVods.fromJson(Map<String, dynamic> j, {String? siteKey}) => PagedVods(
        items: ((j['list'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => VodItem.fromJson(e.cast<String, dynamic>(), siteKey: siteKey))
            .toList(),
        page: int.tryParse('${j['page'] ?? 1}') ?? 1,
        pageCount: int.tryParse('${j['pagecount'] ?? 1}') ?? 1,
      );

  final List<VodItem> items;
  final int page;
  final int pageCount;
  bool get hasMore => page < pageCount;
}

/// One selectable source of the same episode (e.g. "1080P" / "720P").
class PlayQuality {
  const PlayQuality(this.name, this.url);
  final String name;
  final String url;
}

/// A sidecar subtitle file a spider returned with the play result.
class PlaySubtitle {
  const PlaySubtitle({required this.url, required this.name, this.language, this.mimeType});
  final String url;
  final String name;
  final String? language;
  final String? mimeType;
}

final _absoluteUrl = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://');

/// The `url` of a play result can be a list when the source offers several qualities. INFERRED forms (TVBox / CatVod
/// style, not read from the original): alternating `["1080P", "http://..", "720P", "http://.."]`, objects with a
/// `url` plus a name field, or a plain list of URLs. Anything else yields an empty list.
List<PlayQuality> parsePlayQualities(List<dynamic> raw) {
  String? text(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
  final maps = raw.whereType<Map>().toList();
  if (maps.isNotEmpty && maps.length == raw.length) {
    final out = <PlayQuality>[];
    for (final m in maps) {
      final url = text(m['url'] ?? m['src'] ?? m['link']);
      if (url == null) continue;
      out.add(PlayQuality(
          text(m['name'] ?? m['label'] ?? m['quality'] ?? m['title'] ?? m['n']) ?? 'Source ${out.length + 1}', url));
    }
    return out;
  }
  final strings = raw.map(text).toList();
  if (strings.isEmpty || strings.any((s) => s == null)) return const [];
  final all = strings.cast<String>();
  if (all.every(_absoluteUrl.hasMatch)) {
    return [for (var i = 0; i < all.length; i++) PlayQuality('Source ${i + 1}', all[i])];
  }
  if (all.length.isEven) {
    final pairs = <PlayQuality>[];
    for (var i = 0; i < all.length; i += 2) {
      if (_absoluteUrl.hasMatch(all[i]) || !_absoluteUrl.hasMatch(all[i + 1])) return const [];
      pairs.add(PlayQuality(all[i], all[i + 1]));
    }
    return pairs;
  }
  return const [];
}

/// `subs` / `subtitles` / `sub`: a list of objects (`url`, `name`/`label`, `lang`/`language`, `format`/`mime`/`type`),
/// one such object, or a bare URL. Same caveat as above: the shape is the TVBox convention, not observed.
List<PlaySubtitle> parsePlaySubtitles(Object? raw) {
  String? text(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
  final items = raw is List ? raw : (raw == null ? const [] : [raw]);
  final out = <PlaySubtitle>[];
  for (final e in items) {
    if (e is String) {
      final url = text(e);
      if (url != null) out.add(PlaySubtitle(url: url, name: 'Subtitle ${out.length + 1}'));
    } else if (e is Map) {
      final url = text(e['url'] ?? e['src'] ?? e['link']);
      if (url == null) continue;
      out.add(PlaySubtitle(
        url: url,
        name: text(e['name'] ?? e['label'] ?? e['title']) ?? 'Subtitle ${out.length + 1}',
        language: text(e['lang'] ?? e['language']),
        mimeType: text(e['format'] ?? e['mime'] ?? e['mimeType'] ?? e['type']),
      ));
    }
  }
  return out;
}

/// Result of resolving one episode.
class PlayResult {
  const PlayResult({
    required this.url,
    this.headers = const {},
    this.needsParse = false,
    this.audioUrl,
    this.qualities = const [],
    this.subtitles = const [],
  });

  factory PlayResult.fromJson(Map<String, dynamic> j) {
    final raw = j['url'];
    final qualities = raw is List ? parsePlayQualities(raw) : const <PlayQuality>[];
    return PlayResult(
      url: raw is List ? (qualities.isEmpty ? '' : qualities.first.url) : '${raw ?? ''}',
      headers: ((j['header'] ?? j['headers']) as Map?)?.map((k, v) => MapEntry('$k', '$v')) ?? const {},
      needsParse: '${j['parse']}' == '1',
      audioUrl: j['audio'] as String?,
      qualities: qualities,
      subtitles: parsePlaySubtitles(j['subs'] ?? j['subtitles'] ?? j['sub']),
    );
  }

  final String url;
  final Map<String, String> headers;

  /// `parse: 1` means the URL is a web page and has to be sniffed (see features/sniffer).
  final bool needsParse;
  final String? audioUrl;

  /// Alternative URLs of the same episode; [url] is the first one until [withQuality] picks another.
  final List<PlayQuality> qualities;
  final List<PlaySubtitle> subtitles;

  /// The same result with [url] taken from quality [index] (clamped; unchanged when there are no qualities).
  PlayResult withQuality(int index) {
    if (qualities.isEmpty) return this;
    final q = qualities[index.clamp(0, qualities.length - 1)];
    return PlayResult(
      url: q.url,
      headers: headers,
      needsParse: needsParse,
      audioUrl: audioUrl,
      qualities: qualities,
      subtitles: subtitles,
    );
  }
}
