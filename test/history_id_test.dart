import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/core/json_store.dart';
import 'package:uzv_reimpl/features/catpaw/spider_api.dart';
import 'package:uzv_reimpl/features/library/watch_repository.dart';
import 'package:uzv_reimpl/features/player/playback_source.dart';
import 'package:uzv_reimpl/models/vod.dart';

// User report (2026-11-10, phone): opening a 「盘」玩偶 video from 观看历史 failed with `HTTP 500：Cannot read properties of
// undefined (reading 'children')`, while the same video opened from the home list. OBSERVED: the history held
// 愿你自由，我的女儿, then 小春，屁股摇起来！ replaced it, so the two videos were saved under one id. History (and
// favourites) were keyed on the `vod_id` of the detail answer, which this spider does not echo back; asking for the
// detail with that id makes its script throw. The id the detail was asked with is the one to keep.

const _site = SpiderSite(key: 'wanou', name: '「盘」玩偶', api: '/spider/wanou/3');

SpiderApi _apiAnswering(Map<String, dynamic> detail, List<Object?> asked) {
  final dio = Dio()
    ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
      asked.add(o.data);
      h.resolve(Response(requestOptions: o, data: {
        'list': [detail]
      }));
    }));
  return SpiderApi(0, dio: dio);
}

void main() {
  late Directory dir;
  late HistoryRepository history;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('uzv_history_id');
    history = HistoryRepository(store: JsonStore('history.json', baseDir: dir));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('a detail keeps the id it was asked with; the one the spider answered is kept apart', () async {
    final asked = <Object?>[];
    final api = _apiAnswering({'vod_id': '', 'vod_name': '小春，屁股摇起来！', 'vod_play_from': 'q', 'vod_play_url': '1\$a'}, asked);
    final d = (await api.detail(_site, '/movie/123.html'))!;
    expect(asked.single, {'id': '/movie/123.html'});
    expect(d.item.id, '/movie/123.html');
    expect(d.item.siteKey, 'wanou');
    expect(d.responseId, '');

    final same = (await _apiAnswering({'vod_id': '7', 'vod_name': 'x'}, []).detail(_site, '7'))!;
    expect(same.item.id, '7');
    expect(same.responseId, isNull, reason: 'only kept when it differs');
  });

  test('progress is saved under the asked id and replaces the unusable entry of the same video', () async {
    // what the earlier builds saved: the answer's (empty) id
    await history.record(const ProgressEntry(
      item: VodItem(id: '', name: '小春，屁股摇起来！', siteKey: 'wanou'),
      lineIndex: 0,
      episodeIndex: 0,
      episodeName: 'e',
      positionSeconds: 30,
      durationSeconds: 100,
      updatedAt: 0,
    ));
    final asked = <Object?>[];
    final detail = (await _apiAnswering(
            {'vod_id': '', 'vod_name': '小春，屁股摇起来！', 'vod_play_from': 'q', 'vod_play_url': '1\$a'}, asked)
        .detail(_site, '/movie/123.html'))!;
    final source = VodPlaybackSource(site: _site, api: SpiderApi(0), detail: detail, history: history);

    await source.saveProgress(0, 0, 40, 100);

    final all = await history.all();
    expect(all.map((e) => e.item.id), ['/movie/123.html']);
    expect((await history.find('wanou', '/movie/123.html'))!.positionSeconds, 40);
  });

  test('an entry of another video under the answered id is left alone', () async {
    await history.record(const ProgressEntry(
      item: VodItem(id: '', name: '愿你自由，我的女儿', siteKey: 'wanou'),
      lineIndex: 0,
      episodeIndex: 0,
      episodeName: 'e',
      positionSeconds: 30,
      durationSeconds: 100,
      updatedAt: 0,
    ));
    final detail = (await _apiAnswering(
            {'vod_id': '', 'vod_name': '小春，屁股摇起来！', 'vod_play_from': 'q', 'vod_play_url': '1\$a'}, [])
        .detail(_site, '/movie/123.html'))!;
    final source = VodPlaybackSource(site: _site, api: SpiderApi(0), detail: detail, history: history);

    await source.saveProgress(0, 0, 40, 100);

    expect((await history.all()).map((e) => e.item.name).toSet(), {'小春，屁股摇起来！', '愿你自由，我的女儿'});
  });

  // 切换站点 → 站点设置 → 历史记录 off (2026-11-13): the site's videos stay out of 观看历史.
  test('a site with 历史记录 switched off saves no progress', () async {
    final detail = (await _apiAnswering(
            {'vod_id': '1', 'vod_name': '小春，屁股摇起来！', 'vod_play_from': 'q', 'vod_play_url': '1\$a'}, [])
        .detail(_site, '1'))!;
    final source =
        VodPlaybackSource(site: _site, api: SpiderApi(0), detail: detail, history: history, recordHistory: false);

    await source.saveProgress(0, 0, 40, 100);

    expect(await history.all(), isEmpty);
  });
}
