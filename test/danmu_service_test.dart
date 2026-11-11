import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/features/catpaw/catpaw_client.dart';
import 'package:uzv_reimpl/features/catpaw/manager_client.dart';
import 'package:uzv_reimpl/features/danmaku/danmu_service.dart';
import 'package:uzv_reimpl/features/subscription/subscription.dart';
import 'package:uzv_reimpl/services/danmu_client.dart';

import 'support/fake_bridge.dart';

void main() {
  const local = Subscription(key: 'k', name: 'n', indexJsUrl: 'http://x/index.js', danmuToken: 'tok');
  const cloud = Subscription(key: 'c', name: 'n', cloudUrl: 'http://10.0.0.2:9321/secret/');

  group('danmuBaseUrl', () {
    test('off and unconfigured modes give no server', () {
      expect(danmuBaseUrl(const DanmuServiceConfig()), isNull);
      expect(danmuBaseUrl(const DanmuServiceConfig(mode: DanmuMode.remote)), isNull);
      expect(danmuBaseUrl(const DanmuServiceConfig(mode: DanmuMode.subscription)), isNull);
    });

    test('remote url is trimmed', () {
      expect(danmuBaseUrl(const DanmuServiceConfig(mode: DanmuMode.remote, remoteUrl: ' http://h:1/tok// ')), 'http://h:1/tok');
    });

    test('subscription mode uses the fixed 9321 port and the subscription token', () {
      const cfg = DanmuServiceConfig(mode: DanmuMode.subscription);
      expect(danmuBaseUrl(cfg, subscription: local), 'http://127.0.0.1:9321/tok');
      expect(danmuBaseUrl(cfg, subscription: const Subscription(key: 'a', name: 'a', indexJsUrl: 'u')), 'http://127.0.0.1:9321');
    });

    test('cloud subscription: its own address is the danmaku address', () {
      expect(danmuBaseUrl(const DanmuServiceConfig(mode: DanmuMode.subscription), subscription: cloud), 'http://10.0.0.2:9321/secret');
    });

    test('builtin mode has its own port so it cannot clash with the subscription server', () {
      expect(danmuBaseUrl(const DanmuServiceConfig(mode: DanmuMode.builtin)), 'http://127.0.0.1:9311');
      expect(danmuBaseUrl(const DanmuServiceConfig(mode: DanmuMode.builtin, enabled: false)), isNull);
      expect(danmuBaseUrl(const DanmuServiceConfig(mode: DanmuMode.builtin, port: 9400, token: 't')), 'http://127.0.0.1:9400/t');
      expect(builtinDanmuDefaultPort, isNot(subscriptionDanmuPort));
    });
  });

  group('DanmuServiceConfig.fromJson', () {
    test('a legacy file with only remoteUrl becomes remote mode', () {
      expect(DanmuServiceConfig.fromJson({'remoteUrl': 'http://h'}).mode, DanmuMode.remote);
      expect(DanmuServiceConfig.fromJson({}).mode, DanmuMode.off);
    });

    test('round trips', () {
      const c = DanmuServiceConfig(mode: DanmuMode.builtin, scriptUrl: 'http://s/server.cjs', port: 9500, token: 'x', enabled: false, localScript: true);
      final back = DanmuServiceConfig.fromJson(jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>);
      expect((back.mode, back.scriptUrl, back.port, back.token), (DanmuMode.builtin, 'http://s/server.cjs', 9500, 'x'));
      expect((back.enabled, back.localScript), (false, true));
    });

    test('older files: 启用弹幕 follows the mode, and off shows as 本地服务', () {
      expect(DanmuServiceConfig.fromJson({'mode': 'remote', 'remoteUrl': 'http://h'}).enabled, isTrue);
      final off = DanmuServiceConfig.fromJson({'mode': 'off'});
      expect((off.enabled, off.source), (false, DanmuMode.builtin));
    });
  });

  test('DanmuRefsRepository remembers a match per show', () async {
    final dir = await Directory.systemTemp.createTemp('refs');
    addTearDown(() => dir.delete(recursive: true));
    final repo = DanmuRefsRepository(store: JsonStore('danmu_refs.json', baseDir: dir));
    expect(await repo.get('site|1'), isNull);
    await repo.set('site|1', const DanmuRef(42, 'Some Show'));
    final ref = await repo.get('site|1');
    expect((ref!.animeId, ref.title), (42, 'Some Show'));
    await repo.remove('site|1');
    expect(await repo.get('site|1'), isNull);
  });

  test('parseDanmuPush accepts dandanplay and plain objects', () {
    final list = parseDanmuPush([
      {'p': '5,1,255,u', 'm': 'dandan'},
      {'time': 1.5, 'mode': 5, 'color': 16711680, 'text': 'plain'},
      {'nothing': true},
    ]);
    expect(list.map((c) => c.text), ['plain', 'dandan']);
    expect(list.first.mode, 5);
  });

  group('DanmuServiceController (builtin mode)', () {
    late Directory dir;
    late FakeBridge bridge;
    final installed = <String, Map>{};
    final running = <String, Map>{};

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('danmu');
      installed.clear();
      running.clear();
      bridge = FakeBridge();
      // a stand-in for node_host/src/services.js
      bridge.onSend = (channel, message) {
        if (channel != 'manager') return;
        final cmd = jsonDecode(message) as Map;
        final action = cmd['action'];
        var ok = true;
        String? error;
        if (action == 'install') {
          installed[cmd['name'] as String] = cmd;
        } else if (action == 'start') {
          if (!installed.containsKey(cmd['name'])) {
            ok = false;
            error = 'unknown service: ${cmd['name']}';
          } else {
            running[cmd['name'] as String] = cmd;
          }
        } else if (action == 'stop') {
          running.remove(cmd['name']);
        }
        Future.microtask(() {
          if (action != 'list') {
            bridge.emit('manager', jsonEncode({'type': 'result', 'action': action, 'name': cmd['name'], 'ok': ok, 'error': error}));
          }
          bridge.emit('manager', jsonEncode({
            'type': 'list',
            'services': [
              for (final n in installed.keys) {'name': n, 'running': running.containsKey(n), 'port': running[n]?['port']},
            ],
          }));
        });
      };
    });

    tearDown(() => dir.delete(recursive: true));

    Future<DanmuServiceController> controller(DanmuServiceConfig cfg) async {
      final store = JsonStore('danmu_service_config.json', baseDir: dir);
      await store.write(cfg.toJson());
      File('${dir.path}/danmu_api/server.cjs')
        ..createSync(recursive: true)
        ..writeAsStringSync('module.exports = {};');
      return DanmuServiceController(
        store: store,
        catpaw: CatpawClient(bridge),
        manager: ManagerClient(bridge),
        installer: SubscriptionInstaller(root: dir),
        activeSubscription: () async => null,
        root: dir,
      );
    }

    test('installs the script, starts it on its own port and returns a client for it', () async {
      final c = await controller(const DanmuServiceConfig(mode: DanmuMode.builtin, port: 9400, token: 'abc'));
      final client = await c.resolve();
      expect(client, isNotNull);
      expect(installed['danmu_api']!['path'], endsWith('danmu_api/server.cjs'));
      final start = running['danmu_api']!;
      expect(start['port'], 9400);
      expect(start['env'], {'DANMU_API_PORT': '9400', 'TOKEN': 'abc'});
    });

    test('an already running service on the right port is left alone', () async {
      final c = await controller(const DanmuServiceConfig(mode: DanmuMode.builtin, port: 9400));
      await c.resolve();
      bridge.sent.clear();
      await c.resolve();
      expect(bridge.sent.where((m) => m.$1 == 'manager').map((m) => (jsonDecode(m.$2) as Map)['action']), ['list']);
    });

    test('a start failure turns into "no danmaku" instead of an exception', () async {
      final c = await controller(const DanmuServiceConfig(mode: DanmuMode.builtin));
      bridge.onSend = (channel, message) {
        final cmd = jsonDecode(message) as Map;
        if (channel == 'manager' && cmd['action'] != 'list') {
          Future.microtask(() => bridge.emit(
              'manager', jsonEncode({'type': 'result', 'action': cmd['action'], 'name': cmd['name'], 'ok': false, 'error': 'nope'})));
        } else if (channel == 'manager') {
          Future.microtask(() => bridge.emit('manager', jsonEncode({'type': 'list', 'services': []})));
        }
      };
      expect(await c.resolve(), isNull);
    });
  });
}
