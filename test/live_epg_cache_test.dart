import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/features/live/live_store.dart';
import 'package:uzv_reimpl/features/live/m3u_epg.dart';

void main() {
  group('Phase 2.4 Live EPG isolate parsing, O(1) name index, and disk cache', () {
    test('parseM3uAsync and parseXmltvGuideAsync parse gzipped XMLTV in isolate and match display-name case-insensitively', () async {
      const m3u = '#EXTM3U\n#EXTINF:-1 tvg-name="cctv-1综合",CCTV1\nhttp://live/1.m3u8\n';
      const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="ch_cctv1"><display-name>CCTV-1综合</display-name></channel>
  <programme start="20261117080000 +0800" stop="20261117090000 +0800" channel="ch_cctv1">
    <title>朝闻天下</title>
  </programme>
</tv>''';
      final gz = gzip.encode(utf8.encode(xml));

      final channels = await parseM3uAsync(m3u);
      final guide = await parseXmltvGuideAsync(gz);
      expect(channels.single.name, 'CCTV1');
      final progs = guide.forChannel(channels.single);
      expect(progs.single.title, '朝闻天下');
    });

    test('LivePlaylistLoader.loadGuide caches raw EPG bytes on disk and skips re-download within TTL', () async {
      final cacheDir = await Directory.systemTemp.createTemp('live_epg_cache_');
      addTearDown(() => cacheDir.delete(recursive: true));

      var downloads = 0;
      var currentTime = DateTime.utc(2026, 11, 17, 1, 0);
      final loader = LivePlaylistLoader(
        fetch: (_) async => '',
        fetchGuideBytes: (url) async {
          downloads++;
          return utf8.encode('<tv><channel id="c1"><display-name>One</display-name></channel></tv>');
        },
        cacheDir: cacheDir,
        now: () => currentTime,
      );

      final b1 = await loader.loadGuideBytes('http://epg.example/guide.xml.gz');
      final b2 = await loader.loadGuideBytes('http://epg.example/guide.xml.gz');
      expect(b1, isNotEmpty);
      expect(b2, b1);
      expect(downloads, 1, reason: 'second load within 24h must reuse cached EPG file');

      await loader.clearAll();
      await loader.loadGuideBytes('http://epg.example/guide.xml.gz');
      expect(downloads, 2, reason: 'clearAll wipes cached EPG files alongside playlists');
    });
  });
}
