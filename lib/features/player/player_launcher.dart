import 'package:flutter/foundation.dart' show TargetPlatform, debugPrint, defaultTargetPlatform;
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/haptics.dart';
import '../../core/json_store.dart';
import '../../models/vod.dart';
import '../../services/danmu_client.dart';
import '../catpaw/spider_api.dart';
import '../danmaku/danmu_service.dart';
import '../library/watch_repository.dart';
import '../sniffer/sniffer_service.dart';
import 'head_tail.dart';
import 'native_player_api.g.dart';
import 'player_session.dart';
import 'playback_source.dart';
import 'session_router.dart';
import 'video_format_probe.dart';

/// Defaults mirror the player options visible in the changelog and the dex strings
/// (hardware decode, fill mode, long-press speed, fast-forward step, PiP, skip notice, danmaku appearance).
PlaybackConfig defaultPlaybackConfig() => PlaybackConfig(
      hwDecode: true,
      fitMode: 'fit',
      speed: 1.0,
      longPressSpeed: 2.0,
      fastForwardSeconds: 10,
      autoPictureInPicture: true,
      pauseOnBackground: false,
      isPriorityLandscape: true,
      orientationMode: 'auto',
      isHiddenFastSeekBtn: false,
      isShowStatsBar: false,
      isShowAllDuration: false,
      isShowEpisodeSwitchNotice: true,
      showNetSpeed: true,
      hapticEnabled: true,
      skipNotice: true,
      kernel: defaultTargetPlatform == TargetPlatform.iOS ? 'avplayer' : 'exo',
    );

DanmakuConfig defaultDanmakuConfig() => DanmakuConfig(
      enabled: true,
      opacity: 1.0,
      fontSize: 18,
      scrollSpeed: 1.0,
      area: 0.5,
      colorMode: 'original',
      gradientStyle: 'none',
      showTop: true,
      showBottom: true,
      delaySeconds: 0,
      lineHeight: 1.2,
      strokeWidth: 1.0,
      blackList: const [],
    );

/// Persists player + danmaku preferences (`player_config.json`).
class PlayerConfigRepository {
  PlayerConfigRepository({JsonStore? store}) : _store = store ?? JsonStore('player_config.json');
  final JsonStore _store;

  /// Pigeon's `decode` indexes every field, so a file written before a field was added (the lists are positional)
  /// would throw. Padding with nulls is safe because every field added later is optional; anything still unreadable
  /// falls back to the defaults instead of taking the player down.
  static T _decode<T>(Object? raw, T Function(List<Object?>) decode, int length, T fallback) {
    if (raw is! List) return fallback;
    try {
      return decode([...raw, for (var i = raw.length; i < length; i++) null]);
    } catch (_) {
      return fallback;
    }
  }

  Future<(PlaybackConfig, DanmakuConfig)> load() async {
    final j = await _store.read<Map<String, dynamic>>(<String, dynamic>{});
    final defaultPlayback = defaultPlaybackConfig();
    final defaultDanmaku = defaultDanmakuConfig();
    final playback = _decode(
        j['playback'], PlaybackConfig.decode, (defaultPlayback.encode() as List<Object?>).length, defaultPlayback);
    if (defaultTargetPlatform == TargetPlatform.iOS && playback.kernel.trim().toLowerCase() == 'mpv') {
      playback.autoPictureInPicture = false;
    }
    final danmaku =
        _decode(j['danmaku'], DanmakuConfig.decode, (defaultDanmaku.encode() as List<Object?>).length, defaultDanmaku);
    AppHaptics.enabled = playback.hapticEnabled;
    return (playback, danmaku);
  }

  Future<void> save(PlaybackConfig playback, DanmakuConfig danmaku) {
    AppHaptics.enabled = playback.hapticEnabled;
    return _store.write(<String, dynamic>{'playback': playback.encode(), 'danmaku': danmaku.encode()});
  }

  /// Preferences changed inside the native player (partial: only the parts that changed are set).
  Future<void> saveReport(PreferenceReport r) async {
    final (p, d) = await load();
    await save(r.playbackConfig ?? p, r.danmakuConfig ?? d);
  }
}

/// Opens the native player for a [PlaybackSource] and resolves when the user leaves it.
class PlayerLauncher {
  PlayerLauncher({
    required this.configs,
    required this.sniffer,
    this.danmu,
    this.preferVideoDanmu,
    this.refs,
    this.headTail,
    this.onSession,
    this.describeError,
    NativePlayerHostApi? host,
    PlayerSessionRouter? router,
    VideoFormatProbe? formatProbe,
    this.fastLaunchBudget = const Duration(milliseconds: 300),
    this.installRouter = true,
    Future<void> Function()? enableWakelock,
    Future<void> Function()? disableWakelock,
  })  : host = host ?? NativePlayerHostApi(),
        router = router ?? PlayerSessionRouter.shared,
        _formatProbe = formatProbe ?? VideoFormatProbe.shared,
        _enableWakelock = enableWakelock ?? _defaultEnableWakelock,
        _disableWakelock = disableWakelock ?? _defaultDisableWakelock;

  static Future<void> _defaultEnableWakelock() async {
    try {
      await WakelockPlus.enable();
    } catch (e) {
      debugPrint('WakelockPlus.enable ignored: $e');
    }
  }

  static Future<void> _defaultDisableWakelock() async {
    try {
      await WakelockPlus.disable();
    } catch (e) {
      debugPrint('WakelockPlus.disable ignored: $e');
    }
  }

  final PlayerConfigRepository configs;
  final SnifferService sniffer;
  final Future<DanmuClient?> Function()? danmu;
  final Future<bool> Function()? preferVideoDanmu;
  final DanmuRefsRepository? refs;
  final HeadTailRepository? headTail;

  /// Called with the newest live session (null when none is left) so callbacks like `danmuPush` can reach it.
  final void Function(PlayerSession? session)? onSession;

  /// See PlayerSession.describeError.
  final String Function(Object error)? describeError;
  final NativePlayerHostApi host;
  final PlayerSessionRouter router;
  final VideoFormatProbe _formatProbe;

  /// Maximum time spent trying to fast-resolve + header-probe the stream's format before opening the player in
  /// default landscape (any still-running resolve/probe continues in parallel and adapts to portrait if needed).
  final Duration fastLaunchBudget;
  final bool installRouter;
  final Future<void> Function() _enableWakelock;
  final Future<void> Function() _disableWakelock;

  Future<PageClosedEvent> playSource(
    PlaybackSource source, {
    int line = 0,
    int episode = 0,
    void Function()? onOpened,
    bool Function()? isCancelled,
  }) async {
    final sw = Stopwatch()..start();
    final session = PlayerSession(
      sessionId: '${source.memoryKey ?? source.title}|${DateTime.now().microsecondsSinceEpoch}',
      source: source,
      host: host,
      sniffer: sniffer,
      danmu: danmu,
      preferVideoDanmu: preferVideoDanmu,
      refs: refs,
      headTail: headTail,
      formatProbe: _formatProbe,
      onPreferences: (r) => configs.saveReport(r),
      describeError: describeError ?? (e) => '$e',
      isCancelled: isCancelled,
    );
    if (installRouter) router.install();
    router.register(session);
    onSession?.call(session);
    session.prefetchEpisode(line, episode);
    var wakelockHeld = false;
    Future<void>? wakelockFuture;
    try {
      final memKey = source.memoryKey;
      final configFuture = configs.load();
      final htFuture = memKey == null || headTail == null ? Future.value(null) : headTail!.getAll(memKey);
      final qualityFuture = source.resumeQuality();
      final fallbackDimsFuture = source.fallbackDimensions(line, episode);
      wakelockFuture = _enableWakelock().then((_) {
        wakelockHeld = true;
      });
      final (playback, danmaku) = await configFuture;
      final ht = await htFuture;
      final quality = await qualityFuture;
      if (isCancelled?.call() == true) {
        session.cancelBeforeOpen();
        return await session.closed;
      }

      final startSecondsFuture = source.resumeSeconds(line, episode, outroSeconds: ht?.outro ?? 0);
      final autoOrient = effectiveOrientationMode(playback) == 'auto' && source.epg == null;
      final budget = autoOrient ? fastLaunchBudget : const Duration(milliseconds: 60);
      final resolveWindow = budget - sw.elapsed;
      final initialSource = resolveWindow > Duration.zero
          ? await session.preResolveInitialSource(
              line: line,
              episode: episode,
              quality: quality,
              timeout: resolveWindow,
            )
          : null;
      if (isCancelled?.call() == true) {
        session.cancelBeforeOpen();
        return await session.closed;
      }

      final fallbackDims = autoOrient ? await fallbackDimsFuture : null;
      var startedInitialProbe = false;
      if (autoOrient && initialSource != null && initialSource.success) {
        final url = initialSource.url?.trim() ?? '';
        if (url.isNotEmpty && (initialSource.videoWidth == null || initialSource.videoHeight == null)) {
          final cached = _formatProbe.cached(url);
          if (cached != null) {
            initialSource.videoWidth = cached.width;
            initialSource.videoHeight = cached.height;
            source.onVideoDimensionsKnown(cached.width, cached.height);
          } else if (fallbackDims != null) {
            initialSource.videoWidth = fallbackDims.width;
            initialSource.videoHeight = fallbackDims.height;
            source.onVideoDimensionsKnown(fallbackDims.width, fallbackDims.height);
          } else if (!VideoFormatProbe.shouldSkipProbe(url)) {
            startedInitialProbe = true;
            session.startInitialProbe(
              lineIndex: line,
              episodeIndex: episode,
              url: url,
              headers: initialSource.headers ?? const {},
            );
          }
        }
      }

      final startSeconds = await startSecondsFuture;
      if (isCancelled?.call() == true) {
        session.cancelBeforeOpen();
        return await session.closed;
      }

      // Spend any remaining click-to-open budget directly in Dart on the already-running probe so `OpenPlayerRequest`
      // carries `(videoWidth, videoHeight)` to Native in a single hop (zero `Dart -> Native -> Dart` round-trips). If
      // the unified budget expires first, Native opens immediately in default landscape (`probeBudgetMs: 0`) and the
      // still-running probe pushes `updateVideoSize` in the background as soon as it finishes.
      if (startedInitialProbe && initialSource != null) {
        final remainingProbeWindow = budget - sw.elapsed;
        final clampedWindow = remainingProbeWindow <= Duration.zero
            ? Duration.zero
            : (remainingProbeWindow > const Duration(milliseconds: 260)
                ? const Duration(milliseconds: 260)
                : remainingProbeWindow);
        final hit = _formatProbe.cached(initialSource.url ?? '') ??
            (clampedWindow > Duration.zero ? await session.waitForInitialProbe(clampedWindow) : null);
        if (isCancelled?.call() == true) {
          session.cancelBeforeOpen();
          return await session.closed;
        }
        if (hit != null) {
          initialSource.videoWidth = hit.width;
          initialSource.videoHeight = hit.height;
          session.markInitialProbeDelivered();
          source.onVideoDimensionsKnown(hit.width, hit.height);
        }
      }

      await wakelockFuture;
      await session.open(
        playback: playback,
        danmaku: danmaku,
        line: line,
        episode: episode,
        startSeconds: startSeconds,
        quality: quality,
        headTailJson: HeadTailRepository.sectionsJsonFrom(ht),
        initialSource: initialSource,
        fallbackVideoSize: autoOrient ? fallbackDims : null,
        probeBudgetMs: 0,
      );
      if (isCancelled?.call() == true) {
        session.cancelBeforeOpen();
        return await session.closed;
      }
      onOpened?.call();
      return await session.closed;
    } finally {
      if (wakelockFuture != null) {
        await wakelockFuture.catchError((Object _) {});
      }
      router.unregister(session);
      onSession?.call(router.latest); // another player may still be open (e.g. one in picture-in-picture)
      if (wakelockHeld && router.latest == null) {
        await _disableWakelock();
      }
    }
  }

  /// Convenience for spider videos.
  Future<PageClosedEvent> play({
    required SpiderSite site,
    required SpiderApi api,
    required VodDetail detail,
    required HistoryRepository history,
    bool recordHistory = true,
    int line = 0,
    int episode = 0,
    void Function()? onOpened,
    bool Function()? isCancelled,
  }) =>
      playSource(
        VodPlaybackSource(site: site, api: api, detail: detail, history: history, recordHistory: recordHistory),
        line: line,
        episode: episode,
        onOpened: onOpened,
        isCancelled: isCancelled,
      );
}


const _orientationModes = {'auto', 'landscape', 'portrait'};

/// 屏幕方向: a valid [PlaybackConfig.orientationMode] wins, else derived from the legacy isPriorityLandscape flag.
String effectiveOrientationMode(PlaybackConfig p) {
  final m = p.orientationMode;
  if (m != null && _orientationModes.contains(m)) return m;
  return p.isPriorityLandscape ? 'auto' : 'portrait';
}

void setOrientationMode(PlaybackConfig p, String mode) {
  p.orientationMode = mode;
  p.isPriorityLandscape = mode != 'portrait';
}
