import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/app_preferences.dart';
import '../app/providers.dart';
import '../app/theme.dart';
import '../app/ui_hooks.dart';
import '../core/app_log.dart';
import '../core/haptics.dart';
import '../features/cleanup/cleanup_service.dart';
import '../features/fonts/font_library.dart';
import '../features/player/native_player_api.g.dart';
import '../l10n/l10n.dart';
import 'app_shell.dart';
import 'widgets.dart';

String languageLabel(AppLocalizations l, AppLanguage language) => switch (language) {
      AppLanguage.system => l.languageSystem,
      AppLanguage.zh => l.languageZh,
      AppLanguage.en => l.languageEn,
    };

/// `/settings/language`. OBSERVED: one card per language (globe tile, name, accent check on the chosen one).
class LanguageScreen extends ConsumerWidget {
  const LanguageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final c = AppColors.of(context);
    final prefs = ref.watch(appPreferencesProvider);
    return Scaffold(
      // OBSERVED: this page's title is bold, unlike 主题设置 and 功能设置
      appBar: AppBar(title: Text(l.language, style: const TextStyle(fontWeight: FontWeight.w700))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 13, 16, 24), children: [
        for (final lang in AppLanguage.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 11),
            child: Material(
              color: c.card,
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => ref.read(appPreferencesProvider.notifier).update(prefs.copyWith(language: lang)),
                child: Padding(
                  // OBSERVED: 81 dp cards, tile 27 dp from the left edge
                  padding: const EdgeInsets.fromLTRB(26, 25.5, 26, 25.5),
                  child: Row(children: [
                    const IconTile(Icons.language),
                    const SizedBox(width: 15),
                    Expanded(child: Text(languageLabel(l, lang), style: TextStyle(fontSize: 14.5, color: c.label))),
                    if (lang == prefs.language) Icon(Icons.check_circle, color: AppColors.of(context).accent, size: 22),
                  ]),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// A card with an accent icon and a title, as on 主题设置 (外观与主题定制).
class _TitledCard extends StatelessWidget {
  const _TitledCard({required this.icon, required this.title, required this.children});
  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 18),
      decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Padding(
              padding: const EdgeInsets.only(left: 2),
              child: Icon(icon, size: 21, color: AppColors.of(context).accent)),
          const SizedBox(width: 9),
          Expanded(child: Text(title, style: TextStyle(fontSize: 16, color: c.label))),
        ]),
        ...children,
      ]),
    );
  }
}

/// [large]: OBSERVED 字体大小 is bigger and brighter than the other labels on the card.
Widget _fieldLabel(BuildContext context, String text, {Widget? trailing, bool large = false, double top = 16}) =>
    Padding(
      padding: EdgeInsets.fromLTRB(1, top, 1, 7),
      child: Row(children: [
        Expanded(
          child: Text(text,
              style: TextStyle(
                  fontSize: large ? 15 : 13,
                  color: large ? AppColors.of(context).label : AppColors.of(context).subtitle)),
        ),
        if (trailing != null) trailing,
      ]),
    );

/// `/settings/theme`. OBSERVED card 外观与主题定制: 主题模式 (自适应 / 亮色 / 暗色), 暗色背景风格 (深灰底 / 纯黑底; only
/// shown while the page is dark), 主题色彩 (six swatches) and 字体大小 (80–150 %); a second card 字体 imports font
/// files, which is not reproduced (README / ANALYSIS).
class ThemeSettingsScreen extends ConsumerStatefulWidget {
  const ThemeSettingsScreen({super.key});
  @override
  ConsumerState<ThemeSettingsScreen> createState() => _ThemeSettingsScreenState();
}

class _ThemeSettingsScreenState extends ConsumerState<ThemeSettingsScreen> {
  /// The slider position while dragging. The scale is applied when the finger lifts, because applying it on every
  /// step re-lays out the page under the finger.
  double? _dragScale;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = AppColors.of(context);
    final prefs = ref.watch(appPreferencesProvider);
    final notifier = ref.read(appPreferencesProvider.notifier);
    final scale = _dragScale ?? prefs.textScale;
    return Scaffold(
      appBar: AppBar(title: Text(l.settingsTheme)),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
        _TitledCard(icon: Icons.palette_outlined, title: l.themeCustomize, children: [
          _fieldLabel(context, l.themeModeLabel),
          AppSegmented<ThemeMode>(
            onCard: true,
            height: 32,
            strong: true,
            segments: {
              ThemeMode.system: (null, l.themeAuto),
              ThemeMode.light: (null, l.themeLight),
              ThemeMode.dark: (null, l.themeDark),
            },
            value: prefs.themeMode,
            onChanged: (v) => notifier.update(prefs.copyWith(themeMode: v)),
          ),
          // OBSERVED: gone with 亮色 chosen. INFERRED: the same for 自适应 on a light system (the page's brightness).
          if (Theme.of(context).brightness == Brightness.dark) ...[
            _fieldLabel(context, l.themeDarkStyle),
            AppSegmented<DarkStyle>(
              onCard: true,
              height: 32,
              strong: true,
              segments: {DarkStyle.gray: (null, l.themeDarkGray), DarkStyle.black: (null, l.themeDarkBlack)},
              value: prefs.darkStyle,
              onChanged: (v) => notifier.update(prefs.copyWith(darkStyle: v)),
            ),
          ],
          _fieldLabel(context, l.themeColor),
          _AccentSwatches(value: prefs.accent, onChanged: (v) => notifier.update(prefs.copyWith(accent: v))),
          _fieldLabel(
            context,
            l.themeFontSize,
            top: 11, // OBSERVED: closer to the swatches than the other labels are to their controls
            large: true,
            trailing: Text('${(scale * 100).round()}%', style: TextStyle(fontSize: 11.5, color: c.secondaryLabel)),
          ),
          Slider(
            value: scale,
            min: AppPreferences.minTextScale,
            max: AppPreferences.maxTextScale,
            divisions: 14,
            onChanged: (v) => setState(() => _dragScale = v),
            onChangeEnd: (v) {
              setState(() => _dragScale = null);
              notifier.update(prefs.copyWith(textScale: (v * 20).round() / 20));
            },
          ),
        ]),
        const SizedBox(height: 16),
        const _FontCard(),
      ]),
    );
  }
}

/// 主题设置 → 字体 (see `font_library.dart` for what was OBSERVED): 默认 and the imported fonts as radio rows, each
/// imported one drawn in its own font with a × that asks before deleting; 导入字体 below.
class _FontCard extends ConsumerWidget {
  const _FontCard();

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final l = context.l10n;
    final picked = await ref.read(fontPickerProvider)();
    if (picked == null || !context.mounted) return;
    final result = await ref.read(fontSettingsProvider.notifier).importFont(picked.name, picked.bytes);
    if (!context.mounted) return;
    switch (result) {
      case FontImportResult.imported:
        showSuccessHud(context, l.fontImported);
      case FontImportResult.exists:
        showWarningHud(context, l.fontExists);
      case FontImportResult.failed:
        showWarningHud(context, l.fontImportFailed);
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, UserFont font) async {
    final l = context.l10n;
    if (!await confirmAction(context,
        title: l.fontDelete,
        message: l.fontDeleteConfirm,
        confirmLabel: l.delete,
        destructive: true,
        smallTitle: true)) {
      return;
    }
    await ref.read(fontSettingsProvider.notifier).delete(font);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final c = AppColors.of(context);
    final fonts = ref.watch(fontSettingsProvider);
    final notifier = ref.read(fontSettingsProvider.notifier);
    return _TitledCard(icon: Icons.text_fields, title: l.fontCardTitle, children: [
      const SizedBox(height: 6),
      _FontRow(label: l.fontDefault, selected: fonts.selected == null, onTap: () => notifier.select(null)),
      for (final f in fonts.fonts)
        _FontRow(
          key: ValueKey('font-${f.id}'),
          label: f.name,
          family: f.family,
          selected: fonts.selectedId == f.id,
          onTap: () => notifier.select(f.id),
          onDelete: () => _delete(context, ref, f),
        ),
      const SizedBox(height: 10),
      Center(
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: c.accent,
            side: BorderSide(color: Theme.of(context).colorScheme.outline),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            minimumSize: const Size(0, 40),
            padding: const EdgeInsets.symmetric(horizontal: 26),
          ),
          onPressed: () => _import(context, ref),
          icon: const Icon(Icons.add, size: 20),
          label: Text(l.fontImport, style: const TextStyle(fontSize: 14.5)),
        ),
      ),
    ]);
  }
}

class _FontRow extends StatelessWidget {
  const _FontRow(
      {super.key, required this.label, required this.selected, required this.onTap, this.family, this.onDelete});
  final String label;
  final String? family;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        height: 47, // OBSERVED row pitch
        child: Row(children: [
          const SizedBox(width: 6),
          Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 21, color: selected ? c.accent : c.subtitle),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 16, color: c.label, fontFamily: family)),
          ),
          if (onDelete != null)
            IconButton(
              tooltip: context.l10n.fontDelete,
              icon: Icon(Icons.close, size: 20, color: c.subtitle),
              onPressed: onDelete,
            ),
        ]),
      ),
    );
  }
}

/// 主题色彩. OBSERVED: 40 dp circles in the swatch colour; the chosen one has a white ring (black on the light theme),
/// a white check and a glow in its colour. The choice applies at once.
class _AccentSwatches extends StatelessWidget {
  const _AccentSwatches({required this.value, required this.onChanged});
  final ThemeAccent value;
  final ValueChanged<ThemeAccent> onChanged;

  @override
  Widget build(BuildContext context) {
    final ring = Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black87;
    return Wrap(spacing: 14, runSpacing: 10, children: [
      for (final a in ThemeAccent.values)
        Semantics(
          button: true,
          selected: a == value,
          child: GestureDetector(
            key: ValueKey('accent-${a.name}'),
            onTap: () {
              AppHaptics.selection();
              onChanged(a);
            },
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: a.color,
                shape: BoxShape.circle,
                border: a == value ? Border.all(color: ring, width: 2.5) : null,
                boxShadow: a == value ? [BoxShadow(color: a.color.withValues(alpha: 0.45), blurRadius: 8)] : null,
              ),
              child: a == value ? const Icon(Icons.check, color: Colors.white, size: 20) : null,
            ),
          ),
        ),
    ]);
  }
}

/// `/settings/features`. OBSERVED rows: 触感反馈, 日志记录, catpaw 服务超时 (15s). 日志记录 is left out: this project
/// writes no log files.
class FeatureSettingsScreen extends ConsumerStatefulWidget {
  const FeatureSettingsScreen({super.key});
  @override
  ConsumerState<FeatureSettingsScreen> createState() => _FeatureSettingsScreenState();
}

class _FeatureSettingsScreenState extends ConsumerState<FeatureSettingsScreen> {
  PlaybackConfig? _p;
  DanmakuConfig? _d;

  @override
  void initState() {
    super.initState();
    ref.read(playerConfigRepositoryProvider).load().then((v) {
      if (!mounted) return;
      setState(() {
        _p = v.$1;
        _d = v.$2;
      });
    });
  }

  /// 触感反馈 is the player's `hapticEnabled` (player_config.json); the native player vibrates on its gestures.
  Future<void> _setHaptics(bool v) async {
    final (p, d) = await ref.read(playerConfigRepositoryProvider).load();
    p.hapticEnabled = v;
    await ref.read(playerConfigRepositoryProvider).save(p, d);
    if (v) AppHaptics.medium(force: true);
    if (!mounted) return;
    setState(() {
      _p = p;
      _d = d;
    });
  }

  Future<void> _setLogging(bool on) async {
    AppHaptics.light();
    final notifier = ref.read(appPreferencesProvider.notifier);
    await notifier.update(ref.read(appPreferencesProvider).copyWith(loggingEnabled: on));
  }

  /// OBSERVED dialog 清空日志 / 确定清空所有日志记录吗？ (取消 / 清空); the message afterwards is INFERRED from its strings.
  Future<void> _clearLog() async {
    final l = context.l10n;
    final ok = await confirmAction(context,
        title: l.logClear,
        message: l.logClearConfirm,
        confirmLabel: l.logClearAction,
        smallTitle: true,
        neutralButtons: true);
    if (!ok) return;
    showToast(await ref.read(appLogProvider).clear() ? l.logCleared : l.logClearFailed);
  }

  /// OBSERVED: the system save dialog with the file name filled in, and no message afterwards.
  Future<void> _exportLog() async {
    final l = context.l10n;
    final bytes = await ref.read(appLogProvider).read();
    if (bytes == null) {
      showToast(l.logNoFile);
      return;
    }
    try {
      await ref.read(logSaverProvider)(logExportName, bytes);
    } catch (e) {
      showToast('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = AppColors.of(context);
    final prefs = ref.watch(appPreferencesProvider);
    final p = _p;
    return Scaffold(
      appBar: AppBar(title: Text(l.settingsFeatures)),
      body: ListView(children: [
        SettingsSection(children: [
          SettingsTile(
            icon: Icons.vibration,
            title: l.playerHaptics,
            onTap: p == null || _d == null ? null : () => _setHaptics(!p.hapticEnabled),
            trailing: Switch(value: p?.hapticEnabled ?? true, onChanged: p == null || _d == null ? null : _setHaptics),
          ),
          // OBSERVED: no separator under 日志记录; one between its two rows, starting at their text.
          Column(children: [
            SettingsTile(
              icon: Icons.article_outlined,
              title: l.featureLogging,
              onTap: () => _setLogging(!prefs.loggingEnabled),
              trailing: Switch(value: prefs.loggingEnabled, onChanged: _setLogging),
            ),
            if (prefs.loggingEnabled) ...[
              SettingsTile(indent: 20, icon: Icons.cleaning_services_outlined, title: l.logClear, onTap: _clearLog),
              Divider(height: 0.6, indent: 78, color: c.separator),
              SettingsTile(indent: 20, icon: Icons.ios_share, title: l.logExport, onTap: _exportLog),
            ],
          ]),
          SettingsTile(
            icon: Icons.hourglass_bottom,
            title: l.catpawTimeout,
            subtitle: l.catpawTimeoutSub,
            trailing: Text('${prefs.catpawTimeoutSeconds}s', style: TextStyle(fontSize: 14.5, color: c.label)),
            onTap: () => showModalBottomSheet<void>(
              context: context,
              showDragHandle: true,
              backgroundColor: c.page,
              builder: (_) => const _CatpawTimeoutSheet(),
            ),
          ),
        ]),
      ]),
    );
  }
}

/// OBSERVED sheet: hourglass + 「catpaw 服务超时」, the description, then 接收超时（秒） with a 5–80 s slider.
class _CatpawTimeoutSheet extends ConsumerStatefulWidget {
  const _CatpawTimeoutSheet();
  @override
  ConsumerState<_CatpawTimeoutSheet> createState() => _CatpawTimeoutSheetState();
}

class _CatpawTimeoutSheetState extends ConsumerState<_CatpawTimeoutSheet> {
  int? _drag;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = AppColors.of(context);
    final prefs = ref.watch(appPreferencesProvider);
    final value = _drag ?? prefs.catpawTimeoutSeconds;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 4, 20, 24 + MediaQuery.paddingOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.hourglass_bottom, size: 22, color: AppColors.of(context).accent),
          const SizedBox(width: 8),
          Expanded(
              child:
                  Text(l.catpawTimeout, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: c.label))),
        ]),
        const SizedBox(height: 8),
        Text(l.catpawTimeoutSub, style: TextStyle(fontSize: 12, color: c.subtitle)),
        const SizedBox(height: 22),
        Row(children: [
          Expanded(child: Text(l.catpawTimeoutField, style: TextStyle(fontSize: 14, color: c.label))),
          Text('$value s', style: TextStyle(fontSize: 11.5, color: c.secondaryLabel)),
        ]),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(overlayShape: SliderComponentShape.noOverlay),
          child: Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Slider(
              value: value.toDouble(),
              min: AppPreferences.minCatpawTimeout.toDouble(),
              max: AppPreferences.maxCatpawTimeout.toDouble(),
              onChanged: (v) => setState(() => _drag = v.round()),
              onChangeEnd: (v) {
                setState(() => _drag = null);
                ref.read(appPreferencesProvider.notifier).update(prefs.copyWith(catpawTimeoutSeconds: v.round()));
              },
            ),
          ),
        ),
      ]),
    );
  }
}

/// 设置 → 数据清理: a sheet over the settings list (OBSERVED: 全选, group 缓存 with one card per item, 清理选中项).
Future<void> showCleanupSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true, // above the floating tab bar, as in the original
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.of(context).page,
      builder: (_) => const _CleanupSheet(),
    );

class _CleanupSheet extends ConsumerStatefulWidget {
  const _CleanupSheet();
  @override
  ConsumerState<_CleanupSheet> createState() => _CleanupSheetState();
}

class _CleanupSheetState extends ConsumerState<_CleanupSheet> {
  final _chosen = <CleanupItem>{};
  bool _busy = false;

  String _label(AppLocalizations l, CleanupItem item) => switch (item) {
        CleanupItem.images => l.cleanupImages,
        CleanupItem.temp => l.cleanupTemp,
        CleanupItem.livePlaylists => l.cleanupLivePlaylists,
      };

  Future<void> _run() async {
    final l = context.l10n;
    setState(() => _busy = true);
    try {
      final n = await ref.read(cleanupServiceProvider).clear(_chosen);
      showToast(l.cleanupDone(n));
      if (mounted) Navigator.pop(context);
    } catch (e) {
      showToast(l.cleanupFailed('$e'));
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = AppColors.of(context);
    final all = _chosen.length == CleanupItem.values.length;
    Widget row(String text, bool value, ValueChanged<bool> onChanged, {bool card = true}) => Padding(
          padding: EdgeInsets.only(bottom: card ? 8 : 0),
          child: Material(
            color: card ? c.card : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => onChanged(!value),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
                child: Row(children: [
                  Icon(value ? Icons.check_box : Icons.check_box_outline_blank,
                      color: value ? AppColors.of(context).accent : c.subtitle, size: 22),
                  const SizedBox(width: 14),
                  Expanded(child: Text(text, style: TextStyle(fontSize: 14.5, color: c.label))),
                ]),
              ),
            ),
          ),
        );
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 12 + MediaQuery.paddingOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l.settingsCleanup, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: c.label)),
        const SizedBox(height: 6),
        Text(l.cleanupDescription, style: TextStyle(fontSize: 12, height: 1.4, color: c.subtitle)),
        const SizedBox(height: 4),
        row(l.selectAll, all, (v) => setState(() => v ? _chosen.addAll(CleanupItem.values) : _chosen.clear()),
            card: false),
        Divider(color: c.separator),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 2, 8),
          child: Text(l.cleanupGroupCache,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.of(context).accent)),
        ),
        for (final item in CleanupItem.values)
          row(_label(l, item), _chosen.contains(item),
              (v) => setState(() => v ? _chosen.add(item) : _chosen.remove(item))),
        const SizedBox(height: 30),
        PrimaryButton(label: l.cleanupRun, expand: true, height: 44, onPressed: _busy || _chosen.isEmpty ? null : _run),
      ]),
    );
  }
}

/// `/settings/home-tabs` (设置 → 主页页面). OBSERVED: 已启用 with 「长按拖拽调整顺序」 on the right, one card per tab
/// (drag-handle tile, icon, name, switch); 首页 and 设置 carry 「必需页面，不可关闭」 and a disabled switch;
/// 未启用 lists the rest in catalog order without a handle and disappears when empty. Turning a tab on appends it to
/// the end; all ten may be on at once. Changes apply to the bar right away.
class HomeTabsScreen extends ConsumerWidget {
  const HomeTabsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final c = AppColors.of(context);
    final prefs = ref.watch(appPreferencesProvider);
    final enabled = prefs.homeTabs;
    final disabled = [
      for (final t in HomeTab.values)
        if (!enabled.contains(t)) t
    ];
    void save(List<HomeTab> next) => ref.read(appPreferencesProvider.notifier).update(prefs.copyWith(homeTabs: next));

    Widget header(String text, {Widget? trailing}) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 20, 0, 9),
          child: Row(children: [
            Expanded(
                child: Text(text, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.subtitle))),
            if (trailing != null) trailing,
          ]),
        );

    return Scaffold(
      appBar: AppBar(title: Text(l.settingsHomeTabs)),
      body: ListView(padding: EdgeInsets.fromLTRB(16, 6, 16, 24 + MediaQuery.paddingOf(context).bottom), children: [
        header(l.homeTabsEnabled,
            trailing: Text(l.homeTabsHint, style: TextStyle(fontSize: 12.5, color: c.secondaryLabel))),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          // `to` is already the index after removing the moved item
          onReorderItem: (from, to) {
            final next = [...enabled];
            next.insert(to, next.removeAt(from));
            save(next);
          },
          children: [
            for (final t in enabled)
              _HomeTabCard(
                key: ValueKey(t),
                tab: t,
                on: true,
                onChanged: t.required ? null : (_) => save([...enabled]..remove(t)),
              ),
          ],
        ),
        if (disabled.isNotEmpty) ...[
          header(l.homeTabsDisabled),
          for (final t in disabled)
            _HomeTabCard(key: ValueKey(t), tab: t, on: false, onChanged: (_) => save([...enabled, t])),
        ],
      ]),
    );
  }
}

class _HomeTabCard extends StatelessWidget {
  const _HomeTabCard({super.key, required this.tab, required this.on, required this.onChanged});
  final HomeTab tab;
  final bool on;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: c.card,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          // OBSERVED: 60 dp cards 12 dp apart; enabled ones start with a 35 dp handle tile, the others with the icon
          height: 60,
          child: Padding(
            padding: EdgeInsets.only(left: on ? 12 : 31, right: 10),
            child: Row(children: [
              if (on) ...[
                Container(
                  width: 35,
                  height: 35,
                  decoration: BoxDecoration(
                    color: Color.alphaBlend(c.label.withValues(alpha: 0.02), c.card),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.drag_indicator, size: 20, color: c.label.withValues(alpha: 0.75)),
                ),
                const SizedBox(width: 12),
              ],
              Icon(homeTabIcons(tab).$1, size: 21, color: c.label),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(homeTabLabel(l, tab), style: TextStyle(fontSize: 14.5, color: c.label)),
                      if (tab.required) ...[
                        const SizedBox(height: 2),
                        Text(l.homeTabsRequired, style: TextStyle(fontSize: 12, color: c.subtitle)),
                      ],
                    ]),
              ),
              Switch(value: on, onChanged: onChanged),
            ]),
          ),
        ),
      ),
    );
  }
}
