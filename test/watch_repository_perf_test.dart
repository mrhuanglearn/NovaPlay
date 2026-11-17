import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/features/catpaw/spider_api.dart';
import 'package:uzv_reimpl/features/library/watch_repository.dart';
import 'package:uzv_reimpl/features/player/native_player_api.g.dart';
import 'package:uzv_reimpl/features/player/playback_source.dart';
import 'package:uzv_reimpl/features/player/player_session.dart';
import 'package:uzv_reimpl/features/sniffer/sniffer_service.dart';
import 'package:uzv_reimpl/models/vod.dart';

class _CountingJsonStore extends JsonStore {
  _CountingJsonStore(super.fileName, {super.baseDir});
  int diskReads = 0;
  int diskWrites = 0;

  @override
  Future<T> read<T>(T fallback) {
    diskReads++;
    return super.read<T>(fallback);
  }

  @override
  Future<void> write(Object? json) {
    diskWrites++;
    return super.write(json);
  }
}

class _NoopHost extends NativePlayerHostApi {
  @override
  Future<void> openPlayerPage(OpenPlayerRequest request) async {}
  @override
  Future<void> provideSource(SourcePayload payload) async {}
}

class _NoopApi extends SpiderApi {
  _NoopApi() : super(0);
}

void main() {
  group('Phase 2.2 WatchRepository in-memory index & deferred flush', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('watch_perf_');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('record(flush: false) updates memory index without disk write until flush()', () async {
      final store = _CountingJsonStore('history.json', baseDir: dir);
      final repo = HistoryRepository(store: store);

      await repo.record(
        const ProgressEntry(
          item: VodItem(id: 'v1', name: 'Movie 1', siteKey: 's1'),
          lineIndex: 0,
          episodeIndex: 0,
          episodeName: 'Ep 1',
          positionSeconds: 15,
          durationSeconds: 120,
          updatedAt: 0,
        ),
        flush: false,
      );

      expect(store.diskWrites, 0);
      expect(File('${dir.path}/history.json').existsSync(), isFalse);

      // Subsequent find() hits the in-memory index with zero store reads.
      final readsBefore = store.diskReads;
      final hit = await repo.find('s1', 'v1');
      expect(hit?.positionSeconds, 15);
      expect(store.diskReads, readsBefore);

      await repo.flush();
      expect(store.diskWrites, 1);
      expect(File('${dir.path}/history.json').existsSync(), isTrue);
    });

    test('FavoriteRepository caches isFavorite lookups in memory', () async {
      final store = _CountingJsonStore('favorites.json', baseDir: dir);
      final fav = FavoriteRepository(store: store);

      await fav.toggle(const VodItem(id: 'f1', name: 'Fav 1', siteKey: 's1'));
      final readsAfterToggle = store.diskReads;

      expect(await fav.isFavorite('s1', 'f1'), isTrue);
      expect(await fav.isFavorite('s1', 'missing'), isFalse);
      expect(store.diskReads, readsAfterToggle);
    });

    test('PlayerSession heartbeat updates memory without immediate disk write and flushes on close', () async {
      final store = _CountingJsonStore('history.json', baseDir: dir);
      final repo = HistoryRepository(store: store);
      final detail = VodDetail(
        item: const VodItem(id: '10', name: 'Series', siteKey: 'demo'),
        lines: parsePlayLines('Line1', r'Ep1$u1'),
      );
      final src = VodPlaybackSource(
        site: const SpiderSite(key: 'demo', name: 'Demo', api: '/spider/demo/3'),
        api: _NoopApi(),
        detail: detail,
        history: repo,
      );
      final session = PlayerSession(
        sessionId: 'hb1',
        source: src,
        host: _NoopHost(),
        sniffer: SnifferService(),
        onPreferences: (_) {},
      );

      await session.onHeartbeat(Heartbeat(sessionId: 'hb1', positionSeconds: 22, durationSeconds: 200));
      expect((await repo.find('demo', '10'))?.positionSeconds, 22);
      expect(store.diskWrites, 0);

      await session.onPageClosed(PageClosedEvent(sessionId: 'hb1', positionSeconds: 30, completed: false));
      expect(store.diskWrites, 1);
      expect((await repo.find('demo', '10'))?.positionSeconds, 30);
    });
  });
}
