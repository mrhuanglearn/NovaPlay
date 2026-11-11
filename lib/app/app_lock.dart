import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/subscription/subscription.dart';
import 'app_preferences.dart';
import 'providers.dart';

// 设置 → 锁密码 and 订阅 → 上锁, OBSERVED on the original (2026-11-09, docs/ui-ref/original/orig_lock_*.png): a code is a
// string of the digits 1–4 typed on a 2×2 colour keypad, of any length. A locked subscription is hidden from 订阅管理, and
// the home page shows 订阅已上锁 while the active subscription is locked, until the code is verified. One unlock opens
// both pages; the open-lock button in 订阅管理 closes them again.

/// The three states the settings row shows (未设置 / 空密码 / 已设置).
enum LockPasswordState { notSet, empty, set }

/// Only a salted SHA-256 of the code is kept (settings.json `lockPassword`), never the code.
String lockCodeHash(String code) => sha256.convert(utf8.encode('uzv-lock:$code')).toString();

final _emptyHash = lockCodeHash('');

LockPasswordState lockStateOf(String? hash) => hash == null
    ? LockPasswordState.notSet
    : hash == _emptyHash
        ? LockPasswordState.empty
        : LockPasswordState.set;

bool lockCodeMatches(String? hash, String code) => hash != null && hash == lockCodeHash(code);

/// With no password or an empty one, opening the lock asks for nothing. So a locked subscription can never stay hidden
/// for good (after 清除, or with locked subscriptions from a restored backup but no password).
bool lockNeedsCode(String? hash) => lockStateOf(hash) == LockPasswordState.set;

/// Whether locked subscriptions are shown right now. Memory only: INFERRED that the original asks again after a restart.
class SubscriptionsUnlocked extends Notifier<bool> {
  @override
  bool build() => false;

  void unlock() => state = true;
  void relock() => state = false;
}

final subscriptionsUnlockedProvider = NotifierProvider<SubscriptionsUnlocked, bool>(SubscriptionsUnlocked.new);

/// The subscriptions 订阅管理 lists.
List<Subscription> visibleSubscriptions(List<Subscription> all, {required bool unlocked}) => unlocked
    ? all
    : [
        for (final s in all)
          if (!s.locked) s
      ];

/// Whether the home page shows 订阅已上锁: the active subscription (the first when none was chosen) is locked and the
/// lock is closed. The runtime keeps running; only the home page is covered (OBSERVED).
final homeLockedProvider = Provider<bool>((ref) {
  if (ref.watch(subscriptionsUnlockedProvider)) return false;
  final subs = ref.watch(subscriptionsProvider).valueOrNull;
  if (subs == null || subs.isEmpty) return false;
  final key = ref.watch(activeSubscriptionKeyProvider).valueOrNull;
  return subs.firstWhere((s) => s.key == key, orElse: () => subs.first).locked;
});

extension LockPreferences on AppPreferencesNotifier {
  /// null clears the password (未设置); '' is the empty password chosen with 不设置.
  Future<void> setLockCode(String? code) => setLockHash(code == null ? null : lockCodeHash(code));
}
