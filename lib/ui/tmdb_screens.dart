import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../app/extra_providers.dart';
import '../app/providers.dart';
import '../app/theme.dart';
import '../app/ui_hooks.dart';
import '../features/tracking/tracking_service.dart';
import '../l10n/l10n.dart';
import '../services/tmdb_client.dart';
import 'app_shell.dart';
import 'form_widgets.dart';
import 'widgets.dart';

/// `/tmdb/search`: pick the TMDB entry that belongs to a video. Pops with the chosen [TmdbMatch].
class TmdbSearchScreen extends ConsumerStatefulWidget {
  const TmdbSearchScreen({super.key, this.initialQuery = '', this.tvOnly = false});
  final String initialQuery;
  final bool tvOnly;
  @override
  ConsumerState<TmdbSearchScreen> createState() => _TmdbSearchScreenState();
}

class _TmdbSearchScreenState extends ConsumerState<TmdbSearchScreen> {
  late final _controller = TextEditingController(text: widget.initialQuery);
  Future<List<TmdbMatch>>? _results;

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery.isNotEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _search() {
    final q = _controller.text.trim();
    if (q.isEmpty) return;
    final notEnabled = context.l10n.tmdbNotEnabledError;
    setState(() {
      _results = ref.read(tmdbProvider.future).then((client) async {
        if (client == null) throw StateError(notEnabled);
        final hits = await client.searchMulti(q);
        return widget.tvOnly ? hits.where((m) => m.mediaType == 'tv').toList() : hits;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final client = ref.watch(tmdbProvider).valueOrNull;
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: TextField(
          controller: _controller,
          autofocus: widget.initialQuery.isEmpty,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(hintText: l.tmdbSearchHint, isDense: true),
          onSubmitted: (_) => _search(),
        ),
        actions: [IconButton(tooltip: l.search, icon: const Icon(Icons.search), onPressed: _search)],
      ),
      body: _results == null
          ? EmptyState(icon: Icons.movie_filter_outlined, title: l.tmdbSearchPrompt)
          : FutureBuilder<List<TmdbMatch>>(
              future: _results,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) return ErrorState(error: snap.error!, onRetry: _search);
                final list = snap.data ?? const [];
                if (list.isEmpty) return EmptyState(icon: Icons.search_off, title: l.noResults);
                return ListView(children: [
                  SettingsSection(children: [
                    for (final m in list)
                      ListTile(
                        leading: m.posterPath == null || client == null
                            ? const Icon(Icons.movie_outlined)
                            : ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: Image.network(client.imageUrl(m.posterPath!, size: 'w92'),
                                    width: 40, fit: BoxFit.cover),
                              ),
                        title: Text(m.title),
                        subtitle: Text(
                            '${m.mediaType == 'tv' ? l.mediaSeries : l.mediaMovie}${m.releaseDate == null || m.releaseDate!.isEmpty ? '' : ' · ${m.releaseDate!.substring(0, 4)}'}\n${m.overview ?? ''}',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis),
                        isThreeLine: true,
                        onTap: () => context.pop(m),
                      ),
                  ]),
                ]);
              },
            ),
    );
  }
}

/// `/tracking/manage`: followed series, and the switch that adds favorites automatically.
class TrackingManageScreen extends ConsumerWidget {
  const TrackingManageScreen({super.key});

  Future<int?> _askSeason(BuildContext context) {
    final l = context.l10n;
    final c = TextEditingController(text: '1');
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.trackingSeason),
        content: TextField(
            controller: c,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(hintText: l.trackingSeasonNumber)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, int.tryParse(c.text.trim()) ?? 1), child: Text(l.add)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final shows = ref.watch(trackingListProvider);
    final auto = ref.watch(autoSyncFavoritesProvider).valueOrNull ?? false;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.trackingManage),
        actions: [
          IconButton(
            tooltip: l.trackingAdd,
            icon: const Icon(Icons.add),
            onPressed: () async {
              final match = await context.push<TmdbMatch>('/tmdb/search?tv=1');
              if (match == null || !context.mounted) return;
              final season = await _askSeason(context);
              if (season == null) return;
              await trackIfSeries(ref.read(trackingStoreProvider), match, season: season);
              ref.invalidate(trackingListProvider);
              ref.invalidate(trackingWeekProvider);
            },
          ),
        ],
      ),
      body: ListView(padding: EdgeInsets.only(bottom: 24 + MediaQuery.paddingOf(context).bottom), children: [
        SettingsSection(children: [
          SwitchRow(
            icon: Icons.sync,
            title: l.trackingAutoSync,
            subtitle: l.trackingAutoSyncSub,
            value: auto,
            onChanged: (v) async {
              await ref.read(autoSyncFavoritesStoreProvider).write({'enabled': v});
              ref.invalidate(autoSyncFavoritesProvider);
            },
          ),
        ]),
        ...shows.when(
          loading: () =>
              const [Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))],
          error: (e, _) => [ErrorState(error: e, onRetry: () => ref.invalidate(trackingListProvider))],
          data: (list) => list.isEmpty
              ? [
                  Padding(
                      padding: const EdgeInsets.all(32),
                      child: EmptyState(icon: Icons.event_note_outlined, title: l.trackingEmpty))
                ]
              : [
                  SettingsSection(title: l.trackingFollowed, children: [
                    for (final TrackedShow s in list)
                      SettingsTile(
                        title: s.title,
                        subtitle: l.trackingShowSubtitle(s.season, s.watched.length),
                        onTap: () => context.push(Uri(path: '/search', queryParameters: {'q': s.title}).toString()),
                        trailing: IconButton(
                          tooltip: l.delete,
                          icon: Icon(Icons.delete_outline, color: AppColors.of(context).secondaryLabel),
                          onPressed: () async {
                            await ref.read(trackingStoreProvider).remove(s.tmdbId);
                            ref.invalidate(trackingListProvider);
                            ref.invalidate(trackingWeekProvider);
                          },
                        ),
                      ),
                  ]),
                ],
        ),
      ]),
    );
  }
}

/// `/calendar`, the 追剧日历 tab. Without TMDB it shows the original's not-configured state (OBSERVED:
/// "未启用 TMDB，无法获取更新日历" / "这里空空如也，什么都没有发现" / 前往设置).
class CalendarScreen extends ConsumerWidget {
  const CalendarScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final tmdb = ref.watch(tmdbProvider);
    final enabled = tmdb.valueOrNull != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.tabCalendar),
        actions: [
          if (enabled)
            IconButton(
                tooltip: l.trackingManage,
                icon: const Icon(Icons.tune),
                onPressed: () => context.push('/tracking/manage')),
        ],
      ),
      body: tmdb.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorState(error: e, onRetry: () => ref.invalidate(tmdbProvider)),
        data: (client) => client == null
            ? EmptyState(
                icon: Icons.event_busy_rounded,
                title: l.calendarTmdbDisabled,
                subtitle: l.nothingHere,
                action: OutlinedButton(onPressed: () => context.push('/settings/tmdb'), child: Text(l.goToSettings)),
              )
            : const TrackingCalendarTab(),
      ),
    );
  }
}

/// Weekly calendar of followed series.
class TrackingCalendarTab extends ConsumerStatefulWidget {
  const TrackingCalendarTab({super.key});
  @override
  ConsumerState<TrackingCalendarTab> createState() => _TrackingCalendarTabState();
}

class _TrackingCalendarTabState extends ConsumerState<TrackingCalendarTab> {
  DateTime _week = weekStart(DateTime.now());

  void _shift(int weeks) => setState(() => _week = _week.add(Duration(days: 7 * weeks)));

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final entries = ref.watch(trackingWeekProvider(_week));
    final fmt = DateFormat.MMMd(locale);
    final isThisWeek = _week == weekStart(DateTime.now());
    return Column(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => _shift(-1)),
          Text(
              isThisWeek
                  ? l.calendarThisWeek
                  : '${fmt.format(_week)} – ${fmt.format(_week.add(const Duration(days: 6)))}',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
          IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => _shift(1)),
        ]),
      ),
      Expanded(
        child: entries.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorState(error: e, onRetry: () => ref.invalidate(trackingWeekProvider)),
          data: (list) => list.isEmpty
              ? EmptyState(
                  icon: Icons.event_available_outlined,
                  title: l.calendarNothingThisWeek,
                  subtitle: l.nothingHere,
                  action: OutlinedButton(onPressed: () => context.push('/tracking/manage'), child: Text(l.trackingAdd)),
                )
              : ListView(padding: EdgeInsets.only(bottom: tabBottomInset(context)), children: [
                  SettingsSection(children: [
                    for (final e in list)
                      ListTile(
                        leading: SizedBox(
                          width: 44,
                          child: Text(DateFormat.E(locale).format(e.date),
                              textAlign: TextAlign.center,
                              style: TextStyle(color: AppColors.of(context).accent, fontWeight: FontWeight.w600)),
                        ),
                        title: Text(e.show.title),
                        subtitle: Text(l.calendarEpisode(e.episode.number, e.episode.name)),
                        trailing: Icon(e.watched ? Icons.check_circle : Icons.radio_button_unchecked,
                            color: e.watched ? AppColors.of(context).accent : AppColors.of(context).secondaryLabel),
                        onTap: () =>
                            context.push(Uri(path: '/search', queryParameters: {'q': e.show.title}).toString()),
                        onLongPress: () async {
                          await ref
                              .read(trackingStoreProvider)
                              .markWatched(e.show.tmdbId, e.episode.number, watched: !e.watched);
                          ref.invalidate(trackingWeekProvider);
                          showToast(e.watched ? l.markedUnwatched : l.markedWatched);
                        },
                      ),
                  ]),
                ]),
        ),
      ),
    ]);
  }
}
