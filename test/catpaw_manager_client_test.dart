import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/features/catpaw/catpaw_client.dart';
import 'package:uzv_reimpl/features/catpaw/manager_client.dart';

import 'support/fake_bridge.dart';

void main() {
  group('CatpawClient', () {
    test('attach waits for "Node ready", startAndWait resolves with the port event', () async {
      final bridge = FakeBridge();
      bridge.onSend = (channel, message) {
        final cmd = jsonDecode(message) as Map;
        if (channel == 'catpaw' && cmd['action'] == 'start') {
          scheduleMicrotask(() => bridge.emit('catpaw', jsonEncode({'type': 'port', 'name': cmd['name'], 'port': 4321})));
        }
      };
      final client = CatpawClient(bridge);
      await client.attach();
      expect(bridge.started, isTrue);
      final port = await client.startAndWait(name: 'sub1', scriptPath: '/s/index.js', configPath: '/s/config.js', force: true);
      expect(port, 4321);
      expect(client.portOf('sub1'), 4321);
      final start = jsonDecode(bridge.sent.last.$2) as Map;
      expect(start, containsPair('path', '/s/index.js'));
      expect(start, containsPair('configPath', '/s/config.js'));
      expect(start, containsPair('force', true));
      await client.dispose();
    });

    test('a runtime that cannot start fails attach at once, and attach can be retried afterwards', () async {
      final bridge = FakeBridge()..statusOnStart = 'Node runtime failed: dlopen failed: library "libc++_shared.so" not found';
      final client = CatpawClient(bridge);
      await expectLater(
        client.attach(),
        throwsA(predicate((e) => '$e'.contains('Node runtime failed') && '$e'.contains('libc++_shared.so'))),
      );
      bridge.statusOnStart = 'Node ready, version test';
      await client.attach(); // the failure was not cached
      await client.dispose();
    });

    test('a runtime that ends right after starting is reported as an error too', () async {
      final bridge = FakeBridge()..statusOnStart = 'Node runtime exited with code 1';
      final client = CatpawClient(bridge);
      await expectLater(client.attach(), throwsA(predicate((e) => '$e'.contains('exited with code 1'))));
      await client.dispose();
    });

    test('a native start call that throws is passed on', () async {
      final bridge = FakeBridge()..startError = PlatformException(code: 'node_start_failed', message: 'no assets');
      final client = CatpawClient(bridge);
      await expectLater(client.attach(), throwsA(isA<PlatformException>()));
      await client.dispose();
    });

    test('a failed start surfaces the script error', () async {
      final bridge = FakeBridge();
      bridge.onSend = (channel, message) {
        final cmd = jsonDecode(message) as Map;
        if (cmd['action'] == 'start') {
          scheduleMicrotask(() => bridge.emit('catpaw',
              jsonEncode({'type': 'result', 'action': 'start', 'name': cmd['name'], 'ok': false, 'error': 'boom'})));
        }
      };
      final client = CatpawClient(bridge);
      await client.attach();
      await expectLater(client.startAndWait(name: 'x', scriptPath: '/s.js'), throwsA(predicate((e) => '$e'.contains('boom'))));
      await client.dispose();
    });
  });

  group('ManagerClient', () {
    test('install and start are acknowledged; start carries port and env', () async {
      final bridge = FakeBridge();
      bridge.onSend = (channel, message) {
        final cmd = jsonDecode(message) as Map;
        if (channel != 'manager') return;
        scheduleMicrotask(() {
          bridge.emit('manager', jsonEncode({'type': 'result', 'action': cmd['action'], 'name': cmd['name'], 'ok': true}));
          bridge.emit('manager', jsonEncode({
            'type': 'list',
            'services': [
              {'name': cmd['name'], 'running': cmd['action'] == 'start', 'port': cmd['action'] == 'start' ? cmd['port'] : null},
            ],
          }));
        });
      };
      final m = ManagerClient(bridge)..listen();
      expect((await m.install('danmu_api', '/d/server.cjs', defaultPort: 9322)).ok, isTrue);
      final r = await m.start('danmu_api', port: 9322, env: {'DANMU_API_PORT': '9322'});
      expect(r.ok, isTrue);
      final start = jsonDecode(bridge.sent.last.$2) as Map;
      expect(start['port'], 9322);
      expect(start['env'], {'DANMU_API_PORT': '9322'});
      await Future<void>.delayed(Duration.zero);
      expect(m.find('danmu_api')?.running, isTrue);
      expect(m.find('danmu_api')?.port, 9322);
      await m.dispose();
    });

    test('a negative acknowledgement is returned, not thrown', () async {
      final bridge = FakeBridge();
      bridge.onSend = (channel, message) {
        final cmd = jsonDecode(message) as Map;
        scheduleMicrotask(() =>
            bridge.emit('manager', jsonEncode({'type': 'result', 'action': cmd['action'], 'name': cmd['name'], 'ok': false, 'error': 'not installed'})));
      };
      final m = ManagerClient(bridge);
      final r = await m.start('nope');
      expect(r.ok, isFalse);
      expect(r.error, 'not installed');
      await m.dispose();
    });

    test('refresh asks for a list and returns the snapshot', () async {
      final bridge = FakeBridge();
      bridge.onSend = (channel, message) {
        scheduleMicrotask(() => bridge.emit('manager', jsonEncode({
              'type': 'list',
              'services': [
                {'name': 'a', 'running': false, 'port': null},
              ],
            })));
      };
      final m = ManagerClient(bridge);
      final list = await m.refresh();
      expect(list.single.name, 'a');
      await m.dispose();
    });
  });
}
