import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/app_lock.dart';
import '../app/providers.dart';
import '../app/site_prefs.dart';
import '../app/theme.dart';
import '../features/catpaw/spider_api.dart';
import '../features/search/search_state.dart';
import '../l10n/l10n.dart';
import 'lock_dialogs.dart';

final _compact40 = IconButton.styleFrom(
    minimumSize: const Size(40, 40),
    maximumSize: const Size(40, 40),
    padding: EdgeInsets.zero,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap);

/// The home page's 切换站点 sheet and its 站点设置 page.
///
/// OBSERVED on the phone (UZN, 2026-11-13): 切换站点 has three buttons at the top right — 单列 / 双列 (the two-column
/// form shows a radio circle before each name, a tick on the current site), a globe that opens the subscription's web
/// page (CatPawPlay 首页) and a gear that turns the sheet into 站点设置. 站点设置 has ✓ at the top right (back to 切换站点)
/// and, while a site is locked, a padlock before it that opens / closes the lock. See `site_prefs.dart`.
/// Before 2026-11-13 UZV's sheet had none of these buttons.
class SiteSwitchSheet extends ConsumerStatefulWidget {
  const SiteSwitchSheet({super.key, required this.pageContext});

  /// The home page's context, for opening the web page once the sheet is closed.
  final BuildContext pageContext;

  static const gridToggleKey = ValueKey('siteSheetGridToggle');
  static const websiteKey = ValueKey('siteSheetWebsite');
  static const settingsKey = ValueKey('siteSheetSettings');
  static const doneKey = ValueKey('siteSheetDone');
  static const lockKey = ValueKey('siteSheetLock');

  @override
  ConsumerState<SiteSwitchSheet> createState() => _SiteSwitchSheetState();
}

class _SiteSwitchSheetState extends ConsumerState<SiteSwitchSheet> {
  bool _settings = false;

  void _openWebsite() {
    final rt = ref.read(catpawRuntimeProvider).valueOrNull;
    if (rt == null) return;
    final url = '${rt.api.baseUrl}/website';
    Navigator.pop(context);
    final page = widget.pageContext;
    if (page.mounted) page.push(Uri(path: '/website', queryParameters: {'url': url}).toString());
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = AppColors.of(context);
    final prefs = ref.watch(sitePrefsProvider).valueOrNull ?? const SitePrefs();
    final unlocked = ref.watch(sitesUnlockedProvider);
    final hasLocked = ref.watch(homeSitesProvider).any((s) => prefs.isLocked(s.key));
    final actions = _settings
        ? [
            if (hasLocked)
              IconButton(
                key: SiteSwitchSheet.lockKey,
                tooltip: unlocked ? l.lockRelock : l.homeSiteUnlock,
                style: _compact40,
                icon: Icon(unlocked ? Icons.lock_open_outlined : Icons.lock, size: 22, color: c.label),
                onPressed: () => unlocked
                    ? ref.read(subscriptionsUnlockedProvider.notifier).relock()
                    : unlockSubscriptions(context, ref),
              ),
            IconButton(
              key: SiteSwitchSheet.doneKey,
              tooltip: l.done,
              style: _compact40,
              icon: Icon(Icons.check, size: 24, color: c.label),
              onPressed: () => setState(() => _settings = false),
            ),
          ]
        : [
            IconButton(
              key: SiteSwitchSheet.gridToggleKey,
              tooltip: prefs.grid ? l.searchOneColumn : l.searchTwoColumns,
              style: _compact40,
              icon: Icon(prefs.grid ? Icons.view_agenda_rounded : Icons.grid_view_rounded, size: 22, color: c.label),
              onPressed: () => ref.read(sitePrefsProvider.notifier).toggleGrid(),
            ),
            IconButton(
              key: SiteSwitchSheet.websiteKey,
              tooltip: l.homeSiteWebsite,
              style: _compact40,
              icon: Icon(Icons.language, size: 22, color: c.label),
              onPressed: _openWebsite,
            ),
            IconButton(
              key: SiteSwitchSheet.settingsKey,
              tooltip: l.homeSiteSettings,
              style: _compact40,
              icon: Icon(Icons.settings, size: 22, color: c.label),
              onPressed: () => setState(() => _settings = true),
            ),
          ];
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.62),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 12),
            child: Row(children: [
              Expanded(
                child: Text(_settings ? l.homeSiteSettings : l.homeSwitchSite,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c.label)),
              ),
              for (final a in actions) Padding(padding: const EdgeInsets.only(left: 6), child: a),
            ]),
          ),
          Flexible(child: _settings ? const _SiteSettingsList() : _SiteChoiceList(grid: prefs.grid)),
        ]),
      ),
    );
  }
}

class _SiteChoiceList extends ConsumerWidget {
  const _SiteChoiceList({required this.grid});
  final bool grid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sites = ref.watch(visibleHomeSitesProvider);
    final current = ref.watch(currentSiteProvider);
    void pick(SpiderSite s) {
      ref.read(selectedHomeSiteProvider.notifier).select(s.key);
      Navigator.pop(context);
    }

    if (grid) {
      return GridView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2, mainAxisExtent: 52, crossAxisSpacing: 12, mainAxisSpacing: 10),
        itemCount: sites.length,
        itemBuilder: (_, i) => _SiteChoiceTile(
            site: sites[i], selected: sites[i].key == current?.key, grid: true, onTap: () => pick(sites[i])),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: sites.length,
      itemBuilder: (_, i) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _SiteChoiceTile(
            site: sites[i], selected: sites[i].key == current?.key, grid: false, onTap: () => pick(sites[i])),
      ),
    );
  }
}

class _SiteChoiceTile extends StatelessWidget {
  const _SiteChoiceTile({required this.site, required this.selected, required this.grid, required this.onTap});
  final SpiderSite site;
  final bool selected;
  final bool grid;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final accent = c.accent;
    return Material(
      color: selected ? accent.withValues(alpha: 0.16) : c.cardHigh.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: selected ? accent.withValues(alpha: 0.6) : Colors.transparent),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: grid ? 12 : 16, vertical: 13),
          child: Row(children: [
            if (grid) ...[
              Icon(selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: 20, color: selected ? accent : c.secondaryLabel),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(site.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                    color: selected ? accent : c.label,
                  )),
            ),
            if (selected && !grid)
              Container(width: 7, height: 7, decoration: BoxDecoration(color: accent, shape: BoxShape.circle)),
          ]),
        ),
      ),
    );
  }
}

class _SiteSettingsList extends ConsumerWidget {
  const _SiteSettingsList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final sites = ref.watch(settingsSitesProvider);
    final prefs = ref.watch(sitePrefsProvider).valueOrNull ?? const SitePrefs();
    final search = ref.watch(searchPrefsProvider).valueOrNull ?? const SearchPrefs();
    final notifier = ref.read(sitePrefsProvider.notifier);
    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: sites.length,
      itemBuilder: (_, i) {
        final s = sites[i];
        final locked = prefs.isLocked(s.key);
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _SiteSettingsRow(name: s.name, switches: [
            _Switch(
                tooltip: l.homeSiteEnable,
                on: prefs.enabled(s.key),
                onIcon: Icons.visibility,
                offIcon: Icons.visibility_off,
                onTap: () => notifier.toggleEnabled(s.key)),
            _Switch(
                tooltip: l.search,
                on: !search.sitesOff.contains(s.key),
                onIcon: Icons.search,
                offIcon: Icons.search,
                onTap: () => ref.read(searchPrefsProvider.notifier).toggleSite(s.key)),
            _Switch(
                tooltip: l.homeSiteHistory,
                on: prefs.recordsHistory(s.key),
                onIcon: Icons.history,
                offIcon: Icons.history,
                onTap: () => notifier.toggleHistory(s.key)),
            _Switch(
                tooltip: l.subscriptionLock,
                on: locked,
                onIcon: Icons.lock,
                offIcon: Icons.lock_open_outlined,
                onTap: () async {
                  if (!locked && !await confirmFirstLock(context, ref)) return;
                  await notifier.setLocked(s.key, !locked);
                }),
          ]),
        );
      },
    );
  }
}

class _Switch {
  const _Switch(
      {required this.tooltip, required this.on, required this.onIcon, required this.offIcon, required this.onTap});
  final String tooltip;
  final bool on;
  final IconData onIcon;
  final IconData offIcon;
  final VoidCallback onTap;
}

/// OBSERVED: a pale rounded row, the name in bold and four icons; on = accent, off = grey.
class _SiteSettingsRow extends StatelessWidget {
  const _SiteSettingsRow({required this.name, required this.switches});
  final String name;
  final List<_Switch> switches;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      decoration: BoxDecoration(
        color: c.cardHigh.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.label.withValues(alpha: 0.04)),
      ),
      child: Row(children: [
        Expanded(
          child: Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: c.label)),
        ),
        for (final s in switches)
          IconButton(
            tooltip: s.tooltip,
            style: _compact40,
            icon: Icon(s.on ? s.onIcon : s.offIcon,
                size: 22, color: s.on ? c.accent : c.secondaryLabel.withValues(alpha: 0.55)),
            onPressed: s.onTap,
          ),
      ]),
    );
  }
}
