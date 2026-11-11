import 'dart:async';

import '../../models/vod.dart';
import '../../services/danmu_client.dart';
import '../danmaku/danmu_service.dart';
import '../sniffer/sniffer_service.dart';
import 'head_tail.dart';
import 'native_player_api.g.dart';
import 'playback_source.dart';
import 'session_router.dart';

/// What the error layer says when a site's play route answers without a URL.
const emptyPlayUrlMessage = '该线路未返回播放地址，请换一条线路或稍后重试';

class EmptyPlayUrl implements Exception {
  const EmptyPlayUrl();
  @override
  String toString() => emptyPlayUrlMessage;
}

/// One playback session between Dart and the native player. Native calls arrive through [PlayerSessionRouter], which
/// picks the session by id.
///
/// Responsibilities (OBSERVED from the Pigeon surface: the native side asks, Dart answers):
///  - `openPlayerPage` with lines / episodes / config,
///  - answer `onEpisodeRequest` by resolving the episode through the [PlaybackSource] (or sniffing a web page),
///  - answer danmaku requests, search requests and episode lists,
///  - persist progress from `onHeartbeat`, the final position from `onPageClosed`,
///  - persist preference changes made inside the player (`onPreferenceReported`).
class PlayerSession implements NativePlayerFlutterApi {
  PlayerSession({
    required this.sessionId,
    required this.source,
    required this.host,
    required this.sniffer,
    this.danmu,
    this.refs,
    this.headTail,
    required this.onPreferences,
    this.describeError = _plainError,
  });

  final String sessionId;
  final PlaybackSource source;
  final NativePlayerHostApi host;
  final SnifferService sniffer;

  /// Resolves the configured danmaku server on first use (starting it if it is a local service). Null = no danmaku.
  final Future<DanmuClient?> Function()? danmu;
  final DanmuRefsRepository? refs;

  /// 片头片尾 marks of this video (记片头 / 记片尾 in the player). Null = not kept.
  final HeadTailRepository? headTail;
  final void Function(PreferenceReport) onPreferences;

  /// The text the player's error layer shows for a failed episode request (the app passes describeLoadError, so a
  /// spider's `{statusCode, message}` reads `HTTP 401：…` rather than a DioException dump).
  final String Function(Object error) describeError;

  static String _plainError(Object e) => '$e';

  DateTime _lastSaved = DateTime.fromMillisecondsSinceEpoch(0);
  int _line = 0;
  int _episode = 0;
  int _quality = 0;
  double _lastDuration = 0;
  Future<DanmuClient?>? _clientFuture;
  DanmuRef? _anime;
  bool _pushedByVideo = false;
  final Map<int, String> _searchTitles = {};
  final _closed = Completer<PageClosedEvent>();

  /// Completes when the player page closes.
  Future<PageClosedEvent> get closed => _closed.future;

  int get line => _line;
  int get episode => _episode;

  Future<void> open({
    required PlaybackConfig playback,
    required DanmakuConfig danmaku,
    int line = 0,
    int episode = 0,
    double startSeconds = 0,
    int quality = 0,
    String? headTailJson,
  }) async {
    _line = line;
    _episode = episode;
    _quality = quality;
    final lines = source.lines;
    List<EpisodeItem> episodesOf(PlayLine l) =>
        [for (var j = 0; j < l.episodes.length; j++) EpisodeItem(episodeIndex: j, episodeName: l.episodes[j].name)];
    await host.openPlayerPage(OpenPlayerRequest(
      sessionId: sessionId,
      title: source.title,
      isMovie: source.isMovie,
      lines: [
        for (var i = 0; i < lines.length; i++)
          LineInfo(lineIndex: i, lineName: lines[i].name, episodes: episodesOf(lines[i]))
      ],
      episodes: episodesOf(lines[line]),
      playbackConfig: playback,
      danmakuConfig: danmaku,
      startPositionSeconds: startSeconds.round(),
      startLineIndex: line,
      startEpisodeIndex: episode,
      coverUrl: source.cover,
      epgProgrammes: source.epg,
      headTailSectionsJson: headTailJson,
      startQualityIndex: quality,
    ));
  }

  // -- Kotlin -> Dart ---------------------------------------------------------------------------

  @override
  Future<void> onEpisodeRequest(EpisodeRequest request) async {
    if (_line != request.lineIndex || _episode != request.episodeIndex) {
      _pushedByVideo = false;
    }
    _line = request.lineIndex;
    _episode = request.episodeIndex;
    try {
      var result = await source.resolve(request.lineIndex, request.episodeIndex);
      // The native side remembers the quality index across episodes; this episode may offer fewer, so clamp.
      final choice = result.qualities.isEmpty ? 0 : request.qualityIndex.clamp(0, result.qualities.length - 1);
      _quality = choice;
      result = result.withQuality(choice);
      // OBSERVED (2026-11-11): some lines answer `{"parse":0,"url":""}`. Handing that to a kernel made ExoPlayer report
      // "FileNotFoundException: : open failed"; it is a failed request, shown as 获取播放链接失败.
      if (result.url.trim().isEmpty) throw const EmptyPlayUrl();
      if (result.needsParse) {
        // `parse: 1` -> the URL is a web page: load it invisibly and take the first media request it makes.
        // (After withQuality, so it is the page of the quality the user picked.)
        final found = await sniffer.sniffFirstVideo(result.url, headers: result.headers);
        if (found == null) throw StateError('no playable stream found on page');
        result = PlayResult(
          url: found.url,
          headers: {...result.headers, ...found.headers},
          qualities: result.qualities,
          subtitles: result.subtitles,
        );
      }
      await host.provideSource(SourcePayload(
        requestId: request.requestId,
        success: true,
        url: result.url,
        audioUrl: result.audioUrl,
        headers: result.headers,
        qualities: [
          for (var i = 0; i < result.qualities.length; i++)
            QualityOption(qualityIndex: i, qualityName: result.qualities[i].name)
        ],
        subtitles: [
          for (final s in result.subtitles)
            SubtitleOption(url: s.url, name: s.name, language: s.language, mimeType: s.mimeType),
        ],
      ));
    } catch (e) {
      await host.provideSource(SourcePayload(requestId: request.requestId, success: false, errorMessage: describeError(e)));
    }
  }

  /// Cached as a future (not a flag): a search issued while the first resolve is still starting a local service must
  /// wait for it instead of seeing "no server".
  Future<DanmuClient?> _client() =>
      _clientFuture ??= (danmu?.call() ?? Future<DanmuClient?>.value(null)).catchError((Object _) => null);

  @override
  Future<void> onDanmakuRequest(DanmakuRequest request) async {
    if (_pushedByVideo) return;
    final client = await _client();
    if (client == null) return;
    try {
      final key = source.memoryKey;
      _anime ??= (key == null ? null : await refs?.get(key));
      if (_anime == null) {
        // No match yet: take the best hit for the title; the user can correct it in the danmaku panel.
        final hit = (await client.searchAnime(source.title)).firstOrNull;
        if (hit != null) _anime = DanmuRef(hit.animeId, hit.title);
      }
      final anime = _anime;
      if (anime == null) return;
      final eps = await client.episodes(anime.animeId);
      if (request.episodeIndex < 0 || request.episodeIndex >= eps.length) return;
      final ep = eps[request.episodeIndex];
      final list = await client.comments(ep.episodeId);
      if (_pushedByVideo) return;
      await host.updateDanmaku(DanmakuPayload(
        sessionId: sessionId,
        commentsJson: danmuCommentsToJson(list),
        animeTitle: anime.title,
        episodeTitle: ep.title,
      ));
    } catch (_) {
      // danmaku is best-effort; the player simply shows none
    }
  }

  /// A script pushed comments through the `danmuPush` callback (payload shape inferred, see DartActions).
  Future<void> pushDanmaku(List<DanmuComment> comments, {String? title}) {
    _pushedByVideo = true;
    return host.updateDanmaku(
        DanmakuPayload(sessionId: sessionId, commentsJson: danmuCommentsToJson(comments), animeTitle: title));
  }

  @override
  Future<DanmakuPromptInfo> getDanmakuPromptInfo(String sessionId) async =>
      DanmakuPromptInfo(keyword: source.title, episodeNumber: _episode + 1);

  @override
  Future<void> onDanmakuSearchRequest(DanmakuSearchRequest request) async {
    final client = await _client();
    if (client == null) {
      await host.provideDanmakuSearchResults(sessionId, const []);
      return;
    }
    final found = await client.searchAnime(request.keyword);
    for (final a in found) {
      _searchTitles[a.animeId] = a.title;
    }
    await host.provideDanmakuSearchResults(sessionId, [
      for (final a in found)
        DanmakuSearchResultItem(
            animeId: a.animeId, animeTitle: a.title, episodeCount: a.episodeCount, imageUrl: a.imageUrl),
    ]);
  }

  @override
  Future<void> onDanmakuEpisodesRequest(String sessionId, int animeId) async {
    final client = await _client();
    if (client == null) return;
    final ref = DanmuRef(animeId, _searchTitles[animeId] ?? '');
    _anime = ref; // later episodes (and later sessions of the same show) match automatically
    final key = source.memoryKey;
    if (key != null) await refs?.set(key, ref);
    final eps = await client.episodes(animeId);
    await host.provideDanmakuEpisodesResults(sessionId, [
      for (var i = 0; i < eps.length; i++) EpisodeItem(episodeIndex: i, episodeName: eps[i].title),
    ]);
  }

  @override
  Future<void> onHeartbeat(Heartbeat heartbeat) async {
    if (heartbeat.durationSeconds > 0) _lastDuration = heartbeat.durationSeconds;
    final now = DateTime.now();
    if (now.difference(_lastSaved) < const Duration(seconds: 5)) return;
    _lastSaved = now;
    await source.saveProgress(_line, _episode, heartbeat.positionSeconds, heartbeat.durationSeconds, quality: _quality);
  }

  @override
  Future<void> onPageClosed(PageClosedEvent event) async {
    // The close event has no duration; keep the last one seen so the history progress bar does not reset to 0.
    await source.saveProgress(_line, _episode, event.positionSeconds, _lastDuration, quality: _quality);
    await source.finish(_line, _episode, event.positionSeconds);
    if (!_closed.isCompleted) _closed.complete(event);
  }

  @override
  Future<void> onPreferenceReported(PreferenceReport report) async => onPreferences(report);

  @override
  Future<void> onHeadTailMarked(String sessionId, String type, double seconds) async {
    final key = source.memoryKey;
    if (key != null) await headTail?.mark(key, type, seconds);
  }

  @override
  Future<void> onStateChanged(StateEvent event) async {}

  @override
  Future<void> onErrorReported(ErrorReport report) async {}
}
