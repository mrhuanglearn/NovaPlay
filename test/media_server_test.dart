import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uzv_reimpl/features/media_server/media_source.dart';
import 'package:uzv_reimpl/services/media_server_client.dart';

class RecordedRequest {
  RecordedRequest(this.method, this.uri, this.headers, this.body);
  final String method;
  final Uri uri;
  final Map<String, dynamic> headers;
  final String body;
}

/// Answers from a route table and remembers every request.
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.routes);
  final Map<String, Object?> routes; // "METHOD /path" -> json
  final requests = <RecordedRequest>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final body = requestStream == null ? '' : utf8.decode((await requestStream.toList()).expand((b) => b).toList());
    requests.add(RecordedRequest(options.method, options.uri, options.headers, body));
    final key = '${options.method} ${options.uri.path}';
    final json = routes[key];
    if (json == null && !routes.containsKey(key)) return ResponseBody.fromString('not found: $key', 404);
    return ResponseBody.fromString(jsonEncode(json), 200, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }

  @override
  void close({bool force = false}) {}
}

MediaServerClient clientWith(FakeAdapter adapter, {String? token}) {
  final dio = Dio()..httpClientAdapter = adapter;
  return MediaServerClient(
    MediaAccount(id: 'a1', name: 'Home', baseUrl: 'http://emby:8096/', userId: token == null ? null : 'u1', token: token),
    dio: dio,
  );
}

void main() {
  test('login posts credentials with the MediaBrowser header and keeps only user id and token', () async {
    final adapter = FakeAdapter({
      'POST /Users/AuthenticateByName': {
        'User': {'Id': 'u1'},
        'AccessToken': 'tok',
      },
    });
    final account = await clientWith(adapter).login('bob', 'pw');
    expect((account.userId, account.token), ('u1', 'tok'));
    final req = adapter.requests.single;
    expect(req.uri.toString(), 'http://emby:8096/Users/AuthenticateByName');
    expect(jsonDecode(req.body), {'Username': 'bob', 'Pw': 'pw'});
    expect(req.headers['X-Emby-Authorization'], allOf(contains('MediaBrowser'), contains('Client="NovaPlay"')));
    expect(jsonEncode(account.toJson()), isNot(contains('pw')));
  });

  test('items are parsed with season / episode numbers, resume position and favorite flag', () async {
    final adapter = FakeAdapter({
      'GET /Shows/s1/Episodes': {
        'Items': [
          {'Id': 'e2', 'Name': 'Two', 'Type': 'Episode', 'ParentIndexNumber': 1, 'IndexNumber': 2, 'UserData': {'PlaybackPositionTicks': 600000000, 'IsFavorite': true}},
          {'Id': 'e1', 'Name': 'One', 'Type': 'Episode', 'ParentIndexNumber': 1, 'IndexNumber': 1},
          {'Id': 'f1', 'Name': 'Finale', 'Type': 'Episode', 'ParentIndexNumber': 2, 'IndexNumber': 1},
        ],
      },
    });
    final eps = await clientWith(adapter, token: 'tok').episodes('s1');
    expect(eps.first.label, 'S1E2 Two');
    expect(eps.first.positionTicks, 600000000);
    expect(eps.first.isFavorite, isTrue);
    final bySeason = groupBySeason(eps);
    expect(bySeason.keys, [1, 2]);
    expect(bySeason[1]!.map((e) => e.id), ['e1', 'e2']);
    expect(adapter.requests.single.headers['X-Emby-Token'], 'tok');
  });

  test('favorite toggling uses POST to add and DELETE to remove', () async {
    final adapter = FakeAdapter({
      'POST /Users/u1/FavoriteItems/i1': {},
      'DELETE /Users/u1/FavoriteItems/i1': {},
    });
    final c = clientWith(adapter, token: 'tok');
    await c.setFavorite('i1', true);
    await c.setFavorite('i1', false);
    expect(adapter.requests.map((r) => r.method), ['POST', 'DELETE']);
  });

  test('playback source resolves a direct stream URL and reports progress in ticks', () async {
    final adapter = FakeAdapter({
      'POST /Items/m1/PlaybackInfo': {},
      'POST /Sessions/Playing/Progress': {},
      'POST /Sessions/Playing/Stopped': {},
    });
    final client = clientWith(adapter, token: 'tok');
    final source = MediaServerPlaybackSource(
      client: client,
      title: 'Movie',
      items: const [MediaItem(id: 'm1', name: 'Movie', type: 'Movie', positionTicks: 300000000)],
      memoryId: 'm1',
    );
    expect(source.isMovie, isTrue);
    expect(source.memoryKey, 'emby|a1|m1');
    expect(await source.resumeSeconds(0, 0), 30);
    final r = await source.resolve(0, 0);
    expect(r.url, 'http://emby:8096/Videos/m1/stream?static=true&api_key=tok');
    await source.saveProgress(0, 0, 12.5, 100);
    await source.finish(0, 0, 13);
    final progress = adapter.requests.firstWhere((r) => r.uri.path == '/Sessions/Playing/Progress');
    expect(jsonDecode(progress.body), {'ItemId': 'm1', 'PositionTicks': 125000000});
    expect(adapter.requests.last.uri.path, '/Sessions/Playing/Stopped');
  });

  test('a failing progress report does not throw into the player', () async {
    final source = MediaServerPlaybackSource(
      client: clientWith(FakeAdapter({}), token: 'tok'),
      title: 't',
      items: const [MediaItem(id: 'x', name: 'x', type: 'Movie')],
    );
    await source.saveProgress(0, 0, 1, 2);
    await source.finish(0, 0, 1);
  });
}
