import 'package:dio/dio.dart';

import '../../models/vod.dart';

/// One video source exposed by a running catpaw instance.
class SpiderSite {
  const SpiderSite(
      {required this.key,
      required this.name,
      required this.api,
      this.type = 3,
      this.searchable = true,
      this.indexs = false});

  factory SpiderSite.fromJson(Map<String, dynamic> j) => SpiderSite(
        key: '${j['key']}',
        name: '${j['name'] ?? j['key']}',
        api: '${j['api']}',
        type: int.tryParse('${j['type']}') ?? 3,
        searchable: '${j['searchable'] ?? 1}' != '0',
        indexs: '${j['indexs'] ?? 0}' == '1',
      );

  final String key;
  final String name;
  final String api;
  final int type;
  final bool searchable;

  /// `indexs: 1`: an index site (OBSERVED: 「荐」豆瓣 of a catpaw subscription). Its posters are recommendations with no
  /// detail of their own; the original opens 搜索 with the title when one is tapped.
  final bool indexs;
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
  SpiderApi(
    int port, {
    Dio? dio,
    String? baseUrl,
    Duration receiveTimeout = const Duration(seconds: 15),
    this.onConnectionErrorRecover,
  })  : _port = port,
        _isLocal = baseUrl == null,
        _dio = dio ??
            Dio(BaseOptions(
              baseUrl: (baseUrl ?? 'http://127.0.0.1:$port').replaceAll(RegExp(r'/+$'), ''),
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: receiveTimeout,
            ));

  int _port;
  final bool _isLocal;
  final Dio _dio;

  /// Optional single-flight recovery callback for local CatPaw instances when the loopback socket/worker died while idle.
  final Future<int?> Function()? onConnectionErrorRecover;

  int get port => _port;

  /// Updates the local loopback port (e.g. after `reload` or worker restart stepped to a new free port).
  void updateLocalPort(int nextPort) {
    if (!_isLocal || nextPort <= 0) return;
    _port = nextPort;
    _dio.options.baseUrl = 'http://127.0.0.1:$nextPort';
  }

  /// Address of the spider server (`http://127.0.0.1:<port>` or the cloud service's address), without a trailing `/`.
  String get baseUrl => _dio.options.baseUrl;

  Duration? get receiveTimeout => _dio.options.receiveTimeout;

  /// Applies a new 服务超时 to the next requests without rebuilding the client.
  set receiveTimeout(Duration? value) => _dio.options.receiveTimeout = value;

  /// Lightweight health probe (`GET /config`) used when resuming from idle/background.
  Future<bool> probe({Duration timeout = const Duration(milliseconds: 2500)}) async {
    try {
      final res = await _dio.get<Object?>(
        '/config',
        options: Options(sendTimeout: timeout, receiveTimeout: timeout),
      );
      final code = res.statusCode ?? 0;
      return code >= 200 && code < 500;
    } catch (_) {
      return false;
    }
  }

  /// Probes local `/config` and runs [onConnectionErrorRecover] if dead before non-Dio callers (e.g. WebView) open [baseUrl].
  Future<void> ensureHealthy() async {
    final recover = onConnectionErrorRecover;
    if (recover == null || await probe()) return;
    final nextPort = await recover();
    if (nextPort != null) updateLocalPort(nextPort);
  }

  Future<Response<T>> _withRecovery<T>(Future<Response<T>> Function() request) async {
    try {
      return await request();
    } on DioException catch (e) {
      final recover = onConnectionErrorRecover;
      if (recover != null &&
          (e.type == DioExceptionType.connectionError || e.type == DioExceptionType.connectionTimeout)) {
        final nextPort = await recover();
        if (nextPort != null) {
          updateLocalPort(nextPort);
          return await request();
        }
      }
      rethrow;
    }
  }

  Future<List<SpiderSite>> sites() async {
    final res = await _withRecovery(() => _dio.get<Map<String, dynamic>>('/config'));
    final video = (res.data?['video'] as Map?)?.cast<String, dynamic>();
    return ((video?['sites'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => SpiderSite.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  Future<Map<String, dynamic>> _post(SpiderSite site, String op, [Map<String, Object?> body = const {}]) async {
    final res = await _withRecovery(() => _dio.post<Map<String, dynamic>>('${site.api}/$op', data: body));
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
