import 'package:dio/dio.dart';

/// TMDB metadata (posters, episode lists, calendar air dates).
///
/// OBSERVED: default hosts https://api.themoviedb.org and https://image.tmdb.org/t/p (both overridable by the
/// user "leave empty to use official"), routes `/3/configuration`, `/search/multi`, "/tmdb/search",
/// settings stored in tmdb_settings.json (switch, API key, proxy addresses), matches in tmdb_refs.json,
/// a custom wait time for matching on the detail page (1.1.12). The Dart package `tmdb_api` is linked in.
class TmdbSettings {
  const TmdbSettings({this.enabled = false, this.apiKey = '', this.apiBase = '', this.imageBase = '', this.language = 'zh-CN', this.matchWaitSeconds = 5});

  factory TmdbSettings.fromJson(Map<String, dynamic> j) => TmdbSettings(
        enabled: j['enabled'] as bool? ?? false,
        apiKey: j['apiKey'] as String? ?? '',
        apiBase: j['apiBase'] as String? ?? '',
        imageBase: j['imageBase'] as String? ?? '',
        language: j['language'] as String? ?? 'zh-CN',
        matchWaitSeconds: (j['matchWaitSeconds'] as num?)?.toInt() ?? 5,
      );

  final bool enabled;
  final String apiKey;
  final String apiBase;
  final String imageBase;
  final String language;

  /// How long the detail page waits for the automatic TMDB match before showing the page without it (changelog 1.1.12).
  final int matchWaitSeconds;

  String get effectiveApi => apiBase.isEmpty ? 'https://api.themoviedb.org' : apiBase.replaceAll(RegExp(r'/+$'), '');
  String get effectiveImage => imageBase.isEmpty ? 'https://image.tmdb.org/t/p' : imageBase.replaceAll(RegExp(r'/+$'), '');

  Map<String, dynamic> toJson() =>
      {'enabled': enabled, 'apiKey': apiKey, 'apiBase': apiBase, 'imageBase': imageBase, 'language': language, 'matchWaitSeconds': matchWaitSeconds};
}

class TmdbMatch {
  const TmdbMatch({required this.id, required this.mediaType, required this.title, this.posterPath, this.overview, this.releaseDate});

  factory TmdbMatch.fromJson(Map<String, dynamic> j) => TmdbMatch(
        id: j['id'] as int,
        mediaType: j['media_type'] as String? ?? 'movie',
        title: (j['title'] ?? j['name'] ?? '') as String,
        posterPath: j['poster_path'] as String?,
        overview: j['overview'] as String?,
        releaseDate: (j['release_date'] ?? j['first_air_date']) as String?,
      );

  final int id;
  final String mediaType; // movie | tv
  final String title;
  final String? posterPath;
  final String? overview;
  final String? releaseDate;
  Map<String, dynamic> toJson() => {
        'id': id,
        'media_type': mediaType,
        'title': title,
        'poster_path': posterPath,
        'overview': overview,
        'release_date': releaseDate,
      };
}

class TmdbEpisode {
  const TmdbEpisode({required this.number, required this.name, this.overview, this.stillPath, this.airDate, this.runtime});

  factory TmdbEpisode.fromJson(Map<String, dynamic> j) => TmdbEpisode(
        number: j['episode_number'] as int,
        name: (j['name'] ?? '') as String,
        overview: j['overview'] as String?,
        stillPath: j['still_path'] as String?,
        airDate: j['air_date'] == null ? null : DateTime.tryParse(j['air_date'] as String),
        runtime: j['runtime'] as int?,
      );

  final int number;
  final String name;
  final String? overview;
  final String? stillPath;
  final DateTime? airDate;
  final int? runtime;
}

class TmdbClient {
  TmdbClient(this.settings, {Dio? dio}) : _dio = dio ?? Dio();
  final TmdbSettings settings;
  final Dio _dio;

  Future<Map<String, dynamic>> _get(String path, [Map<String, Object?> query = const {}]) async {
    final key = settings.apiKey;
    // v4 read-access tokens are JWTs and go into the Authorization header, v3 keys into the query string.
    final isBearer = key.startsWith('eyJ');
    final res = await _dio.get<Map<String, dynamic>>(
      '${settings.effectiveApi}/3$path',
      queryParameters: {'language': settings.language, if (!isBearer && key.isNotEmpty) 'api_key': key, ...query},
      options: Options(headers: {if (isBearer) 'Authorization': 'Bearer $key'}),
    );
    return res.data ?? const {};
  }

  Future<bool> testConnection() async {
    try {
      await _get('/configuration');
      return true;
    } on DioException {
      return false;
    }
  }

  Future<List<TmdbMatch>> searchMulti(String query, {int page = 1}) async {
    final j = await _get('/search/multi', {'query': query, 'page': page});
    return ((j['results'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .where((e) => e['media_type'] == 'movie' || e['media_type'] == 'tv')
        .map(TmdbMatch.fromJson)
        .toList();
  }

  Future<Map<String, dynamic>> details(TmdbMatch m) => _get('/${m.mediaType}/${m.id}', {'append_to_response': 'credits'});

  Future<List<TmdbEpisode>> season(int tvId, int seasonNumber) async {
    final j = await _get('/tv/$tvId/season/$seasonNumber');
    return ((j['episodes'] as List?) ?? const []).whereType<Map>().map((e) => TmdbEpisode.fromJson(e.cast<String, dynamic>())).toList();
  }

  String imageUrl(String path, {String size = 'w500'}) => '${settings.effectiveImage}/$size$path';
}
