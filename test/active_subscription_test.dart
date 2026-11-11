import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/app/providers.dart';
import 'package:uzv_reimpl/core/json_store.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('uzv_active_sub'));
  tearDown(() => dir.deleteSync(recursive: true));

  ProviderContainer container() => ProviderContainer(overrides: [
        settingsStoreProvider.overrideWithValue(JsonStore('settings.json', baseDir: dir)),
      ]);

  test('no selection yet means null (the first subscription is used)', () async {
    final c = container();
    addTearDown(c.dispose);
    expect(await c.read(activeSubscriptionKeyProvider.future), isNull);
  });

  test('the selected subscription survives an app restart', () async {
    final first = container();
    await first.read(activeSubscriptionKeyProvider.future);
    await first.read(activeSubscriptionKeyProvider.notifier).select('mock');
    expect(first.read(activeSubscriptionKeyProvider).valueOrNull, 'mock');
    first.dispose();

    final restarted = container();
    addTearDown(restarted.dispose);
    expect(await restarted.read(activeSubscriptionKeyProvider.future), 'mock');
  });

  test('selecting keeps the other settings in settings.json', () async {
    final store = JsonStore('settings.json', baseDir: dir);
    await store.write({'other': 1});
    final c = container();
    addTearDown(c.dispose);
    await c.read(activeSubscriptionKeyProvider.notifier).select('a');
    expect(await store.read<Map<String, dynamic>>(const {}), {'other': 1, 'activeSubscription': 'a'});
  });
}
