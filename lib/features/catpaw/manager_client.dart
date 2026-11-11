import 'dart:async';
import 'dart:convert';

import '../../core/node_bridge.dart';
import 'catpaw_protocol.dart';

/// Typed facade over the `manager` channel: standalone Node scripts (danmu_api style) that are installed once and
/// started / stopped on demand. Wire format: node_host/src/services.js. Every non-`list` command is acknowledged
/// with a `result` event followed by a fresh `list` snapshot.
class ManagerClient {
  ManagerClient(this._bridge);

  final NodeBridge _bridge;
  final _events = StreamController<CatpawEvent>.broadcast();
  StreamSubscription<String>? _sub;
  List<CatpawInstance> _services = const [];

  List<CatpawInstance> get services => _services;

  Stream<CatpawEvent> get events => _events.stream;

  /// Idempotent. The Node runtime must already be attached (see `CatpawClient.attach`).
  void listen() {
    _sub ??= _bridge.listen(Channels.manager).listen((raw) {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final event = CatpawEvent.parse(decoded.cast<String, dynamic>());
      if (event == null) return;
      if (event is CatpawList) _services = event.services;
      _events.add(event);
    });
  }

  Future<void> _send(Map<String, Object?> cmd) => _bridge.send(Channels.manager, jsonEncode(cmd));

  Future<CatpawResult> _ack(String action, String name, Map<String, Object?> cmd) async {
    listen();
    final done = Completer<CatpawResult>();
    final sub = events.listen((e) {
      if (e is CatpawResult && e.action == action && e.name == name && !done.isCompleted) done.complete(e);
    });
    try {
      await _send({'action': action, 'name': name, ...cmd});
      return await done.future.timeout(const Duration(seconds: 10));
    } finally {
      await sub.cancel();
    }
  }

  Future<CatpawResult> install(String name, String scriptPath, {int? defaultPort}) =>
      _ack(Actions.install, name, {'path': scriptPath, if (defaultPort != null) 'defaultPort': defaultPort});

  Future<CatpawResult> start(String name, {int? port, Map<String, String>? env, bool enableLog = true}) =>
      _ack(Actions.start, name, {if (port != null) 'port': port, if (env != null) 'env': env, 'enableLog': enableLog});

  Future<CatpawResult> stop(String name) => _ack(Actions.stop, name, const {});

  Future<CatpawResult> uninstall(String name) => _ack(Actions.uninstall, name, const {});

  /// Stops and restarts a running service with its previous port / env (e.g. after the script file changed).
  Future<CatpawResult> reload(String name) => _ack(Actions.reload, name, const {});

  Future<List<CatpawInstance>> refresh() async {
    listen();
    final next = events.firstWhere((e) => e is CatpawList).timeout(const Duration(seconds: 5));
    await _send({'action': Actions.list});
    await next;
    return _services;
  }

  CatpawInstance? find(String name) {
    for (final s in _services) {
      if (s.name == name) return s;
    }
    return null;
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _events.close();
  }
}
