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
import 'package:uzv_reimpl/features/subscription/subscription.dart';
import 'package:uzv_reimpl/l10n/l10n.dart';
import 'package:uzv_reimpl/models/vod.dart';
import 'package:uzv_reimpl/ui/home_screen.dart';
import 'package:uzv_reimpl/ui/load_error.dart';
import 'package:uzv_reimpl/ui/widgets.dart';

// OBSERVED on the original (2026-11-09, a mock subscription with five sites): switching site loads the new site's
// first category even when its id equals the previous one; grey placeholders show while it loads; HTTP 500 shows
// 加载失败 / "HTTP 500：<message>" / 重新加载; filters are laid out inline (年份 全部 2025 …) and a picked value is sent as
// `filters`, 全部 removes the key. Before 2026-11-10 UZV kept showing the previous site's posters (issue 1).

const _a = SpiderSite(key: 'a', name: '配置站点', api: '/spider/a/3');
const _b = SpiderSite(key: 'b', name: '第二站点', api: '/spider/b/3');
const _fail = SpiderSite(key: 'fail', name: '失败站点', api: '/spider/fail/3');

const _filters = [
  VodFilter(key: 'year', name: '年份', values: [MapEntry('全部', ''), MapEntry('2025', '2025')]),
  VodFilter(key: 'by', name: '排序', init: 'time', values: [MapEntry('最新', 'time'), MapEntry('最热', 'hits')]),
];

void main() {
  late _FakeApi api;
  late _MemoryStore settings;

  setUp(() {
    api = _FakeApi();
    settings = _MemoryStore('settings.json');
  });

  Future<ProviderContainer> pump(WidgetTester tester) async {
    final container = ProviderContainer(overrides: [
      settingsStoreProvider.overrideWithValue(settings),
      subscriptionsProvider.overrideWith((ref) async => const [Subscription(key: 'mock', name: 'catpaw')]),
      catpawRuntimeProvider.overrideWith((ref) async => SpiderRuntime(
          subscription: const Subscription(key: 'mock', name: 'catpaw'), api: api, sites: const [_a, _b, _fail])),
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
        home: const HomeScreen(),
      ),
    ));
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> switchTo(WidgetTester tester, String from, String to, {bool settle = true}) async {
    await tester.tap(find.text(from));
    await tester.pumpAndSettle();
    await tester.tap(find.text(to).last);
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
  }

  testWidgets('switching to a site whose first category has the same id loads that site', (tester) async {
    await pump(tester);
    expect(find.text('a-电影-1'), findsOneWidget);
    await switchTo(tester, '配置站点', '第二站点');
    expect(find.text('b-电影-1'), findsOneWidget);
    expect(find.text('a-电影-1'), findsNothing);
    _expectCall(api.categoryCalls.last, 'b', '1', 1, const {});
  });

  testWidgets('while the first page loads, grey poster placeholders are shown', (tester) async {
    await pump(tester);
    final gate = Completer<void>();
    api.gates['b'] = gate;
    await switchTo(tester, '配置站点', '第二站点', settle: false);
    expect(find.byType(VodSkeletonGrid), findsOneWidget);
    expect(find.text('a-电影-1'), findsNothing);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(VodSkeletonGrid), findsNothing);
    expect(find.text('b-电影-1'), findsOneWidget);
  });

  // User report (2026-11-10, phone): switching site showed no loading activity for ~10 s. The poster placeholders
  // were 0 dp wide (a childless DecoratedBox under a loosely constrained Column), so only the title bars showed.
  testWidgets('the placeholders are poster sized and a spinner turns over them', (tester) async {
    await pump(tester);
    final gate = Completer<void>();
    api.gates['b'] = gate;
    await switchTo(tester, '配置站点', '第二站点', settle: false);
    final posters = find.byKey(VodSkeletonGrid.posterKey);
    expect(posters, findsWidgets);
    // the column count follows MediaQuery (800 wide in tests), so only the shape is checked: as wide as a grid cell
    final size = tester.getSize(posters.first);
    final columns = posters.evaluate().length / 4;
    expect(size.width, greaterThan((420 - 22 - 11 * (columns - 1)) / columns - 1));
    expect(size.height, greaterThan(size.width));
    expect(find.descendant(of: find.byType(VodSkeletonGrid), matching: find.byType(CircularProgressIndicator)),
        findsOneWidget);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a failing category shows 加载失败 with the reason; 重新加载 asks again', (tester) async {
    await pump(tester);
    await switchTo(tester, '配置站点', '失败站点');
    expect(find.text('加载失败'), findsOneWidget);
    expect(find.text('HTTP 500：mock category failure'), findsOneWidget);
    expect(find.text('电影'), findsOneWidget); // the category tabs stay
    final calls = api.categoryCalls.length;
    api.failing.remove('fail');
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    expect(api.categoryCalls.length, calls + 1);
    expect(find.text('fail-电影-1'), findsOneWidget);
    expect(find.text('加载失败'), findsNothing);
  });

  testWidgets('the chosen site is back after a restart', (tester) async {
    await pump(tester);
    await switchTo(tester, '配置站点', '第二站点');
    expect((await settings.read<Map<String, dynamic>>(const {}))['homeSite'], {'mock': 'b'});

    await tester.pumpWidget(const SizedBox()); // "close the app"
    api.categoryCalls.clear();
    await pump(tester);
    expect(find.text('第二站点'), findsOneWidget);
    expect(find.text('b-电影-1'), findsOneWidget);
    expect(api.categoryCalls.map((c) => c.$1), ['b'], reason: 'the first site must not be loaded for nothing');
  });

  testWidgets('a saved site that is gone falls back to the first one', (tester) async {
    await settings.write({
      'homeSite': {'mock': 'removed'}
    });
    await pump(tester);
    expect(find.text('配置站点'), findsOneWidget);
    expect(find.text('a-电影-1'), findsOneWidget);
  });

  group('filters', () {
    setUp(() => api.filters = _filters);

    testWidgets('are laid out inline; the init value (or 全部) is selected', (tester) async {
      await pump(tester);
      expect(find.text('筛选'), findsNothing);
      for (final t in ['年份', '全部', '2025', '排序', '最新', '最热']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      final ctx = tester.element(find.text('年份'));
      Color? colorOf(String t) => tester.widget<Text>(find.text(t)).style?.color;
      expect(colorOf('全部'), AppColors.of(ctx).accent);
      expect(colorOf('最新'), AppColors.of(ctx).accent);
      expect(colorOf('2025'), isNot(AppColors.of(ctx).accent));
      expect(api.categoryCalls.single.$4, isEmpty); // init values are not sent
    });

    testWidgets('picking a value reloads with it; 全部 leaves the key out', (tester) async {
      await pump(tester);
      await tester.tap(find.text('2025'));
      await tester.pumpAndSettle();
      _expectCall(api.categoryCalls.last, 'a', '1', 1, {'year': '2025'});
      expect(find.text('a-电影-1 2025'), findsOneWidget);
      await tester.tap(find.text('最新'));
      await tester.pumpAndSettle();
      expect(api.categoryCalls.last.$4, {'year': '2025', 'by': 'time'});
      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();
      expect(api.categoryCalls.last.$4, {'by': 'time'});
    });

    testWidgets('隐藏筛选 hides the rows', (tester) async {
      await pump(tester);
      await tester.tap(find.byIcon(Icons.tune));
      await tester.pumpAndSettle();
      await tester.tap(find.text('隐藏筛选'));
      await tester.pumpAndSettle();
      expect(find.text('年份'), findsNothing);
      expect(find.text('a-电影-1'), findsOneWidget);
    });
  });

  group('request bodies match the original', () {
    late List<(String, Object?)> sent;
    late SpiderApi real;

    setUp(() {
      sent = [];
      final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:1'))
        ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
          sent.add((o.path, o.data));
          h.resolve(Response(requestOptions: o, statusCode: 200, data: <String, dynamic>{}));
        }));
      real = SpiderApi(1, dio: dio);
    });

    test('home asks for filters', () async {
      await real.home(_a);
      expect(sent.single.$1, '/spider/a/3/home');
      expect(sent.single.$2, {'filter': true});
    });

    test('category sends filter + filters', () async {
      await real.category(_a, '1', page: 2);
      await real.category(_a, '1', filters: {'year': '2025'});
      expect(sent[0].$2, {'id': '1', 'page': 2, 'filter': false, 'filters': <String, String>{}});
      expect(sent[1].$2, {
        'id': '1',
        'page': 1,
        'filter': true,
        'filters': {'year': '2025'}
      });
    });
  });

  group('describeLoadError', () {
    final l = lookupAppLocalizations(const Locale('zh'));
    DioException bad(int code, Object? data) => DioException.badResponse(
        statusCode: code,
        requestOptions: RequestOptions(),
        response: Response(requestOptions: RequestOptions(), statusCode: code, data: data));

    test('HTTP errors show the code and the script message', () {
      expect(describeLoadError(bad(500, {'error': 'mock category failure'}), l), 'HTTP 500：mock category failure');
      expect(describeLoadError(bad(404, {'message': 'no such site'}), l), 'HTTP 404：no such site');
      expect(describeLoadError(bad(502, null), l), 'HTTP 502');
    });

    // OBSERVED on the phone (2026-11-10, 「盘」木偶 whose site answered 403): catpaw's error body is fastify's
    // `{statusCode, error: <reason phrase>, message}` and the original shows the message.
    test('a fastify error body shows its message, not the reason phrase', () {
      expect(
          describeLoadError(
              bad(500, {
                'statusCode': 500,
                'error': 'Internal Server Error',
                'message': 'Request failed with status code 403',
              }),
              l),
          'HTTP 500：Request failed with status code 403');
    });

    test('timeouts and refused connections use the original wording', () {
      expect(
          describeLoadError(DioException.receiveTimeout(timeout: Duration.zero, requestOptions: RequestOptions()), l),
          '连接 catpaw 服务超时，请稍后重试');
      expect(describeLoadError(DioException.connectionError(requestOptions: RequestOptions(), reason: 'refused'), l),
          '无法连接 catpaw 服务，请确认本地服务已启动');
      expect(describeLoadError(Exception('boom'), l), 'boom');
    });
  });
}

void _expectCall(
    (String, String, int, Map<String, String>) call, String site, String type, int page, Map<String, String> filters) {
  expect((call.$1, call.$2, call.$3), (site, type, page));
  expect(call.$4, filters);
}

class _FakeApi extends SpiderApi {
  _FakeApi() : super(0);

  final categoryCalls = <(String, String, int, Map<String, String>)>[];
  final gates = <String, Completer<void>>{};
  final failing = <String>{'fail'};
  List<VodFilter> filters = const [];

  @override
  Future<void> init(SpiderSite site) async {}

  @override
  Future<HomeData> home(SpiderSite site) async => HomeData(categories: [
        VodCategory(id: '1', name: '电影', filters: site.key == 'a' ? filters : const []),
        const VodCategory(id: '2', name: '剧集'),
      ], featured: const []);

  @override
  Future<PagedVods> category(SpiderSite site, String typeId,
      {int page = 1, Map<String, String> filters = const {}}) async {
    categoryCalls.add((site.key, typeId, page, Map.of(filters)));
    await gates[site.key]?.future;
    if (failing.contains(site.key)) {
      throw DioException.badResponse(
          statusCode: 500,
          requestOptions: RequestOptions(),
          response:
              Response(requestOptions: RequestOptions(), statusCode: 500, data: {'error': 'mock category failure'}));
    }
    final name =
        '${site.key}-${typeId == '1' ? '电影' : '剧集'}-$page${filters['year'] == null ? '' : ' ${filters['year']}'}';
    return PagedVods(
        items: [VodItem(id: '${site.key}$typeId', name: name, siteKey: site.key)], page: page, pageCount: 1);
  }
}

/// A JsonStore in memory: widget tests run on a fake clock where real file I/O never completes.
class _MemoryStore extends JsonStore {
  _MemoryStore(super.name);
  Object? _data;

  @override
  Future<T> read<T>(T fallback) async => (_data as T?) ?? fallback;

  @override
  Future<void> write(Object? json) async => _data = json;
}
