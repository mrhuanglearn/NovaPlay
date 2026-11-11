import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/providers.dart';
import '../app/theme.dart';
import '../app/ui_hooks.dart';
import '../features/backup/backup_service.dart';
import '../services/tmdb_client.dart';
import '../services/webdav_sync.dart';
import '../l10n/l10n.dart';
import 'form_widgets.dart';
import 'player_settings_screens.dart' show SettingsNote;
import 'restore_flow.dart';
import 'subscriptions_screen.dart' show relativeTime;
import 'widgets.dart';

/// `/settings/tmdb`. OBSERVED unconnected layout: two-card illustration, 连接 TMDB, description, API Key field, a 连接
/// button that stays grey until a key is entered, and a 去申请 API Key link. The connected layout could not be seen
/// (no key); INFERRED from the strings 启用 TMDB, 断开 TMDB 连接？ and 将清除 API Key 并停用 TMDB 功能，代理配置会保留.
class TmdbSettingsScreen extends ConsumerStatefulWidget {
  const TmdbSettingsScreen({super.key});
  @override
  ConsumerState<TmdbSettingsScreen> createState() => _TmdbSettingsScreenState();
}

class _TmdbSettingsScreenState extends ConsumerState<TmdbSettingsScreen> {
  final _key = TextEditingController();
  final _api = TextEditingController();
  final _image = TextEditingController();
  final _lang = TextEditingController();
  final _wait = TextEditingController();
  TmdbSettings? _saved;
  bool _busy = false;
  bool _showAdvanced = false;

  @override
  void initState() {
    super.initState();
    _key.addListener(() => setState(() {}));
    ref.read(tmdbSettingsStoreProvider).read<Map<String, dynamic>>(<String, dynamic>{}).then((j) {
      final s = TmdbSettings.fromJson(j);
      if (!mounted) return;
      setState(() {
        _saved = s;
        _api.text = s.apiBase;
        _image.text = s.imageBase;
        _lang.text = s.language;
        _wait.text = '${s.matchWaitSeconds}';
      });
    });
  }

  @override
  void dispose() {
    for (final c in [_key, _api, _image, _lang, _wait]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _connected => (_saved?.apiKey ?? '').isNotEmpty;

  TmdbSettings _with({bool? enabled, String? apiKey}) => TmdbSettings(
        enabled: enabled ?? _saved?.enabled ?? false,
        apiKey: apiKey ?? _saved?.apiKey ?? '',
        apiBase: _api.text.trim(),
        imageBase: _image.text.trim(),
        language: _lang.text.trim().isEmpty ? 'zh-CN' : _lang.text.trim(),
        matchWaitSeconds: (int.tryParse(_wait.text.trim()) ?? 5).clamp(1, 60),
      );

  Future<void> _write(TmdbSettings s) async {
    await ref.read(tmdbSettingsStoreProvider).write(s.toJson());
    ref.invalidate(tmdbProvider);
    if (mounted) setState(() => _saved = s);
  }

  Future<void> _connect() async {
    final l = context.l10n;
    final candidate = _with(enabled: true, apiKey: _key.text.trim());
    setState(() => _busy = true);
    try {
      if (!await TmdbClient(candidate).testConnection()) {
        showToast(l.tmdbConnectionFailed);
        return;
      }
      await _write(candidate);
      _key.clear();
      showToast(l.connectionOk);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    final l = context.l10n;
    if (!await confirmAction(context,
        title: l.tmdbDisconnectTitle,
        message: l.tmdbDisconnectBody,
        confirmLabel: l.tmdbDisconnect,
        destructive: true)) {
      return;
    }
    await _write(_with(enabled: false, apiKey: ''));
  }

  Future<void> _test() async {
    final l = context.l10n;
    setState(() => _busy = true);
    final ok = await TmdbClient(_with()).testConnection();
    if (mounted) setState(() => _busy = false);
    showToast(ok ? l.connectionOk : l.tmdbConnectionFailed);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = AppColors.of(context);
    final saved = _saved;
    if (saved == null) {
      return Scaffold(
          appBar: AppBar(title: Text(l.settingsTmdb)), body: const Center(child: CircularProgressIndicator()));
    }
    final key = saved.apiKey;
    final advanced = SettingsSection(title: l.tmdbProxyGroup, children: [
      CommitTextRow(
          controller: _api, label: l.tmdbApiBase, hint: 'https://api.themoviedb.org', onCommit: (_) => _write(_with())),
      CommitTextRow(
          controller: _image,
          label: l.tmdbImageBase,
          hint: 'https://image.tmdb.org/t/p',
          onCommit: (_) => _write(_with())),
      CommitTextRow(controller: _lang, label: l.language, hint: 'zh-CN', onCommit: (_) => _write(_with())),
      CommitTextRow(controller: _wait, label: l.tmdbMatchWait, hint: '5', onCommit: (_) => _write(_with())),
    ]);
    return Scaffold(
      appBar: AppBar(title: Text(l.settingsTmdb)),
      body: ListView(padding: EdgeInsets.fromLTRB(0, 0, 0, 32 + MediaQuery.paddingOf(context).bottom), children: [
        Padding(
          // OBSERVED positions (dp): art top 104, title 34 below the art, 14.5 description
          padding: const EdgeInsets.fromLTRB(20, 104, 20, 0),
          child: Column(children: [
            const _TmdbArt(),
            const SizedBox(height: 34),
            Text(_connected ? l.tmdbConnected : l.tmdbConnectTitle,
                style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700, color: c.label)),
            const SizedBox(height: 10),
            Text(l.tmdbConnectDescription,
                textAlign: TextAlign.center, style: TextStyle(fontSize: 14.5, height: 1.35, color: c.subtitle)),
          ]),
        ),
        if (!_connected) ...[
          const SizedBox(height: 26),
          LabeledField(
              controller: _key,
              label: 'API Key',
              hint: l.tmdbKeyHint,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8)),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size(double.infinity, 51),
                disabledBackgroundColor: c.cardHigh,
                disabledForegroundColor: c.secondaryLabel,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: _busy || _key.text.trim().isEmpty ? null : _connect,
              icon: const Icon(Icons.link, size: 20),
              label: Text(l.tmdbConnect, style: const TextStyle(fontSize: 16)),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: TextButton(
              onPressed: () => context.push(
                  Uri(path: '/website', queryParameters: {'url': 'https://www.themoviedb.org/settings/api'})
                      .toString()),
              child: Text(l.tmdbGetKey, style: const TextStyle(fontSize: 12.5)),
            ),
          ),
          Center(
            child: TextButton.icon(
              onPressed: () => setState(() => _showAdvanced = !_showAdvanced),
              icon: Icon(_showAdvanced ? Icons.expand_less : Icons.expand_more, size: 18, color: c.secondaryLabel),
              label: Text(l.tmdbProxyGroup, style: TextStyle(fontSize: 12.5, color: c.secondaryLabel)),
            ),
          ),
          if (_showAdvanced) advanced,
        ] else ...[
          const SizedBox(height: 8),
          SettingsSection(children: [
            SwitchRow(
              icon: Icons.movie_filter_outlined,
              title: l.tmdbEnable,
              subtitle: l.tmdbEnableSub,
              value: saved.enabled,
              onChanged: (v) => _write(_with(enabled: v)),
            ),
            SettingsTile(
              icon: Icons.key_outlined,
              title: 'API Key',
              subtitle: key.length <= 4 ? '••••' : '••••••••${key.substring(key.length - 4)}',
              trailing: TextButton(onPressed: _busy ? null : _test, child: Text(l.testConnection)),
            ),
            SettingsTile(icon: Icons.link_off, title: l.tmdbDisconnect, destructive: true, onTap: _disconnect),
          ]),
          advanced,
          SettingsNote(l.tmdbKeyStorageNote),
        ],
      ]),
    );
  }
}

/// OBSERVED header art: a grey outlined card behind a blue card with a light block and two text lines.
class _TmdbArt extends StatelessWidget {
  const _TmdbArt();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return SizedBox(
      width: 76,
      height: 97,
      child: Stack(children: [
        Positioned(
          left: 0,
          top: 0,
          child: Container(
            width: 52,
            height: 74,
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: c.secondaryLabel.withValues(alpha: 0.7), width: 1.6)),
          ),
        ),
        Positioned(
          left: 23,
          top: 23,
          child: Container(
            width: 53,
            height: 74,
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            decoration: BoxDecoration(color: AppColors.of(context).accent, borderRadius: BorderRadius.circular(8)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                  height: 30,
                  decoration: BoxDecoration(color: const Color(0xFF1E5BB8), borderRadius: BorderRadius.circular(5))),
              const SizedBox(height: 9),
              Container(height: 3, color: const Color(0xFF0B2A5A)),
              const SizedBox(height: 5),
              Container(height: 3, width: 24, color: const Color(0xFF0B2A5A)),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// `/settings/webdav`. OBSERVED unconfigured state: grey cloud-off icon, 尚未配置 WebDAV 同步, description, 添加配置.
/// The configured state could not be seen (no server); INFERRED from the strings 启用同步, 立即同步, 正在同步…, 尚未同步,
/// "多端数据同步（可自选类型）" and "WebDAV 同步跳过：未选择任何数据类型".
class WebDavSettingsScreen extends ConsumerStatefulWidget {
  const WebDavSettingsScreen({super.key});
  @override
  ConsumerState<WebDavSettingsScreen> createState() => _WebDavSettingsScreenState();
}

class _WebDavSettingsScreenState extends ConsumerState<WebDavSettingsScreen> {
  WebDavConfig? _config;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final j = await ref.read(webDavConfigStoreProvider).read<Map<String, dynamic>>(<String, dynamic>{});
    if (mounted) setState(() => _config = WebDavConfig.fromJson(j));
  }

  Future<void> _write(WebDavConfig c) async {
    await ref.read(webDavConfigStoreProvider).write(c.toJson());
    if (mounted) setState(() => _config = c);
  }

  Future<void> _sync() async {
    final l = context.l10n;
    final cfg = _config!;
    if (cfg.documents.isEmpty) return showToast(l.webdavNoTypes);
    setState(() => _busy = true);
    try {
      await ref.read(webDavSyncProvider)(cfg).sync(documents: cfg.documents);
      await _write(cfg.copyWith(lastSyncMs: DateTime.now().millisecondsSinceEpoch));
      showToast(l.webdavSyncDone);
    } catch (e) {
      showToast(l.webdavSyncFailed(e is WebDavException ? e.message : '$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editConfig() async {
    await context.push('/settings/webdav/config');
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = AppColors.of(context);
    final cfg = _config;
    return Scaffold(
      appBar: AppBar(title: Text(l.settingsWebdav)),
      body: cfg == null
          ? const Center(child: CircularProgressIndicator())
          : !cfg.isConfigured
              ? EmptyState(
                  icon: Icons.cloud_off_outlined,
                  plain: true,
                  title: l.webdavEmptyTitle,
                  subtitle: l.webdavEmptySubtitle,
                  actionGap: 18,
                  action: PrimaryButton(label: l.webdavAddConfig, onPressed: _editConfig),
                )
              : ListView(padding: EdgeInsets.only(bottom: 32 + MediaQuery.paddingOf(context).bottom), children: [
                  SettingsSection(children: [
                    SettingsTile(
                      icon: Icons.cloud_outlined,
                      title: cfg.username.isEmpty ? cfg.url : cfg.username,
                      subtitle:
                          [cfg.url, if (cfg.subPath.isNotEmpty) '${l.webdavIsolation}: ${cfg.subPath}'].join('\n'),
                      onTap: _editConfig,
                    ),
                    SwitchRow(
                      icon: Icons.sync,
                      title: l.webdavEnableSync,
                      subtitle: l.webdavEnableSyncSub,
                      value: cfg.enabled,
                      onChanged: (v) => _write(cfg.copyWith(enabled: v)),
                    ),
                  ]),
                  SettingsSection(title: l.webdavTypesGroup, children: [
                    for (final (type, icon, title, sub) in [
                      ('favorites', Icons.favorite_border, l.webdavTypeFavorites, l.webdavTypeFavoritesSub),
                      ('history', Icons.history, l.webdavTypeHistory, l.webdavTypeHistorySub),
                      ('tracking', Icons.calendar_month_outlined, l.webdavTypeTracking, l.webdavTypeTrackingSub),
                      ('tmdb', Icons.movie_filter_outlined, l.webdavTypeTmdb, l.webdavTypeTmdbSub),
                      ('player', Icons.play_circle_outline, l.webdavTypePlayer, l.webdavTypePlayerSub),
                      ('live', Icons.live_tv_rounded, l.webdavTypeLive, l.webdavTypeLiveSub),
                    ])
                      SwitchRow(
                        icon: icon,
                        title: title,
                        subtitle: sub,
                        value: cfg.types.contains(type),
                        onChanged: (v) => _write(cfg.copyWith(
                          types: [
                            for (final t in webdavDataTypeOrder)
                              if (t == type ? v : cfg.types.contains(t)) t
                          ],
                        )),
                      ),
                  ]),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                    child: PrimaryButton(
                        icon: Icons.sync,
                        label: _busy ? l.webdavSyncing : l.webdavSyncNow,
                        expand: true,
                        onPressed: _busy ? null : _sync),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                    child: Text(
                      cfg.lastSyncMs == null ? l.webdavNeverSynced : l.webdavLastSync(relativeTime(l, cfg.lastSyncMs)),
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12.5, color: c.secondaryLabel),
                    ),
                  ),
                  SettingsSection(children: [
                    SettingsTile(
                      icon: Icons.cloud_download_outlined,
                      title: l.backupRestoreWebdavTitle,
                      subtitle: l.backupRestoreWebdavSub,
                      onTap: _busy
                          ? null
                          : () async {
                              if (!await confirmAction(context,
                                  title: l.restoreConfirmTitle,
                                  message: l.restoreConfirmBody,
                                  confirmLabel: l.restore,
                                  plainConfirm: true)) {
                                return;
                              }
                              if (!context.mounted) return;
                              final sync = ref.read(webDavSyncProvider)(cfg);
                              await runRestore(
                                  context, ref, () async => (await sync.restoreAll(documents: cfg.documents)).pulled,
                                  describe: (e) => l.webdavSyncFailed(e is WebDavException ? e.message : '$e'));
                            },
                    ),
                  ]),
                  SettingsNote(l.webdavNote),
                ]),
    );
  }
}

/// `/settings/webdav/config` (OBSERVED: WebDAV 配置 with 隔离名称, 服务地址, 账号, 密码 and a full-width 保存). Saving checks
/// the connection first.
class WebDavConfigScreen extends ConsumerStatefulWidget {
  const WebDavConfigScreen({super.key});
  @override
  ConsumerState<WebDavConfigScreen> createState() => _WebDavConfigScreenState();
}

class _WebDavConfigScreenState extends ConsumerState<WebDavConfigScreen> {
  final _sub = TextEditingController();
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  WebDavConfig? _old;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    ref.read(webDavConfigStoreProvider).read<Map<String, dynamic>>(<String, dynamic>{}).then((j) {
      final c = WebDavConfig.fromJson(j);
      if (!mounted) return;
      setState(() {
        _old = c;
        _sub.text = c.subPath;
        _url.text = c.url;
        _user.text = c.username;
        _pass.text = c.password;
      });
    });
  }

  @override
  void dispose() {
    for (final c in [_sub, _url, _user, _pass]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final l = context.l10n;
    if (_url.text.trim().isEmpty || _user.text.trim().isEmpty || _pass.text.isEmpty) {
      return showToast(l.webdavFillRequired);
    }
    final old = _old ?? const WebDavConfig(url: '', username: '', password: '');
    final cfg = old.copyWith(
      url: _url.text.trim(),
      username: _user.text.trim(),
      password: _pass.text,
      subPath: _sub.text.trim(),
      // INFERRED: a new configuration starts with sync switched on
      enabled: old.isConfigured ? old.enabled : true,
    );
    setState(() => _busy = true);
    try {
      await WebDavClient(cfg).checkConnection();
      await ref.read(webDavConfigStoreProvider).write(cfg.toJson());
      showToast(l.saved);
      if (mounted) context.pop();
    } on WebDavException catch (e) {
      showToast(e.kind == 'auth' ? l.webdavAuthFailed : '${l.webdavConnectFailed}: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l.webdavConfigTitle)),
      body: ListView(padding: EdgeInsets.only(bottom: 32 + MediaQuery.paddingOf(context).bottom), children: [
        SettingsSection(dividers: false, children: [
          LabeledField(controller: _sub, label: l.webdavIsolation, hint: l.webdavIsolationHint),
          LabeledField(
              controller: _url,
              label: l.webdavServiceAddress,
              hint: l.webdavServiceAddressHint,
              keyboardType: TextInputType.url),
          LabeledField(controller: _user, label: l.webdavAccountLabel, hint: l.webdavAccountHint),
          PasswordField(controller: _pass, label: l.password, hint: l.webdavPasswordHint),
        ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
          child: PrimaryButton(label: l.save, expand: true, onPressed: _busy || _old == null ? null : _save),
        ),
      ]),
    );
  }
}

/// `/settings/backup` (OBSERVED: 导出备份 → 选择数据项并导出 "打包为 zip 保存到 uzData/Data/Backups"; 从备份恢复 → 选择备份文件恢复
/// "从 zip 备份包覆盖恢复数据"). The zip is written to the app's external files folder (Backups) and offered to share.
class BackupScreen extends ConsumerWidget {
  const BackupScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.read(backupServiceProvider);
    final l = context.l10n;

    Future<void> restore() async {
      final Uint8List? picked;
      try {
        picked = await ref.read(backupPickerProvider)();
      } catch (e) {
        // Seen on Waydroid for a file the media store had not indexed yet (file_picker: "Failed to retrieve path.").
        return showToast(l.restoreFileFailed(e is PlatformException ? e.message ?? e.code : '$e'));
      }
      if (picked == null || !context.mounted) return;
      // OBSERVED: the file is checked as soon as it is picked; a wrong one gets the error box and no sheet.
      final BackupContents contents;
      try {
        contents = service.read(picked);
      } on FormatException {
        return showErrorHud(context, l.restoreNotBackup);
      }
      final chosen = await showModalBottomSheet<Set<String>>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        backgroundColor: AppColors.of(context).page,
        builder: (_) => _BackupRestoreSheet(contents: contents),
      );
      if (chosen == null || chosen.isEmpty || !context.mounted) return;
      // OBSERVED: 确认恢复 comes after the sheet closes; 取消 goes back to the page.
      if (!await confirmAction(context,
          title: l.restoreConfirmTitle, message: l.restoreConfirmBody, confirmLabel: l.restore, plainConfirm: true)) {
        return;
      }
      if (!context.mounted) return;
      await runRestore(context, ref, () => service.restore(contents, chosen), describe: (e) => '$e');
    }

    return Scaffold(
      appBar: AppBar(title: Text(l.settingsBackup)),
      body: ListView(padding: EdgeInsets.only(bottom: 32 + MediaQuery.paddingOf(context).bottom), children: [
        SettingsSection(title: l.backupGroupExport, children: [
          SettingsTile(
            icon: Icons.archive_outlined,
            title: l.backupExportItems,
            subtitle: l.backupExportItemsSub,
            onTap: () async {
              final path = await showModalBottomSheet<String>(
                context: context,
                isScrollControlled: true,
                showDragHandle: true,
                backgroundColor: AppColors.of(context).page,
                builder: (_) => _BackupExportSheet(service: service, saver: ref.read(backupSaverProvider)),
              );
              if (path != null && context.mounted) await _showExportDone(context, ref, path);
            },
          ),
        ]),
        SettingsSection(title: l.backupGroupRestore, children: [
          SettingsTile(
              icon: Icons.settings_backup_restore,
              title: l.backupRestoreFile,
              subtitle: l.backupRestoreFileSub,
              onTap: restore),
        ]),
      ]),
    );
  }
}

class _BackupExportSheet extends StatefulWidget {
  const _BackupExportSheet({required this.service, required this.saver});
  final BackupService service;
  final Future<String> Function(String fileName, List<int> bytes) saver;
  @override
  State<_BackupExportSheet> createState() => _BackupExportSheetState();
}

class _BackupExportSheetState extends State<_BackupExportSheet> {
  final _chosen = {
    for (final i in backupItems)
      if (i.byDefault) i.key
  };
  bool _busy = false;

  /// Saves the zip and closes the sheet with its path; 导出完成 is shown by the page.
  Future<void> _export() async {
    final l = context.l10n;
    final saver = widget.saver;
    setState(() => _busy = true);
    try {
      final bytes = await widget.service.exportZip(_chosen);
      final path = await saver(backupFileName(DateTime.now()), bytes);
      if (mounted) Navigator.pop(context, path);
    } catch (_) {
      showToast(l.exportFailed);
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = AppColors.of(context);
    final all = _chosen.length == backupItems.length;
    final sensitive = backupItems.any((i) => i.sensitive && _chosen.contains(i.key));
    Widget row(String text, bool value, ValueChanged<bool> onChanged, {bool card = true}) =>
        _choiceRow(context, text, value, onChanged, card: card);
    Widget header(String text) => _choiceGroupHeader(context, text);
    final groups = _backupGroups(l);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.86,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 12 + MediaQuery.paddingOf(context).bottom),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l.settingsBackup, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: c.label)),
          const SizedBox(height: 6),
          Text(l.backupSheetDescription, style: TextStyle(fontSize: 12, height: 1.4, color: c.subtitle)),
          const SizedBox(height: 4),
          row(l.selectAll, all,
              (v) => setState(() => v ? _chosen.addAll(backupItems.map((i) => i.key)) : _chosen.clear()),
              card: false),
          Divider(color: c.separator),
          Expanded(
            child: ListView(children: [
              for (final (g, title) in groups) ...[
                header(title),
                for (final i in backupItems.where((i) => i.group == g))
                  row(_backupItemLabel(l, i.key), _chosen.contains(i.key),
                      (v) => setState(() => v ? _chosen.add(i.key) : _chosen.remove(i.key))),
              ],
            ]),
          ),
          if (sensitive)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.warning_amber_rounded, size: 15, color: AppColors.danger),
                const SizedBox(width: 6),
                Expanded(
                    child: Text(l.backupSensitiveWarning,
                        style: const TextStyle(fontSize: 11.5, height: 1.4, color: AppColors.danger))),
              ]),
            ),
          const SizedBox(height: 10),
          // OBSERVED: greyed out while nothing is chosen. INFERRED: 正在导出… while the zip is written.
          PrimaryButton(
              label: _busy ? l.exporting : l.backupExportButton,
              expand: true,
              onPressed: _busy || _chosen.isEmpty ? null : _export),
        ]),
      ),
    );
  }
}

/// OBSERVED after 选择数据项并导出 (two exports of the original): 导出完成 / 备份文件已保存：<file name> and, whatever was
/// chosen, 备份可能包含账号、密码等敏感信息，分享时请注意。 in red; 完成 (accent) closes it, 分享 (text colour) closes it and opens
/// the system share sheet. INFERRED: 分享失败 when sharing throws.
Future<void> _showExportDone(BuildContext context, WidgetRef ref, String path) async {
  final l = context.l10n;
  final share = ref.read(backupShareProvider);
  final shareIt = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(l.exportDoneTitle),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l.exportSavedAs(path.split('/').last)),
        const SizedBox(height: 8),
        // 13: the original wraps this line one character later than at 13.5.
        Text(l.exportShareWarning, style: TextStyle(fontSize: 13, color: AppColors.dangerText(c))),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.done)),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: AppColors.of(c).label),
          onPressed: () => Navigator.pop(c, true),
          child: Text(l.share),
        ),
      ],
    ),
  );
  if (shareIt != true) return;
  try {
    await share(path, l.backupShareText);
  } catch (_) {
    showToast(l.shareFailed);
  }
}

String _backupItemLabel(AppLocalizations l, String key) => switch (key) {
      'history' => l.backupItemHistory,
      'favorites' => l.backupItemFavorites,
      'progress' => l.backupItemProgress,
      'lastEpisode' => l.backupItemLastEpisode,
      'tmdbRefs' => l.backupItemTmdbRefs,
      'headTail' => l.backupItemHeadTail,
      'tracking' => l.backupItemTracking,
      'danmuRefs' => l.backupItemDanmuRefs,
      'live' => l.backupItemLive,
      'subscriptions' => l.backupItemSubscriptions,
      'appSettings' => l.backupItemAppSettings,
      _ => l.backupItemAccounts,
    };

List<(String, String)> _backupGroups(AppLocalizations l) => [
      ('user', l.backupGroupUser),
      ('subscriptions', l.backupGroupSubscriptions),
      ('preferences', l.backupGroupPreferences)
    ];

/// A check box row of the export and restore sheets; [card] rows are tinted while chosen (OBSERVED in both sheets).
Widget _choiceRow(BuildContext context, String text, bool value, ValueChanged<bool> onChanged, {bool card = true}) {
  final c = AppColors.of(context);
  return Padding(
    padding: EdgeInsets.only(bottom: card ? 8 : 0),
    child: Material(
      color: card ? (value ? Color.alphaBlend(c.accent.withValues(alpha: 0.10), c.card) : c.card) : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(children: [
            Icon(value ? Icons.check_box : Icons.check_box_outline_blank,
                color: value ? c.accent : c.subtitle, size: 22),
            const SizedBox(width: 14),
            Expanded(child: Text(text, style: TextStyle(fontSize: 14.5, color: c.label))),
          ]),
        ),
      ),
    ),
  );
}

Widget _choiceGroupHeader(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.fromLTRB(2, 10, 2, 8),
      child:
          Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.of(context).accent)),
    );

/// 选择备份文件恢复, after the file was read. OBSERVED (2026-11-09, with the user's consent, a backup of the original
/// opened and cancelled): title 备份与恢复, 备份时间：yyyy-MM-dd HH:mm, 来源版本：v1.1.13（android）, 勾选要恢复的数据项…, 全选,
/// then only the items in the backup, grouped as on the export sheet and all chosen; the header stays while the list
/// scrolls; no sensitive-data warning; 恢复 is greyed out and does nothing while nothing is chosen. Pops the chosen keys.
class _BackupRestoreSheet extends StatefulWidget {
  const _BackupRestoreSheet({required this.contents});
  final BackupContents contents;
  @override
  State<_BackupRestoreSheet> createState() => _BackupRestoreSheetState();
}

class _BackupRestoreSheetState extends State<_BackupRestoreSheet> {
  late final _available = widget.contents.items;
  late final _chosen = {..._available};

  static String _time(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = AppColors.of(context);
    final contents = widget.contents;
    final all = _available.isNotEmpty && _chosen.length == _available.length;
    final info = TextStyle(fontSize: 12, height: 1.4, color: c.subtitle);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.86,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 12 + MediaQuery.paddingOf(context).bottom),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l.settingsBackup, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: c.label)),
          const SizedBox(height: 6),
          if (contents.createdAt case final t?) Text(l.backupCreatedAt(_time(t)), style: info),
          if (contents.appVersion case final v?) Text(l.backupSourceVersion(v, contents.platform ?? '?'), style: info),
          const SizedBox(height: 14),
          Text(l.backupRestoreSheetDescription, style: info),
          const SizedBox(height: 4),
          _choiceRow(context, l.selectAll, all, (v) => setState(() => v ? _chosen.addAll(_available) : _chosen.clear()),
              card: false),
          Divider(color: c.separator),
          Expanded(
            child: ListView(children: [
              for (final (g, title) in _backupGroups(l))
                if (backupItems.any((i) => i.group == g && _available.contains(i.key))) ...[
                  _choiceGroupHeader(context, title),
                  for (final i in backupItems.where((i) => i.group == g && _available.contains(i.key)))
                    _choiceRow(context, _backupItemLabel(l, i.key), _chosen.contains(i.key),
                        (v) => setState(() => v ? _chosen.add(i.key) : _chosen.remove(i.key))),
                ],
            ]),
          ),
          const SizedBox(height: 10),
          PrimaryButton(
              label: l.restore,
              expand: true,
              onPressed: _chosen.isEmpty ? null : () => Navigator.pop(context, {..._chosen})),
        ]),
      ),
    );
  }
}
