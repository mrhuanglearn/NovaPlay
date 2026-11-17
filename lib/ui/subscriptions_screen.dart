import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/app_lock.dart';
import '../app/providers.dart';
import '../app/router.dart';
import '../app/theme.dart';
import '../app/ui_hooks.dart';
import '../features/subscription/subscription.dart';
import '../l10n/l10n.dart';
import 'lock_dialogs.dart';
import 'widgets.dart';

export 'subscription_edit_screens.dart';

const subscriptionBoldTitle = TextStyle(fontSize: 18, fontWeight: FontWeight.w700);
const _boldTitle = subscriptionBoldTitle;

/// "刚刚" / "N 分钟前" / "N 小时前" / "N 天前" (OBSERVED wording).
String relativeTime(AppLocalizations l, int? epochMs, {DateTime? now}) {
  if (epochMs == null) return '—';
  final d = (now ?? DateTime.now()).difference(DateTime.fromMillisecondsSinceEpoch(epochMs));
  if (d.inMinutes < 1) return l.timeJustNow;
  if (d.inHours < 1) return l.timeMinutesAgo(d.inMinutes);
  if (d.inDays < 1) return l.timeHoursAgo(d.inHours);
  return l.timeDaysAgo(d.inDays);
}

/// [all] after moving the [from]th of the [shown] subscriptions to [to] (an onReorderItem index, which already accounts
/// for the removed item). Hidden (locked) subscriptions keep their places; the shown ones fill the other places.
List<Subscription> reorderShown(List<Subscription> all, List<Subscription> shown, int from, int to) {
  final moved = [...shown];
  moved.insert(to, moved.removeAt(from));
  final shownKeys = {for (final s in shown) s.key};
  final it = moved.iterator;
  return [for (final s in all) shownKeys.contains(s.key) ? (it..moveNext()).current : s];
}

/// The subscription whose sites are shown: the selected one, else the first (same rule as catpawRuntimeProvider).
String? effectiveActiveKey(List<Subscription> list, String? selected) {
  if (list.isEmpty) return null;
  return list.any((s) => s.key == selected) ? selected : list.first.key;
}

String subscriptionDisplayUrl(Subscription s) => s.cloudUrl ?? s.indexJsUrl ?? '';
String _displayUrl(Subscription s) => subscriptionDisplayUrl(s);

String _chipLabel(AppLocalizations l, Subscription s) =>
    s.cloudUrl != null ? l.subscriptionChipCloud : (s.local ? l.subscriptionChipLocal : l.subscriptionChipNetwork);

IconData _kindIcon(Subscription s) =>
    s.cloudUrl != null ? Icons.cloud_outlined : (s.local ? Icons.folder_zip_outlined : Icons.rss_feed);

void refreshActiveSubscriptionRuntime(WidgetRef ref, {bool resetCategory = false}) {
  if (resetCategory) ref.read(selectedTypeIdProvider.notifier).select(null);
  ref.invalidate(catpawRuntimeProvider);
  ref.invalidate(videoFeedProvider);
  ref.read(catpawRuntimeProvider);
}

Future<bool> deleteSubscriptionsAndRefresh(
  BuildContext context,
  WidgetRef ref, {
  required List<Subscription> all,
  required List<Subscription> doomed,
  required String confirmMessage,
}) async {
  if (doomed.isEmpty) return false;
  if (!await confirmSubscriptionDelete(context, confirmMessage)) return false;
  final savedSelected = ref.read(activeSubscriptionKeyProvider).valueOrNull;
  final currentActive = effectiveActiveKey(all, savedSelected);
  final doomedKeys = {for (final s in doomed) s.key};
  final deletedActive = currentActive != null && doomedKeys.contains(currentActive);
  for (final s in doomed) {
    try {
      await ref.read(catpawClientProvider).uninstall(s.key);
    } catch (e) {
      debugPrint('uninstall catpaw ${s.key} ignored: $e');
    }
  }
  await ref.read(subscriptionServiceProvider).removeAll(doomed);
  final remaining = await ref.read(subscriptionRepositoryProvider).all();
  if (deletedActive || (savedSelected != null && doomedKeys.contains(savedSelected))) {
    await ref.read(activeSubscriptionKeyProvider.notifier).select(remaining.firstOrNull?.key);
  }
  ref.invalidate(subscriptionsProvider);
  if (deletedActive) {
    refreshActiveSubscriptionRuntime(ref, resetCategory: true);
  }
  return true;
}

Future<void> _refreshOne(BuildContext context, WidgetRef ref, Subscription s) async {
  final l = context.l10n;
  try {
    final updated = await ref.read(subscriptionServiceProvider).refresh(
          s,
          confirmConfigMismatch: () => confirmConfigChecksumMismatch(rootNavigatorKey),
        );
    ref.invalidate(subscriptionsProvider);
    if (updated == null) {
      showToast(l.subscriptionUpToDate(s.name));
    } else {
      final subs = await ref.read(subscriptionsProvider.future);
      final active = effectiveActiveKey(subs, ref.read(activeSubscriptionKeyProvider).valueOrNull);
      if (active == s.key) refreshActiveSubscriptionRuntime(ref);
      showToast(l.subscriptionUpdatedOne);
    }
  } catch (e) {
    showToast(l.subscriptionCheckFailed('$e'));
  }
}

/// `/subscriptions` (设置 → 订阅管理).
class SubscriptionsScreen extends ConsumerStatefulWidget {
  const SubscriptionsScreen({super.key});
  @override
  ConsumerState<SubscriptionsScreen> createState() => _SubscriptionsScreenState();
}

class _SubscriptionsScreenState extends ConsumerState<SubscriptionsScreen> {
  bool _editing = false;
  final _selected = <String>{};
  final _refreshing = <String>{};
  bool _refreshingAll = false;

  Future<void> _refresh(Subscription s) async {
    setState(() => _refreshing.add(s.key));
    await _refreshOne(context, ref, s);
    if (mounted) setState(() => _refreshing.remove(s.key));
  }

  Future<void> _refreshAll(List<Subscription> list) async {
    final l = context.l10n;
    setState(() => _refreshingAll = true);
    showToast(l.subscriptionChecking);
    final service = ref.read(subscriptionServiceProvider);
    final active = effectiveActiveKey(list, ref.read(activeSubscriptionKeyProvider).valueOrNull);
    var updated = 0;
    Object? failure;
    for (final s in list.where((s) => s.indexJsUrl != null)) {
      try {
        if (await service.refresh(s, confirmConfigMismatch: () => confirmConfigChecksumMismatch(rootNavigatorKey)) !=
            null) {
          updated++;
          if (s.key == active) refreshActiveSubscriptionRuntime(ref);
        }
      } catch (e) {
        failure ??= e;
      }
    }
    ref.invalidate(subscriptionsProvider);
    if (!mounted) return;
    setState(() => _refreshingAll = false);
    if (failure != null) {
      showToast(l.subscriptionCheckFailed('$failure'));
    } else {
      showToast(updated == 0 ? l.subscriptionAllUpToDate : l.subscriptionUpdatedCount(updated));
    }
  }

  Future<void> _activate(Subscription s) async {
    await ref.read(activeSubscriptionKeyProvider.notifier).select(s.key);
    refreshActiveSubscriptionRuntime(ref, resetCategory: true);
    if (mounted) showToast(context.l10n.subscriptionSwitchedTo(s.name));
  }

  Future<void> _deleteSelected(List<Subscription> list) async {
    final doomed = list.where((s) => _selected.contains(s.key)).toList();
    final ok = await deleteSubscriptionsAndRefresh(
      context,
      ref,
      all: list,
      doomed: doomed,
      confirmMessage: context.l10n.subscriptionDeleteSelectedConfirm(doomed.length),
    );
    if (ok && mounted) setState(_selected.clear);
  }

  /// Reorders the shown subscriptions; hidden (locked) ones keep their places in the saved order.
  Future<void> _reorder(List<Subscription> all, List<Subscription> shown, int from, int to) async {
    await ref.read(subscriptionRepositoryProvider).save(reorderShown(all, shown, from, to));
    ref.invalidate(subscriptionsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final subs = ref.watch(subscriptionsProvider);
    final all = subs.valueOrNull ?? const <Subscription>[];
    final unlocked = ref.watch(subscriptionsUnlockedProvider);
    final list = visibleSubscriptions(all, unlocked: unlocked);
    final active = effectiveActiveKey(all, ref.watch(activeSubscriptionKeyProvider).valueOrNull);
    final allSelected = list.isNotEmpty && _selected.length == list.length;
    // OBSERVED: a closed lock while subscriptions are hidden (tap = 验证锁密码), an open one after (tap = lock again).
    final lockButton = IconButton(
      tooltip: unlocked ? l.lockRelock : l.lockUnlockSubscriptions,
      icon: Icon(unlocked ? Icons.lock_open_outlined : Icons.lock),
      onPressed: () =>
          unlocked ? ref.read(subscriptionsUnlockedProvider.notifier).relock() : unlockSubscriptions(context, ref),
    );
    final addButton = IconButton(
        tooltip: l.subscriptionAdd, icon: const Icon(Icons.add), onPressed: () => context.push('/subscriptions/add'));
    // User request (2026-11-10): back (system key or the app bar arrow) first leaves the edit mode and stays here. The
    // original 1.1.7 leaves the page instead.
    return PopScope(
      canPop: !_editing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _editing) {
          setState(() {
            _editing = false;
            _selected.clear();
          });
        }
      },
      child: _scaffold(context, l, all, list, active, allSelected, lockButton, addButton),
    );
  }

  Widget _scaffold(BuildContext context, AppLocalizations l, List<Subscription> all, List<Subscription> list,
      String? active, bool allSelected, Widget lockButton, Widget addButton) {
    final subs = ref.watch(subscriptionsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(l.subscriptions, style: _boldTitle),
        actions: all.isEmpty
            ? null
            : list.isEmpty
                ? [lockButton, addButton] // OBSERVED with every subscription hidden
                : _editing
                    ? [
                        TextButton(
                          onPressed: () => setState(
                              () => allSelected ? _selected.clear() : _selected.addAll(list.map((s) => s.key))),
                          child: Text(allSelected ? l.deselectAll : l.selectAll),
                        ),
                        TextButton(
                          onPressed: () => setState(() {
                            _editing = false;
                            _selected.clear();
                          }),
                          child: Text(l.done),
                        ),
                        const SizedBox(width: 4),
                      ]
                    : [
                        if (all.any((s) => s.locked)) lockButton,
                        _refreshingAll
                            ? const Padding(
                                padding: EdgeInsets.all(14),
                                child:
                                    SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                              )
                            : IconButton(icon: const Icon(Icons.sync), onPressed: () => _refreshAll(all)),
                        TextButton(onPressed: () => setState(() => _editing = true), child: Text(l.edit)),
                        addButton,
                      ],
      ),
      bottomNavigationBar: _editing && list.isNotEmpty
          ? _SelectionBar(count: _selected.length, onDelete: () => _deleteSelected(all))
          : null,
      body: subs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorState(error: e, onRetry: () => ref.invalidate(subscriptionsProvider)),
        data: (all) {
          if (all.isEmpty) return const _EmptySubscriptions();
          if (list.isEmpty) return const _HiddenSubscriptions();
          final bottom = 24 + MediaQuery.paddingOf(context).bottom;
          if (_editing) {
            return ReorderableListView.builder(
              padding: EdgeInsets.fromLTRB(0, 8, 0, bottom),
              buildDefaultDragHandles: false,
              itemCount: list.length,
              onReorderItem: (a, b) => _reorder(all, list, a, b),
              itemBuilder: (context, i) => _EditRow(
                key: ValueKey(list[i].key),
                index: i,
                sub: list[i],
                selected: _selected.contains(list[i].key),
                onTap: () => setState(
                    () => _selected.contains(list[i].key) ? _selected.remove(list[i].key) : _selected.add(list[i].key)),
              ),
            );
          }
          return ListView(padding: EdgeInsets.fromLTRB(0, 14, 0, bottom), children: [
            for (final s in list)
              _SubscriptionCard(
                sub: s,
                active: s.key == active,
                refreshing: _refreshing.contains(s.key),
                onTap: () => context.push('/subscriptions/edit/${Uri.encodeComponent(s.key)}'),
                onRefresh: () => _refresh(s),
                onActivate: () => _activate(s),
              ),
          ]);
        },
      ),
    );
  }
}

Future<bool> confirmSubscriptionDelete(BuildContext context, String message) async {
  final l = context.l10n;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(l.subscriptionDelete),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.cancel)),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: AppColors.dangerText(c)),
          onPressed: () => Navigator.pop(c, true),
          child: Text(l.delete),
        ),
      ],
    ),
  );
  return ok == true;
}

/// OBSERVED when every subscription is locked and hidden: a grey lock and 有已上锁的订阅被隐藏.
class _HiddenSubscriptions extends StatelessWidget {
  const _HiddenSubscriptions();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.lock, size: 48, color: c.secondaryLabel),
        const SizedBox(height: 10),
        Text(context.l10n.lockHiddenSubscriptions, style: TextStyle(fontSize: 13.5, color: c.secondaryLabel)),
      ]),
    );
  }
}

class _EmptySubscriptions extends StatelessWidget {
  const _EmptySubscriptions();

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = AppColors.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(36, 24, 36, 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const _StackedCardsArt(),
          const SizedBox(height: 32),
          Text(l.subscriptionsEmptyTitle, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c.label)),
          const SizedBox(height: 10),
          Text(l.subscriptionsEmptySubtitle,
              textAlign: TextAlign.center, style: TextStyle(fontSize: 14.5, color: c.secondaryLabel)),
          const SizedBox(height: 36),
          FilledButton.icon(
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
                textStyle: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w500)),
            onPressed: () => context.push('/subscriptions/add'),
            icon: const Icon(Icons.add, size: 22),
            label: Text(l.subscriptionAdd),
          ),
        ]),
      ),
    );
  }
}

/// The original's empty-state art: two outlined cards behind a filled accent card with three text lines.
class _StackedCardsArt extends StatelessWidget {
  const _StackedCardsArt();

  @override
  Widget build(BuildContext context) {
    final outline = AppColors.of(context).secondaryLabel.withValues(alpha: 0.45);
    Widget ghost(double left, double top) => Positioned(
          left: left,
          top: top,
          child: Container(
            width: 86,
            height: 58,
            decoration:
                BoxDecoration(border: Border.all(color: outline, width: 1.6), borderRadius: BorderRadius.circular(10)),
          ),
        );
    Widget line(double w) => Container(
          width: w,
          height: 4,
          margin: const EdgeInsets.only(bottom: 6),
          decoration: BoxDecoration(color: const Color(0xFF16346B), borderRadius: BorderRadius.circular(2)),
        );
    return SizedBox(
      width: 116,
      height: 90,
      child: Stack(children: [
        ghost(0, 0),
        ghost(14, 12),
        Positioned(
          left: 28,
          top: 28,
          child: Container(
            width: 86,
            height: 58,
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
            decoration: BoxDecoration(color: AppColors.of(context).accent, borderRadius: BorderRadius.circular(10)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [line(60), line(44), line(52)]),
          ),
        ),
      ]),
    );
  }
}

class _KindChip extends StatelessWidget {
  const _KindChip(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: c.cardHigh.withValues(alpha: 0.75), borderRadius: BorderRadius.circular(4)),
      child: Text(text, style: TextStyle(fontSize: 10, color: c.secondaryLabel)),
    );
  }
}

class _SubscriptionCard extends StatelessWidget {
  const _SubscriptionCard({
    required this.sub,
    required this.active,
    required this.refreshing,
    required this.onTap,
    required this.onRefresh,
    required this.onActivate,
  });
  final Subscription sub;
  final bool active;
  final bool refreshing;
  final VoidCallback onTap;
  final VoidCallback onRefresh;
  final VoidCallback onActivate;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = AppColors.of(context);
    // OBSERVED colours: active card #1B2027 with a #163150 border, inactive card #2C2C2E; icon tile accent / #28323F
    final bg = active ? Color.alphaBlend(AppColors.of(context).accent.withValues(alpha: 0.07), c.page) : c.card;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
              color: active ? AppColors.of(context).accent.withValues(alpha: 0.4) : c.separator.withValues(alpha: 0.6)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            child: Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: active ? AppColors.of(context).accent : AppColors.of(context).accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(11),
                  boxShadow: active
                      ? [BoxShadow(color: AppColors.of(context).accent.withValues(alpha: 0.45), blurRadius: 14)]
                      : null,
                ),
                child: Icon(_kindIcon(sub),
                    color: active ? AppColors.of(context).onAccent : AppColors.of(context).accent, size: 21),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(sub.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: active ? AppColors.of(context).accent : c.label)),
                  const SizedBox(height: 5),
                  Row(children: [
                    _KindChip(_chipLabel(l, sub)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(_displayUrl(sub),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: c.secondaryLabel)),
                    ),
                  ]),
                  const SizedBox(height: 4),
                  Text(l.subscriptionLastUpdatedAt(relativeTime(l, sub.updatedAt)),
                      style: TextStyle(fontSize: 10, color: c.secondaryLabel)),
                ]),
              ),
              if (sub.indexJsUrl != null)
                refreshing
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : IconButton(icon: Icon(Icons.sync, size: 20, color: c.secondaryLabel), onPressed: onRefresh),
              const SizedBox(width: 2),
              active
                  ? Container(
                      height: 27,
                      padding: const EdgeInsets.symmetric(horizontal: 11),
                      decoration:
                          BoxDecoration(color: AppColors.of(context).accent, borderRadius: BorderRadius.circular(14)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.check, size: 15, color: AppColors.of(context).onAccent),
                        const SizedBox(width: 4),
                        Text(l.subscriptionActive,
                            style: TextStyle(
                                fontSize: 12, color: AppColors.of(context).onAccent, fontWeight: FontWeight.w500)),
                      ]),
                    )
                  : Material(
                      color: AppColors.of(context).accent.withValues(alpha: 0.14),
                      shape:
                          StadiumBorder(side: BorderSide(color: AppColors.of(context).accent.withValues(alpha: 0.7))),
                      child: InkWell(
                        customBorder: const StadiumBorder(),
                        onTap: onActivate,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                          child: Text(l.subscriptionActivate,
                              style: TextStyle(fontSize: 12, color: AppColors.of(context).accent)),
                        ),
                      ),
                    ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _EditRow extends StatelessWidget {
  const _EditRow({super.key, required this.index, required this.sub, required this.selected, required this.onTap});
  final int index;
  final Subscription sub;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Material(
        color: selected ? Color.alphaBlend(AppColors.of(context).accent.withValues(alpha: 0.07), c.page) : c.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
              color:
                  selected ? AppColors.of(context).accent.withValues(alpha: 0.5) : c.separator.withValues(alpha: 0.6)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            child: Row(children: [
              Icon(selected ? Icons.check_box : Icons.check_box_outline_blank,
                  size: 24, color: selected ? AppColors.of(context).accent : c.secondaryLabel),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(sub.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: c.label)),
                  const SizedBox(height: 5),
                  Row(children: [
                    _KindChip(_chipLabel(l, sub)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(_displayUrl(sub),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: c.secondaryLabel)),
                    ),
                  ]),
                ]),
              ),
              const SizedBox(width: 8),
              ReorderableDragStartListener(
                index: index,
                child: Container(
                  width: 40,
                  height: 40,
                  decoration:
                      BoxDecoration(color: c.cardHigh.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(9)),
                  child: Icon(Icons.drag_indicator, color: c.secondaryLabel),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({required this.count, required this.onDelete});
  final int count;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = AppColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(color: c.page, border: Border(top: BorderSide(color: c.separator))),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 16, 12),
          child: Row(children: [
            Text(l.selectedCount(count), style: TextStyle(fontSize: 16, color: c.label)),
            const Spacer(),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.danger,
                side: const BorderSide(color: AppColors.danger),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                minimumSize: const Size(92, 44),
              ),
              onPressed: count == 0 ? null : onDelete,
              icon: const Icon(Icons.delete_outline, size: 20),
              label: Text(l.delete),
            ),
          ]),
        ),
      ),
    );
  }
}
