import '../../core/json_store.dart';
import '../../models/vod.dart';

/// Favorites, watch history and resume positions.
///
/// OBSERVED files: favorites.json, history.json, last_episode.json, play_progress.json, auto_sync_favorites.json.
/// Providers named in the Dart pool: favoriteRepositoryProvider, historyRepositoryProvider,
/// lastEpisodeRepositoryProvider, isFavoritedProvider, favoriteListProvider, historyListProvider.
/// INFERRED: JSON layout.
String vodKey(String siteKey, String vodId) => '$siteKey|$vodId';

class ProgressEntry {
  const ProgressEntry({
    required this.item,
    required this.lineIndex,
    required this.episodeIndex,
    required this.episodeName,
    required this.positionSeconds,
    required this.durationSeconds,
    required this.updatedAt,
    this.qualityIndex = 0,
    this.videoWidth,
    this.videoHeight,
  });

  static int? _posInt(Object? v) {
    final n = v is int ? v : (v is num ? v.round() : null);
    return (n != null && n > 0) ? n : null;
  }

  factory ProgressEntry.fromJson(Map<String, dynamic> j) => ProgressEntry(
        item: VodItem.fromJson((j['item'] as Map).cast<String, dynamic>(), siteKey: j['siteKey'] as String?),
        lineIndex: j['line'] as int? ?? 0,
        episodeIndex: j['episode'] as int? ?? 0,
        episodeName: j['episodeName'] as String? ?? '',
        positionSeconds: (j['pos'] as num?)?.toDouble() ?? 0,
        durationSeconds: (j['dur'] as num?)?.toDouble() ?? 0,
        updatedAt: j['updatedAt'] as int? ?? 0,
        qualityIndex: j['quality'] as int? ?? 0,
        videoWidth: _posInt(j['vw']),
        videoHeight: _posInt(j['vh']),
      );

  final VodItem item;
  final int lineIndex;
  final int episodeIndex;
  final String episodeName;
  final double positionSeconds;
  final double durationSeconds;
  final int updatedAt;

  /// The source quality picked last (index into the play result's quality list; 0 = the first, e.g. 原画).
  final int qualityIndex;

  /// Known display dimensions of this VOD (populated once probed or decoded), so resuming or playing later episodes
  /// adapts immediately without flashing the wrong orientation.
  final int? videoWidth;
  final int? videoHeight;

  double get fraction => durationSeconds <= 0 ? 0 : (positionSeconds / durationSeconds).clamp(0, 1);

  Map<String, dynamic> toJson() => {
        'siteKey': item.siteKey,
        'item': item.toJson(),
        'line': lineIndex,
        'episode': episodeIndex,
        'episodeName': episodeName,
        'pos': positionSeconds,
        'dur': durationSeconds,
        'updatedAt': updatedAt,
        'quality': qualityIndex,
        if (videoWidth != null && videoWidth! > 0) 'vw': videoWidth,
        if (videoHeight != null && videoHeight! > 0) 'vh': videoHeight,
      };
}

class HistoryRepository {
  HistoryRepository({JsonStore? store, this.maxEntries = 300}) : _store = store ?? JsonStore('history.json');
  final JsonStore _store;
  final int maxEntries;
  DateTime Function() now = DateTime.now;

  int _syncedRev = -1;
  List<ProgressEntry> _entries = [];
  final Map<String, ProgressEntry> _byKey = {};

  Future<void> _ensureLoaded() async {
    if (_syncedRev == _store.revision) return;
    final raw = await _store.read<List<dynamic>>(const []);
    final list = raw.whereType<Map>().map((e) => ProgressEntry.fromJson(e.cast<String, dynamic>())).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _entries = list;
    _byKey
      ..clear()
      ..addEntries(list.reversed.map((e) => MapEntry(vodKey(e.item.siteKey ?? '', e.item.id), e)));
    _syncedRev = _store.revision;
  }

  Future<List<ProgressEntry>> all() async {
    await _ensureLoaded();
    return List<ProgressEntry>.unmodifiable(_entries);
  }

  Future<ProgressEntry?> find(String siteKey, String vodId) async {
    await _ensureLoaded();
    return _byKey[vodKey(siteKey, vodId)];
  }

  Future<void> record(ProgressEntry entry, {bool flush = true}) async {
    await _ensureLoaded();
    final key = vodKey(entry.item.siteKey ?? '', entry.item.id);
    final prev = _byKey[key];
    final stamped = ProgressEntry(
      item: entry.item,
      lineIndex: entry.lineIndex,
      episodeIndex: entry.episodeIndex,
      episodeName: entry.episodeName,
      positionSeconds: entry.positionSeconds,
      durationSeconds: entry.durationSeconds,
      updatedAt: now().millisecondsSinceEpoch,
      qualityIndex: entry.qualityIndex,
      videoWidth: entry.videoWidth ?? prev?.videoWidth,
      videoHeight: entry.videoHeight ?? prev?.videoHeight,
    );
    _entries.removeWhere((e) => vodKey(e.item.siteKey ?? '', e.item.id) == key);
    _entries.insert(0, stamped);
    while (_entries.length > maxEntries) {
      final dropped = _entries.removeLast();
      _byKey.remove(vodKey(dropped.item.siteKey ?? '', dropped.item.id));
    }
    _byKey[key] = stamped;
    final encoded = [for (final e in _entries) e.toJson()];
    if (flush) {
      await _store.write(encoded);
    } else {
      _store.writeMemory(encoded);
    }
    _syncedRev = _store.revision;
  }

  Future<void> flush() => _store.flush();

  Future<void> remove(String siteKey, String vodId) async {
    await _ensureLoaded();
    final key = vodKey(siteKey, vodId);
    _entries.removeWhere((e) => vodKey(e.item.siteKey ?? '', e.item.id) == key);
    _byKey.remove(key);
    await _store.write([for (final e in _entries) e.toJson()]);
    _syncedRev = _store.revision;
  }

  Future<void> clear() async {
    _entries = [];
    _byKey.clear();
    await _store.write(<dynamic>[]);
    _syncedRev = _store.revision;
  }
}

class FavoriteRepository {
  FavoriteRepository({JsonStore? store}) : _store = store ?? JsonStore('favorites.json');
  final JsonStore _store;

  int _syncedRev = -1;
  List<VodItem> _items = [];
  final Set<String> _keys = {};

  Future<void> _ensureLoaded() async {
    if (_syncedRev == _store.revision) return;
    final raw = await _store.read<List<dynamic>>(const []);
    _items = raw
        .whereType<Map>()
        .map((e) => VodItem.fromJson(e.cast<String, dynamic>(), siteKey: e['siteKey'] as String?))
        .toList();
    _keys
      ..clear()
      ..addAll(_items.map((e) => vodKey(e.siteKey ?? '', e.id)));
    _syncedRev = _store.revision;
  }

  Future<List<VodItem>> all() async {
    await _ensureLoaded();
    return List<VodItem>.unmodifiable(_items);
  }

  Future<bool> isFavorite(String siteKey, String vodId) async {
    await _ensureLoaded();
    return _keys.contains(vodKey(siteKey, vodId));
  }

  /// Returns the new state.
  Future<bool> toggle(VodItem item) async {
    await _ensureLoaded();
    final key = vodKey(item.siteKey ?? '', item.id);
    final idx = _items.indexWhere((e) => vodKey(e.siteKey ?? '', e.id) == key);
    if (idx >= 0) {
      _items.removeAt(idx);
      _keys.remove(key);
    } else {
      _items.insert(0, item);
      _keys.add(key);
    }
    await _store.write([for (final e in _items) e.toJson()]);
    _syncedRev = _store.revision;
    return idx < 0;
  }
}
