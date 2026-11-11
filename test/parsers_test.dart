import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/features/live/m3u_epg.dart';
import 'package:uzv_reimpl/models/vod.dart';
import 'package:uzv_reimpl/services/danmu_client.dart';

void main() {
  group('parsePlayLines', () {
    test('splits lines on \$\$\$ and episodes on #', () {
      final lines = parsePlayLines(r'lineA$$$lineB', r'EP1$http://a/1#EP2$http://a/2$$$EP1$http://b/1');
      expect(lines.map((l) => l.name), ['lineA', 'lineB']);
      expect(lines[0].episodes.map((e) => e.name), ['EP1', 'EP2']);
      expect(lines[0].episodes[1].url, 'http://a/2');
      expect(lines[1].episodes.single.url, 'http://b/1');
    });

    test('numbers bare urls and names missing lines', () {
      final lines = parsePlayLines(null, 'http://x/1#http://x/2');
      expect(lines.single.name, 'Line 1');
      expect(lines.single.episodes.map((e) => e.name), ['1', '2']);
    });

    test('empty input yields no lines', () {
      expect(parsePlayLines('a', ''), isEmpty);
      expect(parsePlayLines('a', null), isEmpty);
    });
  });

  group('M3U / XMLTV', () {
    test('parseM3u reads attributes and display names', () {
      final ch = parseM3u('#EXTM3U\n'
          '#EXTINF:-1 tvg-id="c1" tvg-name="One" tvg-logo="http://l/1.png" group-title="News",Channel One\n'
          'http://s/1.m3u8\n'
          '#EXTINF:-1,Bare\n'
          'http://s/2.m3u8\n');
      expect(ch, hasLength(2));
      expect(ch[0].name, 'Channel One');
      expect(ch[0].group, 'News');
      expect(ch[0].tvgId, 'c1');
      expect(ch[0].logo, 'http://l/1.png');
      expect(ch[1].name, 'Bare');
      expect(ch[1].group, isNull);
    });

    test('parseXmltvTime applies the zone offset', () {
      expect(parseXmltvTime('20261108183000 +0800'), DateTime.utc(2026, 11, 8, 10, 30));
      expect(parseXmltvTime('20261108183000 -0130'), DateTime.utc(2026, 11, 8, 20, 0));
      expect(parseXmltvTime('garbage'), isNull);
    });

    const xml = '<tv><programme start="20261108180000 +0000" stop="20261108190000 +0000" channel="c1">'
        '<title>News</title><desc>Evening</desc></programme>'
        '<programme start="bad" stop="bad" channel="c1"><title>Skipped</title></programme></tv>';

    test('parseXmltv skips broken programmes', () {
      final epg = parseXmltv(utf8.encode(xml));
      expect(epg.single.title, 'News');
      expect(epg.single.description, 'Evening');
    });

    test('parseXmltv accepts gzip', () {
      final epg = parseXmltv(gzip.encode(utf8.encode(xml)));
      expect(epg.single.channelId, 'c1');
    });

    test('epgFor falls back from tvg-id to display name', () {
      final entry = EpgEntry(channelId: 'x9', start: DateTime.utc(2026), stop: DateTime.utc(2026, 1, 2), title: 't');
      const ch = LiveChannel(name: 'Some Name', url: 'u', tvgId: 'nope');
      final hit = epgFor(ch, {'x9': [entry]}, {'x9': 'some name'});
      expect(hit, [entry]);
      expect(epgFor(ch, {}, {}), isEmpty);
    });
  });

  group('danmaku', () {
    test('parseDandanComments sorts by time and drops malformed rows', () {
      final list = parseDandanComments([
        {'p': '12.5,1,16777215,u', 'm': 'later'},
        {'p': '3,5,255,u', 'm': 'top'},
        {'p': 'bad', 'm': 'x'},
      ]);
      expect(list.map((c) => c.text), ['top', 'later']);
      expect(list.first.mode, 5);
      expect(list.first.color, 255);
    });

    test('filterDanmu honours blacklist and top/bottom switches', () {
      final src = parseDandanComments([
        {'p': '1,1,1,u', 'm': 'spoiler here'},
        {'p': '2,5,1,u', 'm': 'top'},
        {'p': '3,4,1,u', 'm': 'bottom'},
        {'p': '4,1,1,u', 'm': 'keep'},
      ]);
      final out = filterDanmu(src, blackList: ['spoiler', ''], showTop: false, showBottom: false);
      expect(out.map((c) => c.text), ['keep']);
    });
  });
}
