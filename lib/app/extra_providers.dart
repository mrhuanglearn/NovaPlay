import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_process.dart';
import '../core/json_store.dart';
import '../features/downloads/download_manager.dart';
import '../features/library/tmdb_refs.dart';
import '../features/library/watch_repository.dart';
import '../features/media_server/media_source.dart';
import '../features/reset/app_reset_service.dart';
import '../features/tracking/tracking_service.dart';
import '../services/media_server_client.dart';
import '../services/tmdb_client.dart';
import 'providers.dart';

final tmdbRefsRepositoryProvider = Provider((ref) => TmdbRefsRepository());

typedef TmdbKey = ({String siteKey, String vodId, String title});

/// TMDB entry for a detail page: the saved choice, else an automatic search that gives up after the configured wait.
final tmdbMatchProvider = FutureProvider.family<TmdbMatch?, TmdbKey>((ref, k) async {
  final key = vodKey(k.siteKey, k.vodId);
  final refs = ref.watch(tmdbRefsRepositoryProvider);
  final saved = await refs.get(key);
  if (saved != null) return saved;
  final client = await ref.watch(tmdbProvider.future);
  if (client == null) return null;
  try {
    final hits = await client.searchMulti(k.title).timeout(Duration(seconds: client.settings.matchWaitSeconds));
    if (hits.isEmpty) return null;
    await refs.set(key, hits.first);
    return hits.first;
  } catch (_) {
    return null; // the page simply shows without TMDB data
  }
});

final trackingStoreProvider = Provider((ref) => TrackingStore());
final FutureProvider<List<TrackedShow>> trackingListProvider =
    FutureProvider<List<TrackedShow>>((ref) => ref.watch(trackingStoreProvider).all());

final autoSyncFavoritesStoreProvider = Provider((ref) => JsonStore('auto_sync_favorites.json'));

/// "Favorites join the tracking calendar automatically" (OBSERVED file auto_sync_favorites.json; layout inferred).
final FutureProvider<bool> autoSyncFavoritesProvider = FutureProvider<bool>((ref) async {
  final j = await ref.watch(autoSyncFavoritesStoreProvider).read<Map<String, dynamic>>(<String, dynamic>{});
  return j['enabled'] == true;
});

/// Episodes airing in the week starting at the given Monday.
final trackingWeekProvider = FutureProvider.family<List<CalendarEntry>, DateTime>((ref, weekStartDay) async {
  final client = await ref.watch(tmdbProvider.future);
  if (client == null) return const [];
  return TrackingCalendar(ref.watch(trackingStoreProvider), client).week(weekStartDay);
});

final FutureProvider<DownloadManager> downloadManagerProvider = FutureProvider<DownloadManager>((ref) async {
  final m = DownloadManager(store: JsonStore('downloads.json'));
  await m.load();
  return m;
});

final downloadTasksProvider = StreamProvider<List<DownloadTask>>((ref) async* {
  final m = await ref.watch(downloadManagerProvider.future);
  yield m.tasks.values.toList();
  var last = DateTime.fromMillisecondsSinceEpoch(0);
  await for (final t in m.updates) {
    final now = DateTime.now();
    // byte-level progress arrives many times a second; only state changes are worth an immediate rebuild
    if (t.state == DownloadState.running && now.difference(last) < const Duration(milliseconds: 400)) continue;
    last = now;
    yield m.tasks.values.toList();
  }
});

/// Adds a TMDB series to the tracking calendar (season 1). Returns false for movies / no match.
Future<bool> trackIfSeries(TrackingStore store, TmdbMatch? match, {int season = 1}) async {
  if (match == null || match.mediaType != 'tv') return false;
  await store.add(TrackedShow(tmdbId: match.id, title: match.title, season: season, posterPath: match.posterPath));
  return true;
}

final mediaAccountRepositoryProvider = Provider((ref) => MediaAccountRepository());
final FutureProvider<List<MediaAccount>> mediaAccountsProvider =
    FutureProvider<List<MediaAccount>>((ref) => ref.watch(mediaAccountRepositoryProvider).all());

final mediaClientProvider = FutureProvider.family<MediaServerClient?, String>((ref, accountId) async {
  final accounts = await ref.watch(mediaAccountsProvider.future);
  final account = accounts.where((a) => a.id == accountId).firstOrNull;
  return account == null ? null : MediaServerClient(account);
});

typedef MediaHome = ({List<MediaItem> resume, List<MediaItem> latest});

final embyHomeProvider = FutureProvider.family<MediaHome, String>((ref, accountId) async {
  final client = await ref.watch(mediaClientProvider(accountId).future);
  if (client == null) return (resume: const <MediaItem>[], latest: const <MediaItem>[]);
  final results = await Future.wait([client.resume(), client.latest()]);
  return (resume: results[0], latest: results[1]);
});

final embySearchProvider = FutureProvider.family<List<MediaItem>, ({String account, String query})>((ref, q) async {
  final client = await ref.watch(mediaClientProvider(q.account).future);
  if (client == null || q.query.trim().isEmpty) return const [];
  return client.search(q.query.trim());
});

final embyFavoritesProvider = FutureProvider.family<List<MediaItem>, String>((ref, accountId) async {
  final client = await ref.watch(mediaClientProvider(accountId).future);
  return client == null ? const [] : client.favorites();
});

/// 设置 → 重置应用. Downloads are stopped first so they do not write their progress back after the wipe.
final appResetServiceProvider = Provider((ref) => AppResetService(stopWriters: () {
      if (ref.exists(downloadManagerProvider)) ref.read(downloadManagerProvider).valueOrNull?.cancelAll();
    }));

/// Ends the process after 重置应用 (replaced in tests).
final appExitProvider = Provider<Future<void> Function()>((ref) => exitApp);
