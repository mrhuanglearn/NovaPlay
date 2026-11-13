import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uzv_reimpl/app/providers.dart';
import 'package:uzv_reimpl/app/site_prefs.dart';
import 'package:uzv_reimpl/app/theme.dart';
import 'package:uzv_reimpl/app/ui_hooks.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/features/catpaw/spider_api.dart';
import 'package:uzv_reimpl/features/subscription/subscription.dart';
import 'package:uzv_reimpl/l10n/l10n.dart';
import 'package:uzv_reimpl/models/vod.dart';
import 'package:uzv_reimpl/ui/home_screen.dart';
import 'package:uzv_reimpl/ui/site_switch_sheet.dart';

// User report (2026-11-13, Android phone): on the home page with 「荐」豆瓣 (a) no poster showed, (b) every poster opened
// 未找到, and (c) 切换站点 lacked the buttons at its top right. OBSERVED on UZN the same day: 豆瓣 posters show, tapping one
// opens 搜索 with its title, and 切换站点 has 单列/双列, a globe (the subscription's web page) and a gear (站点设置 with
// 启用 / 搜索 / 历史记录 / 上锁 per site).

const _douban = SpiderSite(key: 'nodejs_douban', name: '「荐」豆瓣', api: '/spider/douban/3', indexs: true);
const _a = SpiderSite(key: 'a', name: '「盘」玩偶', api: '/spider/a/3');
const _b = SpiderSite(key: 'b', name: '「盘」木偶', api: '/spider/b/3');

void main() {
  test('SpiderSite reads indexs from /config', () {
    expect(SpiderSite.fromJson({'key': 'd', 'name': 'd', 'api': '/x', 'indexs': 1}).indexs, isTrue);
    expect(SpiderSite.fromJson({'key': 'd', 'name': 'd', 'api': '/x'}).indexs, isFalse);
  });

  late _MemoryStore settings;
  late GoRouter router;

  setUp(() => settings = _MemoryStore());

  Future<ProviderContainer> pump(WidgetTester tester) async {
    final container = ProviderContainer(overrides: [
      settingsStoreProvider.overrideWithValue(settings),
      subscriptionsProvider.overrideWith((ref) async => const [Subscription(key: 'mock', name: 'catpaw')]),
      catpawRuntimeProvider.overrideWith((ref) async => SpiderRuntime(
          subscription: const Subscription(key: 'mock', name: 'catpaw'),
          api: _FakeApi(),
          sites: const [_douban, _a, _b])),
    ]);
    addTearDown(container.dispose);
    router = GoRouter(routes: [
      GoRoute(path: '/', builder: (c, s) => const HomeScreen()),
      GoRoute(path: '/search', builder: (c, s) => Text('search:${s.uri.queryParameters['q']}')),
      GoRoute(path: '/website', builder: (c, s) => Text('website:${s.uri.queryParameters['url']}')),
      GoRoute(path: '/video/detail', builder: (c, s) => Text('detail:${s.uri.queryParameters['id']}')),
    ]);
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        scaffoldMessengerKey: rootMessengerKey,
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildAppTheme(Brightness.light),
      ),
    ));
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
    await tester.pumpAndSettle();
  }

  testWidgets('a poster of an index site (indexs: 1) opens 搜索 with its title', (tester) async {
    await pump(tester);
    await tester.tap(find.text('可能的爱'));
    await tester.pumpAndSettle();
    expect(find.text('search:可能的爱'), findsOneWidget);
  });

  testWidgets('a poster of an ordinary site still opens its detail page', (tester) async {
    await pump(tester);
    await openSheet(tester);
    await tester.tap(find.text('「盘」玩偶').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('a-影片'));
    await tester.pumpAndSettle();
    expect(find.text('detail:a1'), findsOneWidget);
  });

  testWidgets('切换站点 has 单列/双列, globe and gear; 双列 is kept in settings', (tester) async {
    await pump(tester);
    await openSheet(tester);
    expect(find.text('切换站点'), findsOneWidget);
    expect(find.byKey(SiteSwitchSheet.gridToggleKey), findsOneWidget);
    expect(find.byKey(SiteSwitchSheet.websiteKey), findsOneWidget);
    expect(find.byKey(SiteSwitchSheet.settingsKey), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked), findsNothing);

    await tester.tap(find.byKey(SiteSwitchSheet.gridToggleKey));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_circle), findsOneWidget); // the current site
    expect(find.byIcon(Icons.radio_button_unchecked), findsNWidgets(2));
    expect((settings.data as Map)['siteSheetGrid'], isTrue);
  });

  testWidgets('the globe opens the subscription web page', (tester) async {
    await pump(tester);
    await openSheet(tester);
    await tester.tap(find.byKey(SiteSwitchSheet.websiteKey));
    await tester.pumpAndSettle();
    expect(find.text('website:http://127.0.0.1:0/website'), findsOneWidget);
  });

  testWidgets('站点设置: 启用 off hides a site from 切换站点 and search; 历史记录 and 搜索 switch', (tester) async {
    final c = await pump(tester);
    await openSheet(tester);
    await tester.tap(find.byKey(SiteSwitchSheet.settingsKey));
    await tester.pumpAndSettle();
    expect(find.text('站点设置'), findsOneWidget);
    expect(find.byTooltip('启用'), findsNWidgets(3));
    expect(find.byTooltip('历史记录'), findsNWidgets(3));
    expect(find.byTooltip('上锁'), findsNWidgets(3));

    final muou = find.ancestor(of: find.text('「盘」木偶'), matching: find.byType(Row)).first;
    await tester.tap(find.descendant(of: muou, matching: find.byTooltip('启用')));
    await tester.tap(find.descendant(of: muou, matching: find.byTooltip('历史记录')));
    await tester.tap(find.descendant(of: muou, matching: find.byTooltip('搜索')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.visibility_off), findsOneWidget);
    final prefs = c.read(sitePrefsProvider).value!;
    expect(prefs.disabled, {'b'});
    expect(prefs.recordsHistory('b'), isFalse);
    expect(c.read(searchPrefsProvider).value!.sitesOff, {'b'});
    expect(c.read(searchableSitesProvider).map((s) => s.key), ['nodejs_douban', 'a']);

    await tester.tap(find.byKey(SiteSwitchSheet.doneKey));
    await tester.pumpAndSettle();
    expect(find.text('切换站点'), findsOneWidget);
    expect(find.text('「盘」木偶'), findsNothing);
    expect(find.text('「盘」玩偶'), findsOneWidget);
  });

  testWidgets('上锁 asks 首次上锁, hides the site, and the padlock opens the lock again', (tester) async {
    await pump(tester);
    await openSheet(tester);
    await tester.tap(find.byKey(SiteSwitchSheet.settingsKey));
    await tester.pumpAndSettle();
    expect(find.byKey(SiteSwitchSheet.lockKey), findsNothing);

    final wanou = find.ancestor(of: find.text('「盘」玩偶'), matching: find.byType(Row)).first;
    await tester.tap(find.descendant(of: wanou, matching: find.byTooltip('上锁')));
    await tester.pumpAndSettle();
    expect(find.text('首次上锁'), findsOneWidget);
    await tester.tap(find.text('不设置'));
    await tester.pumpAndSettle();
    expect(find.text('「盘」玩偶'), findsNothing);
    expect(find.byKey(SiteSwitchSheet.lockKey), findsOneWidget);

    await tester.tap(find.byKey(SiteSwitchSheet.lockKey)); // empty password: opens without asking
    await tester.pumpAndSettle();
    expect(find.text('「盘」玩偶'), findsOneWidget);
    expect(find.byIcon(Icons.lock), findsOneWidget); // the site's padlock, now on
  });
}

class _FakeApi extends SpiderApi {
  _FakeApi() : super(0);

  @override
  Future<void> init(SpiderSite site) async {}

  @override
  Future<HomeData> home(SpiderSite site) async =>
      const HomeData(categories: [VodCategory(id: '1', name: '热播')], featured: []);

  @override
  Future<PagedVods> category(SpiderSite site, String typeId,
          {int page = 1, Map<String, String> filters = const {}}) async =>
      PagedVods(items: [
        site.key == 'nodejs_douban'
            ? VodItem(id: '36847425', name: '可能的爱', siteKey: site.key)
            : VodItem(id: '${site.key}1', name: '${site.key}-影片', siteKey: site.key),
      ], page: page, pageCount: 1);
}

/// settings.json in memory: widget tests run on a fake clock where real file I/O never completes.
class _MemoryStore extends JsonStore {
  _MemoryStore() : super('settings.json');
  Object? data;

  @override
  Future<T> read<T>(T fallback) async => (data as T?) ?? fallback;

  @override
  Future<void> write(Object? json) async => data = json;
}
