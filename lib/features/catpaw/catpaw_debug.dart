import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../app/providers.dart';
import '../../core/redact.dart';
import '../danmaku/danmu_service.dart';
import '../subscription/subscription.dart';
import 'catpaw_protocol.dart';
import 'spider_api.dart';

export '../../core/redact.dart' show redactUrls;

// 设置 → 开发者 → catpaw 调试 (`/debug`, title "catpaw 多实例"), OBSERVED on the original (2026-11-09, docs/ui-ref/
// original/orig_debug_*.png). Before Start Node: a card 启动 catpaw 运行时 with Dart 回调端口（空=随机）. After: ● Node 运行中,
// 最近结果, 日志 (copy all / clear), then catpaw (加载实例 → 运行实例) and 通用服务 (安装服务 → 已注册服务). Log lines are not
// translated in the original either ("Node ready; dart callback :…", "Node 已在运行，跳过重复启动（回调沿用启动方端口）: …").

enum DebugNodeState { idle, starting, running }

class DebugLogLine {
  const DebugLogLine(this.time, this.text);
  final DateTime time;
  final String text;

  /// OBSERVED "00:22:04  Node 已在运行…": the time, two spaces, the text.
  @override
  String toString() {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}  $text';
  }
}

class CatpawDebugState {
  const CatpawDebugState({
    this.node = DebugNodeState.idle,
    this.lastResult,
    this.log = const [],
    this.instances = const [],
    this.services = const [],
    this.busy = false,
  });

  final DebugNodeState node;

  /// 最近结果: the outcome of the last command ("-" while there is none).
  final String? lastResult;
  final List<DebugLogLine> log;

  /// 运行实例 (catpaw channel) and 已注册服务 (manager channel), from the runtime's list events.
  final List<CatpawInstance> instances;
  final List<CatpawInstance> services;

  /// A load / install is in flight.
  final bool busy;

  CatpawDebugState copyWith({
    DebugNodeState? node,
    String? lastResult,
    List<DebugLogLine>? log,
    List<CatpawInstance>? instances,
    List<CatpawInstance>? services,
    bool? busy,
  }) =>
      CatpawDebugState(
        node: node ?? this.node,
        lastResult: lastResult ?? this.lastResult,
        log: log ?? this.log,
        instances: instances ?? this.instances,
        services: services ?? this.services,
        busy: busy ?? this.busy,
      );
}


/// OBSERVED 实例名（存储隔离键，空则取 URL 账号）: the given name, else the URL's account. Without either, the md5 of the
/// URL (INFERRED: the original's running instance was named by 32 hex digits).
String debugInstanceName(String url, String given) {
  final name = given.trim();
  if (name.isNotEmpty) return name;
  final uri = Uri.tryParse(url.trim());
  final user = uri == null || uri.userInfo.isEmpty ? '' : Uri.decodeComponent(uri.userInfo.split(':').first);
  if (user.isNotEmpty) return user;
  return md5.convert(utf8.encode(url.trim())).toString();
}

/// Folder name for [name] (instance and service names are free text).
String _safe(String name) => name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

/// Where the debug page keeps downloaded scripts: `files/catpaw_debug/` (not the cache, which 数据清理 empties, and not
/// `subscriptions/`, which belongs to 订阅管理). Generic services are loaded from their path, so the copy must stay.
final catpawDebugDirProvider = Provider<Future<Directory> Function()>(
  (ref) => () async => Directory(p.join((await getApplicationSupportDirectory()).path, 'catpaw_debug')),
);

/// 测试 on a running instance: how many sites it serves (INFERRED meaning of the original's flask button).
final catpawProbeProvider =
    Provider<Future<int> Function(int port)>((ref) => (port) async => (await SpiderApi(port).sites()).length);

final catpawDebugProvider =
    NotifierProvider.autoDispose<CatpawDebugController, CatpawDebugState>(CatpawDebugController.new);

class CatpawDebugController extends AutoDisposeNotifier<CatpawDebugState> {
  /// Network audit lines come fast; older lines are dropped.
  static const maxLogLines = 500;

  final _subs = <StreamSubscription<Object?>>[];

  @override
  CatpawDebugState build() {
    ref.onDispose(() {
      for (final s in _subs) {
        s.cancel();
      }
    });
    return const CatpawDebugState();
  }

  void _log(String text) {
    final next = [...state.log, DebugLogLine(DateTime.now(), redactUrls(text))];
    state = state.copyWith(log: next.length > maxLogLines ? next.sublist(next.length - maxLogLines) : next);
  }

  void _result(String text) {
    final clean = redactUrls(text);
    state = state.copyWith(lastResult: clean);
    _log(clean);
  }

  void clearLog() => state = state.copyWith(log: const []);

  String get logText => state.log.join('\n');

  /// Start Node. With the runtime already up (the home page starts it) nothing restarts and the callback server keeps
  /// its port, as in the original ("回调沿用启动方端口").
  Future<void> startNode({int? dartPort}) async {
    if (state.node != DebugNodeState.idle) return;
    state = state.copyWith(node: DebugNodeState.starting);
    final catpaw = ref.read(catpawClientProvider);
    final already = catpaw.attached;
    try {
      await catpaw.attach();
      final port = await ref.read(dartCallbackServerProvider).start(preferredPort: dartPort);
      await catpaw.setDartPort(port);
      _listen();
      state = state.copyWith(node: DebugNodeState.running);
      _log(already ? 'Node 已在运行，跳过重复启动（回调沿用启动方端口）: $port' : 'Node ready; dart callback :$port');
      await refresh();
    } catch (e) {
      state = state.copyWith(node: DebugNodeState.idle);
      _result('catpaw 启动失败，请重试: $e');
    }
  }

  void _listen() {
    if (_subs.isNotEmpty) return;
    final catpaw = ref.read(catpawClientProvider);
    final manager = ref.read(managerClientProvider)..listen();
    _subs
      ..add(catpaw.statusLog.listen(_log))
      ..add(ref.read(nodeBridgeProvider).listen(Channels.netlog).listen(_log))
      ..add(catpaw.events.listen((e) {
        if (e is CatpawList) state = state.copyWith(instances: e.services);
        // loadInstance reports its own start (with the port); the event would repeat it without one.
        if (e is CatpawResult && e.action != Actions.list && e.action != Actions.start) _resultOf('catpaw', e);
      }))
      ..add(manager.events.listen((e) {
        if (e is CatpawList) state = state.copyWith(services: e.services);
        if (e is CatpawResult && e.action != Actions.list) _resultOf('service', e);
      }));
  }

  void _resultOf(String kind, CatpawResult e) =>
      _result('$kind ${e.action} ${e.name ?? ''}: ${e.ok ? 'ok' : 'failed: ${e.error ?? ''}'}');

  /// Asks both channels for their lists; the answers arrive as list events.
  Future<void> refresh() async {
    await ref.read(catpawClientProvider).list();
    try {
      await ref.read(managerClientProvider).refresh();
    } on TimeoutException {
      // An older runtime without the manager channel: the services list stays empty.
    }
  }

  /// 加载 catpaw 实例: downloads the script (and its index.config.js) like a subscription, then starts it.
  Future<void> loadInstance({
    required String url,
    String name = '',
    int? port,
    bool force = false,
    bool netLog = true,
    bool serviceLog = true,
  }) async {
    if (url.trim().isEmpty || state.busy) return;
    final instance = debugInstanceName(url, name);
    state = state.copyWith(busy: true);
    _log('加载 catpaw 实例 $instance ← ${url.trim()}');
    try {
      final root = await ref.read(catpawDebugDirProvider)();
      final installer = SubscriptionInstaller(root: Directory(p.join(root.path, 'instances')));
      final script =
          await installer.install(Subscription(key: _safe(instance), name: instance, indexJsUrl: url.trim()));
      final listening = await ref.read(catpawClientProvider).startAndWait(
            name: instance,
            scriptPath: script.scriptPath,
            configPath: script.configPath,
            port: port,
            force: force,
            enableLog: serviceLog,
            enableNetLog: netLog,
          );
      _result('catpaw start $instance: ok :$listening');
    } catch (e) {
      _result('catpaw start $instance: failed: $e');
    } finally {
      state = state.copyWith(busy: false);
      await ref.read(catpawClientProvider).list();
    }
  }

  Future<void> stopInstance(String name) async {
    _log('停止 $name');
    await ref.read(catpawClientProvider).stop(name);
    await ref.read(catpawClientProvider).list();
  }

  Future<void> testInstance(CatpawInstance instance) async {
    final port = instance.port;
    if (port == null) return;
    try {
      _result('测试 ${instance.name}: ${await ref.read(catpawProbeProvider)(port)} 个站点');
    } catch (e) {
      _result('测试 ${instance.name}: failed: $e');
    }
  }

  /// 安装服务 from a URL: the script is downloaded to `catpaw_debug/services/<name>/` and registered there.
  Future<void> installService({required String url, String name = '', int? defaultPort}) async {
    if (url.trim().isEmpty || state.busy) return;
    final service = debugInstanceName(url, name);
    await _install(service, defaultPort, (file) async {
      _log('安装服务 $service ← ${url.trim()}');
      final r = await Dio().get<List<int>>(url.trim(), options: Options(responseType: ResponseType.bytes));
      await file.writeAsBytes(r.data ?? const []);
    });
  }

  /// 加载本地脚本: a .js file picked by the user, registered under [name] or the file name.
  Future<void> installLocalService(
      {required List<int> bytes, required String fileName, String name = '', int? defaultPort}) async {
    if (state.busy) return;
    final given = name.trim();
    final service = given.isNotEmpty ? given : p.basenameWithoutExtension(fileName);
    await _install(service, defaultPort, (file) async {
      _log('加载本地脚本 $service ← $fileName');
      await file.writeAsBytes(bytes);
    });
  }

  Future<void> _install(String service, int? defaultPort, Future<void> Function(File file) fetch) async {
    if (service == builtinDanmuName) {
      // The built-in danmu service is registered under this name; replacing it would break 弹幕服务.
      _result('service install $service: failed: 与内置弹幕服务重名');
      return;
    }
    state = state.copyWith(busy: true);
    try {
      final root = await ref.read(catpawDebugDirProvider)();
      final file = File(p.join(root.path, 'services', _safe(service), 'index.js'));
      await file.parent.create(recursive: true);
      await fetch(file);
      await ref.read(managerClientProvider).install(service, file.path, defaultPort: defaultPort);
    } catch (e) {
      _result('service install $service: failed: $e');
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  Future<void> startService(String name) => _quiet(() => ref.read(managerClientProvider).start(name));

  Future<void> stopService(String name) => _quiet(() => ref.read(managerClientProvider).stop(name));

  /// Unregisters a stopped service and deletes the copy this page made of its script (not in the original, which has
  /// no way to remove one).
  Future<void> uninstallService(String name) async {
    await _quiet(() => ref.read(managerClientProvider).uninstall(name));
    try {
      final dir = Directory(p.join((await ref.read(catpawDebugDirProvider)()).path, 'services', _safe(name)));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Not one of ours.
    }
  }

  /// The result itself arrives as a manager event; only a lost answer is reported here.
  Future<void> _quiet(Future<CatpawResult> Function() command) async {
    try {
      await command();
    } catch (e) {
      _result('service: failed: $e');
    }
  }
}
