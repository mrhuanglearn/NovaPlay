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
  });

  factory ProgressEntry.fromJson(Map<String, dynamic> j) => ProgressEntry(
        item: VodItem.fromJson((j['item'] as Map).cast<String, dynamic>(), siteKey: j['siteKey'] as String?),
        lineIndex: j['line'] as int? ?? 0,
        episodeIndex: j['episode'] as int? ?? 0,
        episodeName: j['episodeName'] as String? ?? '',
        positionSeconds: (j['pos'] as num?)?.toDouble() ?? 0,
        durationSeconds: (j['dur'] as num?)?.toDouble() ?? 0,
        updatedAt: j['updatedAt'] as int? ?? 0,
        qualityIndex: j['quality'] as int? ?? 0,
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
      };
}

class HistoryRepository {
  HistoryRepository({JsonStore? store, this.maxEntries = 300}) : _store = store ?? JsonStore('history.json');
  final JsonStore _store;
  final int maxEntries;
  DateTime Function() now = DateTime.now;

  Future<List<ProgressEntry>> all() async {
    final raw = await _store.read<List<dynamic>>(const []);
    final list = raw.whereType<Map>().map((e) => ProgressEntry.fromJson(e.cast<String, dynamic>())).toList();
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  Future<ProgressEntry?> find(String siteKey, String vodId) async {
    for (final e in await all()) {
      if (vodKey(e.item.siteKey ?? '', e.item.id) == vodKey(siteKey, vodId)) return e;
    }
    return null;
  }

  Future<void> record(ProgressEntry entry) async {
    final stamped = ProgressEntry(
      item: entry.item,
      lineIndex: entry.lineIndex,
      episodeIndex: entry.episodeIndex,
      episodeName: entry.episodeName,
      positionSeconds: entry.positionSeconds,
      durationSeconds: entry.durationSeconds,
      updatedAt: now().millisecondsSinceEpoch,
      qualityIndex: entry.qualityIndex,
    );
    final list = (await all())
        .where((e) => vodKey(e.item.siteKey ?? '', e.item.id) != vodKey(entry.item.siteKey ?? '', entry.item.id))
        .toList()
      ..insert(0, stamped);
    await _store.write(list.take(maxEntries).map((e) => e.toJson()).toList());
  }

  Future<void> remove(String siteKey, String vodId) async {
    final list = (await all()).where((e) => vodKey(e.item.siteKey ?? '', e.item.id) != vodKey(siteKey, vodId)).toList();
    await _store.write(list.map((e) => e.toJson()).toList());
  }

  Future<void> clear() => _store.write(<dynamic>[]);
}

class FavoriteRepository {
  FavoriteRepository({JsonStore? store}) : _store = store ?? JsonStore('favorites.json');
  final JsonStore _store;

  Future<List<VodItem>> all() async {
    final raw = await _store.read<List<dynamic>>(const []);
    return raw
        .whereType<Map>()
        .map((e) => VodItem.fromJson(e.cast<String, dynamic>(), siteKey: e['siteKey'] as String?))
        .toList();
  }

  Future<bool> isFavorite(String siteKey, String vodId) async =>
      (await all()).any((e) => vodKey(e.siteKey ?? '', e.id) == vodKey(siteKey, vodId));

  /// Returns the new state.
  Future<bool> toggle(VodItem item) async {
    final list = await all();
    final key = vodKey(item.siteKey ?? '', item.id);
    final idx = list.indexWhere((e) => vodKey(e.siteKey ?? '', e.id) == key);
    if (idx >= 0) {
      list.removeAt(idx);
    } else {
      list.insert(0, item);
    }
    await _store.write(list.map((e) => e.toJson()).toList());
    return idx < 0;
  }
}
