import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/extra_providers.dart';
import '../app/providers.dart';
import '../app/ui_hooks.dart';
import '../features/downloads/download_manager.dart';
import '../features/player/playback_source.dart';
import '../l10n/l10n.dart';
import 'app_shell.dart';
import 'widgets.dart';

String downloadStateLabel(BuildContext context, DownloadState s) => switch (s) {
      DownloadState.queued => context.l10n.downloadQueued,
      DownloadState.running => context.l10n.downloadRunning,
      DownloadState.paused => context.l10n.downloadPaused,
      DownloadState.done => context.l10n.downloadDone,
      DownloadState.failed => context.l10n.downloadFailed,
    };

/// Downloaded and downloading episodes, grouped by show (changelog 1.1.4).
class DownloadsTab extends ConsumerWidget {
  const DownloadsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final tasks = ref.watch(downloadTasksProvider);
    return tasks.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorState(error: e, onRetry: () => ref.invalidate(downloadTasksProvider)),
      data: (list) {
        if (list.isEmpty) {
          return EmptyState(
            icon: Icons.download_rounded,
            title: l.noData, // OBSERVED 暂无数据 / 暂无下载任务
            subtitle: l.downloadsEmptySubtitle,
          );
        }
        final groups = <String, List<DownloadTask>>{};
        for (final t in list) {
          groups.putIfAbsent(t.group ?? l.downloadsOtherGroup, () => []).add(t);
        }
        return ListView(padding: EdgeInsets.only(bottom: tabBottomInset(context)), children: [
          for (final g in groups.entries)
            SettingsSection(
              title:
                  '${g.key}  ·  ${l.downloadsDoneCount(g.value.where((t) => t.state == DownloadState.done).length, g.value.length)}',
              children: [for (final t in g.value) _TaskTile(task: t)],
            ),
        ]);
      },
    );
  }
}

class _TaskTile extends ConsumerWidget {
  const _TaskTile({required this.task});
  final DownloadTask task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.read(downloadManagerProvider).valueOrNull;
    final done = task.state == DownloadState.done;
    return ListTile(
      title: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(task.state == DownloadState.failed
            ? '${downloadStateLabel(context, task.state)}: ${task.error ?? ''}'
            : downloadStateLabel(context, task.state)),
        if (!done) LinearProgressIndicator(value: task.state == DownloadState.queued ? null : task.progress),
      ]),
      onTap: done && task.localPlaylist != null
          ? () async {
              try {
                await ref.read(playerLauncherProvider).playSource(
                    DirectPlaybackSource.single(title: task.title, url: Uri.file(task.localPlaylist!).toString()));
              } catch (e) {
                showToast('$e');
              }
            }
          : null,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (task.state == DownloadState.running)
          IconButton(
              tooltip: context.l10n.downloadPause,
              icon: const Icon(Icons.pause),
              onPressed: () => manager?.pause(task.id))
        else if (!done)
          IconButton(
              tooltip: context.l10n.downloadResume,
              icon: const Icon(Icons.play_arrow),
              onPressed: () => manager?.resume(task.id)),
        IconButton(
          tooltip: context.l10n.delete,
          icon: const Icon(Icons.delete_outline),
          onPressed: () async {
            await manager?.remove(task.id);
            ref.invalidate(downloadTasksProvider);
          },
        ),
      ]),
    );
  }
}
