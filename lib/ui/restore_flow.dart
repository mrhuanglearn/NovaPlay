import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/extra_providers.dart';
import '../app/ui_hooks.dart';
import '../core/restore_error.dart';
import '../l10n/l10n.dart';

/// 从备份恢复 and 从 WebDAV 恢复, after the confirm dialog. OBSERVED strings of the original: 正在恢复…,
/// 数据已恢复，应用即将退出，请重新打开。 and 恢复过程中出错，建议重启应用. INFERRED, as for 重置应用: a progress dialog, then the message
/// with 确定, then the process ends. Exiting is what makes restored data take effect: everything loaded before (the
/// preferences, the active subscription and its running script, live sources…) is stale, and saving a preference
/// would write the old values back over the restored settings.json.
///
/// [restore] returns the restored file names. [describe] turns any error other than a [RestoreWriteException] (those
/// mean nothing was written) into the message shown; the app keeps running then.
Future<void> runRestore(BuildContext context, WidgetRef ref, Future<List<String>> Function() restore,
    {required String Function(Object error) describe}) async {
  final l = context.l10n;
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
          Expanded(child: Text(l.restoreInProgress)),
        ]),
      ),
    ),
  );
  final List<String> restored;
  try {
    restored = await restore();
  } on RestoreWriteException {
    navigator.pop();
    showToast(l.restoreWriteFailed);
    return;
  } catch (e) {
    navigator.pop();
    showToast(describe(e));
    return;
  }
  navigator.pop();
  if (restored.isEmpty) return showToast(l.backupRestored(0));
  if (!context.mounted) return exitApp();
  await showDialog<void>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: false,
    builder: (c) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Text(l.restoreDone),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: Text(l.ok))],
      ),
    ),
  );
  await exitApp();
}
