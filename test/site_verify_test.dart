import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/app/theme.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/features/catpaw/site_auth.dart';
import 'package:uzv_reimpl/features/catpaw/spider_api.dart';
import 'package:uzv_reimpl/l10n/l10n.dart';
import 'package:uzv_reimpl/ui/widgets.dart';

class _MemStore extends JsonStore {
  _MemStore(super.name);
  Object? _data;

  @override
  Future<T> read<T>(T fallback) async => (_data as T?) ?? fallback;

  @override
  Future<void> write(Object? json) async => _data = json;
}

void main() {
  const libvioOn = SpiderSite(
    key: 'nodejs_libvio',
    name: '「盘」立播',
    api: '/spider/libvio/3',
    browserVerify: true,
    verifyUrl: 'https://libvio.host',
  );
  const libvioOff = SpiderSite(
    key: 'nodejs_libvio',
    name: '「盘」立播',
    api: '/spider/libvio/3',
    browserVerify: false,
  );
  const customOn = SpiderSite(
    key: 'demo',
    name: '「盘」示例',
    api: '/spider/demo/3',
    browserVerify: true,
  );

  test('SpiderSite.fromJson parses browserVerify (1/0/true/false) and verifyUrl from CatPaw /config', () {
    final sOn = SpiderSite.fromJson({
      'key': 'nodejs_libvio',
      'name': '「盘」立播',
      'api': '/spider/libvio/3',
      'browserVerify': 1,
      'verifyUrl': 'https://libvio.host',
    });
    expect(sOn.browserVerify, isTrue);
    expect(sOn.verifyUrl, 'https://libvio.host');

    final sOff = SpiderSite.fromJson({
      'key': 'nodejs_libvio',
      'name': '「盘」立播',
      'api': '/spider/libvio/3',
      'browserVerify': 0,
    });
    expect(sOff.browserVerify, isFalse, reason: 'explicit 0/false from CatPaw disables 403 verify even on libvio');

    final sLegacyLibvio = SpiderSite.fromJson({
      'key': 'nodejs_libvio',
      'name': '「盘」立播',
      'api': '/spider/libvio/3',
    });
    expect(sLegacyLibvio.browserVerify, isTrue, reason: 'legacy bundles without browserVerify keep built-in libvio default');

    final sDefault = SpiderSite.fromJson({
      'key': 'nodejs_pomo',
      'name': '「盘」Pomo',
      'api': '/spider/pomo/3',
    });
    expect(sDefault.browserVerify, isFalse);
  });

  test('SiteAuthRepository persists verified cookie, userAgent, and origin per site', () async {
    final repo = SiteAuthRepository(store: _MemStore('site_verifications.json'));
    await repo.save(const SiteAuthEntry(
      siteKey: 'Libvio',
      origin: 'https://libvio.host/',
      cookie: '__cdn_clearance=abc',
      userAgent: 'Mozilla/5.0 Mobile',
      updatedAt: 100,
    ));
    final loaded = await repo.get('libvio');
    expect(loaded, isNotNull);
    expect(loaded!.origin, 'https://libvio.host');
    expect(loaded.cookie, '__cdn_clearance=abc');
    expect(loaded.userAgent, 'Mozilla/5.0 Mobile');

    await repo.remove('libvio');
    expect(await repo.get('libvio'), isNull);
  });

  test('detectSiteVerifyChallenge strictly respects site.browserVerify and skips when false', () {
    final hubErr = DioException.badResponse(
      statusCode: 500,
      requestOptions: RequestOptions(path: '/spider/libvio/3/category'),
      response: Response(
        requestOptions: RequestOptions(path: '/spider/libvio/3/category'),
        statusCode: 500,
        data: {'statusCode': 500, 'message': 'HTTP 502 for http://45.192.199.124:3006/libvio/show/1--------1---.html'},
      ),
    );
    final c1 = detectSiteVerifyChallenge(
      hubErr,
      libvioOn,
      subscriptionHubUrl: 'http://mrhuang:mrhuang@45.192.199.124:3006/index.js.md5',
      statusCode: 500,
      responseData: hubErr.response?.data,
    );
    expect(c1, isNotNull);
    expect(c1!.verifyUrl, 'https://libvio.host/');

    // Same site & 403 error, but browserVerify == false -> MUST NOT trigger!
    final err403 = DioException.badResponse(
      statusCode: 403,
      requestOptions: RequestOptions(path: '/spider/libvio/3/category'),
      response: Response(
        requestOptions: RequestOptions(path: '/spider/libvio/3/category'),
        statusCode: 403,
        data: {'code': 'BROWSER_VERIFY_REQUIRED', 'message': 'HTTP 403 for https://libvio.host/show/1.html'},
      ),
    );
    expect(
      detectSiteVerifyChallenge(err403, libvioOff, statusCode: 403, responseData: err403.response?.data),
      isNull,
    );

    final direct403 = DioException.badResponse(
      statusCode: 403,
      requestOptions: RequestOptions(path: '/spider/demo/3/category'),
      response: Response(
        requestOptions: RequestOptions(path: '/spider/demo/3/category'),
        statusCode: 403,
        data: {'code': 'BROWSER_VERIFY_REQUIRED', 'message': 'HTTP 403 for https://mirror.example.org/vodshow/1.html'},
      ),
    );
    final c2 = detectSiteVerifyChallenge(
      direct403,
      customOn,
      statusCode: 403,
      responseData: direct403.response?.data,
    );
    expect(c2, isNotNull);
    expect(c2!.verifyUrl, 'https://mirror.example.org/');
  });

  testWidgets('ErrorState shows browser verification only when site.browserVerify is true', (tester) async {
    final err = DioException.badResponse(
      statusCode: 403,
      requestOptions: RequestOptions(path: '/spider/libvio/3/category'),
      response: Response(
        requestOptions: RequestOptions(path: '/spider/libvio/3/category'),
        statusCode: 403,
        data: {'message': 'HTTP 403 for https://libvio.host/show/1--------1---.html'},
      ),
    );

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildAppTheme(Brightness.dark),
      home: Scaffold(body: ErrorState(error: err, site: libvioOn, onRetry: () {})),
    ));
    await tester.pumpAndSettle();
    expect(find.text('「盘」立播 需要浏览器安全验证'), findsOneWidget);
    expect(find.text('去内置浏览器验证'), findsOneWidget);

    // When browserVerify is false, ErrorState renders standard failure without browser verification buttons.
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildAppTheme(Brightness.dark),
      home: Scaffold(body: ErrorState(error: err, site: libvioOff, onRetry: () {})),
    ));
    await tester.pumpAndSettle();
    expect(find.text('「盘」立播 需要浏览器安全验证'), findsNothing);
    expect(find.text('去内置浏览器验证'), findsNothing);
    expect(find.text('加载失败'), findsOneWidget);
  });
}
