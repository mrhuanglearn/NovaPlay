import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/features/player/native_player_api.g.dart';
import 'package:uzv_reimpl/features/player/player_launcher.dart';

void main() {
  late Directory dir;
  late JsonStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('pcfg');
    store = JsonStore('player_config.json', baseDir: dir);
  });
  tearDown(() => dir.delete(recursive: true));

  test('a config saved with the current schema round-trips, including audioLang', () async {
    final repo = PlayerConfigRepository(store: store);
    final p = defaultPlaybackConfig()
      ..audioLang = 'ja'
      ..subtitleLang = 'zh';
    await repo.save(p, defaultDanmakuConfig());
    final (loaded, _) = await repo.load();
    expect((loaded.audioLang, loaded.subtitleLang), ('ja', 'zh'));
  });

  test('a file written before audioLang existed still loads (positional lists are padded)', () async {
    final full = defaultPlaybackConfig().encode() as List<Object?>;
    final legacy = full.sublist(0, full.length - 1); // what the previous schema produced
    await store.write({'playback': legacy, 'danmaku': defaultDanmakuConfig().encode()});
    final (loaded, _) = await PlayerConfigRepository(store: store).load();
    expect(loaded.kernel, 'exo');
    expect(loaded.audioLang, isNull);
    expect(loaded.hwDecode, isTrue);
  });

  test('unreadable parts fall back to the defaults instead of throwing', () async {
    await store.write({'playback': ['garbage'], 'danmaku': 'nope'});
    final (p, d) = await PlayerConfigRepository(store: store).load();
    expect(p.kernel, defaultPlaybackConfig().kernel);
    expect(d.enabled, defaultDanmakuConfig().enabled);
  });

  test('a preference report from the player updates only the part it carries', () async {
    final repo = PlayerConfigRepository(store: store);
    await repo.save(defaultPlaybackConfig(), defaultDanmakuConfig());
    final changed = defaultPlaybackConfig()..audioLang = 'en';
    await repo.saveReport(PreferenceReport(sessionId: 's', playbackConfig: changed));
    final (p, d) = await repo.load();
    expect(p.audioLang, 'en');
    expect(d.fontSize, defaultDanmakuConfig().fontSize);
  });
}
