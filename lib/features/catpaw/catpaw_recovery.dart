import 'dart:async';

import '../subscription/subscription.dart';
import 'catpaw_client.dart';
import 'catpaw_protocol.dart';
import 'dart_callback_server.dart';
import 'spider_api.dart';

/// Supervises the local CatPaw runtime across idle / background resume and on-demand connection failures
/// (matching the original app's `[recover]` flow: verify `DartCallbackServer` -> probe `/config` -> `reload` -> fallback `restart`).
class CatpawSupervisor {
  CatpawSupervisor({
    required this.catpaw,
    required this.callbackServer,
    required this.activeSubscription,
    required this.currentApi,
    required this.restartInstance,
    this.isRuntimeStarting,
    this.log,
  });

  final CatpawClient catpaw;
  final DartCallbackServer callbackServer;
  final Future<Subscription?> Function() activeSubscription;
  final SpiderApi? Function() currentApi;
  final Future<int?> Function(Subscription sub) restartInstance;
  final bool Function()? isRuntimeStarting;
  final void Function(String message)? log;

  Future<int?>? _inFlight;

  /// Triggered when the app returns to foreground (`AppLifecycleState.resumed`).
  Future<int?> onAppResumed() => _coalesce(() => _recover(probeFirst: true));

  /// Triggered immediately when a local `SpiderApi` call hits `connectionError` / `connectionTimeout`.
  Future<int?> recoverNow() => _coalesce(() => _recover(probeFirst: false));

  Future<int?> _coalesce(Future<int?> Function() work) {
    final existing = _inFlight;
    if (existing != null) return existing;
    final fut = work().whenComplete(() => _inFlight = null);
    _inFlight = fut;
    return fut;
  }

  Future<int?> _recover({required bool probeFirst}) async {
    if (probeFirst && (isRuntimeStarting?.call() ?? false) && currentApi() == null) return null;
    final sub = await activeSubscription();
    if (sub == null || sub.cloudUrl != null) return null;

    // 1. Ensure DartCallbackServer is alive and sync its port to Node (and live workers).
    try {
      final cbPort = await callbackServer.ensureRunning();
      if (catpaw.attached) {
        await catpaw.setDartPort(cbPort);
      }
    } catch (e) {
      log?.call('[recover] DartCallbackServer check failed: $e');
    }

    final api = currentApi();
    if (probeFirst && api != null) {
      if (await api.probe()) return api.port;
      log?.call('[recover] /config 探活失败 port=${api.port}, 尝试 reload');
    }

    // 2. Fast path: in-place `reload` re-listens the worker's HTTP server while preserving spider memory/session.
    if (catpaw.attached && catpaw.portOf(sub.key) != null) {
      try {
        final reloaded = await catpaw.reload(sub.key);
        if (reloaded.ok) {
          final nextPort = catpaw.portOf(sub.key) ?? api?.port;
          if (nextPort != null) {
            api?.updateLocalPort(nextPort);
            final healthy = await (api ?? SpiderApi(nextPort)).probe();
            if (healthy) {
              unawaited(
                catpaw
                    .reloadDanmu(sub.key)
                    .catchError((Object _) => const CatpawResult(action: Actions.reloadDanmu, name: '', ok: false)),
              );
              log?.call('[recover] reload 成功 port=$nextPort');
              return nextPort;
            }
          }
        }
      } catch (e) {
        log?.call('[recover] reload 异常: $e');
      }
    }

    // 3. Fallback: restart the CatPaw worker (`force: true`) and update the runtime port.
    log?.call('[recover] reload 后仍不可用, 兜底 restart (${sub.key})');
    try {
      final restartedPort = await restartInstance(sub);
      if (restartedPort != null) {
        api?.updateLocalPort(restartedPort);
        return restartedPort;
      }
    } catch (e) {
      log?.call('[recover] restart 失败: $e');
    }
    return null;
  }
}
