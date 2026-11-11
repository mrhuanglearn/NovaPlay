import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/app_preferences.dart';
import '../app/theme.dart';
import '../app/ui_hooks.dart';
import '../core/haptics.dart';
import '../l10n/l10n.dart';

/// Shell path of each [HomeTab]; the router has one branch per tab, in [HomeTab.values] order. The optional tabs'
/// paths are this project's (the original's were not recovered).
String homeTabPath(HomeTab tab) => switch (tab) {
      HomeTab.home => '/',
      HomeTab.live => '/live',
      HomeTab.calendar => '/calendar',
      HomeTab.library => '/library',
      HomeTab.settings => '/settings',
      HomeTab.mediaServer => '/tab/media-server',
      HomeTab.favorites => '/tab/favorites',
      HomeTab.history => '/tab/history',
      HomeTab.downloads => '/tab/downloads',
      HomeTab.search => '/tab/search',
    };

/// Outlined and selected icon of each tab (OBSERVED shapes on the bar and on 主页页面).
(IconData, IconData) homeTabIcons(HomeTab tab) => switch (tab) {
      HomeTab.home => (Icons.home_outlined, Icons.home_rounded),
      HomeTab.live => (Icons.live_tv_outlined, Icons.live_tv_rounded),
      HomeTab.calendar => (Icons.calendar_month_outlined, Icons.calendar_month_rounded),
      HomeTab.library => (Icons.video_library_outlined, Icons.video_library_rounded),
      HomeTab.settings => (Icons.settings_outlined, Icons.settings_rounded),
      HomeTab.mediaServer => (Icons.dns_outlined, Icons.dns_rounded),
      HomeTab.favorites => (Icons.favorite_border_rounded, Icons.favorite_rounded),
      HomeTab.history => (Icons.history_rounded, Icons.history_rounded),
      HomeTab.downloads => (Icons.download_outlined, Icons.download_rounded),
      HomeTab.search => (Icons.search_rounded, Icons.search_rounded),
    };

String homeTabLabel(AppLocalizations l, HomeTab tab) => switch (tab) {
      HomeTab.home => l.tabHome,
      HomeTab.live => l.tabLive,
      HomeTab.calendar => l.tabCalendar,
      HomeTab.library => l.tabLibrary,
      HomeTab.settings => l.tabSettings,
      HomeTab.mediaServer => l.settingsMediaServer,
      HomeTab.favorites => l.libraryFavorites,
      HomeTab.history => l.libraryHistory,
      HomeTab.downloads => l.libraryDownloads,
      HomeTab.search => l.search,
    };

/// The top-level tabs with the original's floating, blurred pill navigation bar (OBSERVED default order: 首页, 直播,
/// 追剧日历, 媒体库, 设置; the selected tab gets a grey pill and an accent icon). Which tabs show and in what order
/// comes from 设置 → 主页页面 ([AppPreferences.homeTabs]); OBSERVED with all ten enabled, the bar squeezes them into
/// one row. Back on any tab root first shows "再按一次返回键退出应用" and only a second press within two seconds
/// leaves the app (OBSERVED on Waydroid).
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  static const barHeight = 64.0;
  static const barMargin = EdgeInsets.fromLTRB(18, 0, 18, 10);

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  DateTime? _lastBack;

  void _onBack() {
    final now = DateTime.now();
    if (_lastBack != null && now.difference(_lastBack!) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
      return;
    }
    _lastBack = now;
    showToast(context.l10n.pressBackAgainToExit, duration: const Duration(seconds: 2));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final tabs = ref.watch(appPreferencesProvider.select((p) => p.homeTabs));
    final items = [
      for (final t in tabs) (homeTabIcons(t).$1, homeTabIcons(t).$2, homeTabLabel(l, t)),
    ];
    // Branch indexes follow HomeTab.values; the bar shows the enabled tabs in the user's order.
    final current = HomeTab.values[widget.shell.currentIndex];
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
        extendBody: true,
        body: widget.shell,
        bottomNavigationBar: _FloatingNavBar(
          items: items,
          index: tabs.indexOf(current),
          onTap: (i) {
            final branch = tabs[i].index;
            widget.shell.goBranch(branch, initialLocation: branch == widget.shell.currentIndex);
          },
        ),
      ),
    );
  }
}

class _FloatingNavBar extends StatelessWidget {
  const _FloatingNavBar({required this.items, required this.index, required this.onTap});
  final List<(IconData, IconData, String)> items;
  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: AppShell.barMargin,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppShell.barHeight / 2),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              height: AppShell.barHeight,
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: c.navBar,
                borderRadius: BorderRadius.circular(AppShell.barHeight / 2),
                border: Border.all(color: c.separator, width: 0.8),
              ),
              child: LayoutBuilder(builder: (context, box) {
                // 26 dp icons for the usual five tabs; smaller once more tabs share the row (OBSERVED with ten)
                final iconSize = (box.maxWidth / items.length * 0.6).clamp(16.0, 26.0);
                return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (var i = 0; i < items.length; i++)
                    Expanded(
                      child: Semantics(
                        label: items[i].$3,
                        selected: i == index,
                        button: true,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            AppHaptics.selection();
                            onTap(i);
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            decoration: BoxDecoration(
                              color: i == index ? c.navSelected : Colors.transparent,
                              borderRadius: BorderRadius.circular(AppShell.barHeight / 2),
                            ),
                            child: Icon(
                              i == index ? items[i].$2 : items[i].$1,
                              size: iconSize,
                              color: i == index ? AppColors.of(context).accent : c.label.withValues(alpha: 0.75),
                            ),
                          ),
                        ),
                      ),
                    ),
                ]);
              }),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom padding a scroll view on a tab root needs so its last rows can scroll clear of the floating bar. Inside the
/// shell's body (extendBody) MediaQuery's bottom padding already includes the bar.
double tabBottomInset(BuildContext context) => MediaQuery.paddingOf(context).bottom + 12;
