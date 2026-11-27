import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/app/providers.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/features/catpaw/spider_api.dart';
import 'package:uzv_reimpl/features/subscription/subscription.dart';

/// The layout the original documents (`https://user:pass@host/index.js.md5`): the URL users paste is the checksum
/// file, the script is next to it without `.md5`, and `index.config.js` (+ `.md5`) sits beside the script.
void main() {
  late HttpServer server;
  late Directory dir;
  late Map<String, List<int>> files;
  late List<String> requestedPaths;
  String? requiredAuth;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('uzv_sub');
    files = {};
    requestedPaths = [];
    requiredAuth = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      requestedPaths.add(req.uri.path);
      final auth = requiredAuth;
      if (auth != null && req.headers.value('authorization') != 'Basic ${base64Encode(utf8.encode(auth))}') {
        req.response.statusCode = 401;
      } else if (files[req.uri.path] case final body?) {
        req.response.add(body);
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    dir.deleteSync(recursive: true);
  });

  String base([String userInfo = '']) => 'http://$userInfo${InternetAddress.loopbackIPv4.address}:${server.port}';
  String md5Of(String s) => md5.convert(utf8.encode(s)).toString();
  void put(String path, String content, {bool withMd5 = true, String? md5Text}) {
    files[path] = utf8.encode(content);
    if (withMd5) files['$path.md5'] = utf8.encode('${md5Text ?? md5Of(content)}\n');
  }

  Subscription sub(String url) => Subscription(key: 'k', name: 'n', indexJsUrl: url);
  const script = 'module.exports = { start() {} };';
  const config = 'module.exports = { sites: 3 };';

  test('an index.js.md5 URL installs index.js and index.config.js from next to it', () async {
    put('/sub/index.js', script);
    put('/sub/index.config.js', config);
    final r = await SubscriptionInstaller(root: dir).install(sub('${base()}/sub/index.js.md5'));
    expect(File(r.scriptPath).readAsStringSync(), script);
    expect(File(r.configPath!).readAsStringSync(), config);
    expect(r.md5, md5Of(script));
  });

  test('script download progress is published while downloading and cleared after', () async {
    put('/sub/index.js', script);
    final installer = SubscriptionInstaller(root: dir);
    final seen = <({int received, int total})?>[];
    installer.downloadProgress.addListener(() => seen.add(installer.downloadProgress.value));
    await installer.install(sub('${base()}/sub/index.js.md5'));
    expect(seen.whereType<({int received, int total})>().last.received, utf8.encode(script).length);
    expect(installer.downloadProgress.value, isNull);
  });

  test('credentials in the URL are sent as basic auth and kept out of error messages', () async {
    requiredAuth = 'u:secret';
    put('/sub/index.js', script, md5Text: '0' * 32);
    final installer = SubscriptionInstaller(root: dir);
    await expectLater(
      installer.install(sub('${base('u:secret@')}/sub/index.js.md5')),
      throwsA(predicate((e) => '$e'.contains('md5 mismatch') && !'$e'.contains('secret'))),
    );
    put('/sub/index.js', script);
    final r = await installer.install(sub('${base('u:secret@')}/sub/index.js.md5'));
    expect(File(r.scriptPath).readAsStringSync(), script);
  });

  test('a .md5 URL that does not hold a 32-hex md5 fails instead of installing the checksum as the script', () async {
    files['/sub/index.js.md5'] = utf8.encode('<html>login</html>');
    files['/sub/index.js'] = utf8.encode(script);
    await expectLater(
      SubscriptionInstaller(root: dir).install(sub('${base()}/sub/index.js.md5')),
      throwsA(predicate((e) => '$e'.contains('no 32-hex md5 found at'))),
    );
  });

  test('a missing index.config.js means an empty config', () async {
    put('/sub/index.js', script);
    final r = await SubscriptionInstaller(root: dir).install(sub('${base()}/sub/index.js.md5'));
    expect(r.configPath, isNull);
  });

  test('a config whose md5 does not match is used only when the user agrees', () async {
    put('/sub/index.js', script);
    put('/sub/index.config.js', config, md5Text: '1' * 32);
    final installer = SubscriptionInstaller(root: dir);
    var asked = 0;
    final declined = await installer.install(sub('${base()}/sub/index.js.md5'), confirmConfigMismatch: () async {
      asked++;
      return false;
    });
    expect(declined.configPath, isNull);
    final accepted = await installer.install(sub('${base()}/sub/index.js.md5'), confirmConfigMismatch: () async {
      asked++;
      return true;
    });
    expect(File(accepted.configPath!).readAsStringSync(), config);
    expect(asked, 2);
  });

  test('a plain index.js URL still installs without a checksum file', () async {
    put('/sub/index.js', script, withMd5: false);
    final r = await SubscriptionInstaller(root: dir).install(sub('${base()}/sub/index.js'));
    expect(File(r.scriptPath).readAsStringSync(), script);
  });

  test('installs made before this layout was understood are not reused', () async {
    final installer = SubscriptionInstaller(root: dir);
    final old = File('${dir.path}/subscriptions/k/index.js')..createSync(recursive: true);
    old.writeAsStringSync('3a5f0c…'); // what the old installer saved for an index.js.md5 URL
    expect(await installer.installedScript(sub('${base()}/sub/index.js.md5')), isNull);

    put('/sub/index.js', script);
    put('/sub/index.config.js', config);
    await installer.install(sub('${base()}/sub/index.js.md5'));
    final reused = await installer.installedScript(sub('${base()}/sub/index.js.md5'));
    expect(reused!.md5, md5Of(script));
    expect(reused.configPath, isNotNull);
  });

  test('remoteMd5 reads the checksum file and is null when it cannot be fetched', () async {
    put('/sub/index.js', script);
    final installer = SubscriptionInstaller(root: dir);
    expect(await installer.remoteMd5(sub('${base()}/sub/index.js.md5')), md5Of(script));
    expect(await installer.remoteMd5(sub('${base()}/missing/index.js.md5')), isNull);
  });

  group('SubscriptionService', () {
    late SubscriptionRepository repo;
    late SubscriptionService service;
    var clock = DateTime(2026, 11, 9, 12);

    setUp(() {
      repo = SubscriptionRepository(store: JsonStore('subscriptions.json', baseDir: dir));
      service = SubscriptionService(repository: repo, installer: SubscriptionInstaller(root: dir), now: () => clock);
    });

    test('adding installs first, names a blank subscription "catpaw" and records the md5 and time', () async {
      put('/sub/index.js', script);
      final sub = await service.addNetwork(url: ' ${base()}/sub/index.js.md5 ', name: '  ');
      expect(sub.name, defaultSubscriptionName);
      expect(sub.installedMd5, md5Of(script));
      expect(sub.updatedAt, clock.millisecondsSinceEpoch);
      expect((await repo.all()).single.indexJsUrl, '${base()}/sub/index.js.md5');
    });

    test('a failed download is not saved', () async {
      await expectLater(service.addNetwork(url: '${base()}/nothing/index.js.md5'), throwsA(anything));
      expect(await repo.all(), isEmpty);
      expect(Directory('${dir.path}/subscriptions').listSync(), isEmpty);
    });

    test('the same URL cannot be added twice', () async {
      put('/sub/index.js', script);
      await service.addNetwork(url: '${base()}/sub/index.js.md5');
      await expectLater(service.addNetwork(url: '${base()}/sub/index.js.md5'), throwsA(isA<DuplicateSubscriptionException>()));
    });

    test('refresh reports up to date, stamps updatedAt, updates config.js changes, and downloads a changed script', () async {
      put('/sub/index.js', script);
      put('/sub/index.config.js', config);
      final sub = await service.addNetwork(url: '${base()}/sub/index.js.md5');
      clock = clock.add(const Duration(minutes: 10));
      expect(await service.refresh(sub), isNull);
      expect((await repo.all()).single.updatedAt, clock.millisecondsSinceEpoch,
          reason: 'manual refresh updates updatedAt even when index.js.md5 is unchanged');

      // Only index.config.js changes while index.js.md5 stays the same.
      const configV2 = 'module.exports = { sites: 9 };';
      put('/sub/index.config.js', configV2);
      clock = clock.add(const Duration(minutes: 5));
      final cfgUpdated = await service.refresh(sub);
      expect(cfgUpdated, isNotNull);
      expect(cfgUpdated!.updatedAt, clock.millisecondsSinceEpoch);
      final installed = await SubscriptionInstaller(root: dir).installedScript(sub);
      expect(File(installed!.configPath!).readAsStringSync(), configV2);

      // Cloud subscription refresh probes /config and stamps updatedAt.
      files['/config'] = utf8.encode('{"sites":[]}');
      final cloud = await service.addCloud(url: base());
      clock = clock.add(const Duration(minutes: 3));
      expect(await service.refresh(cloud), isNull);
      expect((await repo.all()).firstWhere((s) => s.key == cloud.key).updatedAt, clock.millisecondsSinceEpoch);

      const v2 = 'module.exports = { start() {}, v: 2 };';
      put('/sub/index.js', v2);
      requestedPaths.clear();
      clock = clock.add(const Duration(hours: 1));
      final updated = await service.refresh(sub);
      expect(updated!.installedMd5, md5Of(v2));
      expect(updated.updatedAt, clock.millisecondsSinceEpoch);
      expect((await repo.all()).firstWhere((s) => s.key == sub.key).installedMd5, md5Of(v2));
      expect(
        requestedPaths.where((p) => p == '/sub/index.js.md5').length,
        1,
        reason: 'refresh must not re-fetch index.js.md5 a second time during install',
      );

      // Up-to-date refresh checks only .md5 sidecars and downloads zero JS files.
      requestedPaths.clear();
      expect(await service.refresh(sub), isNull);
      expect(requestedPaths.toSet(), {'/sub/index.js.md5', '/sub/index.config.js.md5'});
    });

    test('runStartupSubscriptionAutoUpdate syncs all autoUpdate subscriptions and reloads active runtime on update',
        () async {
      put('/a/index.js', script);
      put('/b/index.js', script);
      final subA = await service.addNetwork(url: '${base()}/a/index.js.md5', name: 'Active', autoUpdate: true);
      final subB = await service.addNetwork(url: '${base()}/b/index.js.md5', name: 'Secondary', autoUpdate: true);

      const scriptV2 = 'module.exports = { start() {}, v: "new_active" };';
      put('/a/index.js', scriptV2);
      clock = clock.add(const Duration(hours: 2));

      var runtimeBuilds = 0;
      final container = ProviderContainer(overrides: [
        subscriptionRepositoryProvider.overrideWithValue(repo),
        subscriptionInstallerProvider.overrideWithValue(service.installer),
        subscriptionServiceProvider.overrideWithValue(service),
        settingsStoreProvider.overrideWithValue(JsonStore('settings.json', baseDir: dir)),
        catpawRuntimeProvider.overrideWith((ref) async {
          runtimeBuilds++;
          final subs = await ref.read(subscriptionsProvider.future);
          return SpiderRuntime(
            subscription: subs.first,
            api: SpiderApi(2333, baseUrl: 'http://127.0.0.1:2333'),
            sites: const [],
          );
        }),
      ]);
      addTearDown(container.dispose);

      await container.read(catpawRuntimeProvider.future);
      expect(runtimeBuilds, 1);

      await runStartupSubscriptionAutoUpdate(container);
      await container.read(catpawRuntimeProvider.future);

      final all = await repo.all();
      final savedA = all.firstWhere((s) => s.key == subA.key);
      final savedB = all.firstWhere((s) => s.key == subB.key);
      expect(savedA.installedMd5, md5Of(scriptV2));
      expect(savedA.updatedAt, clock.millisecondsSinceEpoch, reason: 'active autoUpdate stamped and updated');
      expect(savedB.updatedAt, clock.millisecondsSinceEpoch, reason: 'non-active autoUpdate also checked and stamped');
      expect(runtimeBuilds, greaterThanOrEqualTo(2), reason: 'active runtime reloaded onto newly downloaded script');
    });

    test('runStartupSubscriptionAutoUpdate silently keeps cached script when an autoUpdate source is unreachable',
        () async {
      final tmpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      tmpServer.listen((req) async {
        if (req.uri.path == '/dead/index.js.md5') {
          req.response.write('${md5Of(script)}\n');
        } else {
          req.response.write(script);
        }
        await req.response.close();
      });
      final deadSub = await service.addNetwork(
        url: 'http://127.0.0.1:${tmpServer.port}/dead/index.js.md5',
        name: 'USB Tunnel',
        autoUpdate: true,
      );
      final initialUpdatedAt = deadSub.updatedAt;
      await tmpServer.close(force: true);

      clock = clock.add(const Duration(hours: 1));
      final container = ProviderContainer(overrides: [
        subscriptionRepositoryProvider.overrideWithValue(repo),
        subscriptionInstallerProvider.overrideWithValue(service.installer),
        subscriptionServiceProvider.overrideWithValue(service),
        settingsStoreProvider.overrideWithValue(JsonStore('settings_dead.json', baseDir: dir)),
      ]);
      addTearDown(container.dispose);

      await runStartupSubscriptionAutoUpdate(container);
      final saved = (await repo.all()).single;
      expect(saved.installedMd5, md5Of(script));
      expect(saved.updatedAt, initialUpdatedAt, reason: 'unreachable background check leaves cached record untouched');
    });

    test(
        'iosStartupSubscriptionGateProvider updates before home entry and lets slow downloads finish in background after timeout',
        () async {
      put('/ios/index.js', script);
      final subIos = await service.addNetwork(url: '${base()}/ios/index.js.md5', name: 'iOS Sub', autoUpdate: true);

      // 1. Fast remote update finishes inside gate -> runtime starts ONCE on the updated script (no double refresh).
      const scriptV2 = 'module.exports = { start() {}, v: "ios_v2" };';
      put('/ios/index.js', scriptV2);
      clock = clock.add(const Duration(hours: 1));
      var fastBuilds = 0;
      String? startedMd5;
      final fastContainer = ProviderContainer(overrides: [
        iosStartupGateEnabledProvider.overrideWithValue(true),
        iosStartupGateTimeoutProvider.overrideWithValue(const Duration(seconds: 3)),
        subscriptionRepositoryProvider.overrideWithValue(repo),
        subscriptionInstallerProvider.overrideWithValue(service.installer),
        subscriptionServiceProvider.overrideWithValue(service),
        settingsStoreProvider.overrideWithValue(JsonStore('settings.json', baseDir: dir)),
        catpawRuntimeProvider.overrideWith((ref) async {
          await ref.watch(iosStartupSubscriptionGateProvider.future);
          fastBuilds++;
          final installed = await service.installer.installedScript(subIos);
          startedMd5 = installed?.md5;
          final subs = await ref.read(subscriptionsProvider.future);
          return SpiderRuntime(
            subscription: subs.first,
            api: SpiderApi(2333, baseUrl: 'http://127.0.0.1:2333'),
            sites: const [],
          );
        }),
      ]);
      addTearDown(fastContainer.dispose);

      await fastContainer.read(iosStartupSubscriptionGateProvider.future);
      await fastContainer.read(catpawRuntimeProvider.future);
      expect(fastBuilds, 1, reason: 'home runtime initialized exactly once after gate');
      expect(startedMd5, md5Of(scriptV2), reason: 'already running the updated V2 script on first boot');

      // 2. Slow remote server exceeds gate timeout -> enters immediately on local cache, keeps download alive, and
      // hot-reloads runtime once the background download finishes.
      const scriptV3 = 'module.exports = { start() {}, v: "ios_v3" };';
      final slowServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => slowServer.close(force: true));
      slowServer.listen((req) async {
        await Future<void>.delayed(const Duration(milliseconds: 160));
        if (req.uri.path == '/ios/index.js.md5') {
          req.response.write('${md5Of(scriptV3)}\n');
        } else if (req.uri.path == '/ios/index.js') {
          req.response.write(scriptV3);
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close().catchError((_) {});
      });
      final slowSub = subIos.copyWith(indexJsUrl: 'http://127.0.0.1:${slowServer.port}/ios/index.js.md5');
      await repo.save([slowSub]);

      var timeoutBuilds = 0;
      String? currentMd5;
      final timeoutContainer = ProviderContainer(overrides: [
        iosStartupGateEnabledProvider.overrideWithValue(true),
        iosStartupGateTimeoutProvider.overrideWithValue(const Duration(milliseconds: 60)),
        subscriptionRepositoryProvider.overrideWithValue(repo),
        subscriptionInstallerProvider.overrideWithValue(service.installer),
        subscriptionServiceProvider.overrideWithValue(service),
        settingsStoreProvider.overrideWithValue(JsonStore('settings_slow.json', baseDir: dir)),
        catpawRuntimeProvider.overrideWith((ref) async {
          await ref.watch(iosStartupSubscriptionGateProvider.future);
          timeoutBuilds++;
          currentMd5 = (await service.installer.installedScript(slowSub))?.md5;
          return SpiderRuntime(
            subscription: slowSub,
            api: SpiderApi(2333, baseUrl: 'http://127.0.0.1:2333'),
            sites: const [],
          );
        }),
      ]);
      addTearDown(timeoutContainer.dispose);
      timeoutContainer.listen<AsyncValue<SpiderRuntime?>>(catpawRuntimeProvider, (_, __) {}, fireImmediately: true);

      await timeoutContainer.read(iosStartupSubscriptionGateProvider.future);
      await timeoutContainer.read(catpawRuntimeProvider.future);
      expect(timeoutBuilds, 1, reason: 'entered home immediately on local cache when gate timed out');
      expect(currentMd5, md5Of(scriptV2), reason: 'booted onto local cached V2 script');

      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (timeoutBuilds < 2 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      await timeoutContainer.read(catpawRuntimeProvider.future);
      expect(timeoutBuilds, 2, reason: 'uncancelled gate download finished in background and hot-reloaded runtime');
      expect(currentMd5, md5Of(scriptV3), reason: 'reloaded onto newly downloaded V3 script');
    });

    test('background refresh reports errors via onBackgroundError while preserving null return contract', () async {
      put('/sub/index.js', script);
      final added = await service.addNetwork(url: '${base()}/sub/index.js.md5');

      final okErrors = <Object>[];
      expect(await service.refresh(added, background: true, onBackgroundError: okErrors.add), isNull);
      expect(okErrors, isEmpty);

      // Missing .md5 sidecar (404 -> DioException on required md5) invokes onBackgroundError and returns null.
      files.remove('/sub/index.js.md5');
      final missingErrors = <Object>[];
      expect(await service.refresh(added, background: true, onBackgroundError: missingErrors.add), isNull);
      expect(missingErrors, hasLength(1));

      // Non-hex .md5 sidecar with custom installer returning null scriptMd5 also invokes onBackgroundError.
      final nullMd5Installer = _NullMd5Installer(dir);
      final customService = SubscriptionService(repository: repo, installer: nullMd5Installer, now: () => clock);
      final unreachableErrors = <Object>[];
      expect(await customService.refresh(added, background: true, onBackgroundError: unreachableErrors.add), isNull);
      expect(unreachableErrors, hasLength(1));
    });

    test('background failure and timeout do not stamp cooldown and retryPendingSubscriptionAutoUpdates recovers',
        () async {
      put('/retry/index.js', script);
      await service.addNetwork(url: '${base()}/retry/index.js.md5', name: 'RetrySub', autoUpdate: true);

      // 1. Background check fails (server returns 404/offline) -> no cooldown stamped, pending retry recorded.
      files.remove('/retry/index.js.md5');
      var runtimeBuilds = 0;
      var confirmDialogCalls = 0;
      final container = ProviderContainer(overrides: [
        subscriptionRepositoryProvider.overrideWithValue(repo),
        subscriptionInstallerProvider.overrideWithValue(service.installer),
        subscriptionServiceProvider.overrideWithValue(service),
        settingsStoreProvider.overrideWithValue(JsonStore('settings_retry.json', baseDir: dir)),
        catpawRuntimeProvider.overrideWith((ref) async {
          runtimeBuilds++;
          final subs = await ref.read(subscriptionsProvider.future);
          return SpiderRuntime(
            subscription: subs.first,
            api: SpiderApi(2333, baseUrl: 'http://127.0.0.1:2333'),
            sites: const [],
          );
        }),
      ]);
      addTearDown(container.dispose);

      await container.read(catpawRuntimeProvider.future);
      expect(runtimeBuilds, 1);

      await runStartupSubscriptionAutoUpdate(container);
      expect((await repo.all()).single.installedMd5, md5Of(script));

      // Immediately (<15s!) bring server back with V2 + mismatched config md5 (background must NOT ask modal confirm).
      const scriptV2 = 'module.exports = { start() {}, v: "recovered_v2" };';
      put('/retry/index.js', scriptV2);
      put('/retry/index.config.js', config, md5Text: 'f' * 32);
      clock = clock.add(const Duration(minutes: 5));

      await retryPendingSubscriptionAutoUpdates(container);
      await container.read(catpawRuntimeProvider.future);
      expect((await repo.all()).single.installedMd5, md5Of(scriptV2));
      expect(runtimeBuilds, greaterThanOrEqualTo(2));
      expect(confirmDialogCalls, 0);

      // Once succeeded, another immediate retryPendingSubscriptionAutoUpdates is a no-op (0 HTTP calls).
      requestedPaths.clear();
      await retryPendingSubscriptionAutoUpdates(container);
      expect(requestedPaths, isEmpty);

      // 2. Overall autoUpdate timeout cancels zombie slow download, clears slot, and records retry-pending.
      final zombieServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => zombieServer.close(force: true));
      var zombieHealthy = false;
      const scriptV3 = 'module.exports = { start() {}, v: "recovered_v3" };';
      zombieServer.listen((req) async {
        if (!zombieHealthy) {
          // Hang longer than autoUpdateTimeoutProvider without closing.
          await Future<void>.delayed(const Duration(seconds: 2));
          await req.response.close().catchError((_) {});
          return;
        }
        if (req.uri.path == '/zombie/index.js.md5') {
          req.response.write('${md5Of(scriptV3)}\n');
        } else if (req.uri.path == '/zombie/index.js') {
          req.response.write(scriptV3);
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });
      final zombieSub = (await repo.all()).single.copyWith(
            indexJsUrl: 'http://127.0.0.1:${zombieServer.port}/zombie/index.js.md5',
          );
      await repo.save([zombieSub]);

      final zombieContainer = ProviderContainer(overrides: [
        autoUpdateTimeoutProvider.overrideWithValue(const Duration(milliseconds: 80)),
        subscriptionRepositoryProvider.overrideWithValue(repo),
        subscriptionInstallerProvider.overrideWithValue(service.installer),
        subscriptionServiceProvider.overrideWithValue(service),
        settingsStoreProvider.overrideWithValue(JsonStore('settings_zombie.json', baseDir: dir)),
      ]);
      addTearDown(zombieContainer.dispose);

      await runStartupSubscriptionAutoUpdate(zombieContainer).timeout(const Duration(seconds: 1));
      expect((await repo.all()).single.installedMd5, md5Of(scriptV2), reason: 'timed out zombie check kept V2');

      zombieHealthy = true;
      await retryPendingSubscriptionAutoUpdates(zombieContainer);
      expect((await repo.all()).single.installedMd5, md5Of(scriptV3), reason: 'retry after timeout updated to V3');
    });

    test('manual refresh preempts and cancels an in-flight background autoUpdate', () async {
      const scriptV2 = 'module.exports = { start() {}, v: "manual_v2" };';
      var scriptFetches = 0;
      final bgScriptStarted = Completer<void>();
      final releaseStalledBg = Completer<void>();
      final dualServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => dualServer.close(force: true));
      dualServer.listen((req) async {
        if (req.uri.path == '/dual/index.js.md5') {
          req.response.write('${md5Of(scriptFetches == 0 ? script : scriptV2)}\n');
          await req.response.close();
          return;
        }
        if (req.uri.path == '/dual/index.js') {
          final n = ++scriptFetches;
          if (n == 1) {
            // Initial addNetwork install.
            req.response.write(script);
            await req.response.close();
          } else if (n == 2) {
            // Background autoUpdate download: stall mid-flight until preempted.
            if (!bgScriptStarted.isCompleted) bgScriptStarted.complete();
            await releaseStalledBg.future;
            req.response.write(scriptV2);
            await req.response.close().catchError((_) {});
          } else {
            // Manual refresh download: succeeds immediately!
            req.response.write(scriptV2);
            await req.response.close();
          }
          return;
        }
        req.response.statusCode = 404;
        await req.response.close();
      });

      final dualSub = await service.addNetwork(
        url: 'http://127.0.0.1:${dualServer.port}/dual/index.js.md5',
        name: 'DualSub',
        autoUpdate: true,
      );
      expect(scriptFetches, 1);

      final container = ProviderContainer(overrides: [
        subscriptionRepositoryProvider.overrideWithValue(repo),
        subscriptionInstallerProvider.overrideWithValue(service.installer),
        subscriptionServiceProvider.overrideWithValue(service),
        settingsStoreProvider.overrideWithValue(JsonStore('settings_dual.json', baseDir: dir)),
      ]);
      addTearDown(container.dispose);

      final bgFuture = runStartupSubscriptionAutoUpdate(container);
      await bgScriptStarted.future.timeout(const Duration(seconds: 2));

      // Preempt background autoUpdate just as SubscriptionsScreen._refreshOne / _refreshAll does.
      cancelBackgroundAutoUpdate(container, dualSub.key);
      clock = clock.add(const Duration(minutes: 10));
      final updated = await service.refresh(dualSub);
      expect(updated, isNotNull);
      expect(updated!.installedMd5, md5Of(scriptV2));

      releaseStalledBg.complete();
      await bgFuture;

      final installed = await service.installer.installedScript(dualSub);
      expect(installed!.md5, md5Of(scriptV2));
      final subDir = Directory('${dir.path}/subscriptions/${dualSub.key}');
      expect(subDir.listSync().where((e) => e.path.endsWith('.tmp')), isEmpty);
    });

    test('a local zip needs both index.js and index.config.js', () async {
      List<int> zip(Map<String, String> files) {
        final a = Archive();
        files.forEach((n, c) => a.addFile(ArchiveFile.bytes(n, utf8.encode(c))));
        return ZipEncoder().encode(a);
      }

      await expectLater(service.addLocal(zip: zip({'index.js': script})), throwsA(isA<StateError>()));
      expect(await repo.all(), isEmpty);
      final sub = await service.addLocal(zip: zip({'dist/index.js': script, 'dist/index.config.js': config}), name: 'zip');
      expect(sub.local, isTrue);
      final installed = await SubscriptionInstaller(root: dir).installedScript(sub);
      expect(File(installed!.scriptPath).readAsStringSync(), script);
      expect(File(installed.configPath!).readAsStringSync(), config);
    });

    test('removeAll deletes the subscriptions and their files', () async {
      put('/sub/index.js', script);
      final a = await service.addNetwork(url: '${base()}/sub/index.js.md5');
      final b = await service.addCloud(url: 'http://10.0.0.2:9321');
      await service.removeAll([a]);
      expect((await repo.all()).map((s) => s.key), [b.key]);
      expect(await SubscriptionInstaller(root: dir).installedScript(a), isNull);
    });

    test('updateSubscription edits URL & name and preserves existing install on download failure', () async {
      put('/v1/index.js', script);
      const v2 = 'module.exports = { start() {}, v: 2 };';
      put('/v2/index.js', v2);
      final installer = SubscriptionInstaller(root: dir);
      final sub = await service.addNetwork(url: '${base()}/v1/index.js.md5', name: 'Old');

      await expectLater(
        service.updateSubscription(sub, url: '${base()}/missing/index.js.md5', name: 'Broken'),
        throwsA(anything),
      );
      expect((await repo.all()).single.indexJsUrl, '${base()}/v1/index.js.md5');
      expect((await installer.installedScript(sub))!.md5, md5Of(script));

      clock = clock.add(const Duration(minutes: 5));
      final updated = await service.updateSubscription(sub, url: ' ${base()}/v2/index.js.md5 ', name: 'NewName');
      expect(updated.name, 'NewName');
      expect(updated.indexJsUrl, '${base()}/v2/index.js.md5');
      expect(updated.installedMd5, md5Of(v2));
      expect(updated.updatedAt, clock.millisecondsSinceEpoch);
      expect((await repo.all()).single.indexJsUrl, '${base()}/v2/index.js.md5');

      // Saving again with the same URL does not collide with itself, while colliding with another subscription fails.
      final same = await service.updateSubscription(updated, url: '${base()}/v2/index.js.md5', name: 'RenamedAgain');
      expect(same.name, 'RenamedAgain');
      final other = await service.addNetwork(url: '${base()}/v1/index.js.md5', name: 'Other');
      await expectLater(
        service.updateSubscription(other, url: '${base()}/v2/index.js.md5'),
        throwsA(isA<DuplicateSubscriptionException>()),
      );
    });
  });

  test('discard removes an install so the next start downloads again', () async {
    put('/sub/index.js', script);
    final installer = SubscriptionInstaller(root: dir);
    await installer.install(sub('${base()}/sub/index.js.md5'));
    await installer.discard(sub('${base()}/sub/index.js.md5'));
    expect(await installer.installedScript(sub('${base()}/sub/index.js.md5')), isNull);
  });

  test('concurrent installWithKnownMd5 and refreshConfig use distinct temp files and keep installed.json valid',
      () async {
    const v1 = 'module.exports = { v: 1 };';
    const v2 = 'module.exports = { v: 2 };';
    const v3 = 'module.exports = { v: 3 };';
    const cfg1 = 'module.exports = { c: 1 };';
    const cfg2 = 'module.exports = { c: 2 };';
    const cfg3 = 'module.exports = { c: 3 };';

    final slowStageStarted = Completer<void>();
    final releaseSlowStage = Completer<void>();
    final raceServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => raceServer.close(force: true));
    raceServer.listen((req) async {
      switch (req.uri.path) {
        case '/v1/index.js':
          req.response.write(v1);
        case '/v1/index.config.js':
          req.response.write(cfg1);
        case '/slow/index.js':
          req.response.add(utf8.encode(v2));
          await req.response.flush();
          if (!slowStageStarted.isCompleted) slowStageStarted.complete();
          await releaseSlowStage.future;
        case '/slow/index.config.js':
          req.response.write(cfg2);
        case '/fast/index.js':
          req.response.write(v3);
        case '/fast/index.config.js':
          req.response.write(cfg3);
        default:
          req.response.statusCode = 404;
      }
      await req.response.close().catchError((_) {});
    });

    String raceUrl(String p) => 'http://127.0.0.1:${raceServer.port}$p';
    final installer = SubscriptionInstaller(root: dir);
    final initial = await installer.installWithKnownMd5(
      Subscription(key: 'race', name: 'Race', indexJsUrl: raceUrl('/v1/index.js')),
      expectedScriptMd5: md5Of(v1),
      expectedConfigMd5: md5Of(cfg1),
      skipConfigMd5Fetch: true,
    );
    expect(initial.md5, md5Of(v1));

    final subDir = Directory('${dir.path}/subscriptions/race');
    final slowToken = CancelToken();
    final slowFuture = installer.installWithKnownMd5(
      Subscription(key: 'race', name: 'Race', indexJsUrl: raceUrl('/slow/index.js')),
      expectedScriptMd5: md5Of(v2),
      expectedConfigMd5: md5Of(cfg2),
      skipConfigMd5Fetch: true,
      cancelToken: slowToken,
    );
    await slowStageStarted.future.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 30));

    // While slow install is mid-flight, config.js.<seq>.tmp uses a unique name and existing installed.json is intact.
    final midNames = subDir.listSync().map((e) => e.uri.pathSegments.last).toList();
    expect(midNames.any((n) => RegExp(r'^config\.js\.\d+\.tmp$').hasMatch(n)), isTrue);
    expect(midNames.contains('config.js.tmp'), isFalse);
    expect(midNames.contains('index.js.tmp'), isFalse);
    expect((await installer.installedScript(Subscription(key: 'race', name: 'Race', indexJsUrl: raceUrl('/v1/index.js'))))?.md5,
        md5Of(v1));

    // Concurrent fast install + refreshConfig finish cleanly while slow install is paused, then slow install cancels.
    final fastInstalled = await installer.installWithKnownMd5(
      Subscription(key: 'race', name: 'Race', indexJsUrl: raceUrl('/fast/index.js')),
      expectedScriptMd5: md5Of(v3),
      expectedConfigMd5: md5Of(cfg3),
      skipConfigMd5Fetch: true,
    );
    expect(fastInstalled.md5, md5Of(v3));

    slowToken.cancel('preempted');
    releaseSlowStage.complete();
    await expectLater(slowFuture, throwsA(isA<DioException>()));

    // Two concurrent succeeding installs + refreshConfig also never lose installed.json or leave .tmp files.
    await Future.wait([
      installer.installWithKnownMd5(
        Subscription(key: 'race', name: 'Race', indexJsUrl: raceUrl('/v1/index.js')),
        expectedScriptMd5: md5Of(v1),
        expectedConfigMd5: md5Of(cfg1),
        skipConfigMd5Fetch: true,
      ),
      installer.installWithKnownMd5(
        Subscription(key: 'race', name: 'Race', indexJsUrl: raceUrl('/fast/index.js')),
        expectedScriptMd5: md5Of(v3),
        expectedConfigMd5: md5Of(cfg3),
        skipConfigMd5Fetch: true,
      ),
      installer.refreshConfig(
        Subscription(key: 'race', name: 'Race', indexJsUrl: raceUrl('/fast/index.js')),
        knownConfigMd5: md5Of(cfg3),
        skipConfigMd5Fetch: true,
      ),
    ]);

    final finalInstalled =
        await installer.installedScript(Subscription(key: 'race', name: 'Race', indexJsUrl: raceUrl('/fast/index.js')));
    expect(finalInstalled, isNotNull);
    expect(finalInstalled!.md5, md5.convert(File(finalInstalled.scriptPath).readAsBytesSync()).toString());
    expect(subDir.listSync().where((e) => e.path.endsWith('.tmp')), isEmpty);
  });
}

class _NullMd5Installer extends SubscriptionInstaller {
  _NullMd5Installer(Directory root) : super(root: root);

  @override
  Future<String?> remoteMd5(Subscription sub) async => null;
}
