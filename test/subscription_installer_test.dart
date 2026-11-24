import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
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
}
