import 'package:flutter/services.dart';

const _channel = MethodChannel('uzv/app');

/// Ends the app's task and its process (`MainActivity`). Finishing the activity is not enough after 重置应用: the
/// embedded Node runtime cannot be started twice in one process, and the providers still hold the old data.
/// Without the native side (tests, other platforms) it falls back to closing the activity.
Future<void> exitApp() async {
  try {
    await _channel.invokeMethod<void>('exit');
  } on MissingPluginException {
    await SystemNavigator.pop();
  }
}
