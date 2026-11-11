import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/app/app_preferences.dart';
import 'package:uzv_reimpl/app/providers.dart';
import 'package:uzv_reimpl/app/theme.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/l10n/l10n.dart';
import 'package:uzv_reimpl/ui/preference_screens.dart';
import 'package:uzv_reimpl/ui/settings_screens.dart';

AppColors palette(Brightness b, ThemeAccent a, {bool black = false}) =>
    buildAppTheme(b, pureBlack: black, accent: a.color).extension<AppColors>()!;

void main() {
  group('主题色彩 preference', () {
    test('six swatches in the original order, blue by default', () {
      expect(ThemeAccent.values.map((a) => a.color.toARGB32()), [
        0xFF007AFF,
        0xFF34C759,
        0xFFAF52DE,
        0xFFFF9500,
        0xFFFF2D55,
        0xFFFFCC00,
      ]);
      expect(const AppPreferences().accent, ThemeAccent.blue);
      expect(AppPreferences.fromJson(const {}).accent, ThemeAccent.blue);
      expect(AppPreferences.fromJson(const {'themeColor': 'teal'}).accent, ThemeAccent.blue);
    });

    test('round trip, equality, copyWith and withLockHash keep it', () {
      const p = AppPreferences(accent: ThemeAccent.pink);
      expect(p.toJson()['themeColor'], 'pink');
      expect(AppPreferences.fromJson(p.toJson()), p);
      expect(p == const AppPreferences(), isFalse);
      expect(p.copyWith(textScale: 1.2).accent, ThemeAccent.pink);
      expect(p.withLockHash('h').accent, ThemeAccent.pink);
      expect(const AppPreferences().copyWith(accent: ThemeAccent.green).accent, ThemeAccent.green);
    });
  });

  group('palettes (hex values sampled from the original)', () {
    test('dark blue stays as verified before; only the input fill moved to the sampled #33353A', () {
      final c = palette(Brightness.dark, ThemeAccent.blue);
      expect(c.page, const Color(0xFF1C1C1E));
      expect(c.card, const Color(0xFF2C2C2E));
      expect(c.label, const Color(0xFFE2E2E9));
      expect(c.subtitle, const Color(0xFFC4C6D0));
      expect(c.cardHigh, const Color(0xFF33353A));
      expect(c.accent, const Color(0xFF007AFF));
      expect(c.onAccent, const Color(0xFF102F60));
      final s = c.secondaryLabel.toARGB32();
      for (final (shift, want) in [(16, 0x9B), (8, 0x9D), (0, 0xA5)]) {
        expect(((s >> shift) & 0xFF) - want, inInclusiveRange(-1, 1));
      }
    });

    test('dark green: tinted text, input fill and text on the accent', () {
      final c = palette(Brightness.dark, ThemeAccent.green);
      expect(c.page, const Color(0xFF1C1C1E));
      expect(c.card, const Color(0xFF2C2C2E));
      expect(c.label, const Color(0xFFE0E4DB));
      expect(c.subtitle, const Color(0xFFC2C9BD));
      expect(c.cardHigh, const Color(0xFF313630));
      expect(c.onAccent, const Color(0xFF033912));
      final theme = buildAppTheme(Brightness.dark, accent: ThemeAccent.green.color);
      expect(theme.colorScheme.primary, const Color(0xFF34C759));
      expect(theme.colorScheme.onPrimary, const Color(0xFF033912));
    });

    test('the text colour of each swatch on the dark theme', () {
      expect({
        for (final a in ThemeAccent.values) a: palette(Brightness.dark, a).label
      }, {
        ThemeAccent.blue: const Color(0xFFE2E2E9),
        ThemeAccent.green: const Color(0xFFE0E4DB),
        ThemeAccent.purple: const Color(0xFFE9E0E7),
        ThemeAccent.orange: const Color(0xFFEFE0D5),
        ThemeAccent.pink: const Color(0xFFF0DEDE),
        ThemeAccent.yellow: const Color(0xFFEAE1D4),
      });
    });

    test('light green and 纯黑底 green', () {
      final light = palette(Brightness.light, ThemeAccent.green);
      expect(light.page, const Color(0xFFF2F2F7));
      expect(light.card, const Color(0xFFFFFFFF));
      expect(light.label, const Color(0xFF181D18));
      expect(light.onAccent, const Color(0xFFFFFFFF));
      final black = palette(Brightness.dark, ThemeAccent.green, black: true);
      expect(black.page, const Color(0xFF000000));
      expect(black.card, const Color(0xFF121212));
      expect(black.label, const Color(0xFFE0E4DB));
    });

    test('themes are cached, so rebuilding the app does not rebuild or animate them', () {
      final a = buildAppTheme(Brightness.dark, accent: ThemeAccent.orange.color);
      expect(identical(a, buildAppTheme(Brightness.dark, accent: ThemeAccent.orange.color)), isTrue);
      expect(identical(a, buildAppTheme(Brightness.dark, accent: ThemeAccent.pink.color)), isFalse);
    });
  });

  group('主题设置 page', () {
    Future<(ProviderContainer, _MemoryStore)> pump(WidgetTester tester, {ThemeMode mode = ThemeMode.dark}) async {
      final store = _MemoryStore();
      final container = ProviderContainer(overrides: [
        settingsStoreProvider.overrideWithValue(store),
        initialAppPreferencesProvider.overrideWithValue(AppPreferences(themeMode: mode)),
      ]);
      addTearDown(container.dispose);
      await tester.binding.setSurfaceSize(const Size(420, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: Consumer(builder: (context, ref, _) {
          final prefs = ref.watch(appPreferencesProvider);
          return MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: buildAppTheme(Brightness.light, accent: prefs.accent.color),
            darkTheme: buildAppTheme(Brightness.dark, accent: prefs.accent.color),
            themeMode: prefs.themeMode,
            home: const ThemeSettingsScreen(),
          );
        }),
      ));
      await tester.pumpAndSettle();
      return (container, store);
    }

    Color paletteIconColor(WidgetTester tester) => tester.widget<Icon>(find.byIcon(Icons.palette_outlined)).color!;

    testWidgets('主题色彩 sits between 暗色背景风格 and 字体大小; picking a swatch applies and saves it', (tester) async {
      final (container, store) = await pump(tester);
      expect(find.text('主题色彩'), findsOneWidget);
      expect(tester.getTopLeft(find.text('暗色背景风格')).dy, lessThan(tester.getTopLeft(find.text('主题色彩')).dy));
      expect(tester.getTopLeft(find.text('主题色彩')).dy, lessThan(tester.getTopLeft(find.text('字体大小')).dy));
      expect(find.descendant(of: find.byKey(const ValueKey('accent-blue')), matching: find.byIcon(Icons.check)),
          findsOneWidget);
      expect(paletteIconColor(tester), const Color(0xFF007AFF));

      await tester.tap(find.byKey(const ValueKey('accent-green')));
      await tester.pumpAndSettle();
      expect(container.read(appPreferencesProvider).accent, ThemeAccent.green);
      expect((await store.read<Map<String, dynamic>>(const {}))['themeColor'], 'green');
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('accent-green')), matching: find.byIcon(Icons.check)),
          findsOneWidget);
      expect(paletteIconColor(tester), const Color(0xFF34C759));
      final ring = (tester
              .widget<Container>(
                  find.descendant(of: find.byKey(const ValueKey('accent-green')), matching: find.byType(Container)))
              .decoration as BoxDecoration)
          .border as Border;
      expect(ring.top.color, Colors.white);
    });

    testWidgets('light: no 暗色背景风格, and the chosen swatch has a dark ring', (tester) async {
      await pump(tester, mode: ThemeMode.light);
      expect(find.text('暗色背景风格'), findsNothing);
      expect(find.text('主题色彩'), findsOneWidget);
      final ring = (tester
              .widget<Container>(
                  find.descendant(of: find.byKey(const ValueKey('accent-blue')), matching: find.byType(Container)))
              .decoration as BoxDecoration)
          .border as Border;
      expect(ring.top.color, Colors.black87);
    });

    testWidgets('the 主题设置 row says 配色、暗黑风格、字体大小', (tester) async {
      final container = ProviderContainer(overrides: [settingsStoreProvider.overrideWithValue(_MemoryStore())]);
      addTearDown(container.dispose);
      await tester.binding.setSurfaceSize(const Size(420, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildAppTheme(Brightness.dark),
          home: const SettingsIndexScreen(),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('配色、暗黑风格、字体大小'), findsOneWidget);
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
