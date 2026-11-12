import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uzv_reimpl/app/providers.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/features/catpaw/dart_callback_server.dart';
import 'package:uzv_reimpl/features/subscription/subscription.dart';

Future<Map<String, dynamic>> _postMsg(int port, Map<String, Object?> payload) async {
  final client = HttpClient();
  try {
    final req = await client.post('127.0.0.1', port, '/msg');
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode(payload)));
    final res = await req.close();
    final text = await utf8.decoder.bind(res).join();
    return (jsonDecode(text) as Map).cast<String, dynamic>();
  } finally {
    client.close(force: true);
  }
}

ProviderContainer _makeContainer(Directory dir) {
  return ProviderContainer(overrides: [
    settingsStoreProvider.overrideWithValue(JsonStore('settings.json', baseDir: dir)),
    subscriptionRepositoryProvider
        .overrideWithValue(SubscriptionRepository(store: JsonStore('subscriptions.json', baseDir: dir))),
    subscriptionProfilesStoreProvider.overrideWithValue(JsonStore('subscription_profiles.json', baseDir: dir)),
  ]);
}

void main() {
  test('saveProfile via POST /msg {action, opt} persists and queryProfile restores it after cold restart', () async {
    final tempDir = await Directory.systemTemp.createTemp('uzv-profile-test-');
    addTearDown(() => tempDir.delete(recursive: true));

    // Launch #1: user has one active subscription, sets cookies & account in /website -> CatPaw posts saveProfile.
    final c1 = _makeContainer(tempDir);
    await c1
        .read(subscriptionRepositoryProvider)
        .save([const Subscription(key: 'sub_alpha', name: 'Main', indexJsUrl: 'https://example.com/index.js')]);
    final srv1 = c1.read(dartCallbackServerProvider);
    final port1 = await srv1.start();

    final saveReply = await _postMsg(port1, {
      'action': 'saveProfile',
      'opt': {
        'quark': '__puus=cookie_value_123',
        'uc': 'uc_cookie_456',
        'pan123': {'username': 'user@example.com', 'password': 'pw'},
      },
    });
    expect(saveReply['ok'], isTrue);
    await srv1.stop();
    c1.dispose();

    // Verify file actually landed on disk in subscription_profiles.json (not {"null": null}).
    final onDisk = await JsonStore('subscription_profiles.json', baseDir: tempDir).read<Map<String, dynamic>>({});
    expect(onDisk.containsKey('null'), isFalse);
    expect(onDisk['sub_alpha'], isA<Map>());

    // Launch #2 (full app exit + cold restart): CatPaw calls POST /msg {"action":"queryProfile"} with NO name!
    final c2 = _makeContainer(tempDir);
    addTearDown(c2.dispose);
    final srv2 = c2.read(dartCallbackServerProvider);
    final port2 = await srv2.start();

    final queryReply = await _postMsg(port2, {'action': 'queryProfile'});
    expect(queryReply['ok'], isTrue);
    expect(queryReply['data'], {
      'quark': '__puus=cookie_value_123',
      'uc': 'uc_cookie_456',
      'pan123': {'username': 'user@example.com', 'password': 'pw'},
    });
  });

  test('sequential partial saveProfile updates merge keys per subscription and stay isolated across subscriptions',
      () async {
    final tempDir = await Directory.systemTemp.createTemp('uzv-profile-merge-');
    addTearDown(() => tempDir.delete(recursive: true));

    final c = _makeContainer(tempDir);
    addTearDown(c.dispose);
    await c.read(subscriptionRepositoryProvider).save([
      const Subscription(key: 'sub_1', name: 'One', indexJsUrl: 'https://a.example/index.js'),
      const Subscription(key: 'sub_2', name: 'Two', indexJsUrl: 'https://b.example/index.js'),
    ]);
    await c.read(activeSubscriptionKeyProvider.notifier).select('sub_1');
    final srv = c.read(dartCallbackServerProvider);
    final port = await srv.start();

    await _postMsg(port, {
      'action': 'saveProfile',
      'opt': {'quark': 'ck_q'},
    });
    await _postMsg(port, {
      'action': 'saveProfile',
      'opt': {'ali': 'tk_a'},
    });

    // Switch active subscription to sub_2 and save different profile.
    await c.read(activeSubscriptionKeyProvider.notifier).select('sub_2');
    await _postMsg(port, {
      'action': 'saveProfile',
      'opt': {'quark': 'other_q'},
    });

    final sub2Reply = await _postMsg(port, {'action': 'queryProfile'});
    expect(sub2Reply['data'], {'quark': 'other_q'});

    await c.read(activeSubscriptionKeyProvider.notifier).select('sub_1');
    final sub1Reply = await _postMsg(port, {'action': 'queryProfile'});
    expect(sub1Reply['data'], {'quark': 'ck_q', 'ali': 'tk_a'});
  });

  test('saveProfile with non-Map opt (JSON string) round-trips intact via resolveCall and queryProfile', () async {
    final tempDir = await Directory.systemTemp.createTemp('uzv-profile-str-');
    addTearDown(() => tempDir.delete(recursive: true));

    final c = _makeContainer(tempDir);
    addTearDown(c.dispose);
    await c
        .read(subscriptionRepositoryProvider)
        .save([const Subscription(key: 'sub_s', name: 'StrSub', indexJsUrl: 'https://s.example/index.js')]);
    final port = await c.read(dartCallbackServerProvider).start();

    const rawEncoded = '{"bili":"SESSDATA=xyz"}';
    final r1 = resolveCall(Uri.parse('http://127.0.0.1/msg'), {'action': 'saveProfile', 'opt': rawEncoded});
    expect(r1.action, 'saveProfile');
    expect(r1.args, {'value': rawEncoded});

    await _postMsg(port, {'action': 'saveProfile', 'opt': rawEncoded});
    final res = await _postMsg(port, {'action': 'queryProfile'});
    expect(res['data'], rawEncoded);
  });

  test('named profile slots {name, profile} round-trip cleanly', () async {
    final tempDir = await Directory.systemTemp.createTemp('uzv-profile-named-');
    addTearDown(() => tempDir.delete(recursive: true));

    final c = _makeContainer(tempDir);
    addTearDown(c.dispose);
    await c
        .read(subscriptionRepositoryProvider)
        .save([const Subscription(key: 'sub_n', name: 'NamedSub', indexJsUrl: 'https://n.example/index.js')]);
    final port = await c.read(dartCallbackServerProvider).start();

    await _postMsg(port, {
      'action': 'saveProfile',
      'opt': {
        'name': 'quarkSlot',
        'profile': {'cookie': 'slot_ck'},
      },
    });
    final res = await _postMsg(port, {
      'action': 'queryProfile',
      'opt': {'name': 'quarkSlot'},
    });
    expect(res['data'], {'cookie': 'slot_ck'});
  });

  test('SubscriptionInstaller.invalidateScript removes script markers while preserving Temp/_redirect user data',
      () async {
    final tempDir = await Directory.systemTemp.createTemp('uzv-installer-keep-temp-');
    addTearDown(() => tempDir.delete(recursive: true));

    const sub = Subscription(key: 'sub_keep', name: 'Keep', indexJsUrl: 'https://k.example/index.js');
    final subDir = Directory(p.join(tempDir.path, 'subscriptions', sub.key));
    final redirectFile = File(p.join(subDir.path, 'Temp', '_redirect', '_ios_container', 'db.json'));
    await redirectFile.parent.create(recursive: true);
    await File(p.join(subDir.path, 'index.js')).writeAsString('exports.start = () => {};');
    await File(p.join(subDir.path, 'config.js')).writeAsString('module.exports = {};');
    await File(p.join(subDir.path, 'installed.json')).writeAsString('{"format":1,"md5":"0123456789abcdef0123456789abcdef"}');
    await redirectFile.writeAsString('{"quark":"keep_me"}');

    final installer = SubscriptionInstaller(root: tempDir);
    expect(await installer.installedScript(sub), isNotNull);

    await installer.invalidateScript(sub);

    expect(await installer.installedScript(sub), isNull);
    expect(await redirectFile.exists(), isTrue);
    expect(await redirectFile.readAsString(), '{"quark":"keep_me"}');
  });

  test('SnifferService.webViewSettings enables sharedCookiesEnabled and persistent storage for iOS WKWebView', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final settings = c.read(snifferServiceProvider).webViewSettings;
    expect(settings.sharedCookiesEnabled, isTrue);
    expect(settings.domStorageEnabled, isTrue);
    expect(settings.databaseEnabled, isTrue);
    expect(settings.thirdPartyCookiesEnabled, isTrue);
  });
}
