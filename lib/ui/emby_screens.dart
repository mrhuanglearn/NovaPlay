import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/extra_providers.dart';
import '../app/providers.dart';
import '../app/theme.dart';
import '../app/ui_hooks.dart';
import '../features/media_server/media_source.dart';
import '../services/media_server_client.dart';
import 'form_widgets.dart';
import '../l10n/l10n.dart';
import 'app_shell.dart';
import 'widgets.dart';

String _routeTo(String path, Map<String, String> q) => Uri(path: path, queryParameters: q).toString();

/// `/emby/accounts` (OBSERVED title 媒体服务器账号, person-add action, empty state 暂无数据 / 添加一个账号以浏览你的
/// Emby 媒体库 / 添加账号). Only the access token is stored, never the password.
///
/// [asTab]: the optional 媒体服务器 bottom tab (设置 → 主页页面). OBSERVED there: title 媒体服务器, a manage-accounts
/// action in place of person-add, the same empty state.
class EmbyAccountsScreen extends ConsumerWidget {
  const EmbyAccountsScreen({super.key, this.asTab = false});
  final bool asTab;

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    await context.push('/emby/accounts/add');
    ref.invalidate(mediaAccountsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final accounts = ref.watch(mediaAccountsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(asTab ? l.settingsMediaServer : l.mediaAccountsTitle),
        actions: [
          asTab
              ? IconButton(
                  tooltip: l.mediaManageAccounts,
                  icon: const Icon(Icons.manage_accounts_outlined),
                  onPressed: () async {
                    await context.push('/emby/accounts');
                    ref.invalidate(mediaAccountsProvider);
                  },
                )
              : IconButton(
                  tooltip: l.mediaAddAccount,
                  icon: const Icon(Icons.person_add_alt_1),
                  onPressed: () => _add(context, ref)),
        ],
      ),
      body: accounts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorState(error: e, onRetry: () => ref.invalidate(mediaAccountsProvider)),
        data: (list) => list.isEmpty
            ? EmptyState(
                icon: Icons.person_add_alt_1,
                title: l.noData,
                subtitle: l.mediaEmptySubtitle,
                actionGap: 48,
                action: PrimaryButton(
                    icon: Icons.person_add_alt_1, label: l.mediaAddAccount, onPressed: () => _add(context, ref)),
              )
            : ListView(
                padding: EdgeInsets.only(
                    bottom: asTab ? tabBottomInset(context) : 24 + MediaQuery.paddingOf(context).bottom),
                children: [
                    SettingsSection(children: [
                      for (final a in list)
                        SettingsTile(
                          icon: Icons.dns_outlined,
                          title: a.name,
                          subtitle: '${a.kind == 'jellyfin' ? 'Jellyfin' : 'Emby'} · ${a.baseUrl}',
                          onTap: () => context.push(_routeTo('/emby/search', {'account': a.id})),
                          trailing: IconButton(
                            tooltip: l.delete,
                            icon: Icon(Icons.delete_outline, color: AppColors.of(context).secondaryLabel),
                            onPressed: () async {
                              if (!await confirmAction(context,
                                  message: l.mediaDeleteConfirm(a.name), destructive: true)) {
                                return;
                              }
                              await ref.read(mediaAccountRepositoryProvider).remove(a.id);
                              ref.invalidate(mediaAccountsProvider);
                            },
                          ),
                        ),
                    ]),
                  ]),
      ),
    );
  }
}

/// `/emby/accounts/add`: OBSERVED 添加账号 page (服务器类型 自动探测 / Emby / Jellyfin / Plex, 服务器地址, 用户名, 密码 可留空,
/// 登录并保存). Plex is not offered: this project has no Plex client.
class EmbyAddAccountScreen extends ConsumerStatefulWidget {
  const EmbyAddAccountScreen({super.key});
  @override
  ConsumerState<EmbyAddAccountScreen> createState() => _EmbyAddAccountScreenState();
}

class _EmbyAddAccountScreenState extends ConsumerState<EmbyAddAccountScreen> {
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  String _kind = 'auto';
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_url, _user, _pass]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final l = context.l10n;
    final url = _url.text.trim().replaceAll(RegExp(r'/+$'), '');
    if (url.isEmpty) return showToast(l.mediaAddressRequired);
    setState(() => _busy = true);
    try {
      final existing = await ref.read(mediaAccountsProvider.future);
      final user = _user.text.trim();
      var draft = MediaAccount(
          id: '${DateTime.now().millisecondsSinceEpoch}',
          name: Uri.tryParse(url)?.host ?? url,
          baseUrl: url,
          kind: _kind == 'auto' ? 'emby' : _kind);
      {
        // /System/Info/Public answers without signing in on both servers; Jellyfin names itself in ProductName.
        final info = await MediaServerClient(draft).publicInfo().catchError((_) => const <String, dynamic>{});
        final product = '${info['ProductName'] ?? ''}'.toLowerCase();
        final serverName = '${info['ServerName'] ?? ''}'.trim();
        draft = MediaAccount(
          id: draft.id,
          name: serverName.isEmpty ? draft.name : serverName,
          baseUrl: url,
          kind: _kind == 'auto' ? (product.contains('jellyfin') ? 'jellyfin' : 'emby') : _kind,
        );
      }
      final signedIn = await MediaServerClient(draft).login(user, _pass.text);
      if (existing.any((a) => a.baseUrl.replaceAll(RegExp(r'/+$'), '') == url && a.userId == signedIn.userId)) {
        showToast(l.mediaAccountExists);
        return;
      }
      await ref.read(mediaAccountRepositoryProvider).upsert(signedIn);
      ref.invalidate(mediaAccountsProvider);
      showToast(l.mediaSignedIn);
      if (mounted) context.pop();
    } catch (e) {
      showToast(l.signInFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = AppColors.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.mediaAddAccount)),
      body: ListView(padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + MediaQuery.paddingOf(context).bottom), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 8, 2, 8),
          child:
              Text(l.mediaServerType, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.subtitle)),
        ),
        AppSegmented<String>(
          segments: {'auto': (null, l.mediaAutoDetect), 'emby': (null, 'Emby'), 'jellyfin': (null, 'Jellyfin')},
          value: _kind,
          onChanged: (v) => setState(() => _kind = v),
        ),
        const SizedBox(height: 4),
        LabeledField(
            controller: _url,
            label: l.serverAddress,
            hint: l.mediaAddressHint,
            keyboardType: TextInputType.url,
            padding: bareFieldPadding),
        LabeledField(controller: _user, label: l.userName, padding: bareFieldPadding),
        PasswordField(controller: _pass, label: l.password, hint: l.mediaPasswordHint, padding: bareFieldPadding),
        const SizedBox(height: 16),
        PrimaryButton(icon: Icons.login, label: l.mediaSignInAndSave, expand: true, onPressed: _busy ? null : _submit),
      ]),
    );
  }
}

class _MediaCard extends StatelessWidget {
  const _MediaCard({required this.item, required this.client, required this.onTap});
  final MediaItem item;
  final MediaServerClient client;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox.expand(
                child: Image.network(client.imageUrl(item.seriesId ?? item.id),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => ColoredBox(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        child: const Icon(Icons.movie_outlined))),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(item.label, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
        ]),
      );
}

Widget _mediaGrid(BuildContext context, MediaServerClient client, String account, List<MediaItem> items) {
  final columns = (MediaQuery.sizeOf(context).width / 130).floor().clamp(2, 10);
  return GridView.builder(
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    padding: const EdgeInsets.all(12),
    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns, childAspectRatio: 0.6, crossAxisSpacing: 10, mainAxisSpacing: 10),
    itemCount: items.length,
    itemBuilder: (_, i) => _MediaCard(
      item: items[i],
      client: client,
      onTap: () => context.push(_routeTo('/emby/detail', {'account': account, 'id': items[i].id})),
    ),
  );
}

/// `/emby/search?account=`: continue watching + latest, or search results.
class EmbySearchScreen extends ConsumerStatefulWidget {
  const EmbySearchScreen({super.key, required this.account});
  final String account;
  @override
  ConsumerState<EmbySearchScreen> createState() => _EmbySearchScreenState();
}

class _EmbySearchScreenState extends ConsumerState<EmbySearchScreen> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(mediaClientProvider(widget.account)).valueOrNull;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(hintText: context.l10n.embySearchLibrary, isDense: true),
          onSubmitted: (v) => setState(() => _query = v.trim()),
        ),
        actions: [
          IconButton(
              tooltip: context.l10n.libraryFavorites,
              icon: const Icon(Icons.favorite_border),
              onPressed: () => context.push(_routeTo('/emby/favorites', {'account': widget.account})))
        ],
      ),
      body: client == null
          ? EmptyState(icon: Icons.dns_outlined, title: context.l10n.embyAccountNotFound)
          : _query.isNotEmpty
              ? ref.watch(embySearchProvider((account: widget.account, query: _query))).when(
                    loading: () => const Center(child: CircularProgressIndicator()),
                    error: (e, _) => ErrorState(error: e),
                    data: (items) => items.isEmpty
                        ? EmptyState(icon: Icons.search_off, title: context.l10n.noResults)
                        : SingleChildScrollView(child: _mediaGrid(context, client, widget.account, items)),
                  )
              : ref.watch(embyHomeProvider(widget.account)).when(
                    loading: () => const Center(child: CircularProgressIndicator()),
                    error: (e, _) => ErrorState(error: e),
                    data: (home) => ListView(children: [
                      if (home.resume.isNotEmpty) ...[
                        SectionHeader(context.l10n.embyContinueWatching),
                        _mediaGrid(context, client, widget.account, home.resume),
                      ],
                      SectionHeader(context.l10n.embyLatest),
                      _mediaGrid(context, client, widget.account, home.latest),
                    ]),
                  ),
    );
  }
}

/// `/emby/favorites?account=`.
class EmbyFavoritesScreen extends ConsumerWidget {
  const EmbyFavoritesScreen({super.key, required this.account});
  final String account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(mediaClientProvider(account)).valueOrNull;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.libraryFavorites)),
      body: client == null
          ? EmptyState(icon: Icons.dns_outlined, title: context.l10n.embyAccountNotFound)
          : ref.watch(embyFavoritesProvider(account)).when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => ErrorState(error: e),
                data: (items) => items.isEmpty
                    ? EmptyState(icon: Icons.favorite_border, title: context.l10n.favoritesEmptyTitle)
                    : SingleChildScrollView(child: _mediaGrid(context, client, account, items)),
              ),
    );
  }
}

/// `/emby/detail?account=&id=`: a movie (play) or a series (seasons and episodes).
class EmbyDetailScreen extends ConsumerStatefulWidget {
  const EmbyDetailScreen({super.key, required this.account, required this.id});
  final String account;
  final String id;
  @override
  ConsumerState<EmbyDetailScreen> createState() => _EmbyDetailScreenState();
}

class _EmbyDetailScreenState extends ConsumerState<EmbyDetailScreen> {
  late final Future<({MediaItem item, List<MediaItem> episodes})> _load = _fetch();
  int _season = 1;
  bool? _favorite;

  Future<({MediaItem item, List<MediaItem> episodes})> _fetch() async {
    // first evaluated from build(), so the localized message can be read before the first await
    final notFound = context.l10n.embyAccountNotFound;
    final client = await ref.read(mediaClientProvider(widget.account).future);
    if (client == null) throw StateError(notFound);
    final item = await client.item(widget.id);
    final episodes = item.isSeries ? await client.episodes(item.id) : <MediaItem>[];
    return (item: item, episodes: episodes);
  }

  Future<void> _play(MediaServerClient client, MediaItem item, List<MediaItem> all, int startIndex) async {
    try {
      await ref.read(playerLauncherProvider).playSource(
            MediaServerPlaybackSource(
                client: client, title: item.name, items: all, cover: client.imageUrl(item.id), memoryId: item.id),
            episode: startIndex,
          );
      ref.invalidate(embyHomeProvider);
    } catch (e) {
      showToast('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(mediaClientProvider(widget.account)).valueOrNull;
    return FutureBuilder(
      future: _load,
      builder: (context, snap) {
        final data = snap.data;
        final item = data?.item;
        return Scaffold(
          appBar: AppBar(
            title: Text(item?.name ?? ''),
            actions: [
              if (item != null && client != null)
                IconButton(
                  icon: Icon((_favorite ?? item.isFavorite) ? Icons.favorite : Icons.favorite_border),
                  onPressed: () async {
                    final next = !(_favorite ?? item.isFavorite);
                    try {
                      await client.setFavorite(item.id, next);
                      setState(() => _favorite = next);
                      ref.invalidate(embyFavoritesProvider);
                    } catch (e) {
                      showToast('$e');
                    }
                  },
                ),
            ],
          ),
          body: switch (snap.connectionState) {
            ConnectionState.done when snap.hasError => ErrorState(error: snap.error!),
            ConnectionState.done when data != null && client != null =>
              _body(context, client, data.item, data.episodes),
            _ => const Center(child: CircularProgressIndicator()),
          },
        );
      },
    );
  }

  Widget _body(BuildContext context, MediaServerClient client, MediaItem item, List<MediaItem> episodes) {
    final seasons = groupBySeason(episodes);
    final ordered = [for (final s in seasons.values) ...s];
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(client.imageUrl(item.id),
                width: 120, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox(width: 120, height: 180))),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.name, style: Theme.of(context).textTheme.titleLarge),
            if (item.year != null) Text('${item.year}'),
            const SizedBox(height: 8),
            if (!item.isSeries)
              FilledButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: Text(context.l10n.play),
                  onPressed: () => _play(client, item, [item], 0)),
          ]),
        ),
      ]),
      const SizedBox(height: 12),
      if ((item.overview ?? '').isNotEmpty) Text(item.overview!),
      if (item.isSeries && seasons.isNotEmpty) ...[
        const SizedBox(height: 12),
        SizedBox(
          height: 44,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (final s in seasons.keys)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                    label: Text(context.l10n.embySeason(s)),
                    selected: s == _season,
                    onSelected: (_) => setState(() => _season = s)),
              ),
          ]),
        ),
        for (final e in seasons[_season] ?? seasons.values.first)
          ListTile(
            title: Text(e.label),
            subtitle: e.positionTicks != null && e.positionTicks! > 0 ? Text(context.l10n.embyInProgress) : null,
            trailing: const Icon(Icons.play_arrow),
            // the whole series is queued so the player can move on to the next episode / season by itself
            onTap: () => _play(client, item, ordered, ordered.indexWhere((x) => x.id == e.id)),
          ),
      ],
    ]);
  }
}
