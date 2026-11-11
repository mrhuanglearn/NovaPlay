import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/json_store.dart';

/// A "subscription" = a source bundle: a catpaw `index.js` (+ optional config) the Node runtime executes.
///
/// OBSERVED UI strings: "catpaw index.js URL", "Add a catpaw subscription on the Subscriptions page first",
/// `https://user:pass@host/index.js.md5`, `.../server.cjs.md5` (integrity files fetched next to the script),
/// routes `/subscriptions`, `/subscriptions/add`, `/subscriptions/edit/:subKey`, per-subscription lock,
/// manual update check, `subscription_profiles.json`, "useSubscriptionDanmu", cloud catpaw service URL.
/// INFERRED: field names below.
class Subscription {
  const Subscription({
    required this.key,
    required this.name,
    this.indexJsUrl,
    this.configUrl,
    this.cloudUrl,
    this.local = false,
    this.locked = false,
    this.autoUpdate = false,
    this.danmuToken,
    this.installedMd5,
    this.updatedAt,
  });

  factory Subscription.fromJson(Map<String, dynamic> j) => Subscription(
        key: j['key'] as String,
        name: j['name'] as String? ?? j['key'] as String,
        indexJsUrl: j['indexJsUrl'] as String?,
        configUrl: j['configUrl'] as String?,
        cloudUrl: j['cloudUrl'] as String?,
        local: j['local'] as bool? ?? false,
        locked: j['locked'] as bool? ?? false,
        autoUpdate: j['autoUpdate'] as bool? ?? false,
        danmuToken: j['danmuToken'] as String?,
        installedMd5: j['installedMd5'] as String?,
        updatedAt: (j['updatedAt'] as num?)?.toInt(),
      );

  final String key;
  final String name;
  final String? indexJsUrl;
  final String? configUrl;

  /// Direct `http://ip:9321[/TOKEN]` of a remotely hosted catpaw service (no local runtime needed).
  final String? cloudUrl;

  /// Installed from a local zip (OBSERVED 本地 / "选择本地 zip 压缩包作为订阅源，需同时包含 index.js 与 index.config.js").
  final bool local;

  /// OBSERVED 上锁: hidden from 订阅管理 (and covering the home page while active) until the lock password is verified.
  final bool locked;

  /// OBSERVED 自动更新 "随启动自动同步最新内容", off by default: when on, a newer script is downloaded on activation.
  final bool autoUpdate;
  final String? danmuToken;
  final String? installedMd5;

  /// When the script was last downloaded (epoch ms), shown as 上次更新.
  final int? updatedAt;

  Subscription copyWith({
    String? name,
    bool? locked,
    bool? autoUpdate,
    String? installedMd5,
    String? danmuToken,
    int? updatedAt,
  }) =>
      Subscription(
        key: key,
        name: name ?? this.name,
        indexJsUrl: indexJsUrl,
        configUrl: configUrl,
        cloudUrl: cloudUrl,
        local: local,
        locked: locked ?? this.locked,
        autoUpdate: autoUpdate ?? this.autoUpdate,
        danmuToken: danmuToken ?? this.danmuToken,
        installedMd5: installedMd5 ?? this.installedMd5,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'name': name,
        if (indexJsUrl != null) 'indexJsUrl': indexJsUrl,
        if (configUrl != null) 'configUrl': configUrl,
        if (cloudUrl != null) 'cloudUrl': cloudUrl,
        if (local) 'local': true,
        'locked': locked,
        if (autoUpdate) 'autoUpdate': true,
        if (danmuToken != null) 'danmuToken': danmuToken,
        if (installedMd5 != null) 'installedMd5': installedMd5,
        if (updatedAt != null) 'updatedAt': updatedAt,
      };
}

class SubscriptionRepository {
  SubscriptionRepository({JsonStore? store}) : _store = store ?? JsonStore('subscriptions.json');
  final JsonStore _store;

  Future<List<Subscription>> all() async {
    final raw = await _store.read<List<dynamic>>(const []);
    return raw.whereType<Map>().map((e) => Subscription.fromJson(e.cast<String, dynamic>())).toList();
  }

  Future<void> save(List<Subscription> subs) => _store.write(subs.map((s) => s.toJson()).toList());

  Future<void> upsert(Subscription sub) async {
    final list = await all();
    final i = list.indexWhere((s) => s.key == sub.key);
    if (i >= 0) {
      list[i] = sub;
    } else {
      list.add(sub);
    }
    await save(list);
  }

  Future<void> remove(String key) async => save((await all()).where((s) => s.key != key).toList());
}

/// OBSERVED: a blank name becomes "catpaw" (the name field's hint is 留空将自动从地址生成).
const defaultSubscriptionName = 'catpaw';

/// OBSERVED "该 URL 的订阅已存在".
class DuplicateSubscriptionException implements Exception {
  const DuplicateSubscriptionException();
  @override
  String toString() => 'a subscription with this URL already exists';
}

/// Adding, refreshing and replacing subscriptions. A network or local subscription is installed before it is saved, as
/// in the original (its 安装 button downloads first and only then shows 已添加), so a bad URL never lands in the list.
class SubscriptionService {
  SubscriptionService({required this.repository, required this.installer, DateTime Function()? now})
      : _now = now ?? DateTime.now;
  final SubscriptionRepository repository;
  final SubscriptionInstaller installer;
  final DateTime Function() _now;

  static int _seq = 0;
  String _newKey() => '${_now().microsecondsSinceEpoch}${(_seq++ % 1000).toString().padLeft(3, '0')}';
  String _name(String? name) => (name ?? '').trim().isEmpty ? defaultSubscriptionName : name!.trim();

  Future<void> _ensureUnique({String? indexJsUrl, String? cloudUrl}) async {
    for (final s in await repository.all()) {
      if ((indexJsUrl != null && s.indexJsUrl == indexJsUrl) || (cloudUrl != null && s.cloudUrl == cloudUrl)) {
        throw const DuplicateSubscriptionException();
      }
    }
  }

  Future<Subscription> addNetwork({
    required String url,
    String? name,
    bool autoUpdate = false,
    bool locked = false,
    Future<bool> Function()? confirmConfigMismatch,
  }) async {
    final u = url.trim();
    await _ensureUnique(indexJsUrl: u);
    var sub = Subscription(key: _newKey(), name: _name(name), indexJsUrl: u, autoUpdate: autoUpdate, locked: locked);
    try {
      final installed = await installer.install(sub, confirmConfigMismatch: confirmConfigMismatch);
      sub = sub.copyWith(installedMd5: installed.md5, updatedAt: _now().millisecondsSinceEpoch);
    } catch (_) {
      await installer.discard(sub);
      rethrow;
    }
    await repository.upsert(sub);
    return sub;
  }

  Future<Subscription> addCloud({required String url, String? name, bool locked = false}) async {
    final u = url.trim();
    await _ensureUnique(cloudUrl: u);
    final sub = Subscription(key: _newKey(), name: _name(name), cloudUrl: u, locked: locked);
    await repository.upsert(sub);
    return sub;
  }

  Future<Subscription> addLocal({required List<int> zip, String? name, bool locked = false}) async {
    var sub = Subscription(key: _newKey(), name: _name(name), local: true, locked: locked);
    try {
      final installed = await installer.installZip(sub, zip);
      sub = sub.copyWith(installedMd5: installed.md5, updatedAt: _now().millisecondsSinceEpoch);
    } catch (_) {
      await installer.discard(sub);
      rethrow;
    }
    await repository.upsert(sub);
    return sub;
  }

  /// Re-imports a local subscription's zip (OBSERVED "重新选择 zip 压缩包以覆盖当前本地源").
  Future<Subscription> replaceZip(Subscription sub, List<int> zip) async {
    final installed = await installer.installZip(sub, zip);
    final updated = sub.copyWith(installedMd5: installed.md5, updatedAt: _now().millisecondsSinceEpoch);
    await repository.upsert(updated);
    return updated;
  }

  /// Downloads [sub] again when the server has a different script. Returns the updated subscription, or null when it
  /// was already up to date (OBSERVED "」已是最新" / "已更新到最新"). Cloud and local subscriptions have nothing to fetch.
  Future<Subscription?> refresh(Subscription sub, {Future<bool> Function()? confirmConfigMismatch}) async {
    if (sub.indexJsUrl == null) return null;
    final installed = await installer.installedScript(sub);
    final remote = await installer.remoteMd5(sub);
    if (installed != null && remote != null && remote == installed.md5) return null;
    final fresh = await installer.install(sub, confirmConfigMismatch: confirmConfigMismatch);
    if (installed != null && fresh.md5 == installed.md5) return null;
    final updated = sub.copyWith(installedMd5: fresh.md5, updatedAt: _now().millisecondsSinceEpoch);
    await repository.upsert(updated);
    return updated;
  }

  /// Removes subscriptions and their installed files.
  Future<void> removeAll(Iterable<Subscription> subs) async {
    final keys = subs.map((s) => s.key).toSet();
    for (final s in subs) {
      await installer.discard(s);
    }
    await repository.save((await repository.all()).where((s) => !keys.contains(s.key)).toList());
  }
}

class InstalledScript {
  const InstalledScript({required this.scriptPath, required this.configPath, required this.md5});
  final String scriptPath;
  final String? configPath;
  final String md5;
}

/// Where a script and its checksum live.
///
/// OBSERVED (the original's hints `https://user:pass@host/index.js.md5` and `…/server.cjs.md5`, its errors
/// "no 32-hex md5 found at " and "md5 mismatch (expected "): the URL users paste is the script's checksum file and the
/// script is the same URL without `.md5`. A URL without `.md5` is taken as the script itself, with an optional checksum
/// at `<url>.md5`. Before 2026-11-09 this project downloaded a `.md5` URL as the script, so Node was handed a hex
/// string ("require bundle failed: Invalid or unexpected token").
class ScriptUrls {
  ScriptUrls._(this.script, this.md5, {required this.md5Given});

  factory ScriptUrls.parse(String url) {
    final u = Uri.parse(url.trim());
    if (u.path.endsWith('.md5')) {
      return ScriptUrls._(u.replace(path: u.path.substring(0, u.path.length - 4)), u, md5Given: true);
    }
    return ScriptUrls._(u, u.replace(path: '${u.path}.md5'), md5Given: false);
  }

  final Uri script;
  final Uri md5;

  /// The user gave the checksum URL, so it must hold an md5.
  final bool md5Given;

  /// `index.config.js` next to `index.js` (OBSERVED file name; the original loads it as the script's start config).
  Uri? get config {
    final path = script.path;
    if (!path.endsWith('.js') || path.endsWith('.config.js')) return null;
    return script.replace(path: '${path.substring(0, path.length - 3)}.config.js');
  }
}

/// [uri] without `user:pass@`, for messages that reach the screen.
String redactUrl(Uri uri) => uri.userInfo.isEmpty ? uri.toString() : uri.replace(userInfo: '').toString();

/// Downloads a subscription's script (and its `index.config.js`), verifies them against their `.md5` files and stores
/// them for the Node runtime.
class SubscriptionInstaller {
  SubscriptionInstaller({Dio? dio, Directory? root})
      : _dio = dio ?? Dio(),
        _root = root;
  final Dio _dio;
  final Directory? _root;

  /// Written last by [install]; an install without it (interrupted, or from before 2026-11-09) is not reused.
  static const _markerName = 'installed.json';
  static const _format = 1;
  static final _md5Pattern = RegExp(r'\b[0-9a-fA-F]{32}\b');

  Future<Directory> _dir(Subscription sub) async =>
      Directory(p.join((_root ?? await getApplicationSupportDirectory()).path, 'subscriptions', sub.key));

  /// The script from an earlier [install], if its files are still on disk. Lets the app start offline.
  Future<InstalledScript?> installedScript(Subscription sub) async {
    final dir = await _dir(sub);
    final script = File(p.join(dir.path, 'index.js'));
    final marker = File(p.join(dir.path, _markerName));
    if (!await script.exists() || !await marker.exists()) return null;
    try {
      final m = jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
      if (m['format'] != _format) return null;
      final config = File(p.join(dir.path, 'config.js'));
      return InstalledScript(
        scriptPath: script.path,
        configPath: await config.exists() ? config.path : null,
        md5: m['md5'] as String,
      );
    } catch (_) {
      return null;
    }
  }

  /// Downloads the script [url] names to [file] and checks it against its md5 (see [ScriptUrls]). Used for
  /// subscription scripts and for the embedded danmu_api script.
  Future<({String path, String md5})> downloadScript(String url, File file) async {
    final urls = ScriptUrls.parse(url);
    final expected = await _fetchMd5(urls.md5, required: urls.md5Given);
    final bytes = await _bytes(urls.script);
    final digest = md5.convert(bytes).toString();
    if (expected != null && expected != digest) {
      throw StateError('md5 mismatch for ${redactUrl(urls.script)} (expected $expected, got $digest)');
    }
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return (path: file.path, md5: digest);
  }

  /// [confirmConfigMismatch] is asked when `index.config.js` does not match its `.md5` (OBSERVED dialog
  /// "配置文件校验不一致"); declining starts the script with an empty config ("已忽略 md5 不匹配的 config").
  Future<InstalledScript> install(Subscription sub, {Future<bool> Function()? confirmConfigMismatch}) async {
    final url = sub.indexJsUrl;
    if (url == null) throw ArgumentError('subscription ${sub.key} has no index.js url');
    final dir = await _dir(sub);
    await dir.create(recursive: true);
    final marker = File(p.join(dir.path, _markerName));
    if (await marker.exists()) await marker.delete();
    final configFile = File(p.join(dir.path, 'config.js'));
    if (await configFile.exists()) await configFile.delete();

    final script = await downloadScript(url, File(p.join(dir.path, 'index.js')));

    String? configPath;
    if (sub.configUrl != null) {
      final cfg = (await _dio.get<String>(sub.configUrl!)).data ?? '{}';
      jsonDecode(cfg); // fail early if the server returned something that is not JSON
      await configFile.writeAsString('module.exports = $cfg;', flush: true);
      configPath = configFile.path;
    } else if (ScriptUrls.parse(url).config case final configUri?) {
      configPath = await _downloadConfig(configUri, configFile, confirmConfigMismatch);
    }
    await marker.writeAsString(jsonEncode({'format': _format, 'md5': script.md5}), flush: true);
    return InstalledScript(scriptPath: script.path, configPath: configPath, md5: script.md5);
  }

  /// OBSERVED: a config that cannot be downloaded is not an error ("index.config.js 下载失败（将以空 config 启动）").
  Future<String?> _downloadConfig(Uri uri, File file, Future<bool> Function()? confirmMismatch) async {
    final List<int> bytes;
    try {
      bytes = await _bytes(uri);
    } on DioException {
      return null;
    }
    final expected = await _fetchMd5(uri.replace(path: '${uri.path}.md5'), required: false);
    if (expected != null && expected != md5.convert(bytes).toString()) {
      if (confirmMismatch != null && !await confirmMismatch()) return null;
    }
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// The md5 the server announces for [sub]'s script, or null when it cannot be read (offline, no checksum file).
  /// OBSERVED: the original compares it with the local md5 whenever a subscription is activated
  /// ("activate: 更新检查 remoteMd5=… localMd5=").
  Future<String?> remoteMd5(Subscription sub) async {
    final url = sub.indexJsUrl;
    if (url == null) return null;
    try {
      return await _fetchMd5(ScriptUrls.parse(url).md5, required: false).timeout(const Duration(seconds: 8));
    } catch (_) {
      return null;
    }
  }

  /// Installs `index.js` and `index.config.js` from a zip (OBSERVED: both are required, "zip 内必须同时包含 index.js 与
  /// index.config.js"). Entries are matched by file name, the shallowest one wins, so a zip with a top folder works.
  Future<InstalledScript> installZip(Subscription sub, List<int> zipBytes) async {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes);
    } catch (e) {
      throw StateError('not a zip archive: $e');
    }
    ArchiveFile? pick(String name) {
      final hits = archive.files.where((f) => f.isFile && p.posix.basename(f.name) == name).toList()
        ..sort((a, b) => a.name.split('/').length.compareTo(b.name.split('/').length));
      return hits.isEmpty ? null : hits.first;
    }

    final script = pick('index.js');
    final config = pick('index.config.js');
    if (script == null || config == null) throw StateError('zip must contain both index.js and index.config.js');
    final dir = await _dir(sub);
    await dir.create(recursive: true);
    final marker = File(p.join(dir.path, _markerName));
    if (await marker.exists()) await marker.delete();
    final scriptBytes = script.content;
    final scriptFile = File(p.join(dir.path, 'index.js'));
    await scriptFile.writeAsBytes(scriptBytes, flush: true);
    final configFile = File(p.join(dir.path, 'config.js'));
    await configFile.writeAsBytes(config.content, flush: true);
    final digest = md5.convert(scriptBytes).toString();
    await marker.writeAsString(jsonEncode({'format': _format, 'md5': digest}), flush: true);
    return InstalledScript(scriptPath: scriptFile.path, configPath: configFile.path, md5: digest);
  }

  /// Removes [sub]'s installed files, so the next start downloads them again.
  Future<void> discard(Subscription sub) async {
    final dir = await _dir(sub);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<List<int>> _bytes(Uri uri) async =>
      (await _dio.getUri<List<int>>(uri, options: Options(responseType: ResponseType.bytes))).data!;

  /// The first 32-hex word of [uri]. When the checksum is optional, a missing file or one without an md5 gives null.
  Future<String?> _fetchMd5(Uri uri, {required bool required}) async {
    final String body;
    try {
      body = utf8.decode(await _bytes(uri), allowMalformed: true);
    } on DioException {
      if (required) rethrow;
      return null;
    }
    final match = _md5Pattern.firstMatch(body);
    if (match == null && required) throw StateError('no 32-hex md5 found at ${redactUrl(uri)}');
    return match?.group(0)!.toLowerCase();
  }
}
