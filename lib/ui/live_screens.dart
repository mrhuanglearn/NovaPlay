import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/live_providers.dart';
import '../app/providers.dart';
import '../app/theme.dart';
import '../app/ui_hooks.dart';
import '../features/live/live_store.dart';
import '../features/live/m3u_epg.dart';
import '../features/player/native_player_api.g.dart';
import '../features/player/playback_source.dart';
import '../models/vod.dart';
import '../l10n/l10n.dart';
import 'app_shell.dart';
import 'widgets.dart';

/// `/live`: channels of the chosen M3U source, grouped, with the current programme from the XMLTV guide.
class LiveScreen extends ConsumerStatefulWidget {
  const LiveScreen({super.key});
  @override
  ConsumerState<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends ConsumerState<LiveScreen> {
  String? _group;
  String _query = '';
  bool _searching = false;

  Future<void> _play(
      LiveSource source, List<LiveChannel> all, Set<String> blocked, LiveChannel tapped, XmltvGuide? guide) async {
    final groups = liveGroups(all, blocked: blocked);
    final lines = [
      for (final g in groups)
        PlayLine(g, [for (final c in all.where((c) => groupOf(c) == g)) PlayEpisode(c.name, c.url)]),
    ];
    final line = groups.indexOf(groupOf(tapped));
    final episode = lines[line].episodes.indexWhere((e) => e.url == tapped.url);
    final now = DateTime.now();
    final programmes = guide == null
        ? null
        : [
            for (final e in guide.forChannel(tapped).where((e) =>
                e.stop.isAfter(now.subtract(const Duration(hours: 1))) &&
                e.start.isBefore(now.add(const Duration(hours: 24)))))
              EpgProgramme(
                startEpochMs: e.start.millisecondsSinceEpoch,
                endEpochMs: e.stop.millisecondsSinceEpoch,
                title: e.title,
                description: e.description,
              ),
          ];
    try {
      await ref.read(playerLauncherProvider).playSource(
            DirectPlaybackSource(title: source.name, lines: lines, epg: programmes ?? const <EpgProgramme>[]),
            line: line,
            episode: episode < 0 ? 0 : episode,
          );
    } catch (e) {
      showToast('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final sources = ref.watch(liveSourcesProvider);
    final source = ref.watch(currentLiveSourceProvider);
    final blocked = ref.watch(livePreferencesProvider).valueOrNull?.blockedGroups ?? const <String>{};
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                autofocus: true,
                decoration: InputDecoration(hintText: l.liveSearchChannels, isDense: true),
                onChanged: (v) => setState(() => _query = v),
              )
            : (sources.valueOrNull?.length ?? 0) > 1 && source != null
                ? DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: source.id,
                      items: [for (final s in sources.value!) DropdownMenuItem(value: s.id, child: Text(s.name))],
                      onChanged: (id) {
                        _group = null;
                        ref.read(selectedLiveSourceProvider.notifier).select(id);
                      },
                    ),
                  )
                : Text(source?.name ?? l.tabLive),
        actions: [
          if (source != null)
            IconButton(
              tooltip: l.search,
              icon: Icon(_searching ? Icons.close : Icons.search),
              onPressed: () => setState(() {
                _searching = !_searching;
                _query = '';
              }),
            ),
          if (source != null)
            IconButton(
                tooltip: l.liveSettings, icon: const Icon(Icons.tune), onPressed: () => context.push('/live/settings')),
        ],
      ),
      body: source == null
          ? EmptyState(
              icon: Icons.add_circle_outline_rounded,
              title: l.liveEmptyTitle,
              subtitle: l.liveEmptySubtitle,
              action: PrimaryButton(
                  icon: Icons.add, label: l.liveAddSource, onPressed: () => context.push('/live/sources/edit')),
            )
          : ref.watch(liveChannelsProvider(source.id)).when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => ErrorState(error: e, onRetry: () => ref.invalidate(liveChannelsProvider(source.id))),
                data: (all) {
                  final guide = ref.watch(liveGuideProvider(source.id)).valueOrNull;
                  final groups = liveGroups(all, blocked: blocked);
                  final shown = visibleChannels(all, blocked: blocked, group: _group, query: _query);
                  final now = DateTime.now();
                  return Column(children: [
                    SizedBox(
                      height: 48,
                      child: ListView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(4),
                              child: ChoiceChip(
                                  label: Text(l.all),
                                  selected: _group == null,
                                  onSelected: (_) => setState(() => _group = null)),
                            ),
                            for (final g in groups)
                              Padding(
                                padding: const EdgeInsets.all(4),
                                child: ChoiceChip(
                                    label: Text(g),
                                    selected: _group == g,
                                    onSelected: (_) => setState(() => _group = g)),
                              ),
                          ]),
                    ),
                    Expanded(
                      child: shown.isEmpty
                          ? EmptyState(icon: Icons.search_off, title: l.liveNoChannels)
                          : ListView.builder(
                              padding: EdgeInsets.only(bottom: tabBottomInset(context)),
                              itemCount: shown.length,
                              itemBuilder: (context, i) {
                                final c = shown[i];
                                final programme = guide == null ? null : currentProgramme(guide.forChannel(c), now);
                                return ListTile(
                                  leading: SizedBox(
                                    width: 48,
                                    child: c.logo == null || c.logo!.isEmpty
                                        ? const Icon(Icons.tv)
                                        : Image.network(c.logo!,
                                            fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Icon(Icons.tv)),
                                  ),
                                  title: Text(c.name),
                                  subtitle: programme == null
                                      ? null
                                      : Text(programme.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                                  onTap: () => _play(source, all, blocked, c, guide),
                                );
                              },
                            ),
                    ),
                  ]);
                },
              ),
    );
  }
}

/// `/live/settings` (OBSERVED 直播设置: 直播源管理 / 全局 EPG 地址 / 屏蔽分类管理).
class LiveSettingsScreen extends ConsumerStatefulWidget {
  const LiveSettingsScreen({super.key});
  @override
  ConsumerState<LiveSettingsScreen> createState() => _LiveSettingsScreenState();
}

class _LiveSettingsScreenState extends ConsumerState<LiveSettingsScreen> {
  final _epg = TextEditingController();

  @override
  void initState() {
    super.initState();
    ref.read(livePreferencesProvider.future).then((p) {
      if (mounted) _epg.text = p.globalEpgUrl;
    });
  }

  @override
  void dispose() {
    _epg.dispose();
    super.dispose();
  }

  Future<void> _saveEpg() async {
    final l = context.l10n;
    final prefs = await ref.read(livePreferencesProvider.future);
    await ref.read(livePreferencesRepositoryProvider).save(prefs.copyWith(globalEpgUrl: _epg.text.trim()));
    ref.invalidate(livePreferencesProvider);
    ref.invalidate(liveGuideProvider);
    FocusManager.instance.primaryFocus?.unfocus();
    showToast(l.liveEpgSaved);
  }

  Future<void> _delete(LiveSource s) async {
    final l = context.l10n;
    if (!await confirmAction(context, message: l.liveDeleteConfirm(s.name), destructive: true)) return;
    await ref.read(liveSourceRepositoryProvider).remove(s.id);
    await ref.read(livePlaylistLoaderProvider).remove(s.id);
    ref.invalidate(liveSourcesProvider);
    showToast(l.liveSourceDeleted);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = AppColors.of(context);
    final sources = ref.watch(liveSourcesProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l.liveSettings)),
      body: ListView(padding: EdgeInsets.only(bottom: 24 + MediaQuery.paddingOf(context).bottom), children: [
        SettingsSection(title: l.liveSourcesGroup, children: [
          ...sources.when(
            loading: () =>
                const [Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))],
            error: (e, _) => [SettingsTile(title: '$e')],
            data: (list) => [
              for (final s in list)
                SettingsTile(
                  icon: Icons.live_tv_rounded,
                  title: s.name,
                  subtitle: s.url,
                  onTap: () => context.push(Uri(path: '/live/sources/edit', queryParameters: {'id': s.id}).toString()),
                  trailing: IconButton(
                    tooltip: l.delete,
                    icon: Icon(Icons.delete_outline, color: c.secondaryLabel),
                    onPressed: () => _delete(s),
                  ),
                ),
            ],
          ),
          SettingsTile(icon: Icons.add, title: l.liveAddSource, onTap: () => context.push('/live/sources/edit')),
        ]),
        SettingsSection(title: l.liveGlobalEpg, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.liveGlobalEpgHint, style: TextStyle(fontSize: 11.5, height: 1.4, color: c.subtitle)),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _epg,
                    keyboardType: TextInputType.url,
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      suffixIcon: IconButton(
                        icon: Icon(Icons.content_paste, size: 18, color: c.secondaryLabel),
                        onPressed: () async {
                          final t = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
                          if (t != null && t.isNotEmpty) _epg.text = t;
                        },
                      ),
                    ),
                    onSubmitted: (_) => _saveEpg(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(
                      minimumSize: const Size(64, 41), padding: const EdgeInsets.symmetric(horizontal: 18)),
                  onPressed: _saveEpg,
                  child: Text(l.save),
                ),
              ]),
            ]),
          ),
        ]),
        SettingsSection(title: l.liveBlockedGroup, children: [
          SettingsTile(
            icon: Icons.block,
            title: l.liveBlockedCategories,
            subtitle: l.liveBlockedCategoriesSub,
            onTap: () => context.push('/live/blocked-categories'),
          ),
        ]),
      ]),
    );
  }
}

/// `/live/sources/edit[?id=]` (OBSERVED 添加直播源: 名称, 源地址 + "仅支持 M3U 格式播放列表", User-Agent = okhttp, 自动刷新
/// 关闭 / 每次 / 24 小时, 验证并保存). The playlist is downloaded and parsed before anything is saved.
class LiveSourceEditScreen extends ConsumerStatefulWidget {
  const LiveSourceEditScreen({super.key, this.id});
  final String? id;
  @override
  ConsumerState<LiveSourceEditScreen> createState() => _LiveSourceEditScreenState();
}

class _LiveSourceEditScreenState extends ConsumerState<LiveSourceEditScreen> {
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _ua = TextEditingController(text: defaultLiveUserAgent);
  LiveRefresh _refresh = LiveRefresh.daily;
  LiveSource? _old;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.id != null) {
      ref.read(liveSourcesProvider.future).then((list) {
        final s = list.where((s) => s.id == widget.id).firstOrNull;
        if (s == null || !mounted) return;
        setState(() {
          _old = s;
          _name.text = s.name;
          _url.text = s.url;
          _ua.text = s.userAgent;
          _refresh = s.refresh;
        });
      });
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _url, _ua]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final l = context.l10n;
    final url = _url.text.trim();
    if (url.isEmpty) return;
    final sources = await ref.read(liveSourcesProvider.future);
    if (sources.any((s) => s.url == url && s.id != widget.id)) return showToast(l.liveSourceExists);
    final source = LiveSource(
      id: widget.id ?? '${DateTime.now().millisecondsSinceEpoch}',
      name: _name.text.trim().isEmpty ? (Uri.tryParse(url)?.host ?? url) : _name.text.trim(),
      url: url,
      epgUrl: _old?.epgUrl ?? '',
      userAgent: _ua.text.trim(),
      refresh: _refresh,
    );
    setState(() => _busy = true);
    try {
      final text = await fetchLivePlaylist(source);
      if (parseM3u(text).isEmpty) throw StateError(l.liveNoChannels);
      await ref.read(livePlaylistLoaderProvider).store(source.id, text);
      await ref.read(liveSourceRepositoryProvider).upsert(source);
      ref.invalidate(liveSourcesProvider);
      ref.invalidate(livePlaylistProvider);
      ref.invalidate(liveGuideProvider);
      showToast(l.liveSourceSaved);
      if (mounted) context.pop();
    } catch (e) {
      showToast(l.liveSourceSaveFailed(e is StateError ? e.message : '$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = AppColors.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.id == null ? l.liveAddSource : l.liveEditSource)),
      body: ListView(padding: EdgeInsets.fromLTRB(16, 4, 16, 24 + MediaQuery.paddingOf(context).bottom), children: [
        LabeledField(controller: _name, label: l.name, hint: l.liveNameHint, padding: bareFieldPadding),
        LabeledField(
            controller: _url,
            label: l.liveSourceUrl,
            hint: 'https://example.com/playlist.m3u',
            keyboardType: TextInputType.url,
            padding: bareFieldPadding),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
          child: Row(children: [
            Icon(Icons.info_outline, size: 13, color: c.subtitle),
            const SizedBox(width: 4),
            Text(l.liveM3uOnly, style: TextStyle(fontSize: 11.5, color: c.subtitle)),
          ]),
        ),
        LabeledField(controller: _ua, label: 'User-Agent', hint: l.liveUserAgentHint, padding: bareFieldPadding),
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 8, 2, 8),
          child: Text(l.liveAutoRefresh, style: TextStyle(fontSize: 12.5, color: c.subtitle)),
        ),
        AppSegmented<LiveRefresh>(
          segments: {
            LiveRefresh.off: (null, l.liveRefreshOff),
            LiveRefresh.always: (null, l.liveRefreshAlways),
            LiveRefresh.daily: (null, l.liveRefresh24h)
          },
          value: _refresh,
          onChanged: (v) => setState(() => _refresh = v),
        ),
        const SizedBox(height: 20),
        PrimaryButton(
            icon: Icons.check_circle, label: l.liveVerifyAndSave, expand: true, onPressed: _busy ? null : _save),
      ]),
    );
  }
}

/// `/live/blocked-categories` (OBSERVED: 屏蔽分类 with a + action; empty state 暂无数据 / 暂无屏蔽分类). + offers the
/// groups of the current source that are not hidden yet.
class BlockedCategoriesScreen extends ConsumerWidget {
  const BlockedCategoriesScreen({super.key});

  Future<void> _save(WidgetRef ref, LivePreferences prefs, Set<String> blocked) async {
    await ref.read(livePreferencesRepositoryProvider).save(prefs.copyWith(blockedGroups: blocked));
    ref.invalidate(livePreferencesProvider);
  }

  Future<void> _add(BuildContext context, WidgetRef ref, LivePreferences prefs) async {
    final l = context.l10n;
    final source = ref.read(currentLiveSourceProvider);
    final all = source == null
        ? const <LiveChannel>[]
        : await ref.read(liveChannelsProvider(source.id).future).catchError((_) => const <LiveChannel>[]);
    final candidates = liveGroups(all, blocked: prefs.blockedGroups);
    if (!context.mounted) return;
    if (candidates.isEmpty) return showToast(l.liveNothingToBlock);
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(l.liveBlockPick,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.of(sheet).label)),
          ),
          for (final g in candidates) ListTile(title: Text(g), onTap: () => Navigator.pop(sheet, g)),
        ]),
      ),
    );
    if (picked == null) return;
    await _save(ref, prefs, {...prefs.blockedGroups, picked});
    showToast(l.liveCategoryBlocked(picked));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(livePreferencesProvider).valueOrNull ?? const LivePreferences();
    final l = context.l10n;
    final blocked = prefs.blockedGroups.toList()..sort();
    return Scaffold(
      appBar: AppBar(
        title: Text(l.liveBlockedCategories),
        actions: [
          IconButton(tooltip: l.liveBlockPick, icon: const Icon(Icons.add), onPressed: () => _add(context, ref, prefs))
        ],
      ),
      body: blocked.isEmpty
          ? EmptyState(icon: Icons.block, title: l.noData, subtitle: l.liveBlockedEmpty)
          : ListView(children: [
              SettingsSection(children: [
                for (final g in blocked)
                  SettingsTile(
                    icon: Icons.block,
                    title: g,
                    trailing: IconButton(
                      icon: Icon(Icons.remove_circle_outline, color: AppColors.of(context).secondaryLabel),
                      onPressed: () async {
                        await _save(ref, prefs, {...prefs.blockedGroups}..remove(g));
                        showToast(l.liveCategoryUnblocked(g));
                      },
                    ),
                  ),
              ]),
            ]),
    );
  }
}
