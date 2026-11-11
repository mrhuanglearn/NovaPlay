import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/app/app_lock.dart';
import 'package:uzv_reimpl/app/app_preferences.dart';
import 'package:uzv_reimpl/app/providers.dart';
import 'package:uzv_reimpl/app/theme.dart';
import 'package:uzv_reimpl/app/ui_hooks.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/features/subscription/subscription.dart';
import 'package:uzv_reimpl/l10n/l10n.dart';
import 'package:uzv_reimpl/ui/home_screen.dart';
import 'package:uzv_reimpl/ui/lock_dialogs.dart';
import 'package:uzv_reimpl/ui/settings_screens.dart';
import 'package:uzv_reimpl/ui/subscriptions_screen.dart';

const _alpha = Subscription(key: 'a', name: 'Alpha');
const _beta = Subscription(key: 'b', name: 'Beta', locked: true);

void main() {
  group('lock model', () {
    test('three states; only the hash is kept', () {
      expect(lockStateOf(null), LockPasswordState.notSet);
      expect(lockStateOf(lockCodeHash('')), LockPasswordState.empty);
      expect(lockStateOf(lockCodeHash('1234')), LockPasswordState.set);
      expect(lockCodeHash('12'), hasLength(64));
      expect(lockCodeMatches(lockCodeHash('12'), '12'), isTrue);
      expect(lockCodeMatches(lockCodeHash('12'), '21'), isFalse);
      expect(lockCodeMatches(null, ''), isFalse);
      expect([null, lockCodeHash(''), lockCodeHash('3')].map(lockNeedsCode), [false, false, true]);
    });

    test('kept in settings.json; cleared only through withLockHash', () {
      final p = const AppPreferences().withLockHash(lockCodeHash('21'));
      expect(AppPreferences.fromJson(p.toJson()), p);
      expect(p.copyWith(textScale: 1.2).lockHash, p.lockHash);
      final cleared = p.withLockHash(null);
      expect(cleared.lockHash, isNull);
      expect(cleared.toJson()['lockPassword'], isNull);
      expect(AppPreferences.fromJson(const {'lockPassword': ''}).lockHash, isNull);
    });

    test('hidden subscriptions keep their places when the shown ones are reordered', () {
      const c = Subscription(key: 'c', name: 'C');
      const d = Subscription(key: 'd', name: 'D', locked: true);
      const e = Subscription(key: 'e', name: 'E');
      final all = [_alpha, _beta, c, d, e];
      final shown = visibleSubscriptions(all, unlocked: false);
      expect(shown.map((s) => s.key), ['a', 'c', 'e']);
      expect(visibleSubscriptions(all, unlocked: true), all);
      expect(reorderShown(all, shown, 0, 2).map((s) => s.key), ['c', 'b', 'e', 'd', 'a']);
    });

    test('the home page is covered while the active subscription is locked and the lock is closed', () async {
      final container = ProviderContainer(overrides: [
        settingsStoreProvider.overrideWithValue(_MemoryStore('settings.json')),
        subscriptionsProvider.overrideWith((ref) async => const [_beta, _alpha]),
      ]);
      addTearDown(container.dispose);
      final sub = container.listen(homeLockedProvider, (previous, next) {});
      addTearDown(sub.close);
      await container.read(subscriptionsProvider.future);
      await container.read(activeSubscriptionKeyProvider.future);
      expect(container.read(homeLockedProvider), isTrue); // nothing chosen: the first one, locked
      container.read(subscriptionsUnlockedProvider.notifier).unlock();
      expect(container.read(homeLockedProvider), isFalse);
      container.read(subscriptionsUnlockedProvider.notifier).relock();
      expect(container.read(homeLockedProvider), isTrue);
      await container.read(activeSubscriptionKeyProvider.notifier).select('a');
      expect(container.read(homeLockedProvider), isFalse);
    });
  });

  group('lock dialogs', () {
    testWidgets('设置 → 锁密码 without a password: too short, a mismatch, then a new one', (tester) async {
      final c = await _pump(tester, run: (context, ref) => showLockPasswordDialog(context));
      await _go(tester);
      expect(find.text('尚未设置锁密码'), findsOneWidget);
      expect(find.text('输入新密码'), findsOneWidget);
      expect(find.text('清除'), findsNothing);
      await _press(tester, '下一步');
      expect(find.text('请至少输入一位'), findsOneWidget);

      await _type(tester, '12');
      await _press(tester, '下一步');
      expect(find.text('再次输入确认'), findsOneWidget);
      expect(find.text('点击色块输入密码'), findsOneWidget); // the input starts empty again
      await _type(tester, '21');
      await _press(tester, '确认');
      expect(find.text('两次输入不一致，请重试'), findsOneWidget);
      expect(find.text('输入新密码'), findsOneWidget);
      expect(c.read(appPreferencesProvider).lockHash, isNull);

      await _type(tester, '12');
      await _press(tester, '下一步');
      await _type(tester, '12');
      await _press(tester, '确认');
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('锁密码已更新'), findsOneWidget);
      expect(c.read(appPreferencesProvider).lockHash, lockCodeHash('12'));
    });

    testWidgets('with a password: 旧密码错误, 清除 needs the right code, then a change', (tester) async {
      final c =
          await _pump(tester, lockHash: lockCodeHash('12'), run: (context, ref) => showLockPasswordDialog(context));
      await _go(tester);
      expect(find.text('当前已设置锁密码'), findsOneWidget);
      expect(find.text('验证旧密码'), findsOneWidget);
      await _type(tester, '3');
      await _press(tester, '下一步');
      expect(find.text('旧密码错误'), findsOneWidget);
      expect(find.text('点击色块输入密码'), findsOneWidget);
      await _press(tester, '清除');
      expect(find.text('旧密码错误'), findsOneWidget);
      expect(c.read(appPreferencesProvider).lockHash, lockCodeHash('12'));

      await _type(tester, '12');
      await _press(tester, '下一步');
      expect(find.text('输入新密码'), findsOneWidget);
      expect(find.text('清除'), findsNothing);
      await _type(tester, '4');
      await _press(tester, '下一步');
      await _type(tester, '4');
      await _press(tester, '确认');
      expect(c.read(appPreferencesProvider).lockHash, lockCodeHash('4'));
    });

    testWidgets('清除 with the right code', (tester) async {
      final c =
          await _pump(tester, lockHash: lockCodeHash('31'), run: (context, ref) => showLockPasswordDialog(context));
      await _go(tester);
      await _type(tester, '31');
      await _press(tester, '清除');
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('已清除锁密码'), findsOneWidget);
      expect(c.read(appPreferencesProvider).lockHash, isNull);
    });

    testWidgets('验证锁密码 closes by itself once the digits match; backspace removes one', (tester) async {
      final c = await _pump(tester, lockHash: lockCodeHash('21'), run: unlockSubscriptions);
      await _go(tester);
      expect(find.text('验证锁密码'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
      await _type(tester, '22');
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.byIcon(Icons.backspace));
      await tester.pumpAndSettle();
      await _type(tester, '1');
      expect(find.byType(AlertDialog), findsNothing);
      expect(c.read(subscriptionsUnlockedProvider), isTrue);
    });

    testWidgets('验证锁密码 dismissed: still locked', (tester) async {
      final c = await _pump(tester, lockHash: lockCodeHash('21'), run: unlockSubscriptions);
      await _go(tester);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(c.read(subscriptionsUnlockedProvider), isFalse);
    });

    for (final hash in [null, lockCodeHash('')]) {
      testWidgets('no code to ask for (${hash == null ? '未设置' : '空密码'}): unlocking opens at once', (tester) async {
        final c = await _pump(tester, lockHash: hash, run: unlockSubscriptions);
        await _go(tester);
        expect(find.byType(AlertDialog), findsNothing);
        expect(c.read(subscriptionsUnlockedProvider), isTrue);
      });
    }

    testWidgets('首次上锁: 取消 keeps it unlocked, 确认 keeps the digits, later locks ask nothing', (tester) async {
      final results = <bool>[];
      final c = await _pump(tester, run: (context, ref) async => results.add(await confirmFirstLock(context, ref)));
      await _go(tester);
      expect(find.text('首次上锁'), findsOneWidget);
      expect(find.text('是否设置锁密码？不设置则使用空密码（无密码保护）。'), findsOneWidget);
      await _press(tester, '取消');
      expect(results, [false]);
      expect(c.read(appPreferencesProvider).lockHash, isNull);

      await _go(tester);
      await _press(tester, '确认');
      expect(find.text('请至少输入一位'), findsOneWidget);
      await _type(tester, '34');
      await _press(tester, '确认');
      expect(results, [false, true]);
      expect(c.read(appPreferencesProvider).lockHash, lockCodeHash('34'));

      await _go(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(results, [false, true, true]);
    });

    testWidgets('首次上锁 → 不设置: the empty password', (tester) async {
      final results = <bool>[];
      final c = await _pump(tester, run: (context, ref) async => results.add(await confirmFirstLock(context, ref)));
      await _go(tester);
      await _press(tester, '不设置');
      expect(results, [true]);
      expect(lockStateOf(c.read(appPreferencesProvider).lockHash), LockPasswordState.empty);
      expect(find.text('已设为空密码'), findsOneWidget);
    });
  });

  group('pages', () {
    testWidgets('设置 shows the 锁密码 state', (tester) async {
      final c = await _pump(tester, home: const SettingsIndexScreen());
      expect(find.text('锁密码'), findsOneWidget);
      expect(find.text('未设置'), findsOneWidget);
      await c.read(appPreferencesProvider.notifier).setLockCode('');
      await tester.pumpAndSettle();
      expect(find.text('空密码'), findsOneWidget);
      await c.read(appPreferencesProvider.notifier).setLockCode('2');
      await tester.pumpAndSettle();
      expect(find.text('已设置'), findsOneWidget);
    });

    testWidgets('订阅管理 hides locked subscriptions until the lock button opens them', (tester) async {
      await _pump(tester, subs: const [_alpha, _beta], home: const SubscriptionsScreen());
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsNothing);
      await tester.tap(find.byIcon(Icons.lock));
      await tester.pumpAndSettle();
      expect(find.text('Beta'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.lock_open_outlined));
      await tester.pumpAndSettle();
      expect(find.text('Beta'), findsNothing);
    });

    testWidgets('订阅管理 with every subscription hidden: lock and add only', (tester) async {
      await _pump(tester, subs: const [_beta], home: const SubscriptionsScreen());
      expect(find.text('有已上锁的订阅被隐藏'), findsOneWidget);
      expect(find.byIcon(Icons.sync), findsNothing);
      expect(find.text('编辑'), findsNothing);
      expect(find.byIcon(Icons.add), findsOneWidget);
    });

    testWidgets('订阅管理 without locked subscriptions has no lock button', (tester) async {
      await _pump(tester, subs: const [_alpha], home: const SubscriptionsScreen());
      expect(find.byIcon(Icons.lock), findsNothing);
      expect(find.byIcon(Icons.lock_open_outlined), findsNothing);
    });

    testWidgets('编辑订阅 → 上锁 asks 首次上锁 only while no password exists', (tester) async {
      final repo = SubscriptionRepository(store: _MemoryStore('subscriptions.json'));
      await repo.save(const [_alpha, Subscription(key: 'c', name: 'C')]);
      final c = await _pump(tester, repository: repo, home: const EditSubscriptionScreen(subKey: 'a'));
      Future<bool> locked() async => (await repo.all()).firstWhere((s) => s.key == 'a').locked;

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await _press(tester, '取消');
      expect(await locked(), isFalse);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await _type(tester, '1');
      await _press(tester, '确认');
      expect(await locked(), isTrue);
      expect(c.read(appPreferencesProvider).lockHash, lockCodeHash('1'));

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(await locked(), isFalse);
    });

    testWidgets('添加订阅 → 上锁 asks 首次上锁 too', (tester) async {
      final c = await _pump(tester, subs: const [_alpha], home: const AddSubscriptionScreen());
      bool lockOn() => tester.widget<Switch>(find.byType(Switch).last).value; // after 自动更新
      await tester.tap(find.byType(Switch).last);
      await tester.pumpAndSettle();
      await _press(tester, '取消');
      expect(lockOn(), isFalse);
      await tester.tap(find.byType(Switch).last);
      await tester.pumpAndSettle();
      await _press(tester, '不设置');
      expect(lockOn(), isTrue);
      expect(lockStateOf(c.read(appPreferencesProvider).lockHash), LockPasswordState.empty);
    });

    testWidgets('home page: 订阅已上锁 until 解锁 and the code', (tester) async {
      final c = await _pump(
        tester,
        lockHash: lockCodeHash('4'),
        subs: const [_beta],
        home: const HomeScreen(),
        overrides: [catpawRuntimeProvider.overrideWith((ref) async => null)],
      );
      expect(find.text('订阅已上锁'), findsOneWidget);
      expect(find.text('当前订阅已上锁，请解锁后查看'), findsOneWidget);
      expect(find.byType(AppBar), findsNothing);
      await _press(tester, '解锁');
      await _type(tester, '4');
      expect(c.read(subscriptionsUnlockedProvider), isTrue);
      expect(find.text('订阅已上锁'), findsNothing);
    });
  });
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  String? lockHash,
  List<Subscription>? subs,
  SubscriptionRepository? repository,
  Widget? home,
  Future<void> Function(BuildContext context, WidgetRef ref)? run,
  List<Override> overrides = const [],
}) async {
  final container = ProviderContainer(overrides: [
    settingsStoreProvider.overrideWithValue(_MemoryStore('settings.json')),
    initialAppPreferencesProvider.overrideWithValue(const AppPreferences().withLockHash(lockHash)),
    if (subs != null) subscriptionsProvider.overrideWith((ref) async => subs),
    if (repository != null) subscriptionRepositoryProvider.overrideWithValue(repository),
    ...overrides,
  ]);
  addTearDown(container.dispose);
  await tester.binding.setSurfaceSize(const Size(420, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      scaffoldMessengerKey: rootMessengerKey,
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildAppTheme(Brightness.dark),
      home: home ??
          Consumer(
            builder: (context, ref, child) => Scaffold(
              body: Center(child: ElevatedButton(onPressed: () => run!(context, ref), child: const Text('go'))),
            ),
          ),
    ),
  ));
  await tester.pumpAndSettle();
  return container;
}

Future<void> _go(WidgetTester tester) async {
  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
}

Future<void> _press(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

/// Taps the keypad tiles (the numbered dots above them are not buttons).
Future<void> _type(WidgetTester tester, String digits) async {
  for (final d in digits.split('')) {
    await tester.tap(find.widgetWithText(InkWell, d));
    await tester.pumpAndSettle();
  }
}

/// A JsonStore in memory: widget tests run on a fake clock where real file I/O never completes.
class _MemoryStore extends JsonStore {
  _MemoryStore(super.name);
  Object? _data;

  @override
  Future<T> read<T>(T fallback) async => (_data as T?) ?? fallback;

  @override
  Future<void> write(Object? json) async => _data = json;
}
