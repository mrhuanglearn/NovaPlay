import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/features/player/native_player_api.g.dart';
import 'package:uzv_reimpl/features/player/player_session.dart';
import 'package:uzv_reimpl/features/player/playback_source.dart';
import 'package:uzv_reimpl/features/player/session_router.dart';
import 'package:uzv_reimpl/features/sniffer/sniffer_service.dart';
import 'package:uzv_reimpl/models/vod.dart';

class RecordingSource extends PlaybackSource {
  RecordingSource(this.title);
  @override
  final String title;
  final saved = <(int, int, double, double)>[];
  final finished = <double>[];

  @override
  List<PlayLine> get lines => const [
        PlayLine('l', [PlayEpisode('1', 'u')])
      ];

  @override
  Future<PlayResult> resolve(int lineIndex, int episodeIndex) async => const PlayResult(url: 'http://x');

  @override
  Future<void> saveProgress(int lineIndex, int episodeIndex, double position, double duration,
          {int quality = 0}) async =>
      saved.add((lineIndex, episodeIndex, position, duration));

  @override
  Future<void> finish(int lineIndex, int episodeIndex, double position) async => finished.add(position);
}

PlayerSession session(String id, PlaybackSource source) => PlayerSession(
      sessionId: id,
      source: source,
      host: NativePlayerHostApi(), // never called by the events exercised here
      sniffer: SnifferService(),
      onPreferences: (_) {},
    );

void main() {
  late PlayerSessionRouter router;
  late RecordingSource a;
  late RecordingSource b;
  late PlayerSession sa;
  late PlayerSession sb;

  setUp(() {
    router = PlayerSessionRouter();
    a = RecordingSource('Show A');
    b = RecordingSource('Show B');
    sa = session('A', a);
    sb = session('B', b);
    router
      ..register(sa)
      ..register(sb);
  });

  test('a heartbeat only reaches the session it names', () async {
    await router.onHeartbeat(Heartbeat(sessionId: 'A', positionSeconds: 10, durationSeconds: 100));
    expect(a.saved, [(0, 0, 10.0, 100.0)]);
    expect(b.saved, isEmpty);
  });

  test('closing A completes A only and leaves B registered and working', () async {
    await router.onPageClosed(PageClosedEvent(sessionId: 'A', positionSeconds: 42, completed: false));
    expect((await sa.closed).positionSeconds, 42);
    expect(a.finished, [42.0]);
    expect(sb.closed.timeout(const Duration(milliseconds: 50), onTimeout: () => throw StateError('B closed')),
        throwsStateError);
    expect(b.finished, isEmpty);

    router.unregister(sa);
    expect(router.length, 1);
    expect(router.latest, same(sb));
    await router.onHeartbeat(Heartbeat(sessionId: 'B', positionSeconds: 5, durationSeconds: 50));
    expect(b.saved, [(0, 0, 5.0, 50.0)]);
  });

  test('the close position is saved with the last known duration, not 0', () async {
    await router.onHeartbeat(Heartbeat(sessionId: 'A', positionSeconds: 10, durationSeconds: 100));
    await router.onPageClosed(PageClosedEvent(sessionId: 'A', positionSeconds: 90, completed: false));
    expect(a.saved.last, (0, 0, 90.0, 100.0));
  });

  test('events of unknown or already unregistered sessions are ignored', () async {
    router.unregister(sa);
    await router.onHeartbeat(Heartbeat(sessionId: 'A', positionSeconds: 1, durationSeconds: 2));
    await router.onPageClosed(PageClosedEvent(sessionId: 'nope', positionSeconds: 1, completed: true));
    expect(a.saved, isEmpty);
    expect(b.saved, isEmpty);
  });

  test('danmaku prompt info comes from the right session', () async {
    expect((await router.getDanmakuPromptInfo('B')).keyword, 'Show B');
    expect((await router.getDanmakuPromptInfo('gone')).keyword, '');
  });

  test('unregistering a stale registration does not remove a newer session with the same id', () {
    final replacement = session('A', RecordingSource('Show A2'));
    router.register(replacement);
    router.unregister(sa);
    expect(router.length, 2);
  });
}
