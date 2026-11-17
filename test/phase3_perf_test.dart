import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/app/providers.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/core/node_bridge.dart';
import 'package:uzv_reimpl/features/catpaw/catpaw_client.dart';
import 'package:uzv_reimpl/features/catpaw/catpaw_protocol.dart';
import 'package:uzv_reimpl/features/catpaw/spider_api.dart';
import 'package:uzv_reimpl/features/downloads/download_manager.dart';
import 'package:uzv_reimpl/features/search/search_state.dart';
import 'package:uzv_reimpl/features/subscription/subscription.dart';
import 'package:uzv_reimpl/features/tracking/tracking_service.dart';
import 'package:uzv_reimpl/models/vod.dart';
import 'package:uzv_reimpl/services/tmdb_client.dart';

class _TrackingSearchApi extends SpiderApi {
  _TrackingSearchApi() : super(0);
  int active = 0;
  int maxObservedActive = 0;
  int canceledCount = 0;

  @override
  Future<PagedVods> search(SpiderSite site, String keyword, {int page = 1, CancelToken? cancelToken}) async {
    active++;
    if (active > maxObservedActive) maxObservedActive = active;
    final gate = Completer<void>();
    cancelToken?.whenCancel.then((_) {
      canceledCount++;
      if (!gate.isCompleted) gate.complete();
    });
    Timer(const Duration(milliseconds: 50), () {
      if (!gate.isCompleted) gate.complete();
    });
    await gate.future;
    active--;
    if (cancelToken != null && cancelToken.isCancelled) {
      throw DioException.requestCancelled(requestOptions: RequestOptions(path: site.api), reason: 'disposed');
    }
    return PagedVods(items: [VodItem(id: site.key, name: 'Hit ${site.key}', siteKey: site.key)], page: 1, pageCount: 1);
  }
}

class _SlowTmdbClient extends TmdbClient {
  _SlowTmdbClient() : super(const TmdbSettings(enabled: true, apiKey: 'k'));
  int networkCalls = 0;

  @override
  Future<List<TmdbEpisode>> season(int tvId, int seasonNumber) {
    return cachedSeason(tvId, seasonNumber, () async {
      networkCalls++;
      await Future<void>.delayed(const Duration(milliseconds: 70));
      return [
        TmdbEpisode(number: 1, name: 'Ep $tvId', airDate: DateTime(2026, 11, 17)),
      ];
    });
  }
}

class _CountingProfileStore extends JsonStore {
  _CountingProfileStore(super.fileName, {super.baseDir});
  int reads = 0;
  int writes = 0;

  @override
  Future<T> read<T>(T fallback) {
    reads++;
    return super.read<T>(fallback);
  }

  @override
  Future<void> write(Object? json) {
    writes++;
    return super.write(json);
  }
}

class _FakeNodeBridge extends NodeBridge {
  final _controllers = <String, StreamController<String>>{};
  @override
  Future<void> start() async {
    _emit('status', 'Node ready, version v20.0.0');
  }

  void _emit(String ch, String msg) =>
      (_controllers[ch] ??= StreamController<String>.broadcast()).add(msg);

  @override
  Future<void> send(String channel, String message) async {
    if (channel == 'catpaw' && message.contains('"action":"start"')) {
      scheduleMicrotask(() {
        _emit('catpaw', '{"type":"port","name":"sub1","port":2333}');
        _emit('catpaw', '{"type":"result","action":"start","name":"sub1","ok":true}');
      });
    }
  }

  @override
  Stream<String> listen(String channel) =>
      (_controllers[channel] ??= StreamController<String>.broadcast()).stream;
}

class _SlowRemoteInstaller extends SubscriptionInstaller {
  _SlowRemoteInstaller(Directory root, this.remoteMd5Completer) : super(root: root);
  final Completer<String?> remoteMd5Completer;
  int remoteMd5Calls = 0;

  @override
  Future<InstalledScript?> installedScript(Subscription sub) async =>
      const InstalledScript(scriptPath: '/tmp/index.js', configPath: '/tmp/config.js', md5: 'old_md5');

  @override
  Future<String?> remoteMd5(Subscription sub) {
    remoteMd5Calls++;
    return remoteMd5Completer.future;
  }
}

void main() {
  group('Phase 3 Secondary Performance', () {
    test('3.1 SearchRun bounds concurrency and cancels in-flight requests on dispose', () async {
      final api = _TrackingSearchApi();
      final sites = List.generate(18, (i) => SpiderSite(key: 's$i', name: 'Site $i', api: '/spider/s$i/3'));
      final run = SearchRun(keyword: 'test', sites: sites, api: api, maxConcurrent: 4);

      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(api.maxObservedActive, lessThanOrEqualTo(4));

      run.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(api.canceledCount, greaterThan(0));
    });

    test('3.2 DownloadManager enforces global maxActiveTasks queue and throttles chunk progress events', () async {
      final dir = await Directory.systemTemp.createTemp('dl_phase3_');
      addTearDown(() => dir.delete(recursive: true));

      var activeHttp = 0;
      var maxActiveHttp = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        activeHttp++;
        if (activeHttp > maxActiveHttp) maxActiveHttp = activeHttp;
        req.response.statusCode = 200;
        req.response.bufferOutput = false;
        for (var i = 0; i < 40; i++) {
          req.response.add(const [1, 2, 3, 4]);
          await req.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        await req.response.close();
        activeHttp--;
      });

      final mgr = DownloadManager(maxActiveTasks: 2);
      var updateEventsForT0 = 0;
      final sub = mgr.updates.listen((t) {
        if (t.id == 't0') updateEventsForT0++;
      });
      addTearDown(sub.cancel);

      final tasks = List.generate(
        5,
        (i) => mgr.enqueue(DownloadTask(
          id: 't$i',
          title: 'Ep $i',
          url: 'http://127.0.0.1:${server.port}/ep$i.mp4',
          dir: '${dir.path}/t$i',
        )),
      );

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (tasks.any((t) => t.state != DownloadState.done) && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(tasks.every((t) => t.state == DownloadState.done), isTrue);
      expect(maxActiveHttp, lessThanOrEqualTo(2), reason: 'global active downloads must respect maxActiveTasks');
      expect(updateEventsForT0, lessThan(15), reason: '40 chunks within ~50ms must be throttled');
    });

    test('3.3 Startup autoUpdate starts installed script immediately without blocking on slow remoteMd5', () async {
      final dir = await Directory.systemTemp.createTemp('autoupdate_bg_');
      addTearDown(() => dir.delete(recursive: true));

      final spiderServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => spiderServer.close(force: true));
      spiderServer.listen((req) {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write('{"video":{"sites":[{"key":"demo","name":"Demo","api":"/spider/demo/3"}]}}')
          ..close();
      });

      final remoteGate = Completer<String?>();
      final installer = _SlowRemoteInstaller(dir, remoteGate);
      final bridge = _FakeNodeBridge();
      final subStore = JsonStore('subscriptions.json', baseDir: dir);
      await subStore.write([
        const Subscription(
          key: 'sub1',
          name: 'Sub 1',
          indexJsUrl: 'http://example.com/index.js.md5',
          autoUpdate: true,
          installedMd5: 'old_md5',
        ).toJson(),
      ]);

      final container = ProviderContainer(overrides: [
        nodeBridgeProvider.overrideWithValue(bridge),
        catpawClientProvider.overrideWith((ref) {
          final c = _PortOverrideCatpawClient(bridge, spiderServer.port);
          ref.onDispose(c.dispose);
          return c;
        }),
        subscriptionRepositoryProvider.overrideWithValue(SubscriptionRepository(store: subStore)),
        subscriptionInstallerProvider.overrideWithValue(installer),
        settingsStoreProvider.overrideWithValue(JsonStore('settings.json', baseDir: dir)),
        subscriptionProfilesStoreProvider.overrideWithValue(JsonStore('profiles.json', baseDir: dir)),
      ]);
      addTearDown(container.dispose);

      // Must resolve immediately even though remoteGate has NOT completed!
      final rt = await container.read(catpawRuntimeProvider.future).timeout(const Duration(seconds: 2));
      expect(rt?.sites.single.key, 'demo');
      expect(installer.remoteMd5Calls, 1);
      remoteGate.complete(null);
    });

    test('3.4 TrackingCalendar fetches seasons in parallel and reuses TmdbClient season cache across weeks', () async {
      final dir = await Directory.systemTemp.createTemp('tmdb_perf_');
      addTearDown(() => dir.delete(recursive: true));
      final store = TrackingStore(store: JsonStore('tracking.json', baseDir: dir));
      await store.add(TrackedShow(tmdbId: 101, title: 'Show A', season: 1));
      await store.add(TrackedShow(tmdbId: 102, title: 'Show B', season: 1));
      await store.add(TrackedShow(tmdbId: 103, title: 'Show C', season: 1));

      final tmdb = _SlowTmdbClient();
      final cal = TrackingCalendar(store, tmdb);

      final sw = Stopwatch()..start();
      final w1 = await cal.week(DateTime(2026, 11, 17));
      sw.stop();
      expect(w1, hasLength(3));
      expect(sw.elapsedMilliseconds, lessThan(180), reason: '3 x 70ms calls must run in parallel (<180ms vs >=210ms)');
      expect(tmdb.networkCalls, 3);

      // Switching to next week reuses cached seasons with 0 additional HTTP calls!
      final w2 = await cal.week(DateTime(2026, 11, 24));
      expect(w2, isEmpty);
      expect(tmdb.networkCalls, 3);
    });

    test('3.5 queryProfile serves clean profiles from memory cache without re-reading or re-writing store', () async {
      final dir = await Directory.systemTemp.createTemp('profile_cache_');
      addTearDown(() => dir.delete(recursive: true));
      final profileStore = _CountingProfileStore('subscription_profiles.json', baseDir: dir);
      await profileStore.write({
        'sub1': {'quark': {'cookie': 'ck_123'}},
      });
      final subStore = JsonStore('subscriptions.json', baseDir: dir);
      await subStore.write([
        const Subscription(key: 'sub1', name: 'Sub 1', indexJsUrl: 'http://x/index.js.md5').toJson(),
      ]);

      final container = ProviderContainer(overrides: [
        subscriptionProfilesStoreProvider.overrideWithValue(profileStore),
        subscriptionRepositoryProvider.overrideWithValue(SubscriptionRepository(store: subStore)),
        settingsStoreProvider.overrideWithValue(JsonStore('settings.json', baseDir: dir)),
      ]);
      addTearDown(container.dispose);

      final cb = container.read(dartCallbackServerProvider);
      final port = await cb.ensureRunning();
      addTearDown(cb.stop);

      final writesBefore = profileStore.writes;
      final dio = Dio(BaseOptions(headers: {'x-uzv-token': cb.token}));
      final r1 = await dio.post<Map<String, dynamic>>('http://127.0.0.1:$port/msg',
          data: {'action': DartActions.queryProfile, 'args': <String, dynamic>{}});
      expect(((r1.data?['quark']) as Map?)?['cookie'], 'ck_123');
      final readsAfterFirst = profileStore.reads;

      final r2 = await dio.post<Map<String, dynamic>>('http://127.0.0.1:$port/msg',
          data: {'action': DartActions.queryProfile, 'args': <String, dynamic>{}});
      expect(((r2.data?['quark']) as Map?)?['cookie'], 'ck_123');
      expect(profileStore.reads, readsAfterFirst, reason: 'second queryProfile hits cached sanitized profile');
      expect(profileStore.writes, writesBefore, reason: 'clean profile must never trigger redundant disk writes');
    });
  });
}

class _PortOverrideCatpawClient extends CatpawClient {
  _PortOverrideCatpawClient(super.bridge, this.portToReturn);
  final int portToReturn;

  @override
  Future<int> startAndWait({
    required String name,
    required String scriptPath,
    String? configPath,
    int? port,
    bool force = false,
    bool enableNetLog = false,
    bool enableLog = true,
    Map<String, String>? env,
    Duration timeout = const Duration(seconds: 20),
  }) async =>
      portToReturn;
}
