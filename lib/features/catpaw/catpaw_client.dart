import 'dart:async';
import 'dart:convert';

import '../../core/node_bridge.dart';
import 'catpaw_protocol.dart';

/// Typed facade over the `catpaw` channel: start / stop / reload instances and track their ports.
class CatpawClient {
  CatpawClient(this._bridge);

  final NodeBridge _bridge;
  final _events = StreamController<CatpawEvent>.broadcast();
  final _status = StreamController<String>.broadcast();
  final Map<String, int> _ports = {};
  StreamSubscription<String>? _catpawSub;
  StreamSubscription<String>? _statusSub;

  Stream<CatpawEvent> get events => _events.stream;

  /// Human readable log lines from the Node runtime (status channel).
  Stream<String> get statusLog => _status.stream;

  int? portOf(String name) => _ports[name];

  Future<void>? _attachFuture;
  bool _attached = false;

  /// Whether Node is up and announced itself (an earlier [attach] succeeded).
  bool get attached => _attached;

  /// Starts the runtime and completes once Node has connected and announced itself ("Node ready, version ...").
  /// Commands sent earlier would be rejected by the native plugin because the socket is not up yet.
  Future<void> attach() => _attachFuture ??= _attach().catchError((Object e, StackTrace st) {
        _attachFuture = null; // a failed start must not be cached: "Retry" has to try again
        Error.throwWithStackTrace(e, st);
      });

  Future<void> _attach() async {
    _catpawSub ??= _bridge.listen(Channels.catpaw).listen((raw) {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final event = CatpawEvent.parse(decoded.cast<String, dynamic>());
      if (event == null) return;
      if (event is CatpawPort) _ports[event.name] = event.port;
      if (event is CatpawList) {
        _ports
          ..removeWhere((k, _) => !event.services.any((s) => s.name == k))
          ..addEntries(event.services.where((s) => s.port != null).map((s) => MapEntry(s.name, s.port!)));
      }
      _events.add(event);
    });
    _statusSub ??= _bridge.listen(Channels.status).listen(_status.add);
    // The native side reports a runtime that could not start (missing libnode.so, ...) or that ended on the status
    // channel as well, so that case fails right away instead of after the 30 s timeout.
    final outcome = _status.stream
        .firstWhere((line) =>
            line.startsWith('Node ready') ||
            line.startsWith('Node runtime failed') ||
            line.startsWith('Node runtime exited'))
        .timeout(const Duration(seconds: 30));
    try {
      await _bridge.start();
    } catch (_) {
      outcome.ignore(); // its timeout must not surface later as an unhandled error
      rethrow;
    }
    final line = await outcome;
    if (!line.startsWith('Node ready')) throw StateError(line);
    _attached = true;
  }

  Future<void> _send(Map<String, Object?> cmd) => _bridge.send(Channels.catpaw, jsonEncode(cmd));

  Future<void> setDartPort(int port) => _send({'action': Actions.setDartPort, 'port': port});

  /// Starts [name] and completes with its port once the script's HTTP server is listening.
  Future<int> startAndWait({
    required String name,
    required String scriptPath,
    String? configPath,
    int? port,
    bool force = false,
    bool enableLog = false,
    bool enableNetLog = false,
    Map<String, String>? env,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final done = Completer<int>();
    final sub = events.listen((e) {
      if (e is CatpawPort && e.name == name && !done.isCompleted) done.complete(e.port);
      if (e is CatpawResult && e.name == name && e.action == Actions.start && !e.ok && !done.isCompleted) {
        done.completeError(StateError(e.error ?? 'start failed'));
      }
    });
    try {
      await _send({
        'action': Actions.start,
        'name': name,
        'path': scriptPath,
        if (configPath != null) 'configPath': configPath,
        if (port != null) 'port': port,
        'force': force,
        'enableLog': enableLog,
        'enableNetLog': enableNetLog,
        if (env != null) 'env': env,
      });
      return await done.future.timeout(timeout);
    } on TimeoutException {
      unawaited(stop(name).catchError((Object _) {}));
      rethrow;
    } finally {
      await sub.cancel();
    }
  }

  Future<void> stop(String name) => _send({'action': Actions.stop, 'name': name});

  /// Stops [name] and deletes its data directory.
  Future<void> uninstall(String name) => _send({'action': Actions.uninstall, 'name': name});

  Future<void> list() => _send({'action': Actions.list});

  Future<CatpawResult> _reload(String action, String name) async {
    final c = Completer<CatpawResult>();
    final sub = events.listen((e) {
      if (e is CatpawResult && e.action == action && e.name == name && !c.isCompleted) c.complete(e);
    });
    try {
      await _send({'action': action, 'name': name});
      return await c.future.timeout(const Duration(seconds: 6));
    } finally {
      await sub.cancel();
    }
  }

  /// Rebinds the instance's HTTP servers (used after subscription / network changes).
  Future<CatpawResult> reload(String name) => _reload(Actions.reload, name);

  /// Rebinds only the subscription danmu server (port 9321).
  Future<CatpawResult> reloadDanmu(String name) => _reload(Actions.reloadDanmu, name);

  Future<void> dispose() async {
    await _catpawSub?.cancel();
    await _statusSub?.cancel();
    await _events.close();
    await _status.close();
  }
}
