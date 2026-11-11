import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/app/extra_providers.dart';
import 'package:uzv_reimpl/app/providers.dart';
import 'package:uzv_reimpl/app/theme.dart';
import 'package:uzv_reimpl/app/ui_hooks.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/core/restore_error.dart';
import 'package:uzv_reimpl/features/backup/backup_service.dart';
import 'package:uzv_reimpl/l10n/l10n.dart';
import 'package:uzv_reimpl/services/webdav_sync.dart';
import 'package:uzv_reimpl/ui/service_settings_screens.dart';
import 'package:uzv_reimpl/ui/widgets.dart';

// 从备份恢复 / 从 WebDAV 恢复. The original says 数据已恢复，应用即将退出，请重新打开。 (OBSERVED string): what the app loaded
// before the restore is stale, and the next save of a preference would write the old values back over the restored
// settings.json. So a restore ends with that message and the app exits, as after 重置应用.

const _done = '数据已恢复，应用即将退出，请重新打开。';
const _writeFailed = '恢复过程中出错，建议重启应用';

void main() {
  group('a restore either writes nothing or reports a failed write', () {
    late Directory src;
    late Directory dst;
    setUp(() {
      src = Directory.systemTemp.createTempSync('uzv_restore_src');
      dst = Directory.systemTemp.createTempSync('uzv_restore_dst');
    });
    tearDown(() {
      src.deleteSync(recursive: true);
      dst.deleteSync(recursive: true);
    });

    test('backup: a document that cannot be written fails with RestoreWriteException after the earlier ones', () async {
      await JsonStore('history.json', baseDir: src).write([
        {'id': 'h'}
      ]);
      await JsonStore('favorites.json', baseDir: src).write([
        {'vod_id': 'f'}
      ]);
      final zip = await BackupService(storeFor: (f) => JsonStore(f, baseDir: src)).exportZip(['history', 'favorites']);
      final target =
          BackupService(storeFor: (f) => f == 'favorites.json' ? _BrokenStore(f) : JsonStore(f, baseDir: dst));
      await expectLater(target.importBytes(zip),
          throwsA(isA<RestoreWriteException>().having((e) => e.file, 'file', 'favorites.json')));
      expect(await JsonStore('history.json', baseDir: dst).read<Object?>(null), [
        {'id': 'h'}
      ]);
    });

    test('WebDAV: a document that cannot be downloaded leaves every local document as it was', () async {
      final remote = _Remote()
        ..files['uzvSync/manifest.json'] = jsonEncode({'favorites.json': 1, 'history.json': 1})
        ..files['uzvSync/favorites.json'] = jsonEncode([
          {'vod_id': 'remote'}
        ])
        ..failing.add('uzvSync/history.json');
      await JsonStore('favorites.json', baseDir: dst).write([
        {'vod_id': 'local'}
      ]);
      final sync = WebDavSync(remote,
          storeFor: (f) => JsonStore(f, baseDir: dst), state: JsonStore('webdav_sync_state.json', baseDir: dst));
      await expectLater(sync.restoreAll(), throwsA(isA<WebDavException>()));
      expect(await JsonStore('favorites.json', baseDir: dst).read<Object?>(null), [
        {'vod_id': 'local'}
      ]);
    });

    test('WebDAV: a document that cannot be written fails with RestoreWriteException', () async {
      final remote = _Remote()
        ..files['uzvSync/manifest.json'] = jsonEncode({'favorites.json': 1})
        ..files['uzvSync/favorites.json'] = '[]';
      final sync = WebDavSync(remote,
          storeFor: (f) => _BrokenStore(f), state: JsonStore('webdav_sync_state.json', baseDir: dst));
      await expectLater(sync.restoreAll(), throwsA(isA<RestoreWriteException>()));
    });
  });

  group('BackupService.read / restore', () {
    late Directory src;
    late Directory dst;
    setUp(() {
      src = Directory.systemTemp.createTempSync('uzv_read_src');
      dst = Directory.systemTemp.createTempSync('uzv_read_dst');
    });
    tearDown(() {
      src.deleteSync(recursive: true);
      dst.deleteSync(recursive: true);
    });

    test('read writes nothing and lists the items present; restore writes only the chosen ones', () async {
      await JsonStore('history.json', baseDir: src).write(['h']);
      await JsonStore('settings.json', baseDir: src).write({'themeColor': 'green'});
      final made = DateTime(2026, 11, 9, 5, 55);
      final zip = await BackupService(storeFor: (f) => JsonStore(f, baseDir: src))
          .exportZip(['history', 'favorites', 'appSettings'], now: made);
      final service = BackupService(storeFor: (f) => JsonStore(f, baseDir: dst));
      final contents = service.read(zip);
      expect(dst.listSync(), isEmpty);
      expect(contents.items, ['history', 'appSettings']); // 收藏 was chosen but had nothing to export
      expect(contents.createdAt, made);
      expect(contents.appVersion, '0.1.0');
      expect(contents.platform, Platform.operatingSystem);

      expect(await service.restore(contents, ['appSettings']), ['settings.json']);
      expect(await JsonStore('settings.json', baseDir: dst).read<Object?>(null), {'themeColor': 'green'});
      expect(File('${dst.path}/history.json').existsSync(), isFalse);
    });

    test('JSON backups of earlier versions: no version, time from the file', () {
      final made = DateTime(2026, 1, 2, 3, 4);
      final contents = BackupService().read(utf8.encode(jsonEncode({
        'format': 'uzv-reimpl-backup',
        'version': 1,
        'createdAt': made.millisecondsSinceEpoch,
        'documents': {'favorites.json': [], 'unknown.json': 1},
      })));
      expect(contents.items, ['favorites']);
      expect(contents.documents.keys, ['favorites.json']);
      expect(contents.createdAt, made);
      expect(contents.appVersion, isNull);
    });
  });

  group('从备份恢复', () {
    final full = BackupContents({'history.json': [], 'favorites.json': [], 'settings.json': {}},
        createdAt: DateTime(2026, 11, 9, 5, 55), appVersion: '0.1.0', platform: 'android');

    Future<(_FakeBackup, List<String>)> pump(WidgetTester tester,
        {Uint8List? picked,
        Object? pickError,
        BackupContents? contents,
        Object? readError,
        List<String> result = const ['settings.json'],
        Object? error}) async {
      final backup = _FakeBackup(contents: contents ?? full, readError: readError, result: result, error: error);
      final exits = <String>[];
      final container = ProviderContainer(overrides: [
        backupServiceProvider.overrideWithValue(backup),
        backupPickerProvider.overrideWithValue(() async {
          if (pickError != null) throw pickError;
          return picked;
        }),
        appExitProvider.overrideWithValue(() async => exits.add('exit')),
      ]);
      addTearDown(container.dispose);
      await _show(tester, container, const BackupScreen());
      await tester.tap(find.text('选择备份文件恢复'));
      await tester.pumpAndSettle();
      return (backup, exits);
    }

    Finder restoreButton() => find.widgetWithText(PrimaryButton, '恢复');

    testWidgets('the sheet: backup time, source version, the items in the backup, all chosen', (tester) async {
      final (backup, _) = await pump(tester, picked: Uint8List.fromList([1, 2, 3]));
      expect(backup.read_, [1, 2, 3]);
      expect(find.text('备份与恢复'), findsWidgets);
      expect(find.text('备份时间：2026-11-09 05:55'), findsOneWidget);
      expect(find.text('来源版本：v0.1.0（android）'), findsOneWidget);
      expect(find.text('勾选要恢复的数据项，将以备份包内容覆盖本地同名数据。'), findsOneWidget);
      for (final t in ['全选', '播放历史', '收藏', '应用设置（含弹幕服务配置）', '用户数据', '偏好设置']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      for (final t in ['播放进度', '订阅列表', '订阅与弹幕服务', '媒体服务器与 WebDAV 账号']) {
        expect(find.text(t), findsNothing, reason: t);
      }
      expect(find.byIcon(Icons.check_box), findsNWidgets(4)); // 全选 + three items
      expect(find.textContaining('明文'), findsNothing); // no sensitive-data warning
      expect(backup.restored, isNull);
    });

    testWidgets('a backup without version fields shows only the time', (tester) async {
      await pump(tester,
          picked: Uint8List(1),
          contents: BackupContents({'favorites.json': []}, createdAt: DateTime(2026, 1, 2, 3, 4)));
      expect(find.text('备份时间：2026-01-02 03:04'), findsOneWidget);
      expect(find.textContaining('来源版本'), findsNothing);
    });

    testWidgets('nothing chosen: 恢复 is disabled; 全选 is ticked only when everything is', (tester) async {
      final (backup, _) = await pump(tester, picked: Uint8List(1));
      await tester.tap(find.text('全选'));
      await tester.pump();
      expect(find.byIcon(Icons.check_box), findsNothing);
      expect(tester.widget<PrimaryButton>(restoreButton()).onPressed, isNull);
      await tester.tap(restoreButton(), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('确认恢复'), findsNothing);

      await tester.tap(find.text('收藏'));
      await tester.pump();
      expect(find.byIcon(Icons.check_box), findsOneWidget); // only 收藏, 全选 stays clear
      expect(tester.widget<PrimaryButton>(restoreButton()).onPressed, isNotNull);
      expect(backup.restored, isNull);
    });

    testWidgets('only the chosen items: 确认恢复, 正在恢复…, then the message; 确定 ends the app', (tester) async {
      final (backup, exits) = await pump(tester, picked: Uint8List(1));
      await tester.tap(find.text('播放历史'));
      await tester.pump();
      await tester.tap(restoreButton());
      await tester.pumpAndSettle();
      expect(find.text('备份时间：2026-11-09 05:55'), findsNothing); // the sheet is closed
      expect(find.text('确认恢复'), findsOneWidget);
      expect(find.text('选中的数据将被备份包内容覆盖（本地多出的记录会丢失），完成后应用将自动退出，需重新打开。'), findsOneWidget);
      // OBSERVED: 取消 in the accent colour, 恢复 in the text colour.
      final dialog = tester.element(find.byType(AlertDialog));
      Color? colorOf(String text) =>
          tester.widget<TextButton>(find.widgetWithText(TextButton, text)).style?.foregroundColor?.resolve({}) ??
          Theme.of(dialog).colorScheme.primary;
      expect(colorOf('取消'), AppColors.of(dialog).accent);
      expect(colorOf('恢复'), AppColors.of(dialog).label);

      await tester.tap(find.widgetWithText(TextButton, '恢复'));
      await tester.pump();
      expect(find.text('正在恢复…'), findsOneWidget);
      await tester.tap(find.byType(ModalBarrier).last, warnIfMissed: false); // not dismissible
      await tester.pump();
      expect(find.text('正在恢复…'), findsOneWidget);

      backup.gate.complete();
      await tester.pumpAndSettle();
      expect(backup.restored, ['favorites', 'appSettings']);
      expect(find.text(_done), findsOneWidget);
      await tester.tap(find.byType(ModalBarrier).last, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(exits, isEmpty);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(exits, ['exit']);
    });

    testWidgets('取消 on 确认恢复, or closing the sheet: nothing is restored', (tester) async {
      var (backup, exits) = await pump(tester, picked: Uint8List(1));
      await tester.tap(restoreButton());
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('确认恢复'), findsNothing);
      expect(find.text('全选'), findsNothing); // back on the page, not the sheet
      expect(backup.restored, isNull);

      (backup, exits) = await pump(tester, picked: Uint8List(1));
      await tester.tapAt(const Offset(200, 20)); // above the sheet
      await tester.pumpAndSettle();
      expect(find.text('全选'), findsNothing);
      expect(find.text('确认恢复'), findsNothing);
      expect(backup.restored, isNull);
      expect(exits, isEmpty);
    });

    testWidgets('no file picked: nothing happens', (tester) async {
      final (backup, _) = await pump(tester);
      expect(backup.read_, isNull);
      expect(find.text('全选'), findsNothing);
    });

    testWidgets('the picker fails: 恢复文件失败 with its reason', (tester) async {
      final (backup, exits) =
          await pump(tester, pickError: PlatformException(code: 'unknown_path', message: 'Failed to retrieve path.'));
      expect(find.text('恢复文件失败: Failed to retrieve path.'), findsOneWidget);
      expect(find.text('全选'), findsNothing);
      expect(backup.read_, isNull);
      expect(exits, isEmpty);
    });

    testWidgets('not a backup: an error box right after picking, no sheet', (tester) async {
      final (_, exits) =
          await pump(tester, picked: Uint8List(1), readError: const FormatException('not a backup file'));
      expect(find.text('不是有效的星映备份包'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.text('全选'), findsNothing);
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('不是有效的星映备份包'), findsNothing);
      expect(exits, isEmpty);
    });

    testWidgets('a write that fails part way: 恢复过程中出错，建议重启应用', (tester) async {
      final (backup, exits) = await pump(tester,
          picked: Uint8List(1), error: RestoreWriteException('favorites.json', const FileSystemException('full')));
      await tester.tap(restoreButton());
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '恢复'));
      await tester.pump();
      backup.gate.complete();
      await tester.pumpAndSettle();
      expect(find.text(_writeFailed), findsOneWidget);
      expect(find.text(_done), findsNothing);
      expect(exits, isEmpty);
    });
  });

  group('从 WebDAV 恢复', () {
    Future<(_FakeSync, List<String>)> pump(WidgetTester tester,
        {List<String> pulled = const ['favorites.json'], Object? error}) async {
      final sync = _FakeSync(pulled: pulled, error: error);
      final exits = <String>[];
      final config = _MemoryStore('webdav_config.json');
      await config.write(const WebDavConfig(url: 'https://dav.example', username: 'u', password: 'p').toJson());
      final container = ProviderContainer(overrides: [
        webDavConfigStoreProvider.overrideWithValue(config),
        webDavSyncProvider.overrideWithValue((cfg) => sync),
        appExitProvider.overrideWithValue(() async => exits.add('exit')),
      ]);
      addTearDown(container.dispose);
      await _show(tester, container, const WebDavSettingsScreen());
      await tester.scrollUntilVisible(find.text('从 WebDAV 恢复'), 200);
      await tester.tap(find.text('从 WebDAV 恢复'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '恢复'));
      await tester.pump();
      expect(find.text('正在恢复…'), findsOneWidget);
      sync.gate.complete();
      await tester.pumpAndSettle();
      return (sync, exits);
    }

    testWidgets('restored documents: the same message, then the app exits', (tester) async {
      final (sync, exits) = await pump(tester);
      expect(sync.restored, 1);
      expect(find.text(_done), findsOneWidget);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(exits, ['exit']);
    });

    testWidgets('a server error before anything was written: the WebDAV message, the app keeps running',
        (tester) async {
      final (_, exits) = await pump(tester, error: WebDavException('auth', '401'));
      expect(find.text('WebDAV 同步失败：401'), findsOneWidget);
      expect(exits, isEmpty);
    });

    testWidgets('nothing on the server: 已恢复 0 个文档, the app keeps running', (tester) async {
      final (_, exits) = await pump(tester, pulled: const []);
      expect(find.text('已恢复 0 个文档'), findsOneWidget);
      expect(exits, isEmpty);
    });
  });
}

Future<void> _show(WidgetTester tester, ProviderContainer container, Widget screen) async {
  await tester.binding.setSurfaceSize(const Size(420, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      scaffoldMessengerKey: rootMessengerKey,
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildAppTheme(Brightness.dark),
      home: screen,
    ),
  ));
  await tester.pumpAndSettle();
}

class _FakeBackup extends BackupService {
  _FakeBackup({required this.contents, this.readError, required this.result, this.error});
  final BackupContents contents;
  final Object? readError;
  final List<String> result;
  final Object? error;
  final gate = Completer<void>();
  List<int>? read_;
  List<String>? restored;

  @override
  BackupContents read(List<int> bytes) {
    read_ = bytes;
    if (readError != null) throw readError!;
    return contents;
  }

  @override
  Future<List<String>> restore(BackupContents contents, Iterable<String> items) async {
    restored = [...items];
    await gate.future;
    if (error != null) throw error!;
    return result;
  }
}

class _FakeSync extends WebDavSync {
  _FakeSync({required this.pulled, this.error}) : super(_Remote());
  final List<String> pulled;
  final Object? error;
  final gate = Completer<void>();
  int restored = 0;

  @override
  Future<SyncReport> restoreAll({Iterable<String>? documents}) async {
    restored++;
    await gate.future;
    if (error != null) throw error!;
    return SyncReport(pulled: [...pulled]);
  }
}

class _Remote implements WebDavRemote {
  final files = <String, String>{};
  final failing = <String>{};
  @override
  Future<void> mkcol(String dir) async {}
  @override
  Future<String?> readText(String path) async {
    if (failing.contains(path)) throw WebDavException('connection', 'reset');
    return files[path];
  }

  @override
  Future<void> writeText(String path, String body) async => files[path] = body;
}

class _BrokenStore extends JsonStore {
  _BrokenStore(super.name);
  @override
  Future<void> write(Object? json) async => throw const FileSystemException('No space left on device');
}

class _MemoryStore extends JsonStore {
  _MemoryStore(super.name);
  Object? _data;

  @override
  Future<T> read<T>(T fallback) async => (_data as T?) ?? fallback;

  @override
  Future<void> write(Object? json) async => _data = json;
}
