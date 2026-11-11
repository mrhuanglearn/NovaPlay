import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/features/backup/backup_service.dart';
import 'package:uzv_reimpl/services/webdav_sync.dart';

class MemoryRemote implements WebDavRemote {
  final files = <String, String>{};
  @override
  Future<void> mkcol(String dir) async {}
  @override
  Future<String?> readText(String path) async => files[path];
  @override
  Future<void> writeText(String path, String body) async => files[path] = body;
}

void main() {
  group('decideSync', () {
    test('first sync: whichever side exists wins', () {
      expect(decideSync(localMs: 10, remoteMs: 0), SyncAction.push);
      expect(decideSync(localMs: 0, remoteMs: 10), SyncAction.pull);
      expect(decideSync(localMs: 0, remoteMs: 0), SyncAction.none);
    });

    test('only the side that moved since the last sync is transferred', () {
      expect(decideSync(localMs: 20, remoteMs: 10, lastLocalMs: 10, lastRemoteMs: 10), SyncAction.push);
      expect(decideSync(localMs: 10, remoteMs: 20, lastLocalMs: 10, lastRemoteMs: 10), SyncAction.pull);
      expect(decideSync(localMs: 10, remoteMs: 10, lastLocalMs: 10, lastRemoteMs: 10), SyncAction.none);
    });

    test('a file we just pulled has a newer local mtime but is not a local change', () {
      // remote 100 was written locally at 500; state remembers both
      expect(decideSync(localMs: 500, remoteMs: 100, lastLocalMs: 500, lastRemoteMs: 100), SyncAction.none);
    });

    test('both changed: newest wins', () {
      expect(decideSync(localMs: 30, remoteMs: 20, lastLocalMs: 10, lastRemoteMs: 10), SyncAction.push);
      expect(decideSync(localMs: 20, remoteMs: 30, lastLocalMs: 10, lastRemoteMs: 10), SyncAction.pull);
    });
  });

  group('WebDavSync', () {
    late Directory a;
    late Directory b;
    late MemoryRemote remote;

    setUp(() async {
      a = await Directory.systemTemp.createTemp('devA');
      b = await Directory.systemTemp.createTemp('devB');
      remote = MemoryRemote();
    });
    tearDown(() async {
      await a.delete(recursive: true);
      await b.delete(recursive: true);
    });

    WebDavSync device(Directory dir) => WebDavSync(
          remote,
          storeFor: (f) => JsonStore(f, baseDir: dir),
          state: JsonStore('webdav_sync_state.json', baseDir: dir),
        );

    Future<void> touch(Directory dir, String file, int ms) => File('${dir.path}/$file').setLastModified(DateTime.fromMillisecondsSinceEpoch(ms));

    test('push from one device, pull on another, and the pulled file does not bounce back', () async {
      await JsonStore('favorites.json', baseDir: a).write([{'vod_id': '1'}]);
      await touch(a, 'favorites.json', 1000000);
      final r1 = await device(a).sync();
      expect(r1.pushed, ['favorites.json']);
      expect(jsonDecode(remote.files['uzvSync/manifest.json']!), {'favorites.json': 1000000});

      final r2 = await device(b).sync();
      expect(r2.pulled, ['favorites.json']);
      expect(await JsonStore('favorites.json', baseDir: b).read<Object?>(null), [{'vod_id': '1'}]);

      // B's local file now has a "now" mtime, far newer than the remote manifest; it must not be pushed back.
      final r3 = await device(b).sync();
      expect(r3.pushed, isEmpty);
      expect(r3.pulled, isEmpty);
      final r4 = await device(a).sync();
      expect(r4.pushed, isEmpty);
      expect(r4.pulled, isEmpty);
    });

    test('a later local edit is pushed and then pulled by the other device', () async {
      await JsonStore('history.json', baseDir: a).write([1]);
      await touch(a, 'history.json', 1000000);
      await device(a).sync();
      await device(b).sync();

      await JsonStore('history.json', baseDir: a).write([1, 2]);
      await touch(a, 'history.json', 2000000);
      expect((await device(a).sync()).pushed, ['history.json']);
      final r = await device(b).sync();
      expect(r.pulled, ['history.json']);
      expect(await JsonStore('history.json', baseDir: b).read<Object?>(null), [1, 2]);
    });
  });

  group('BackupService', () {
    test('export then import restores every known document and ignores unknown ones', () async {
      final src = await Directory.systemTemp.createTemp('bkSrc');
      final dst = await Directory.systemTemp.createTemp('bkDst');
      addTearDown(() async {
        await src.delete(recursive: true);
        await dst.delete(recursive: true);
      });
      await JsonStore('favorites.json', baseDir: src).write([{'vod_id': '9'}]);
      await JsonStore('tmdb_settings.json', baseDir: src).write({'enabled': true});
      final text = await BackupService(storeFor: (f) => JsonStore(f, baseDir: src)).export();

      final tampered = jsonDecode(text) as Map<String, dynamic>;
      (tampered['documents'] as Map)['../evil.json'] = {'x': 1};
      final restored = await BackupService(storeFor: (f) => JsonStore(f, baseDir: dst)).import(jsonEncode(tampered));
      expect(restored, unorderedEquals(['favorites.json', 'tmdb_settings.json']));
      expect(await JsonStore('favorites.json', baseDir: dst).read<Object?>(null), [{'vod_id': '9'}]);
      expect(File('${dst.path}/../evil.json').existsSync(), isFalse);
    });

    test('garbage is rejected', () async {
      final svc = BackupService(storeFor: (f) => JsonStore(f, baseDir: Directory.systemTemp));
      await expectLater(svc.import('not json'), throwsFormatException);
      await expectLater(svc.import('{"format":"other"}'), throwsFormatException);
      await expectLater(svc.importBytes([0x50, 0x4B, 3, 4, 9, 9, 9]), throwsFormatException);
    });

    test('zip: only the chosen items are exported, and a restore writes only known documents', () async {
      final src = await Directory.systemTemp.createTemp('bkZipSrc');
      final dst = await Directory.systemTemp.createTemp('bkZipDst');
      addTearDown(() async {
        await src.delete(recursive: true);
        await dst.delete(recursive: true);
      });
      await JsonStore('history.json', baseDir: src).write([{'id': 1}]);
      await JsonStore('favorites.json', baseDir: src).write([{'id': 2}]);
      await JsonStore('emby_accounts.json', baseDir: src).write([{'token': 't'}]);
      final zip = await BackupService(storeFor: (f) => JsonStore(f, baseDir: src)).exportZip(['history', 'accounts']);

      final names = ZipDecoder().decodeBytes(zip).files.map((f) => f.name).toList();
      expect(names, unorderedEquals(['history.json', 'emby_accounts.json', 'manifest.json']));

      // a crafted archive: extra entries with paths or unknown names are skipped
      final archive = ZipDecoder().decodeBytes(zip);
      final evil = utf8.encode('{"x":1}');
      archive.addFile(ArchiveFile('../evil.json', evil.length, evil));
      archive.addFile(ArchiveFile('other.json', evil.length, evil));
      final restored = await BackupService(storeFor: (f) => JsonStore(f, baseDir: dst)).importBytes(ZipEncoder().encode(archive));
      expect(restored, unorderedEquals(['history.json', 'emby_accounts.json']));
      expect(await JsonStore('history.json', baseDir: dst).read<Object?>(null), [{'id': 1}]);
      expect(File('${dst.path}/../evil.json').existsSync(), isFalse);
      expect(File('${dst.path}/other.json').existsSync(), isFalse);
    });

    test('importBytes still reads the JSON backups of earlier versions', () async {
      final src = await Directory.systemTemp.createTemp('bkOld');
      addTearDown(() => src.delete(recursive: true));
      await JsonStore('favorites.json', baseDir: src).write([1]);
      final svc = BackupService(storeFor: (f) => JsonStore(f, baseDir: src));
      expect(await svc.importBytes(utf8.encode(await svc.export())), ['favorites.json']);
    });

    test('every backup item lists documents, accounts are opt-in', () {
      expect(backupItems.every((i) => i.files.isNotEmpty), isTrue);
      expect(backupItems.where((i) => !i.byDefault).map((i) => i.key), ['accounts']);
      expect(backupFiles, containsAll(syncedDocuments));
    });
  });

  group('WebDAV data types', () {
    test('documentsForTypes covers every synced document and keeps their order', () {
      expect(documentsForTypes(webdavDataTypeOrder), syncedDocuments);
      expect(documentsForTypes(['live', 'favorites']), ['favorites.json', 'live_sources.json', 'live_preferences.json', 'auto_sync_favorites.json']);
      expect(documentsForTypes(const []), isEmpty);
    });

    test('older configs sync everything and are not switched on', () {
      final c = WebDavConfig.fromJson({'url': 'https://dav', 'username': 'u', 'password': 'p'});
      expect(c.enabled, isFalse);
      expect(c.documents, syncedDocuments);
      final back = WebDavConfig.fromJson(c.copyWith(enabled: true, types: ['tmdb', 'bogus'], lastSyncMs: 5).toJson());
      expect((back.enabled, back.lastSyncMs), (true, 5));
      expect(back.types, ['tmdb']);
    });

    test('sync(documents:) leaves the other documents alone', () async {
      final dir = await Directory.systemTemp.createTemp('devT');
      addTearDown(() => dir.delete(recursive: true));
      final remote = MemoryRemote();
      await JsonStore('favorites.json', baseDir: dir).write([1]);
      await JsonStore('history.json', baseDir: dir).write([2]);
      final r = await WebDavSync(remote, storeFor: (f) => JsonStore(f, baseDir: dir), state: JsonStore('s.json', baseDir: dir))
          .sync(documents: documentsForTypes(['history']));
      expect(r.pushed, ['history.json']);
    });
  });
}
