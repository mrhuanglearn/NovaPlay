import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/extra_providers.dart';
import '../app/ui_hooks.dart';
import '../l10n/l10n.dart';
import 'widgets.dart';

/// 设置 → 重置应用. OBSERVED: the row (danger colour, 清空全部数据并重启) and the confirm dialog 重置应用 with 取消 / 删除.
/// INFERRED from the original's strings (pressing 删除 there would have erased its test data, which cannot be backed up
/// without root): a 正在重置… dialog while the files are deleted, then 所有数据已清空，应用将退出，请重新打开。 with 确定,
/// after which the process ends; on an error 重置失败，请重试.
Future<void> confirmAndResetApp(BuildContext context, WidgetRef ref) async {
  final l = context.l10n;
  if (!await confirmAction(context, title: l.settingsReset, message: l.resetConfirmBody, destructive: true)) return;
  if (!context.mounted) return;
  final service = ref.read(appResetServiceProvider);
  final exitApp = ref.read(appExitProvider);
  final navigator = Navigator.of(context, rootNavigator: true);

  showDialog<void>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: false,
    builder: (c) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
          const SizedBox(width: 18),
          Expanded(child: Text(l.resetInProgress)),
        ]),
      ),
    ),
  );
  try {
    await service.reset();
  } catch (_) {
    navigator.pop();
    showToast(l.resetFailed);
    return;
  }
  navigator.pop();
  if (!context.mounted) return exitApp();

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (c) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Text(l.resetDone),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: Text(l.ok))],
      ),
    ),
  );
  try {
    await service.wipe(); // anything written while the message was up
  } catch (_) {
    // The process ends anyway; what is left is deleted by the next reset.
  }
  await exitApp();
}
