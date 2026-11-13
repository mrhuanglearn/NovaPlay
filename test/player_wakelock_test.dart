import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/features/player/native_player_api.g.dart';
import 'package:uzv_reimpl/features/player/playback_source.dart';
import 'package:uzv_reimpl/features/player/player_launcher.dart';
import 'package:uzv_reimpl/features/player/session_router.dart';
import 'package:uzv_reimpl/features/sniffer/sniffer_service.dart';

class _FakeHost extends NativePlayerHostApi {
  final opened = <OpenPlayerRequest>[];
  Object? errorOnOpen;

  @override
  Future<void> openPlayerPage(OpenPlayerRequest request) async {
    if (errorOnOpen != null) throw errorOnOpen!;
    opened.add(request);
  }
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('uzv_wakelock_test');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('PlayerLauncher enables wakelock during playback and only disables when the last session closes', () async {
    final host = _FakeHost();
    final router = PlayerSessionRouter();
    final events = <String>[];

    final launcher = PlayerLauncher(
      configs: PlayerConfigRepository(store: JsonStore('player_config.json', baseDir: dir)),
      sniffer: SnifferService(),
      host: host,
      router: router,
      installRouter: false,
      enableWakelock: () async => events.add('enable'),
      disableWakelock: () async => events.add('disable'),
    );

    final f1 = launcher.playSource(DirectPlaybackSource.single(title: 'V1', url: 'https://example.com/1.mp4'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(host.opened, hasLength(1));
    expect(events, ['enable']);

    // Open a second session while first is e.g. in PiP
    final f2 = launcher.playSource(DirectPlaybackSource.single(title: 'V2', url: 'https://example.com/2.mp4'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(host.opened, hasLength(2));
    expect(events, ['enable', 'enable']);

    // Closing first session must NOT disable wakelock while second session is still open
    final s1Id = host.opened[0].sessionId;
    final s2Id = host.opened[1].sessionId;
    await router.onPageClosed(PageClosedEvent(sessionId: s1Id, positionSeconds: 10, completed: false));
    await f1;
    expect(events, ['enable', 'enable'], reason: 'second player session is still active');

    // Closing last session disables wakelock
    await router.onPageClosed(PageClosedEvent(sessionId: s2Id, positionSeconds: 20, completed: false));
    await f2;
    expect(events, ['enable', 'enable', 'disable']);
  });

  test('PlayerLauncher disables wakelock if openPlayerPage throws', () async {
    final host = _FakeHost()..errorOnOpen = StateError('native open failed');
    final router = PlayerSessionRouter();
    final events = <String>[];

    final launcher = PlayerLauncher(
      configs: PlayerConfigRepository(store: JsonStore('player_config.json', baseDir: dir)),
      sniffer: SnifferService(),
      host: host,
      router: router,
      installRouter: false,
      enableWakelock: () async => events.add('enable'),
      disableWakelock: () async => events.add('disable'),
    );

    await expectLater(
      launcher.playSource(DirectPlaybackSource.single(title: 'V1', url: 'https://example.com/1.mp4')),
      throwsStateError,
    );
    expect(events, ['enable', 'disable']);
  });
}
