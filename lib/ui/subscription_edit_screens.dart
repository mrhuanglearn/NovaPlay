import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/providers.dart';
import '../app/router.dart';
import '../app/theme.dart';
import '../app/ui_hooks.dart';
import '../features/subscription/subscription.dart';
import '../l10n/l10n.dart';
import 'form_widgets.dart';
import 'lock_dialogs.dart';
import 'subscriptions_screen.dart';
import 'widgets.dart';

enum _SubscriptionKind { network, local, cloud }

/// `/subscriptions/add`. Layout OBSERVED on the original: 网络 / 本地 / 云端 segments, a hint line, a card with the address
/// (or archive picker) and 名称, 自动更新 (network only), 上锁, then 安装不受信任的订阅 (or 连接云端服务) and 无法添加？.
class AddSubscriptionScreen extends ConsumerStatefulWidget {
  const AddSubscriptionScreen({super.key});
  @override
  ConsumerState<AddSubscriptionScreen> createState() => _AddSubscriptionScreenState();
}

class _AddSubscriptionScreenState extends ConsumerState<AddSubscriptionScreen> {
  final _name = TextEditingController();
  final _url = TextEditingController();
  _SubscriptionKind _kind = _SubscriptionKind.network;
  bool _lock = false;
  bool _autoUpdate = false;
  bool _busy = false;
  ({String name, List<int> bytes})? _zip;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _pickZip() async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['zip']);
    if (f == null) return;
    final bytes = await f.readAsBytes();
    if (mounted) setState(() => _zip = (name: f.name, bytes: bytes));
  }

  Future<void> _save() async {
    final l = context.l10n;
    final service = ref.read(subscriptionServiceProvider);
    setState(() => _busy = true);
    try {
      final Subscription added;
      switch (_kind) {
        case _SubscriptionKind.network:
          if (_url.text.trim().isEmpty) return showToast(l.subscriptionUrlRequired);
          added = await service.addNetwork(
            url: _url.text,
            name: _name.text,
            autoUpdate: _autoUpdate,
            locked: _lock,
            confirmConfigMismatch: () => confirmConfigChecksumMismatch(rootNavigatorKey),
          );
        case _SubscriptionKind.local:
          final zip = _zip;
          if (zip == null) return showToast(l.subscriptionZipRequired);
          added = await service.addLocal(zip: zip.bytes, name: _name.text, locked: _lock);
        case _SubscriptionKind.cloud:
          if (_url.text.trim().isEmpty) return showToast(l.subscriptionUrlRequired);
          added = await service.addCloud(url: _url.text, name: _name.text, locked: _lock);
      }
      ref.invalidate(subscriptionsProvider);
      await ref.read(activeSubscriptionKeyProvider.notifier).select(added.key);
      refreshActiveSubscriptionRuntime(ref, resetCategory: true);
      if (!mounted) return;
      showSuccessHud(context, l.added);
      context.pop();
    } on DuplicateSubscriptionException {
      showToast(l.subscriptionDuplicate);
    } catch (e) {
      showToast(_kind == _SubscriptionKind.local ? l.subscriptionZipFailed('$e') : l.subscriptionDownloadFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setLock(bool v) async {
    if (v && !await confirmFirstLock(context, ref)) return;
    if (mounted) setState(() => _lock = v);
  }

  void _help() {
    final l = context.l10n;
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(l.notice),
        content: Text(l.subscriptionCantAddHelp),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(l.ok))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = AppColors.of(context);
    final existing = ref.watch(subscriptionsProvider).valueOrNull?.length ?? 0;
    final canLock = existing >= 1; // OBSERVED "仅有一个订阅时不支持上锁": the new one would be the only one
    final hint = switch (_kind) {
      _SubscriptionKind.network => l.subscriptionNetworkHint,
      _SubscriptionKind.local => l.subscriptionLocalHint,
      _SubscriptionKind.cloud => l.subscriptionCloudHint,
    };
    const spinner = SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));
    return Scaffold(
      appBar: AppBar(title: Text(l.subscriptionAdd, style: subscriptionBoldTitle)),
      body: ListView(padding: EdgeInsets.fromLTRB(0, 4, 0, 32 + MediaQuery.paddingOf(context).bottom), children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: AppSegmented<_SubscriptionKind>(
            value: _kind,
            onChanged: (v) => setState(() => _kind = v),
            segments: {
              _SubscriptionKind.network: (Icons.language, l.subscriptionKindNetwork),
              _SubscriptionKind.local: (Icons.folder_open_outlined, l.subscriptionKindLocal),
              _SubscriptionKind.cloud: (Icons.cloud_outlined, l.subscriptionKindCloud),
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 14, 22, 0),
          child: Text(hint, style: TextStyle(fontSize: 13, color: c.secondaryLabel)),
        ),
        SettingsSection(padding: const EdgeInsets.fromLTRB(16, 0, 16, 0), dividers: false, children: [
          if (_kind == _SubscriptionKind.local)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
              child: Material(
                color: c.cardHigh.withValues(alpha: 0.5),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12), side: BorderSide(color: c.separator)),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: _pickZip,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
                    child: Row(children: [
                      Icon(Icons.upload_outlined, color: AppColors.of(context).accent, size: 22),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(l.subscriptionLocalArchive, style: TextStyle(fontSize: 12.5, color: c.secondaryLabel)),
                          const SizedBox(height: 3),
                          Text(_zip?.name ?? l.subscriptionPickArchive,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 15.5, color: c.label)),
                        ]),
                      ),
                      Icon(Icons.chevron_right, color: c.secondaryLabel),
                    ]),
                  ),
                ),
              ),
            )
          else
            LabeledField(
              controller: _url,
              label: _kind == _SubscriptionKind.cloud ? l.subscriptionCloudAddress : l.subscriptionSourceUrl,
              hint:
                  _kind == _SubscriptionKind.cloud ? 'https://api.example.com' : 'https://user:pass@host/index.js.md5',
              keyboardType: TextInputType.url,
            ),
          LabeledField(controller: _name, label: l.name, hint: l.subscriptionNameHint),
        ]),
        if (_kind == _SubscriptionKind.network)
          SettingsSection(children: [
            SwitchRow(
              icon: Icons.sync,
              title: l.subscriptionAutoUpdate,
              subtitle: l.subscriptionAutoUpdateSub,
              value: _autoUpdate,
              onChanged: (v) => setState(() => _autoUpdate = v),
            ),
          ]),
        SettingsSection(children: [
          SwitchRow(
            icon: Icons.lock_rounded,
            title: l.subscriptionLock,
            subtitle: canLock ? l.subscriptionLockSub : l.subscriptionLockSingle,
            value: _lock && canLock,
            onChanged: canLock ? _setLock : null,
          ),
        ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 28, 16, 0),
          child: _kind == _SubscriptionKind.cloud
              ? FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                  onPressed: _busy ? null : _save,
                  icon: _busy ? spinner : const Icon(Icons.cloud_done_outlined, size: 20),
                  label: Text(l.subscriptionConnectCloud),
                )
              : FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.danger,
                    foregroundColor: AppColors.onDanger,
                    minimumSize: const Size.fromHeight(46),
                  ),
                  onPressed: _busy ? null : _save,
                  icon: _busy ? spinner : const Icon(Icons.warning_rounded, size: 20),
                  label: Text(l.subscriptionInstallUntrusted),
                ),
        ),
        const SizedBox(height: 18),
        Center(
          child: InkWell(
            onTap: _help,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Text(l.subscriptionCantAdd,
                  style: TextStyle(
                      fontSize: 14,
                      color: c.secondaryLabel,
                      decoration: TextDecoration.underline,
                      decorationColor: c.secondaryLabel)),
            ),
          ),
        ),
      ]),
    );
  }
}

/// `/subscriptions/edit/:subKey`. OBSERVED layout: read-only address with a lock, editable 名称, 自动更新, 上锁, an info
/// card (上次更新 / 内容指纹 = first 8 hex digits of the script md5) and 删除订阅.
class EditSubscriptionScreen extends ConsumerStatefulWidget {
  const EditSubscriptionScreen({super.key, required this.subKey});
  final String subKey;
  @override
  ConsumerState<EditSubscriptionScreen> createState() => _EditSubscriptionScreenState();
}

class _EditSubscriptionScreenState extends ConsumerState<EditSubscriptionScreen> {
  final _url = TextEditingController();
  final _name = TextEditingController();
  bool _loaded = false;
  bool _busy = false;

  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _update(Subscription Function(Subscription) change) async {
    final repo = ref.read(subscriptionRepositoryProvider);
    final current = (await repo.all()).where((s) => s.key == widget.subKey).firstOrNull;
    if (current == null) return;
    await repo.upsert(change(current));
    ref.invalidate(subscriptionsProvider);
  }

  Future<void> _setLock(bool v) async {
    if (v && !await confirmFirstLock(context, ref)) return;
    await _update((x) => x.copyWith(locked: v));
  }

  Future<void> _replaceZip(Subscription s) async {
    final l = context.l10n;
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['zip']);
    if (f == null) return;
    setState(() => _busy = true);
    try {
      await ref.read(subscriptionServiceProvider).replaceZip(s, await f.readAsBytes());
      ref.invalidate(subscriptionsProvider);
      final subs = await ref.read(subscriptionsProvider.future);
      if (effectiveActiveKey(subs, ref.read(activeSubscriptionKeyProvider).valueOrNull) == s.key) {
        refreshActiveSubscriptionRuntime(ref);
      }
      showToast(l.subscriptionUpdatedOne);
    } catch (e) {
      showToast(l.subscriptionZipFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(Subscription s) async {
    final l = context.l10n;
    if (!s.local && _url.text.trim().isEmpty) return showToast(l.subscriptionUrlRequired);
    setState(() => _busy = true);
    try {
      final subsBefore = await ref.read(subscriptionRepositoryProvider).all();
      final wasActive = effectiveActiveKey(subsBefore, ref.read(activeSubscriptionKeyProvider).valueOrNull) == s.key;
      await ref.read(subscriptionServiceProvider).updateSubscription(
            s,
            url: s.local ? null : _url.text,
            name: _name.text,
            forceRefreshScript: wasActive && !s.local && s.cloudUrl == null,
            confirmConfigMismatch: () => confirmConfigChecksumMismatch(rootNavigatorKey),
          );
      ref.invalidate(subscriptionsProvider);
      if (wasActive) {
        refreshActiveSubscriptionRuntime(ref, resetCategory: true);
      }
      if (!mounted) return;
      showSuccessHud(context, l.saved);
      context.pop();
    } on DuplicateSubscriptionException {
      showToast(l.subscriptionDuplicate);
    } catch (e) {
      showToast(l.subscriptionDownloadFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(Subscription s, List<Subscription> list) async {
    final ok = await deleteSubscriptionsAndRefresh(
      context,
      ref,
      all: list,
      doomed: [s],
      confirmMessage: context.l10n.subscriptionDeleteOneConfirm(s.name),
    );
    if (ok && mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final list = ref.watch(subscriptionsProvider).valueOrNull;
    final s = list?.where((x) => x.key == widget.subKey).firstOrNull;
    if (s != null && !_loaded) {
      _loaded = true;
      _url.text = subscriptionDisplayUrl(s);
      _name.text = s.name;
    }
    return Scaffold(
      appBar: AppBar(title: Text(l.subscriptionEdit, style: subscriptionBoldTitle)),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : s == null
              ? EmptyState(icon: Icons.error_outline, title: l.subscriptionNotFound)
              : ListView(padding: EdgeInsets.fromLTRB(0, 0, 0, 32 + MediaQuery.paddingOf(context).bottom), children: [
                  SettingsSection(dividers: false, children: [
                    if (s.local)
                      SettingsTile(
                        icon: Icons.folder_zip_outlined,
                        title: l.subscriptionReplaceZip,
                        subtitle: l.subscriptionReplaceZipSub,
                        trailing: _busy
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : null,
                        onTap: _busy ? null : () => _replaceZip(s),
                      )
                    else
                      LabeledField(
                        controller: _url,
                        label: s.cloudUrl != null ? l.subscriptionCloudAddress : l.subscriptionSourceUrl,
                        hint: s.cloudUrl != null
                            ? 'https://api.example.com'
                            : 'https://user:pass@host/index.js.md5',
                        keyboardType: TextInputType.url,
                      ),
                    LabeledField(
                      controller: _name,
                      label: l.name,
                      hint: l.subscriptionNameHint,
                    ),
                  ]),
                  if (s.indexJsUrl != null)
                    SettingsSection(children: [
                      SwitchRow(
                        icon: Icons.sync,
                        title: l.subscriptionAutoUpdate,
                        subtitle: l.subscriptionAutoUpdateSub,
                        value: s.autoUpdate,
                        onChanged: (v) => _update((x) => x.copyWith(autoUpdate: v)),
                      ),
                    ]),
                  SettingsSection(children: [
                    SwitchRow(
                      icon: Icons.lock_rounded,
                      title: l.subscriptionLock,
                      subtitle: list.length >= 2 ? l.subscriptionLockSub : l.subscriptionLockSingle,
                      value: s.locked,
                      onChanged: list.length >= 2 || s.locked ? _setLock : null,
                    ),
                  ]),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                    child: PrimaryButton(
                      label: l.save,
                      icon: _busy ? null : Icons.check_rounded,
                      expand: true,
                      height: 46,
                      onPressed: _busy ? null : () => _save(s),
                    ),
                  ),
                  if (s.cloudUrl == null)
                    SettingsSection(dividers: false, children: [
                      _InfoRow(
                          icon: Icons.schedule, label: l.subscriptionLastUpdated, value: relativeTime(l, s.updatedAt)),
                      _InfoRow(
                        icon: Icons.fingerprint,
                        label: l.subscriptionFingerprint,
                        value: (s.installedMd5 ?? '').length >= 8 ? s.installedMd5!.substring(0, 8) : '—',
                        mono: true,
                      ),
                    ]),
                  SettingsSection(children: [
                    SettingsTile(
                        icon: Icons.delete_outline,
                        title: l.subscriptionDelete,
                        destructive: true,
                        onTap: () => _delete(s, list)),
                  ]),
                ]),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.label, required this.value, this.mono = false});
  final IconData icon;
  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      child: Row(children: [
        Icon(icon, size: 19, color: c.secondaryLabel),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(fontSize: 15, color: c.label)),
        const Spacer(),
        Text(value,
            style:
                TextStyle(fontSize: mono ? 13.5 : 15, color: c.secondaryLabel, fontFamily: mono ? 'monospace' : null)),
      ]),
    );
  }
}
