import '../../core/json_store.dart';
import '../../services/tmdb_client.dart';

/// The TMDB entry the user (or the automatic match) picked for a video, keyed like the favorites (`tmdb_refs.json`).
class TmdbRefsRepository {
  TmdbRefsRepository({JsonStore? store}) : _store = store ?? JsonStore('tmdb_refs.json');
  final JsonStore _store;

  Future<TmdbMatch?> get(String key) async {
    final all = await _store.read<Map<String, dynamic>>(<String, dynamic>{});
    final e = all[key];
    return e is Map ? TmdbMatch.fromJson(e.cast<String, dynamic>()) : null;
  }

  Future<void> set(String key, TmdbMatch match) async {
    final all = await _store.read<Map<String, dynamic>>(<String, dynamic>{});
    all[key] = match.toJson();
    await _store.write(all);
  }

  Future<void> remove(String key) async {
    final all = await _store.read<Map<String, dynamic>>(<String, dynamic>{});
    if (all.remove(key) != null) await _store.write(all);
  }
}
