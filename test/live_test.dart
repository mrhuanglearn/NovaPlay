import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/features/live/live_store.dart';
import 'package:uzv_reimpl/features/live/m3u_epg.dart';

void main() {
  final channels = parseM3u('#EXTM3U\n'
      '#EXTINF:-1 tvg-id="a" group-title="News",Alpha News\nhttp://s/a\n'
      '#EXTINF:-1 group-title="Sports",Beta Sports\nhttp://s/b\n'
      '#EXTINF:-1 group-title="News",Gamma\nhttp://s/c\n'
      '#EXTINF:-1,No Group\nhttp://s/d\n');

  test('groups keep first-appearance order and honour the block list', () {
    expect(liveGroups(channels), ['News', 'Sports', 'Other']);
    expect(liveGroups(channels, blocked: {'Sports'}), ['News', 'Other']);
  });

  test('visibleChannels filters by group, block list and query', () {
    expect(visibleChannels(channels, group: 'News').map((c) => c.name), ['Alpha News', 'Gamma']);
    expect(visibleChannels(channels, blocked: {'News'}).map((c) => c.name), ['Beta Sports', 'No Group']);
    expect(visibleChannels(channels, query: 'SPORT').map((c) => c.name), ['Beta Sports']);
  });

  test('parseXmltvGuide groups programmes and maps display names; currentProgramme picks the one on air', () {
    const xml = '<tv><channel id="a"><display-name>Alpha News</display-name></channel>'
        '<programme start="20260101100000 +0000" stop="20260101110000 +0000" channel="a"><title>Later</title></programme>'
        '<programme start="20260101090000 +0000" stop="20260101100000 +0000" channel="a"><title>Earlier</title></programme></tv>';
    final guide = parseXmltvGuide(utf8.encode(xml));
    expect(guide.displayNames['a'], 'Alpha News');
    expect(guide.byChannel['a']!.map((e) => e.title), ['Earlier', 'Later']);
    expect(guide.forChannel(channels.first), hasLength(2));
    expect(currentProgramme(guide.byChannel['a']!, DateTime.utc(2026, 1, 1, 9, 30))!.title, 'Earlier');
    expect(currentProgramme(guide.byChannel['a']!, DateTime.utc(2026, 1, 1, 12)), isNull);
  });

  test('m3uGuideUrl reads x-tvg-url / url-tvg from the header only', () {
    expect(m3uGuideUrl('#EXTM3U x-tvg-url="http://g/a.xml.gz,http://g/b.xml"\n#EXTINF:-1,A\nhttp://s/a'), 'http://g/a.xml.gz');
    expect(m3uGuideUrl('#EXTM3U url-tvg="http://g/c.xml"\n'), 'http://g/c.xml');
    expect(m3uGuideUrl('#EXTM3U\n#EXTINF:-1 x-tvg-url="http://nope",A\nhttp://s/a'), isNull);
    expect(m3uGuideUrl('http://s/a'), isNull);
  });

  test('guideUrlFor prefers the source, then the playlist header, then the global guide', () {
    const prefs = LivePreferences(globalEpgUrl: 'http://global/epg.xml');
    const plain = LiveSource(id: '1', name: 'n', url: 'u');
    expect(guideUrlFor(plain, '#EXTM3U\n', prefs), 'http://global/epg.xml');
    expect(guideUrlFor(plain, '#EXTM3U x-tvg-url="http://own"\n', prefs), 'http://own');
    expect(guideUrlFor(const LiveSource(id: '1', name: 'n', url: 'u', epgUrl: 'http://src'), '#EXTM3U x-tvg-url="http://own"\n', prefs), 'http://src');
    expect(guideUrlFor(plain, '#EXTM3U\n', const LivePreferences()), isNull);
  });

  test('LiveSource keeps older entries working: okhttp and 24 h refresh by default', () {
    final s = LiveSource.fromJson({'id': 7, 'name': 'n', 'url': 'u', 'epgUrl': ''});
    expect(s.userAgent, 'okhttp');
    expect(s.refresh, LiveRefresh.daily);
    final back = LiveSource.fromJson(const LiveSource(id: '7', name: 'n', url: 'u', userAgent: 'x', refresh: LiveRefresh.off).toJson());
    expect((back.userAgent, back.refresh), ('x', LiveRefresh.off));
  });

  group('LivePlaylistLoader', () {
    late Directory dir;
    var now = DateTime(2026, 1, 2, 12);
    var fetches = 0;
    var fail = false;
    LivePlaylistLoader loader() => LivePlaylistLoader(
          cacheDir: dir,
          now: () => now,
          fetch: (s) async {
            if (fail) throw StateError('offline');
            fetches++;
            return '#EXTM3U\n#EXTINF:-1,v$fetches\nhttp://s/$fetches';
          },
        );
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('live');
      fetches = 0;
      fail = false;
      now = DateTime.now();
    });
    tearDown(() => dir.delete(recursive: true));

    test('24 h: reuses the cache until it is a day old', () async {
      const s = LiveSource(id: 'a', name: 'n', url: 'u');
      expect(await loader().load(s), contains('v1'));
      expect(await loader().load(s), contains('v1'));
      now = now.add(const Duration(hours: 25));
      expect(await loader().load(s), contains('v2'));
    });

    test('every time: downloads again, and falls back to the cache when offline', () async {
      const s = LiveSource(id: 'b', name: 'n', url: 'u', refresh: LiveRefresh.always);
      await loader().load(s);
      expect(await loader().load(s), contains('v2'));
      fail = true;
      expect(await loader().load(s), contains('v2'));
    });

    test('off: never downloads again once cached; a missing cache is still fetched', () async {
      const s = LiveSource(id: 'c', name: 'n', url: 'u', refresh: LiveRefresh.off);
      expect(await loader().load(s), contains('v1'));
      now = now.add(const Duration(days: 30));
      expect(await loader().load(s), contains('v1'));
      await loader().remove('c');
      expect(await loader().load(s), contains('v2'));
    });
  });
}
