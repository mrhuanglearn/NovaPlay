import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/features/catpaw/spider_api.dart';
import 'package:uzv_reimpl/features/library/watch_repository.dart';
import 'package:uzv_reimpl/features/player/head_tail.dart';
import 'package:uzv_reimpl/features/player/native_player_api.g.dart';
import 'package:uzv_reimpl/features/player/player_session.dart';
import 'package:uzv_reimpl/features/player/playback_source.dart';
import 'package:uzv_reimpl/features/sniffer/sniffer_service.dart';
import 'package:uzv_reimpl/models/vod.dart';

// Issue 4 (2026-11-10): leaving a video at 47 s and pressing 立即播放 again started at 0, and the line / quality picked
// were not remembered. The Dart side did compute the position (logged on the device: resume=25.2, the player got
// 25000 ms); the mpv kernel ignored it (fixed in MpvCore, see MpvCoreTest). These tests pin the Dart half: what is
// saved while playing and what the next player is opened with.

const _site = SpiderSite(key: 'demo', name: '配置站点', api: '/spider/demo/3');

class _Host extends NativePlayerHostApi {
  final opened = <OpenPlayerRequest>[];
  final sources = <SourcePayload>[];

  @override
  Future<void> openPlayerPage(OpenPlayerRequest request) async => opened.add(request);

  @override
  Future<void> provideSource(SourcePayload payload) async => sources.add(payload);
}

class _Api extends SpiderApi {
  _Api() : super(0);

  @override
  Future<PlayResult> play(SpiderSite site, String flag, String id) async => const PlayResult(
        url: 'http://v/hd.mp4',
        qualities: [PlayQuality('原画', 'http://v/hd.mp4'), PlayQuality('标清', 'http://v/sd.mp4')],
      );
}

void main() {
  late Directory dir;
  late HistoryRepository history;
  final detail = VodDetail(
    item: const VodItem(id: '1', name: '山海纪行', siteKey: 'demo'),
    lines: parsePlayLines(r'线路一$$$线路二', r'第1集$e1#第2集$e2#第3集$e3$$$第1集$e1#第2集$e2'),
  );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('uzv_resume');
    history = HistoryRepository(store: JsonStore('history.json', baseDir: dir));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  VodPlaybackSource source() => VodPlaybackSource(site: _site, api: _Api(), detail: detail, history: history);

  PlayerSession session(_Host host, PlaybackSource s) => PlayerSession(
        sessionId: 's${host.opened.length}',
        source: s,
        host: host,
        sniffer: SnifferService(),
        onPreferences: (_) {},
      );

  test('position, line, episode and the quality picked in the player are saved', () async {
    final host = _Host();
    final s = session(host, source());
    await s.open(playback: _playback(), danmaku: _danmaku(), line: 1, episode: 1);
    // the user switches to 标清 in the player: the native side asks for the same episode with quality 1
    await s.onEpisodeRequest(
        EpisodeRequest(sessionId: s.sessionId, requestId: 2, lineIndex: 1, episodeIndex: 1, qualityIndex: 1));
    expect(host.sources.last.url, 'http://v/sd.mp4');
    await s.onHeartbeat(Heartbeat(sessionId: s.sessionId, positionSeconds: 40, durationSeconds: 300));
    await s.onPageClosed(PageClosedEvent(sessionId: s.sessionId, positionSeconds: 47.7, completed: false));

    final e = (await history.find('demo', '1'))!;
    expect((e.lineIndex, e.episodeIndex, e.episodeName), (1, 1, '第2集'));
    expect(e.positionSeconds, 47.7);
    expect(e.durationSeconds, 300);
    expect(e.qualityIndex, 1);
  });

  test('the next player starts at the saved position with the saved quality', () async {
    await history.record(const ProgressEntry(
      item: VodItem(id: '1', name: '山海纪行', siteKey: 'demo'),
      lineIndex: 1,
      episodeIndex: 1,
      episodeName: '第2集',
      positionSeconds: 47.7,
      durationSeconds: 300,
      updatedAt: 0,
      qualityIndex: 1,
    ));
    final src = source();
    final host = _Host();
    await session(host, src).open(
      playback: _playback(),
      danmaku: _danmaku(),
      line: 1,
      episode: 1,
      startSeconds: await src.resumeSeconds(1, 1),
      quality: await src.resumeQuality(),
    );
    final r = host.opened.single;
    expect((r.startLineIndex, r.startEpisodeIndex, r.startPositionSeconds, r.startQualityIndex), (1, 1, 48, 1));
    expect(await src.resumeSeconds(0, 1), 0, reason: 'another line starts from the beginning');
  });

  // Found on the device (2026-11-10): 第3集 (the last one) played to the end, so the history kept pos ≈ dur; pressing
  // 立即播放 again opened the player at the very end, mpv reported 'ended' at once and the page closed after ~2 s.
  test('an episode watched to the end starts again from the beginning', () async {
    Future<double> resumeAt(double pos) async {
      await history.record(ProgressEntry(
        item: const VodItem(id: '1', name: '山海纪行', siteKey: 'demo'),
        lineIndex: 0,
        episodeIndex: 2,
        episodeName: '第3集',
        positionSeconds: pos,
        durationSeconds: 300,
        updatedAt: 0,
      ));
      return source().resumeSeconds(0, 2);
    }

    expect(await resumeAt(299.9), 0);
    expect(await resumeAt(296), 0, reason: 'within the last 5 s');
    expect(await resumeAt(290), 290);
  });

  test('an entry written before the quality was saved reads as quality 0', () {
    final e = ProgressEntry.fromJson({
      'siteKey': 'demo',
      'item': {'vod_id': '1', 'vod_name': 'x'},
      'line': 0,
      'episode': 2,
      'pos': 25.2,
      'dur': 300,
    });
    expect(e.qualityIndex, 0);
    expect(e.toJson()['quality'], 0);
  });

  test('HeadTailRepository.parseSecondsInput parses plain seconds and mm:ss / hh:mm:ss', () {
    expect(HeadTailRepository.parseSecondsInput('90'), 90);
    expect(HeadTailRepository.parseSecondsInput(' 01:30 '), 90);
    expect(HeadTailRepository.parseSecondsInput('01：45'), 105);
    expect(HeadTailRepository.parseSecondsInput('1:02:03'), 3723);
    expect(HeadTailRepository.parseSecondsInput('0'), isNull);
    expect(HeadTailRepository.parseSecondsInput('-10'), isNull);
    expect(HeadTailRepository.parseSecondsInput('abc'), isNull);
    expect(HeadTailRepository.parseSecondsInput('1:2:3:4'), isNull);
  });

  test('an episode left inside its configured outro starts again from 0 instead of re-skipping immediately', () async {
    Future<double> resumeAt(double pos, double dur, double outro) async {
      await history.record(ProgressEntry(
        item: const VodItem(id: '1', name: '山海纪行', siteKey: 'demo'),
        lineIndex: 0,
        episodeIndex: 0,
        episodeName: '第1集',
        positionSeconds: pos,
        durationSeconds: dur,
        updatedAt: 0,
      ));
      return source().resumeSeconds(0, 0, outroSeconds: outro);
    }

    expect(await resumeAt(2230, 2400, 180), 0, reason: 'saved inside 180s outro resets to 0');
    expect(await resumeAt(2100, 2400, 180), 2100, reason: 'saved before outro resumes normally');
    expect(await resumeAt(80, 120, 60), 80, reason: 'short clip <180s ignores outro reset');
    expect(await resumeAt(1200, 2400, 1200), 1200, reason: 'oversized outro > dur/3 is ignored');
  });

  test('stale heartbeats arriving while resolving the next episode do not overwrite its history', () async {
    final gate = Completer<PlayResult>();
    final slowSource = VodPlaybackSource(
      site: _site,
      api: _SlowApi(gate.future),
      detail: detail,
      history: history,
    );
    final host = _Host();
    final s = session(host, slowSource);
    await s.open(playback: _playback(), danmaku: _danmaku(), line: 0, episode: 0);

    // Native requests Episode 2 while Episode 1's old heartbeat arrives at 2390s.
    final reqFuture = s.onEpisodeRequest(
        EpisodeRequest(sessionId: s.sessionId, requestId: 2, lineIndex: 0, episodeIndex: 1, qualityIndex: 0));
    await s.onHeartbeat(Heartbeat(sessionId: s.sessionId, positionSeconds: 2390, durationSeconds: 2400));
    expect(await history.find('demo', '1'), isNull, reason: 'heartbeat ignored while episode resolve is in flight');

    gate.complete(const PlayResult(url: 'http://v/ep2.mp4'));
    await reqFuture;
    await s.onHeartbeat(Heartbeat(sessionId: s.sessionId, positionSeconds: 15, durationSeconds: 2400));
    final saved = (await history.find('demo', '1'))!;
    expect((saved.episodeIndex, saved.positionSeconds), (1, 15));
  });

  test('prefetchEpisode starts spider play before native open and reuses the single in-flight call', () async {
    var calls = 0;
    final gate = Completer<PlayResult>();
    final countingSource = VodPlaybackSource(
      site: _site,
      api: _CountingApi(() {
        calls++;
        return gate.future;
      }),
      detail: detail,
      history: history,
    );
    final host = _Host();
    final s = session(host, countingSource);
    s.prefetchEpisode(0, 1);
    expect(calls, 1, reason: 'spider.play kicked off immediately before openPlayerPage');

    await s.open(playback: _playback(), danmaku: _danmaku(), line: 0, episode: 1);
    final reqFuture = s.onEpisodeRequest(
        EpisodeRequest(sessionId: s.sessionId, requestId: 1, lineIndex: 0, episodeIndex: 1, qualityIndex: 0));
    expect(calls, 1, reason: 'onEpisodeRequest reuses prefetched future without duplicate play()');

    gate.complete(const PlayResult(url: 'http://v/prefetched.mp4'));
    await reqFuture;
    expect(host.sources.single.url, 'http://v/prefetched.mp4');
  });

  test('initialSource is resolved once, passed to open, and onEpisodeRequest is not needed', () async {
    var calls = 0;
    final countingSource = VodPlaybackSource(
      site: _site,
      api: _CountingApi(() async {
        calls++;
        return const PlayResult(url: 'http://v/pre.mp4');
      }),
      detail: detail,
      history: history,
    );
    final host = _Host();
    final s = session(host, countingSource);
    final initial = await s.preResolveInitialSource(line: 0, episode: 1, quality: 0);
    expect(initial?.success, isTrue);
    expect(initial?.url, 'http://v/pre.mp4');
    await s.open(playback: _playback(), danmaku: _danmaku(), line: 0, episode: 1, initialSource: initial);
    expect(host.opened.single.initialSource?.url, 'http://v/pre.mp4');
    expect(calls, 1);
  });

  test('pre-resolve timeout returns null and onEpisodeRequest still reuses the in-flight resolve', () async {
    var calls = 0;
    final gate = Completer<PlayResult>();
    final countingSource = VodPlaybackSource(
      site: _site,
      api: _CountingApi(() {
        calls++;
        return gate.future;
      }),
      detail: detail,
      history: history,
    );
    final host = _Host();
    final s = session(host, countingSource);
    final initial = await s.preResolveInitialSource(
        line: 0, episode: 1, quality: 0, timeout: const Duration(milliseconds: 20));
    expect(initial, isNull);
    await s.open(playback: _playback(), danmaku: _danmaku(), line: 0, episode: 1);
    expect(host.opened.single.initialSource, isNull);
    final req = s.onEpisodeRequest(
        EpisodeRequest(sessionId: s.sessionId, requestId: 7, lineIndex: 0, episodeIndex: 1, qualityIndex: 0));
    gate.complete(const PlayResult(url: 'http://v/slow.mp4'));
    await req;
    expect(calls, 1, reason: 'no duplicate play()');
    expect(host.sources.single.url, 'http://v/slow.mp4');
    expect(host.sources.single.requestId, 7);
  });

  test('HeadTailRepository.sectionsJsonFrom encodes non-empty marks and omits empty', () {
    expect(HeadTailRepository.sectionsJsonFrom(null), isNull);
    expect(HeadTailRepository.sectionsJsonFrom((intro: 0.0, outro: 0.0, ranges: const [])), isNull);
    expect(
      HeadTailRepository.sectionsJsonFrom((intro: 12.5, outro: 30.0, ranges: const [(60.0, 75.5)])),
      '[{"type":"intro","endMs":12500},{"type":"outro","beforeEndMs":30000},{"type":"range","startMs":60000,"endMs":75500}]',
    );
  });
}

class _CountingApi extends SpiderApi {
  _CountingApi(this._fn) : super(0);
  final Future<PlayResult> Function() _fn;

  @override
  Future<PlayResult> play(SpiderSite site, String flag, String id) => _fn();
}

class _SlowApi extends SpiderApi {
  _SlowApi(this._next) : super(0);
  final Future<PlayResult> _next;

  @override
  Future<PlayResult> play(SpiderSite site, String flag, String id) => _next;
}

PlaybackConfig _playback() => PlaybackConfig(
      hwDecode: true,
      fitMode: 'fit',
      speed: 1,
      longPressSpeed: 2,
      fastForwardSeconds: 10,
      autoPictureInPicture: false,
      pauseOnBackground: false,
      isPriorityLandscape: true,
      isHiddenFastSeekBtn: false,
      isShowStatsBar: false,
      isShowAllDuration: false,
      isShowEpisodeSwitchNotice: true,
      showNetSpeed: true,
      hapticEnabled: true,
      skipNotice: true,
      kernel: 'exo',
    );

DanmakuConfig _danmaku() => DanmakuConfig(
      enabled: false,
      opacity: 1,
      fontSize: 18,
      scrollSpeed: 1,
      area: 0.5,
      colorMode: 'original',
      gradientStyle: 'none',
      showTop: true,
      showBottom: true,
      delaySeconds: 0,
      lineHeight: 1.2,
      strokeWidth: 1,
      blackList: const [],
    );
