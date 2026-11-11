import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/features/player/native_player_api.g.dart';
import 'package:uzv_reimpl/features/player/player_session.dart';
import 'package:uzv_reimpl/features/player/playback_source.dart';
import 'package:uzv_reimpl/features/sniffer/sniffer_service.dart';
import 'package:uzv_reimpl/models/vod.dart';

class FakeHost extends NativePlayerHostApi {
  final payloads = <SourcePayload>[];
  @override
  Future<void> provideSource(SourcePayload payload) async => payloads.add(payload);
}

class FakeSniffer extends SnifferService {
  final asked = <String>[];
  @override
  Future<SniffedResource?> sniffFirstVideo(String pageUrl, {Map<String, String> headers = const {}, Duration timeout = const Duration(seconds: 20)}) async {
    asked.add(pageUrl);
    return const SniffedResource(url: 'http://cdn/real.m3u8', kind: 'hls', headers: {'Referer': 'r'});
  }
}

class ScriptedSource extends PlaybackSource {
  ScriptedSource(this.result);
  PlayResult result;
  @override
  String get title => 't';
  @override
  List<PlayLine> get lines => const [PlayLine('l', [PlayEpisode('1', 'u')])];
  @override
  Future<PlayResult> resolve(int lineIndex, int episodeIndex) async => result;
}

EpisodeRequest request(int quality) => EpisodeRequest(sessionId: 's', requestId: 7, lineIndex: 0, episodeIndex: 0, qualityIndex: quality);

PlayerSession sessionFor(PlaybackSource source, FakeHost host, SnifferService sniffer) =>
    PlayerSession(sessionId: 's', source: source, host: host, sniffer: sniffer, onPreferences: (_) {});

void main() {
  group('parsePlayQualities', () {
    test('alternating name / url list', () {
      final q = parsePlayQualities(['1080P', 'http://a/1080.m3u8', '720P', 'http://a/720.m3u8']);
      expect(q.map((e) => e.name), ['1080P', '720P']);
      expect(q.last.url, 'http://a/720.m3u8');
    });

    test('objects with various name fields', () {
      final q = parsePlayQualities([
        {'url': 'http://a/1', 'name': 'HD'},
        {'src': 'http://a/2', 'label': 'SD'},
        {'link': 'http://a/3'},
        {'name': 'no url'},
      ]);
      expect(q.map((e) => e.name), ['HD', 'SD', 'Source 3']);
    });

    test('plain url list gets numbered names', () {
      expect(parsePlayQualities(['http://a/1', 'https://a/2']).map((e) => e.name), ['Source 1', 'Source 2']);
    });

    test('garbage gives nothing', () {
      expect(parsePlayQualities([]), isEmpty);
      expect(parsePlayQualities(['a', 'b']), isEmpty); // even length but no URL in the url slot
      expect(parsePlayQualities(['http://a', 'x', 'y']), isEmpty);
      expect(parsePlayQualities(['1080P', 'http://a', '720P']), isEmpty); // dangling name
      expect(parsePlayQualities([1, 2, 3]), isEmpty);
      expect(parsePlayQualities(['http://a/1', 'http://a/2', 3]), isEmpty);
    });
  });

  group('PlayResult.fromJson', () {
    test('a string url stays a single source', () {
      final r = PlayResult.fromJson({'url': 'http://a/x.m3u8', 'parse': 0});
      expect(r.url, 'http://a/x.m3u8');
      expect(r.qualities, isEmpty);
      expect(r.needsParse, isFalse);
    });

    test('a url list is no longer stringified into the url', () {
      final r = PlayResult.fromJson({'url': ['HD', 'http://a/hd', 'SD', 'http://a/sd']});
      expect(r.url, 'http://a/hd');
      expect(r.qualities, hasLength(2));
      expect(r.withQuality(1).url, 'http://a/sd');
      expect(r.withQuality(99).url, 'http://a/sd'); // clamped
      expect(r.withQuality(-3).url, 'http://a/hd');
    });

    test('an unparsable list leaves an empty url instead of junk', () {
      expect(PlayResult.fromJson({'url': ['x']}).url, '');
    });

    test('subtitles in the supported shapes', () {
      final r = PlayResult.fromJson({
        'url': 'http://a',
        'subs': [
          {'url': 'http://s/a.srt', 'name': 'English', 'lang': 'en', 'format': 'application/x-subrip'},
          {'url': 'http://s/b.ass'},
          {'name': 'no url'},
          'http://s/c.vtt',
        ],
      });
      expect(r.subtitles.map((s) => s.name), ['English', 'Subtitle 2', 'Subtitle 3']);
      expect(r.subtitles.first.language, 'en');
      expect(r.subtitles.first.mimeType, 'application/x-subrip');
      expect(PlayResult.fromJson({'url': 'u', 'sub': {'url': 'http://s/x.srt'}}).subtitles, hasLength(1));
      expect(PlayResult.fromJson({'url': 'u'}).subtitles, isEmpty);
    });
  });

  group('PlayerSession answers for the native side', () {
    test('the requested quality is clamped, its url is the one sent, and the names come along', () async {
      final host = FakeHost();
      final source = ScriptedSource(PlayResult.fromJson({
        'url': ['1080P', 'http://a/1080', '720P', 'http://a/720'],
        'subs': [{'url': 'http://s/a.srt', 'name': 'English', 'lang': 'en'}],
      }));
      final s = sessionFor(source, host, FakeSniffer());
      await s.onEpisodeRequest(request(1));
      await s.onEpisodeRequest(request(5)); // remembered index from a longer list
      expect(host.payloads.map((p) => p.url), ['http://a/720', 'http://a/720']);
      final p = host.payloads.first;
      expect(p.requestId, 7);
      expect(p.qualities!.map((q) => (q.qualityIndex, q.qualityName)), [(0, '1080P'), (1, '720P')]);
      expect(p.subtitles!.single.url, 'http://s/a.srt');
      expect(p.subtitles!.single.language, 'en');
    });

    test('with no qualities the list is empty and the index is ignored', () async {
      final host = FakeHost();
      final s = sessionFor(ScriptedSource(const PlayResult(url: 'http://a/only')), host, FakeSniffer());
      await s.onEpisodeRequest(request(3));
      expect(host.payloads.single.url, 'http://a/only');
      expect(host.payloads.single.qualities, isEmpty);
    });

    test('a parse page is sniffed for the chosen quality, not the first', () async {
      final host = FakeHost();
      final sniffer = FakeSniffer();
      final source = ScriptedSource(PlayResult.fromJson({
        'url': ['HD', 'http://page/hd', 'SD', 'http://page/sd'],
        'parse': 1,
      }));
      await sessionFor(source, host, sniffer).onEpisodeRequest(request(1));
      expect(sniffer.asked, ['http://page/sd']);
      expect(host.payloads.single.url, 'http://cdn/real.m3u8');
      expect(host.payloads.single.headers, containsPair('Referer', 'r'));
      expect(host.payloads.single.qualities, hasLength(2));
    });

    test('a failing source reports the error instead of throwing', () async {
      final host = FakeHost();
      final source = _Failing();
      await sessionFor(source, host, FakeSniffer()).onEpisodeRequest(request(0));
      expect(host.payloads.single.success, isFalse);
      expect(host.payloads.single.errorMessage, contains('boom'));
    });

    // OBSERVED on the phone (2026-11-10): a cloud-drive spider's /play answered 401 and the page spun for ever. The
    // player's error layer now shows the message; the app passes describeLoadError so it reads like the other errors.
    test('the failure text is the one describeError gives', () async {
      final host = FakeHost();
      final session = PlayerSession(
        sessionId: 's',
        source: _Failing(),
        host: host,
        sniffer: FakeSniffer(),
        onPreferences: (_) {},
        describeError: (e) => 'HTTP 401：${(e as StateError).message}',
      );
      await session.onEpisodeRequest(request(0));
      expect(host.payloads.single.errorMessage, 'HTTP 401：boom');
    });
  });
}

class _Failing extends ScriptedSource {
  _Failing() : super(const PlayResult(url: ''));
  @override
  Future<PlayResult> resolve(int lineIndex, int episodeIndex) async => throw StateError('boom');
}
