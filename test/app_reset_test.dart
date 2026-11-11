import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/app/extra_providers.dart';
import 'package:uzv_reimpl/app/providers.dart';
import 'package:uzv_reimpl/app/theme.dart';
import 'package:uzv_reimpl/app/ui_hooks.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/features/reset/app_reset_service.dart';
import 'package:uzv_reimpl/l10n/l10n.dart';
import 'package:uzv_reimpl/ui/settings_screens.dart';

void main() {
  group('AppResetService', () {
    late Directory root;
    late Directory files;
    late Directory cache;
    late Directory docs;
    late Directory backups;
    setUp(() {
      root = Directory.systemTemp.createTempSync('uzv_reset');
      files = Directory('${root.path}/files')..createSync();
      cache = Directory('${root.path}/cache')..createSync();
      docs = Directory('${root.path}/app_flutter')..createSync();
      backups = Directory('${root.path}/external/files/Backups')..createSync(recursive: true);
      File('${backups.path}/uzv_backup.zip').writeAsStringSync('zip');
      File('${files.path}/settings.json').writeAsStringSync('{}');
      File('${files.path}/subscriptions/a/index.js').createSync(recursive: true);
      File('${files.path}/node-data/catpaw/db.json').createSync(recursive: true);
      File('${files.path}/downloads/x/1.ts').createSync(recursive: true);
      File('${cache.path}/file_picker/backup.zip').createSync(recursive: true);
      File('${docs.path}/note').createSync();
      Link('${files.path}/backups-link').createSync(backups.path);
    });
    tearDown(() {
      Process.runSync('chmod', ['-R', 'u+w', root.path]);
      root.deleteSync(recursive: true);
    });

    AppResetService service({void Function()? stop, Future<void> Function()? web}) =>
        AppResetService(dirs: () async => [files, cache, docs], stopWriters: stop, clearWebView: web ?? () async {});

    test('empties every app directory; links are removed, not followed; exported backups stay', () async {
      await service().wipe();
      for (final d in [files, cache, docs]) {
        expect(d.existsSync(), isTrue);
        expect(d.listSync(), isEmpty, reason: d.path);
      }
      expect(File('${backups.path}/uzv_backup.zip').readAsStringSync(), 'zip');
    });

    test('stops the writers and clears the WebView first; a WebView failure does not stop the reset', () async {
      final calls = <String>[];
      await service(
        stop: () => calls.add('stop'),
        web: () async {
          calls.add('web');
          throw StateError('no WebView yet');
        },
      ).reset();
      expect(calls, ['stop', 'web']);
      expect(files.listSync(), isEmpty);
    });

    test('an entry that cannot be deleted fails the reset after the others are gone', () async {
      final stuck = Directory('${files.path}/stuck')..createSync();
      File('${stuck.path}/f').createSync();
      Process.runSync('chmod', ['555', stuck.path]);
      await expectLater(service().wipe(), throwsA(isA<FileSystemException>()));
      expect(files.listSync().map((e) => e.path.split('/').last), ['stuck']);
      expect(cache.listSync(), isEmpty);
    });

    test('backups exported to the documents directory (no external storage) are kept too', () async {
      File('${docs.path}/Backups/uzv_backup.zip').createSync(recursive: true);
      await service().wipe();
      expect(docs.listSync().map((e) => e.path.split('/').last), ['Backups']);
      expect(File('${docs.path}/Backups/uzv_backup.zip').existsSync(), isTrue);
    });

    test('a missing directory is skipped', () async {
      docs.deleteSync(recursive: true);
      await service().wipe();
      expect(files.listSync(), isEmpty);
    });
  });

  group('重置应用 in 设置', () {
    Future<(_FakeReset, List<String>)> pump(WidgetTester tester, {bool fail = false}) async {
      final reset = _FakeReset(fail: fail);
      final exits = <String>[];
      final container = ProviderContainer(overrides: [
        settingsStoreProvider.overrideWithValue(_MemoryStore()),
        appResetServiceProvider.overrideWithValue(reset),
        appExitProvider.overrideWithValue(() async => exits.add('exit')),
      ]);
      addTearDown(container.dispose);
      await tester.binding.setSurfaceSize(const Size(420, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          scaffoldMessengerKey: rootMessengerKey,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildAppTheme(Brightness.dark),
          home: const SettingsIndexScreen(),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重置应用'));
      await tester.pumpAndSettle();
      return (reset, exits);
    }

    testWidgets('the row and the confirm dialog use the original wording; 取消 does nothing', (tester) async {
      final (reset, exits) = await pump(tester);
      expect(find.text('清空全部数据并重启'), findsOneWidget);
      expect(find.textContaining('将清空所有本地数据'), findsOneWidget);
      expect(find.textContaining('已导出的备份文件会保留'), findsOneWidget);
      final delete = tester.widget<TextButton>(find.widgetWithText(TextButton, '删除'));
      expect(delete.style?.foregroundColor?.resolve({}), AppColors.danger);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(reset.resets, 0);
      expect(exits, isEmpty);
    });

    testWidgets('删除: 正在重置…, then the message, then the files are wiped once more and the app exits', (tester) async {
      final (reset, exits) = await pump(tester);
      await tester.tap(find.text('删除'));
      await tester.pump();
      expect(find.text('正在重置…'), findsOneWidget);
      await tester.tap(find.byType(ModalBarrier).last, warnIfMissed: false); // not dismissible
      await tester.pump();
      expect(find.text('正在重置…'), findsOneWidget);

      reset.gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('正在重置…'), findsNothing);
      expect(find.text('所有数据已清空，应用将退出，请重新打开。'), findsOneWidget);
      expect(exits, isEmpty);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect((reset.resets, reset.wipes), (1, 1));
      expect(exits, ['exit']);
    });

    testWidgets('a failed reset says 重置失败，请重试 and keeps the app running', (tester) async {
      final (reset, exits) = await pump(tester, fail: true);
      await tester.tap(find.text('删除'));
      await tester.pump();
      reset.gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('正在重置…'), findsNothing);
      expect(find.text('重置失败，请重试'), findsOneWidget);
      expect(exits, isEmpty);
    });
  });
}

class _FakeReset extends AppResetService {
  _FakeReset({this.fail = false});
  final bool fail;
  final gate = Completer<void>();
  var resets = 0;
  var wipes = 0;

  @override
  Future<void> reset() async {
    resets++;
    await gate.future;
    if (fail) throw const FileSystemException('busy');
  }

  @override
  Future<void> wipe() async => wipes++;
}

/// settings.json in memory: widget tests run on a fake clock where real file I/O never completes.
class _MemoryStore extends JsonStore {
  _MemoryStore() : super('settings.json');
  Object? _data;

  @override
  Future<T> read<T>(T fallback) async => (_data as T?) ?? fallback;

  @override
  Future<void> write(Object? json) async => _data = json;
}
