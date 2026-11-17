import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_http.dart';
import '../features/live/live_store.dart';
import '../features/live/m3u_epg.dart';

final liveSourceRepositoryProvider = Provider((ref) => LiveSourceRepository());
final livePreferencesRepositoryProvider = Provider((ref) => LivePreferencesRepository());

final FutureProvider<List<LiveSource>> liveSourcesProvider = FutureProvider<List<LiveSource>>((ref) => ref.watch(liveSourceRepositoryProvider).all());
final FutureProvider<LivePreferences> livePreferencesProvider = FutureProvider<LivePreferences>((ref) => ref.watch(livePreferencesRepositoryProvider).load());

/// Id of the source being browsed. Null = the remembered one, else the first.
class SelectedLiveSource extends Notifier<String?> {
  @override
  String? build() => null;
  void select(String? id) => state = id;
}

final selectedLiveSourceProvider = NotifierProvider<SelectedLiveSource, String?>(SelectedLiveSource.new);

final Provider<LiveSource?> currentLiveSourceProvider = Provider<LiveSource?>((ref) {
  final sources = ref.watch(liveSourcesProvider).valueOrNull ?? const [];
  if (sources.isEmpty) return null;
  final wanted = ref.watch(selectedLiveSourceProvider) ?? ref.watch(livePreferencesProvider).valueOrNull?.lastSourceId;
  return sources.firstWhere((s) => s.id == wanted, orElse: () => sources.first);
});

/// Downloads a playlist with the source's User-Agent.
Future<String> fetchLivePlaylist(LiveSource source) async {
  final res = await createAppDio(connectTimeout: const Duration(seconds: 12), receiveTimeout: const Duration(seconds: 60)).get<String>(
    source.url,
    options: Options(
      responseType: ResponseType.plain,
      headers: {if (source.userAgent.trim().isNotEmpty) 'User-Agent': source.userAgent.trim()},
    ),
  );
  return res.data ?? '';
}

Future<List<int>> fetchLiveGuideBytes(String url) async {
  final res = await createAppDio(connectTimeout: const Duration(seconds: 15), receiveTimeout: const Duration(seconds: 120))
      .get<List<int>>(url, options: Options(responseType: ResponseType.bytes));
  return res.data ?? const <int>[];
}

final livePlaylistLoaderProvider =
    Provider((ref) => LivePlaylistLoader(fetch: fetchLivePlaylist, fetchGuideBytes: fetchLiveGuideBytes));

/// The playlist text, downloaded or cached according to the source's 自动刷新 setting.
final livePlaylistProvider = FutureProvider.family<String, String>((ref, sourceId) async {
  final sources = await ref.watch(liveSourcesProvider.future);
  final source = sources.firstWhere((s) => s.id == sourceId);
  return ref.watch(livePlaylistLoaderProvider).load(source);
});

final liveChannelsProvider = FutureProvider.family<List<LiveChannel>, String>((ref, sourceId) async {
  return parseM3uAsync(await ref.watch(livePlaylistProvider(sourceId).future));
});

/// Null when no guide is known or it could not be loaded (the channel list works without it).
final liveGuideProvider = FutureProvider.family<XmltvGuide?, String>((ref, sourceId) async {
  final sources = await ref.watch(liveSourcesProvider.future);
  final source = sources.firstWhere((s) => s.id == sourceId);
  final prefs = await ref.watch(livePreferencesProvider.future);
  final url = guideUrlFor(source, await ref.watch(livePlaylistProvider(sourceId).future), prefs);
  if (url == null) return null;
  try {
    final bytes = await ref.watch(livePlaylistLoaderProvider).loadGuideBytes(url, refresh: source.refresh);
    if (bytes.isEmpty) return null;
    return await parseXmltvGuideAsync(bytes);
  } catch (e) {
    debugPrint('liveGuideProvider load failed ($url): $e');
    return null;
  }
});
