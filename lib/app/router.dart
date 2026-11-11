import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../l10n/l10n.dart';
import '../ui/app_shell.dart';
import '../ui/category_screen.dart';
import '../ui/catpaw_debug_screen.dart';
import '../ui/detail_screen.dart';
import '../ui/downloads_tab.dart';
import '../ui/emby_screens.dart';
import '../ui/home_screen.dart';
import '../ui/library_screen.dart';
import '../ui/live_screens.dart';
import '../ui/player_settings_screens.dart';
import '../ui/preference_screens.dart';
import '../ui/service_settings_screens.dart';
import '../ui/search_screen.dart';
import '../ui/settings_screens.dart';
import '../ui/subscriptions_screen.dart';
import '../ui/tmdb_screens.dart';
import '../ui/web_screens.dart';
import 'app_preferences.dart';

/// Route table. OBSERVED paths in the original: /search, /video/detail, /video/sub-category, /library (+ /favorite,
/// /history, /downloads), /tracking/manage, /live/settings, /live/sources/edit, /live/blocked-categories,
/// /emby/accounts[/edit], /emby/search, /emby/detail, /emby/favorites, /settings (+ /backup, /changelog, /danmu,
/// /feature, /home-tabs, /language, /player, /theme, /tmdb, /webdav[/config]), /subscriptions[/add|/edit/:subKey],
/// /sniffer/web, /tmdb/search, /website, /debug, /cache, /check.
/// Unimplemented paths from that list: /settings/changelog, /cache, /check, /debug,
/// /subscriptions/edit/:subKey, /library/{favorite,history,downloads} as separate pages (they are tabs of /library here).
///
/// The tab roots live in a [StatefulShellRoute] under the floating navigation bar, one branch per [HomeTab] in that
/// enum's order: /, /live, /calendar, /library, /settings, then the optional tabs of 设置 → 主页页面 under /tab/…
/// (`/calendar` and /tab/… are this project's paths; the original's were not recovered). The bar shows only the
/// enabled ones; the app opens on the first enabled tab (inferred). Every other page is pushed on the root navigator,
/// full screen without the bar, as in the original. Tab roots must be reached with `go`, never `push`.
final rootNavigatorKey = GlobalKey<NavigatorState>();

final routerProvider = Provider<GoRouter>((ref) {
  // Read once: the router is built at start-up and must not be rebuilt when the tab list changes.
  final firstTab = ref.read(appPreferencesProvider).homeTabs.first;
  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: homeTabPath(firstTab),
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (c, s, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/', builder: (c, s) => const HomeScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/live', builder: (c, s) => const LiveScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/calendar', builder: (c, s) => const CalendarScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/library', builder: (c, s) => const LibraryScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/settings', builder: (c, s) => const SettingsIndexScreen())]),
          StatefulShellBranch(
            routes: [
              GoRoute(path: homeTabPath(HomeTab.mediaServer), builder: (c, s) => const EmbyAccountsScreen(asTab: true))
            ],
          ),
          StatefulShellBranch(routes: [
            GoRoute(
              path: homeTabPath(HomeTab.favorites),
              builder: (c, s) => LibrarySectionScreen(title: c.l10n.libraryFavorites, body: const FavoritesView()),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: homeTabPath(HomeTab.history),
              builder: (c, s) => LibrarySectionScreen(title: c.l10n.libraryHistory, body: const HistoryView()),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: homeTabPath(HomeTab.downloads),
              builder: (c, s) => LibrarySectionScreen(title: c.l10n.downloadsManage, body: const DownloadsTab()),
            ),
          ]),
          StatefulShellBranch(
              routes: [GoRoute(path: homeTabPath(HomeTab.search), builder: (c, s) => const SearchScreen())]),
        ],
      ),
      GoRoute(path: '/search', builder: (c, s) => SearchScreen(initialQuery: s.uri.queryParameters['q'] ?? '')),
      GoRoute(
        path: '/video/detail',
        builder: (c, s) => DetailScreen(vodId: s.uri.queryParameters['id']!, siteKey: s.uri.queryParameters['site']),
      ),
      GoRoute(
          path: '/video/sub-category',
          builder: (c, s) => SubCategoryScreen(typeId: s.uri.queryParameters['type'] ?? '')),
      GoRoute(path: '/tracking/manage', builder: (c, s) => const TrackingManageScreen()),
      GoRoute(
        path: '/tmdb/search',
        builder: (c, s) => TmdbSearchScreen(
            initialQuery: s.uri.queryParameters['q'] ?? '', tvOnly: s.uri.queryParameters['tv'] == '1'),
      ),
      GoRoute(path: '/emby/accounts', builder: (c, s) => const EmbyAccountsScreen()),
      GoRoute(path: '/emby/accounts/add', builder: (c, s) => const EmbyAddAccountScreen()),
      GoRoute(
          path: '/emby/search', builder: (c, s) => EmbySearchScreen(account: s.uri.queryParameters['account'] ?? '')),
      GoRoute(
          path: '/emby/favorites',
          builder: (c, s) => EmbyFavoritesScreen(account: s.uri.queryParameters['account'] ?? '')),
      GoRoute(
        path: '/emby/detail',
        builder: (c, s) =>
            EmbyDetailScreen(account: s.uri.queryParameters['account'] ?? '', id: s.uri.queryParameters['id'] ?? ''),
      ),
      GoRoute(
          path: '/sniffer/web',
          builder: (c, s) => WebScreen(initialUrl: s.uri.queryParameters['url'] ?? '', sniff: true)),
      GoRoute(path: '/website', builder: (c, s) => WebScreen(initialUrl: s.uri.queryParameters['url'] ?? '')),
      GoRoute(path: '/live/settings', builder: (c, s) => const LiveSettingsScreen()),
      GoRoute(path: '/live/sources/edit', builder: (c, s) => LiveSourceEditScreen(id: s.uri.queryParameters['id'])),
      GoRoute(path: '/live/blocked-categories', builder: (c, s) => const BlockedCategoriesScreen()),
      GoRoute(path: '/subscriptions', builder: (c, s) => const SubscriptionsScreen()),
      GoRoute(path: '/subscriptions/add', builder: (c, s) => const AddSubscriptionScreen()),
      GoRoute(
          path: '/subscriptions/edit/:subKey',
          builder: (c, s) => EditSubscriptionScreen(subKey: s.pathParameters['subKey']!)),
      GoRoute(path: '/settings/player', builder: (c, s) => const PlayerSettingsScreen()),
      GoRoute(path: '/settings/danmu', builder: (c, s) => const DanmuSettingsScreen()),
      GoRoute(path: '/settings/danmu/blocked-words', builder: (c, s) => const DanmuBlockedWordsScreen()),
      GoRoute(path: '/settings/tmdb', builder: (c, s) => const TmdbSettingsScreen()),
      GoRoute(path: '/settings/webdav', builder: (c, s) => const WebDavSettingsScreen()),
      GoRoute(path: '/settings/webdav/config', builder: (c, s) => const WebDavConfigScreen()),
      GoRoute(path: '/settings/backup', builder: (c, s) => const BackupScreen()),
      GoRoute(path: '/settings/home-tabs', builder: (c, s) => const HomeTabsScreen()),
      GoRoute(path: '/settings/language', builder: (c, s) => const LanguageScreen()),
      GoRoute(path: '/settings/theme', builder: (c, s) => const ThemeSettingsScreen()),
      GoRoute(path: '/settings/feature', builder: (c, s) => const FeatureSettingsScreen()),
      GoRoute(path: '/debug', builder: (c, s) => const CatpawDebugScreen()),
    ],
  );
});
