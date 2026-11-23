import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/json_store.dart';
import '../core/node_bridge.dart';
import '../features/backup/backup_service.dart';
import '../features/catpaw/catpaw_client.dart';
import '../features/catpaw/catpaw_protocol.dart';
import '../features/catpaw/catpaw_recovery.dart';
import '../features/catpaw/dart_callback_server.dart';
import '../features/catpaw/manager_client.dart';
import '../features/catpaw/site_auth.dart';
import '../features/catpaw/spider_api.dart';
import '../features/cleanup/cleanup_service.dart';
import '../features/danmaku/danmu_service.dart';
import '../features/library/watch_repository.dart';
import '../features/player/head_tail.dart';
import '../features/player/playback_source.dart';
import '../features/player/player_launcher.dart';
import '../features/player/player_session.dart';
import '../features/search/search_state.dart';
import '../features/sniffer/sniffer_service.dart';
import '../features/subscription/profile_service.dart';
import '../features/subscription/subscription.dart';
import '../l10n/l10n.dart';
import '../models/vod.dart';
import '../services/danmu_client.dart';
import '../services/tmdb_client.dart';
import '../services/webdav_sync.dart';
import '../ui/load_error.dart';
import '../ui/poster_image.dart';
import 'app_preferences.dart';
import 'extra_providers.dart';
import 'live_providers.dart';
import 'router.dart';
import 'site_prefs.dart';
import 'ui_hooks.dart';

export '../features/subscription/profile_service.dart' show sanitizeSubscriptionProfile, mergeProfileMaps;

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
final siteAuthRepositoryProvider = Provider((ref) => SiteAuthRepository());

Future<void> _syncBrowserVerifySitesToHost(Ref ref, CatpawClient catpaw, List<SpiderSite> sites) async {
  try {
    final saved = await ref.read(siteAuthRepositoryProvider).all();
    final active = <String, Map<String, Object?>>{};
    for (final site in sites) {
      if (!site.browserVerify) continue;
      final key = site.key.trim().toLowerCase();
      final bareKey = key.replaceFirst(RegExp(r'^nodejs_'), '');
      final stored = saved[key] ?? saved[bareKey];
      final origin = (stored?.origin.isNotEmpty == true ? stored!.origin : (site.verifyUrl ?? '')).trim();
      final payload = SiteAuthEntry(
        siteKey: key,
        origin: origin,
        cookie: stored?.cookie ?? '',
        userAgent: stored?.userAgent ?? '',
        updatedAt: stored?.updatedAt ?? 0,
      ).toJson();
      active[key] = payload;
      if (bareKey.isNotEmpty && bareKey != key) {
        active[bareKey] = {...payload, 'siteKey': bareKey};
      }
    }
    await catpaw.setSiteAuth(active, replace: true);
  } catch (e) {
    debugPrint('sync browserVerify site auth failed: $e');
  }
}

/// Persists browser-verified credentials for a site and hot-pushes them to the active local CatPaw worker.
Future<void> applyVerifiedSiteAuth(WidgetRef ref, SiteAuthEntry entry) async {
  await ref.read(siteAuthRepositoryProvider).save(entry);
  final catpaw = ref.read(catpawClientProvider);
  if (catpaw.attached) {
    final key = entry.siteKey.trim().toLowerCase();
    final bareKey = key.replaceFirst(RegExp(r'^nodejs_'), '');
    final json = entry.toJson();
    await catpaw.setSiteAuth({
      key: json,
      if (bareKey.isNotEmpty && bareKey != key) bareKey: {...json, 'siteKey': bareKey},
    });
  }
  try {
    final subs = await ref.read(subscriptionsProvider.future);
    final selected = await ref.read(activeSubscriptionKeyProvider.future);
    final subKey = subs.where((s) => s.key == selected).firstOrNull?.key ?? (subs.isNotEmpty ? subs.first.key : 'default');
    await ref.read(subscriptionProfileServiceProvider).saveProfile(subKey, {
      entry.siteKey: {
        'cookie': entry.cookie,
        'userAgent': entry.userAgent,
        'origin': entry.origin,
      },
    });
  } catch (e) {
    debugPrint('save verified site auth to profile failed: $e');
  }
  final rt = ref.read(catpawRuntimeProvider).valueOrNull;
  if (rt != null) {
    unawaited(rt.api.saveSiteAuth(
      siteKey: entry.siteKey,
      origin: entry.origin,
      cookie: entry.cookie,
      userAgent: entry.userAgent,
    ));
  }
}
final playerConfigRepositoryProvider = Provider((ref) => PlayerConfigRepository());
final snifferServiceProvider = Provider((ref) => SnifferService());
final settingsStoreProvider = Provider((ref) => JsonStore('settings.json'));
final subscriptionProfilesStoreProvider = Provider((ref) => JsonStore('subscription_profiles.json'));
final subscriptionProfileServiceProvider =
    Provider((ref) => SubscriptionProfileService(ref.watch(subscriptionProfilesStoreProvider)));
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
      ensureSubscriptionPort: () async => (await ref.read(catpawRuntimeProvider.future))?.api.port,
    ));

final headTailRepositoryProvider = Provider((ref) => HeadTailRepository());

final playerLauncherProvider = Provider((ref) => PlayerLauncher(
      configs: ref.watch(playerConfigRepositoryProvider),
      sniffer: ref.watch(snifferServiceProvider),
      danmu: () => ref.read(danmuServiceControllerProvider).resolve(),
      preferVideoDanmu: () async {
        final cfg = await ref.read(danmuServiceControllerProvider).config();
        return cfg.enabled && cfg.preferVideoDanmu;
      },
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

  Future<void> select(String? key) async {
    await ref.read(settingsStoreProvider).update<Map<String, dynamic>>(const {}, (cur) {
      final out = Map<String, dynamic>.of(cur);
      if (key == null) {
        out.remove(_field);
      } else {
        out[_field] = key;
      }
      return out;
    });
    state = AsyncData(key);
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

/// Container-scoped tracker for the currently running local CatPaw worker key and in-flight background auto-updates.
class _CatpawRuntimeState {
  String? lastRunningSubKey;
  final Set<String> checkingAutoUpdate = {};
}

final _catpawRuntimeStateProvider = Provider((ref) => _CatpawRuntimeState());

/// Checks remote MD5 in the background so `sub.autoUpdate` never blocks app startup by up to 8s.
void _scheduleBackgroundAutoUpdateCheck(
    Ref ref, Subscription sub, String currentMd5, SubscriptionInstaller installer) {
  final tracker = ref.read(_catpawRuntimeStateProvider);
  if (!tracker.checkingAutoUpdate.add(sub.key)) return;
  var alive = true;
  ref.onDispose(() => alive = false);
  unawaited(() async {
    try {
      final remote = await installer.remoteMd5(sub);
      if (!alive || remote == null || remote == currentMd5) return;
      final next = await installer.install(
        sub,
        confirmConfigMismatch: () => confirmConfigChecksumMismatch(rootNavigatorKey),
      );
      if (!alive) return;
      await ref
          .read(subscriptionRepositoryProvider)
          .upsert(sub.copyWith(installedMd5: next.md5, updatedAt: DateTime.now().millisecondsSinceEpoch));
      ref.invalidate(subscriptionsProvider);
      // Keep the running worker alive so Home never resets mid-scroll; the staged script takes effect on next launch
      // or explicit refresh.
      if (tracker.lastRunningSubKey != sub.key) {
        ref.invalidate(catpawRuntimeProvider);
      }
    } catch (e) {
      debugPrint('background autoUpdate failed for ${sub.key}: $e');
    } finally {
      tracker.checkingAutoUpdate.remove(sub.key);
    }
  }());
}

/// Supervises the active local CatPaw instance across idle/background resume and connection drops.
final catpawSupervisorProvider = Provider<CatpawSupervisor>((ref) {
  return CatpawSupervisor(
    catpaw: ref.watch(catpawClientProvider),
    callbackServer: ref.watch(dartCallbackServerProvider),
    activeSubscription: () async {
      final subs = await ref.read(subscriptionsProvider.future);
      if (subs.isEmpty) return null;
      final key = await ref.read(activeSubscriptionKeyProvider.future);
      return subs.firstWhere((s) => s.key == key, orElse: () => subs.first);
    },
    currentApi: () => ref.read(catpawRuntimeProvider).valueOrNull?.api,
    isRuntimeStarting: () => ref.read(catpawRuntimeProvider).isLoading,
    restartInstance: (sub) async {
      final installed = ref.read(catpawRuntimeProvider).valueOrNull == null
          ? null
          : await ref.read(subscriptionInstallerProvider).installedScript(sub);
      if (installed == null) {
        ref.invalidate(catpawRuntimeProvider);
        return (await ref.read(catpawRuntimeProvider.future))?.api.port;
      }
      final catpaw = ref.read(catpawClientProvider);
      await catpaw.attach();
      final cb = ref.read(dartCallbackServerProvider);
      await catpaw.setDartPort(await cb.ensureRunning(), token: cb.token);
      final profileFilePath = await ref.read(subscriptionProfileServiceProvider).prepareProfilePath(sub.key);
      ref.read(_catpawRuntimeStateProvider).lastRunningSubKey = sub.key;
      final nextPort = await catpaw.startAndWait(
        name: sub.key,
        scriptPath: installed.scriptPath,
        configPath: installed.configPath,
        force: true,
        env: profileFilePath == null ? null : {'profile_path': profileFilePath},
      );
      final currentSites = ref.read(catpawRuntimeProvider).valueOrNull?.sites;
      if (currentSites != null) {
        await _syncBrowserVerifySitesToHost(ref, catpaw, currentSites);
      }
      return nextPort;
    },
    log: (msg) {
      debugPrint(msg);
      ref.read(nodeBridgeProvider).logDiagnostic(msg);
    },
  );
});

/// Installs the active subscription's script (if needed), starts it in the Node runtime and loads its sites.
/// Cloud subscriptions skip the local runtime and talk to the given address directly.
final FutureProvider<SpiderRuntime?> catpawRuntimeProvider = FutureProvider<SpiderRuntime?>((ref) async {
  // Rebuild only when what the runtime runs can change (which subscription is first, where each script comes from).
  // Renaming, 自动更新/上锁 and the 上次更新 stamp below must not restart the running script; pages that change the script
  // itself (refresh, a new zip) invalidate this provider explicitly.
  await ref.watch(subscriptionsProvider.selectAsync(_runtimeInputs));
  final runtimeState = ref.watch(_catpawRuntimeStateProvider);
  final subs = await ref.read(subscriptionsProvider.future);
  if (subs.isEmpty) {
    PosterImage.localCatpawPort = 0;
    final prevKey = runtimeState.lastRunningSubKey;
    if (prevKey != null) {
      runtimeState.lastRunningSubKey = null;
      try {
        final catpaw = ref.read(catpawClientProvider);
        if (catpaw.attached) await catpaw.stop(prevKey);
      } catch (e) {
        debugPrint('stop previous catpaw ($prevKey) failed: $e');
      }
    }
    return null; // UI: "Add a catpaw subscription on the Subscriptions page first"
  }
  final key = await ref.watch(activeSubscriptionKeyProvider.future);
  final sub = subs.firstWhere((s) => s.key == key, orElse: () => subs.first);

  if (sub.cloudUrl != null) {
    PosterImage.localCatpawPort = 0;
    final prevKey = runtimeState.lastRunningSubKey;
    if (prevKey != null && prevKey != sub.key) {
      runtimeState.lastRunningSubKey = null;
      try {
        final catpaw = ref.read(catpawClientProvider);
        if (catpaw.attached) await catpaw.stop(prevKey);
      } catch (e) {
        debugPrint('stop previous catpaw ($prevKey) failed: $e');
      }
    }
    final uri = Uri.parse(sub.cloudUrl!);
    final api =
        SpiderApi(uri.port, baseUrl: sub.cloudUrl, receiveTimeout: ref.read(appPreferencesProvider).catpawTimeout);
    return SpiderRuntime(subscription: sub, api: api, sites: await api.sites());
  }

  final catpaw = ref.watch(catpawClientProvider);
  await catpaw.attach(); // completes after "Node ready"
  final prevKey = runtimeState.lastRunningSubKey;
  if (prevKey != null && prevKey != sub.key) {
    try {
      await catpaw.stop(prevKey);
    } catch (e) {
      debugPrint('stop previous catpaw ($prevKey) failed: $e');
    }
  }
  // Scripts reach the app through this loopback server; the port must be announced before the script starts.
  final cb = ref.watch(dartCallbackServerProvider);
  await catpaw.setDartPort(await cb.ensureRunning(), token: cb.token);
  final installer = ref.watch(subscriptionInstallerProvider);
  var installed = await installer.installedScript(sub); // reuse: no network needed on later launches
  var freshlyInstalled = false;
  if (installed == null) {
    if (sub.local) throw StateError('the local script is missing; import the zip again on the edit page');
    installed =
        await installer.install(sub, confirmConfigMismatch: () => confirmConfigChecksumMismatch(rootNavigatorKey));
    await ref
        .read(subscriptionRepositoryProvider)
        .upsert(sub.copyWith(installedMd5: installed.md5, updatedAt: DateTime.now().millisecondsSinceEpoch));
    freshlyInstalled = true;
  } else if (sub.autoUpdate && !sub.local) {
    _scheduleBackgroundAutoUpdateCheck(ref, sub, installed.md5, installer);
  }
  final int port;
  try {
    final profileFilePath = await ref.read(subscriptionProfileServiceProvider).prepareProfilePath(sub.key);
    runtimeState.lastRunningSubKey = sub.key;
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
  PosterImage.localCatpawPort = port;
  final api = SpiderApi(
    port,
    receiveTimeout: ref.read(appPreferencesProvider).catpawTimeout,
    onConnectionErrorRecover: () => ref.read(catpawSupervisorProvider).recoverNow(),
  );
  final sites = await api.sites();
  await _syncBrowserVerifySitesToHost(ref, catpaw, sites);
  return SpiderRuntime(subscription: sub, api: api, sites: sites);
});

String _runtimeInputs(List<Subscription> subs) =>
    [for (final s in subs) '${s.key}|${s.indexJsUrl}|${s.cloudUrl}|${s.local}'].join('\n');

class LiveCatalogRevision extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final liveCatalogRevisionProvider = NotifierProvider<LiveCatalogRevision, int>(LiveCatalogRevision.new);

final liveSitesProvider = FutureProvider<List<SpiderSite>>((ref) async {
  final rev = ref.watch(liveCatalogRevisionProvider);
  final rt = await ref.watch(catpawRuntimeProvider.future);
  if (rt == null) return const [];
  if (rev == 0) return rt.sites;
  return rt.api.sites();
});

void reloadLiveCatalog(ProviderContainer container) {
  container.read(liveCatalogRevisionProvider.notifier).bump();
  container.invalidate(videoFeedProvider);
}

final homeSitesProvider = Provider<List<SpiderSite>>((ref) {
  final live = ref.watch(liveSitesProvider);
  return live.valueOrNull ?? ref.watch(catpawRuntimeProvider).valueOrNull?.sites ?? const [];
});

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
    await ref.read(settingsStoreProvider).update<Map<String, dynamic>>(const {}, (settings) {
      final saved = settings[_field];
      return {
        ...settings,
        _field: {if (saved is Map) ...saved, sub: key},
      };
    });
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
  // Wait for the saved choice (including across subscription switches) instead of flashing the first site first.
  if (selected.isLoading || (!selected.hasValue && !selected.hasError)) return null;
  // Likewise wait for 站点设置, so a disabled or locked site is not loaded first. A site that is switched off or locked
  // while shown gives way to the first one still listed in 切换站点 (all sites when none is left).
  final prefs = ref.watch(sitePrefsProvider);
  if (prefs.isLoading || (!prefs.hasValue && !prefs.hasError)) return null;
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
      final site = ref.read(homeSitesProvider).where((s) => s.key == q.siteKey).firstOrNull ??
          rt?.sites.where((s) => s.key == q.siteKey).firstOrNull;
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
bool webviewReplacesTop(Uri top, bool Function(DetailQuery q) detailLoading) =>
    top.path == '/video/detail' &&
    detailLoading((siteKey: top.queryParameters['site'], vodId: top.queryParameters['id'] ?? ''));

final Provider<DartCallbackServer> dartCallbackServerProvider = Provider<DartCallbackServer>((ref) {
  final history = ref.watch(historyRepositoryProvider);
  final profileService = ref.watch(subscriptionProfileServiceProvider);
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

  // Every payload field name below is INFERRED (only the action names were observed), hence the alias lists.
  final server = DartCallbackServer(handlers: {
    DartActions.toast: (args) async {
      final message = str(args, ['message', 'msg', 'text', 'content']) ?? '';
      final duration = toastDuration(args['duration']);
      final onPlayer = await ref
          .read(playerLauncherProvider)
          .host
          .showToast(message, duration >= const Duration(milliseconds: 3500))
          .catchError((Object _) => false);
      if (!onPlayer) showToast(message, duration: duration);
      return true;
    },
    DartActions.queryHistory: (args) async => [for (final e in await history.all()) e.toJson()],
    DartActions.queryProfile: (args) async => profileService.queryProfile(await activeProfileSubKey(), args),
    DartActions.saveProfile: (args) async {
      try {
        await profileService.saveProfile(await activeProfileSubKey(), args);
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
      final ctx = rootNavigatorKey.currentContext;
      final home = ctx != null ? ProviderScope.containerOf(ctx, listen: false).read(videoFeedProvider).valueOrNull : null;
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
      final rawUrl = str(args, ['url']);
      if (rawUrl == null) throw ArgumentError('url missing');
      var url = PosterImage.normalizeLocalUrl(rawUrl);
      if (PosterImage.localCatpawPort > 0) {
        final parsed = Uri.tryParse(url);
        if (parsed != null &&
            parsed.scheme == 'http' &&
            parsed.hasPort &&
            parsed.port == 9321 &&
            PosterImage.isPrivateLanIpv4(parsed.host)) {
          url = parsed.replace(host: '127.0.0.1').toString();
        }
      }
      final router = ref.read(routerProvider);
      final config = router.routerDelegate.currentConfiguration;
      final topUri = config.isNotEmpty ? config.uri : Uri.parse('/');
      final target = Uri(path: '/website', queryParameters: {'url': url}).toString();
      if (topUri.path == '/website') {
        if (topUri.queryParameters['url'] != url) unawaited(router.pushReplacement(target));
        return true;
      }
      final isBasesetDetail = topUri.path == '/video/detail' &&
          ((topUri.queryParameters['site'] ?? '').endsWith('baseset') ||
              topUri.queryParameters['id'] == 'openInternalWebsite' ||
              (topUri.queryParameters['id'] ?? '').startsWith('webpage:'));
      final ctx = rootNavigatorKey.currentContext;
      final rootContainer = ctx != null ? ProviderScope.containerOf(ctx, listen: false) : null;
      final replaces = rootContainer != null &&
          webviewReplacesTop(topUri, (q) => rootContainer.read(videoDetailProvider(q)).isLoading);
      if (replaces || isBasesetDetail) {
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
    await ref.read(settingsStoreProvider).update<Map<String, dynamic>>(const {}, (cur) => next.writeTo(cur, _subscription));
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

/// Invalidates Riverpod state for documents overwritten during a WebDAV pull so open screens show fresh data immediately.
void refreshProvidersAfterWebDavPull(ProviderContainer container, Iterable<String> pulled) {
  final set = pulled.toSet();
  if (set.isEmpty) return;
  if (set.contains('favorites.json')) container.invalidate(favoriteListProvider);
  if (set.contains('auto_sync_favorites.json')) container.invalidate(autoSyncFavoritesProvider);
  if (set.contains('history.json') || set.contains('play_progress.json') || set.contains('last_episode.json')) {
    container.invalidate(historyListProvider);
  }
  if (set.contains('tracking.json')) {
    container.invalidate(trackingListProvider);
    container.invalidate(trackingWeekProvider);
  }
  if (set.contains('tmdb_settings.json') || set.contains('tmdb_refs.json')) {
    container.invalidate(tmdbProvider);
    container.invalidate(tmdbMatchProvider);
    container.invalidate(trackingWeekProvider);
  }
  if (set.contains('live_sources.json')) container.invalidate(liveSourcesProvider);
  if (set.contains('live_preferences.json')) container.invalidate(livePreferencesProvider);
  if (set.contains('player_config.json')) {
    unawaited(container.read(playerConfigRepositoryProvider).load());
  }
}
