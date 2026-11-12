import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/app/app_preferences.dart';
import 'package:uzv_reimpl/app/providers.dart';
import 'package:uzv_reimpl/app/theme.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/features/subscription/subscription.dart';
import 'package:uzv_reimpl/l10n/l10n.dart';
import 'package:uzv_reimpl/ui/subscriptions_screen.dart';
import 'package:uzv_reimpl/ui/widgets.dart';

// User report (2026-11-10): 设置 → 订阅管理 → 编辑, then back, left the page for 设置. The user wants back to leave the
// edit mode first and stay on 订阅管理. (OBSERVED: the original 1.1.7 on the user's phone leaves the page, so this is a
// deliberate difference.)

const _alpha = Subscription(
  key: 'a',
  name: 'Alpha',
  indexJsUrl: 'https://woleigedouer:woleigedouer@catpaw.douer.me/index.js.md5',
);

void main() {
  Future<void> pump(WidgetTester tester) async {
    final container = ProviderContainer(overrides: [
      settingsStoreProvider.overrideWithValue(_MemoryStore('settings.json')),
      initialAppPreferencesProvider.overrideWithValue(const AppPreferences()),
      subscriptionsProvider.overrideWith((ref) async => const [_alpha]),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildAppTheme(Brightness.dark),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SubscriptionsScreen())),
                child: const Text('设置页'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('设置页'));
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsOneWidget);
  }

  testWidgets('system back in edit mode leaves the edit mode and stays on 订阅管理', (tester) async {
    await pump(tester);
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(find.text('完成'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('完成'), findsNothing);
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('设置页'), findsNothing, reason: 'still on 订阅管理');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('设置页'), findsOneWidget, reason: 'outside the edit mode back leaves the page');
  });

  testWidgets('the app bar back arrow does the same', (tester) async {
    await pump(tester);
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('设置页'), findsNothing);
  });

  testWidgets('subscription URL preserves user:pass@ credentials on screen', (tester) async {
    await pump(tester);
    expect(
      find.text('https://woleigedouer:woleigedouer@catpaw.douer.me/index.js.md5'),
      findsOneWidget,
    );
  });

  test('parsePosterRequest preserves anti-hotlink headers for Douban and CatVod @Header tags', () {
    final douban = parsePosterRequest('https://img9.doubanio.com/view/photo/s_ratio_poster/public/p2928374.jpg');
    expect(douban.url, 'https://img9.doubanio.com/view/photo/s_ratio_poster/public/p2928374.jpg');
    expect(douban.headers['Referer'], 'https://movie.douban.com/');
    expect(douban.headers['User-Agent'], isNotEmpty);

    final tagged = parsePosterRequest(
      'https://example.com/poster.jpg@Referer=https://custom.ref/@User-Agent=CustomUA/1.0',
    );
    expect(tagged.url, 'https://example.com/poster.jpg');
    expect(tagged.headers['Referer'], 'https://custom.ref/');
    expect(tagged.headers['User-Agent'], 'CustomUA/1.0');
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
