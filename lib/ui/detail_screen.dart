import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/extra_providers.dart';
import '../app/providers.dart';
import '../app/ui_hooks.dart';
import '../features/downloads/enqueue.dart';
import '../features/library/watch_repository.dart';
import '../models/vod.dart';
import '../services/tmdb_client.dart';
import '../l10n/l10n.dart';
import '../app/theme.dart';
import 'widgets.dart';

String _stripCatpawTags(String raw) =>
    raw.replaceAll(RegExp(r'\[a=cr:\{[^}]*\}/\]'), '').replaceAll('[/a]', '').trim();

abstract final class DetailScreenRetry {
  /// Minimum time the spinner stays after 「重新加载」, so a request that fails at once (no network) still shows the
  /// page is working instead of looking like the tap did nothing.
  static const minSpinner = Duration(milliseconds: 600);
}

class DetailScreen extends ConsumerStatefulWidget {
  const DetailScreen({super.key, required this.vodId, this.siteKey});
  final String vodId;

  /// Site the item came from; null = the site currently selected on the home page.
  final String? siteKey;
  @override
  ConsumerState<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends ConsumerState<DetailScreen> {
  int _line = 0;
  bool _favorite = false;
  bool _opening = false;

  String get _siteKey => ref.read(siteByKeyProvider(widget.siteKey))?.key ?? '';

  @override
  void initState() {
    super.initState();
    final site = ref.read(siteByKeyProvider(widget.siteKey));
    if (site != null) {
      ref.read(favoriteRepositoryProvider).isFavorite(site.key, widget.vodId).then((v) {
        if (mounted) setState(() => _favorite = v);
      });
      // The 选集 sheet opens on the line the history was played on (before 2026-11-10 it always showed the first).
      ref.read(historyRepositoryProvider).find(site.key, widget.vodId).then((e) {
        if (mounted && e != null && !_lineTouched) setState(() => _line = e.lineIndex);
      });
    }
  }

  /// The user picked a line before the history was read: keep theirs.
  bool _lineTouched = false;

  /// 「重新加载」 is running: the page shows the spinner instead of the previous error.
  bool _retrying = false;

  /// Riverpod keeps showing the previous error while an invalidated provider refetches (`skipLoadingOnRefresh`), and an
  /// offline request fails within milliseconds, so before 2026-11-13 「重新加载」 looked dead. Now it shows the spinner
  /// for at least [DetailScreenRetry.minSpinner], and also reloads the subscription runtime when that is what failed.
  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    final started = DateTime.now();
    final query = (siteKey: widget.siteKey, vodId: widget.vodId);
    if (ref.read(catpawRuntimeProvider).hasError) ref.invalidate(catpawRuntimeProvider);
    ref.invalidate(videoDetailProvider(query));
    try {
      await ref.read(videoDetailProvider(query).future);
    } catch (_) {
      // The error is shown by the page itself.
    }
    final rest = DetailScreenRetry.minSpinner - DateTime.now().difference(started);
    if (rest > Duration.zero) await Future<void>.delayed(rest);
    if (mounted) setState(() => _retrying = false);
  }

  Future<void> _play(VodDetail detail, int episode) async {
    final rt = ref.read(catpawRuntimeProvider).valueOrNull;
    final site = ref.read(siteByKeyProvider(widget.siteKey));
    if (rt == null || site == null || _opening) return;
    setState(() => _opening = true);
    try {
      await ref.read(playerLauncherProvider).play(
            site: site,
            api: rt.api,
            detail: detail,
            history: ref.read(historyRepositoryProvider),
            line: _line,
            episode: episode,
            onOpened: () {
              if (mounted) setState(() => _opening = false);
            },
          );
      ref.invalidate(historyListProvider);
    } catch (e) {
      showToast('$e');
    } finally {
      if (mounted && _opening) setState(() => _opening = false);
    }
  }

  Future<void> _download(VodDetail detail, int episode) async {
    final rt = ref.read(catpawRuntimeProvider).valueOrNull;
    final site = ref.read(siteByKeyProvider(widget.siteKey));
    if (rt == null || site == null) return;
    try {
      final manager = await ref.read(downloadManagerProvider.future);
      await enqueueEpisode(
        manager: manager,
        sniffer: ref.read(snifferServiceProvider),
        site: site,
        api: rt.api,
        detail: detail,
        lineIndex: _line,
        episodeIndex: episode,
      );
      ref.invalidate(downloadTasksProvider);
      if (mounted) showToast(context.l10n.downloadStarted);
    } catch (e) {
      showToast('$e');
    }
  }

  Future<void> _toggleFavorite(VodDetail d, TmdbMatch? match) async {
    final now = await ref.read(favoriteRepositoryProvider).toggle(d.item);
    ref.invalidate(favoriteListProvider);
    setState(() => _favorite = now);
    if (now && await ref.read(autoSyncFavoritesProvider.future)) {
      if (await trackIfSeries(ref.read(trackingStoreProvider), match)) {
        ref.invalidate(trackingListProvider);
        if (mounted) showToast(context.l10n.addedToCalendar);
      }
    }
  }

  Future<void> _chooseTmdb(VodDetail d) async {
    final match =
        await context.push<TmdbMatch>(Uri(path: '/tmdb/search', queryParameters: {'q': d.item.name}).toString());
    if (match == null) return;
    await ref.read(tmdbRefsRepositoryProvider).set(vodKey(_siteKey, widget.vodId), match);
    ref.invalidate(tmdbMatchProvider);
  }

  /// 片头片尾 management sheet (matching orig_detail_head_tail.png: 片头 / 片尾 / 区间, seconds input, + 添加, saved list).
  Future<void> _openHeadTailSheet() async {
    final repo = ref.read(headTailRepositoryProvider);
    final key = vodKey(_siteKey, widget.vodId);
    var data = await repo.getAll(key);
    if (!mounted) return;
    var tab = 'intro';
    final singleCtrl = TextEditingController();
    final startCtrl = TextEditingController();
    final endCtrl = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useRootNavigator: true,
      backgroundColor: AppColors.of(context).page,
      builder: (sheetCtx) => StatefulBuilder(builder: (sheetCtx, setSheet) {
        final c = AppColors.of(sheetCtx);
        Future<void> reload() async {
          final next = await repo.getAll(key);
          setSheet(() => data = next);
        }

        final entries = <(String label, Future<void> Function() onDelete)>[
          if (data.intro > 0)
            ('片头：0s - ${data.intro.round()}s', () async { await repo.mark(key, 'intro', 0); await reload(); }),
          if (data.outro > 0)
            ('片尾：结束前 ${data.outro.round()}s', () async { await repo.mark(key, 'outro', 0); await reload(); }),
          for (var i = 0; i < data.ranges.length; i++)
            (
              '区间：${data.ranges[i].$1.round()}s - ${data.ranges[i].$2.round()}s',
              () async { await repo.removeRange(key, i); await reload(); },
            ),
        ];

        return Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + MediaQuery.viewInsetsOf(sheetCtx).bottom + MediaQuery.paddingOf(sheetCtx).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('片头片尾', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: c.label)),
            const SizedBox(height: 14),
            AppSegmented<String>(
              segments: const {'intro': (null, '片头'), 'outro': (null, '片尾'), 'range': (null, '区间')},
              value: tab,
              onChanged: (v) => setSheet(() => tab = v),
            ),
            const SizedBox(height: 14),
            if (tab != 'range') ...[
              Text(tab == 'intro' ? '片头结束（秒）' : '片尾时长（距离结束秒数）',
                  style: TextStyle(fontSize: 13, color: c.secondaryLabel)),
              const SizedBox(height: 8),
              TextField(
                controller: singleCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(isDense: true),
              ),
            ] else ...[
              Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('开始（秒）', style: TextStyle(fontSize: 13, color: c.secondaryLabel)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: startCtrl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(isDense: true),
                    ),
                  ]),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('结束（秒）', style: TextStyle(fontSize: 13, color: c.secondaryLabel)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: endCtrl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(isDense: true),
                    ),
                  ]),
                ),
              ]),
            ],
            const SizedBox(height: 16),
            PrimaryButton(
              icon: Icons.add,
              label: '添加',
              expand: true,
              onPressed: () async {
                if (tab == 'range') {
                  final s = double.tryParse(startCtrl.text.trim()) ?? 0;
                  final e = double.tryParse(endCtrl.text.trim()) ?? 0;
                  if (e <= s || s < 0) return;
                  await repo.addRange(key, s, e);
                  startCtrl.clear();
                  endCtrl.clear();
                } else {
                  final v = double.tryParse(singleCtrl.text.trim()) ?? 0;
                  if (v <= 0) return;
                  await repo.mark(key, tab, v);
                  singleCtrl.clear();
                }
                await reload();
              },
            ),
            const SizedBox(height: 20),
            if (entries.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text('暂无片头片尾记录', style: TextStyle(fontSize: 13.5, color: c.secondaryLabel))),
              )
            else
              for (final (label, onDelete) in entries)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(label, style: TextStyle(fontSize: 14, color: c.label)),
                  trailing: IconButton(
                    icon: Icon(Icons.delete_outline, color: c.secondaryLabel),
                    onPressed: onDelete,
                  ),
                ),
          ]),
        );
      }),
    );
    singleCtrl.dispose();
    startCtrl.dispose();
    endCtrl.dispose();
  }

  /// 立即播放 continues where the history left off (same line and episode), else the first episode of the first line.
  Future<void> _playNow(VodDetail d) async {
    final noLines = context.l10n.detailNoLines;
    final entry = await ref.read(historyRepositoryProvider).find(_siteKey, widget.vodId);
    if (!mounted) return;
    if (entry != null &&
        entry.lineIndex < d.lines.length &&
        entry.episodeIndex < d.lines[entry.lineIndex].episodes.length) {
      setState(() => _line = entry.lineIndex);
      return _play(d, entry.episodeIndex);
    }
    if (d.lines.isEmpty) return showToast(noLines);
    return _play(d, 0);
  }

  /// OBSERVED 选集 sheet: "选集  线路一 · 3集", locate and order buttons, line pills, numbered episode rows with a
  /// download button each; the current episode is tinted.
  Future<void> _openEpisodes(VodDetail d) async {
    if (d.lines.isEmpty) return showToast(context.l10n.detailNoLines);
    final entry = await ref.read(historyRepositoryProvider).find(_siteKey, widget.vodId);
    if (!mounted) return;
    var reversed = false;
    final scroll = ScrollController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useRootNavigator: true,
      // OBSERVED: the sheet is darker than its episode rows
      backgroundColor: AppColors.of(context).page,
      builder: (sheetContext) => StatefulBuilder(builder: (sheetContext, setSheet) {
        final l = sheetContext.l10n;
        final c = AppColors.of(sheetContext);
        final lineIndex = _line.clamp(0, d.lines.length - 1);
        final line = d.lines[lineIndex];
        final current = entry != null && entry.lineIndex == lineIndex ? entry.episodeIndex : 0;
        final order = [for (var i = 0; i < line.episodes.length; i++) i];
        if (reversed) order.setAll(0, order.reversed.toList());
        return SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * 0.62,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
              child: Row(children: [
                Text(l.detailEpisodes, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.label)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(l.detailEpisodeSheetSub(line.name, line.episodes.length),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: c.secondaryLabel)),
                ),
                IconButton(
                  tooltip: l.detailLocateCurrent,
                  icon: const Icon(Icons.my_location, size: 21),
                  onPressed: () {
                    final pos = order.indexOf(current);
                    if (pos >= 0 && scroll.hasClients) {
                      scroll.animateTo((pos * 58.0).clamp(0, scroll.position.maxScrollExtent),
                          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
                    }
                  },
                ),
                IconButton(
                  tooltip: l.detailReverseOrder,
                  icon: Icon(reversed ? Icons.arrow_upward : Icons.arrow_downward, size: 21),
                  onPressed: () => setSheet(() => reversed = !reversed),
                ),
              ]),
            ),
            if (d.lines.length > 1)
              SizedBox(
                height: 52,
                child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                    children: [
                      for (var i = 0; i < d.lines.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: Material(
                            color: i == lineIndex ? AppColors.of(context).accent : c.cardHigh.withValues(alpha: 0.6),
                            shape: const StadiumBorder(),
                            child: InkWell(
                              customBorder: const StadiumBorder(),
                              onTap: () {
                                setState(() {
                                  _line = i;
                                  _lineTouched = true;
                                });
                                setSheet(() {});
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                                child: Text(d.lines[i].name,
                                    style: TextStyle(fontSize: 13.5, color: i == lineIndex ? c.onAccent : c.label)),
                              ),
                            ),
                          ),
                        ),
                    ]),
              ),
            Expanded(
              child: ListView.builder(
                controller: scroll,
                padding: EdgeInsets.fromLTRB(20, 4, 20, 16 + MediaQuery.paddingOf(sheetContext).bottom),
                itemCount: order.length,
                itemBuilder: (_, k) {
                  final i = order[k];
                  final isCurrent = i == current;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: isCurrent
                          ? Color.alphaBlend(AppColors.of(context).accent.withValues(alpha: 0.12), c.card)
                          : c.card,
                      borderRadius: BorderRadius.circular(8),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () {
                          Navigator.pop(sheetContext);
                          _play(d, i);
                        },
                        // OBSERVED: rows are ~51 dp high with an 8 dp gap
                        child: Container(
                          height: 51,
                          padding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
                          child: Row(children: [
                            Container(
                              width: 32,
                              height: 32,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: isCurrent ? AppColors.of(context).accent : c.cardHigh,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text('${i + 1}',
                                  style: TextStyle(fontSize: 13.5, color: isCurrent ? c.onAccent : c.label)),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Text(line.episodes[i].name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 14, color: isCurrent ? AppColors.of(context).accent : c.label)),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: Icon(Icons.download, size: 22, color: c.secondaryLabel),
                              onPressed: () => _download(d, i),
                            ),
                          ]),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ]),
        );
      }),
    );
    scroll.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = AppColors.of(context);
    final detail = ref.watch(videoDetailProvider((siteKey: widget.siteKey, vodId: widget.vodId)));
    final d0 = detail.valueOrNull;
    final tmdbOn = ref.watch(tmdbProvider).valueOrNull != null;
    final tmdb = d0 == null || !tmdbOn
        ? null
        : ref.watch(tmdbMatchProvider((siteKey: _siteKey, vodId: widget.vodId, title: d0.item.name))).valueOrNull;
    return Scaffold(
      appBar: AppBar(
        title: Text(d0?.item.name ?? ''),
        actions: [
          IconButton(
            tooltip: '片头片尾',
            icon: const Icon(Icons.content_cut, size: 21),
            onPressed: d0 == null ? null : _openHeadTailSheet,
          ),
          IconButton(
            tooltip: l.favorite,
            icon: Icon(_favorite ? Icons.favorite : Icons.favorite_border,
                color: _favorite ? AppColors.destructive : null),
            onPressed: d0 == null ? null : () => _toggleFavorite(d0, tmdb),
          ),
        ],
      ),
      body: _retrying && !detail.hasValue
          ? const Center(child: CircularProgressIndicator())
          : detail.when(
        skipLoadingOnRefresh: false,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorState(error: e, onRetry: _retry),
        data: (d) {
          if (d == null) return EmptyState(icon: Icons.search_off, title: l.notFound);
          final overview =
              (d.content ?? '').isNotEmpty ? d.content!.replaceAll(RegExp(r'<[^>]+>'), '').trim() : tmdb?.overview;
          final tags = [if ((d.item.year ?? '').isNotEmpty) d.item.year!, if ((d.area ?? '').isNotEmpty) d.area!];
          final meta = TextStyle(fontSize: 13, color: c.label.withValues(alpha: 0.9), height: 1.5);
          return ListView(
              padding: EdgeInsets.fromLTRB(16, 10, 16, 24 + MediaQuery.paddingOf(context).bottom),
              children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 119,
                      height: 167,
                      child: d.item.pic == null
                          ? ColoredBox(color: c.card, child: Icon(Icons.movie_outlined, color: c.secondaryLabel))
                          : Image.network(d.item.pic!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => ColoredBox(
                                  color: c.card, child: Icon(Icons.movie_outlined, color: c.secondaryLabel))),
                    ),
                  ),
                  const SizedBox(width: 21),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const SizedBox(height: 2),
                      Text(d.item.name,
                          style: TextStyle(fontSize: 23, fontWeight: FontWeight.w700, color: c.label, height: 1.2)),
                      if ((d.item.remarks ?? '').isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(d.item.remarks!,
                            style: TextStyle(
                                fontSize: 13.5, fontWeight: FontWeight.w600, color: AppColors.of(context).accent)),
                      ],
                      if (tags.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Wrap(spacing: 8, runSpacing: 6, children: [
                          for (final t in tags)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(6)),
                              child: Text(t, style: TextStyle(fontSize: 11, color: c.label.withValues(alpha: 0.85))),
                            ),
                        ]),
                      ],
                    ]),
                  ),
                ]),
                const SizedBox(height: 28),
                Row(children: [
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(39),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                          textStyle: const TextStyle(fontSize: 14)),
                      onPressed: _opening ? null : () => _playNow(d),
                      icon: _opening
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.play_arrow, size: 20),
                      label: Text(l.detailPlayNow),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(39),
                        textStyle: const TextStyle(fontSize: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        side: BorderSide(color: c.secondaryLabel.withValues(alpha: 0.7)),
                      ),
                      onPressed: () => _openEpisodes(d),
                      icon: const Icon(Icons.video_library_outlined, size: 19),
                      label: Text(l.detailEpisodes),
                    ),
                  ),
                ]),
                if (tmdbOn) ...[
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, children: [
                    ActionChip(
                      avatar: const Icon(Icons.movie_filter_outlined, size: 18),
                      label: Text(tmdb == null ? l.detailMatchTmdb : 'TMDB: ${tmdb.title}'),
                      onPressed: () => _chooseTmdb(d),
                    ),
                    if (tmdb != null && tmdb.mediaType == 'tv')
                      ActionChip(
                        avatar: const Icon(Icons.event_note_outlined, size: 18),
                        label: Text(l.trackingAdd),
                        onPressed: () async {
                          await trackIfSeries(ref.read(trackingStoreProvider), tmdb);
                          ref.invalidate(trackingListProvider);
                          if (context.mounted) showToast(context.l10n.addedToCalendar);
                        },
                      ),
                  ]),
                ],
                const SizedBox(height: 23),
                if ((d.director ?? '').isNotEmpty) Text(l.detailDirector(_stripCatpawTags(d.director!)), style: meta),
                if ((d.actor ?? '').isNotEmpty)
                  Text(l.detailCast(_stripCatpawTags(d.actor!)), maxLines: 3, overflow: TextOverflow.ellipsis, style: meta),
                if ((overview ?? '').isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(l.detailIntro, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c.label)),
                  const SizedBox(height: 10),
                  Text(overview!, style: TextStyle(fontSize: 13, color: c.label.withValues(alpha: 0.82), height: 1.55)),
                ],
              ]);
        },
      ),
    );
  }
}
