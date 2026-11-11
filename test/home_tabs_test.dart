import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/app/app_preferences.dart';
import 'package:uzv_reimpl/app/providers.dart';
import 'package:uzv_reimpl/app/theme.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/l10n/l10n.dart';
import 'package:uzv_reimpl/ui/app_shell.dart';
import 'package:uzv_reimpl/ui/preference_screens.dart';

void main() {
  group('home tabs in AppPreferences', () {
    test('default: the original five in the original order', () {
      expect(AppPreferences.fromJson(const {}).homeTabs, [HomeTab.home, HomeTab.live, HomeTab.calendar, HomeTab.library, HomeTab.settings]);
    });

    test('round trip keeps the order', () {
      const tabs = [HomeTab.search, HomeTab.home, HomeTab.favorites, HomeTab.settings];
      final p = const AppPreferences().copyWith(homeTabs: tabs);
      expect(AppPreferences.fromJson(p.toJson()).homeTabs, tabs);
      expect(p.toJson()['homeTabs'], ['search', 'home', 'favorites', 'settings']);
    });

    test('unknown ids and repeats are dropped; 首页 and 设置 are always kept', () {
      final p = AppPreferences.fromJson(const {
        'homeTabs': ['live', 'plex', 'live', 'search'],
      });
      expect(p.homeTabs, [HomeTab.home, HomeTab.live, HomeTab.search, HomeTab.settings]);
      expect(const AppPreferences().copyWith(homeTabs: [HomeTab.library]).homeTabs, [HomeTab.home, HomeTab.library, HomeTab.settings]);
      expect(AppPreferences.fromJson(const {'homeTabs': 'x'}).homeTabs, HomeTab.defaults);
    });

    test('every tab has its own shell path', () {
      final paths = HomeTab.values.map(homeTabPath).toSet();
      expect(paths.length, HomeTab.values.length);
      expect(homeTabPath(HomeTab.home), '/');
      expect(homeTabPath(HomeTab.settings), '/settings');
    });
  });

  group('主页页面 screen', () {
    Future<ProviderContainer> pump(WidgetTester tester) async {
      final container = ProviderContainer(overrides: [settingsStoreProvider.overrideWithValue(_MemoryStore())]);
      addTearDown(container.dispose);
      await tester.binding.setSurfaceSize(const Size(420, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildAppTheme(Brightness.dark),
          home: const HomeTabsScreen(),
        ),
      ));
      await tester.pumpAndSettle();
      return container;
    }

    Switch switchOf(WidgetTester tester, String label) => tester.widget<Switch>(
          find.descendant(of: find.ancestor(of: find.text(label), matching: find.byType(Material)).first, matching: find.byType(Switch)),
        );

    testWidgets('首页 and 设置 cannot be switched off; turning a tab on appends it, off removes it', (tester) async {
      final c = await pump(tester);
      expect(find.text('必需页面，不可关闭'), findsNWidgets(2));
      expect(switchOf(tester, '首页').onChanged, isNull);
      expect(switchOf(tester, '设置').onChanged, isNull);
      expect(find.text('未启用'), findsOneWidget);

      switchOf(tester, '搜索').onChanged!(true);
      await tester.pumpAndSettle();
      expect(c.read(appPreferencesProvider).homeTabs.last, HomeTab.search);

      switchOf(tester, '直播').onChanged!(false);
      await tester.pumpAndSettle();
      expect(c.read(appPreferencesProvider).homeTabs, [HomeTab.home, HomeTab.calendar, HomeTab.library, HomeTab.settings, HomeTab.search]);
    });

    testWidgets('the 未启用 group disappears when every tab is on', (tester) async {
      final c = await pump(tester);
      await c.read(appPreferencesProvider.notifier).update(const AppPreferences().copyWith(homeTabs: HomeTab.values));
      await tester.pumpAndSettle();
      expect(find.text('未启用'), findsNothing);
      expect(find.byType(Switch), findsNWidgets(HomeTab.values.length));
    });

    testWidgets('long-press and drag reorders the enabled tabs', (tester) async {
      final c = await pump(tester);
      final gesture = await tester.startGesture(tester.getCenter(find.text('直播')));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      // 140 dp in all with 72 dp rows: past 追剧日历 and 媒体库 (a slot is taken once half a row is crossed), not 设置
      for (var i = 0; i < 2; i++) {
        await gesture.moveBy(const Offset(0, 50));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(c.read(appPreferencesProvider).homeTabs, [HomeTab.home, HomeTab.calendar, HomeTab.library, HomeTab.live, HomeTab.settings]);
    });
  });
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
