import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/ui/poster_image.dart';
import 'package:uzv_reimpl/ui/widgets.dart';

// User report (2026-11-13, Android phone): no 「荐」豆瓣 poster showed. OBSERVED: img*.doubanio.com answers 418 without a
// Referer and 403 to `User-Agent: Dart/3.x (dart:io), Mozilla/5.0 …` — what Flutter's NetworkImage sends, because it
// adds the given User-Agent next to dart:io's own. With the browser User-Agent alone it answers 200.
// (No testWidgets in this file: the widget-test binding replaces every HttpClient with one that answers 400.)

void main() {
  test('posters are fetched with the browser User-Agent alone (doubanio answers 403 to "Dart/…, Mozilla/…")', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    List<String>? agents;
    String? referer;
    server.listen((req) {
      agents = req.headers[HttpHeaders.userAgentHeader];
      referer = req.headers.value(HttpHeaders.refererHeader);
      req.response
        ..add([1, 2, 3])
        ..close();
    });
    final bytes = await PosterImage.fetchBytes('http://127.0.0.1:${server.port}/p.webp',
        {'Referer': 'https://movie.douban.com/', 'User-Agent': 'Mozilla/5.0 test'});
    expect(bytes, [1, 2, 3]);
    expect(agents, ['Mozilla/5.0 test']);
    expect(referer, 'https://movie.douban.com/');
  });

  test('douban posters get the Referer and a browser User-Agent', () {
    final r = parsePosterRequest('https://img3.doubanio.com/view/photo/s_ratio_poster/public/p2935488630.webp');
    expect(r.headers['Referer'], 'https://movie.douban.com/');
    expect(r.headers['User-Agent'], startsWith('Mozilla/5.0'));
  });
}
