import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/features/subscription/subscription.dart';

/// The layout the original documents (`https://user:pass@host/index.js.md5`): the URL users paste is the checksum
/// file, the script is next to it without `.md5`, and `index.config.js` (+ `.md5`) sits beside the script.
void main() {
  late HttpServer server;
  late Directory dir;
  late Map<String, List<int>> files;
  String? requiredAuth;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('uzv_sub');
    files = {};
    requiredAuth = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
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

    test('refresh reports up to date, then downloads a changed script', () async {
      put('/sub/index.js', script);
      final sub = await service.addNetwork(url: '${base()}/sub/index.js.md5');
      expect(await service.refresh(sub), isNull);
      const v2 = 'module.exports = { start() {}, v: 2 };';
      put('/sub/index.js', v2);
      clock = clock.add(const Duration(hours: 1));
      final updated = await service.refresh(sub);
      expect(updated!.installedMd5, md5Of(v2));
      expect(updated.updatedAt, clock.millisecondsSinceEpoch);
      expect((await repo.all()).single.installedMd5, md5Of(v2));
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
  });

  test('discard removes an install so the next start downloads again', () async {
    put('/sub/index.js', script);
    final installer = SubscriptionInstaller(root: dir);
    await installer.install(sub('${base()}/sub/index.js.md5'));
    await installer.discard(sub('${base()}/sub/index.js.md5'));
    expect(await installer.installedScript(sub('${base()}/sub/index.js.md5')), isNull);
  });
}
