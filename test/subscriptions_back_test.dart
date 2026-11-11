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

// User report (2026-11-10): 设置 → 订阅管理 → 编辑, then back, left the page for 设置. The user wants back to leave the
// edit mode first and stay on 订阅管理. (OBSERVED: the original 1.1.7 on the user's phone leaves the page, so this is a
// deliberate difference.)

const _alpha = Subscription(key: 'a', name: 'Alpha');

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
}

class _MemoryStore extends JsonStore {
  _MemoryStore(super.name);
  Object? _data;

  @override
  Future<T> read<T>(T fallback) async => (_data as T?) ?? fallback;

  @override
  Future<void> write(Object? json) async => _data = json;
}
