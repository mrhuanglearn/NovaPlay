import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app_preferences.dart';
import 'app/providers.dart';
import 'app/router.dart';
import 'app/theme.dart';
import 'app/ui_hooks.dart';
import 'core/app_log.dart';
import 'core/json_store.dart';
import 'features/fonts/font_library.dart';
import 'features/player/player_launcher.dart';
import 'l10n/l10n.dart';
import 'services/webdav_sync.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Language, theme and font size are read before the first frame, so a cold start never flashes the system ones.
  final prefs =
      AppPreferences.fromJson(await JsonStore('settings.json').read<Map<String, dynamic>>(<String, dynamic>{}));
  // 功能设置 → 日志记录: uncaught errors go to log.txt while it is on (installed here only: tests own the handlers).
  unawaited(appLog.setEnabled(prefs.loggingEnabled));
  installErrorLog(appLog);
  // 功能设置 → 触感反馈: preload `hapticEnabled` from `player_config.json` before the first frame.
  unawaited(PlayerConfigRepository().load());
  // 主题设置 → 字体: imported fonts are registered before the first frame too (the original preloads them at start).
  final fontFiles = FontFiles();
  final fontsStore = JsonStore('fonts.json');
  final savedFonts = FontSettings.fromJson(await fontsStore.read<Object?>(null));
  final fonts = await restoreFonts(savedFonts, fontFiles);
  if (!identical(fonts, savedFonts)) {
    try {
      await fontsStore.write(fonts.toJson());
    } catch (_) {
      // The trimmed list is written again on the next change; starting matters more.
    }
  }
  final container = ProviderContainer(overrides: [
    initialAppPreferencesProvider.overrideWithValue(prefs),
    fontFilesProvider.overrideWithValue(fontFiles),
    initialFontSettingsProvider.overrideWithValue(fonts),
  ]);
  runApp(UncontrolledProviderScope(container: container, child: const UzvApp()));
  unawaited(_startupWebDavSync(container));
}

/// 启用同步 (WebDAV settings): sync the chosen data once per app start. Failures are shown, never thrown.
Future<void> _startupWebDavSync(ProviderContainer container) async {
  final store = container.read(webDavConfigStoreProvider);
  try {
    final cfg = WebDavConfig.fromJson(await store.read<Map<String, dynamic>>(<String, dynamic>{}));
    if (!cfg.enabled || !cfg.isConfigured || cfg.documents.isEmpty) return;
    final report = await container.read(webDavSyncProvider)(cfg).sync(documents: cfg.documents);
    if (report.pulled.isNotEmpty) {
      refreshProvidersAfterWebDavPull(container, report.pulled);
    }
    await store.update<Map<String, dynamic>>(
      <String, dynamic>{},
      (cur) => WebDavConfig.fromJson(cur).copyWith(lastSyncMs: DateTime.now().millisecondsSinceEpoch).toJson(),
    );
  } catch (e) {
    final ctx = rootNavigatorKey.currentContext;
    if (ctx != null && ctx.mounted) showToast(ctx.l10n.webdavSyncFailed(e is WebDavException ? e.message : '$e'));
  }
}

class UzvApp extends ConsumerStatefulWidget {
  const UzvApp({super.key});

  @override
  ConsumerState<UzvApp> createState() => _UzvAppState();
}

class _UzvAppState extends ConsumerState<UzvApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(catpawSupervisorProvider).onAppResumed());
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(appPreferencesProvider);
    final fontFamily = ref.watch(fontSettingsProvider).fontFamily;
    return MaterialApp.router(
      onGenerateTitle: (c) => c.l10n.appName,
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: rootMessengerKey,
      routerConfig: ref.watch(routerProvider),
      // 设置 → 语言: null follows the system (跟随系统); this project has Chinese and English.
      locale: prefs.locale,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildAppTheme(Brightness.light, accent: prefs.accent.color, fontFamily: fontFamily),
      darkTheme: buildAppTheme(Brightness.dark,
          pureBlack: prefs.darkStyle == DarkStyle.black, accent: prefs.accent.color, fontFamily: fontFamily),
      themeMode: prefs.themeMode,
      // 主题设置 → 字体大小 scales all text on top of the system font size, as the original does.
      builder: (context, child) {
        if (prefs.textScale == 1.0) return child!;
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(mq.textScaler.scale(1) * prefs.textScale)),
          child: child!,
        );
      },
    );
  }
}
