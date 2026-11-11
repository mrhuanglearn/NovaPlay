import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../core/json_store.dart';
import '../core/restore_error.dart';

/// WebDAV sync of user data.
///
/// OBSERVED: UI strings ("WebDAV account name", "Isolates data when sharing one WebDAV; leave empty to use the
/// root", "WebDAV authentication failed", "connection check must not recurse the whole tree" (changelog 1.1.8)),
/// the remote folder name `uznSync`, a `manifest.json`, routes `/settings/webdav[/config]`, and the list of synced
/// documents (favorites, history, TMDB matches & switch/key/proxy, watch progress, tracking data, player settings,
/// live sources and preferences, auto-sync-favorites switch). Sensitive items (cloud-drive cookies, TMDB key) are
/// stored in plaintext - the UI warns about it. INFERRED: manifest layout and conflict policy (newest wins per file).
class WebDavConfig {
  const WebDavConfig({
    required this.url,
    required this.username,
    required this.password,
    this.subPath = '',
    this.enabled = false,
    this.types = webdavDataTypeOrder,
    this.lastSyncMs,
  });
  factory WebDavConfig.fromJson(Map<String, dynamic> j) => WebDavConfig(
        url: j['url'] as String? ?? '',
        username: j['username'] as String? ?? '',
        password: j['password'] as String? ?? '',
        subPath: j['subPath'] as String? ?? '',
        enabled: j['enabled'] as bool? ?? false,
        types: j['types'] is List
            ? (j['types'] as List).whereType<String>().where(webdavDataTypes.containsKey).toList()
            : webdavDataTypeOrder,
        lastSyncMs: (j['lastSyncMs'] as num?)?.toInt(),
      );

  final String url;
  final String username;
  final String password;

  /// 隔离名称: a folder under the WebDAV root, so several people can share one server.
  final String subPath;

  /// 启用同步: sync [types] when the app starts.
  final bool enabled;

  /// Keys of [webdavDataTypes] chosen on the settings page (OBSERVED "多端数据同步（可自选类型）").
  final List<String> types;
  final int? lastSyncMs;

  bool get isConfigured => url.trim().isNotEmpty;

  /// The documents of the chosen [types], in [syncedDocuments] order.
  List<String> get documents => documentsForTypes(types);

  WebDavConfig copyWith(
          {String? url,
          String? username,
          String? password,
          String? subPath,
          bool? enabled,
          List<String>? types,
          int? lastSyncMs}) =>
      WebDavConfig(
        url: url ?? this.url,
        username: username ?? this.username,
        password: password ?? this.password,
        subPath: subPath ?? this.subPath,
        enabled: enabled ?? this.enabled,
        types: types ?? this.types,
        lastSyncMs: lastSyncMs ?? this.lastSyncMs,
      );

  /// Stored in plaintext in `webdav_config.json`, like the original (the UI warns about it).
  Map<String, dynamic> toJson() => {
        'url': url,
        'username': username,
        'password': password,
        'subPath': subPath,
        'enabled': enabled,
        'types': types,
        if (lastSyncMs != null) 'lastSyncMs': lastSyncMs,
      };
}

/// Data types the user can pick for sync, and their documents. The grouping is this project's (the original's own
/// groups were not seen; its strings mention favorites, history, TMDB "组级整体覆盖", player and live settings).
const webdavDataTypes = <String, List<String>>{
  'favorites': ['favorites.json', 'auto_sync_favorites.json'],
  'history': ['history.json', 'play_progress.json', 'last_episode.json'],
  'tracking': ['tracking.json'],
  'tmdb': ['tmdb_settings.json', 'tmdb_refs.json'],
  'player': ['player_config.json', 'video_head_tail.json'],
  'live': ['live_sources.json', 'live_preferences.json'],
};
const webdavDataTypeOrder = <String>['favorites', 'history', 'tracking', 'tmdb', 'player', 'live'];

List<String> documentsForTypes(Iterable<String> types) {
  final wanted = {for (final t in types) ...?webdavDataTypes[t]};
  return [
    for (final d in syncedDocuments)
      if (wanted.contains(d)) d
  ];
}

class WebDavException implements Exception {
  WebDavException(this.kind, this.message);
  final String kind; // auth | connection | notFound | other
  final String message;
  @override
  String toString() => 'WebdavException: $kind: $message';
}

/// The three WebDAV operations the sync needs (an interface so the decision logic can be tested without a server).
abstract class WebDavRemote {
  Future<void> mkcol(String dir);
  Future<String?> readText(String path);
  Future<void> writeText(String path, String body);
}

class WebDavClient implements WebDavRemote {
  WebDavClient(this.config, {Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 30),
              validateStatus: (_) => true,
            )) {
    final token = base64Encode(utf8.encode('${config.username}:${config.password}'));
    _dio.options.headers['Authorization'] = 'Basic $token';
  }

  final WebDavConfig config;
  final Dio _dio;

  String _url(String relative) {
    final base = config.url.replaceAll(RegExp(r'/+$'), '');
    final sub = config.subPath.replaceAll(RegExp(r'^/+|/+$'), '');
    return [base, if (sub.isNotEmpty) sub, relative.replaceAll(RegExp(r'^/+'), '')].join('/');
  }

  void _check(Response<dynamic> r) {
    final code = r.statusCode ?? 0;
    if (code == 401 || code == 403) {
      throw WebDavException('auth', 'WebDAV authentication failed. Check your username and password');
    }
    if (code == 404) throw WebDavException('notFound', '${r.requestOptions.uri}');
    if (code >= 400) throw WebDavException('other', 'HTTP $code');
  }

  /// Depth-0 PROPFIND on the root only (never `Depth: infinity`, see changelog 1.1.8).
  Future<void> checkConnection() async {
    try {
      final r = await _dio.request<dynamic>(_url(''), options: Options(method: 'PROPFIND', headers: {'Depth': '0'}));
      _check(r);
    } on DioException catch (e) {
      throw WebDavException('connection', e.message ?? 'WebDAV connection failed');
    }
  }

  @override
  Future<void> mkcol(String dir) async {
    final r = await _dio.request<dynamic>(_url(dir), options: Options(method: 'MKCOL'));
    if (r.statusCode != 405 && r.statusCode != 201 && r.statusCode != 200) _check(r); // 405 = already exists
  }

  @override
  Future<String?> readText(String path) async {
    final r = await _dio.get<String>(_url(path), options: Options(responseType: ResponseType.plain));
    if (r.statusCode == 404) return null;
    _check(r);
    return r.data;
  }

  @override
  Future<void> writeText(String path, String body) async {
    final r = await _dio.put<dynamic>(_url(path), data: Uint8List.fromList(utf8.encode(body)));
    _check(r);
  }
}

/// Documents that take part in the sync, keyed by file name in the app data dir.
const syncedDocuments = <String>[
  'favorites.json',
  'history.json',
  'play_progress.json',
  'last_episode.json',
  'tmdb_refs.json',
  'tmdb_settings.json',
  'tracking.json',
  'player_config.json',
  'video_head_tail.json',
  'live_sources.json',
  'live_preferences.json',
  'auto_sync_favorites.json',
];

class SyncReport {
  SyncReport({List<String>? pushed, List<String>? pulled})
      : pushed = pushed ?? [],
        pulled = pulled ?? [];
  final List<String> pushed;
  final List<String> pulled;
}

enum SyncAction { none, push, pull }

/// What to do with one document.
///
/// [localMs]/[remoteMs] are the current modification times, [lastLocalMs]/[lastRemoteMs] what both were right after
/// the previous sync of this document (0 = never synced). A side counts as changed only if it moved since then;
/// comparing raw timestamps instead would bounce a freshly pulled file straight back to the server, because writing
/// it locally gives it a newer mtime than the remote manifest entry.
SyncAction decideSync({required int localMs, required int remoteMs, int lastLocalMs = 0, int lastRemoteMs = 0}) {
  final localChanged = localMs > lastLocalMs;
  final remoteChanged = remoteMs > lastRemoteMs;
  if (localChanged && !remoteChanged) return SyncAction.push;
  if (remoteChanged && !localChanged) return SyncAction.pull;
  if (localChanged && remoteChanged) return localMs > remoteMs ? SyncAction.push : SyncAction.pull; // newest wins
  return SyncAction.none;
}

/// Newest-wins merge per document, driven by `uzvSync/manifest.json` = {"file": updatedAtMs}.
/// Per-document state of the previous sync lives in `webdav_sync_state.json` ({file: {"local": ms, "remote": ms}}).
class WebDavSync {
  WebDavSync(this.client, {JsonStore Function(String file)? storeFor, JsonStore? state})
      : _storeFor = storeFor ?? JsonStore.new,
        _state = state ?? JsonStore('webdav_sync_state.json');
  final WebDavRemote client;
  final JsonStore Function(String) _storeFor;
  final JsonStore _state;

  static const folder = 'uzvSync';

  /// Syncs [documents] (default: every synced document).
  Future<SyncReport> sync({Iterable<String>? documents}) async {
    await client.mkcol(folder);
    final remoteRaw = await client.readText('$folder/manifest.json');
    final remote = <String, int>{
      if (remoteRaw != null) ...(jsonDecode(remoteRaw) as Map).map((k, v) => MapEntry('$k', (v as num).toInt())),
    };
    final state = (await _state.read<Map<String, dynamic>>(<String, dynamic>{}))
        .map((k, v) => MapEntry(k, (v as Map).cast<String, dynamic>()));
    final manifest = Map<String, int>.from(remote);
    final report = SyncReport();
    var manifestDirty = false;
    for (final file in documents ?? syncedDocuments) {
      final store = _storeFor(file);
      final localMs = await store.modifiedMs();
      final remoteMs = remote[file] ?? 0;
      final last = state[file];
      final action = decideSync(
        localMs: localMs,
        remoteMs: remoteMs,
        lastLocalMs: (last?['local'] as num?)?.toInt() ?? 0,
        lastRemoteMs: (last?['remote'] as num?)?.toInt() ?? 0,
      );
      if (action == SyncAction.push) {
        final doc = await store.read<Object?>(null);
        if (doc == null) continue;
        await client.writeText('$folder/$file', jsonEncode(doc));
        manifest[file] = localMs;
        manifestDirty = true;
        state[file] = {'local': localMs, 'remote': localMs};
        report.pushed.add(file);
      } else if (action == SyncAction.pull) {
        final text = await client.readText('$folder/$file');
        if (text == null) continue;
        await store.write(jsonDecode(text));
        state[file] = {
          'local': await store.modifiedMs(),
          'remote': remoteMs
        }; // our own write must not count as a change
        report.pulled.add(file);
      }
    }
    if (manifestDirty) await client.writeText('$folder/manifest.json', jsonEncode(manifest));
    await _state.write(state);
    return report;
  }

  /// "Restore from WebDAV": takes the remote copy of every document that exists there, overwriting local data. A
  /// [RestoreWriteException] means some documents were replaced; any other error, that none were.
  Future<SyncReport> restoreAll({Iterable<String>? documents}) async {
    final remoteRaw = await client.readText('$folder/manifest.json');
    if (remoteRaw == null) return SyncReport();
    final remote = (jsonDecode(remoteRaw) as Map).map((k, v) => MapEntry('$k', (v as num).toInt()));
    final state = (await _state.read<Map<String, dynamic>>(<String, dynamic>{}))
        .map((k, v) => MapEntry(k, (v as Map).cast<String, dynamic>()));
    // Download and decode everything first: a server or format error then leaves every local document as it was.
    final docs = <String, (Object?, int)>{};
    for (final file in documents ?? syncedDocuments) {
      final remoteMs = remote[file];
      if (remoteMs == null) continue;
      final text = await client.readText('$folder/$file');
      if (text == null) continue;
      docs[file] = (jsonDecode(text), remoteMs);
    }
    final report = SyncReport();
    for (final MapEntry(key: file, value: (doc, remoteMs)) in docs.entries) {
      final store = _storeFor(file);
      try {
        await store.write(doc);
        state[file] = {'local': await store.modifiedMs(), 'remote': remoteMs};
      } catch (e) {
        throw RestoreWriteException(file, e);
      }
      report.pulled.add(file);
    }
    await _state.write(state);
    return report;
  }
}
