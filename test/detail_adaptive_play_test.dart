import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/app/providers.dart';
import 'package:uzv_reimpl/app/theme.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/features/catpaw/spider_api.dart';
import 'package:uzv_reimpl/features/library/watch_repository.dart';
import 'package:uzv_reimpl/features/player/native_player_api.g.dart';
import 'package:uzv_reimpl/features/player/player_launcher.dart';
import 'package:uzv_reimpl/features/player/player_session.dart';
import 'package:uzv_reimpl/features/player/playback_source.dart';
import 'package:uzv_reimpl/features/player/session_router.dart';
import 'package:uzv_reimpl/features/player/video_format_probe.dart';
import 'package:uzv_reimpl/features/sniffer/sniffer_service.dart';
import 'package:uzv_reimpl/features/subscription/subscription.dart';
import 'package:uzv_reimpl/l10n/l10n.dart';
import 'package:uzv_reimpl/models/vod.dart';
import 'package:uzv_reimpl/ui/detail_screen.dart';
import 'package:uzv_reimpl/ui/player_settings_screens.dart';

class _MemoryStore extends JsonStore {
  _MemoryStore(super.name);
  Object? _data;

  @override
  Future<T> read<T>(T fallback) async => (_data as T?) ?? fallback;

  @override
  Future<void> write(Object? json) async => _data = json;
}

class _TestHost extends NativePlayerHostApi {
  final opened = <OpenPlayerRequest>[];
  final runtimePatches = <(String, RuntimeConfigPatch)>[];

  @override
  Future<void> openPlayerPage(OpenPlayerRequest request) async {
    opened.add(request);
  }

  @override
  Future<void> updateRuntimeConfig(String sessionId, RuntimeConfigPatch patch) async {
    runtimePatches.add((sessionId, patch));
  }
}

class _TrackingPlayApi extends SpiderApi {
  _TrackingPlayApi({this.inlineVideoSize = const (1080, 1920)}) : super(0);
  final (int, int)? inlineVideoSize;
  final calls = <(String, String)>[];

  @override
  Future<PlayResult> play(SpiderSite site, String flag, String id) async {
    calls.add((flag, id));
    return PlayResult(
      url: 'http://127.0.0.1:9/stream_$id.m3u8',
      needsParse: inlineVideoSize == null,
      videoWidth: inlineVideoSize?.$1,
      videoHeight: inlineVideoSize?.$2,
    );
  }
}

void main() {
  late HistoryRepository history;
  late FavoriteRepository favorites;
  late PlayerConfigRepository playerConfigs;
  late JsonStore settingsStore;

  const site = SpiderSite(key: 'shortdrama', name: '短剧源', api: '/spider/shortdrama/3');
  final detail = VodDetail(
    item: const VodItem(id: 'vod_42', name: '逆袭短剧', siteKey: 'shortdrama'),
    lines: parsePlayLines(
      r'线路一$$$线路二',
      r'第1集$l1_ep1#第2集$l1_ep2#第3集$l1_ep3$$$第1集$l2_ep1#第2集$l2_ep2',
    ),
  );

  setUp(() {
    history = HistoryRepository(store: _MemoryStore('history.json'));
    favorites = FavoriteRepository(store: _MemoryStore('favorites.json'));
    playerConfigs = PlayerConfigRepository(store: _MemoryStore('player_config.json'));
    settingsStore = _MemoryStore('settings.json');
  });

  testWidgets('DetailScreen respects user-selected line in 选集 on 立即播放 and prewarms switched line', (tester) async {
    // Watch history is on 线路一 · 第3集 (line 0, episode 2).
    await history.record(const ProgressEntry(
      item: VodItem(id: 'vod_42', name: '逆袭短剧', siteKey: 'shortdrama'),
      lineIndex: 0,
      episodeIndex: 2,
      episodeName: '第3集',
      positionSeconds: 35,
      durationSeconds: 120,
      updatedAt: 0,
    ));

    final api = _TrackingPlayApi();
    final host = _TestHost();
    final router = PlayerSessionRouter();
    final launcher = PlayerLauncher(
      configs: playerConfigs,
      sniffer: SnifferService(),
      host: host,
      router: router,
      installRouter: false,
      enableWakelock: () async {},
      disableWakelock: () async {},
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [
        catpawRuntimeProvider.overrideWith(
          (ref) async => SpiderRuntime(
            subscription: const Subscription(key: 's1', name: 'sub'),
            api: api,
            sites: const [site],
          ),
        ),
        homeSitesProvider.overrideWithValue(const [site]),
        historyRepositoryProvider.overrideWithValue(history),
        favoriteRepositoryProvider.overrideWithValue(favorites),
        playerConfigRepositoryProvider.overrideWithValue(playerConfigs),
        settingsStoreProvider.overrideWithValue(settingsStore),
        playerLauncherProvider.overrideWithValue(launcher),
        tmdbProvider.overrideWith((ref) async => null),
        videoDetailProvider.overrideWith((ref, q) async => detail),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildAppTheme(Brightness.light),
        home: const DetailScreen(vodId: 'vod_42', siteKey: 'shortdrama', enablePrewarmInTest: true),
      ),
    ));
    await tester.pumpAndSettle();

    // Initial prewarm targets saved history: 线路一 · 第3集.
    expect(api.calls, [('线路一', 'l1_ep3')]);

    // User opens 选集 and switches to 线路二, then closes the sheet without tapping an episode row.
    await tester.tap(find.text('选集'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('线路二'));
    await tester.pumpAndSettle();

    // Switching line inside 选集 immediately prewarms 线路二 · 第1集!
    expect(api.calls, [('线路一', 'l1_ep3'), ('线路二', 'l2_ep1')]);

    Navigator.of(tester.element(find.text('线路二'))).pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500)); // let _openEpisodes scroll.dispose timer finish

    // Clicking 立即播放 must play 线路二 · 第1集 (and reuse prewarmed result with 0 extra api.play calls), NOT revert to 线路一!
    await tester.tap(find.text('立即播放'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(host.opened, hasLength(1));
    final opened = host.opened.single;
    expect((opened.startLineIndex, opened.startEpisodeIndex), (1, 0));
    expect((opened.initialSource?.videoWidth, opened.initialSource?.videoHeight), (1080, 1920));
    expect(api.calls, hasLength(2), reason: 'must reuse prewarmed 线路二 PlayResult');

    await router.onPageClosed(PageClosedEvent(sessionId: opened.sessionId, positionSeconds: 10, completed: false));
    await tester.pumpAndSettle();
  });

  testWidgets('DetailScreen loads history, favorite, and remembered dimensions even when site resolves after initState',
      (tester) async {
    await favorites.toggle(const VodItem(id: 'vod_late', name: '延迟站点短剧', siteKey: 'shortdrama'));
    await history.record(const ProgressEntry(
      item: VodItem(id: 'vod_late', name: '延迟站点短剧', siteKey: 'shortdrama'),
      lineIndex: 1,
      episodeIndex: 1,
      episodeName: '第2集',
      positionSeconds: 20,
      durationSeconds: 90,
      updatedAt: 0,
      videoWidth: 720,
      videoHeight: 1280,
    ));

    final runtimeCompleter = Completer<SpiderRuntime?>();
    final api = _TrackingPlayApi(inlineVideoSize: null);
    final lateDetail = VodDetail(
      item: const VodItem(id: 'vod_late', name: '延迟站点短剧', siteKey: 'shortdrama'),
      lines: detail.lines,
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [
        catpawRuntimeProvider.overrideWith((ref) => runtimeCompleter.future),
        historyRepositoryProvider.overrideWithValue(history),
        favoriteRepositoryProvider.overrideWithValue(favorites),
        playerConfigRepositoryProvider.overrideWithValue(playerConfigs),
        settingsStoreProvider.overrideWithValue(settingsStore),
        tmdbProvider.overrideWith((ref) async => null),
        videoDetailProvider.overrideWith((ref, q) async {
          await runtimeCompleter.future;
          return lateDetail;
        }),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildAppTheme(Brightness.light),
        home: const DetailScreen(vodId: 'vod_late', siteKey: 'shortdrama', enablePrewarmInTest: true),
      ),
    ));
    // At initState, catpawRuntimeProvider is still loading so siteByKeyProvider('shortdrama') is null.
    await tester.pump();
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);

    // Runtime now finishes loading.
    runtimeCompleter.complete(SpiderRuntime(
      subscription: const Subscription(key: 's1', name: 'sub'),
      api: api,
      sites: const [site],
    ));
    await tester.pumpAndSettle();

    // Favorite icon, remembered VOD dimensions, and history line/episode prewarm all sync properly!
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    expect(VideoFormatProbe.shared.cachedVod(vodKey('shortdrama', 'vod_late')), (width: 720, height: 1280));
    expect(api.calls, [('线路二', 'l2_ep2')]);
  });

  testWidgets('PlayerSettingsScreen forwards orientation changes to an active PlayerSession via updateRuntimeConfig',
      (tester) async {
    final host = _TestHost();
    final activeSession = PlayerSession(
      sessionId: 'pip_session_1',
      source: DirectPlaybackSource.single(title: 'Demo', url: 'https://example.com/1.mp4'),
      host: host,
      sniffer: SnifferService(),
      onPreferences: (_) {},
    );

    await tester.binding.setSurfaceSize(const Size(500, 4000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer(overrides: [
      playerConfigRepositoryProvider.overrideWithValue(playerConfigs),
    ]);
    addTearDown(container.dispose);
    container.read(activePlayerSessionProvider.notifier).set(activeSession);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildAppTheme(Brightness.light),
        home: const PlayerSettingsScreen(),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('屏幕方向'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('始终竖屏'));
    await tester.pumpAndSettle();

    expect(host.runtimePatches, hasLength(1));
    expect(host.runtimePatches.single.$1, 'pip_session_1');
    expect(host.runtimePatches.single.$2.playbackConfig?.orientationMode, 'portrait');
  });

  testWidgets('DetailScreen re-warms invalidated episode cache upon returning from playback on the same episode',
      (tester) async {
    final api = _TrackingPlayApi();
    final host = _TestHost();
    final router = PlayerSessionRouter();
    final launcher = PlayerLauncher(
      configs: playerConfigs,
      sniffer: SnifferService(),
      host: host,
      router: router,
      installRouter: false,
      enableWakelock: () async {},
      disableWakelock: () async {},
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [
        catpawRuntimeProvider.overrideWith(
          (ref) async => SpiderRuntime(
            subscription: const Subscription(key: 's1', name: 'sub'),
            api: api,
            sites: const [site],
          ),
        ),
        homeSitesProvider.overrideWithValue(const [site]),
        historyRepositoryProvider.overrideWithValue(history),
        favoriteRepositoryProvider.overrideWithValue(favorites),
        playerConfigRepositoryProvider.overrideWithValue(playerConfigs),
        settingsStoreProvider.overrideWithValue(settingsStore),
        playerLauncherProvider.overrideWithValue(launcher),
        tmdbProvider.overrideWith((ref) async => null),
        videoDetailProvider.overrideWith((ref, q) async => detail),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildAppTheme(Brightness.light),
        home: const DetailScreen(vodId: 'vod_42', siteKey: 'shortdrama', enablePrewarmInTest: true),
      ),
    ));
    await tester.pumpAndSettle();
    expect(api.calls, [('线路一', 'l1_ep1')]);

    // Click 立即播放 -> opens using prewarmed result (still 1 call).
    await tester.tap(find.text('立即播放'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(host.opened, hasLength(1));
    expect(api.calls, hasLength(1));

    // Playback fails on expired token (invalidating VodEpisodePrewarmCache) and user returns to DetailScreen on same episode.
    final sId = host.opened.single.sessionId;
    await router.onErrorReported(ErrorReport(sessionId: sId, message: 'HTTP 403', fatal: true));
    await router.onPageClosed(PageClosedEvent(sessionId: sId, positionSeconds: 5, completed: false));
    await tester.pumpAndSettle();

    // DetailScreen must re-warm (线路一, l1_ep1) immediately on return instead of being blocked by stale _lastWarmedTarget!
    expect(api.calls, [('线路一', 'l1_ep1'), ('线路一', 'l1_ep1')]);
  });
}
