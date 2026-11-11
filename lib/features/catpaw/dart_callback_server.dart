import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Loopback HTTP server that lets catpaw scripts call back into the Dart app.
///
/// OBSERVED: the Dart pool contains `DartServer(`, "doStart: DartServer(", "[recover] DartServer(",
/// "Node ready; dart callback :" and the setting "Dart callback port (empty=random)"; the Node side exposes the port
/// to scripts through `catDartServerPort()` after the app sends `setDartPort`; the action names a script may invoke are
/// listed in [DartActions] (queryProfile, saveProfile, sniff, toast, danmuPush, openInternalWebview, ...).
/// OBSERVED on the phone (2026-11-10, a real subscription): the 「设」配置 script sends
/// `POST /msg {"action":"openInternalWebview","opt":{"url":...}}`. INFERRED: the answer shape
/// `{"ok":true,"data":...}` / `{"ok":false,"error":"..."}` (the script did not read it) and the other request shapes
/// accepted by [resolveCall].
typedef DartActionHandler = Future<Object?> Function(Map<String, dynamic> args);

class DartCallbackServer {
  DartCallbackServer({Map<String, DartActionHandler>? handlers}) : handlers = handlers ?? {};

  final Map<String, DartActionHandler> handlers;
  HttpServer? _server;

  int? get port => _server?.port;

  /// Binds 127.0.0.1 (random port when [preferredPort] is 0/null) and returns the port. Idempotent.
  Future<int> start({int? preferredPort}) async {
    final existing = _server;
    if (existing != null) return existing.port;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, preferredPort ?? 0);
    _server = server;
    unawaited(server.forEach(_handle));
    return server.port;
  }

  /// Every request is described here (path, parameter names, value lengths - never the values, which may be cookies)
  /// so the shape scripts really use can be read from the device log.
  void Function(String line) log = (_) {};

  Future<void> _handle(HttpRequest req) async {
    Map<String, Object?> reply;
    int status = 200;
    String action = '';
    try {
      final text = await utf8.decoder.bind(req).join();
      Object? body;
      try {
        body = text.isEmpty ? null : jsonDecode(text);
      } catch (_) {
        body = null;
      }
      final call = resolveCall(req.uri, body, known: handlers.containsKey);
      action = call.action;
      log('[DartServer] ${req.method} ${req.uri.path} query=${req.uri.queryParameters.keys.toList()} '
          'body=${describeShape(body ?? (text.isEmpty ? null : 'text(${text.length})'))} -> $action');
      final handler = handlers[action];
      if (handler == null) {
        status = 501;
        reply = {'ok': false, 'error': 'unsupported action: $action'};
      } else {
        reply = {'ok': true, 'data': await handler(call.args)};
      }
    } catch (e) {
      status = 500;
      reply = {'ok': false, 'error': '$e'};
      log('[DartServer] $action failed: $e');
    }
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(reply));
    await req.response.close();
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }
}

/// The action and its arguments. INFERRED shapes, all accepted: `POST /<action>` with the arguments as the JSON body;
/// a JSON body `{"action"|"type"|"method"|"name": <action>, "data"|"args"|"params"|"payload": {...}}` (any path);
/// `?action=` in the query. Query parameters are merged into the arguments.
({String action, Map<String, dynamic> args}) resolveCall(Uri uri, Object? body, {bool Function(String)? known}) {
  final map = body is Map ? body.cast<String, dynamic>() : <String, dynamic>{};
  final segment = uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
  // `POST /<action>` wins when the path names an action: the body may carry a `name` (a title) of its own.
  if (segment != null && (known?.call(segment) ?? false)) {
    return (action: segment, args: {...map, ...uri.queryParameters});
  }
  String? named;
  for (final k in const ['action', 'type', 'method', 'name']) {
    final v = map[k];
    if (v is String && v.isNotEmpty && !v.contains('/')) {
      named = v;
      break;
    }
  }
  final action = uri.queryParameters['action'] ?? named ?? segment ?? '';
  Map<String, dynamic> args = map;
  if (named != null) {
    // `opt` is OBSERVED (2026-11-10, 「设」配置 → openInternalWebview); the others are guesses kept for other scripts.
    for (final k in const ['opt', 'data', 'args', 'params', 'payload']) {
      final v = map[k];
      if (v is Map) {
        args = v.cast<String, dynamic>();
        break;
      }
    }
  }
  return (action: action, args: {...args, ...uri.queryParameters}..remove('action'));
}

/// Names and value types of a decoded JSON value, with string lengths instead of the strings: `{url: str(41)}`.
String describeShape(Object? v, [int depth = 0]) {
  if (v is Map) {
    if (depth > 2) return '{…}';
    return '{${v.entries.map((e) => '${e.key}: ${describeShape(e.value, depth + 1)}').join(', ')}}';
  }
  if (v is List) return 'list(${v.length})';
  // identifiers (action names, kinds) are shown; anything else only by its length
  if (v is String) return RegExp(r'^[A-Za-z][A-Za-z0-9_.-]{0,39}$').hasMatch(v) ? v : 'str(${v.length})';
  return '$v';
}
