import 'package:flutter/services.dart';

/// Haptic feedback helper backed by the Android `uzv/haptics` MethodChannel (`Haptics.kt`),
/// gated by `PlaybackConfig.hapticEnabled` ("设置" -> "功能设置" -> "触感反馈").
class AppHaptics {
  AppHaptics._();

  static const MethodChannel _channel = MethodChannel('uzv/haptics');

  /// Whether haptic feedback is enabled (persisted in `player_config.json` as `hapticEnabled`).
  static bool enabled = true;

  static Future<void> _invoke(String kind, {bool force = false}) async {
    if (!enabled && !force) return;
    try {
      await _channel.invokeMethod<void>(kind);
    } catch (_) {
      // Ignored in tests or on platforms without the channel.
    }
  }

  static void selection({bool force = false}) {
    _invoke('selection', force: force);
  }

  static void light({bool force = false}) {
    _invoke('light', force: force);
  }

  static void medium({bool force = false}) {
    _invoke('medium', force: force);
  }

  static void heavy({bool force = false}) {
    _invoke('heavy', force: force);
  }
}
