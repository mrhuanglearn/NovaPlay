import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/features/catpaw/catpaw_client.dart';
import 'package:uzv_reimpl/features/catpaw/catpaw_recovery.dart';
import 'package:uzv_reimpl/features/catpaw/dart_callback_server.dart';
import 'package:uzv_reimpl/features/catpaw/spider_api.dart';
import 'package:uzv_reimpl/features/subscription/subscription.dart';

import 'support/fake_bridge.dart';

void main() {
  test('DartCallbackServer.ensureRunning rebinds cleanly if closed during idle', () async {
    final server = DartCallbackServer(handlers: {
      'ping': (_) async => 'pong',
    });
    final p1 = await server.start();
    expect(p1, greaterThan(0));

    // Simulate socket closed during idle
    await server.stop();
    expect(server.port, isNull);

    final p2 = await server.ensureRunning();
    expect(p2, greaterThan(0));

    final http = HttpClient();
    final req = await http.postUrl(Uri.parse('http://127.0.0.1:$p2/ping'));
    req.write('{}');
    final res = await req.close();
    final body = jsonDecode(await utf8.decoder.bind(res).join()) as Map<String, dynamic>;
    expect(body['ok'], isTrue);
    expect(body['data'], 'pong');
    http.close(force: true);
    await server.stop();
  });

  test('CatpawClient clears portOf when list reports instance stopped or missing', () async {
    final bridge = FakeBridge();
    bridge.onSend = (channel, message) {
      final cmd = jsonDecode(message) as Map;
      if (channel == 'catpaw' && cmd['action'] == 'start') {
        scheduleMicrotask(
          () => bridge.emit('catpaw', jsonEncode({'type': 'port', 'name': cmd['name'], 'port': 2333})),
        );
      }
    };
    final client = CatpawClient(bridge);
    await client.attach();
    final port = await client.startAndWait(name: 'sub1', scriptPath: '/s/index.js');
    expect(port, 2333);
    expect(client.portOf('sub1'), 2333);

    // Non-running entry in list clears portOf
    bridge.emit(
      'catpaw',
      jsonEncode({
        'type': 'list',
        'services': [
          {'name': 'sub1', 'running': false, 'port': 2333},
        ],
      }),
    );
    await Future<void>.delayed(Duration.zero);
    expect(client.portOf('sub1'), isNull);
    await client.dispose();
  });

  test('SpiderApi recovers and transparently retries once on connectionError after idle', () async {
    final s1 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = s1.port;
    await s1.close(force: true);

    HttpServer? s2;
    addTearDown(() async => s2?.close(force: true));

    var recoverCalls = 0;
    final api = SpiderApi(
      deadPort,
      onConnectionErrorRecover: () async {
        recoverCalls++;
        s2 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        unawaited(s2!.forEach((req) async {
          req.response.headers.contentType = ContentType.json;
          if (req.uri.path == '/config') {
            req.response.write(jsonEncode({
              'video': {
                'sites': [
                  {'key': 'k1', 'name': 'Site 1', 'api': '/spider/k1/3'},
                ],
              },
            }));
          } else {
            req.response.write(jsonEncode({
              'class': [
                {'type_id': '1', 'type_name': '电影'},
              ],
              'list': [],
            }));
          }
          await req.response.close();
        }));
        return s2!.port;
      },
    );

    const site = SpiderSite(key: 'k1', name: 'Site 1', api: '/spider/k1/3');
    final home = await api.home(site);
    expect(recoverCalls, 1);
    expect(api.port, s2!.port);
    expect(api.baseUrl, 'http://127.0.0.1:${s2!.port}');
    expect(home.categories.single.name, '电影');
  });

  group('CatpawSupervisor', () {
    const localSub = Subscription(key: 'sub1', name: 'Demo', indexJsUrl: 'https://example.com/index.js');

    test('onAppResumed does nothing when /config probe is already healthy', () async {
      final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => srv.close(force: true));
      unawaited(srv.forEach((req) async {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write('{"video":{"sites":[]}}');
        await req.response.close();
      }));

      final bridge = FakeBridge();
      final client = CatpawClient(bridge);
      await client.attach();
      addTearDown(client.dispose);

      final callback = DartCallbackServer();
      addTearDown(callback.stop);

      final api = SpiderApi(srv.port);
      var restarts = 0;
      final supervisor = CatpawSupervisor(
        catpaw: client,
        callbackServer: callback,
        activeSubscription: () async => localSub,
        currentApi: () => api,
        restartInstance: (_) async {
          restarts++;
          return srv.port;
        },
      );

      final port = await supervisor.onAppResumed();
      expect(port, srv.port);
      expect(restarts, 0);
      expect(bridge.sent.where((e) => e.$2.contains('"reload"')), isEmpty);
    });

    test('recovers via reload first when socket died during idle, updating port if moved', () async {
      final deadSrv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final oldPort = deadSrv.port;
      await deadSrv.close(force: true);

      HttpServer? reloadedSrv;
      addTearDown(() async => reloadedSrv?.close(force: true));

      final bridge = FakeBridge();
      bridge.onSend = (channel, message) {
        final cmd = jsonDecode(message) as Map;
        if (channel != 'catpaw') return;
        if (cmd['action'] == 'start') {
          scheduleMicrotask(
            () => bridge.emit('catpaw', jsonEncode({'type': 'port', 'name': cmd['name'], 'port': oldPort})),
          );
        } else if (cmd['action'] == 'reload') {
          unawaited(() async {
            reloadedSrv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            unawaited(reloadedSrv!.forEach((req) async {
              req.response
                ..statusCode = 200
                ..headers.contentType = ContentType.json
                ..write('{"video":{"sites":[]}}');
              await req.response.close();
            }));
            bridge.emit('catpaw', jsonEncode({'type': 'port', 'name': cmd['name'], 'port': reloadedSrv!.port}));
            bridge.emit(
              'catpaw',
              jsonEncode({'type': 'result', 'action': 'reload', 'name': cmd['name'], 'ok': true}),
            );
          }());
        } else if (cmd['action'] == 'reloadDanmu') {
          scheduleMicrotask(
            () => bridge.emit(
              'catpaw',
              jsonEncode({'type': 'result', 'action': 'reloadDanmu', 'name': cmd['name'], 'ok': false}),
            ),
          );
        }
      };

      final client = CatpawClient(bridge);
      await client.attach();
      await client.startAndWait(name: localSub.key, scriptPath: '/s/index.js');
      addTearDown(client.dispose);

      final callback = DartCallbackServer();
      addTearDown(callback.stop);

      final api = SpiderApi(oldPort);
      var restarts = 0;
      final supervisor = CatpawSupervisor(
        catpaw: client,
        callbackServer: callback,
        activeSubscription: () async => localSub,
        currentApi: () => api,
        restartInstance: (_) async {
          restarts++;
          return 9999;
        },
      );

      final port = await supervisor.onAppResumed();
      expect(port, reloadedSrv!.port);
      expect(api.port, reloadedSrv!.port);
      expect(restarts, 0, reason: 'in-place reload succeeded so full worker restart was not needed');
    });

    test('falls back to restarting the worker when reload fails or worker exited', () async {
      final deadSrv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final oldPort = deadSrv.port;
      await deadSrv.close(force: true);

      HttpServer? freshSrv;
      addTearDown(() async => freshSrv?.close(force: true));

      final bridge = FakeBridge();
      final client = CatpawClient(bridge);
      await client.attach();
      // Notice client.portOf('sub1') is null (worker exited during idle!)
      addTearDown(client.dispose);

      final callback = DartCallbackServer();
      addTearDown(callback.stop);

      final api = SpiderApi(oldPort);
      var restarts = 0;
      final supervisor = CatpawSupervisor(
        catpaw: client,
        callbackServer: callback,
        activeSubscription: () async => localSub,
        currentApi: () => api,
        restartInstance: (_) async {
          restarts++;
          freshSrv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          unawaited(freshSrv!.forEach((req) async {
            req.response
              ..statusCode = 200
              ..headers.contentType = ContentType.json
              ..write('{"video":{"sites":[]}}');
            await req.response.close();
          }));
          return freshSrv!.port;
        },
      );

      final port = await supervisor.onAppResumed();
      expect(restarts, 1);
      expect(port, freshSrv!.port);
      expect(api.port, freshSrv!.port);
    });

    test('onAppResumed skips recovery while cold-start runtime is still loading', () async {
      final client = CatpawClient(FakeBridge());
      addTearDown(client.dispose);
      final callback = DartCallbackServer();
      addTearDown(callback.stop);
      var restarts = 0;
      final supervisor = CatpawSupervisor(
        catpaw: client,
        callbackServer: callback,
        activeSubscription: () async => localSub,
        currentApi: () => null,
        isRuntimeStarting: () => true,
        restartInstance: (_) async => ++restarts,
      );

      expect(await supervisor.onAppResumed(), isNull);
      expect(restarts, 0);
    });

    test('SpiderApi.ensureHealthy recovers dead listener and updates baseUrl before opening /website', () async {
      final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = dead.port;
      await dead.close(force: true);

      final api = SpiderApi(deadPort, onConnectionErrorRecover: () async => 2334);
      await api.ensureHealthy();
      expect(api.baseUrl, 'http://127.0.0.1:2334');
    });
  });
}
