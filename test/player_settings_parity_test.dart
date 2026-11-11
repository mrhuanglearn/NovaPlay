import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/app/providers.dart';
import 'package:uzv_reimpl/app/theme.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/features/player/player_launcher.dart';
import 'package:uzv_reimpl/l10n/l10n.dart';
import 'package:uzv_reimpl/ui/form_widgets.dart';
import 'package:uzv_reimpl/ui/player_settings_screens.dart';
import 'package:uzv_reimpl/ui/widgets.dart';

// User report (2026-11-10): the player page's settings must be the same as 设置 → 播放器. OBSERVED in UZN 1.1.7 on the
// phone: the player's gear opens the same rows as the settings page. The native panel's rows are listed in
// android/.../ui/PlayerSettings.kt and checked by PlayerSettingsTest.theStepsMatchThePlayerSettingsPage against this
// same list; change both together.
const playerSettingTitles = [
  '硬件加速', '播放内核', '画面填充', '默认倍速', '快进快退秒数', '长按倍速', '长按滑动调节倍速', '优先横屏', //
  '进度条显示总时长', '隐藏中央快进快退', '进入后台暂停', '进入后台自动画中画', '跳过提示', '切集提示', //
  '显示帧率与编码', '始终显示网速', '首选字幕语言', '字幕字体', '字体目录（可选）', '首选音轨语言',
];
const playerSettingSections = ['解码', '画面与内核', '播放', '信息显示', '字幕与音频'];

void main() {
  late PlayerConfigRepository repo;

  setUp(() => repo = PlayerConfigRepository(store: _MemoryStore('player_config.json')));

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 4000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [playerConfigRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildAppTheme(Brightness.light),
        home: const PlayerSettingsScreen(),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the rows are the ones of the player page, in the same order', (tester) async {
    await pump(tester);
    final titles = tester
        .widgetList(find.byWidgetPredicate((w) => w is SettingsTile || w is CommitTextRow)) // a SwitchRow is a SettingsTile
        .map((w) => switch (w) {
              SettingsTile(:final title) => title,
              CommitTextRow(:final label) => label,
              _ => '',
            })
        .toList();
    expect(titles, playerSettingTitles);
    expect(tester.widgetList<SettingsSection>(find.byType(SettingsSection)).map((s) => s.title).toList(),
        playerSettingSections);
  });

  testWidgets('长按滑动调节倍速 is on until turned off, and is saved', (tester) async {
    await pump(tester);
    final row = find.widgetWithText(SwitchRow, '长按滑动调节倍速');
    expect(tester.widget<SwitchRow>(row).value, isTrue);
    await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    final (p, _) = await repo.load();
    expect(p.isLongPressSpeedAdjustEnabled, isFalse);
  });

  testWidgets('kernels and fill modes use the original labels', (tester) async {
    await pump(tester);
    await tester.tap(find.text('播放内核'));
    await tester.pumpAndSettle();
    for (final t in ['MPV (MPV)', 'MDK (MDK)', 'EXO (SYSTEM)']) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    await tester.tap(find.text('MDK (MDK)'));
    await tester.pumpAndSettle();
    expect(find.text('MDK'), findsOneWidget);
    final (p, _) = await repo.load();
    expect(p.kernel, 'mdk');

    await tester.tap(find.text('画面填充'));
    await tester.pumpAndSettle();
    for (final t in ['裁剪铺满', '拉伸铺满']) {
      expect(find.text(t), findsWidgets, reason: t);
    }
  });
}

class _MemoryStore extends JsonStore {
  _MemoryStore(super.name);
  Object? _data;

  @override
  Future<T> read<T>(T fallback) async => (_data as T?) ?? fallback;

  @override
  Future<void> write(Object? json) async => _data = json;
}
