import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uzv_reimpl/app/app_preferences.dart';
import 'package:uzv_reimpl/app/providers.dart';
import 'package:uzv_reimpl/app/site_prefs.dart';
import 'package:uzv_reimpl/app/theme.dart';
import 'package:uzv_reimpl/app/ui_hooks.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/core/node_bridge.dart';
import 'package:uzv_reimpl/features/catpaw/catpaw_client.dart';
import 'package:uzv_reimpl/features/catpaw/catpaw_recovery.dart';
import 'package:uzv_reimpl/features/catpaw/dart_callback_server.dart';
import 'package:uzv_reimpl/features/catpaw/spider_api.dart';
import 'package:uzv_reimpl/features/subscription/subscription.dart';
import 'package:uzv_reimpl/l10n/l10n.dart';
import 'package:uzv_reimpl/models/vod.dart';
import 'package:uzv_reimpl/ui/category_filters.dart';
import 'package:uzv_reimpl/ui/home_screen.dart';
import 'package:uzv_reimpl/ui/subscriptions_screen.dart';
import 'package:uzv_reimpl/ui/widgets.dart';

class _MemoryStore extends JsonStore {
  _MemoryStore(super.name, [this._data]);
  Object? _data;

  @override
  Future<T> read<T>(T fallback) async => (_data as T?) ?? fallback;

  @override
  Future<void> write(Object? json) async => _data = json;
}

class _MemorySubscriptionInstaller extends SubscriptionInstaller {
  _MemorySubscriptionInstaller(this._remoteScripts, {this.installGate});

  final Map<String, String> _remoteScripts;
  final Future<void>? installGate;
  final Map<String, InstalledScript> _installed = {};

  static String md5Of(String s) => md5.convert(utf8.encode(s)).toString();

  @override
  Future<InstalledScript?> installedScript(Subscription sub) async => _installed[sub.key];

  @override
  Future<InstalledScript> install(Subscription sub, {Future<bool> Function()? confirmConfigMismatch}) async {
    if (installGate != null) await installGate;
    final url = sub.indexJsUrl;
    final body = url == null ? null : _remoteScripts[url];
    if (body == null) throw StateError('404 for $url');
    final res = InstalledScript(scriptPath: '/mem/${sub.key}/index.js', configPath: null, md5: md5Of(body));
    _installed[sub.key] = res;
    return res;
  }

  @override
  Future<void> discard(Subscription sub) async {
    _installed.remove(sub.key);
  }
}

class _NoopNodeBridge extends NodeBridge {
  final _channels = <String, StreamController<String>>{};

  StreamController<String> _ctrl(String ch) => _channels.putIfAbsent(ch, StreamController<String>.broadcast);

  @override
  Future<void> start() async {}

  @override
  Stream<String> listen(String channel) => _ctrl(channel).stream;

  @override
  Future<void> send(String channel, String message) async {
    if (channel != 'catpaw') return;
    final cmd = jsonDecode(message) as Map<String, dynamic>;
    final action = cmd['action'] as String?;
    final name = cmd['name'] as String? ?? '';
    if (action == 'uninstall' || action == 'stop') {
      _ctrl('catpaw').add(jsonEncode({'type': 'list', 'instances': const []}));
      _ctrl('catpaw').add(jsonEncode({'type': 'result', 'action': action, 'name': name, 'ok': true}));
    }
  }
}

void main() {
  group('Issue 1: fast scroll / secondary global refresh guards', () {
    testWidgets('horizontal scroll inside CategoryFilterBar header does not fire VodGrid onNearEnd', (tester) async {
      var nearEndCalls = 0;
      final filters = [
        VodFilter(
          key: 'genre',
          name: '类型',
          init: '',
          values: [for (var i = 0; i < 20; i++) MapEntry('分类$i', '$i')],
        ),
      ];
      final items = [for (var i = 0; i < 30; i++) VodItem(id: '$i', name: '影片$i')];

      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(
          body: VodGrid(
            items: items,
            header: CategoryFilterBar(filters: filters, chosen: const {}, onChanged: (_, __) {}),
            onNearEnd: () => nearEndCalls++,
          ),
        ),
      ));
      await tester.pump();
      nearEndCalls = 0;

      // Fling the horizontal filter list rapidly — must NOT trigger vertical pagination!
      await tester.fling(find.text('分类2'), const Offset(-300, 0), 2000);
      await tester.pumpAndSettle();
      expect(nearEndCalls, 0);

      // Fling the vertical poster grid to the bottom — MUST trigger pagination!
      await tester.fling(find.text('影片3'), const Offset(0, -1800), 3000);
      await tester.pumpAndSettle();
      expect(nearEndCalls, greaterThan(0));
    });

    testWidgets('tapping an already-selected filter chip or category tab does not trigger a secondary reload',
        (tester) async {
      var categoryRequests = 0;
      const site = SpiderSite(key: 'wanou', name: '玩偶', api: '/spider/wanou/3');
      const sub = Subscription(key: 's1', name: 'sub', cloudUrl: 'http://127.0.0.1:9321');
      const homeData = HomeData(
        categories: [
          VodCategory(
            id: 'movie',
            name: '电影',
            filters: [
              VodFilter(
                key: 'year',
                name: '年份',
                init: '',
                values: [MapEntry('全部', ''), MapEntry('2026', '2026')],
              ),
            ],
          ),
          VodCategory(id: 'tv', name: '剧集'),
        ],
        featured: [],
      );

      final container = ProviderContainer(overrides: [
        settingsStoreProvider.overrideWithValue(_MemoryStore('settings.json', <String, dynamic>{})),
        initialAppPreferencesProvider.overrideWithValue(const AppPreferences()),
        subscriptionsProvider.overrideWith((ref) async => const [sub]),
        catpawRuntimeProvider.overrideWith(
          (ref) async => SpiderRuntime(subscription: sub, api: SpiderApi(9321, baseUrl: sub.cloudUrl), sites: const [site]),
        ),
        videoFeedProvider.overrideWith((ref) async => homeData),
        videoCategoryFeedProvider.overrideWithValue((q) async {
          categoryRequests++;
          return PagedVods(
            items: [VodItem(id: 'v$categoryRequests', name: '电影条目$categoryRequests')],
            page: q.page,
            pageCount: 1,
          );
        }),
      ]);
      addTearDown(container.dispose);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildAppTheme(Brightness.dark),
          home: const HomeScreen(),
        ),
      ));
      await tester.pumpAndSettle();
      expect(categoryRequests, 1);
      expect(find.text('电影条目1'), findsOneWidget);

      // Re-tapping '全部' (already empty) or active category ('电影') must NOT reload!
      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('电影'));
      await tester.pumpAndSettle();
      expect(categoryRequests, 1);
      expect(find.text('电影条目1'), findsOneWidget);

      // Tapping '2026' reloads once; tapping '2026' a second time must NOT reload again!
      await tester.tap(find.text('2026'));
      await tester.pumpAndSettle();
      expect(categoryRequests, 2);
      await tester.tap(find.text('2026'));
      await tester.pumpAndSettle();
      expect(categoryRequests, 2);
    });

    test('currentSiteProvider waits while selectedHomeSiteProvider reloads for a switched subscription', () async {
      const siteFirst = SpiderSite(key: 'dytt', name: '电影天堂', api: '/dytt');
      const siteSaved = SpiderSite(key: 'wanou', name: '玩偶', api: '/wanou');
      const subA = Subscription(key: 'subA', name: 'A', cloudUrl: 'http://127.0.0.1:9001');
      const subB = Subscription(key: 'subB', name: 'B', cloudUrl: 'http://127.0.0.1:9002');
      var activeSub = subA;

      final settings = _MemoryStore('settings.json', <String, dynamic>{
        'homeSite': {'subA': 'dytt', 'subB': 'wanou'},
      });
      final container = ProviderContainer(overrides: [
        settingsStoreProvider.overrideWithValue(settings),
        initialAppPreferencesProvider.overrideWithValue(const AppPreferences()),
        catpawRuntimeProvider.overrideWith(
          (ref) async => SpiderRuntime(
            subscription: activeSub,
            api: SpiderApi(9001, baseUrl: activeSub.cloudUrl),
            sites: const [siteFirst, siteSaved],
          ),
        ),
      ]);
      addTearDown(container.dispose);

      final seenSites = <String>[];
      container.listen<SpiderSite?>(currentSiteProvider, (_, next) {
        if (next != null) seenSites.add('${activeSub.key}:${next.key}');
      }, fireImmediately: true);

      await container.read(catpawRuntimeProvider.future);
      await container.read(selectedHomeSiteProvider.future);
      await container.read(sitePrefsProvider.future);
      await Future<void>.delayed(Duration.zero);
      expect(seenSites, ['subA:dytt']);

      seenSites.clear();
      activeSub = subB;
      container.invalidate(catpawRuntimeProvider);
      await container.read(catpawRuntimeProvider.future);
      await container.read(selectedHomeSiteProvider.future);
      await container.read(sitePrefsProvider.future);
      await Future<void>.delayed(Duration.zero);

      // Must NOT transiently emit 'subB:dytt' (sites.first) before 'subB:wanou'!
      expect(seenSites, ['subB:wanou']);
    });

    test('CatpawSupervisor.onAppResumed does not restart when runtime has no currentApi yet', () async {
      var restarts = 0;
      final bridge = _NoopNodeBridge();
      final cb = DartCallbackServer(handlers: const {});
      addTearDown(cb.stop);
      final supervisor = CatpawSupervisor(
        catpaw: CatpawClient(bridge),
        callbackServer: cb,
        activeSubscription: () async => const Subscription(key: 's1', name: 'sub', indexJsUrl: 'http://x/index.js'),
        currentApi: () => null,
        isRuntimeStarting: () => false,
        restartInstance: (_) async {
          restarts++;
          return 2333;
        },
      );
      expect(await supervisor.onAppResumed(), isNull);
      expect(restarts, 0);
    });
  });

  group('Issue 2: edit subscription source and refresh on active edit/delete', () {
    testWidgets('EditSubscriptionScreen edits URL & saves, refreshing active runtime', (tester) async {
      const urlV1 = 'http://127.0.0.1:3006/v1/index.js.md5';
      const urlV2 = 'http://127.0.0.1:3006/v2/index.js.md5';
      const scriptV1 = 'module.exports = { v: 1 };';
      const scriptV2 = 'module.exports = { v: 2 };';

      final repo = SubscriptionRepository(store: _MemoryStore('subscriptions.json'));
      final installer = _MemorySubscriptionInstaller({urlV1: scriptV1, urlV2: scriptV2});
      final service = SubscriptionService(repository: repo, installer: installer);
      final sub = await service.addNetwork(url: urlV1, name: 'First');

      var runtimeBuilds = 0;
      final container = ProviderContainer(overrides: [
        settingsStoreProvider.overrideWithValue(_MemoryStore('settings.json', <String, dynamic>{
          'activeSubscription': sub.key,
        })),
        initialAppPreferencesProvider.overrideWithValue(const AppPreferences()),
        subscriptionRepositoryProvider.overrideWithValue(repo),
        subscriptionInstallerProvider.overrideWithValue(installer),
        subscriptionServiceProvider.overrideWithValue(service),
        nodeBridgeProvider.overrideWithValue(_NoopNodeBridge()),
        catpawRuntimeProvider.overrideWith((ref) async {
          runtimeBuilds++;
          final subs = await ref.watch(subscriptionsProvider.future);
          if (subs.isEmpty) return null;
          return SpiderRuntime(
            subscription: subs.first,
            api: SpiderApi(9321, baseUrl: 'http://127.0.0.1:9321'),
            sites: const [],
          );
        }),
      ]);
      addTearDown(container.dispose);

      await container.read(catpawRuntimeProvider.future);
      expect(runtimeBuilds, 1);

      final router = GoRouter(
        initialLocation: '/subscriptions',
        routes: [
          GoRoute(path: '/subscriptions', builder: (_, __) => const SubscriptionsScreen()),
          GoRoute(
            path: '/subscriptions/edit/:subKey',
            builder: (_, s) => EditSubscriptionScreen(subKey: s.pathParameters['subKey']!),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildAppTheme(Brightness.dark),
          scaffoldMessengerKey: rootMessengerKey,
          routerConfig: router,
        ),
      ));
      await tester.pumpAndSettle();

      // Open edit screen for the active subscription.
      await tester.tap(find.text('First'));
      await tester.pumpAndSettle();

      // Edit URL and Name, then tap 保存.
      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(2));
      await tester.enterText(fields.at(0), urlV2);
      await tester.enterText(fields.at(1), 'EditedSub');
      await tester.pump();

      await tester.tap(find.text('保存'));
      await tester.pump();
      // Advance past showSuccessHud's 1300ms auto-dismiss timer.
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      final saved = (await repo.all()).single;
      expect(saved.name, 'EditedSub');
      expect(saved.indexJsUrl, urlV2);
      expect(saved.installedMd5, _MemorySubscriptionInstaller.md5Of(scriptV2));
      expect(runtimeBuilds, greaterThanOrEqualTo(2));
      expect(find.text('EditedSub'), findsOneWidget);
    });

    testWidgets('deleting the active subscription switches to remaining source and refreshes runtime', (tester) async {
      final repo = SubscriptionRepository(store: _MemoryStore('subscriptions.json'));
      final installer = _MemorySubscriptionInstaller(const {});
      final service = SubscriptionService(repository: repo, installer: installer);
      final subA = await service.addCloud(url: 'http://127.0.0.1:9001', name: 'ActiveCloud');
      final subB = await service.addCloud(url: 'http://127.0.0.1:9002', name: 'BackupCloud');

      var runtimeBuilds = 0;
      String? lastRuntimeKey;
      final container = ProviderContainer(overrides: [
        settingsStoreProvider.overrideWithValue(_MemoryStore('settings.json', <String, dynamic>{
          'activeSubscription': subA.key,
        })),
        initialAppPreferencesProvider.overrideWithValue(const AppPreferences()),
        subscriptionRepositoryProvider.overrideWithValue(repo),
        subscriptionInstallerProvider.overrideWithValue(installer),
        subscriptionServiceProvider.overrideWithValue(service),
        nodeBridgeProvider.overrideWithValue(_NoopNodeBridge()),
        catpawRuntimeProvider.overrideWith((ref) async {
          runtimeBuilds++;
          final subs = await ref.watch(subscriptionsProvider.future);
          if (subs.isEmpty) {
            lastRuntimeKey = null;
            return null;
          }
          final key = await ref.watch(activeSubscriptionKeyProvider.future);
          final chosen = subs.firstWhere((s) => s.key == key, orElse: () => subs.first);
          lastRuntimeKey = chosen.key;
          return SpiderRuntime(
            subscription: chosen,
            api: SpiderApi(9001, baseUrl: chosen.cloudUrl),
            sites: const [],
          );
        }),
      ]);
      addTearDown(container.dispose);

      await container.read(catpawRuntimeProvider.future);
      expect(lastRuntimeKey, subA.key);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildAppTheme(Brightness.dark),
          scaffoldMessengerKey: rootMessengerKey,
          home: const SubscriptionsScreen(),
        ),
      ));
      await tester.pumpAndSettle();

      // Enter batch edit mode, select the ACTIVE subscription, and delete it!
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ActiveCloud'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '删除'));
      await tester.pumpAndSettle();

      expect((await repo.all()).map((s) => s.key), [subB.key]);
      expect(await container.read(activeSubscriptionKeyProvider.future), subB.key);
      await container.read(catpawRuntimeProvider.future);
      expect(lastRuntimeKey, subB.key);
      expect(runtimeBuilds, greaterThanOrEqualTo(2));
    });

    testWidgets('deleting the active subscription from EditSubscriptionScreen refreshes runtime to empty when last',
        (tester) async {
      final repo = SubscriptionRepository(store: _MemoryStore('subscriptions.json'));
      final installer = _MemorySubscriptionInstaller(const {});
      final service = SubscriptionService(repository: repo, installer: installer);
      final subA = await service.addCloud(url: 'http://127.0.0.1:9001', name: 'OnlyActive');

      SpiderRuntime? latestRuntime;
      var runtimeBuilds = 0;
      final container = ProviderContainer(overrides: [
        settingsStoreProvider.overrideWithValue(_MemoryStore('settings.json', <String, dynamic>{
          'activeSubscription': subA.key,
        })),
        initialAppPreferencesProvider.overrideWithValue(const AppPreferences()),
        subscriptionRepositoryProvider.overrideWithValue(repo),
        subscriptionInstallerProvider.overrideWithValue(installer),
        subscriptionServiceProvider.overrideWithValue(service),
        nodeBridgeProvider.overrideWithValue(_NoopNodeBridge()),
        catpawRuntimeProvider.overrideWith((ref) async {
          runtimeBuilds++;
          final subs = await ref.watch(subscriptionsProvider.future);
          if (subs.isEmpty) return latestRuntime = null;
          return latestRuntime = SpiderRuntime(
            subscription: subs.first,
            api: SpiderApi(9001, baseUrl: subs.first.cloudUrl),
            sites: const [],
          );
        }),
      ]);
      addTearDown(container.dispose);

      await container.read(catpawRuntimeProvider.future);
      expect(latestRuntime, isNotNull);

      final router = GoRouter(
        initialLocation: '/subscriptions',
        routes: [
          GoRoute(path: '/subscriptions', builder: (_, __) => const SubscriptionsScreen()),
          GoRoute(
            path: '/subscriptions/edit/:subKey',
            builder: (_, s) => EditSubscriptionScreen(subKey: s.pathParameters['subKey']!),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildAppTheme(Brightness.dark),
          scaffoldMessengerKey: rootMessengerKey,
          routerConfig: router,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('OnlyActive'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('删除订阅'));
      await tester.tap(find.text('删除订阅'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '删除'));
      await tester.pumpAndSettle();

      expect(await repo.all(), isEmpty);
      expect(await container.read(activeSubscriptionKeyProvider.future), isNull);
      await container.read(catpawRuntimeProvider.future);
      expect(latestRuntime, isNull);
      expect(runtimeBuilds, greaterThanOrEqualTo(2));
    });

    testWidgets('leaving AddSubscriptionScreen mid-download still refreshes list and activates on finish',
        (tester) async {
      const slowUrl = 'http://127.0.0.1:3006/slow/index.js.md5';
      final gate = Completer<void>();
      final repo = SubscriptionRepository(store: _MemoryStore('subscriptions.json'));
      final installer = _MemorySubscriptionInstaller({slowUrl: 'module.exports = {};'}, installGate: gate.future);
      final service = SubscriptionService(repository: repo, installer: installer);
      final first = await service.addCloud(url: 'http://127.0.0.1:9001', name: 'Existing');

      String? activeRuntimeKey;
      final container = ProviderContainer(overrides: [
        settingsStoreProvider.overrideWithValue(_MemoryStore('settings.json', <String, dynamic>{
          'activeSubscription': first.key,
        })),
        initialAppPreferencesProvider.overrideWithValue(const AppPreferences()),
        subscriptionRepositoryProvider.overrideWithValue(repo),
        subscriptionInstallerProvider.overrideWithValue(installer),
        subscriptionServiceProvider.overrideWithValue(service),
        nodeBridgeProvider.overrideWithValue(_NoopNodeBridge()),
        catpawRuntimeProvider.overrideWith((ref) async {
          final subs = await ref.watch(subscriptionsProvider.future);
          final key = await ref.watch(activeSubscriptionKeyProvider.future);
          final sub = subs.firstWhere((s) => s.key == key, orElse: () => subs.first);
          activeRuntimeKey = sub.key;
          return SpiderRuntime(
            subscription: sub,
            api: SpiderApi(9001, baseUrl: 'http://127.0.0.1:9001'),
            sites: const [],
          );
        }),
      ]);
      addTearDown(container.dispose);

      final router = GoRouter(
        initialLocation: '/subscriptions',
        routes: [
          GoRoute(path: '/subscriptions', builder: (_, __) => const SubscriptionsScreen()),
          GoRoute(path: '/subscriptions/add', builder: (_, __) => const AddSubscriptionScreen()),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildAppTheme(Brightness.dark),
          scaffoldMessengerKey: rootMessengerKey,
          routerConfig: router,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), slowUrl);
      await tester.enterText(fields.at(1), 'SlowAdded');
      final installBtn = find.text('安装不受信任的订阅');
      await tester.ensureVisible(installBtn);
      await tester.tap(installBtn);
      await tester.pump();

      // Leave the add page before the download finishes (cannot pumpAndSettle while button CircularProgressIndicator spins).
      Navigator.of(tester.element(find.byType(AddSubscriptionScreen))).pop();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(AddSubscriptionScreen), findsNothing);

      // Finish the background download: list refreshes and active subscription switches without unmounted-ref error.
      gate.complete();
      await tester.pumpAndSettle();

      expect(find.text('SlowAdded'), findsOneWidget);
      final added = (await repo.all()).firstWhere((s) => s.name == 'SlowAdded');
      expect(await container.read(activeSubscriptionKeyProvider.future), added.key);
      await container.read(catpawRuntimeProvider.future);
      expect(activeRuntimeKey, added.key);
    });
  });
}
