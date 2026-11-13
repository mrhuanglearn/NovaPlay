import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/app_lock.dart';
import '../app/providers.dart';
import '../app/theme.dart';
import '../app/ui_hooks.dart';
import '../features/catpaw/spider_api.dart';
import '../models/vod.dart';
import '../l10n/l10n.dart';
import 'app_shell.dart';
import 'category_filters.dart';
import 'load_error.dart';
import 'lock_dialogs.dart';
import 'site_switch_sheet.dart';
import 'widgets.dart';

// Layout OBSERVED on the original with a mock subscription (2026-11-09, docs/ui-ref/original/orig_home*.png): a pill
// with a compass icon and the site name (opens a 切换站点 sheet), link (推送解析) and search icons; the site's categories
// as underlined text tabs (no 首页 tab: the first category is shown), a tune icon with 分类屏蔽 / 隐藏筛选 / 切换布局;
// posters with the remark in a dark chip at the bottom left and the title centred underneath.

/// Home-page preferences kept in settings.json: poster layout, filter row visibility and blocked categories per site.
class HomePrefs {
  const HomePrefs({this.listLayout = false, this.hideFilters = false, this.blocked = const {}});
  final bool listLayout;
  final bool hideFilters;
  final Map<String, List<String>> blocked;

  List<String> blockedFor(String? site) => site == null ? const [] : blocked[site] ?? const [];
}

class HomePrefsNotifier extends AsyncNotifier<HomePrefs> {
  static const _field = 'home';

  @override
  Future<HomePrefs> build() async {
    final m = (await ref.watch(settingsStoreProvider).read<Map<String, dynamic>>(const {}))[_field];
    if (m is! Map) return const HomePrefs();
    final blocked = <String, List<String>>{};
    if (m['blocked'] case final Map b) {
      b.forEach((k, v) => blocked['$k'] = [for (final x in (v as List? ?? const [])) '$x']);
    }
    return HomePrefs(listLayout: m['layout'] == 'list', hideFilters: m['hideFilters'] == true, blocked: blocked);
  }

  Future<void> _save(HomePrefs p) async {
    state = AsyncData(p);
    final store = ref.read(settingsStoreProvider);
    final all = Map<String, dynamic>.of(await store.read<Map<String, dynamic>>(const {}));
    all[_field] = {'layout': p.listLayout ? 'list' : 'grid', 'hideFilters': p.hideFilters, 'blocked': p.blocked};
    await store.write(all);
  }

  HomePrefs get _p => state.valueOrNull ?? const HomePrefs();
  Future<void> toggleLayout() =>
      _save(HomePrefs(listLayout: !_p.listLayout, hideFilters: _p.hideFilters, blocked: _p.blocked));
  Future<void> toggleFilters() =>
      _save(HomePrefs(listLayout: _p.listLayout, hideFilters: !_p.hideFilters, blocked: _p.blocked));
  Future<void> setBlocked(String site, List<String> ids) =>
      _save(HomePrefs(listLayout: _p.listLayout, hideFilters: _p.hideFilters, blocked: {..._p.blocked, site: ids}));
}

final homePrefsProvider = AsyncNotifierProvider<HomePrefsNotifier, HomePrefs>(HomePrefsNotifier.new);

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  /// INFERRED: CatVod subscriptions that accept pushed links expose a site with the key `push_agent`.
  void _push(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final push = ref.read(homeSitesProvider).where((s) => s.key == 'push_agent').firstOrNull;
    if (push == null) return showToast(l.homePushNotSupported);
    final controller = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(l.homePushTitle),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l.homePushDescription, style: TextStyle(fontSize: 13, color: AppColors.of(c).secondaryLabel)),
          const SizedBox(height: 12),
          TextField(controller: controller, autofocus: true, decoration: InputDecoration(hintText: l.homePushHint)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(l.cancel)),
          FilledButton(
            onPressed: () {
              final link = controller.text.trim();
              Navigator.pop(c);
              if (link.isEmpty) return;
              context.push(Uri(path: '/video/detail', queryParameters: {'id': link, 'site': push.key}).toString());
            },
            child: Text(l.ok),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    // OBSERVED: while the active subscription is locked the whole page, title bar included, is replaced.
    if (ref.watch(homeLockedProvider)) return const Scaffold(body: _LockedHome());
    final runtime = ref.watch(catpawRuntimeProvider);
    final ready = runtime.valueOrNull != null;
    return Scaffold(
      // The original shows no title bar until a subscription exists.
      appBar: ready
          ? AppBar(
              centerTitle: false,
              titleSpacing: 16,
              title: const _SitePill(),
              actions: [
                IconButton(
                    tooltip: l.homePushTitle, icon: const Icon(Icons.link), onPressed: () => _push(context, ref)),
                IconButton(tooltip: l.search, icon: const Icon(Icons.search), onPressed: () => context.push('/search')),
                const SizedBox(width: 4),
              ],
            )
          : null,
      body: SafeArea(
        bottom: false,
        child: runtime.when(
          skipLoadingOnRefresh: false,
          skipLoadingOnReload: false,
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => EmptyState(
            icon: Icons.cloud_off_rounded,
            title: l.homeCatpawUnavailable,
            subtitle: '$e',
            action: OutlinedButton(onPressed: () => ref.invalidate(catpawRuntimeProvider), child: Text(l.retry)),
          ),
          data: (rt) => rt == null
              ? EmptyState(
                  icon: Icons.dynamic_feed_rounded,
                  title: l.subscriptionsEmptyTitle,
                  subtitle: l.subscriptionsEmptySubtitle,
                  action: PrimaryButton(
                      icon: Icons.add,
                      label: l.subscriptionAdd,
                      expand: true,
                      height: 51,
                      onPressed: () => context.push('/subscriptions/add')),
                )
              : const _HomeBody(),
        ),
      ),
    );
  }
}

/// OBSERVED: a grey lock, 订阅已上锁, 当前订阅已上锁，请解锁后查看 and a small filled 解锁 button, centred on the screen.
class _LockedHome extends ConsumerWidget {
  const _LockedHome();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final c = AppColors.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.lock, size: 52, color: c.secondaryLabel),
          const SizedBox(height: 16),
          Text(l.lockHomeTitle,
              textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c.label)),
          const SizedBox(height: 6),
          Text(l.lockHomeSubtitle, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: c.subtitle)),
          const SizedBox(height: 20),
          FilledButton(
            style: FilledButton.styleFrom(
                minimumSize: const Size(76, 40), padding: const EdgeInsets.symmetric(horizontal: 24)),
            onPressed: () => unlockSubscriptions(context, ref),
            child: Text(l.lockUnlock, style: const TextStyle(fontSize: 15)),
          ),
        ]),
      ),
    );
  }
}

class _SitePill extends ConsumerWidget {
  const _SitePill();

  void _openSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (c) => SiteSwitchSheet(pageContext: context),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppColors.of(context);
    final sites = ref.watch(homeSitesProvider);
    final current = ref.watch(currentSiteProvider);
    if (sites.isEmpty || current == null) return Text(context.l10n.appName);
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: c.card,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () => _openSheet(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 7, 12, 7),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 22,
                height: 22,
                decoration:
                    BoxDecoration(color: AppColors.of(context).accent.withValues(alpha: 0.18), shape: BoxShape.circle),
                child: Icon(Icons.explore, size: 15, color: AppColors.of(context).accent),
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(current.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: c.label)),
              ),
              const SizedBox(width: 4),
              Icon(Icons.keyboard_arrow_down, size: 18, color: c.secondaryLabel),
            ]),
          ),
        ),
      ),
    );
  }
}

class _HomeBody extends ConsumerStatefulWidget {
  const _HomeBody();
  @override
  ConsumerState<_HomeBody> createState() => _HomeBodyState();
}

/// The category list of the current site.
///
/// OBSERVED on the original (2026-11-09, mock sites): switching site shows a spinner while the site's home loads, then
/// grey poster placeholders while the first page of its first category loads; a failed request shows 加载失败 with
/// the reason and 重新加载 under the category tabs; the filters of the selected category are laid out inline above
/// the posters and scroll with them.
/// Before 2026-11-10 UZV kept the previous site's posters when the new site's first category had the same id, showed
/// nothing while a category loaded and dropped category errors silently.
class _HomeBodyState extends ConsumerState<_HomeBody> {
  final List<VodItem> _items = [];
  int _page = 1;
  bool _loading = false;
  bool _done = false;
  Object? _error;

  /// `site|type` of the list in [_items]; changing either starts over.
  String? _loadedFor;
  SpiderSite? _site;
  String? _typeId;

  /// Bumped whenever the list starts over (site, category or a filter changed, 重新加载), so answers to requests of
  /// an older list are dropped.
  int _generation = 0;

  /// Filter values picked per `site|type` (kept while the app runs).
  final Map<String, Map<String, String>> _chosen = {};

  /// The selected category if it is still visible, else the first visible one; null = the site's featured list.
  String? _effectiveType(HomeData home, List<String> blocked) {
    final cats = home.categories.where((c) => !blocked.contains(c.id)).toList();
    final selected = ref.read(selectedTypeIdProvider);
    if (selected != null && cats.any((c) => c.id == selected)) return selected;
    return cats.isEmpty ? null : cats.first.id;
  }

  void _ensureLoaded(String? subKey, SpiderSite site, String? typeId) {
    final key = '${subKey ?? ''}|${site.key}|$typeId';
    if (key == _loadedFor) return;
    _loadedFor = key;
    _site = site;
    _typeId = typeId;
    _restart();
    if (typeId != null) WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
  }

  void _restart() {
    _generation++;
    _items.clear();
    _page = 1;
    _done = false;
    _loading = false;
    _error = null;
  }

  Future<void> _loadMore() async {
    final site = _site;
    final typeId = _typeId;
    if (!mounted || site == null || typeId == null || _loading || _done || _error != null) return;
    final generation = _generation;
    setState(() => _loading = true);
    try {
      final res = await ref.read(videoCategoryFeedProvider)(
          (siteKey: site.key, typeId: typeId, page: _page, filters: _requestFilters()));
      if (!mounted || generation != _generation) return;
      setState(() {
        _items.addAll(res?.items ?? const []);
        _done = res == null || !res.hasMore || res.items.isEmpty;
        _page++;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      if (_items.isEmpty) {
        setState(() => _error = e);
      } else {
        // A later page failed: keep what is shown; scrolling to the end again retries.
        showToast(describeLoadError(e, context.l10n));
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _loading = false);
    }
  }

  /// OBSERVED: 全部 (an empty value) is left out of the request; any other value is sent, even the filter's `init`.
  Map<String, String> _requestFilters() => {
        for (final e in (_chosen[_loadedFor] ?? const <String, String>{}).entries)
          if (e.value.isNotEmpty) e.key: e.value,
      };

  void _reload() {
    setState(_restart);
    _loadMore();
  }

  void _pickFilter(VodFilter f, String value) {
    // Kept even when empty, so 全部 stays selected for a filter whose `init` is something else.
    _chosen.putIfAbsent(_loadedFor ?? '', () => {})[f.key] = value;
    _reload();
  }

  Future<void> _blockCategories(SpiderSite site, HomeData home, HomePrefs prefs) async {
    final l = context.l10n;
    if (home.categories.isEmpty) return showToast(l.homeNoBlockableCategories);
    final blocked = {...prefs.blockedFor(site.key)};
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          title: Text(l.homeBlockCategories),
          contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(shrinkWrap: true, children: [
              for (final cat in home.categories)
                CheckboxListTile(
                  value: blocked.contains(cat.id),
                  title: Text(cat.name),
                  onChanged: (v) => setLocal(() => v == true ? blocked.add(cat.id) : blocked.remove(cat.id)),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: Text(l.cancel)),
            TextButton(onPressed: () => Navigator.pop(c, blocked), child: Text(l.ok)),
          ],
        ),
      ),
    );
    if (result != null) await ref.read(homePrefsProvider.notifier).setBlocked(site.key, result.toList());
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = AppColors.of(context);
    // switching site resets the category; the category provider may also be changed by a script (`switchTab`)
    ref.listen(currentSiteProvider, (_, __) => ref.read(selectedTypeIdProvider.notifier).select(null));
    ref.watch(selectedTypeIdProvider);
    final prefs = ref.watch(homePrefsProvider).valueOrNull ?? const HomePrefs();
    final site = ref.watch(currentSiteProvider);
    final subKey = ref.watch(catpawRuntimeProvider).valueOrNull?.subscription.key;
    final feed = ref.watch(videoFeedProvider);
    final bottom = tabBottomInset(context);
    return feed.when(
      skipLoadingOnRefresh: false,
      skipLoadingOnReload: false,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorState(error: e, bottomInset: bottom, onRetry: () => ref.invalidate(videoFeedProvider)),
      data: (home) {
        if (home == null || site == null) return const SizedBox.shrink();
        final blocked = prefs.blockedFor(site.key);
        final cats = home.categories.where((x) => !blocked.contains(x.id)).toList();
        final typeId = _effectiveType(home, blocked);
        _ensureLoaded(subKey, site, typeId);
        final selected = cats.where((x) => x.id == typeId).firstOrNull;
        final filters = selected != null && selected.filters.isNotEmpty && !prefs.hideFilters
            ? CategoryFilterBar(
                filters: selected.filters, chosen: _chosen[_loadedFor] ?? const {}, onChanged: _pickFilter)
            : null;
        final Widget list;
        if (typeId == null) {
          list = prefs.listLayout
              ? VodList(items: home.featured, bottomInset: bottom)
              : VodGrid(items: home.featured, bottomInset: bottom);
        } else if (_items.isEmpty && _error != null) {
          list = filters == null
              ? ErrorState(error: _error!, bottomInset: bottom, onRetry: _reload)
              : ListView(children: [
                  filters,
                  SizedBox(height: 380, child: ErrorState(error: _error!, onRetry: _reload)),
                ]);
        } else if (_items.isEmpty && !_done) {
          list = VodSkeletonGrid(header: filters, bottomInset: bottom);
        } else if (_items.isEmpty) {
          final empty = EmptyState(icon: Icons.search_off, title: l.noData, subtitle: l.nothingHere);
          list = filters == null ? empty : ListView(children: [filters, SizedBox(height: 380, child: empty)]);
        } else {
          final footer = _loading
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child:
                      Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))))
              : null;
          list = prefs.listLayout
              ? VodList(items: _items, onNearEnd: _loadMore, bottomInset: bottom, header: filters, footer: footer)
              : VodGrid(items: _items, onNearEnd: _loadMore, bottomInset: bottom, header: filters, footer: footer);
        }
        return Column(children: [
          SizedBox(
            height: 46,
            child: Row(children: [
              Expanded(
                child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    children: [
                      for (final VodCategory cat in cats)
                        _CategoryTab(
                          label: cat.name,
                          selected: cat.id == typeId,
                          onTap: () => ref.read(selectedTypeIdProvider.notifier).select(cat.id),
                        ),
                    ]),
              ),
              Container(width: 0.8, height: 26, color: c.separator),
              PopupMenuButton<String>(
                icon: const Icon(Icons.tune),
                position: PopupMenuPosition.under,
                onSelected: (v) => switch (v) {
                  'block' => _blockCategories(site, home, prefs),
                  'filters' => ref.read(homePrefsProvider.notifier).toggleFilters(),
                  _ => ref.read(homePrefsProvider.notifier).toggleLayout(),
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'block', child: _MenuRow(Icons.block, l.homeBlockCategories)),
                  PopupMenuItem(
                    value: 'filters',
                    child:
                        _MenuRow(Icons.filter_alt_outlined, prefs.hideFilters ? l.homeShowFilters : l.homeHideFilters),
                  ),
                  PopupMenuItem(value: 'layout', child: _MenuRow(Icons.grid_view, l.homeSwitchLayout)),
                ],
              ),
            ]),
          ),
          Divider(height: 0.6, color: c.separator),
          Expanded(child: list),
        ]);
      },
    );
  }
}

class _CategoryTab extends StatelessWidget {
  const _CategoryTab({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const SizedBox(height: 4),
          Text(label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
                color: selected ? AppColors.of(context).accent : c.label.withValues(alpha: 0.85),
              )),
          const SizedBox(height: 5),
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: selected ? 18 : 0,
            height: 3,
            decoration: BoxDecoration(color: AppColors.of(context).accent, borderRadius: BorderRadius.circular(2)),
          ),
        ]),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(children: [Icon(icon, size: 20), const SizedBox(width: 12), Text(text)]);
}
