import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uzv_reimpl/features/catpaw/spider_api.dart';
import 'package:uzv_reimpl/features/downloads/download_manager.dart';
import 'package:uzv_reimpl/features/subscription/subscription.dart';
import 'package:uzv_reimpl/services/media_server_client.dart';
import 'package:uzv_reimpl/services/tmdb_client.dart';
import 'package:uzv_reimpl/services/webdav_sync.dart';

void main() {
  group('DownloadManager correctness & security', () {
    test('file resume overwrites from byte 0 when server ignores Range and answers 200 instead of 206', () async {
      final dir = await Directory.systemTemp.createTemp('dl_200');
      addTearDown(() => dir.delete(recursive: true));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      var return206 = false;
      server.listen((req) async {
        final range = req.headers.value(HttpHeaders.rangeHeader);
        if (return206 && range == 'bytes=5-') {
          req.response.statusCode = HttpStatus.partialContent;
          req.response.headers.contentLength = 5;
          req.response.write('56789');
        } else {
          // Server ignores Range and sends full 10-byte file with 200 OK
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentLength = 10;
          req.response.write('0123456789');
        }
        await req.response.close();
      });

      // Case 1: Server answers 200 OK to Range -> must overwrite, NOT append to 15 bytes!
      final d1 = Directory(p.join(dir.path, 't1'))..createSync(recursive: true);
      File(p.join(d1.path, 'video.mp4')).writeAsStringSync('01234');
      final dm = DownloadManager();
      final t1 = dm.enqueue(DownloadTask(id: '1', title: '1', url: 'http://127.0.0.1:${server.port}/v.mp4', dir: d1.path));
      await dm.updates.firstWhere((u) => u.id == '1' && (u.state == DownloadState.done || u.state == DownloadState.failed));
      expect(t1.state, DownloadState.done);
      expect(File(t1.localPlaylist!).readAsStringSync(), '0123456789');

      // Case 2: Server answers 206 Partial Content -> appends cleanly!
      return206 = true;
      final d2 = Directory(p.join(dir.path, 't2'))..createSync(recursive: true);
      File(p.join(d2.path, 'video.mp4')).writeAsStringSync('01234');
      final t2 = dm.enqueue(DownloadTask(id: '2', title: '2', url: 'http://127.0.0.1:${server.port}/v.mp4', dir: d2.path));
      await dm.updates.firstWhere((u) => u.id == '2' && (u.state == DownloadState.done || u.state == DownloadState.failed));
      expect(t2.state, DownloadState.done);
      expect(File(t2.localPlaylist!).readAsStringSync(), '0123456789');
    });

    test('HLS downloads EXT-X-KEY and EXT-X-MAP and rewrites local index.m3u8 URIs', () async {
      final dir = await Directory.systemTemp.createTemp('dl_hls_key');
      addTearDown(() => dir.delete(recursive: true));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      server.listen((req) async {
        switch (req.uri.path) {
          case '/play.m3u8':
            req.response.write('#EXTM3U\n'
                '#EXT-X-VERSION:6\n'
                '#EXT-X-MAP:URI="init.mp4"\n'
                '#EXT-X-KEY:METHOD=AES-128,URI="/keys/enc.key",IV=0x00000000000000000000000000000001\n'
                '#EXTINF:4.0,\n'
                'seg0.ts\n'
                '#EXT-X-ENDLIST\n');
          case '/init.mp4':
            req.response.add([1, 2, 3, 4]);
          case '/keys/enc.key':
            req.response.add(List<int>.filled(16, 0xAB));
          case '/seg0.ts':
            req.response.add([9, 8, 7, 6]);
          default:
            req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final dm = DownloadManager();
      final outDir = p.join(dir.path, 'hls1');
      final task = dm.enqueue(DownloadTask(
        id: 'h1',
        title: 'Encrypted HLS',
        url: 'http://127.0.0.1:${server.port}/play.m3u8',
        dir: outDir,
      ));
      await dm.updates.firstWhere((u) => u.id == 'h1' && (u.state == DownloadState.done || u.state == DownloadState.failed));
      expect(task.state, DownloadState.done);

      final rewritten = File(task.localPlaylist!).readAsStringSync();
      expect(rewritten, isNot(contains('/keys/enc.key')));
      expect(rewritten, isNot(contains('"init.mp4"')));
      final keyMatch = RegExp(r'#EXT-X-KEY:METHOD=AES-128,URI="([^"]+)"').firstMatch(rewritten);
      final mapMatch = RegExp(r'#EXT-X-MAP:URI="([^"]+)"').firstMatch(rewritten);
      expect(keyMatch, isNotNull);
      expect(mapMatch, isNotNull);
      expect(File(p.join(outDir, keyMatch!.group(1)!)).readAsBytesSync(), hasLength(16));
      expect(File(p.join(outDir, mapMatch!.group(1)!)).readAsBytesSync(), [1, 2, 3, 4]);
    });

    test('default HTTP clients enforce finite connect and receive timeouts', () {
      expect(SubscriptionInstaller().dioConnectTimeout, greaterThan(Duration.zero));
      expect(DownloadManager().dioConnectTimeout, greaterThan(Duration.zero));
      expect(TmdbClient(const TmdbSettings()).dioConnectTimeout, greaterThan(Duration.zero));
      expect(MediaServerClient(const MediaAccount(id: '1', name: 'n', baseUrl: 'http://h')).dioConnectTimeout, greaterThan(Duration.zero));
      expect(WebDavClient(const WebDavConfig(url: 'http://h', username: 'u', password: 'p')).dioConnectTimeout, greaterThan(Duration.zero));
      expect(SpiderApi(2333).receiveTimeout, greaterThan(Duration.zero));
    });
  });
}
