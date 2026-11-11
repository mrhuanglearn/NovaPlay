import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/app/app_preferences.dart';
import 'package:uzv_reimpl/app/providers.dart';
import 'package:uzv_reimpl/app/theme.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/features/catpaw/spider_api.dart';
import 'package:uzv_reimpl/features/cleanup/cleanup_service.dart';
import 'package:uzv_reimpl/features/live/live_store.dart';
import 'package:uzv_reimpl/features/subscription/subscription.dart';

void main() {
  group('AppPreferences', () {
    test('defaults: follow the system, dark grey, 100 %, 15 s', () {
      final p = AppPreferences.fromJson(const {});
      expect(p.language, AppLanguage.system);
      expect(p.locale, isNull);
      expect(p.themeMode, ThemeMode.system);
      expect(p.darkStyle, DarkStyle.gray);
      expect(p.textScale, 1.0);
      expect(p.catpawTimeout, const Duration(seconds: 15));
    });

    test('round trip and locale mapping', () {
      const p = AppPreferences(language: AppLanguage.en, themeMode: ThemeMode.dark, darkStyle: DarkStyle.black, textScale: 1.25, catpawTimeoutSeconds: 40);
      final back = AppPreferences.fromJson(p.toJson());
      expect(back, p);
      expect(back.locale, const Locale('en'));
      expect(const AppPreferences(language: AppLanguage.zh).locale, const Locale('zh'));
    });

    test('unknown or out-of-range values fall back or are clamped', () {
      final p = AppPreferences.fromJson(const {'language': 'ja', 'themeMode': 'sepia', 'darkStyle': 1, 'textScale': 3, 'catpawTimeout': 2});
      expect(p.language, AppLanguage.system);
      expect(p.themeMode, ThemeMode.system);
      expect(p.darkStyle, DarkStyle.gray);
      expect(p.textScale, AppPreferences.maxTextScale);
      expect(p.catpawTimeoutSeconds, AppPreferences.minCatpawTimeout);
    });
  });

  group('AppPreferencesNotifier', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('uzv_prefs'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('saving merges into settings.json and survives a restart', () async {
      final store = JsonStore('settings.json', baseDir: dir);
      await store.write({'activeSubscription': 'mock', 'homeLayout': 'grid'});
      final c = ProviderContainer(overrides: [settingsStoreProvider.overrideWithValue(store)]);
      addTearDown(c.dispose);
      final next = c.read(appPreferencesProvider).copyWith(language: AppLanguage.en, darkStyle: DarkStyle.black, catpawTimeoutSeconds: 30);
      await c.read(appPreferencesProvider.notifier).update(next);
      expect(c.read(appPreferencesProvider), next);

      final saved = await store.read<Map<String, dynamic>>(const {});
      expect(saved['activeSubscription'], 'mock');
      expect(saved['homeLayout'], 'grid');
      expect(AppPreferences.fromJson(saved), next);
    });

    test('a new catpaw timeout reaches the running runtime without rebuilding it', () async {
      final api = SpiderApi(1);
      var builds = 0;
      final c = ProviderContainer(overrides: [
        settingsStoreProvider.overrideWithValue(JsonStore('settings.json', baseDir: dir)),
        catpawRuntimeProvider.overrideWith((ref) async {
          builds++;
          return SpiderRuntime(subscription: const Subscription(key: 'k', name: 'n'), api: api, sites: const []);
        }),
      ]);
      addTearDown(c.dispose);
      final sub = c.listen(catpawRuntimeProvider, (previous, next) {});
      addTearDown(sub.close);
      await c.read(catpawRuntimeProvider.future);
      await c.read(appPreferencesProvider.notifier).update(c.read(appPreferencesProvider).copyWith(catpawTimeoutSeconds: 42));
      expect(api.receiveTimeout, const Duration(seconds: 42));
      expect(builds, 1);
    });

    test('the launch value seeds the notifier', () {
      const launched = AppPreferences(themeMode: ThemeMode.light);
      final c = ProviderContainer(overrides: [initialAppPreferencesProvider.overrideWithValue(launched)]);
      addTearDown(c.dispose);
      expect(c.read(appPreferencesProvider), launched);
    });
  });

  test('SpiderApi takes the catpaw timeout and accepts a new one', () {
    final api = SpiderApi(1, receiveTimeout: const Duration(seconds: 7));
    expect(api.receiveTimeout, const Duration(seconds: 7));
    api.receiveTimeout = const Duration(seconds: 60);
    expect(api.receiveTimeout, const Duration(seconds: 60));
    expect(SpiderApi(1).receiveTimeout, const Duration(seconds: 15));
  });

  test('the dark theme carries the chosen palette', () {
    expect(buildAppTheme(Brightness.dark).extension<AppColors>(), same(AppColors.dark));
    expect(buildAppTheme(Brightness.dark, pureBlack: true).extension<AppColors>(), same(AppColors.black));
    expect(buildAppTheme(Brightness.light, pureBlack: true).extension<AppColors>(), same(AppColors.light));
    expect(buildAppTheme(Brightness.dark, pureBlack: true).scaffoldBackgroundColor, const Color(0xFF000000));
  });

  group('CleanupService', () {
    late Directory temp;
    late Directory liveDir;
    late LivePlaylistLoader live;
    var fetches = 0;
    var imagesCleared = 0;
    const source = LiveSource(id: 'a', name: 'A', url: 'http://s/a.m3u', refresh: LiveRefresh.off);

    setUp(() {
      temp = Directory.systemTemp.createTempSync('uzv_tmp');
      liveDir = Directory('${temp.path}/live_cache');
      fetches = 0;
      imagesCleared = 0;
      live = LivePlaylistLoader(cacheDir: liveDir, fetch: (s) async => '#EXTM3U\n#EXTINF:-1,v${++fetches}\nhttp://s/1');
    });
    tearDown(() => temp.deleteSync(recursive: true));

    CleanupService service() => CleanupService(livePlaylists: live, tempDir: () async => temp, clearImages: () => imagesCleared++);

    test('临时文件 removes only the plugin copies', () async {
      File('${temp.path}/file_picker/1/backup.zip').createSync(recursive: true);
      File('${temp.path}/share_plus/uzv_backup.zip').createSync(recursive: true);
      File('${temp.path}/WebView/Default/cookie').createSync(recursive: true);
      expect(await service().clear({CleanupItem.temp}), 1);
      expect(Directory('${temp.path}/file_picker').existsSync(), isFalse);
      expect(Directory('${temp.path}/share_plus').existsSync(), isFalse);
      expect(File('${temp.path}/WebView/Default/cookie').existsSync(), isTrue);
      expect(imagesCleared, 0);
    });

    test('直播列表缓存 is downloaded again afterwards, even with auto-refresh off', () async {
      expect(await live.load(source), contains('v1'));
      expect(await live.load(source), contains('v1')); // cached, refresh off
      expect(await service().clear({CleanupItem.livePlaylists, CleanupItem.images}), 2);
      expect(liveDir.existsSync(), isFalse);
      expect(imagesCleared, 1);
      expect(await live.load(source), contains('v2'));
    });

    test('nothing chosen clears nothing; missing folders are fine', () async {
      expect(await service().clear({}), 0);
      expect(await service().clear(CleanupItem.values.toSet()), 3);
    });
  });
}
