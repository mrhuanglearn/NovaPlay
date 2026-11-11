import 'dart:async';

import 'package:uzv_reimpl/core/node_bridge.dart';

/// In-memory [NodeBridge]: records what Dart sent and lets a test play the part of the Node runtime.
class FakeBridge implements NodeBridge {
  final sent = <(String, String)>[];
  final _controllers = <String, StreamController<String>>{};
  bool started = false;

  /// Called for every message Dart sends; use [emit] inside to answer.
  void Function(String channel, String message)? onSend;

  StreamController<String> _c(String channel) => _controllers.putIfAbsent(channel, () => StreamController<String>.broadcast());

  void emit(String channel, String message) => _c(channel).add(message);

  /// What the "runtime" announces on the status channel after [start]; null = nothing (a hung runtime).
  String? statusOnStart = 'Node ready, version test';

  /// If set, [start] throws it (the native plugin answering the MethodChannel call with an error).
  Object? startError;

  @override
  Future<void> start() async {
    started = true;
    final error = startError;
    if (error != null) throw error;
    // Node announces itself on the status channel once its socket is up.
    final status = statusOnStart;
    if (status != null) scheduleMicrotask(() => emit('status', status));
  }

  @override
  Future<void> send(String channel, String message) async {
    sent.add((channel, message));
    onSend?.call(channel, message);
  }

  @override
  Stream<String> listen(String channel) => _c(channel).stream;
}
