import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/app/providers.dart';
import 'package:uzv_reimpl/features/catpaw/spider_api.dart';
import 'package:uzv_reimpl/features/subscription/subscription.dart';

// User report (2026-11-10, phone): on 「设」配置 the first tap on a QR card opened the web page, but after going back a
// second tap on the same card stayed on an empty 视频详情 page (立即播放 / 选集). OBSERVED: the device log had one
// `openInternalWebview` callback, from the first tap only. The script asks for the web page while it answers the detail
// request, and UZV kept the first answer in memory, so the second tap sent no detail request and the script never called
// back. A detail page asks again each time it is opened.

const _set = SpiderSite(key: 'baseset', name: '「设」配置', api: '/spider/baseset/3');

void main() {
  test('a detail page that was closed asks the spider again when it is opened again', () async {
    var detailRequests = 0;
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        if (o.path.endsWith('/detail')) detailRequests++;
        h.resolve(Response(requestOptions: o, data: {
          'list': [
            {'vod_id': 'danmu', 'vod_name': ''}
          ]
        }));
      }));
    final container = ProviderContainer(overrides: [
      catpawRuntimeProvider.overrideWith((ref) async => SpiderRuntime(
          subscription: const Subscription(key: 'mock', name: 'catpaw'), api: SpiderApi(0, dio: dio), sites: const [_set])),
    ]);
    addTearDown(container.dispose);
    const q = (siteKey: 'baseset', vodId: 'danmu');

    Future<void> openAndClose() async {
      final page = container.listen(videoDetailProvider(q), (_, __) {});
      await container.read(videoDetailProvider(q).future);
      page.close();
      await Future<void>.delayed(Duration.zero); // let an unused provider go
    }

    await openAndClose();
    await openAndClose();
    expect(detailRequests, 2);
  });
}
