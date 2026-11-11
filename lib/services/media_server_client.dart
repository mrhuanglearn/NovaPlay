import 'package:dio/dio.dart';

/// Emby / Jellyfin client (changelog 1.1.6 added "Emby / Jellyfin / Plex module - completely untested", 1.1.8
/// reworked the detail page and fixed gateway-style servers).
///
/// OBSERVED request paths: /System/Info/Public, /Users/AuthenticateByName, /Users/{id}/Items, /Items/Latest,
/// /Items/Resume, /Shows/{id}/Seasons, /Shows/{id}/Episodes, /Items/{id}/PlaybackInfo, /Videos/{id}/...,
/// /Items/{id}/Images/Primary|Backdrop, /Sessions/Playing, /Sessions/Playing/Progress, /Sessions/Playing/Stopped,
/// /FavoriteItems/, routes /emby/accounts, /emby/search, /emby/detail, /emby/favorites.
/// INFERRED: query parameters and the auth header layout (standard Emby/Jellyfin API).
class MediaAccount {
  const MediaAccount({required this.id, required this.name, required this.baseUrl, this.userId, this.token, this.kind = 'emby'});

  factory MediaAccount.fromJson(Map<String, dynamic> j) => MediaAccount(
        id: j['id'] as String,
        name: j['name'] as String,
        baseUrl: j['baseUrl'] as String,
        userId: j['userId'] as String?,
        token: j['token'] as String?,
        kind: j['kind'] as String? ?? 'emby',
      );

  final String id;
  final String name;
  final String baseUrl; // e.g. http://192.168.1.10:8096
  final String? userId;
  final String? token;
  final String kind; // emby | jellyfin

  MediaAccount withLogin(String userId, String token) =>
      MediaAccount(id: id, name: name, baseUrl: baseUrl, userId: userId, token: token, kind: kind);

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'baseUrl': baseUrl, 'userId': userId, 'token': token, 'kind': kind};
}

class MediaItem {
  const MediaItem({
    required this.id,
    required this.name,
    required this.type,
    this.year,
    this.overview,
    this.runTimeTicks,
    this.positionTicks,
    this.seriesId,
    this.seasonNumber,
    this.episodeNumber,
    this.isFavorite = false,
  });

  factory MediaItem.fromJson(Map<String, dynamic> j) => MediaItem(
        id: j['Id'] as String,
        name: (j['Name'] ?? '') as String,
        type: (j['Type'] ?? '') as String,
        year: j['ProductionYear'] as int?,
        overview: j['Overview'] as String?,
        runTimeTicks: j['RunTimeTicks'] as int?,
        positionTicks: (j['UserData'] as Map?)?['PlaybackPositionTicks'] as int?,
        seriesId: j['SeriesId'] as String?,
        seasonNumber: j['ParentIndexNumber'] as int?,
        episodeNumber: j['IndexNumber'] as int?,
        isFavorite: (j['UserData'] as Map?)?['IsFavorite'] == true,
      );

  final String id;
  final String name;
  final String type;
  final int? year;
  final String? overview;
  final int? runTimeTicks;
  final int? positionTicks;
  final String? seriesId;
  final int? seasonNumber;
  final int? episodeNumber;
  final bool isFavorite;

  bool get isSeries => type == 'Series';

  /// "S1E2 Name" for episodes, the plain name otherwise.
  String get label {
    if (type != 'Episode' || episodeNumber == null) return name;
    return 'S${seasonNumber ?? 1}E$episodeNumber $name'.trim();
  }
}

class MediaServerClient {
  MediaServerClient(this.account, {Dio? dio, this.deviceId = 'uzv-reimpl'}) : _dio = dio ?? Dio();
  final MediaAccount account;
  final Dio _dio;
  final String deviceId;

  String get _base => account.baseUrl.replaceAll(RegExp(r'/+$'), '');

  Map<String, String> get _headers => {
        'X-Emby-Authorization':
            'MediaBrowser Client="NovaPlay", Device="Android", DeviceId="$deviceId", Version="1.0"'
            '${account.token == null ? '' : ', Token="${account.token}"'}',
        if (account.token != null) 'X-Emby-Token': account.token!,
      };

  Future<Map<String, dynamic>> publicInfo() async =>
      (await _dio.get<Map<String, dynamic>>('$_base/System/Info/Public')).data ?? const {};

  Future<MediaAccount> login(String username, String password) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '$_base/Users/AuthenticateByName',
      data: {'Username': username, 'Pw': password},
      options: Options(headers: _headers),
    );
    final user = (res.data?['User'] as Map?)?.cast<String, dynamic>();
    final token = res.data?['AccessToken'] as String?;
    if (user == null || token == null) throw StateError('login failed');
    return account.withLogin(user['Id'] as String, token);
  }

  Future<List<MediaItem>> _items(String path, Map<String, Object?> q) async {
    final res = await _dio.get<dynamic>('$_base$path', queryParameters: q, options: Options(headers: _headers));
    final data = res.data;
    final list = data is Map ? (data['Items'] as List? ?? const []) : (data as List? ?? const []);
    return list.whereType<Map>().map((e) => MediaItem.fromJson(e.cast<String, dynamic>())).toList();
  }

  Future<List<MediaItem>> latest() => _items('/Users/${account.userId}/Items/Latest', {'Limit': 30, 'Fields': 'Overview'});
  Future<List<MediaItem>> resume() => _items('/Users/${account.userId}/Items/Resume', {'Limit': 20, 'MediaTypes': 'Video'});
  Future<List<MediaItem>> search(String term) => _items('/Users/${account.userId}/Items', {
        'SearchTerm': term,
        'Recursive': true,
        'IncludeItemTypes': 'Movie,Series',
        'Fields': 'Overview',
        'Limit': 50,
      });
  Future<List<MediaItem>> seasons(String seriesId) => _items('/Shows/$seriesId/Seasons', {'UserId': account.userId});
  Future<List<MediaItem>> episodes(String seriesId, {String? seasonId}) =>
      _items('/Shows/$seriesId/Episodes', {'UserId': account.userId, if (seasonId != null) 'SeasonId': seasonId});

  String imageUrl(String itemId, {String type = 'Primary', int maxWidth = 400}) =>
      '$_base/Items/$itemId/Images/$type?maxWidth=$maxWidth${account.token == null ? '' : '&api_key=${account.token}'}';

  Future<MediaItem> item(String itemId) async {
    final res = await _dio.get<Map<String, dynamic>>('$_base/Users/${account.userId}/Items/$itemId', options: Options(headers: _headers));
    return MediaItem.fromJson(res.data ?? const {});
  }

  Future<List<MediaItem>> favorites() => _items('/Users/${account.userId}/Items', {
        'Filters': 'IsFavorite',
        'Recursive': true,
        'IncludeItemTypes': 'Movie,Series',
        'Fields': 'Overview',
      });

  Future<void> setFavorite(String itemId, bool favorite) {
    final path = '$_base/Users/${account.userId}/FavoriteItems/$itemId';
    return favorite
        ? _dio.post<dynamic>(path, options: Options(headers: _headers))
        : _dio.delete<dynamic>(path, options: Options(headers: _headers));
  }

  /// Direct-play URL (static stream) plus the header map the native player must send.
  Future<({String url, Map<String, String> headers})> playbackUrl(String itemId) async {
    await _dio.post<dynamic>('$_base/Items/$itemId/PlaybackInfo',
        queryParameters: {'UserId': account.userId}, data: const {}, options: Options(headers: _headers));
    return (
      url: '$_base/Videos/$itemId/stream?static=true&api_key=${account.token}',
      headers: {'X-Emby-Token': account.token ?? ''},
    );
  }

  Future<void> reportStarted(String itemId) => _session('/Sessions/Playing', itemId, 0);
  Future<void> reportProgress(String itemId, int positionTicks) => _session('/Sessions/Playing/Progress', itemId, positionTicks);
  Future<void> reportStopped(String itemId, int positionTicks) => _session('/Sessions/Playing/Stopped', itemId, positionTicks);

  Future<void> _session(String path, String itemId, int ticks) => _dio.post<dynamic>('$_base$path',
      data: {'ItemId': itemId, 'PositionTicks': ticks}, options: Options(headers: _headers));
}
