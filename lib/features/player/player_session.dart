import 'dart:async';

import '../../models/vod.dart';
import '../../services/danmu_client.dart';
import '../danmaku/danmu_service.dart';
import '../sniffer/sniffer_service.dart';
import 'head_tail.dart';
import 'native_player_api.g.dart';
import 'playback_source.dart';
import 'session_router.dart';
import 'video_format_probe.dart';

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
    this.preferVideoDanmu,
    this.refs,
    this.headTail,
    VideoFormatProbe? formatProbe,
    required this.onPreferences,
    this.describeError = _plainError,
    this.isCancelled,
  }) : formatProbe = formatProbe ?? VideoFormatProbe.shared;

  final String sessionId;
  final PlaybackSource source;
  final NativePlayerHostApi host;
  final SnifferService sniffer;
  final VideoFormatProbe formatProbe;
  final bool Function()? isCancelled;

  /// Resolves the configured danmaku server on first use (starting it if it is a local service). Null = no danmaku.
  final Future<DanmuClient?> Function()? danmu;
  final Future<bool> Function()? preferVideoDanmu;
  final DanmuRefsRepository? refs;

  /// 片头片尾 marks of this video (记片头 / 记片尾 in the player). Null = not kept.
  final HeadTailRepository? headTail;
  final void Function(PreferenceReport) onPreferences;

  /// The text the player's error layer shows for a failed episode request (the app passes describeLoadError, so a
  /// spider's `{statusCode, message}` reads `HTTP 401：…` rather than a DioException dump).
  final String Function(Object error) describeError;

  static String _plainError(Object e) => '$e';

  DateTime _lastSaved = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _lastFlushed;
  int _line = 0;
  int _episode = 0;
  int _quality = 0;
  double _lastDuration = 0;
  Future<DanmuClient?>? _clientFuture;
  DanmuRef? _anime;
  bool _pushedByVideo = false;
  String? _episodeDanmuUrl;
  List<DanmuComment> _episodeDanmuComments = const [];
  Map<String, String> _episodeHeaders = const {};
  Completer<void>? _episodeResolved;
  bool _resolvingEpisode = false;
  (int, int, Future<PlayResult>)? _prefetchedEpisode;
  (int, int, String)? _resolvedEpisodeUrl;
  (int, int, Future<VideoDimensions?>)? _initialProbe;
  (int, int, VideoDimensions)? _pendingProbedDims;
  bool _opened = false;
  bool _fastProbeDelivered = false;
  final Map<int, String> _searchTitles = {};
  final _closed = Completer<PageClosedEvent>();
  bool _disposed = false;

  /// Completes when the player page closes.
  Future<PageClosedEvent> get closed => _closed.future;

  void cancelBeforeOpen() {
    _disposed = true;
    if (!_closed.isCompleted) {
      _closed.complete(PageClosedEvent(sessionId: sessionId, positionSeconds: 0, completed: false));
    }
  }

  int get line => _line;
  int get episode => _episode;

  /// Kicks off [source.resolve] for the initial episode immediately so spider/API resolution
  /// runs in parallel with native player Activity/ViewController creation and transition.
  void prefetchEpisode(int lineIndex, int episodeIndex) {
    if (lineIndex < 0 || lineIndex >= source.lines.length) return;
    final eps = source.lines[lineIndex].episodes;
    if (episodeIndex < 0 || episodeIndex >= eps.length) return;
    _line = lineIndex;
    _episode = episodeIndex;
    final fut = Future<PlayResult>.sync(() => source.resolve(lineIndex, episodeIndex));
    fut.ignore();
    _prefetchedEpisode = (lineIndex, episodeIndex, fut);
  }

  /// Starts probing the initial stream immediately on the Dart side so [PlayerLauncher] can await any remaining
  /// fast-launch budget without a `Dart -> Native -> Dart` round-trip, while slower streams still push the result in the
  /// background once [open] completes.
  void startInitialProbe({
    required int lineIndex,
    required int episodeIndex,
    required String url,
    required Map<String, String> headers,
  }) {
    final trimmed = url.trim();
    if (_disposed || _closed.isCompleted || source.epg != null || trimmed.isEmpty || VideoFormatProbe.shouldSkipProbe(trimmed)) {
      return;
    }
    final existing = _initialProbe;
    if (existing != null && existing.$1 == lineIndex && existing.$2 == episodeIndex) return;
    final fut = formatProbe.probe(trimmed, headers: headers, timeout: const Duration(milliseconds: 1500));
    _initialProbe = (lineIndex, episodeIndex, fut);
    unawaited(fut.then((dims) {
      if (dims == null || _disposed || _closed.isCompleted) return;
      source.onVideoDimensionsKnown(dims.width, dims.height);
      if (_fastProbeDelivered) return;
      if (_opened) {
        pushProbedVideoSize(lineIndex, episodeIndex, dims);
      } else {
        _pendingProbedDims = (lineIndex, episodeIndex, dims);
      }
    }));
  }

  /// Waits up to [timeout] for an already-started initial probe without cancelling its background completion push.
  Future<VideoDimensions?> waitForInitialProbe(Duration timeout) {
    final existing = _initialProbe;
    if (existing == null || timeout <= Duration.zero) return Future<VideoDimensions?>.value(null);
    return existing.$3.timeout(timeout, onTimeout: () => null);
  }

  void markInitialProbeDelivered() {
    _fastProbeDelivered = true;
    _pendingProbedDims = null;
  }

  Future<void> open({
    required PlaybackConfig playback,
    required DanmakuConfig danmaku,
    int line = 0,
    int episode = 0,
    double startSeconds = 0,
    int quality = 0,
    String? headTailJson,
    SourcePayload? initialSource,
    VideoDimensions? fallbackVideoSize,
    int? probeBudgetMs,
  }) async {
    _line = line;
    _episode = episode;
    _quality = quality;
    if (initialSource?.videoWidth != null && initialSource?.videoHeight != null) {
      _fastProbeDelivered = true;
      _pendingProbedDims = null;
    } else if (_initialProbe == null &&
        source.epg == null &&
        (playback.orientationMode == 'auto' ||
            (playback.orientationMode == null && playback.isPriorityLandscape) ||
            playback.kernel.trim().toLowerCase() == 'vlc') &&
        initialSource != null &&
        initialSource.success &&
        (initialSource.url?.trim().isNotEmpty ?? false)) {
      startInitialProbe(
        lineIndex: line,
        episodeIndex: episode,
        url: initialSource.url!,
        headers: initialSource.headers ?? const {},
      );
    }
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
      initialSource: initialSource,
      initialVideoWidth: fallbackVideoSize?.width,
      initialVideoHeight: fallbackVideoSize?.height,
      probeBudgetMs: probeBudgetMs,
    ));
    _opened = true;
    final pending = _pendingProbedDims;
    _pendingProbedDims = null;
    if (!_fastProbeDelivered && pending != null) {
      pushProbedVideoSize(pending.$1, pending.$2, pending.$3);
    }
  }

  // -- Kotlin -> Dart ---------------------------------------------------------------------------

  @override
  Future<void> onEpisodeRequest(EpisodeRequest request) async {
    if (_line != request.lineIndex || _episode != request.episodeIndex) {
      _pushedByVideo = false;
      _episodeDanmuUrl = null;
      _episodeDanmuComments = const [];
      _episodeHeaders = const {};
    }
    final gate = Completer<void>();
    _episodeResolved = gate;
    _resolvingEpisode = true;
    _line = request.lineIndex;
    _episode = request.episodeIndex;
    try {
      // Scheme A: a pre-resolve that timed out may still be running (or have finished); reuse it instead of calling
      // spider.play a second time.
      final pre = _preResolve;
      final SourcePayload payload;
      if (pre != null && pre.$1 == request.lineIndex && pre.$2 == request.episodeIndex && pre.$3 == request.qualityIndex) {
        _preResolve = null;
        final r = await pre.$4;
        payload = _withRequestId(r, request.requestId);
      } else {
        payload = await resolveEpisodeSource(
            requestId: request.requestId,
            lineIndex: request.lineIndex,
            episodeIndex: request.episodeIndex,
            qualityIndex: request.qualityIndex);
      }
      _resolvingEpisode = false;
      if (!gate.isCompleted) gate.complete();
      if (_disposed || _closed.isCompleted) return;
      final url = payload.url?.trim() ?? '';
      if (payload.success && url.isNotEmpty && (payload.videoWidth == null || payload.videoHeight == null)) {
        final hit = formatProbe.cached(url);
        if (hit != null) {
          payload.videoWidth = hit.width;
          payload.videoHeight = hit.height;
        }
      }
      await host.provideSource(payload);
      if (payload.success && url.isNotEmpty && (payload.videoWidth == null || payload.videoHeight == null)) {
        probeAndPushVideoSize(
          lineIndex: request.lineIndex,
          episodeIndex: request.episodeIndex,
          url: url,
          headers: payload.headers ?? const {},
        );
      }
    } catch (e) {
      _resolvingEpisode = false;
      if (!gate.isCompleted) gate.complete();
      if (_disposed || _closed.isCompleted) return;
      await host.provideSource(SourcePayload(requestId: request.requestId, success: false, errorMessage: describeError(e)));
    }
  }

  void pushProbedVideoSize(int lineIndex, int episodeIndex, VideoDimensions dims) {
    source.onVideoDimensionsKnown(dims.width, dims.height);
    if (_disposed || _closed.isCompleted || _line != lineIndex || _episode != episodeIndex) return;
    unawaited(Future<void>.sync(
      () => host.updateVideoSize(sessionId, lineIndex, episodeIndex, dims.width, dims.height),
    ).catchError((Object _) {}));
  }

  @override
  Future<ProbedVideoSize?> onProbeVideoSize(
    String sessionId,
    int lineIndex,
    int episodeIndex,
    String url,
    Map<String, String> headers,
    int budgetMs,
  ) async {
    if (isCancelled?.call() == true) {
      cancelBeforeOpen();
      return ProbedVideoSize(width: -1, height: -1);
    }
    if (_disposed || _closed.isCompleted || source.epg != null) return null;
    final trimmed = url.trim();
    if (trimmed.isEmpty || VideoFormatProbe.shouldSkipProbe(trimmed)) return null;
    final hit = formatProbe.cached(trimmed);
    if (hit != null) {
      markInitialProbeDelivered();
      source.onVideoDimensionsKnown(hit.width, hit.height);
      return ProbedVideoSize(width: hit.width, height: hit.height);
    }

    final existingInitial = _initialProbe;
    final managedByInitial =
        existingInitial != null && existingInitial.$1 == lineIndex && existingInitial.$2 == episodeIndex;
    final probeFut = managedByInitial
        ? existingInitial.$3
        : formatProbe.probe(
            trimmed,
            headers: headers,
            timeout: const Duration(milliseconds: 1500),
          );
    final budget = Duration(milliseconds: budgetMs.clamp(0, 600));
    final fast = budget > Duration.zero ? await probeFut.timeout(budget, onTimeout: () => null) : null;
    if (isCancelled?.call() == true) {
      cancelBeforeOpen();
      return ProbedVideoSize(width: -1, height: -1);
    }
    if (fast != null) {
      markInitialProbeDelivered();
      source.onVideoDimensionsKnown(fast.width, fast.height);
      return ProbedVideoSize(width: fast.width, height: fast.height);
    }
    if (!managedByInitial) {
      unawaited(probeFut.then((lateDims) {
        if (lateDims != null) pushProbedVideoSize(lineIndex, episodeIndex, lateDims);
      }));
    }
    return null;
  }

  @override
  Future<void> onVideoSizeDetected(
    String sessionId,
    int lineIndex,
    int episodeIndex,
    int width,
    int height,
  ) async {
    if (width <= 0 || height <= 0) return;
    final dims = (width: width, height: height);
    final resolved = _resolvedEpisodeUrl;
    if (resolved != null && resolved.$1 == lineIndex && resolved.$2 == episodeIndex && resolved.$3.isNotEmpty) {
      formatProbe.remember(resolved.$3, dims);
    }
    source.onVideoDimensionsKnown(width, height);
  }

  void probeAndPushVideoSize({
    required int lineIndex,
    required int episodeIndex,
    required String url,
    required Map<String, String> headers,
  }) {
    if (_disposed || _closed.isCompleted || source.epg != null || url.trim().isEmpty) return;
    final hit = formatProbe.cached(url);
    if (hit != null) {
      pushProbedVideoSize(lineIndex, episodeIndex, hit);
      return;
    }
    unawaited(
      formatProbe
          .probe(url, headers: headers, timeout: const Duration(milliseconds: 1500))
          .then((dims) {
        if (dims != null) pushProbedVideoSize(lineIndex, episodeIndex, dims);
      }),
    );
  }

  static SourcePayload _withRequestId(SourcePayload p, int requestId) => SourcePayload(
        requestId: requestId,
        success: p.success,
        url: p.url,
        audioUrl: p.audioUrl,
        headers: p.headers,
        qualities: p.qualities,
        subtitles: p.subtitles,
        errorMessage: p.errorMessage,
        videoWidth: p.videoWidth,
        videoHeight: p.videoHeight,
      );

  (int, int, int, Future<SourcePayload>)? _preResolve;

  /// Resolves (and, for `parse: 1` pages, sniffs) one episode into the payload the native side plays. Failures become
  /// `SourcePayload(success: false, errorMessage: ...)`; this never throws. Reuses [_prefetchedEpisode] when it matches.
  Future<SourcePayload> resolveEpisodeSource({
    required int requestId,
    required int lineIndex,
    required int episodeIndex,
    required int qualityIndex,
  }) async {
    final prefetched = _prefetchedEpisode;
    if (prefetched != null && prefetched.$1 == lineIndex && prefetched.$2 == episodeIndex) _prefetchedEpisode = null;
    try {
      var result = (prefetched != null && prefetched.$1 == lineIndex && prefetched.$2 == episodeIndex)
          ? await prefetched.$3
          : await source.resolve(lineIndex, episodeIndex);
      // The native side remembers the quality index across episodes; this episode may offer fewer, so clamp.
      final choice = result.qualities.isEmpty ? 0 : qualityIndex.clamp(0, result.qualities.length - 1);
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
          videoDanmuUrl: result.videoDanmuUrl,
          videoDanmuComments: result.videoDanmuComments,
        );
      }
      _episodeDanmuUrl = result.videoDanmuUrl;
      _episodeDanmuComments = result.videoDanmuComments;
      _episodeHeaders = result.effectiveHeaders;
      _resolvedEpisodeUrl = (lineIndex, episodeIndex, result.url.trim());
      var vw = result.videoWidth;
      var vh = result.videoHeight;
      if (vw != null && vh != null && vw > 0 && vh > 0) {
        formatProbe.remember(result.url, (width: vw, height: vh));
        source.onVideoDimensionsKnown(vw, vh);
      } else {
        final cachedDims = formatProbe.cached(result.url);
        if (cachedDims != null) {
          vw = cachedDims.width;
          vh = cachedDims.height;
          source.onVideoDimensionsKnown(vw, vh);
        }
      }
      return SourcePayload(
        requestId: requestId,
        success: true,
        url: result.url,
        audioUrl: result.audioUrl,
        headers: result.effectiveHeaders,
        qualities: [
          for (var i = 0; i < result.qualities.length; i++)
            QualityOption(qualityIndex: i, qualityName: result.qualities[i].name)
        ],
        subtitles: [
          for (final s in result.subtitles)
            SubtitleOption(url: s.url, name: s.name, language: s.language, mimeType: s.mimeType),
        ],
        videoWidth: vw,
        videoHeight: vh,
      );
    } catch (e) {
      return SourcePayload(requestId: requestId, success: false, errorMessage: describeError(e));
    }
  }

  /// Scheme A: resolves the initial episode while the detail page is still showing so the native side can open already
  /// playing. Returns null on timeout; the still-running resolve is kept so [onEpisodeRequest] reuses it.
  Future<SourcePayload?> preResolveInitialSource({
    required int line,
    required int episode,
    required int quality,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (line < 0 || line >= source.lines.length) return null;
    final eps = source.lines[line].episodes;
    if (episode < 0 || episode >= eps.length) return null;
    _line = line;
    _episode = episode;
    final fut = resolveEpisodeSource(requestId: 0, lineIndex: line, episodeIndex: episode, qualityIndex: quality);
    _preResolve = (line, episode, quality, fut);
    final r = await fut.timeout(timeout, onTimeout: () => SourcePayload(requestId: -1, success: false));
    if (r.requestId == -1) return null;
    // Delivered inside the open request: the native side will not ask again, so drop the cached copy.
    _preResolve = null;
    return r;
  }

  /// Cached as a future (not a flag): a search issued while the first resolve is still starting a local service must
  /// wait for it instead of seeing "no server".
  Future<DanmuClient?> _client() =>
      _clientFuture ??= (danmu?.call() ?? Future<DanmuClient?>.value(null)).catchError((Object _) => null);

  @override
  Future<void> onDanmakuRequest(DanmakuRequest request) async {
    if (_pushedByVideo || _disposed || _closed.isCompleted) return;
    if (_episodeResolved != null && !_episodeResolved!.isCompleted) {
      await _episodeResolved!.future.timeout(const Duration(seconds: 15), onTimeout: () {});
    }
    if (_pushedByVideo || _disposed || _closed.isCompleted) return;
    if (await (preferVideoDanmu?.call() ?? Future.value(false))) {
      try {
        var direct = _episodeDanmuComments;
        if (direct.isEmpty && _episodeDanmuUrl != null) {
          direct = await fetchVideoDanmakuUrl(_episodeDanmuUrl!, headers: _episodeHeaders);
        }
        if (_disposed || _closed.isCompleted) return;
        if (direct.isNotEmpty) {
          await host.updateDanmaku(DanmakuPayload(
            sessionId: sessionId,
            commentsJson: danmuCommentsToJson(direct),
            animeTitle: source.title,
          ));
          return;
        }
      } catch (_) {
        // Video-returned danmaku failed or returned empty: fall back to automatic danmu service matching.
      }
    }
    final client = await _client();
    if (client == null || _disposed || _closed.isCompleted) return;
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
      if (_pushedByVideo || _disposed || _closed.isCompleted) return;
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
    if (_disposed || _closed.isCompleted) return Future<void>.value();
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
    if (_resolvingEpisode) return;
    if (heartbeat.durationSeconds > 0) _lastDuration = heartbeat.durationSeconds;
    final now = DateTime.now();
    if (now.difference(_lastSaved) < const Duration(seconds: 5)) return;
    _lastSaved = now;
    _lastFlushed ??= now;
    final shouldFlush = now.difference(_lastFlushed!) >= const Duration(seconds: 30);
    if (shouldFlush) _lastFlushed = now;
    await source.saveProgress(
      _line,
      _episode,
      heartbeat.positionSeconds,
      heartbeat.durationSeconds,
      quality: _quality,
      flush: shouldFlush,
    );
  }

  @override
  Future<void> onPageClosed(PageClosedEvent event) async {
    _disposed = true;
    // The close event has no duration; keep the last one seen so the history progress bar does not reset to 0.
    await source.saveProgress(_line, _episode, event.positionSeconds, _lastDuration, quality: _quality, flush: true);
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
  Future<void> onErrorReported(ErrorReport report) async {
    source.invalidateEpisodeCache(_line, _episode);
  }
}
