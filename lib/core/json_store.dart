import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Persists one JSON document per file in the app support directory.
///
/// OBSERVED: the original keeps its state in plain JSON files with these names:
/// favorites.json, history.json, last_episode.json, live_preferences.json, live_sources.json,
/// player_config.json, play_progress.json, subscription_profiles.json, subscriptions.json,
/// tmdb_refs.json, tmdb_settings.json, tracking.json, video_head_tail.json,
/// danmu_service_config.json, auto_sync_favorites.json.
class JsonStore {
  JsonStore(this.fileName, {Directory? baseDir}) : _baseDir = baseDir;

  final String fileName;
  final Directory? _baseDir;
  Future<void> _queue = Future<void>.value();

  Future<Directory> resolveBaseDir() async {
    final dir = _baseDir ?? await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> _file() async {
    final dir = await resolveBaseDir();
    return File(p.join(dir.path, fileName));
  }

  /// Returns the decoded document or [fallback] if the file is missing / corrupt.
  Future<T> read<T>(T fallback) async {
    try {
      final f = await _file();
      if (!await f.exists()) return fallback;
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return fallback;
      return jsonDecode(raw) as T;
    } catch (_) {
      return fallback;
    }
  }

  /// Atomic write (temp file + rename), serialised per store so concurrent saves cannot interleave.
  Future<void> write(Object? json) {
    _queue = _queue.then((_) async {
      final f = await _file();
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(const JsonEncoder.withIndent(' ').convert(json), flush: true);
      await tmp.rename(f.path);
    });
    return _queue;
  }

  /// Last write time in epoch ms, 0 when the file does not exist. Drives the WebDAV "what changed" decision.
  Future<int> modifiedMs() async {
    final f = await _file();
    return await f.exists() ? (await f.lastModified()).millisecondsSinceEpoch : 0;
  }

  Future<void> delete() async {
    final f = await _file();
    if (await f.exists()) await f.delete();
  }
}
