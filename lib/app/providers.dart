import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/json_store.dart';
import '../core/node_bridge.dart';
import '../features/catpaw/catpaw_client.dart';
import '../features/catpaw/catpaw_protocol.dart';
import '../features/catpaw/dart_callback_server.dart';
import '../features/catpaw/manager_client.dart';
import '../features/backup/backup_service.dart';
import '../features/cleanup/cleanup_service.dart';
import '../features/catpaw/spider_api.dart';
import '../features/danmaku/danmu_service.dart';
import '../features/library/watch_repository.dart';
import '../features/player/head_tail.dart';
import '../features/player/playback_source.dart';
import '../features/player/player_launcher.dart';
import '../features/player/player_session.dart';
import '../features/search/search_state.dart';
import '../features/sniffer/sniffer_service.dart';
import '../features/subscription/subscription.dart';
import '../l10n/l10n.dart';
import '../models/vod.dart';
import '../services/danmu_client.dart';
import '../services/tmdb_client.dart';
import '../services/webdav_sync.dart';
import '../ui/load_error.dart';
import 'app_preferences.dart';
import 'live_providers.dart';
import 'router.dart';
import 'site_prefs.dart';
import 'ui_hooks.dart';

// Provider names intentionally follow the ones recovered from the original string pool
// (catpawRuntimeProvider, subscriptionsProvider, homeSitesProvider, selectedHomeSiteProvider, videoFeedProvider,
// videoCategoryFeedProvider, videoDetailProvider, searchPrefsProvider, favoriteRepositoryProvider, ...).

final nodeBridgeProvider = Provider<NodeBridge>((ref) => MethodChannelNodeBridge());

final catpawClientProvider = Provider<CatpawClient>((ref) {
  final c = CatpawClient(ref.watch(nodeBridgeProvider));
  ref.onDispose(c.dispose);
  return c;
});

final subscriptionRepositoryProvider = Provider((ref) => SubscriptionRepository());
final subscriptionInstallerProvider = Provider((ref) => SubscriptionInstaller());
final subscriptionServiceProvider = Provider((ref) => SubscriptionService(
      repository: ref.watch(subscriptionRepositoryProvider),
      installer: ref.watch(subscriptionInstallerProvider),
    ));
final historyRepositoryProvider = Provider((ref) => HistoryRepository());
final favoriteRepositoryProvider = Provider((ref) => FavoriteRepository());
final playerConfigRepositoryProvider = Provider((ref) => PlayerConfigRepository());
final snifferServiceProvider = Provider((ref) => SnifferService());
final settingsStoreProvider = Provider((ref) => JsonStore('settings.json'));
final subscriptionProfilesStoreProvider = Provider((ref) => JsonStore('subscription_profiles.json'));
final webDavConfigStoreProvider = Provider((ref) => JsonStore('webdav_config.json'));
final backupServiceProvider = Provider((ref) => BackupService());

/// 选择备份文件恢复: the system picker. OBSERVED: the original allows only zip files; JSON stays pickable here for the
/// backups of earlier versions of this project. Null when cancelled.
final backupPickerProvider = Provider<Future<Uint8List?> Function()>((ref) => () async {
      final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['zip', 'json']);
      return f?.readAsBytes();
    });

/// 选择数据项并导出: saves the zip as [fileName] in the app's external files folder `Backups` (the documents folder
/// without external storage; 重置应用 keeps both) and returns its path.
final backupSaverProvider =
    Provider<Future<String> Function(String fileName, List<int> bytes)>((ref) => (name, bytes) async {
          final base = (Platform.isAndroid ? await getExternalStorageDirectory() : null) ??
              await getApplicationDocumentsDirectory();
          final dir = Directory('${base.path}/Backups');
          await dir.create(recursive: true);
          final file = File('${dir.path}/$name');
          await file.writeAsBytes(bytes, flush: true);
          return file.path;
        });

/// 导出完成 → 分享: the system share sheet for the saved file.
final backupShareProvider = Provider<Future<void> Function(String path, String text)>(
    (ref) => (path, text) => SharePlus.instance.share(ShareParams(files: [XFile(path)], text: text)));

/// The sync for a WebDAV configuration (立即同步, 从 WebDAV 恢复).
final webDavSyncProvider = Provider<WebDavSync Function(WebDavConfig)>((ref) => (cfg) => WebDavSync(WebDavClient(cfg)));
final cleanupServiceProvider = Provider((ref) => CleanupService(livePlaylists: ref.watch(livePlaylistLoaderProvider)));

/// The session that is playing right now, so callbacks like `danmuPush` can reach it.
class ActivePlayerSession extends Notifier<PlayerSession?> {
  @override
  PlayerSession? build() => null;
  void set(PlayerSession? s) => state = s;
}

final activePlayerSessionProvider = NotifierProvider<ActivePlayerSession, PlayerSession?>(ActivePlayerSession.new);

final managerClientProvider = Provider<ManagerClient>((ref) {
  final c = ManagerClient(ref.watch(nodeBridgeProvider));
  ref.onDispose(c.dispose);
  return c;
});

final danmuRefsProvider = Provider((ref) => DanmuRefsRepository());
final danmuServiceStoreProvider = Provider((ref) => JsonStore('danmu_service_config.json'));

final danmuServiceControllerProvider = Provider((ref) => DanmuServiceController(
      store: ref.watch(danmuServiceStoreProvider),
      catpaw: ref.watch(catpawClientProvider),
      manager: ref.watch(managerClientProvider),
      installer: ref.watch(subscriptionInstallerProvider),
      activeSubscription: () async {
        final subs = await ref.read(subscriptionsProvider.future);
        if (subs.isEmpty) return null;
        final key = await ref.read(activeSubscriptionKeyProvider.future);
        return subs.firstWhere((s) => s.key == key, orElse: () => subs.first);
      },
    ));

final headTailRepositoryProvider = Provider((ref) => HeadTailRepository());

final playerLauncherProvider = Provider((ref) => PlayerLauncher(
      configs: ref.watch(playerConfigRepositoryProvider),
      sniffer: ref.watch(snifferServiceProvider),
      danmu: () => ref.read(danmuServiceControllerProvider).resolve(),
      refs: ref.watch(danmuRefsProvider),
      headTail: ref.watch(headTailRepositoryProvider),
      onSession: (s) => ref.read(activePlayerSessionProvider.notifier).set(s),
      describeError: (e) {
        final context = rootMessengerKey.currentContext;
        return context == null ? '$e' : describeLoadError(e, context.l10n);
      },
    ));

final subscriptionsProvider =
    FutureProvider<List<Subscription>>((ref) => ref.watch(subscriptionRepositoryProvider).all());

/// Key of the subscription whose sites are shown. Null = first one.
/// Persisted as `activeSubscription` in settings.json, so the app comes back to the same subscription after a
/// restart (before 2026-11-08 it was memory-only and every restart fell back to the first subscription).
class ActiveSubscriptionKey extends AsyncNotifier<String?> {
  static const _field = 'activeSubscription';

  @override
  Future<String?> build() async {
    final settings = await ref.watch(settingsStoreProvider).read<Map<String, dynamic>>(const {});
    final key = settings[_field];
    return key is String ? key : null;
  }

  Future<void> select(String key) async {
    state = AsyncData(key);
    final store = ref.read(settingsStoreProvider);
    final settings = Map<String, dynamic>.of(await store.read<Map<String, dynamic>>(const {}));
    settings[_field] = key;
    await store.write(settings);
  }
}

final activeSubscriptionKeyProvider = AsyncNotifierProvider<ActiveSubscriptionKey, String?>(ActiveSubscriptionKey.new);

/// A running catpaw instance plus its list of sites.
class SpiderRuntime {
  const SpiderRuntime({required this.subscription, required this.api, required this.sites});
  final Subscription subscription;
  final SpiderApi api;
  final List<SpiderSite> sites;
}

String? _lastRunningCatpawSubKey;

/// Installs the active subscription's script (if needed), starts it in the Node runtime and loads its sites.
/// Cloud subscriptions skip the local runtime and talk to the given address directly.
final FutureProvider<SpiderRuntime?> catpawRuntimeProvider = FutureProvider<SpiderRuntime?>((ref) async {
  // Rebuild only when what the runtime runs can change (which subscription is first, where each script comes from).
  // Renaming, 自动更新/上锁 and the 上次更新 stamp below must not restart the running script; pages that change the script
  // itself (refresh, a new zip) invalidate this provider explicitly.
  await ref.watch(subscriptionsProvider.selectAsync(_runtimeInputs));
  final subs = await ref.read(subscriptionsProvider.future);
  if (subs.isEmpty) return null; // UI: "Add a catpaw subscription on the Subscriptions page first"
  final key = await ref.watch(activeSubscriptionKeyProvider.future);
  final sub = subs.firstWhere((s) => s.key == key, orElse: () => subs.first);

  if (sub.cloudUrl != null) {
    final prevKey = _lastRunningCatpawSubKey;
    if (prevKey != null && prevKey != sub.key) {
      _lastRunningCatpawSubKey = null;
      try {
        final catpaw = ref.read(catpawClientProvider);
        if (catpaw.attached) await catpaw.stop(prevKey);
      } catch (_) {}
    }
    final uri = Uri.parse(sub.cloudUrl!);
    final api =
        SpiderApi(uri.port, baseUrl: sub.cloudUrl, receiveTimeout: ref.read(appPreferencesProvider).catpawTimeout);
    return SpiderRuntime(subscription: sub, api: api, sites: await api.sites());
  }

  final catpaw = ref.watch(catpawClientProvider);
  await catpaw.attach(); // completes after "Node ready"
  final prevKey = _lastRunningCatpawSubKey;
  if (prevKey != null && prevKey != sub.key) {
    try {
      await catpaw.stop(prevKey);
    } catch (_) {}
  }
  // Scripts reach the app through this loopback server; the port must be announced before the script starts.
  await catpaw.setDartPort(await ref.watch(dartCallbackServerProvider).start());
  final installer = ref.watch(subscriptionInstallerProvider);
  var installed = await installer.installedScript(sub); // reuse: no network needed on later launches
  if (installed != null && sub.autoUpdate) {
    // OBSERVED "activate: 更新检查 remoteMd5=… localMd5=": with 自动更新 on, reinstall when the server has a newer script.
    final remote = await installer.remoteMd5(sub); // null when offline: keep the installed copy
    if (remote != null && remote != installed.md5) installed = null;
  }
  var freshlyInstalled = false;
  if (installed == null) {
    if (sub.local) throw StateError('the local script is missing; import the zip again on the edit page');
    installed =
        await installer.install(sub, confirmConfigMismatch: () => confirmConfigChecksumMismatch(rootNavigatorKey));
    await ref
        .read(subscriptionRepositoryProvider)
        .upsert(sub.copyWith(installedMd5: installed.md5, updatedAt: DateTime.now().millisecondsSinceEpoch));
    freshlyInstalled = true;
  }
  final int port;
  try {
    String? profileFilePath;
    try {
      final profileStore = ref.read(subscriptionProfilesStoreProvider);
      final allProfiles = Map<String, dynamic>.of(await profileStore.read<Map<String, dynamic>>(<String, dynamic>{}));
      final rawEntry = allProfiles[sub.key] ?? allProfiles['default'];
      final sanitized = sanitizeSubscriptionProfile(rawEntry);
      if (rawEntry != null && jsonEncode(sanitized) != jsonEncode(rawEntry)) {
        allProfiles[sub.key] = sanitized;
        await profileStore.write(allProfiles);
      }
      final baseDir = await profileStore.resolveBaseDir();
      final safeSubName = sub.key.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final profileDir = Directory(p.join(baseDir.path, 'subscription_profiles'));
      await profileDir.create(recursive: true);
      final pf = File(p.join(profileDir.path, '$safeSubName.json'));
      if (!await pf.exists() || sanitized != null) {
        final seed = sanitized is Map ? sanitized : (sanitized ?? <String, dynamic>{});
        final tmp = File('${pf.path}.tmp');
        await tmp.writeAsString(jsonEncode(seed), flush: true);
        await tmp.rename(pf.path);
      }
      profileFilePath = pf.path;
    } catch (_) {
      profileFilePath = null;
    }
    _lastRunningCatpawSubKey = sub.key;
    port = await catpaw.startAndWait(
      name: sub.key,
      scriptPath: installed.scriptPath,
      configPath: installed.configPath,
      force: true,
      env: profileFilePath == null ? null : {'profile_path': profileFilePath},
    );
  } catch (e) {
    // Only invalidate the downloaded bundle if Node failed to require/parse it; keep MD5-verified bundles on timeouts.
    if (!sub.local && '$e'.contains('require bundle failed')) await installer.invalidateScript(sub);
    rethrow;
  }
  if (freshlyInstalled) {
    ref.invalidate(subscriptionsProvider); // the subscriptions page shows the new 上次更新 / 内容指纹
  }
  final api = SpiderApi(port, receiveTimeout: ref.read(appPreferencesProvider).catpawTimeout);
  return SpiderRuntime(subscription: sub, api: api, sites: await api.sites());
});

String _runtimeInputs(List<Subscription> subs) =>
    [for (final s in subs) '${s.key}|${s.indexJsUrl}|${s.cloudUrl}|${s.local}'].join('\n');

final homeSitesProvider =
    Provider<List<SpiderSite>>((ref) => ref.watch(catpawRuntimeProvider).valueOrNull?.sites ?? const []);

/// Key of the site shown on the home page for the running subscription. Null = its first site.
///
/// Persisted per subscription as `homeSite: {subscriptionKey: siteKey}` in settings.json, so a restart comes back to
/// the same site (before 2026-11-10 it was memory-only and every restart fell back to the first site).
class SelectedHomeSite extends AsyncNotifier<String?> {
  static const _field = 'homeSite';

  Future<String?> _subscription() => ref.read(catpawRuntimeProvider.future).then((rt) => rt?.subscription.key);

  @override
  Future<String?> build() async {
    final sub = await ref.watch(catpawRuntimeProvider.selectAsync((rt) => rt?.subscription.key));
    if (sub == null) return null;
    final saved = (await ref.read(settingsStoreProvider).read<Map<String, dynamic>>(const {}))[_field];
    final key = saved is Map ? saved[sub] : null;
    return key is String ? key : null;
  }

  Future<void> select(String key) async {
    state = AsyncData(key);
    final sub = await _subscription();
    if (sub == null) return;
    final store = ref.read(settingsStoreProvider);
    final settings = Map<String, dynamic>.of(await store.read<Map<String, dynamic>>(const {}));
    final saved = settings[_field];
    settings[_field] = {if (saved is Map) ...saved, sub: key};
    await store.write(settings);
  }
}

final selectedHomeSiteProvider = AsyncNotifierProvider<SelectedHomeSite, String?>(SelectedHomeSite.new);

/// Category tab selected on the home page (null = the "Home" tab). Scripts can change it through `switchTab`.
class SelectedTypeId extends Notifier<String?> {
  @override
  String? build() => null;
  void select(String? id) => state = id;
}

final selectedTypeIdProvider = NotifierProvider<SelectedTypeId, String?>(SelectedTypeId.new);

final currentSiteProvider = Provider<SpiderSite?>((ref) {
  final all = ref.watch(homeSitesProvider);
  if (all.isEmpty) return null;
  final selected = ref.watch(selectedHomeSiteProvider);
  // Wait for the saved choice instead of loading the first site for nothing (it is read right after the runtime).
  if (!selected.hasValue && !selected.hasError) return null;
  // Likewise wait for 站点设置, so a disabled or locked site is not loaded first. A site that is switched off or locked
  // while shown gives way to the first one still listed in 切换站点 (all sites when none is left).
  final prefs = ref.watch(sitePrefsProvider);
  if (!prefs.hasValue && !prefs.hasError) return null;
  final visible = ref.watch(visibleHomeSitesProvider);
  final sites = visible.isEmpty ? all : visible;
  final key = selected.valueOrNull;
  return sites.firstWhere((s) => s.key == key, orElse: () => sites.first);
});

final FutureProvider<HomeData?> videoFeedProvider = FutureProvider<HomeData?>((ref) async {
  final rt = await ref.watch(catpawRuntimeProvider.future);
  final site = ref.watch(currentSiteProvider);
  if (rt == null || site == null) return null;
  await rt.api.init(site);
  return rt.api.home(site);
});

typedef CategoryQuery = ({String siteKey, String typeId, int page, Map<String, String> filters});

/// Loads one page of a category of a given site.
///
/// Not a cached family: before 2026-11-10 the cache key had no site and no stable filter key, so after switching to
/// a site whose first category id was the same the home page kept the previous site's posters, and a failed page
/// stayed cached so 重试 returned the same error. Pages keep their own state (see the home page) instead.
final videoCategoryFeedProvider = Provider<Future<PagedVods?> Function(CategoryQuery q)>((ref) => (q) async {
      final rt = await ref.read(catpawRuntimeProvider.future);
      final site = rt?.sites.where((s) => s.key == q.siteKey).firstOrNull;
      if (rt == null || site == null) return null;
      return rt.api.category(site, q.typeId, page: q.page, filters: q.filters);
    });

/// The site a given item belongs to (search results and history can come from any site of the subscription).
final siteByKeyProvider = Provider.family<SpiderSite?, String?>((ref, key) {
  final sites = ref.watch(homeSitesProvider);
  if (key != null) {
    for (final s in sites) {
      if (s.key == key) return s;
    }
  }
  return ref.watch(currentSiteProvider);
});

typedef DetailQuery = ({String? siteKey, String vodId});

/// The detail of one video, asked for each time a detail page opens: kept only while a page shows it.
///
/// OBSERVED on the phone (2026-11-10): scripts can act while answering the detail request (「设」配置 asks for its web page
/// then). Kept for the whole app run, the second tap on the same 「设」配置 card sent no request, the script never asked
/// for the web page and an empty 视频详情 stayed on screen.
final videoDetailProvider = FutureProvider.autoDispose.family<VodDetail?, DetailQuery>((ref, q) async {
  final rt = await ref.watch(catpawRuntimeProvider.future);
  final site = ref.watch(siteByKeyProvider(q.siteKey));
  if (rt == null || site == null) return null;
  return rt.api.detail(site, q.vodId);
});

/// How long a script's `toast` stays. OBSERVED payload (2026-11-10, a cloud-drive spider): `{message, duration: 5}`;
/// INFERRED: the number is in seconds (a value above 100 is taken as milliseconds). Kept within 1..10 s, 3 s when absent.
Duration toastDuration(Object? value) {
  final v = value is num ? value : num.tryParse('${value ?? ''}');
  if (v == null || v <= 0) return const Duration(seconds: 3);
  final ms = v > 100 ? v.round() : (v * 1000).round();
  return Duration(milliseconds: ms.clamp(1000, 10000));
}

/// Whether a script's `openInternalWebview` replaces the page on top instead of opening over it.
///
/// OBSERVED on the phone (2026-11-10): tapping a QR card of 「设」配置 opens its detail page; the script answers the
/// detail request with an empty item and, while that request is still running, asks for the web page. The original
/// 1.1.7 leaves the empty 视频详情 under the web page. The user asked to land on the web page directly, so a detail page
/// that is still loading is replaced (back then returns to the home page); any other page stays under the web page.
bool webviewReplacesTop(Uri top, bool Function(DetailQuery q) detailLoading) =>
    top.path == '/video/detail' &&
    detailLoading((siteKey: top.queryParameters['site'], vodId: top.queryParameters['id'] ?? ''));

/// Unwraps any accidental `{"ok": true, "code": 0, "data": ...}` envelope layers while preserving newer top-level site
/// keys (`quark`, `spider`, `guazi`, ...) merged on top of older inner layers.
Object? sanitizeSubscriptionProfile(Object? raw) {
  if (raw is! Map) return raw;
  final map = raw.cast<String, dynamic>();
  final isEnvelope = map['ok'] is bool && map['code'] is num && map.containsKey('data');
  if (isEnvelope) {
    final inner = sanitizeSubscriptionProfile(map['data']);
    final base = inner is Map ? Map<String, dynamic>.of(inner.cast<String, dynamic>()) : <String, dynamic>{};
    final outer = <String, dynamic>{};
    for (final entry in map.entries) {
      final k = entry.key;
      if (k == 'ok' || k == 'code' || k == 'data' || k == 'error') continue;
      outer[k] = sanitizeSubscriptionProfile(entry.value);
    }
    return mergeProfileMaps(base, outer);
  }
  return <String, dynamic>{
    for (final entry in map.entries)
      entry.key: entry.value is Map
          ? Map<String, dynamic>.of((entry.value as Map).cast<String, dynamic>())
          : entry.value,
  };
}

Map<String, dynamic> mergeProfileMaps(Map<String, dynamic> older, Map<String, dynamic> newer) {
  final out = Map<String, dynamic>.of(older);
  for (final entry in newer.entries) {
    final prevVal = out[entry.key];
    final nextVal = entry.value;
    if (prevVal is Map && nextVal is Map) {
      out[entry.key] = {
        ...prevVal.cast<String, dynamic>(),
        ...nextVal.cast<String, dynamic>(),
      };
    } else {
      out[entry.key] = nextVal;
    }
  }
  return out;
}

final Provider<DartCallbackServer> dartCallbackServerProvider = Provider<DartCallbackServer>((ref) {
  final history = ref.watch(historyRepositoryProvider);
  final profiles = ref.watch(subscriptionProfilesStoreProvider);
  String? str(Map<String, dynamic> a, List<String> keys) {
    for (final k in keys) {
      final v = a[k];
      if (v is String && v.isNotEmpty) return v;
      if (v is num) return '$v';
    }
    return null;
  }

  Future<String> activeProfileSubKey() async {
    final subs = await ref.read(subscriptionsProvider.future);
    final selected = await ref.read(activeSubscriptionKeyProvider.future);
    if (selected != null && selected.isNotEmpty) {
      if (subs.isEmpty || subs.any((s) => s.key == selected)) return selected;
    }
    if (subs.isNotEmpty) return subs.first.key;
    return 'default';
  }

  Future<void> syncSidecarProfileFile(String subKey, Object? value) async {
    try {
      final baseDir = await profiles.resolveBaseDir();
      final safeSubName = subKey.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final dir = Directory(p.join(baseDir.path, 'subscription_profiles'));
      await dir.create(recursive: true);
      final pf = File(p.join(dir.path, '$safeSubName.json'));
      final tmp = File('${pf.path}.tmp');
      await tmp.writeAsString(jsonEncode(value ?? <String, dynamic>{}), flush: true);
      await tmp.rename(pf.path);
    } catch (_) {
      // Ignore in pure memory/mocked environments without disk baseDir.
    }
  }

  // Every payload field name below is INFERRED (only the action names were observed), hence the alias lists.
  final server = DartCallbackServer(handlers: {
    DartActions.toast: (args) async {
      final message = str(args, ['message', 'msg', 'text', 'content']) ?? '';
      final duration = toastDuration(args['duration']);
      // While a player page covers the app the SnackBar would be hidden behind it (OBSERVED 2026-11-10: a spider's
      // 夸克登录状态失效 toast never showed and the page kept spinning), so the page shows it as a system toast.
      final onPlayer = await ref
          .read(playerLauncherProvider)
          .host
          .showToast(message, duration >= const Duration(milliseconds: 3500))
          .catchError((Object _) => false);
      if (!onPlayer) showToast(message, duration: duration);
      return true;
    },
    DartActions.queryHistory: (args) async => [for (final e in await history.all()) e.toJson()],
    DartActions.queryProfile: (args) async {
      final subKey = await activeProfileSubKey();
      final all = Map<String, dynamic>.of(await profiles.read<Map<String, dynamic>>(<String, dynamic>{}));
      final slot = args['name'];
      if (slot is String && slot.isNotEmpty && args.length == 1) {
        final scopedKey = all.containsKey('$subKey:$slot') ? '$subKey:$slot' : (all.containsKey(slot) ? slot : null);
        if (scopedKey != null) {
          final rawSlot = all[scopedKey];
          final healedSlot = sanitizeSubscriptionProfile(rawSlot);
          if (jsonEncode(healedSlot) != jsonEncode(rawSlot)) {
            all[scopedKey] = healedSlot;
            await profiles.write(all);
          }
          return RawJsonResponse(healedSlot ?? <String, dynamic>{});
        }
        return const RawJsonResponse(<String, dynamic>{});
      }
      final targetKey = all.containsKey(subKey)
          ? subKey
          : (subKey != 'default' && all.containsKey('default') ? 'default' : null);
      if (targetKey != null) {
        final rawEntry = all[targetKey];
        final healed = sanitizeSubscriptionProfile(rawEntry);
        if (jsonEncode(healed) != jsonEncode(rawEntry)) {
          all[targetKey] = healed;
          await profiles.write(all);
          await syncSidecarProfileFile(targetKey, healed);
        }
        return RawJsonResponse(healed ?? <String, dynamic>{});
      }
      return const RawJsonResponse(<String, dynamic>{});
    },
    DartActions.saveProfile: (args) async {
      try {
        final subKey = await activeProfileSubKey();
        final all = Map<String, dynamic>.of(await profiles.read<Map<String, dynamic>>(<String, dynamic>{}));
        if (all.containsKey('null') && all['null'] == null) {
          all.remove('null');
        }
        final slot = args['name'];
        if (slot is String && slot.isNotEmpty && args.containsKey('profile') && args.length == 2) {
          all['$subKey:$slot'] = sanitizeSubscriptionProfile(args['profile']);
        } else if (args.length == 1 && args.containsKey('value')) {
          all[subKey] = sanitizeSubscriptionProfile(args['value']);
          await syncSidecarProfileFile(subKey, all[subKey]);
        } else if (args.length == 1 && args.containsKey('profile')) {
          final inner = sanitizeSubscriptionProfile(args['profile']);
          final prev = sanitizeSubscriptionProfile(all[subKey]);
          if (inner is Map && inner.isNotEmpty && prev is Map) {
            all[subKey] = mergeProfileMaps(prev.cast<String, dynamic>(), inner.cast<String, dynamic>());
          } else {
            all[subKey] = inner;
          }
          await syncSidecarProfileFile(subKey, all[subKey]);
        } else {
          final sanitizedIncoming = sanitizeSubscriptionProfile(Map<String, dynamic>.of(args));
          final prev = sanitizeSubscriptionProfile(all[subKey]);
          if (sanitizedIncoming is Map && sanitizedIncoming.isNotEmpty && prev is Map) {
            all[subKey] = mergeProfileMaps(prev.cast<String, dynamic>(), sanitizedIncoming.cast<String, dynamic>());
          } else {
            all[subKey] = sanitizedIncoming;
          }
          await syncSidecarProfileFile(subKey, all[subKey]);
        }
        await profiles.write(all);
        return true;
      } catch (e) {
        final msg = '持久化订阅 profile 失败: $e';
        debugPrint(msg);
        ref.read(nodeBridgeProvider).logDiagnostic(msg);
        rethrow;
      }
    },
    DartActions.openVodDetail: (args) async {
      final id = str(args, ['id', 'vodId', 'vod_id']);
      if (id == null) throw ArgumentError('id missing');
      final site = str(args, ['siteKey', 'site', 'key']);
      ref
          .read(routerProvider)
          .push(Uri(path: '/video/detail', queryParameters: {'id': id, if (site != null) 'site': site}).toString());
      return true;
    },
    DartActions.openSearch: (args) async {
      final q = str(args, ['keyword', 'wd', 'q', 'text']) ?? '';
      ref.read(routerProvider).push(Uri(path: '/search', queryParameters: {'q': q}).toString());
      return true;
    },
    DartActions.queryTabs: (args) async {
      final home = ref.read(videoFeedProvider).valueOrNull;
      return {
        'selected': ref.read(selectedTypeIdProvider),
        'tabs': [
          for (final c in home?.categories ?? const <VodCategory>[]) {'id': c.id, 'name': c.name}
        ],
      };
    },
    DartActions.switchTab: (args) async {
      final id = str(args, ['id', 'typeId', 'type_id']);
      ref.read(selectedTypeIdProvider.notifier).select(id);
      ref.read(routerProvider).go('/');
      return true;
    },
    DartActions.openVideoPlayer: (args) async {
      final url = str(args, ['url', 'src']);
      if (url == null) throw ArgumentError('url missing');
      final headers = {for (final e in ((args['headers'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'};
      final source =
          DirectPlaybackSource.single(title: str(args, ['title', 'name']) ?? url, url: url, headers: headers);
      unawaited(
          ref.read(playerLauncherProvider).playSource(source)); // the HTTP call must not wait for the player to close
      return true;
    },
    DartActions.sniff: (args) async {
      final url = str(args, ['url']);
      if (url == null) throw ArgumentError('url missing');
      final headers = {for (final e in ((args['headers'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'};
      final found = await ref.read(snifferServiceProvider).sniffFirstVideo(url, headers: headers);
      return found == null ? null : {'url': found.url, 'kind': found.kind, 'headers': found.headers};
    },
    DartActions.danmuPush: (args) async {
      final session = ref.read(activePlayerSessionProvider);
      if (session == null) return false;
      await session.pushDanmaku(
          parseDanmuPush((args['comments'] ?? args['list'] ?? args['danmu']) as List? ?? const []),
          title: str(args, ['title']));
      return true;
    },
    DartActions.openInternalWebview: (args) async {
      final url = str(args, ['url']);
      if (url == null) throw ArgumentError('url missing');
      final router = ref.read(routerProvider);
      final target = Uri(path: '/website', queryParameters: {'url': url}).toString();
      if (webviewReplacesTop(router.state.uri, (q) => ref.read(videoDetailProvider(q)).isLoading)) {
        unawaited(router.pushReplacement(target));
      } else {
        unawaited(router.push(target));
      }
      return true;
    },
    DartActions.openExternalWebview: (args) async {
      final url = str(args, ['url']);
      if (url == null) throw ArgumentError('url missing');
      return launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    },
  });
  // Logged to the device log (shape only, see DartCallbackServer.log) so the request format scripts use can be checked.
  server.log = (line) {
    debugPrint(line);
    ref.read(nodeBridgeProvider).logDiagnostic(line);
  };
  ref.onDispose(server.stop);
  return server;
});

final searchHistoryRepositoryProvider = Provider((ref) => SearchHistoryRepository());

/// The search page's layout and site switches (see [SearchPrefs]). The switches belong to the running subscription.
class SearchPrefsNotifier extends AsyncNotifier<SearchPrefs> {
  String? _subscription;

  @override
  Future<SearchPrefs> build() async {
    _subscription = await ref.watch(catpawRuntimeProvider.selectAsync((rt) => rt?.subscription.key));
    final s = await ref.read(settingsStoreProvider).read<Map<String, dynamic>>(const {});
    return SearchPrefs.fromSettings(s, _subscription);
  }

  Future<void> _save(SearchPrefs next) async {
    state = AsyncData(next);
    final store = ref.read(settingsStoreProvider);
    await store.write(next.writeTo(await store.read<Map<String, dynamic>>(const {}), _subscription));
  }

  Future<void> setLayout(SearchLayout layout) async {
    final cur = await future;
    if (cur.layout != layout) await _save(cur.copyWith(layout: layout));
  }

  Future<void> toggleGrid() async {
    final cur = await future;
    await _save(cur.copyWith(sitesGrid: !cur.sitesGrid));
  }

  /// 站点搜索管理: OBSERVED tapping a site switches it; the page then searches again.
  Future<void> toggleSite(String siteKey) async {
    final cur = await future;
    final off = {...cur.sitesOff};
    if (!off.remove(siteKey)) off.add(siteKey);
    await _save(cur.copyWith(sitesOff: off));
  }
}

final searchPrefsProvider = AsyncNotifierProvider<SearchPrefsNotifier, SearchPrefs>(SearchPrefsNotifier.new);

/// The sites the search page lists and searches: the video sites (type 3) of the running subscription.
///
/// OBSERVED (UZN 1.1.7, 站点搜索管理 on the phone): every type 3 site is listed and switched on, 「盘」我的 included
/// although its config says `searchable: 0`; 「推」推送 (type 4) and the Apple Music web page (type 7) are not listed.
/// OBSERVED (2026-11-13): sites switched off (启用) or locked in 切换站点 → 站点设置 are not listed either.
final searchableSitesProvider =
    Provider<List<SpiderSite>>((ref) => [for (final s in ref.watch(visibleHomeSitesProvider)) if (s.type == 3) s]);

final tmdbSettingsStoreProvider = Provider((ref) => JsonStore('tmdb_settings.json'));

final tmdbProvider = FutureProvider<TmdbClient?>((ref) async {
  final j = await ref.watch(tmdbSettingsStoreProvider).read<Map<String, dynamic>>(<String, dynamic>{});
  final s = TmdbSettings.fromJson(j);
  return s.enabled ? TmdbClient(s) : null;
});

final favoriteListProvider = FutureProvider<List<VodItem>>((ref) => ref.watch(favoriteRepositoryProvider).all());
final historyListProvider = FutureProvider<List<ProgressEntry>>((ref) => ref.watch(historyRepositoryProvider).all());
