import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/providers.dart';
import '../app/theme.dart';
import '../l10n/l10n.dart';
import 'app_shell.dart';
import 'downloads_tab.dart';
import 'widgets.dart';

/// The 媒体库 tab: 播放历史 / 我的收藏 / 下载 as top tabs in place of a title (OBSERVED order). The tracking calendar
/// is its own tab (追剧日历).
class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: false,
          titleSpacing: 4,
          title: TabBar(
            isScrollable: true,
            labelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            unselectedLabelStyle: const TextStyle(fontSize: 15),
            indicatorSize: TabBarIndicatorSize.label,
            tabs: [Tab(text: l.libraryHistory), Tab(text: l.libraryFavorites), Tab(text: l.libraryDownloads)],
          ),
        ),
        body: const TabBarView(children: [HistoryView(), FavoritesView(), DownloadsTab()]),
      ),
    );
  }
}

/// 播放历史, the body of the 媒体库 tab of that name and of the optional 播放历史 bottom tab (主页页面).
class HistoryView extends ConsumerWidget {
  const HistoryView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    return ref.watch(historyListProvider).when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorState(error: e, onRetry: () => ref.invalidate(historyListProvider)),
          data: (entries) => entries.isEmpty
              ? EmptyState(
                  icon: Icons.history_rounded,
                  title: l.noData,
                  subtitle: l.historyEmptySubtitle,
                )
              : ListView(padding: EdgeInsets.only(bottom: tabBottomInset(context)), children: [
                  SettingsSection(children: [
                    for (final e in entries)
                      InkWell(
                        onTap: () => context.push(Uri(
                          path: '/video/detail',
                          queryParameters: {'id': e.item.id, if (e.item.siteKey != null) 'site': e.item.siteKey!},
                        ).toString()),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: SizedBox(
                                width: 52,
                                height: 72,
                                child: e.item.pic == null
                                    ? ColoredBox(
                                        color: AppColors.of(context).cardHigh, child: const Icon(Icons.movie_outlined))
                                    : Image.network(e.item.pic!,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) => ColoredBox(
                                            color: AppColors.of(context).cardHigh,
                                            child: const Icon(Icons.movie_outlined))),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(e.item.name,
                                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15)),
                                const SizedBox(height: 4),
                                Text(e.episodeName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 13, color: AppColors.of(context).secondaryLabel)),
                                const SizedBox(height: 8),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(2),
                                  child: LinearProgressIndicator(
                                    value: e.fraction,
                                    minHeight: 3,
                                    backgroundColor: AppColors.of(context).cardHigh,
                                  ),
                                ),
                              ]),
                            ),
                          ]),
                        ),
                      ),
                  ]),
                ]),
        );
  }
}

/// 我的收藏, the body of the 媒体库 tab of that name and of the optional 我的收藏 bottom tab (主页页面).
class FavoritesView extends ConsumerWidget {
  const FavoritesView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    return ref.watch(favoriteListProvider).when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorState(error: e, onRetry: () => ref.invalidate(favoriteListProvider)),
          data: (items) => items.isEmpty
              ? EmptyState(
                  icon: Icons.favorite_border_rounded,
                  title: l.noData, // OBSERVED 暂无数据 / 暂无收藏，去发现喜欢的视频吧
                  subtitle: l.favoritesEmptySubtitle,
                )
              : VodGrid(items: items, bottomInset: tabBottomInset(context)),
        );
  }
}

/// Optional bottom tabs (设置 → 主页页面): one 媒体库 section as a page of its own, titled like the original's
/// (OBSERVED 我的收藏, 播放历史, 下载管理).
class LibrarySectionScreen extends StatelessWidget {
  const LibrarySectionScreen({super.key, required this.title, required this.body});
  final String title;
  final Widget body;

  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text(title)), body: body);
}
