import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/app_http.dart';
import '../../core/json_store.dart';
import '../../services/danmu_client.dart';
import '../catpaw/catpaw_client.dart';
import '../catpaw/catpaw_protocol.dart';
import '../catpaw/manager_client.dart';
import '../subscription/subscription.dart';

/// Which danmaku server the app talks to.
///
/// OBSERVED (changelog 1.1.4, string pool): three modes - the embedded `danmu_api` script run by the Node runtime,
/// the subscription's own service, a self-hosted "custom remote" URL; file `danmu_service_config.json`;
/// env var `DANMU_API_PORT`; default local address http://127.0.0.1:9321 with an optional `/TOKEN` path prefix;
/// the script is downloaded as `server.cjs` next to a `.md5` file.
/// The 弹幕服务 page shows the local service on port 9311 (OBSERVED default), separate from the subscription's 9321.
/// INFERRED: the JSON field names, the `off` mode (files from older versions of this project), the `TOKEN` env var.
enum DanmuMode { off, builtin, subscription, remote }

const subscriptionDanmuPort = 9321;
const builtinDanmuDefaultPort = 9311;
const builtinDanmuName = 'danmu_api';

class DanmuServiceConfig {
  const DanmuServiceConfig({
    this.mode = DanmuMode.off,
    this.remoteUrl = '',
    this.token = '',
    this.scriptUrl = '',
    this.port = builtinDanmuDefaultPort,
    this.enabled = true,
    this.localScript = false,
    this.preferVideoDanmu = true,
  });

  factory DanmuServiceConfig.fromJson(Map<String, dynamic> j) {
    final remote = (j['remoteUrl'] as String?) ?? '';
    final name = j['mode'] as String?;
    final mode = DanmuMode.values.where((m) => m.name == name).firstOrNull ??
        // files written before the mode switch existed only had `remoteUrl`
        (remote.isNotEmpty ? DanmuMode.remote : DanmuMode.off);
    return DanmuServiceConfig(
      mode: mode,
      remoteUrl: remote,
      token: (j['token'] as String?) ?? '',
      scriptUrl: (j['scriptUrl'] as String?) ?? '',
      port: (j['port'] as num?)?.toInt() ?? builtinDanmuDefaultPort,
      enabled: j['enabled'] as bool? ?? mode != DanmuMode.off,
      localScript: j['localScript'] as bool? ?? false,
      preferVideoDanmu: j['preferVideoDanmu'] as bool? ?? true,
    );
  }

  final DanmuMode mode;
  final String remoteUrl;
  final String token;
  final String scriptUrl;
  final int port;

  /// 启用弹幕. Off: no danmaku service is used at all.
  final bool enabled;

  /// 本地脚本 instead of 网络订阅源: the script was imported from a file, so 下载脚本 does not apply.
  final bool localScript;

  /// 优先使用视频返回弹幕数据 (OBSERVED in orig_set_danmu.png).
  final bool preferVideoDanmu;

  /// The source shown on the page: the old `off` mode reads as 本地服务, the original's first choice.
  DanmuMode get source => mode == DanmuMode.off ? DanmuMode.builtin : mode;

  DanmuServiceConfig copyWith({
    DanmuMode? mode,
    String? remoteUrl,
    String? token,
    String? scriptUrl,
    int? port,
    bool? enabled,
    bool? localScript,
    bool? preferVideoDanmu,
  }) =>
      DanmuServiceConfig(
        mode: mode ?? this.mode,
        remoteUrl: remoteUrl ?? this.remoteUrl,
        token: token ?? this.token,
        scriptUrl: scriptUrl ?? this.scriptUrl,
        port: port ?? this.port,
        enabled: enabled ?? this.enabled,
        localScript: localScript ?? this.localScript,
        preferVideoDanmu: preferVideoDanmu ?? this.preferVideoDanmu,
      );

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'remoteUrl': remoteUrl,
        'token': token,
        'scriptUrl': scriptUrl,
        'port': port,
        'enabled': enabled,
        'localScript': localScript,
        'preferVideoDanmu': preferVideoDanmu,
      };
}

String _local(int port, String? token) => 'http://127.0.0.1:$port${(token == null || token.isEmpty) ? '' : '/$token'}';

String _trim(String url) => url.trim().replaceAll(RegExp(r'/+$'), '');

final _configDanmuUrlPattern = RegExp(r'''["']?(?:danmuSearchUrl|danmuUrl)["']?\s*:\s*["']([^"']+)["']''');

/// Extracts the danmaku base URL from a subscription's `config.js` (`danmuSearchUrl` / `danmuUrl`), stripping `/api/v2…`
/// and rebasing loopback port 2333 onto [runtimePort] when the CatPaw instance stepped to another port.
String? extractConfigDanmuBase(String? rawConfig, {int? runtimePort}) {
  if (rawConfig == null || rawConfig.isEmpty) return null;
  final match = _configDanmuUrlPattern.firstMatch(rawConfig);
  var raw = match?.group(1)?.trim() ?? '';
  if (raw.isEmpty) return null;
  final apiIdx = raw.indexOf('/api/v2');
  if (apiIdx > 0) raw = raw.substring(0, apiIdx);
  raw = _trim(raw);
  final uri = Uri.tryParse(raw);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  if (runtimePort != null &&
      (uri.host == '127.0.0.1' || uri.host == 'localhost') &&
      uri.hasPort &&
      uri.port == 2333 &&
      runtimePort != 2333) {
    return _trim(uri.replace(port: runtimePort).toString());
  }
  return raw;
}

/// Base URL of the danmaku server for [config], or null when danmaku is off / not configured.
String? danmuBaseUrl(DanmuServiceConfig config, {Subscription? subscription, int? runtimePort}) {
  if (!config.enabled) return null;
  switch (config.mode) {
    case DanmuMode.off:
      return null;
    case DanmuMode.remote:
      final u = _trim(config.remoteUrl);
      return u.isEmpty ? null : u;
    case DanmuMode.subscription:
      if (subscription == null) return null;
      // A cloud catpaw address (`http://ip:9321[/TOKEN]`) already is the danmaku address too.
      if (subscription.cloudUrl != null) return _trim(subscription.cloudUrl!);
      return _local(runtimePort ?? subscriptionDanmuPort, subscription.danmuToken);
    case DanmuMode.builtin:
      return _local(config.port, config.token);
  }
}

/// The danmaku show the user picked for a video (`danmu_refs.json`), so later episodes match automatically.
class DanmuRef {
  const DanmuRef(this.animeId, this.title);
  final int animeId;
  final String title;
}

class DanmuRefsRepository {
  DanmuRefsRepository({JsonStore? store}) : _store = store ?? JsonStore('danmu_refs.json');
  final JsonStore _store;

  Future<DanmuRef?> get(String key) async {
    final all = await _store.read<Map<String, dynamic>>(<String, dynamic>{});
    final e = all[key];
    if (e is! Map) return null;
    final id = (e['animeId'] as num?)?.toInt();
    return id == null ? null : DanmuRef(id, '${e['title'] ?? ''}');
  }

  Future<void> set(String key, DanmuRef ref) async {
    final all = await _store.read<Map<String, dynamic>>(<String, dynamic>{});
    all[key] = {'animeId': ref.animeId, 'title': ref.title};
    await _store.write(all);
  }

  Future<void> remove(String key) async {
    final all = await _store.read<Map<String, dynamic>>(<String, dynamic>{});
    if (all.remove(key) != null) await _store.write(all);
  }
}

/// Resolves the configured mode into a ready [DanmuClient], starting whatever has to run first.
class DanmuServiceController {
  DanmuServiceController({
    required this.store,
    required this.catpaw,
    required this.manager,
    required this.installer,
    required this.activeSubscription,
    this.ensureSubscriptionPort,
    Dio? dio,
    Directory? root,
  })  : _dio = dio ?? createAppDio(connectTimeout: const Duration(seconds: 4), receiveTimeout: const Duration(seconds: 12)),
        _root = root;

  final JsonStore store;
  final CatpawClient catpaw;
  final ManagerClient manager;
  final SubscriptionInstaller installer;
  final Future<Subscription?> Function() activeSubscription;
  final Future<int?> Function()? ensureSubscriptionPort;
  final Dio _dio;
  final Directory? _root;

  Future<DanmuServiceConfig> config() async =>
      DanmuServiceConfig.fromJson(await store.read<Map<String, dynamic>>(<String, dynamic>{}));

  Future<void> save(DanmuServiceConfig c) => store.write(c.toJson());

  /// Null when danmaku is off, not configured, or the service could not be started (danmaku is best effort).
  Future<DanmuClient?> resolve() async {
    final cfg = await config();
    final sub = await activeSubscription();
    if (!cfg.enabled || cfg.mode == DanmuMode.off) return null;
    if (cfg.mode == DanmuMode.subscription) {
      if (sub == null) return null;
      final resolved = await _resolveSubscriptionBase(sub);
      return resolved == null ? null : DanmuClient(resolved, dio: _dio);
    }
    final base = danmuBaseUrl(cfg, subscription: sub);
    if (base == null) return null;
    try {
      if (cfg.mode == DanmuMode.builtin) {
        await _ensureBuiltin(cfg);
      }
    } catch (_) {
      return null;
    }
    return DanmuClient(base, dio: _dio);
  }

  Future<String?> _resolveSubscriptionBase(Subscription sub) async {
    if (sub.cloudUrl != null) {
      final cloudBase = _trim(sub.cloudUrl!);
      final tok = await _probeCatpawDanmuToken(cloudBase);
      if (tok != null && tok.isNotEmpty && !cloudBase.endsWith('/$tok')) return '$cloudBase/$tok';
      return cloudBase;
    }

    int? runtimePort = catpaw.portOf(sub.key);
    if (runtimePort == null && ensureSubscriptionPort != null) {
      try {
        runtimePort = await ensureSubscriptionPort!();
      } catch (e) {
        debugPrint('ensureSubscriptionPort failed for ${sub.key}: $e');
      }
    }

    // 1. Explicit danmuSearchUrl / danmuUrl in installed config.js.
    try {
      final installed = await installer.installedScript(sub);
      if (installed?.configPath != null) {
        final rawCfg = await File(installed!.configPath!).readAsString();
        final cfgBase = extractConfigDanmuBase(rawCfg, runtimePort: runtimePort);
        if (cfgBase != null) {
          if (cfgBase.contains(':$subscriptionDanmuPort') && !await _probeDanmuV2(cfgBase)) {
            await _tryReloadDanmu(sub.key);
          }
          return cfgBase;
        }
      }
    } catch (e) {
      debugPrint('read config.js danmu base failed for ${sub.key}: $e');
    }

    // 2. Modern CatPaw integrated danmu server mounted on the subscription's own HTTP port (`/danmu` + `/api/v2`).
    if (runtimePort != null) {
      final hostBase = 'http://127.0.0.1:$runtimePort';
      final catTok = await _probeCatpawDanmuToken(hostBase);
      if (catTok != null) {
        final effectiveTok = catTok.isNotEmpty ? catTok : sub.danmuToken;
        return _local(runtimePort, effectiveTok);
      }
      final candidate = _local(runtimePort, sub.danmuToken);
      if (await _probeDanmuV2(candidate)) return candidate;
    }

    // 3. Legacy standalone danmu server on port 9321.
    final fallback9321 = _local(subscriptionDanmuPort, sub.danmuToken);
    if (!await _probeDanmuV2(fallback9321)) {
      await _tryReloadDanmu(sub.key);
    }
    return fallback9321;
  }

  /// Queries `<base>/danmu/api/config` (CatPaw built-in danmu server). Returns the configured token (`""` if none),
  /// or `null` when `<base>` does not expose `/danmu/api/config`.
  Future<String?> _probeCatpawDanmuToken(String base) async {
    try {
      final res = await _dio.get<Object?>(
        '$base/danmu/api/config',
        options: Options(
          sendTimeout: const Duration(milliseconds: 1500),
          receiveTimeout: const Duration(milliseconds: 1500),
          validateStatus: (_) => true,
        ),
      );
      if (res.statusCode != 200) return null;
      final data = res.data is String ? jsonDecode(res.data as String) : res.data;
      if (data is! Map) return null;
      final envs = data['envs'];
      final rawTok = envs is Map ? '${envs['TOKEN'] ?? ''}'.trim() : '';
      if (rawTok.isNotEmpty && !RegExp(r'^\*+$').hasMatch(rawTok)) return rawTok;
      return '';
    } catch (_) {
      return null;
    }
  }

  Future<bool> _probeDanmuV2(String base) async {
    try {
      final res = await _dio.get<Object?>(
        '$base/api/v2/search/anime',
        queryParameters: const {'keyword': 'a'},
        options: Options(
          sendTimeout: const Duration(milliseconds: 1500),
          receiveTimeout: const Duration(milliseconds: 2000),
          validateStatus: (_) => true,
        ),
      );
      final code = res.statusCode ?? 0;
      return code >= 200 && code < 400;
    } catch (_) {
      return false;
    }
  }

  Future<void> _tryReloadDanmu(String subKey) async {
    try {
      await catpaw.attach();
      await catpaw.reloadDanmu(subKey);
    } catch (_) {
      // Many subscriptions serve danmu on their main HTTP port and register no 9321 server; never abort resolve().
    }
  }

  Future<File> _scriptFile() async {
    final base = _root ?? await getApplicationSupportDirectory();
    return File(p.join(base.path, 'danmu_api', 'server.cjs'));
  }

  /// Downloads the user-supplied script again (checks `<url>.md5` when the server has one).
  Future<String> updateScript(DanmuServiceConfig cfg) async {
    if (cfg.localScript) throw StateError('local script missing');
    if (cfg.scriptUrl.trim().isEmpty) throw StateError('Set the danmu_api script URL first');
    final file = await _scriptFile();
    return (await installer.downloadScript(cfg.scriptUrl.trim(), file)).md5;
  }

  /// Whether a script is installed for the local service (OBSERVED 尚未添加弹幕服务 when not).
  Future<bool> hasScript() async => (await _scriptFile()).exists();

  /// 加载本地脚本: installs a .cjs/.js file picked by the user. Returns its md5.
  Future<String> importScript(List<int> bytes) async {
    final f = await _scriptFile();
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes, flush: true);
    return md5.convert(bytes).toString();
  }

  /// 运行状态 of the local service (null: not installed in the runtime).
  Future<CatpawInstance?> builtinStatus() async {
    await catpaw.attach();
    manager.listen();
    await manager.refresh();
    return manager.find(builtinDanmuName);
  }

  /// 关闭服务.
  Future<void> stopBuiltin() async {
    final s = await builtinStatus();
    if (s != null && s.running) await manager.stop(builtinDanmuName);
  }

  /// 重启服务: stops it and starts it again with the current script and port.
  Future<void> restartBuiltin(DanmuServiceConfig cfg) async {
    await stopBuiltin();
    await _ensureBuiltin(cfg);
  }

  Future<void> _ensureBuiltin(DanmuServiceConfig cfg) async {
    await catpaw.attach(); // the manager channel shares the runtime
    manager.listen();
    await manager.refresh();
    final existing = manager.find(builtinDanmuName);
    if (existing != null && existing.running && existing.port == cfg.port) return;

    final file = await _scriptFile();
    if (!await file.exists()) await updateScript(cfg);
    if (existing == null) {
      final r = await manager.install(builtinDanmuName, file.path, defaultPort: cfg.port);
      if (!r.ok) throw StateError(r.error ?? 'install failed');
    } else if (existing.running) {
      await manager.stop(builtinDanmuName); // port changed
    }
    final r = await manager.start(builtinDanmuName, port: cfg.port, env: {
      'DANMU_API_PORT': '${cfg.port}',
      if (cfg.token.isNotEmpty) 'TOKEN': cfg.token,
    });
    if (!r.ok) throw StateError(r.error ?? 'start failed');
  }
}
