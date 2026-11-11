import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Visual tokens. OBSERVED by sampling screenshots of the original on Waydroid (docs/ui-ref/original/): page #1C1C1E,
/// grouped cards #2C2C2E, separators ~#38383A, accent #007AFF, text #E2E2E9, row subtitles and section headers #C4C6D0,
/// hints and small meta text ~#9B9DA5, icon tiles = accent at ~15% over the card, centered page titles, a floating
/// pill bottom bar.
///
/// 主题色彩 (OBSERVED with the original switched to each of its six colours, 2026-11-09): page, cards, separators and
/// the bottom bar stay the same; the accent is the swatch colour itself; everything else that is tinted comes from
/// Material's `ColorScheme.fromSeed(seedColor: accent)`. Text = onSurface (#E2E2E9 blue, #E0E4DB green, #E9E0E7 purple,
/// #EFE0D5 orange, #F0DEDE pink, #EAE1D4 yellow, dark), subtitles = onSurfaceVariant, input fill =
/// surfaceContainerHighest (#33353A blue, #313630 green), text and icons on the accent = onPrimary (#102F60 blue,
/// #033912 green; white on the light theme). Light page #F2F2F7 and cards #FFFFFF are OBSERVED too (green, 亮色).
class AppColors extends ThemeExtension<AppColors> {
  const AppColors._({
    required this.page,
    required this.card,
    required this.cardHigh,
    required this.separator,
    required this.label,
    required this.secondaryLabel,
    required this.subtitle,
    required this.navBar,
    required this.navSelected,
    required this.accent,
    required this.onAccent,
  });

  /// The palette for [brightness] (and 纯黑底 when [pureBlack]) tinted by [accent]. Palettes are cached: ThemeData
  /// compares extensions by identity, and a new instance on every rebuild would re-run fromSeed and animate the theme.
  static AppColors palette({required Brightness brightness, bool pureBlack = false, Color accent = defaultAccent}) {
    final black = pureBlack && brightness == Brightness.dark;
    return _cache.putIfAbsent((brightness, black, accent.toARGB32()), () {
      final s = ColorScheme.fromSeed(seedColor: accent, brightness: brightness);
      final dark = brightness == Brightness.dark;
      return AppColors._(
        page: dark ? (black ? const Color(0xFF000000) : const Color(0xFF1C1C1E)) : const Color(0xFFF2F2F7),
        card: dark ? (black ? const Color(0xFF121212) : const Color(0xFF2C2C2E)) : const Color(0xFFFFFFFF),
        // 纯黑底's input fill is INFERRED (not sampled), so it keeps the neutral value used before.
        cardHigh: black ? const Color(0xFF242426) : s.surfaceContainerHighest,
        separator: dark ? (black ? const Color(0xFF1A1A1A) : const Color(0xFF38383A)) : const Color(0xFFDCDCE0),
        label: s.onSurface,
        // INFERRED fit: a quarter of the way from outline to onSurfaceVariant reproduces the sampled #9B9DA5 (blue,
        // dark). The light theme uses outline.
        secondaryLabel: dark ? Color.lerp(s.outline, s.onSurfaceVariant, 0.24)! : s.outline,
        subtitle: s.onSurfaceVariant,
        navBar: dark ? (black ? const Color(0xE00A0A0A) : const Color(0xE02C2C2E)) : const Color(0xE6FFFFFF),
        navSelected: dark ? (black ? const Color(0xFF343435) : const Color(0xFF48484A)) : const Color(0xFFE3E3E8),
        accent: accent,
        onAccent: s.onPrimary,
      );
    });
  }

  static final _cache = <(Brightness, bool, int), AppColors>{};

  final Color page;
  final Color card;
  final Color cardHigh; // inputs and segmented-control tracks inside a card
  final Color separator;
  final Color label;

  /// Hints, chevrons and small meta text.
  final Color secondaryLabel;

  /// Row subtitles, section headers and descriptions (brighter than [secondaryLabel]).
  final Color subtitle;
  final Color navBar;
  final Color navSelected;

  /// 主题色彩 (OBSERVED default #007AFF).
  final Color accent;

  /// Text and icons on accent fills (立即播放, 添加订阅, 已激活). OBSERVED: the seed scheme's onPrimary, a dark shade of
  /// the accent on the dark themes, white on the light one.
  final Color onAccent;

  static const defaultAccent = Color(0xFF007AFF);
  static const destructive = Color(0xFFFF453A);

  /// OBSERVED pink "安装不受信任的订阅" button and the edit-mode 删除 outline: Material's dark error pair.
  static const danger = Color(0xFFFFB4AB);
  static const onDanger = Color(0xFF690005);

  /// Text and icons of destructive rows and buttons (删除订阅, 重置应用, 删除 in confirm dialogs). OBSERVED #FFB4AB on the
  /// dark theme ([danger]); on the light theme Material's light error colour, which stays readable on white.
  static Color dangerText(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? danger : const Color(0xFFBA1A1A);

  /// The blue palettes (the default 主题色彩).
  static AppColors get dark => AppColors.palette(brightness: Brightness.dark);
  static AppColors get light => AppColors.palette(brightness: Brightness.light);

  /// 纯黑底 (主题设置 → 暗色背景风格). OBSERVED with the original switched to it: page #000000, cards #121212,
  /// separators ~#171717, selected nav pill ~#343435. The input fill is inferred.
  static AppColors get black => AppColors.palette(brightness: Brightness.dark, pureBlack: true);

  /// The palette the current theme was built with ([buildAppTheme] registers it as a theme extension).
  static AppColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<AppColors>() ?? (theme.brightness == Brightness.dark ? dark : light);
  }

  @override
  AppColors copyWith() => this;

  @override
  AppColors lerp(covariant ThemeExtension<AppColors>? other, double t) => other is AppColors && t >= 0.5 ? other : this;
}

/// [pureBlack] picks the 纯黑底 palette for the dark theme; [accent] is 主题色彩; [fontFamily] is the font chosen under
/// 主题设置 → 字体 (null = the platform font).
ThemeData buildAppTheme(Brightness brightness,
        {bool pureBlack = false, Color accent = AppColors.defaultAccent, String? fontFamily}) =>
    _themes.putIfAbsent((brightness, pureBlack, accent.toARGB32(), fontFamily),
        () => _buildTheme(brightness, pureBlack, accent, fontFamily));

final _themes = <(Brightness, bool, int, String?), ThemeData>{};

ThemeData _buildTheme(Brightness brightness, bool pureBlack, Color accent, String? fontFamily) {
  final c = AppColors.palette(brightness: brightness, pureBlack: pureBlack, accent: accent);
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness).copyWith(
    primary: accent,
    onPrimary: c.onAccent,
    surface: c.page,
    onSurface: c.label,
    onSurfaceVariant: c.subtitle,
    surfaceContainerLowest: c.page,
    surfaceContainerLow: c.card,
    surfaceContainer: c.card,
    surfaceContainerHigh: c.card,
    surfaceContainerHighest: c.cardHigh,
    outline: c.secondaryLabel,
    outlineVariant: c.separator,
    error: AppColors.destructive,
  );
  final rounded = RoundedRectangleBorder(borderRadius: BorderRadius.circular(10));
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: fontFamily,
    extensions: [c],
    colorScheme: scheme,
    scaffoldBackgroundColor: c.page,
    canvasColor: c.page,
    dividerColor: c.separator,
    dividerTheme: DividerThemeData(color: c.separator, thickness: 0.6, space: 0.6),
    appBarTheme: AppBarTheme(
      backgroundColor: c.page,
      surfaceTintColor: Colors.transparent,
      foregroundColor: c.label,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      // OBSERVED on the phone (2026-11-10, 搜索 and 设置 next to the original at font scale 0.86): the original's titles
      // are 0.885 of the 18 used before, i.e. 16.
      titleTextStyle: TextStyle(color: c.label, fontSize: 16, fontWeight: FontWeight.w500),
      systemOverlayStyle: brightness == Brightness.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
    ),
    cardTheme: CardThemeData(
      color: c.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    listTileTheme:
        ListTileThemeData(iconColor: c.accent, subtitleTextStyle: TextStyle(color: c.secondaryLabel, fontSize: 13)),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
          backgroundColor: c.accent, foregroundColor: c.onAccent, shape: rounded, minimumSize: const Size(64, 44)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.accent,
        side: BorderSide(color: c.secondaryLabel.withValues(alpha: 0.6)),
        shape: const StadiumBorder(),
        minimumSize: const Size(64, 42),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: c.accent)),
    floatingActionButtonTheme: FloatingActionButtonThemeData(backgroundColor: c.accent, foregroundColor: c.onAccent),
    // OBSERVED disabled-on switch (主页页面 必需页面): grey track ≈ label at 12 % over the card, thumb in the card colour.
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled)
          ? (s.contains(WidgetState.selected) ? c.card : c.secondaryLabel.withValues(alpha: 0.38))
          : s.contains(WidgetState.selected)
              ? c.onAccent
              : c.secondaryLabel),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled)
          ? (s.contains(WidgetState.selected)
              ? Color.alphaBlend(c.label.withValues(alpha: 0.12), c.card)
              : c.cardHigh.withValues(alpha: 0.38))
          : s.contains(WidgetState.selected)
              ? c.accent
              : c.cardHigh),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled)
          ? (s.contains(WidgetState.selected) ? Colors.transparent : c.secondaryLabel.withValues(alpha: 0.38))
          : s.contains(WidgetState.selected)
              ? c.accent
              : c.secondaryLabel),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.cardHigh,
      hintStyle: TextStyle(color: c.secondaryLabel),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
      focusedBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: c.accent)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: c.accent,
      unselectedLabelColor: c.label,
      indicatorColor: c.accent,
      dividerColor: Colors.transparent,
      tabAlignment: TabAlignment.start,
      labelPadding: const EdgeInsets.symmetric(horizontal: 12),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: c.card,
      selectedColor: c.accent.withValues(alpha: 0.18),
      side: BorderSide.none,
      shape: const StadiumBorder(),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.cardHigh,
      contentTextStyle: TextStyle(color: c.label),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    dialogTheme: DialogThemeData(backgroundColor: c.card, surfaceTintColor: Colors.transparent),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: c.card, surfaceTintColor: Colors.transparent),
    popupMenuTheme: PopupMenuThemeData(color: c.card, surfaceTintColor: Colors.transparent),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.accent),
  );
}
