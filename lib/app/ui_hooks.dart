import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

/// Lets non-UI code (the Dart callback server answering `toast`) show a snackbar on the root messenger.
final rootMessengerKey = GlobalKey<ScaffoldMessengerState>();

void showToast(String message, {Duration duration = const Duration(seconds: 3)}) {
  rootMessengerKey.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), duration: duration));
}

/// The original's "配置文件校验不一致" question, asked from the subscription installer. True = use the config anyway.
/// With no navigator mounted (tests, background start) the config is used, as when the checksum file is missing.
Future<bool> confirmConfigChecksumMismatch(GlobalKey<NavigatorState> navigatorKey) async {
  final context = navigatorKey.currentContext;
  if (context == null) return true;
  final l = context.l10n;
  final answer = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(l.configChecksumMismatchTitle),
      content: Text(l.configChecksumMismatchBody),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.cancel)),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(l.ok)),
      ],
    ),
  );
  return answer ?? false;
}
