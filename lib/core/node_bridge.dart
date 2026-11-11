import 'dart:async';

import 'package:flutter/services.dart';

/// Dart side of the four `flutter-bridge` string channels exposed by the embedded Node runtime.
///
/// OBSERVED: the Node side registers channels `status`, `catpaw`, `manager`, `netlog` and exchanges plain
/// strings (JSON for `catpaw` / `manager`). INFERRED: how the native plugin ("flutter_nodejs_mobile",
/// libflutter_nodejs_mobile.so) surfaces them to Dart - the MethodChannel / EventChannel names below are
/// this project's own choice and must be matched by android/.../NodeBridgePlugin.kt.
abstract class NodeBridge {
  /// Starts the Node runtime (idempotent) with the bundled `nodejs/index.js` project.
  Future<void> start();

  /// Sends [message] to the Node-side listener of [channel].
  Future<void> send(String channel, String message);

  /// Messages Node sent on [channel].
  Stream<String> listen(String channel);
}

class MethodChannelNodeBridge implements NodeBridge {
  MethodChannelNodeBridge()
      : _method = const MethodChannel('uzv/node'),
        _events = const EventChannel('uzv/node/events');

  final MethodChannel _method;
  final EventChannel _events;
  Stream<Map<Object?, Object?>>? _shared;

  @override
  Future<void> start() => _method.invokeMethod<void>('start');

  @override
  Future<void> send(String channel, String message) =>
      _method.invokeMethod<void>('send', {'channel': channel, 'message': message});

  @override
  Stream<String> listen(String channel) {
    _shared ??= _events.receiveBroadcastStream().cast<Map<Object?, Object?>>().asBroadcastStream();
    return _shared!.where((e) => e['channel'] == channel).map((e) => e['message'] as String);
  }
}
