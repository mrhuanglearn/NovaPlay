import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
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
    this.refs,
    this.headTail,
    this.onSession,
    this.describeError,
    NativePlayerHostApi? host,
    PlayerSessionRouter? router,
    this.installRouter = true,
    Future<void> Function()? enableWakelock,
    Future<void> Function()? disableWakelock,
  })  : host = host ?? NativePlayerHostApi(),
        router = router ?? PlayerSessionRouter.shared,
        _enableWakelock = enableWakelock ?? _defaultEnableWakelock,
        _disableWakelock = disableWakelock ?? _defaultDisableWakelock;

  static Future<void> _defaultEnableWakelock() async {
    try {
      await WakelockPlus.enable();
    } catch (_) {}
  }

  static Future<void> _defaultDisableWakelock() async {
    try {
      await WakelockPlus.disable();
    } catch (_) {}
  }

  final PlayerConfigRepository configs;
  final SnifferService sniffer;
  final Future<DanmuClient?> Function()? danmu;
  final DanmuRefsRepository? refs;
  final HeadTailRepository? headTail;

  /// Called with the newest live session (null when none is left) so callbacks like `danmuPush` can reach it.
  final void Function(PlayerSession? session)? onSession;

  /// See PlayerSession.describeError.
  final String Function(Object error)? describeError;
  final NativePlayerHostApi host;
  final PlayerSessionRouter router;
  final bool installRouter;
  final Future<void> Function() _enableWakelock;
  final Future<void> Function() _disableWakelock;

  Future<PageClosedEvent> playSource(
    PlaybackSource source, {
    int line = 0,
    int episode = 0,
    void Function()? onOpened,
  }) async {
    final (playback, danmaku) = await configs.load();
    final session = PlayerSession(
      sessionId: '${source.memoryKey ?? source.title}|${DateTime.now().microsecondsSinceEpoch}',
      source: source,
      host: host,
      sniffer: sniffer,
      danmu: danmu,
      refs: refs,
      headTail: headTail,
      onPreferences: (r) => configs.saveReport(r),
      describeError: describeError ?? (e) => '$e',
    );
    if (installRouter) router.install();
    router.register(session);
    onSession?.call(session);
    await _enableWakelock();
    try {
      await session.open(
        playback: playback,
        danmaku: danmaku,
        line: line,
        episode: episode,
        startSeconds: await source.resumeSeconds(line, episode),
        quality: await source.resumeQuality(),
        headTailJson: source.memoryKey == null ? null : await headTail?.sectionsJson(source.memoryKey!),
      );
      onOpened?.call();
      return await session.closed;
    } finally {
      router.unregister(session);
      onSession?.call(router.latest); // another player may still be open (e.g. one in picture-in-picture)
      if (router.latest == null) {
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
  }) =>
      playSource(
          VodPlaybackSource(site: site, api: api, detail: detail, history: history, recordHistory: recordHistory),
          line: line, episode: episode, onOpened: onOpened);
}
