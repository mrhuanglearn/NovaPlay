import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/json_store.dart';
import 'm3u_epg.dart';

/// How often a playlist is downloaded again (OBSERVED 自动刷新: 关闭 / 每次 / 24 小时, default 24 小时).
enum LiveRefresh { off, always, daily }

const defaultLiveUserAgent = 'okhttp';

/// One IPTV playlist (M3U). File `live_sources.json` (OBSERVED name; layout inferred). The original's 添加直播源 page has
/// 名称, 源地址, User-Agent (default okhttp) and 自动刷新; [epgUrl] is kept from earlier versions of this project.
class LiveSource {
  const LiveSource({
    required this.id,
    required this.name,
    required this.url,
    this.epgUrl = '',
    this.userAgent = defaultLiveUserAgent,
    this.refresh = LiveRefresh.daily,
  });

  factory LiveSource.fromJson(Map<String, dynamic> j) => LiveSource(
        id: '${j['id']}',
        name: j['name'] as String? ?? '',
        url: j['url'] as String? ?? '',
        epgUrl: j['epgUrl'] as String? ?? '',
        userAgent: j['userAgent'] as String? ?? defaultLiveUserAgent,
        refresh: LiveRefresh.values.where((r) => r.name == j['refresh']).firstOrNull ?? LiveRefresh.daily,
      );

  final String id;
  final String name;
  final String url;
  final String epgUrl;
  final String userAgent;
  final LiveRefresh refresh;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'url': url, 'epgUrl': epgUrl, 'userAgent': userAgent, 'refresh': refresh.name};
}

/// Keeps the last download of each playlist (`live_cache/<id>.m3u`) and decides when to fetch it again.
class LivePlaylistLoader {
  LivePlaylistLoader({required this.fetch, Directory? cacheDir, DateTime Function()? now})
      : _cacheDir = cacheDir,
        _now = now ?? DateTime.now;
  final Future<String> Function(LiveSource source) fetch;
  final Directory? _cacheDir;
  final DateTime Function() _now;

  Future<Directory> _dir() async => _cacheDir ?? Directory(p.join((await getApplicationSupportDirectory()).path, 'live_cache'));

  Future<File> _file(String id) async {
    final dir = await _dir();
    await dir.create(recursive: true);
    return File(p.join(dir.path, '${id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.m3u'));
  }

  /// The cached copy when it is fresh enough for [LiveSource.refresh], else a new download (falling back to the
  /// cached copy when the download fails).
  Future<String> load(LiveSource source) async {
    final f = await _file(source.id);
    final cached = await f.exists();
    final fresh = switch (source.refresh) {
      LiveRefresh.off => cached,
      LiveRefresh.always => false,
      LiveRefresh.daily => cached && _now().difference(await f.lastModified()) < const Duration(hours: 24),
    };
    if (fresh) return f.readAsString();
    try {
      final text = await fetch(source);
      await f.writeAsString(text, flush: true);
      return text;
    } catch (_) {
      if (cached) return f.readAsString();
      rethrow;
    }
  }

  /// Stores a playlist that was just downloaded (验证并保存).
  Future<void> store(String id, String text) async => (await _file(id)).writeAsString(text, flush: true);

  Future<void> remove(String id) async {
    final f = await _file(id);
    if (await f.exists()) await f.delete();
  }

  /// 数据清理 → 直播列表缓存: drops every saved playlist. The next [load] downloads again, also for sources whose
  /// auto-refresh is off (a missing file is never "fresh").
  Future<void> clearAll() async {
    final dir = await _dir();
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

class LiveSourceRepository {
  LiveSourceRepository({JsonStore? store}) : _store = store ?? JsonStore('live_sources.json');
  final JsonStore _store;

  Future<List<LiveSource>> all() async {
    final raw = await _store.read<List<dynamic>>(const []);
    return raw.whereType<Map>().map((e) => LiveSource.fromJson(e.cast<String, dynamic>())).toList();
  }

  Future<void> upsert(LiveSource source) async {
    final list = await all();
    final i = list.indexWhere((s) => s.id == source.id);
    i >= 0 ? list[i] = source : list.add(source);
    await _store.write(list.map((s) => s.toJson()).toList());
  }

  Future<void> remove(String id) async => _store.write((await all()).where((s) => s.id != id).map((s) => s.toJson()).toList());
}

/// `live_preferences.json`: groups the user hid, the last source, the global guide (OBSERVED 全局 EPG 地址:
/// "直播源未自带 EPG 时使用").
class LivePreferences {
  const LivePreferences({this.blockedGroups = const {}, this.lastSourceId, this.globalEpgUrl = ''});

  factory LivePreferences.fromJson(Map<String, dynamic> j) => LivePreferences(
        blockedGroups: ((j['blockedGroups'] as List?) ?? const []).cast<String>().toSet(),
        lastSourceId: j['lastSourceId'] as String?,
        globalEpgUrl: j['globalEpgUrl'] as String? ?? '',
      );

  final Set<String> blockedGroups;
  final String? lastSourceId;
  final String globalEpgUrl;

  LivePreferences copyWith({Set<String>? blockedGroups, String? lastSourceId, String? globalEpgUrl}) => LivePreferences(
        blockedGroups: blockedGroups ?? this.blockedGroups,
        lastSourceId: lastSourceId ?? this.lastSourceId,
        globalEpgUrl: globalEpgUrl ?? this.globalEpgUrl,
      );

  Map<String, dynamic> toJson() => {'blockedGroups': blockedGroups.toList()..sort(), 'lastSourceId': lastSourceId, 'globalEpgUrl': globalEpgUrl};
}

/// The guide for a source: its own (older configurations), the one its playlist names, else the global one.
String? guideUrlFor(LiveSource source, String playlist, LivePreferences prefs) {
  if (source.epgUrl.trim().isNotEmpty) return source.epgUrl.trim();
  final own = m3uGuideUrl(playlist);
  if (own != null) return own;
  return prefs.globalEpgUrl.trim().isEmpty ? null : prefs.globalEpgUrl.trim();
}

class LivePreferencesRepository {
  LivePreferencesRepository({JsonStore? store}) : _store = store ?? JsonStore('live_preferences.json');
  final JsonStore _store;

  Future<LivePreferences> load() async => LivePreferences.fromJson(await _store.read<Map<String, dynamic>>(<String, dynamic>{}));
  Future<void> save(LivePreferences p) => _store.write(p.toJson());
}

const otherGroup = 'Other';

String groupOf(LiveChannel c) => (c.group == null || c.group!.trim().isEmpty) ? otherGroup : c.group!.trim();

/// Groups in order of first appearance, without the blocked ones.
List<String> liveGroups(List<LiveChannel> channels, {Set<String> blocked = const {}}) {
  final seen = <String>{};
  return [
    for (final c in channels)
      if (!blocked.contains(groupOf(c)) && seen.add(groupOf(c))) groupOf(c),
  ];
}

/// Channels of [group] (null = every visible group), filtered by a case-insensitive [query].
List<LiveChannel> visibleChannels(List<LiveChannel> channels, {Set<String> blocked = const {}, String? group, String query = ''}) {
  final q = query.trim().toLowerCase();
  return [
    for (final c in channels)
      if (!blocked.contains(groupOf(c)) && (group == null || groupOf(c) == group) && (q.isEmpty || c.name.toLowerCase().contains(q))) c,
  ];
}
