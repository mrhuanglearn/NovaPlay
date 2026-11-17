import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../core/app_http.dart';
import '../../core/json_store.dart';

/// Offline video download (changelog 1.1.2: batch download, resumable, keeps running in the background,
/// downloaded episodes play from the local cache; 1.1.4: list grouped by show).
///
/// The shipped app supports HLS and direct files; this implementation handles both. Resume works at segment
/// granularity: finished segments stay on disk and are skipped on restart. INFERRED details: file layout and
/// states (the original's classes are in the AOT snapshot and were not recovered).
enum DownloadState { queued, running, paused, done, failed }

class DownloadTask {
  DownloadTask(
      {required this.id,
      required this.title,
      required this.url,
      required this.dir,
      this.headers = const {},
      this.group});
  final String id;
  final String title;
  final String url;
  final String dir;
  final Map<String, String> headers;

  /// Show name; the UI aggregates tasks that share a group.
  final String? group;
  DownloadState state = DownloadState.queued;
  int total = 0;
  int completed = 0;
  String? error;

  /// File to hand to the player once `state == done`.
  String? localPlaylist;
  double get progress => total == 0 ? 0 : completed / total;

  factory DownloadTask.fromJson(Map<String, dynamic> j) => DownloadTask(
        id: j['id'] as String,
        title: j['title'] as String,
        url: j['url'] as String,
        dir: j['dir'] as String,
        headers: ((j['headers'] as Map?) ?? const {}).map((k, v) => MapEntry('$k', '$v')),
        group: j['group'] as String?,
      )
        ..state = DownloadState.values.where((s) => s.name == j['state']).firstOrNull ?? DownloadState.paused
        ..total = (j['total'] as num?)?.toInt() ?? 0
        ..completed = (j['completed'] as num?)?.toInt() ?? 0
        ..localPlaylist = j['localPlaylist'] as String?;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'url': url,
        'dir': dir,
        'headers': headers,
        'group': group,
        'state': state.name,
        'total': total,
        'completed': completed,
        'localPlaylist': localPlaylist,
      };
}

/// Resolves a (possibly relative) URI inside a playlist.
Uri resolveUri(Uri base, String ref) => base.resolve(ref);

/// Extracts media segment URIs (and the key URI, if any) from an HLS media playlist.
class HlsPlaylist {
  HlsPlaylist(this.lines);
  final List<String> lines;

  bool get isMaster => lines.any((l) => l.startsWith('#EXT-X-STREAM-INF'));

  List<String> get segmentRefs => lines.where((l) => l.trim().isNotEmpty && !l.startsWith('#')).toList();

  /// Best variant of a master playlist (highest BANDWIDTH).
  String? bestVariant() {
    int best = -1;
    String? bestRef;
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
      final bw = int.tryParse(RegExp(r'BANDWIDTH=(\d+)').firstMatch(lines[i])?.group(1) ?? '') ?? 0;
      final ref = lines.skip(i + 1).firstWhere((l) => l.trim().isNotEmpty && !l.startsWith('#'), orElse: () => '');
      if (ref.isNotEmpty && bw > best) {
        best = bw;
        bestRef = ref;
      }
    }
    return bestRef;
  }

  static final _uriAttrPattern = RegExp(r'URI="([^"]+)"');

  /// Unique auxiliary URIs referenced by `#EXT-X-KEY` (excluding `METHOD=NONE`) and `#EXT-X-MAP`.
  Map<String, String> auxiliaryAssets() {
    final map = <String, String>{};
    var keyIdx = 0;
    var mapIdx = 0;
    for (final raw in lines) {
      final line = raw.trim();
      if (line.startsWith('#EXT-X-KEY:')) {
        if (RegExp(r'METHOD=NONE\b', caseSensitive: false).hasMatch(line)) continue;
        final ref = _uriAttrPattern.firstMatch(line)?.group(1)?.trim();
        if (ref != null && ref.isNotEmpty && !map.containsKey(ref)) {
          map[ref] = 'key_${keyIdx++}.bin';
        }
      } else if (line.startsWith('#EXT-X-MAP:')) {
        final ref = _uriAttrPattern.firstMatch(line)?.group(1)?.trim();
        if (ref != null && ref.isNotEmpty && !map.containsKey(ref)) {
          map[ref] = 'map_${mapIdx++}.bin';
        }
      }
    }
    return map;
  }

  /// Rewrites every segment reference to `seg_00000.ts`-style local names and rewrites KEY/MAP URIs to [auxMap].
  String rewriteLocal([Map<String, String> auxMap = const {}]) {
    var n = 0;
    return lines.map((l) {
      final trimmed = l.trim();
      if (trimmed.isEmpty) return l;
      if (trimmed.startsWith('#EXT-X-KEY:') || trimmed.startsWith('#EXT-X-MAP:')) {
        return l.replaceAllMapped(_uriAttrPattern, (m) {
          final local = auxMap[m.group(1)?.trim()];
          return local == null ? m.group(0)! : 'URI="$local"';
        });
      }
      if (trimmed.startsWith('#')) return l;
      return 'seg_${(n++).toString().padLeft(5, '0')}.ts';
    }).join('\n');
  }
}

class DownloadManager {
  DownloadManager({
    Dio? dio,
    this.concurrency = 3,
    this.maxActiveTasks = 2,
    JsonStore? store,
  })  : _dio = dio ?? createAppDio(connectTimeout: const Duration(seconds: 15), receiveTimeout: const Duration(seconds: 60)),
        _store = store;
  final Dio _dio;
  final JsonStore? _store;
  final int concurrency;
  final int maxActiveTasks;

  Duration? get dioConnectTimeout => _dio.options.connectTimeout;
  final Map<String, DownloadTask> tasks = {};
  final _updates = StreamController<DownloadTask>.broadcast();
  final _cancel = <String, CancelToken>{};
  final List<String> _pendingIds = [];
  int _activeTaskCount = 0;

  Stream<DownloadTask> get updates => _updates.stream;

  /// Restores the task list saved by an earlier run. Anything that was running comes back paused (resume is manual);
  /// finished segments / the partial file are still on disk, so resuming continues where it stopped.
  Future<void> load() async {
    final store = _store;
    if (store == null) return;
    for (final e in (await store.read<List<dynamic>>(const [])).whereType<Map>()) {
      final t = DownloadTask.fromJson(e.cast<String, dynamic>());
      if (t.state == DownloadState.running || t.state == DownloadState.queued) t.state = DownloadState.paused;
      tasks.putIfAbsent(t.id, () => t);
    }
  }

  Future<void> _persist() async => _store?.write([for (final t in tasks.values) t.toJson()]);

  DownloadTask enqueue(DownloadTask t) {
    t.state = DownloadState.queued;
    tasks[t.id] = t;
    _updates.add(t);
    unawaited(_persist());
    _enqueueId(t.id);
    return t;
  }

  void _enqueueId(String id) {
    if (!_pendingIds.contains(id)) _pendingIds.add(id);
    _pumpQueue();
  }

  void _pumpQueue() {
    while (_activeTaskCount < maxActiveTasks && _pendingIds.isNotEmpty) {
      final nextId = _pendingIds.removeAt(0);
      final t = tasks[nextId];
      if (t == null || t.state != DownloadState.queued) continue;
      _activeTaskCount++;
      unawaited(_run(t).whenComplete(() {
        _activeTaskCount--;
        _pumpQueue();
      }));
    }
  }

  void pause(String id) {
    _pendingIds.remove(id);
    _cancel[id]?.cancel('paused');
    tasks[id]?.state = DownloadState.paused;
    unawaited(_persist());
  }

  /// Stops every running download without saving anything (重置应用 deletes the files right after).
  void cancelAll() {
    _pendingIds.clear();
    for (final token in _cancel.values) {
      token.cancel('reset');
    }
  }

  /// Cancels the task and forgets it; [deleteFiles] also removes what was downloaded.
  Future<void> remove(String id, {bool deleteFiles = true}) async {
    _pendingIds.remove(id);
    _cancel[id]?.cancel('removed');
    final t = tasks.remove(id);
    await _persist();
    if (t != null && deleteFiles) {
      final dir = Directory(t.dir);
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }

  void resume(String id) {
    final t = tasks[id];
    if (t != null && (t.state == DownloadState.paused || t.state == DownloadState.failed)) {
      t.state = DownloadState.queued;
      _updates.add(t);
      _enqueueId(id);
    }
  }

  Future<void> _run(DownloadTask t) async {
    final token = _cancel[t.id] = CancelToken();
    t.state = DownloadState.running;
    t.error = null;
    _updates.add(t);
    try {
      await Directory(t.dir).create(recursive: true);
      if (t.url.toLowerCase().contains('.m3u8')) {
        await _hls(t, token);
      } else {
        await _file(t, token);
      }
      t.state = DownloadState.done;
    } on DioException catch (e) {
      t.state = CancelToken.isCancel(e) ? DownloadState.paused : DownloadState.failed;
      t.error = e.message;
    } catch (e) {
      t.state = DownloadState.failed;
      t.error = '$e';
    }
    _updates.add(t);
    unawaited(_persist());
  }

  Future<void> _file(DownloadTask t, CancelToken token) async {
    final target = File(p.join(t.dir, 'video.mp4'));
    final existing = await target.exists() ? await target.length() : 0;
    final res = await _dio.get<ResponseBody>(
      t.url,
      cancelToken: token,
      options: Options(
        responseType: ResponseType.stream,
        headers: {...t.headers, if (existing > 0) 'Range': 'bytes=$existing-'},
        validateStatus: (code) => code != null && ((code >= 200 && code < 300) || (existing > 0 && code == 416)),
      ),
    );
    if (existing > 0 && res.statusCode == 416) {
      t.completed = existing;
      t.total = existing;
      t.localPlaylist = target.path;
      return;
    }
    final resumed = existing > 0 && res.statusCode == 206;
    final baseOffset = resumed ? existing : 0;
    final contentLength = int.tryParse(res.headers.value('content-length') ?? '') ?? 0;
    t.total = contentLength > 0 ? contentLength + baseOffset : baseOffset;
    final sink = target.openWrite(mode: resumed ? FileMode.append : FileMode.write);
    t.completed = baseOffset;
    var unFlushedBytes = 0;
    final throttle = Stopwatch()..start();
    try {
      await for (final chunk in res.data!.stream) {
        sink.add(chunk);
        t.completed += chunk.length;
        unFlushedBytes += chunk.length;
        if (unFlushedBytes >= 512 * 1024) {
          unFlushedBytes = 0;
          await sink.flush();
        }
        if (throttle.elapsedMilliseconds >= 200) {
          throttle.reset();
          _updates.add(t);
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    t.localPlaylist = target.path;
  }

  Future<void> _hls(DownloadTask t, CancelToken token) async {
    var playlistUri = Uri.parse(t.url);
    var text =
        (await _dio.get<String>(playlistUri.toString(), cancelToken: token, options: Options(headers: t.headers)))
                .data ??
            '';
    var parsed = HlsPlaylist(text.split(RegExp(r'\r?\n')));
    if (parsed.isMaster) {
      final variant = parsed.bestVariant();
      if (variant == null) throw StateError('empty master playlist');
      playlistUri = resolveUri(playlistUri, variant);
      text = (await _dio.get<String>(playlistUri.toString(), cancelToken: token, options: Options(headers: t.headers)))
              .data ??
          '';
      parsed = HlsPlaylist(text.split(RegExp(r'\r?\n')));
    }
    final auxAssets = parsed.auxiliaryAssets();
    for (final entry in auxAssets.entries) {
      final auxFile = File(p.join(t.dir, entry.value));
      if (!(await auxFile.exists() && await auxFile.length() > 0)) {
        final partPath = '${auxFile.path}.part';
        await _dio.download(resolveUri(playlistUri, entry.key).toString(), partPath,
            cancelToken: token, options: Options(headers: t.headers));
        await File(partPath).rename(auxFile.path);
      }
    }
    final refs = parsed.segmentRefs;
    t.total = refs.length;
    t.completed = 0;
    var next = 0;
    final throttle = Stopwatch()..start();
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= refs.length) return;
        final file = File(p.join(t.dir, 'seg_${i.toString().padLeft(5, '0')}.ts'));
        if (!(await file.exists() && await file.length() > 0)) {
          await _dio.download(resolveUri(playlistUri, refs[i]).toString(), '${file.path}.part',
              cancelToken: token, options: Options(headers: t.headers));
          await File('${file.path}.part').rename(file.path);
        }
        t.completed++;
        if (throttle.elapsedMilliseconds >= 200 || t.completed == t.total) {
          throttle.reset();
          _updates.add(t);
        }
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
    final local = File(p.join(t.dir, 'index.m3u8'));
    await local.writeAsString(parsed.rewriteLocal(auxAssets));
    t.localPlaylist = local.path;
  }
}
