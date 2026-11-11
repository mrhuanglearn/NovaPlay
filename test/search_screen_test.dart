import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/app/providers.dart';
import 'package:uzv_reimpl/app/theme.dart';
import 'package:uzv_reimpl/app/ui_hooks.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/features/catpaw/spider_api.dart';
import 'package:uzv_reimpl/features/search/search_state.dart';
import 'package:uzv_reimpl/features/subscription/subscription.dart';
import 'package:uzv_reimpl/l10n/l10n.dart';
import 'package:uzv_reimpl/models/vod.dart';
import 'package:uzv_reimpl/ui/search_screen.dart';

// OBSERVED on the phone (UZN 1.1.7, 2026-11-10, keyword 九门): results come in site by site, only sites with results
// are listed (in the order they answered, with their count); three layouts (列表 / 顶部站点分类 / 左侧站点分类);
// 搜索历史 chips with a clear button that asks first; 站点搜索管理 switches sites and searches again at once; clearing
// the field comes back to the history. Before 2026-11-10 UZV waited for every site and showed one poster grid.

const _live = SpiderSite(key: 'live', name: '「直」直播', api: '/spider/live/3');
const _huban = SpiderSite(key: 'huban', name: '「盘」虎斑', api: '/spider/huban/3');
const _none = SpiderSite(key: 'none', name: '「盘」空空', api: '/spider/none/3');
const _fail = SpiderSite(key: 'fail', name: '「盘」失败', api: '/spider/fail/3');
const _mycloud = SpiderSite(key: 'mycloud', name: '「盘」我的', api: '/spider/mycloud/3', searchable: false);
const _push = SpiderSite(key: 'push', name: '「推」推送', api: '/spider/push/4', type: 4);

void main() {
  group('SearchHistoryRepository', () {
    test('newest first, each keyword once, at most 20, and clear', () async {
      final repo = SearchHistoryRepository(store: _MemoryStore('h.json'));
      await repo.add('九门');
      await repo.add(' 老九门 ');
      expect(await repo.add('九门'), ['九门', '老九门']);
      expect(await repo.add('   '), ['九门', '老九门'], reason: 'blank keywords are not kept');
      for (var i = 0; i < 30; i++) {
        await repo.add('k$i');
      }
      final all = await repo.all();
      expect(all.length, SearchHistoryRepository.limit);
      expect(all.first, 'k29');
      await repo.clear();
      expect(await repo.all(), isEmpty);
    });
  });

  test('SearchPrefs keep the layout and each subscription its own switched-off sites', () {
    final s = const SearchPrefs(layout: SearchLayout.top, sitesOff: {'labi'})
        .writeTo({'other': 1, 'searchSitesOff': {'b': ['x']}}, 'a');
    expect(s['other'], 1);
    expect(s['searchLayout'], 'top');
    expect(s['searchSitesOff'], {'b': ['x'], 'a': ['labi']});
    expect(SearchPrefs.fromSettings(s, 'a').sitesOff, {'labi'});
    expect(SearchPrefs.fromSettings(s, 'b').sitesOff, {'x'});
    expect(SearchPrefs.fromSettings(const {}, 'a').layout, SearchLayout.left);
  });

  test('SearchRun lists sites in the order they answer and only those with results', () async {
    final api = _FakeApi();
    final run = SearchRun(keyword: '九门', sites: const [_live, _huban, _none, _fail], api: api);
    var changes = 0;
    run.addListener(() => changes++);
    api.release('huban');
    await pumpEventQueue();
    expect(run.results.map((r) => r.site.key), ['huban']);
    expect(run.done, isFalse);
    api.release('none');
    api.release('fail');
    api.release('live');
    await pumpEventQueue();
    expect(run.results.map((r) => r.site.key), ['huban', 'live']);
    expect(run.allItems.map((i) => i.name), ['九门', '老九门', '老九门2']);
    expect(run.done, isTrue);
    expect(run.error, isNull, reason: 'some sites answered');
    expect(changes, 4);
    run.dispose();

    final api2 = _FakeApi();
    final failed = SearchRun(keyword: 'x', sites: const [_fail], api: api2);
    api2.release('fail');
    await pumpEventQueue();
    expect(failed.error, isA<DioException>());
  });

  group('search page', () {
    late _FakeApi api;
    late _MemoryStore settings;
    late _MemoryStore history;

    setUp(() {
      api = _FakeApi()..autoRelease = true;
      settings = _MemoryStore('settings.json');
      history = _MemoryStore('search_history.json');
    });

    Future<ProviderContainer> pump(WidgetTester tester, {String initialQuery = ''}) async {
      final container = ProviderContainer(overrides: [
        settingsStoreProvider.overrideWithValue(settings),
        searchHistoryRepositoryProvider.overrideWithValue(SearchHistoryRepository(store: history)),
        subscriptionsProvider.overrideWith((ref) async => const [Subscription(key: 'mock', name: 'catpaw')]),
        catpawRuntimeProvider.overrideWith((ref) async => SpiderRuntime(
            subscription: const Subscription(key: 'mock', name: 'catpaw'),
            api: api,
            sites: const [_live, _huban, _none, _mycloud, _push])),
      ]);
      addTearDown(container.dispose);
      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          scaffoldMessengerKey: rootMessengerKey,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildAppTheme(Brightness.dark),
          home: SearchScreen(initialQuery: initialQuery),
        ),
      ));
      await tester.pumpAndSettle();
      return container;
    }

    Future<void> search(WidgetTester tester, String keyword) async {
      await tester.enterText(find.byType(TextField), keyword);
      await tester.tap(find.widgetWithText(FilledButton, '搜索'));
      await tester.pumpAndSettle();
    }

    testWidgets('left layout by default: the site column with counts, then the chosen site', (tester) async {
      await pump(tester);
      expect(find.text('搜索影视'), findsOneWidget, reason: 'no history yet');
      await search(tester, '九门');
      expect(api.searched, unorderedEquals(['live', 'huban', 'none', 'mycloud']),
          reason: 'every type 3 site, searchable: 0 too (as the original); not the type 4 push site');
      expect(find.text('「直」直播'), findsWidgets);
      expect(find.text('「盘」虎斑'), findsWidgets);
      expect(find.text('「盘」空空'), findsNothing, reason: 'sites without results are not listed');
      expect(find.text('2'), findsOneWidget); // 虎斑's count
      // the first site's card: title, vod_remarks, site tag
      final first = api.order.firstWhere((k) => k != 'none') == 'live' ? '老九门2' : '九门';
      expect(find.text(first), findsOneWidget);
      await tester.tap(find.text('「直」直播').first);
      await tester.pumpAndSettle();
      expect(find.text('老九门2'), findsOneWidget);
      expect(find.text('YY · zonghe'), findsOneWidget);
    });

    testWidgets('/search?q= (the TMDB and 追剧日历 jumps) searches at once and keeps the keyword', (tester) async {
      await pump(tester, initialQuery: '九门');
      expect(api.searched, unorderedEquals(['live', 'huban', 'none', 'mycloud']));
      expect(find.byType(SearchResultCard), findsWidgets);
      expect(await history.read<List<dynamic>>(const []), ['九门']);
    });

    testWidgets('列表 shows every result; 顶部站点分类 shows a tab per site with its count; the choice is kept',
        (tester) async {
      await pump(tester);
      await search(tester, '九门');
      await tester.tap(find.byTooltip('切换布局'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('列表'));
      await tester.pumpAndSettle();
      final cards = find.byType(SearchResultCard);
      for (final t in ['老九门2', '九门', '老九门']) {
        expect(find.descendant(of: cards, matching: find.text(t)), findsOneWidget);
      }
      expect(((await settings.read<Map<String, dynamic>>(const {})))['searchLayout'], 'list');

      await tester.tap(find.byTooltip('切换布局'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('顶部站点分类'));
      await tester.pumpAndSettle();
      expect(find.text('「直」直播 (1)'), findsOneWidget);
      expect(find.text('「盘」虎斑 (2)'), findsOneWidget);
    });

    testWidgets('closing the layout menu or the site sheet does not focus the field again (no keyboard)',
        (tester) async {
      await pump(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await search(tester, '九门');
      bool fieldFocused() => tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus;
      expect(fieldFocused(), isFalse);
      await tester.tap(find.byTooltip('切换布局'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('列表'));
      await tester.pumpAndSettle();
      expect(fieldFocused(), isFalse);
      await tester.tap(find.byTooltip('站点搜索管理'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(200, 60));
      await tester.pumpAndSettle();
      expect(fieldFocused(), isFalse);
    });

    testWidgets('history: newest first, a chip searches again, clearing the field returns, clearing asks first',
        (tester) async {
      await pump(tester);
      await search(tester, '九门');
      await tester.tap(find.byIcon(Icons.cancel));
      await tester.pumpAndSettle();
      expect(find.text('搜索历史'), findsOneWidget);
      expect(find.widgetWithText(InkWell, '九门'), findsOneWidget);

      api.searched.clear();
      await tester.tap(find.widgetWithText(InkWell, '九门'));
      await tester.pumpAndSettle();
      expect(api.searched, isNotEmpty);
      expect(find.byType(SearchResultCard), findsWidgets);

      await tester.tap(find.byIcon(Icons.cancel));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('清空搜索历史'));
      await tester.pumpAndSettle();
      expect(find.text('确定清空全部搜索历史吗？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('搜索历史'), findsOneWidget, reason: 'cancel keeps it');
      await tester.tap(find.byTooltip('清空搜索历史'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '清空搜索历史'));
      await tester.pumpAndSettle();
      expect(find.text('搜索历史'), findsNothing);
      expect(await history.read<List<dynamic>>(const []), isEmpty);
    });

    testWidgets('站点搜索管理: switching a site off leaves it out and searches again at once', (tester) async {
      await pump(tester);
      await search(tester, '九门');
      await tester.tap(find.byTooltip('站点搜索管理'));
      await tester.pumpAndSettle();
      expect(find.text('站点搜索管理'), findsWidgets);
      expect(find.text('「盘」我的'), findsOneWidget, reason: 'listed and on, as in the original');
      expect(find.text('「推」推送'), findsNothing, reason: 'type 4');
      expect(find.byIcon(Icons.search_off_rounded), findsNothing);

      api.searched.clear();
      await tester.tap(find.text('「盘」虎斑').last);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.search_off_rounded), findsOneWidget);
      expect(api.searched, unorderedEquals(['live', 'none', 'mycloud']));
      final saved = (await settings.read<Map<String, dynamic>>(const {}))['searchSitesOff'];
      expect(saved, {'mock': ['huban']});

      await tester.tapAt(const Offset(200, 60)); // the scrim
      await tester.pumpAndSettle();
      expect(find.text('「盘」虎斑'), findsNothing);
      expect(find.text('「直」直播'), findsWidgets);
    });
  });
}

class _FakeApi extends SpiderApi {
  _FakeApi() : super(0);

  bool autoRelease = false;
  final searched = <String>[];
  final order = <String>[];
  final _gates = <String, Completer<void>>{};

  void release(String key) => (_gates[key] ??= Completer<void>()).complete();

  @override
  Future<PagedVods> search(SpiderSite site, String keyword, {int page = 1}) async {
    searched.add(site.key);
    if (!autoRelease) await (_gates[site.key] ??= Completer<void>()).future;
    order.add(site.key);
    if (site.key == 'fail') {
      throw DioException.badResponse(
          statusCode: 500,
          requestOptions: RequestOptions(),
          response: Response(requestOptions: RequestOptions(), statusCode: 500, data: {'message': 'boom'}));
    }
    final items = switch (site.key) {
      'live' => const [VodItem(id: 'l1', name: '老九门2', remarks: 'YY · zonghe', siteKey: 'live')],
      'huban' => const [
          VodItem(id: 'h1', name: '九门', remarks: 'HQ60帧', siteKey: 'huban'),
          VodItem(id: 'h2', name: '老九门', remarks: '4K', siteKey: 'huban'),
        ],
      _ => const <VodItem>[],
    };
    return PagedVods(items: items, page: 1, pageCount: 1);
  }
}

class _MemoryStore extends JsonStore {
  _MemoryStore(super.name);
  Object? _data;

  @override
  Future<T> read<T>(T fallback) async => (_data as T?) ?? fallback;

  @override
  Future<void> write(Object? json) async => _data = json;
}
