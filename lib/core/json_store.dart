import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Object? _cloneJson(Object? v) {
  if (v is Map) return <String, dynamic>{for (final e in v.entries) '${e.key}': _cloneJson(e.value)};
  if (v is List) return <dynamic>[for (final e in v) _cloneJson(e)];
  return v;
}

class _JsonStoreCore {
  _JsonStoreCore(this.fileName, this.baseDir);

  static final Map<String, _JsonStoreCore> _shared = {};

  static _JsonStoreCore shared(String fileName, Directory? baseDir) {
    final key = '${baseDir == null ? '<default>' : p.normalize(baseDir.absolute.path)}|$fileName';
    return _shared.putIfAbsent(key, () => _JsonStoreCore(fileName, baseDir));
  }

  static void clearAllMemoryCaches() {
    for (final c in _shared.values) {
      c.invalidateMemory();
    }
  }

  final String fileName;
  final Directory? baseDir;

  bool hasCache = false;
  Object? cached;

  Future<void> opQueue = Future<void>.value();
  Future<void> diskQueue = Future<void>.value();
  int revision = 0;
  int writeEpoch = 0;
  int flushedEpoch = 0;
  Object? pendingDiskJson;
  Timer? debounceTimer;
  Completer<void>? debounceCompleter;

  void invalidateMemory() {
    debounceTimer?.cancel();
    debounceTimer = null;
    if (debounceCompleter != null && !debounceCompleter!.isCompleted) {
      debounceCompleter!.complete();
    }
    debounceCompleter = null;
    hasCache = false;
    cached = null;
    flushedEpoch = writeEpoch;
    revision++;
  }
}

/// Persists one JSON document per file in the app support directory.
///
/// Shares a per-file singleton state (in-memory cache + coalesced serial disk writes) across all `JsonStore` instances
/// targeting the same file so concurrent callers never race or re-parse unchanged files on the UI isolate.
class JsonStore {
  JsonStore(this.fileName, {Directory? baseDir}) : _baseDir = baseDir;

  /// Clears all in-memory caches (used by factory reset and tests wiping directories out-of-band).
  static void clearMemoryCaches() => _JsonStoreCore.clearAllMemoryCaches();

  final String fileName;
  final Directory? _baseDir;

  late final _JsonStoreCore _core = runtimeType == JsonStore
      ? _JsonStoreCore.shared(fileName, _baseDir)
      : _JsonStoreCore(fileName, _baseDir);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is JsonStore && runtimeType == other.runtimeType && identical(_core, other._core));

  @override
  int get hashCode => Object.hash(runtimeType, identityHashCode(_core));

  /// Monotonic counter incremented whenever this store's content changes in memory or on disk.
  int get revision => _core.revision;

  Future<Directory> resolveBaseDir() async {
    final dir = _baseDir ?? await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> _file() async {
    final dir = await resolveBaseDir();
    return File(p.join(dir.path, fileName));
  }

  /// Returns the decoded document (from memory cache after first load) or [fallback] if missing / corrupt.
  Future<T> read<T>(T fallback) async {
    final core = _core;
    if (core.hasCache) {
      final cloned = _cloneJson(core.cached);
      return cloned is T ? cloned : fallback;
    }
    try {
      final f = await _file();
      if (!await f.exists()) return fallback;
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return fallback;
      final decoded = jsonDecode(raw);
      if (!core.hasCache) {
        core.cached = _cloneJson(decoded);
        core.hasCache = true;
      }
      final out = _cloneJson(core.cached);
      return out is T ? out : fallback;
    } catch (_) {
      return fallback;
    }
  }

  /// Serialised atomic read-modify-write on the shared store state so concurrent writers never clobber keys.
  Future<T> update<T>(T fallback, FutureOr<T> Function(T current) transform) {
    final core = _core;
    final done = Completer<T>();
    core.opQueue = core.opQueue.then((_) async {
      try {
        final cur = await read<T>(fallback);
        final next = await transform(cur);
        await write(next);
        done.complete(next);
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  /// Updates the in-memory cache immediately and coalesces concurrent disk writes atomically (`tmp` + `rename`).
  Future<void> write(Object? json) {
    final core = _core;
    core.debounceTimer?.cancel();
    core.debounceTimer = null;
    final waiter = core.debounceCompleter;
    core.debounceCompleter = null;

    final snap = _cloneJson(json);
    core.cached = snap;
    core.hasCache = true;
    core.revision++;
    final targetEpoch = ++core.writeEpoch;
    core.pendingDiskJson = snap;

    core.diskQueue = core.diskQueue.then((_) async {
      if (core.flushedEpoch >= targetEpoch) return;
      final toWrite = core.pendingDiskJson;
      final epochNow = core.writeEpoch;
      final f = await _file();
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(toWrite), flush: true);
      await tmp.rename(f.path);
      core.flushedEpoch = epochNow;
    });
    if (waiter != null && !waiter.isCompleted) {
      core.diskQueue.then((_) {
        if (!waiter.isCompleted) waiter.complete();
      }, onError: (Object e, StackTrace st) {
        if (!waiter.isCompleted) waiter.completeError(e, st);
      });
    }
    return core.diskQueue;
  }

  /// Updates memory immediately without scheduling a timer or writing to disk until [flush] or [write] runs.
  void writeMemory(Object? json) {
    final core = _core;
    final snap = _cloneJson(json);
    core.cached = snap;
    core.hasCache = true;
    core.pendingDiskJson = snap;
    core.writeEpoch++;
    core.revision++;
  }

  /// Updates memory immediately (0ms UI cost) and schedules a coalesced disk flush after [delay].
  void writeBuffered(Object? json, {Duration delay = const Duration(seconds: 10)}) {
    final core = _core;
    final snap = _cloneJson(json);
    core.cached = snap;
    core.hasCache = true;
    core.pendingDiskJson = snap;
    core.writeEpoch++;
    core.revision++;
    core.debounceCompleter ??= Completer<void>();
    core.debounceTimer?.cancel();
    core.debounceTimer = Timer(delay, () {
      core.debounceTimer = null;
      unawaited(write(core.cached));
    });
  }

  /// Flushes any buffered or memory-only write to disk immediately.
  Future<void> flush() {
    final core = _core;
    if (core.debounceTimer != null || core.flushedEpoch < core.writeEpoch) {
      return write(core.cached);
    }
    return core.diskQueue;
  }

  /// Last write time in epoch ms, 0 when the file does not exist. Drives the WebDAV "what changed" decision.
  Future<int> modifiedMs() async {
    await flush();
    final f = await _file();
    return await f.exists() ? (await f.lastModified()).millisecondsSinceEpoch : 0;
  }

  Future<void> delete() async {
    final core = _core;
    core.invalidateMemory();
    await core.diskQueue;
    final f = await _file();
    if (await f.exists()) await f.delete();
  }
}
