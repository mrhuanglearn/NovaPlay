import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_log.dart';
import 'providers.dart';

/// 设置 → 语言. OBSERVED options: 跟随系统 / 简体中文 / 繁體中文 / 日本語 / English. This project ships only the
/// Chinese and English translations, so the other two are left out.
enum AppLanguage { system, zh, en }

/// 主题设置 → 暗色背景风格 (OBSERVED 深灰底 / 纯黑底).
enum DarkStyle { gray, black }

/// 主题设置 → 主题色彩. OBSERVED swatches, in this order (pixels of the original's swatches; the iOS system colours).
/// The original keeps the choice as `accentColorHex` (a field name in its `libapp.so`); this project stores the name.
enum ThemeAccent {
  blue(Color(0xFF007AFF)),
  green(Color(0xFF34C759)),
  purple(Color(0xFFAF52DE)),
  orange(Color(0xFFFF9500)),
  pink(Color(0xFFFF2D55)),
  yellow(Color(0xFFFFCC00));

  const ThemeAccent(this.color);
  final Color color;
}

/// 设置 → 主页页面: the pages the bottom bar can show. OBSERVED catalog order (the 未启用 list keeps it): 首页, 直播,
/// 追剧日历, 媒体库, 设置, 媒体服务器, 我的收藏, 播放历史, 下载, 搜索. The ids are this project's (the original's enum
/// values were not recovered). The router has one shell branch per value, in this order.
enum HomeTab {
  home,
  live,
  calendar,
  library,
  settings,
  mediaServer,
  favorites,
  history,
  downloads,
  search;

  /// OBSERVED 「必需页面，不可关闭」.
  bool get required => this == home || this == settings;

  /// OBSERVED default: the first five, in this order.
  static const defaults = [home, live, calendar, library, settings];
}

/// App-wide preferences from 语言, 主题设置 and 功能设置, kept in settings.json next to the other UI state.
class AppPreferences {
  const AppPreferences({
    this.language = AppLanguage.system,
    this.themeMode = ThemeMode.system,
    this.darkStyle = DarkStyle.gray,
    this.accent = ThemeAccent.blue,
    this.textScale = 1.0,
    this.catpawTimeoutSeconds = defaultCatpawTimeout,
    this.loggingEnabled = false,
    this.homeTabs = HomeTab.defaults,
    this.lockHash,
  });

  /// OBSERVED 字体大小 slider: 80 % to 150 % in 5 % steps, 100 % by default.
  static const minTextScale = 0.8;
  static const maxTextScale = 1.5;

  /// OBSERVED catpaw 服务超时 (功能设置): 接收超时（秒） slider from 5 to 80 s, 15 s by default.
  static const defaultCatpawTimeout = 15;
  static const minCatpawTimeout = 5;
  static const maxCatpawTimeout = 80;

  final AppLanguage language;
  final ThemeMode themeMode;
  final DarkStyle darkStyle;
  final ThemeAccent accent;
  final double textScale;
  final int catpawTimeoutSeconds;

  /// 功能设置 → 日志记录 (OBSERVED off by default): errors go to log.txt (see `core/app_log.dart`).
  final bool loggingEnabled;

  /// Enabled tabs of the bottom bar in their order. Always holds 首页 and 设置.
  final List<HomeTab> homeTabs;

  /// 锁密码 as [lockCodeHash]; null = 未设置, the hash of '' = 空密码 (see `app_lock.dart`).
  final String? lockHash;

  /// [lockHash] cannot be cleared through [copyWith].
  AppPreferences withLockHash(String? hash) => AppPreferences(
        language: language,
        themeMode: themeMode,
        darkStyle: darkStyle,
        accent: accent,
        textScale: textScale,
        catpawTimeoutSeconds: catpawTimeoutSeconds,
        loggingEnabled: loggingEnabled,
        homeTabs: homeTabs,
        lockHash: hash,
      );

  /// Unknown ids and repeats are dropped; a missing 首页 is put first and a missing 设置 last.
  static List<HomeTab> normalizeTabs(Iterable<HomeTab> tabs) {
    final out = <HomeTab>[];
    for (final t in tabs) {
      if (!out.contains(t)) out.add(t);
    }
    if (!out.contains(HomeTab.home)) out.insert(0, HomeTab.home);
    if (!out.contains(HomeTab.settings)) out.add(HomeTab.settings);
    return List.unmodifiable(out);
  }

  Locale? get locale => switch (language) {
        AppLanguage.system => null,
        AppLanguage.zh => const Locale('zh'),
        AppLanguage.en => const Locale('en'),
      };

  Duration get catpawTimeout => Duration(seconds: catpawTimeoutSeconds);

  static T _enum<T extends Enum>(List<T> values, Object? raw, T fallback) =>
      values.firstWhere((v) => v.name == raw, orElse: () => fallback);

  factory AppPreferences.fromJson(Map<String, dynamic> json) {
    final scale = json['textScale'];
    final timeout = json['catpawTimeout'];
    final tabs = json['homeTabs'];
    final lock = json['lockPassword'];
    return AppPreferences(
      language: _enum(AppLanguage.values, json['language'], AppLanguage.system),
      themeMode: _enum(ThemeMode.values, json['themeMode'], ThemeMode.system),
      darkStyle: _enum(DarkStyle.values, json['darkStyle'], DarkStyle.gray),
      accent: _enum(ThemeAccent.values, json['themeColor'], ThemeAccent.blue),
      textScale: scale is num ? scale.toDouble().clamp(minTextScale, maxTextScale) : 1.0,
      catpawTimeoutSeconds:
          timeout is num ? timeout.round().clamp(minCatpawTimeout, maxCatpawTimeout) : defaultCatpawTimeout,
      loggingEnabled: json['logging'] == true,
      homeTabs: tabs is List
          ? normalizeTabs([for (final t in tabs) ...HomeTab.values.where((v) => v.name == t)])
          : HomeTab.defaults,
      lockHash: lock is String && lock.isNotEmpty ? lock : null,
    );
  }

  /// Only this object's fields; settings.json holds other keys too, so callers merge (see [AppPreferencesNotifier]).
  Map<String, dynamic> toJson() => {
        'language': language.name,
        'themeMode': themeMode.name,
        'darkStyle': darkStyle.name,
        'themeColor': accent.name,
        'textScale': textScale,
        'catpawTimeout': catpawTimeoutSeconds,
        'logging': loggingEnabled,
        'homeTabs': [for (final t in homeTabs) t.name],
        'lockPassword': lockHash,
      };

  AppPreferences copyWith({
    AppLanguage? language,
    ThemeMode? themeMode,
    DarkStyle? darkStyle,
    ThemeAccent? accent,
    double? textScale,
    int? catpawTimeoutSeconds,
    bool? loggingEnabled,
    List<HomeTab>? homeTabs,
  }) =>
      AppPreferences(
        language: language ?? this.language,
        themeMode: themeMode ?? this.themeMode,
        darkStyle: darkStyle ?? this.darkStyle,
        accent: accent ?? this.accent,
        textScale: textScale ?? this.textScale,
        catpawTimeoutSeconds: catpawTimeoutSeconds ?? this.catpawTimeoutSeconds,
        loggingEnabled: loggingEnabled ?? this.loggingEnabled,
        homeTabs: homeTabs == null ? this.homeTabs : normalizeTabs(homeTabs),
        lockHash: lockHash,
      );

  @override
  bool operator ==(Object other) =>
      other is AppPreferences &&
      other.language == language &&
      other.themeMode == themeMode &&
      other.darkStyle == darkStyle &&
      other.accent == accent &&
      other.textScale == textScale &&
      other.catpawTimeoutSeconds == catpawTimeoutSeconds &&
      other.loggingEnabled == loggingEnabled &&
      listEquals(other.homeTabs, homeTabs) &&
      other.lockHash == lockHash;

  @override
  int get hashCode => Object.hash(language, themeMode, darkStyle, accent, textScale, catpawTimeoutSeconds, loggingEnabled,
      Object.hashAll(homeTabs), lockHash);
}

/// What settings.json held at launch. `main()` reads the file before `runApp` and overrides this, so the first frame
/// already has the chosen language and theme (an async load would show the system ones for a moment).
final initialAppPreferencesProvider = Provider<AppPreferences>((ref) => const AppPreferences());

class AppPreferencesNotifier extends Notifier<AppPreferences> {
  @override
  AppPreferences build() => ref.watch(initialAppPreferencesProvider);

  Future<void> update(AppPreferences next) async {
    if (next == state) return;
    final timeoutChanged = next.catpawTimeoutSeconds != state.catpawTimeoutSeconds;
    final loggingChanged = next.loggingEnabled != state.loggingEnabled;
    state = next;
    if (loggingChanged) await ref.read(appLogProvider).setEnabled(next.loggingEnabled);
    // The running catpaw runtime keeps its API client; give it the new limit instead of restarting the script.
    if (timeoutChanged && ref.exists(catpawRuntimeProvider)) {
      ref.read(catpawRuntimeProvider).valueOrNull?.api.receiveTimeout = next.catpawTimeout;
    }
    final store = ref.read(settingsStoreProvider);
    final settings = Map<String, dynamic>.of(await store.read<Map<String, dynamic>>(const {}));
    settings.addAll(next.toJson());
    await store.write(settings);
  }

  Future<void> setLockHash(String? hash) => update(state.withLockHash(hash));
}

final appPreferencesProvider = NotifierProvider<AppPreferencesNotifier, AppPreferences>(AppPreferencesNotifier.new);
