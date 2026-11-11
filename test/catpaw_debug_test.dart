import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/app/providers.dart';
import 'package:uzv_reimpl/app/theme.dart';
import 'package:uzv_reimpl/app/ui_hooks.dart';
import 'package:uzv_reimpl/features/catpaw/catpaw_debug.dart';
import 'package:uzv_reimpl/features/catpaw/dart_callback_server.dart';
import 'package:uzv_reimpl/l10n/l10n.dart';
import 'package:uzv_reimpl/ui/catpaw_debug_screen.dart';

import 'support/fake_bridge.dart';

/// Plays the Node runtime: answers `list`, `start`, `stop` on the catpaw channel and the manager commands.
class _Node {
  _Node(this.bridge) {
    bridge.onSend = (channel, raw) {
      final cmd = jsonDecode(raw) as Map<String, dynamic>;
      final name = cmd['name'] as String?;
      if (channel == 'catpaw') {
        switch (cmd['action']) {
          case 'start':
            if (instances.containsKey(name) && cmd['force'] != true) {
              _emit('catpaw',
                  {'type': 'result', 'action': 'start', 'name': name, 'ok': false, 'error': 'already running: $name'});
            } else {
              instances[name!] = 40000 + instances.length;
              // As node_host/src/catpaw.js: the port, then the worker's start result; stop answers nothing.
              _emit('catpaw', {'type': 'port', 'name': name, 'port': instances[name]});
              _emit('catpaw', {'type': 'result', 'action': 'start', 'name': name, 'ok': true});
            }
          case 'stop':
            instances.remove(name);
          case 'list':
            _emit('catpaw', {
              'type': 'list',
              'services': [
                for (final e in instances.entries)
                  {'name': e.key, 'port': e.value, 'running': true, 'dataDir': '/data/${e.key}'}
              ],
            });
        }
      } else if (channel == 'manager') {
        final action = cmd['action'] as String;
        if (action == 'install') services[name!] = false;
        if (action == 'start') services[name!] = true;
        if (action == 'stop') services[name!] = false;
        if (action == 'uninstall') services.remove(name);
        if (action != 'list') _emit('manager', {'type': 'result', 'action': action, 'name': name, 'ok': true});
        _emit('manager', {
          'type': 'list',
          'services': [
            for (final e in services.entries) {'name': e.key, 'running': e.value, 'port': e.value ? 9000 : null}
          ],
        });
      }
    };
  }

  final FakeBridge bridge;
  final instances = <String, int>{};
  final services = <String, bool>{};
  final sent = <Map<String, dynamic>>[];

  void _emit(String channel, Map<String, Object?> event) =>
      scheduleMicrotask(() => bridge.emit(channel, jsonEncode(event)));
}

class _FakeCallbackServer extends DartCallbackServer {
  int? asked;
  @override
  Future<int> start({int? preferredPort}) async {
    asked = preferredPort;
    return preferredPort ?? 4321;
  }
}

void main() {
  test('instance names: given, else the URL account, else the md5 of the URL', () {
    expect(debugInstanceName('http://a/index.js', ' mine '), 'mine');
    expect(debugInstanceName('https://bob:secret@host/index.js', ''), 'bob');
    final hashed = debugInstanceName('http://192.168.240.1:8765/index.js', '');
    expect(hashed, matches(RegExp(r'^[0-9a-f]{32}$')));
  });

  test('accounts are taken out of every URL in log text', () {
    expect(redactUrls('[net] GET https://u:p@h.example/x → 200 and http://a@b/c'),
        '[net] GET https://h.example/x → 200 and http://b/c');
    expect(redactUrls('mail me@example.com'), 'mail me@example.com');
  });

  group('CatpawDebugController', () {
    late FakeBridge bridge;
    late _Node node;
    late _FakeCallbackServer callback;
    late Directory dir;
    late ProviderContainer c;
    HttpServer? server;

    HttpOverrides? testHttp;
    setUp(() {
      // flutter_test answers every HTTP request with 400; the download tests talk to a real local server.
      testHttp = HttpOverrides.current;
      HttpOverrides.global = null;
      bridge = FakeBridge();
      node = _Node(bridge);
      callback = _FakeCallbackServer();
      dir = Directory.systemTemp.createTempSync('uzv_debug');
      c = ProviderContainer(overrides: [
        nodeBridgeProvider.overrideWithValue(bridge),
        dartCallbackServerProvider.overrideWithValue(callback),
        catpawDebugDirProvider.overrideWithValue(() async => dir),
        catpawProbeProvider.overrideWithValue((port) async => port == 40000 ? 3 : throw StateError('down')),
      ]);
      c.listen(catpawDebugProvider, (previous, next) {});
    });
    tearDown(() async {
      HttpOverrides.global = testHttp;
      c.dispose();
      await server?.close(force: true);
      dir.deleteSync(recursive: true);
    });

    CatpawDebugController ctrl() => c.read(catpawDebugProvider.notifier);
    CatpawDebugState state() => c.read(catpawDebugProvider);
    List<Map<String, dynamic>> sentOn(String channel) => [
          for (final (ch, m) in bridge.sent)
            if (ch == channel) jsonDecode(m) as Map<String, dynamic>
        ];
    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

    test('Start Node attaches, announces the callback port and lists both channels', () async {
      await ctrl().startNode(dartPort: 5555);
      await settle();
      expect(bridge.started, isTrue);
      expect(callback.asked, 5555);
      expect(sentOn('catpaw').map((m) => m['action']), containsAllInOrder(['setDartPort', 'list']));
      expect(sentOn('catpaw').firstWhere((m) => m['action'] == 'setDartPort')['port'], 5555);
      expect(sentOn('manager').map((m) => m['action']), contains('list'));
      expect(state().node, DebugNodeState.running);
      expect(state().log.single.text, 'Node ready; dart callback :5555');
      expect(state().log.single.toString(), matches(RegExp(r'^\d\d:\d\d:\d\d  Node ready')));
    });

    test('with Node already up (the home page started it) nothing restarts', () async {
      await c.read(catpawClientProvider).attach();
      bridge.started = false;
      await ctrl().startNode();
      expect(bridge.started, isFalse);
      expect(state().log.single.text, 'Node 已在运行，跳过重复启动（回调沿用启动方端口）: 4321');
    });

    test('a runtime that cannot start goes back to the start card with the reason', () async {
      bridge.statusOnStart = 'Node runtime failed: dlopen failed';
      await ctrl().startNode();
      expect(state().node, DebugNodeState.idle);
      expect(state().lastResult, contains('catpaw 启动失败，请重试'));
      expect(state().lastResult, contains('dlopen failed'));
    });

    test('加载 catpaw 实例 downloads the script and starts it with the chosen switches; stop and 测试', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server!.listen((req) {
        final body = switch (req.uri.path) {
          '/index.js' => 'module.exports = {}',
          _ => null,
        };
        req.response.statusCode = body == null ? 404 : 200;
        if (body != null) req.response.write(body);
        req.response.close();
      });
      await ctrl().startNode();
      final url = 'http://u:pw@127.0.0.1:${server!.port}/index.js';
      await ctrl().loadInstance(url: url, name: 'dbg', port: 7777, force: true, netLog: false, serviceLog: true);
      await settle();

      final start = sentOn('catpaw').firstWhere((m) => m['action'] == 'start');
      expect(start['name'], 'dbg');
      expect(start['port'], 7777);
      expect(start['force'], isTrue);
      expect(start['enableNetLog'], isFalse);
      expect(start['enableLog'], isTrue);
      expect(File(start['path'] as String).readAsStringSync(), 'module.exports = {}');
      expect(start['path'], startsWith(dir.path));
      expect(state().lastResult, 'catpaw start dbg: ok :40000');
      expect(state().instances.single.name, 'dbg');
      expect(state().log.map((l) => l.text).join('\n'), isNot(contains('pw@')));
      // The runtime's own start result is not logged a second time.
      expect(state().log.where((l) => l.text.startsWith('catpaw start dbg')), hasLength(1));

      await ctrl().testInstance(state().instances.single);
      expect(state().lastResult, '测试 dbg: 3 个站点');

      await ctrl().stopInstance('dbg');
      await settle();
      expect(state().instances, isEmpty);
      expect(state().log.last.text, '停止 dbg');
    });

    test('loading a running instance without 强制重启 reports the runtime\'s refusal', () async {
      await ctrl().startNode();
      node.instances['dbg'] = 41000;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server!.listen((req) {
        req.response.write('x');
        req.response.close();
      });
      await ctrl().loadInstance(url: 'http://127.0.0.1:${server!.port}/index.js', name: 'dbg');
      expect(state().lastResult, contains('already running: dbg'));
      expect(state().busy, isFalse);
    });

    test('通用服务: local script install, start, stop, uninstall; the built-in danmu name is refused', () async {
      await ctrl().startNode();
      await ctrl().installLocalService(bytes: utf8.encode('// svc'), fileName: 'echo.js');
      await settle();
      final install = sentOn('manager').firstWhere((m) => m['action'] == 'install');
      expect(install['name'], 'echo');
      expect(File(install['path'] as String).readAsStringSync(), '// svc');
      expect(state().services.single.running, isFalse);

      await ctrl().startService('echo');
      await settle();
      expect(state().services.single.running, isTrue);
      await ctrl().stopService('echo');
      await ctrl().uninstallService('echo');
      await settle();
      expect(state().services, isEmpty);
      expect(Directory('${dir.path}/services/echo').existsSync(), isFalse);

      await ctrl().installLocalService(bytes: [1], fileName: 'x.js', name: 'danmu_api');
      expect(state().lastResult, contains('与内置弹幕服务重名'));
      expect(sentOn('manager').where((m) => m['action'] == 'install'), hasLength(1));
    });

    test('the log keeps the newest ${CatpawDebugController.maxLogLines} lines and can be cleared', () async {
      await ctrl().startNode();
      for (var i = 0; i < CatpawDebugController.maxLogLines + 20; i++) {
        bridge.emit('netlog', '[net] GET https://a:b@x/$i → 200 (1ms)');
      }
      await settle();
      expect(state().log, hasLength(CatpawDebugController.maxLogLines));
      expect(state().log.last.text, '[net] GET https://x/${CatpawDebugController.maxLogLines + 19} → 200 (1ms)');
      ctrl().clearLog();
      expect(state().log, isEmpty);
    });
  });

  group('page', () {
    Future<FakeBridge> pump(WidgetTester tester) async {
      final bridge = FakeBridge();
      _Node(bridge);
      await tester.binding.setSurfaceSize(const Size(420, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(ProviderScope(
        overrides: [
          nodeBridgeProvider.overrideWithValue(bridge),
          dartCallbackServerProvider.overrideWithValue(_FakeCallbackServer()),
        ],
        child: MaterialApp(
          scaffoldMessengerKey: rootMessengerKey,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildAppTheme(Brightness.dark),
          home: const CatpawDebugScreen(),
        ),
      ));
      await tester.pumpAndSettle();
      return bridge;
    }

    testWidgets('start card → running layout with both tabs and their empty lists', (tester) async {
      await pump(tester);
      expect(find.text('catpaw 多实例'), findsOneWidget);
      expect(find.text('启动 catpaw 运行时'), findsOneWidget);
      expect(find.text('Dart 回调端口（空=随机）'), findsOneWidget);
      await tester.tap(find.text('Start Node'));
      await tester.pumpAndSettle();

      expect(find.text('Node 运行中'), findsOneWidget);
      expect(find.text('最近结果'), findsOneWidget);
      expect(find.textContaining('Node ready; dart callback :4321'), findsOneWidget);
      expect(find.text('加载实例'), findsOneWidget);
      expect(find.text('catpaw index.js URL'), findsOneWidget);
      expect(find.text('加载 catpaw 实例'), findsOneWidget);
      expect(find.text('无实例'), findsOneWidget);
      expect(find.text('开启局域网代理(Dart 反向代理)'), findsNothing);

      await tester.tap(find.text('通用服务'));
      await tester.pumpAndSettle();
      expect(find.text('通用服务 index.js URL'), findsOneWidget);
      expect(find.text('加载本地脚本'), findsOneWidget);
      expect(find.text('无服务'), findsOneWidget);
    });

    testWidgets('copy all logs and clear logs', (tester) async {
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await pump(tester);
      await tester.tap(find.text('Start Node'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('复制全部日志'));
      await tester.pumpAndSettle();
      expect(clipboard, contains('Node ready; dart callback :4321'));
      expect(find.text('已复制'), findsOneWidget);

      await tester.tap(find.byTooltip('清空日志'));
      await tester.pumpAndSettle();
      expect(find.text('暂无日志'), findsOneWidget);
      expect(find.text('日志已清空'), findsOneWidget);
    });
  });
}
