import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/catpaw/spider_api.dart';
import 'app_lock.dart';
import 'providers.dart';

// 切换站点 → 站点设置, OBSERVED on the phone (UZN, 2026-11-13): every site of the running subscription has four switches,
// 启用 (eye), 搜索 (magnifier), 历史记录 (clock) and 上锁 (padlock).
// - 启用 off: the site leaves 切换站点 and 站点搜索管理 (it stays in 站点设置, greyed).
// - 搜索 is the same switch as the site's tile in 搜索 → 站点搜索管理.
// - 上锁: the first lock asks 首次上锁 like a subscription; a locked site leaves 切换站点 and 站点设置 at once, and a lock
//   button appears next to ✓ that opens (解锁) and closes the lock again.
// - 历史记录 off: INFERRED the site's videos are not written to 观看历史 (not checked on the original).
// The 切换站点 sheet also has a 单列 / 双列 toggle (kept after a restart, OBSERVED) and a globe that opens the
// subscription's web page.

/// Per-subscription site switches (settings.json `siteSettings: {subscriptionKey: {disabled, noHistory, locked}}`)
/// and the 切换站点 layout (`siteSheetGrid`).
class SitePrefs {
  const SitePrefs({this.grid = false, this.disabled = const {}, this.noHistory = const {}, this.locked = const {}});

  factory SitePrefs.fromSettings(Map<String, dynamic> s, String? subscription) {
    final all = s[_field];
    final mine = all is Map && subscription != null ? all[subscription] : null;
    Set<String> keys(String name) {
      final v = mine is Map ? mine[name] : null;
      return {if (v is List) for (final k in v) '$k'};
    }

    return SitePrefs(
      grid: s[_gridField] == true,
      disabled: keys('disabled'),
      noHistory: keys('noHistory'),
      locked: keys('locked'),
    );
  }

  static const _field = 'siteSettings';
  static const _gridField = 'siteSheetGrid';

  final bool grid;
  final Set<String> disabled;
  final Set<String> noHistory;
  final Set<String> locked;

  bool enabled(String site) => !disabled.contains(site);
  bool recordsHistory(String site) => !noHistory.contains(site);
  bool isLocked(String site) => locked.contains(site);

  SitePrefs copyWith({bool? grid, Set<String>? disabled, Set<String>? noHistory, Set<String>? locked}) => SitePrefs(
        grid: grid ?? this.grid,
        disabled: disabled ?? this.disabled,
        noHistory: noHistory ?? this.noHistory,
        locked: locked ?? this.locked,
      );

  /// [settings] with these prefs written into it (other subscriptions' switches are kept).
  Map<String, dynamic> writeTo(Map<String, dynamic> settings, String? subscription) {
    final out = Map<String, dynamic>.of(settings);
    out[_gridField] = grid;
    if (subscription != null) {
      final all = out[_field];
      out[_field] = {
        if (all is Map) ...all,
        subscription: {
          'disabled': disabled.toList(),
          'noHistory': noHistory.toList(),
          'locked': locked.toList(),
        },
      };
    }
    return out;
  }
}

class SitePrefsNotifier extends AsyncNotifier<SitePrefs> {
  String? _subscription;

  @override
  Future<SitePrefs> build() async {
    _subscription = await ref.watch(catpawRuntimeProvider.selectAsync((rt) => rt?.subscription.key));
    final s = await ref.read(settingsStoreProvider).read<Map<String, dynamic>>(const {});
    return SitePrefs.fromSettings(s, _subscription);
  }

  Future<void> _save(SitePrefs next) async {
    state = AsyncData(next);
    final store = ref.read(settingsStoreProvider);
    await store.write(next.writeTo(await store.read<Map<String, dynamic>>(const {}), _subscription));
  }

  static Set<String> _flip(Set<String> set, String key) {
    final out = {...set};
    if (!out.remove(key)) out.add(key);
    return out;
  }

  Future<void> toggleGrid() async {
    final cur = await future;
    await _save(cur.copyWith(grid: !cur.grid));
  }

  Future<void> toggleEnabled(String site) async {
    final cur = await future;
    await _save(cur.copyWith(disabled: _flip(cur.disabled, site)));
  }

  Future<void> toggleHistory(String site) async {
    final cur = await future;
    await _save(cur.copyWith(noHistory: _flip(cur.noHistory, site)));
  }

  Future<void> setLocked(String site, bool locked) async {
    final cur = await future;
    final next = {...cur.locked};
    locked ? next.add(site) : next.remove(site);
    await _save(cur.copyWith(locked: next));
  }
}

final sitePrefsProvider = AsyncNotifierProvider<SitePrefsNotifier, SitePrefs>(SitePrefsNotifier.new);

/// Whether locked sites are shown right now: the same lock as the subscriptions (one 解锁 opens both).
final sitesUnlockedProvider = Provider<bool>((ref) => ref.watch(subscriptionsUnlockedProvider));

/// The sites listed in 站点设置: every site except the locked ones while the lock is closed.
final settingsSitesProvider = Provider<List<SpiderSite>>((ref) {
  final sites = ref.watch(homeSitesProvider);
  final prefs = ref.watch(sitePrefsProvider).valueOrNull ?? const SitePrefs();
  if (ref.watch(sitesUnlockedProvider)) return sites;
  return [
    for (final s in sites)
      if (!prefs.isLocked(s.key)) s
  ];
});

/// The sites 切换站点 lists and the home page can show: the [settingsSitesProvider] sites that are 启用.
final visibleHomeSitesProvider = Provider<List<SpiderSite>>((ref) {
  final prefs = ref.watch(sitePrefsProvider).valueOrNull ?? const SitePrefs();
  return [
    for (final s in ref.watch(settingsSitesProvider))
      if (prefs.enabled(s.key)) s
  ];
});
