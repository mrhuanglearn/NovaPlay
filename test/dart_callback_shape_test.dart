import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uzv_reimpl/app/providers.dart';
import 'package:uzv_reimpl/app/router.dart';
import 'package:uzv_reimpl/features/catpaw/dart_callback_server.dart';
import 'package:uzv_reimpl/features/subscription/subscription.dart';
import 'package:uzv_reimpl/ui/poster_image.dart';
import 'package:uzv_reimpl/ui/widgets.dart';

// Only one request shape has been observed (`POST /msg {action, opt}`, below); the others are accepted in case other
// scripts use them, and each request's shape is logged so it can be read from the device.
void main() {
  bool known(String a) => a == 'openInternalWebview' || a == 'toast';

  test('POST /<action> with the arguments as the body; a "name" in the body is an argument', () {
    final c =
        resolveCall(Uri.parse('http://x/openInternalWebview'), {'url': 'http://h/website', 'name': 'x'}, known: known);
    expect(c.action, 'openInternalWebview');
    expect(c.args, {'url': 'http://h/website', 'name': 'x'});
  });

  test('{"action": .., "data": {..}} on any path', () {
    final c = resolveCall(Uri.parse('http://x/msg'), {
      'action': 'openInternalWebview',
      'data': {'url': 'u'}
    });
    expect(c.action, 'openInternalWebview');
    expect(c.args, {'url': 'u'});
  });

  // OBSERVED on the phone (2026-11-10): tapping 通用配置 in 「设」配置 makes the script send
  // `POST /msg {"action":"openInternalWebview","opt":{"url":<33 chars>}}`.
  test('the observed shape: POST /msg {action, opt: {..}}', () {
    final c = resolveCall(
        Uri.parse('http://127.0.0.1:1/msg'),
        {
          'action': 'openInternalWebview',
          'opt': {'url': 'http://192.168.4.159:2333/website'}
        },
        known: known);
    expect(c.action, 'openInternalWebview');
    expect(c.args, {'url': 'http://192.168.4.159:2333/website'});
  });

  test('a detail page still loading is replaced by the web page; anything else stays under it', () {
    final top = Uri(path: '/video/detail', queryParameters: {'id': 'openInternalWebsite', 'site': 'nodejs_baseset'});
    DetailQuery? asked;
    expect(
        webviewReplacesTop(top, (q) {
          asked = q;
          return true;
        }),
        isTrue);
    expect(asked, (siteKey: 'nodejs_baseset', vodId: 'openInternalWebsite'));
    expect(webviewReplacesTop(top, (_) => false), isFalse, reason: 'a loaded detail stays');
    expect(webviewReplacesTop(Uri(path: '/'), (_) => true), isFalse);
    expect(webviewReplacesTop(Uri(path: '/search'), (_) => true), isFalse);
  });

  test('?action= in the query, query parameters become arguments', () {
    final c = resolveCall(Uri.parse('http://x/?action=toast&msg=hi'), null);
    expect(c.action, 'toast');
    expect(c.args, {'msg': 'hi'});
  });

  // OBSERVED payload: `{action: toast, opt: {message: str(22), duration: 5}}`.
  test('a toast lasts the seconds it asks for, within 1..10 s', () {
    expect(toastDuration(5), const Duration(seconds: 5));
    expect(toastDuration('2.5'), const Duration(milliseconds: 2500));
    expect(toastDuration(4000), const Duration(seconds: 4), reason: 'large numbers are milliseconds');
    expect(toastDuration(60), const Duration(seconds: 10));
    expect(toastDuration(null), const Duration(seconds: 3));
    expect(toastDuration(0), const Duration(seconds: 3));
  });

  test('the log shows names and lengths, never values', () {
    expect(describeShape({'url': 'http://192.168.4.159:2333/website', 'action': 'openInternalWebview', 'n': 3}),
        '{url: str(33), action: openInternalWebview, n: 3}');
    expect(describeShape({'cookie': '__pus=abc; ctoken=xyz'}), '{cookie: str(21)}');
  });

  test('PosterImage normalizes local CatPaw LAN URLs to loopback and decodes data: URIs', () async {
    expect(
      PosterImage.normalizeLocalUrl('http://192.168.0.102:2333/spider/baseset/3/qr?text=abc', 2333),
      'http://127.0.0.1:2333/spider/baseset/3/qr?text=abc',
    );
    expect(
      PosterImage.normalizeLocalUrl('http://192.168.0.102:2333/spider/baseset/3/proxy/abc+def/ghi=?t=1', 2333),
      'http://127.0.0.1:2333/spider/baseset/3/proxy/abc%2Bdef%2Fghi=?t=1',
      reason: 'douer unencoded base64 proxy payload with raw / and + is URL-encoded',
    );
    expect(
      PosterImage.normalizeLocalUrl('http://192.168.0.121:3006/index.js', 2333),
      'http://192.168.0.121:3006/index.js',
      reason: 'non-local CatPaw port stays untouched',
    );
    final bytes = await PosterImage.fetchBytes('data:image/png;base64,iVBORw0KGgo=', const {});
    expect(bytes.length, 8);
    expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
  });

  testWidgets('openInternalWebview handler has no Riverpod cycle with catpawRuntimeProvider and normalizes port 9321',
      (tester) async {
    String? pushed;
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const SizedBox()),
        GoRoute(
          path: '/website',
          builder: (_, state) {
            pushed = state.uri.queryParameters['url'];
            return const SizedBox();
          },
        ),
      ],
    );
    final container = ProviderContainer(overrides: [
      routerProvider.overrideWithValue(router),
      subscriptionsProvider.overrideWith((ref) async => const <Subscription>[]),
    ]);
    addTearDown(() {
      PosterImage.localCatpawPort = 0;
      container.dispose();
    });

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pump();

    // Establish catpawRuntimeProvider alongside dartCallbackServerProvider, then set active local CatPaw port.
    await container.read(catpawRuntimeProvider.future);
    final cb = container.read(dartCallbackServerProvider);
    PosterImage.localCatpawPort = 2333;

    expect(
      await cb.handlers['openInternalWebview']!({'url': 'http://192.168.0.102:9321/douer'}),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(pushed, 'http://127.0.0.1:9321/douer');
  });

  test('detectQrBoundsForTest trims wide white margin around square QR modules', () async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 120, 120), Paint()..color = Colors.white);
    canvas.drawRect(const Rect.fromLTWH(30, 30, 60, 60), Paint()..color = Colors.black);
    final img = await recorder.endRecording().toImage(120, 120);
    addTearDown(img.dispose);

    final bounds = await detectQrBoundsForTest(img);
    expect(bounds, const Rect.fromLTWH(30, 30, 60, 60));
  });
}
