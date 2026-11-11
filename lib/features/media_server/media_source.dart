import '../../core/json_store.dart';
import '../../models/vod.dart';
import '../../services/media_server_client.dart';
import '../player/playback_source.dart';

/// Emby / Jellyfin accounts (`emby_accounts.json`; file name and layout are this project's choice). The password is
/// never stored, only the access token returned by the login.
class MediaAccountRepository {
  MediaAccountRepository({JsonStore? store}) : _store = store ?? JsonStore('emby_accounts.json');
  final JsonStore _store;

  Future<List<MediaAccount>> all() async {
    final raw = await _store.read<List<dynamic>>(const []);
    return raw.whereType<Map>().map((e) => MediaAccount.fromJson(e.cast<String, dynamic>())).toList();
  }

  Future<void> upsert(MediaAccount account) async {
    final list = await all();
    final i = list.indexWhere((a) => a.id == account.id);
    i >= 0 ? list[i] = account : list.add(account);
    await _store.write(list.map((a) => a.toJson()).toList());
  }

  Future<void> remove(String id) async =>
      _store.write((await all()).where((a) => a.id != id).map((a) => a.toJson()).toList());
}

const _ticksPerSecond = 10000000;

/// Plays items of a media server through the shared native player; progress goes back to the server.
class MediaServerPlaybackSource extends PlaybackSource {
  MediaServerPlaybackSource(
      {required this.client, required this.title, required this.items, this.cover, this.memoryId});

  final MediaServerClient client;
  final List<MediaItem> items;
  final String? memoryId;

  @override
  final String title;
  @override
  final String? cover;

  @override
  List<PlayLine> get lines => [
        PlayLine(client.account.name, [for (final i in items) PlayEpisode(i.label, i.id)]),
      ];

  @override
  String? get memoryKey => memoryId == null ? null : 'emby|${client.account.id}|$memoryId';

  @override
  Future<PlayResult> resolve(int lineIndex, int episodeIndex) async {
    final r = await client.playbackUrl(items[episodeIndex].id);
    return PlayResult(url: r.url, headers: r.headers);
  }

  @override
  Future<double> resumeSeconds(int lineIndex, int episodeIndex) async =>
      (items[episodeIndex].positionTicks ?? 0) / _ticksPerSecond;

  @override
  Future<void> saveProgress(int lineIndex, int episodeIndex, double position, double duration,
      {int quality = 0}) async {
    try {
      await client.reportProgress(items[episodeIndex].id, (position * _ticksPerSecond).round());
    } catch (_) {
      // progress reporting must never interrupt playback
    }
  }

  @override
  Future<void> finish(int lineIndex, int episodeIndex, double position) async {
    try {
      await client.reportStopped(items[episodeIndex].id, (position * _ticksPerSecond).round());
    } catch (_) {}
  }
}

/// Seasons of a series' episode list, e.g. {1: [...], 2: [...]}, ordered by season then episode number.
Map<int, List<MediaItem>> groupBySeason(List<MediaItem> episodes) {
  final map = <int, List<MediaItem>>{};
  for (final e in episodes) {
    map.putIfAbsent(e.seasonNumber ?? 1, () => []).add(e);
  }
  for (final l in map.values) {
    l.sort((a, b) => (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0));
  }
  return Map.fromEntries(map.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
}
