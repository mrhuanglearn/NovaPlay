import 'package:dio/dio.dart';

import '../../models/vod.dart';

/// One video source exposed by a running catpaw instance.
class SpiderSite {
  const SpiderSite({required this.key, required this.name, required this.api, this.type = 3, this.searchable = true});

  factory SpiderSite.fromJson(Map<String, dynamic> j) => SpiderSite(
        key: '${j['key']}',
        name: '${j['name'] ?? j['key']}',
        api: '${j['api']}',
        type: int.tryParse('${j['type']}') ?? 3,
        searchable: '${j['searchable'] ?? 1}' != '0',
      );

  final String key;
  final String name;
  final String api;
  final int type;
  final bool searchable;
}

class HomeData {
  const HomeData({required this.categories, required this.featured});
  final List<VodCategory> categories;
  final List<VodItem> featured;
}

/// HTTP client for the spider server a catpaw script starts on `127.0.0.1:<port>`.
///
/// OBSERVED: the Dart pool contains `/config`, `/check`, `/website`, `home`-style tokens ("Fetch spider home"),
/// the MacCMS keys in models/vod.dart, and a localhost default of http://127.0.0.1:9321.
/// INFERRED (CatVod / CatPawOpen conventions, not read from the binary): the exact route layout
/// `GET /config` -> `{video:{sites:[{key,name,type,api}]}}` and `POST {api}/{init|home|category|detail|search|play}`
/// with the JSON bodies used below. Adjust [_post] paths if a given source differs.
class SpiderApi {
  /// [baseUrl] defaults to the local runtime; pass the subscription's address for a cloud catpaw service
  /// (`http://ip:9321` or `http://ip:9321/TOKEN`).
  /// [receiveTimeout] is 功能设置 → catpaw 服务超时 (OBSERVED default 15 s).
  SpiderApi(this.port, {Dio? dio, String? baseUrl, Duration receiveTimeout = const Duration(seconds: 15)})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: (baseUrl ?? 'http://127.0.0.1:$port').replaceAll(RegExp(r'/+$'), ''),
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: receiveTimeout,
            ));

  final int port;
  final Dio _dio;

  Duration? get receiveTimeout => _dio.options.receiveTimeout;

  /// Applies a new 服务超时 to the next requests without rebuilding the client.
  set receiveTimeout(Duration? value) => _dio.options.receiveTimeout = value;

  Future<List<SpiderSite>> sites() async {
    final res = await _dio.get<Map<String, dynamic>>('/config');
    final video = (res.data?['video'] as Map?)?.cast<String, dynamic>();
    return ((video?['sites'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => SpiderSite.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  Future<Map<String, dynamic>> _post(SpiderSite site, String op, [Map<String, Object?> body = const {}]) async {
    final res = await _dio.post<Map<String, dynamic>>('${site.api}/$op', data: body);
    return res.data ?? const {};
  }

  Future<void> init(SpiderSite site) => _post(site, 'init');

  /// OBSERVED request bodies of the original (2026-11-09, logged by a mock subscription): `home` is posted with
  /// `{"filter":true}`; `category` with `{"id","page","filter":<any filter chosen>,"filters":{key:value}}`, where a
  /// chosen value is sent even when it equals the filter's `init`, and 全部 (an empty value) removes the key.
  Future<HomeData> home(SpiderSite site) async {
    final j = await _post(site, 'home', {'filter': true});
    final filterMap = (j['filters'] as Map?)?.cast<String, dynamic>();
    return HomeData(
      categories: ((j['class'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => VodCategory.fromJson(e.cast<String, dynamic>(), filterMap: filterMap))
          .toList(),
      featured: ((j['list'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => VodItem.fromJson(e.cast<String, dynamic>(), siteKey: site.key))
          .toList(),
    );
  }

  Future<PagedVods> category(SpiderSite site, String typeId,
          {int page = 1, Map<String, String> filters = const {}}) async =>
      PagedVods.fromJson(
          await _post(site, 'category', {'id': typeId, 'page': page, 'filter': filters.isNotEmpty, 'filters': filters}),
          siteKey: site.key);

  Future<VodDetail?> detail(SpiderSite site, String vodId) async {
    final j = await _post(site, 'detail', {'id': vodId});
    final list = (j['list'] as List?) ?? const [];
    if (list.isEmpty) return null;
    return VodDetail.fromJson((list.first as Map).cast<String, dynamic>(), siteKey: site.key).withRequestedId(vodId);
  }

  Future<PagedVods> search(SpiderSite site, String keyword, {int page = 1}) async =>
      PagedVods.fromJson(await _post(site, 'search', {'wd': keyword, 'page': page}), siteKey: site.key);

  Future<PlayResult> play(SpiderSite site, String flag, String id) async =>
      PlayResult.fromJson(await _post(site, 'play', {'flag': flag, 'id': id}));
}
