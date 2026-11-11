import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../app/theme.dart';
import '../features/search/search_state.dart';
import '../l10n/l10n.dart';
import '../models/vod.dart';
import 'app_shell.dart';
import 'load_error.dart';
import 'widgets.dart';

// OBSERVED on the phone (UZN 1.1.7, 2026-11-10; sizes in dp at the phone's font scale 0.86, colours sampled):
// - top bar: 搜索, then two accent icons: 站点搜索管理 (manage_search, opens a sheet) and 切换布局 (a menu 列表 /
//   顶部站点分类 / 左侧站点分类 with a check on the current one; the button shows the current layout's icon).
// - the search card (16 from the edges), then 搜索历史 with a clear button and the keywords as chips; clearing the field
//   comes back to the history (changelog 1.1.2 "搜索清空输入框即回到搜索历史区").
// - results come in site by site; only sites with results are listed, in the order they answered, with their count.
//   列表: every result in one list. 顶部站点分类: a scrollable tab per site, "「直」直播 (1)". 左侧站点分类: a 104 wide
//   site column (name, count under it; the current one tinted with an accent bar on the left) and its results.
// - a result is a 104 high card: 64×88 poster, the title (bold, 2 lines), vod_remarks in the accent colour (OBSERVED
//   raw answer: `{"vod_remarks":"YY · zonghe"}` shows as "YY · zonghe"), and the site name in a tinted tag.
// - 站点搜索管理: a sheet with a drag handle, the title, a 双列视图 button and one row per site; a site that searches
//   is tinted with an accent border, one that does not is plain with a crossed-out search icon. Switching a site
//   searches again at once.

/// Material 3 colours the original uses as they are (the app theme maps some of them to its own card colours).
ColorScheme _m3(BuildContext context) =>
    ColorScheme.fromSeed(seedColor: AppColors.of(context).accent, brightness: Theme.of(context).brightness);

/// OBSERVED 36 wide buttons (站点搜索管理 in the top bar, 双列视图 in the sheet).
final _compact36 = IconButton.styleFrom(
    minimumSize: const Size(36, 36),
    maximumSize: const Size(36, 36),
    padding: EdgeInsets.zero,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap);

IconData _layoutIcon(SearchLayout l) => switch (l) {
      SearchLayout.list => Icons.view_agenda_rounded,
      SearchLayout.top => Icons.view_day_rounded,
      SearchLayout.left => Icons.view_sidebar_rounded,
    };

/// `/search` and the 搜索 tab.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key, this.initialQuery = ''});
  final String initialQuery;
  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  late final TextEditingController _controller = TextEditingController(text: widget.initialQuery);
  // Own node: FocusScope.unfocus() left the field as the page's last focused child, so closing the layout menu or the
  // site sheet focused it again and opened the keyboard (phone, 2026-11-10).
  final FocusNode _focus = FocusNode();
  SearchRun? _run;
  List<String> _history = const [];
  String? _leftSite; // 左侧站点分类: the key of the site shown

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onText);
    ref.read(searchHistoryRepositoryProvider).all().then((h) {
      if (mounted) setState(() => _history = h);
    });
    if (widget.initialQuery.trim().isNotEmpty) _search(widget.initialQuery);
  }

  @override
  void dispose() {
    _run?.dispose();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// An emptied field goes back to the history.
  void _onText() {
    if (_controller.text.isEmpty && _run != null) {
      setState(() {
        _run!.dispose();
        _run = null;
      });
    }
  }

  void _submit() {
    final k = _controller.text.trim();
    if (k.isEmpty) return;
    _focus.unfocus();
    _search(k);
  }

  Future<void> _search(String keyword) async {
    final k = keyword.trim();
    ref.read(searchHistoryRepositoryProvider).add(k).then((h) {
      if (mounted) setState(() => _history = h);
    });
    final rt = await ref.read(catpawRuntimeProvider.future);
    final prefs = await ref.read(searchPrefsProvider.future);
    if (!mounted) return;
    final sites = [for (final s in ref.read(searchableSitesProvider)) if (!prefs.sitesOff.contains(s.key)) s];
    final run = SearchRun(keyword: k, sites: sites, api: rt?.api);
    run.addListener(() {
      if (mounted && identical(run, _run)) setState(() {});
    });
    setState(() {
      _run?.dispose();
      _run = run;
      _leftSite = null;
    });
  }

  Future<void> _clearHistory() async {
    final l = context.l10n;
    final ok = await confirmAction(context,
        title: l.searchHistoryClear,
        message: l.searchHistoryClearConfirm,
        confirmLabel: l.searchHistoryClear,
        destructive: true);
    if (!ok) return;
    await ref.read(searchHistoryRepositoryProvider).clear();
    if (mounted) setState(() => _history = const []);
  }

  Future<void> _openSites() async {
    final m3 = _m3(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useRootNavigator: true,
      requestFocus: false,
      backgroundColor: m3.surfaceContainerLow,
      builder: (_) => _SiteSheet(onToggled: () {
        final run = _run;
        if (run != null) _search(run.keyword);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = AppColors.of(context);
    final layout = ref.watch(searchPrefsProvider).valueOrNull?.layout ?? SearchLayout.left;
    return Scaffold(
      appBar: AppBar(title: Text(l.search), actions: [
        IconButton(
          tooltip: l.searchSiteManager,
          style: _compact36,
          icon: Icon(Icons.manage_search_rounded, size: 22, color: c.accent),
          onPressed: _openSites,
        ),
        PopupMenuButton<SearchLayout>(
          tooltip: l.searchSwitchLayout,
          icon: Icon(_layoutIcon(layout), size: 21, color: c.accent),
          position: PopupMenuPosition.under,
          offset: const Offset(0, 5), // OBSERVED: the menu's top 5 lower than here by default
          requestFocus: false,
          color: _m3(context).surfaceContainer,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          onSelected: (v) => ref.read(searchPrefsProvider.notifier).setLayout(v),
          itemBuilder: (_) => [
            for (final (v, label) in [
              (SearchLayout.list, l.searchLayoutList),
              (SearchLayout.top, l.searchLayoutTop),
              (SearchLayout.left, l.searchLayoutLeft),
            ])
              PopupMenuItem(
                value: v,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(_layoutIcon(v), size: 20, color: c.label),
                  const SizedBox(width: 12),
                  Text(label, style: TextStyle(fontSize: 14, color: c.label)),
                  if (v == layout) ...[
                    const SizedBox(width: 14),
                    Icon(Icons.check_rounded, size: 20, color: c.accent),
                  ],
                ]),
              ),
          ],
        ),
      ]),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _searchCard(context),
        Expanded(child: _run == null ? _historyView(context) : _results(context, _run!, layout)),
      ]),
    );
  }

  Widget _searchCard(BuildContext context) {
    final l = context.l10n;
    final c = AppColors.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11.5),
      decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        Expanded(
          child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _controller,
            builder: (context, value, _) => TextField(
              controller: _controller,
              focusNode: _focus,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                hintText: l.searchHint,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 9.5),
                prefixIconConstraints: const BoxConstraints(minWidth: 46, minHeight: 41),
                suffixIconConstraints: const BoxConstraints(minWidth: 44, minHeight: 41),
                // OBSERVED: a white search icon; the paste button is Cupertino's doc_on_clipboard (the original ships
                // CupertinoIcons cut down to a few glyphs), the clear button a filled cancel, both in onSurfaceVariant.
                prefixIcon: Icon(Icons.search,
                    size: 24, color: Theme.of(context).brightness == Brightness.dark ? Colors.white : c.label),
                suffixIcon: IconButton(
                  tooltip: value.text.isEmpty ? l.paste : null,
                  style: IconButton.styleFrom(
                      minimumSize: const Size(44, 41),
                      padding: EdgeInsets.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  icon: Icon(value.text.isEmpty ? CupertinoIcons.doc_on_clipboard : Icons.cancel,
                      size: 21, color: c.subtitle),
                  onPressed: value.text.isEmpty
                      ? () async {
                          final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
                          if (text != null && text.isNotEmpty) _controller.text = text;
                        }
                      : _controller.clear,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          style: FilledButton.styleFrom(
              shape: const StadiumBorder(),
              minimumSize: const Size(64, 39),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              // a 48 high tap target made the card 7 taller than the original's 64
              tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          onPressed: _submit,
          child: Text(l.search),
        ),
      ]),
    );
  }

  Widget _historyView(BuildContext context) {
    final l = context.l10n;
    final c = AppColors.of(context);
    if (_history.isEmpty) return EmptyState(icon: Icons.search, title: l.searchEmptyTitle, subtitle: l.searchPrompt);
    return ListView(padding: EdgeInsets.only(bottom: 16 + tabBottomInset(context)), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 13, 10, 0),
        child: SizedBox(
          height: 48,
          child: Row(children: [
            Expanded(
                child: Text(l.searchHistory,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.label))),
            IconButton(
              tooltip: l.searchHistoryClear,
              icon: Icon(Icons.delete_sweep_rounded, size: 21, color: c.label),
              onPressed: _clearHistory,
            ),
          ]),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          for (final k in _history)
            Material(
              color: c.cardHigh,
              shape: const StadiumBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () {
                  _controller.text = k;
                  _focus.unfocus();
                  _search(k);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  child: Text(k, style: TextStyle(fontSize: 13, color: c.label)),
                ),
              ),
            ),
        ]),
      ),
    ]);
  }

  Widget _results(BuildContext context, SearchRun run, SearchLayout layout) {
    final l = context.l10n;
    final c = AppColors.of(context);
    final results = run.results;
    if (results.isEmpty) {
      if (!run.done) {
        // INFERRED: what shows before the first site answers (the original's 搜索中… was not caught on screen).
        return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 14),
          Text(l.searchSearching, style: TextStyle(fontSize: 14, color: c.secondaryLabel)),
          SizedBox(height: 60 + tabBottomInset(context)),
        ]);
      }
      final error = run.error;
      if (error != null) {
        return EmptyState(
          icon: Icons.error_outline,
          color: AppColors.dangerText(context),
          title: l.searchFailed(describeLoadError(error, l)),
          bottomInset: tabBottomInset(context),
        );
      }
      return EmptyState(
          icon: Icons.search_off,
          title: run.total == 0 ? l.searchNoSites : l.noResults,
          bottomInset: tabBottomInset(context));
    }
    final body = switch (layout) {
      // OBSERVED: the first card 22 below the search card (16 + its own 6)
      SearchLayout.list => _cards(context, [for (final r in results) for (final i in r.items) (i, r.site.name)],
          const EdgeInsets.fromLTRB(12, 0, 12, 0)),
      SearchLayout.top => _TopTabs(results: results, cards: (r) => _siteCards(context, r)),
      SearchLayout.left => _leftView(context, results),
    };
    // No progress bar while other sites are still answering: none was seen on the original; its list just grows.
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 16),
      Expanded(child: body),
    ]);
  }

  Widget _siteCards(BuildContext context, SiteResults r) =>
      _cards(context, [for (final i in r.items) (i, r.site.name)], const EdgeInsets.fromLTRB(12, 8, 12, 0));

  Widget _cards(BuildContext context, List<(VodItem, String)> items, EdgeInsets padding) => ListView.builder(
        padding: padding.copyWith(bottom: 12 + tabBottomInset(context)),
        itemCount: items.length,
        itemBuilder: (context, i) => SearchResultCard(item: items[i].$1, siteName: items[i].$2),
      );

  Widget _leftView(BuildContext context, List<SiteResults> results) {
    final current = results.firstWhere((r) => r.site.key == _leftSite, orElse: () => results.first);
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        width: 104,
        child: ListView(padding: EdgeInsets.only(bottom: tabBottomInset(context)), children: [
          for (final r in results)
            _SiteColumnItem(
              results: r,
              selected: identical(r, current),
              onTap: () => setState(() => _leftSite = r.site.key),
            ),
        ]),
      ),
      VerticalDivider(width: 1, thickness: 1, color: _m3(context).outlineVariant),
      Expanded(
        child: KeyedSubtree(
          key: ValueKey(current.site.key),
          child: _cards(context, [for (final i in current.items) (i, current.site.name)],
              const EdgeInsets.fromLTRB(8, 8, 12, 0)),
        ),
      ),
    ]);
  }
}

/// One result. OBSERVED sizes: 104 high, 8 inside, a 64×88 poster with rounded corners, 12 apart.
class SearchResultCard extends StatelessWidget {
  const SearchResultCard({super.key, required this.item, required this.siteName});
  final VodItem item;
  final String siteName;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final remarks = item.remarks?.trim() ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Material(
        color: c.card,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => openVod(context, item),
          child: SizedBox(
            height: 104,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(width: 64, height: 88, child: vodPoster(item))),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(item.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.label)),
                    if (remarks.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(remarks,
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.accent)),
                    ],
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                          color: c.accent.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)),
                      child: Text(siteName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: c.accent)),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// 左侧站点分类: one site in the column. OBSERVED: 55 high, the name over the count; the current one has a 10 % accent
/// background, a 3 wide accent bar on the left and its name in the accent colour.
class _SiteColumnItem extends StatelessWidget {
  const _SiteColumnItem({required this.results, required this.selected, required this.onTap});
  final SiteResults results;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Material(
      color: selected ? c.accent.withValues(alpha: 0.1) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 55,
          decoration: selected ? BoxDecoration(border: Border(left: BorderSide(color: c.accent, width: 3))) : null,
          padding: EdgeInsets.only(left: selected ? 11 : 14, right: 6),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(results.site.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? c.accent : c.label)),
            const SizedBox(height: 2),
            Text('${results.items.length}', style: TextStyle(fontSize: 12, color: c.subtitle)),
          ]),
        ),
      ),
    );
  }
}

/// 顶部站点分类: Material 3 scrollable tabs (OBSERVED: accent label and 3 high rounded indicator under the current one,
/// the others in onSurfaceVariant, an outlineVariant line under the bar); swiping moves between sites.
class _TopTabs extends StatelessWidget {
  const _TopTabs({required this.results, required this.cards});
  final List<SiteResults> results;
  final Widget Function(SiteResults r) cards;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final m3 = _m3(context);
    return DefaultTabController(
      length: results.length,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          padding: EdgeInsets.zero,
          labelPadding: const EdgeInsets.symmetric(horizontal: 16),
          dividerColor: m3.outlineVariant,
          labelColor: AppColors.of(context).accent,
          unselectedLabelColor: m3.onSurfaceVariant,
          labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          unselectedLabelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w400),
          tabs: [for (final r in results) Tab(text: l.searchSiteTab(r.site.name, r.items.length))],
        ),
        Expanded(child: TabBarView(children: [for (final r in results) cards(r)])),
      ]),
    );
  }
}

/// 站点搜索管理.
class _SiteSheet extends ConsumerWidget {
  const _SiteSheet({required this.onToggled});
  final VoidCallback onToggled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final c = AppColors.of(context);
    final sites = ref.watch(searchableSitesProvider);
    final prefs = ref.watch(searchPrefsProvider).valueOrNull ?? const SearchPrefs();
    Widget tile(int i) {
      final s = sites[i];
      return _SiteTile(
        name: s.name,
        on: !prefs.sitesOff.contains(s.key),
        onTap: () async {
          await ref.read(searchPrefsProvider.notifier).toggleSite(s.key);
          onToggled();
        },
      );
    }

    final bottom = 16 + MediaQuery.paddingOf(context).bottom;
    return ConstrainedBox(
      // OBSERVED: the sheet (drag handle included) is about two thirds of the screen
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.62),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 16, 0),
          child: Row(children: [
            Expanded(
                child: Text(l.searchSiteManager,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c.label))),
            IconButton(
              tooltip: prefs.sitesGrid ? l.searchOneColumn : l.searchTwoColumns,
              style: _compact36,
              icon: Icon(prefs.sitesGrid ? Icons.view_agenda_rounded : Icons.grid_view_rounded,
                  size: 20, color: c.label),
              onPressed: () => ref.read(searchPrefsProvider.notifier).toggleGrid(),
            ),
          ]),
        ),
        if (sites.isEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(20, 24, 20, bottom + 16),
            child: Text(l.searchNoSites, textAlign: TextAlign.center, style: TextStyle(color: c.secondaryLabel)),
          )
        else
          Flexible(
            child: prefs.sitesGrid
                // INFERRED: 双列视图 was not opened on the original (it changes a preference there).
                ? GridView.builder(
                    shrinkWrap: true,
                    padding: EdgeInsets.fromLTRB(20, 20, 20, bottom),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2, mainAxisExtent: 46, crossAxisSpacing: 8, mainAxisSpacing: 6),
                    itemCount: sites.length,
                    itemBuilder: (_, i) => tile(i),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    padding: EdgeInsets.fromLTRB(20, 20, 20, bottom),
                    itemCount: sites.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (_, i) => SizedBox(height: 46, child: tile(i)),
                  ),
          ),
      ]),
    );
  }
}

/// OBSERVED: on = 15 % accent fill, 45 % accent border, accent search icon and bold accent name; off = no fill, a faint
/// border, a grey crossed-out search icon and the name in the text colour.
class _SiteTile extends StatelessWidget {
  const _SiteTile({required this.name, required this.on, required this.onTap});
  final String name;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: BorderSide(color: on ? c.accent.withValues(alpha: 0.45) : c.label.withValues(alpha: 0.04)),
    );
    return Material(
      color: on ? c.accent.withValues(alpha: 0.15) : Colors.transparent,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Icon(on ? Icons.search_rounded : Icons.search_off_rounded,
                size: 18, color: on ? c.accent : c.subtitle.withValues(alpha: 0.5)),
            const SizedBox(width: 11),
            Expanded(
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                      color: on ? c.accent : c.label)),
            ),
          ]),
        ),
      ),
    );
  }
}
