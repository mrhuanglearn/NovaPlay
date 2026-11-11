import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/app/providers.dart';
import 'package:uzv_reimpl/app/theme.dart';
import 'package:uzv_reimpl/app/ui_hooks.dart';
import 'package:uzv_reimpl/features/backup/backup_service.dart';
import 'package:uzv_reimpl/l10n/l10n.dart';
import 'package:uzv_reimpl/ui/service_settings_screens.dart';
import 'package:uzv_reimpl/ui/widgets.dart';

// 选择数据项并导出, OBSERVED on the original (2026-11-09, with the user's consent two backups were exported): the sheet's
// 导出 is greyed out while nothing is chosen; after saving, the sheet closes and 导出完成 shows 备份文件已保存：<file name>
// and, always (also for a backup of 播放历史 only), 备份可能包含账号、密码等敏感信息，分享时请注意。 in red; 完成 (accent)
// closes it, 分享 (text colour) closes it and opens the system share sheet. Files are named uzn-backup-yyyyMMdd-HHmmss.zip.

const _warning = '备份可能包含账号、密码等敏感信息，分享时请注意。';

void main() {
  test('file name: novaplay-backup-yyyyMMdd-HHmmss.zip', () {
    expect(backupFileName(DateTime(2026, 11, 9, 5, 55, 24)), 'novaplay-backup-20261109-055524.zip');
  });

  group('选择数据项并导出', () {
    late List<(String, List<int>)> saved;
    late List<String> shared;
    late _FakeBackup backup;

    Future<void> pump(WidgetTester tester, {Object? saveError, Object? shareError}) async {
      saved = [];
      shared = [];
      backup = _FakeBackup();
      final container = ProviderContainer(overrides: [
        backupServiceProvider.overrideWithValue(backup),
        backupSaverProvider.overrideWithValue((name, bytes) async {
          if (saveError != null) throw saveError;
          saved.add((name, bytes));
          return '/storage/Backups/$name';
        }),
        backupShareProvider.overrideWithValue((path, text) async {
          if (shareError != null) throw shareError;
          shared.add(path);
        }),
      ]);
      addTearDown(container.dispose);
      await tester.binding.setSurfaceSize(const Size(420, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          scaffoldMessengerKey: rootMessengerKey,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildAppTheme(Brightness.dark),
          home: const BackupScreen(),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择数据项并导出'));
      await tester.pumpAndSettle();
    }

    Finder exportButton() => find.widgetWithText(PrimaryButton, '导出');

    testWidgets('nothing chosen: 导出 is greyed out', (tester) async {
      await pump(tester);
      await tester.tap(find.text('全选'));
      await tester.pump();
      await tester.tap(find.text('全选'));
      await tester.pump();
      expect(find.byIcon(Icons.check_box), findsNothing);
      expect(tester.widget<PrimaryButton>(exportButton()).onPressed, isNull);
      await tester.tap(exportButton(), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(saved, isEmpty);
      expect(find.text('请至少选择一项'), findsNothing);
    });

    testWidgets('导出: the sheet closes and 导出完成 names the file, with the warning; 完成 closes it', (tester) async {
      await pump(tester);
      await tester.tap(exportButton());
      await tester.pumpAndSettle();
      expect(backup.exported, isNotNull);
      final name = saved.single.$1;
      expect(name, matches(RegExp(r'^novaplay-backup-\d{8}-\d{6}\.zip$')));
      expect(saved.single.$2, [7, 7]);
      expect(find.text('全选'), findsNothing); // the sheet is closed
      expect(find.text('导出完成'), findsOneWidget);
      expect(find.text('备份文件已保存：$name'), findsOneWidget);
      final dialog = tester.element(find.byType(AlertDialog));
      expect(tester.widget<Text>(find.text(_warning)).style?.color, AppColors.dangerText(dialog));
      Color? colorOf(String text) =>
          tester.widget<TextButton>(find.widgetWithText(TextButton, text)).style?.foregroundColor?.resolve({}) ??
          Theme.of(dialog).colorScheme.primary;
      expect(colorOf('完成'), AppColors.of(dialog).accent);
      expect(colorOf('分享'), AppColors.of(dialog).label);
      expect(shared, isEmpty); // no share sheet until 分享

      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.text('导出完成'), findsNothing);
      expect(shared, isEmpty);
    });

    testWidgets('分享 closes the dialog and shares the saved file', (tester) async {
      await pump(tester);
      await tester.tap(exportButton());
      await tester.pumpAndSettle();
      await tester.tap(find.text('分享'));
      await tester.pumpAndSettle();
      expect(find.text('导出完成'), findsNothing);
      expect(shared, ['/storage/Backups/${saved.single.$1}']);
    });

    testWidgets('a failed save: 导出失败，请重试, no dialog', (tester) async {
      await pump(tester, saveError: const FormatException('disk full'));
      await tester.tap(exportButton());
      await tester.pumpAndSettle();
      expect(find.text('导出失败，请重试'), findsOneWidget);
      expect(find.text('导出完成'), findsNothing);
    });

    testWidgets('a failed share: 分享失败', (tester) async {
      await pump(tester, shareError: StateError('no share target'));
      await tester.tap(exportButton());
      await tester.pumpAndSettle();
      await tester.tap(find.text('分享'));
      await tester.pumpAndSettle();
      expect(find.text('分享失败'), findsOneWidget);
    });
  });
}

class _FakeBackup extends BackupService {
  Iterable<String>? exported;

  @override
  Future<List<int>> exportZip(Iterable<String> items, {DateTime? now}) async {
    exported = [...items];
    return [7, 7];
  }
}
