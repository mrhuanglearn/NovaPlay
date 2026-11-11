import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/json_store.dart';
import '../../models/vod.dart';
import '../catpaw/spider_api.dart';

/// How the search page lays out its results. OBSERVED (UZN 1.1.7 on the phone, 2026-11-10, 切换布局 menu): 列表 (every
/// result in one list), 顶部站点分类 (a tab per site above the results) and 左侧站点分类 (a site column on the left).
enum SearchLayout {
  list('list'),
  top('top'),
  left('left');

  const SearchLayout(this.id);
  final String id;

  static SearchLayout parse(Object? v) =>
      SearchLayout.values.firstWhere((l) => l.id == v, orElse: () => SearchLayout.left);
}

/// What the search page keeps in settings.json:
/// `searchLayout` (a [SearchLayout] id), `searchSitesGrid` (双列视图 of the site sheet) and
/// `searchSitesOff: {subscriptionKey: [siteKey, ...]}` (sites switched off in 站点搜索管理).
///
/// INFERRED: the default layout. The original on the phone was on 左侧站点分类; its default was not seen.
class SearchPrefs {
  const SearchPrefs({this.layout = SearchLayout.left, this.sitesGrid = false, this.sitesOff = const {}});

  factory SearchPrefs.fromSettings(Map<String, dynamic> s, String? subscription) {
    final off = s['searchSitesOff'];
    final list = off is Map && subscription != null ? off[subscription] : null;
    return SearchPrefs(
      layout: SearchLayout.parse(s['searchLayout']),
      sitesGrid: s['searchSitesGrid'] == true,
      sitesOff: {if (list is List) for (final k in list) '$k'},
    );
  }

  final SearchLayout layout;
  final bool sitesGrid;
  final Set<String> sitesOff;

  /// [settings] with these prefs written into it (other subscriptions' switches are kept).
  Map<String, dynamic> writeTo(Map<String, dynamic> settings, String? subscription) {
    final out = Map<String, dynamic>.of(settings);
    out['searchLayout'] = layout.id;
    out['searchSitesGrid'] = sitesGrid;
    if (subscription != null) {
      final off = out['searchSitesOff'];
      out['searchSitesOff'] = {if (off is Map) ...off, subscription: sitesOff.toList()};
    }
    return out;
  }

  SearchPrefs copyWith({SearchLayout? layout, bool? sitesGrid, Set<String>? sitesOff}) => SearchPrefs(
      layout: layout ?? this.layout, sitesGrid: sitesGrid ?? this.sitesGrid, sitesOff: sitesOff ?? this.sitesOff);
}

/// 搜索历史: newest first, each keyword once. OBSERVED: chips under 搜索历史, a clear button that asks
/// "确定清空全部搜索历史吗？". INFERRED: at most [limit] keywords are kept (the original's limit was not seen).
class SearchHistoryRepository {
  SearchHistoryRepository({JsonStore? store}) : _store = store ?? JsonStore('search_history.json');
  final JsonStore _store;
  static const limit = 20;

  Future<List<String>> all() async {
    final raw = await _store.read<List<dynamic>>(const []);
    return [for (final k in raw) if (k is String && k.trim().isNotEmpty) k];
  }

  Future<List<String>> add(String keyword) async {
    final k = keyword.trim();
    final list = await all();
    if (k.isEmpty) return list;
    final next = [k, ...list.where((e) => e != k)].take(limit).toList();
    await _store.write(next);
    return next;
  }

  Future<void> clear() => _store.write(const <String>[]);
}

/// The results of one site.
class SiteResults {
  const SiteResults(this.site, this.items);
  final SpiderSite site;
  final List<VodItem> items;
}

/// One search over several sites, run in parallel; each site's results are added when that site answers.
///
/// OBSERVED (UZN 1.1.7): the sites appear in the order they answer (two runs of the same keyword gave different
/// orders), and only sites with results are listed, each with its count. INFERRED: a site that fails is left out like
/// one without results; when every site fails, the first error is kept for the page to show.
class SearchRun extends ChangeNotifier {
  /// [api] may be null only when there are no [sites] (no subscription running).
  SearchRun({required this.keyword, required List<SpiderSite> sites, required SpiderApi? api})
      : _total = api == null ? 0 : sites.length {
    if (api == null || sites.isEmpty) {
      _done = true;
      return;
    }
    for (final s in sites) {
      unawaited(_searchOne(api, s));
    }
  }

  final String keyword;
  final int _total;
  final List<SiteResults> _results = [];
  int _answered = 0;
  bool _done = false;
  bool _disposed = false;
  Object? _firstError;
  int _failures = 0;

  List<SiteResults> get results => List.unmodifiable(_results);

  /// Every result in arrival order (the 列表 layout).
  List<VodItem> get allItems => [for (final r in _results) ...r.items];
  bool get done => _done;
  int get total => _total;
  int get answered => _answered;

  /// Set when every site failed: the error of the first one.
  Object? get error => _done && _results.isEmpty && _failures == _total ? _firstError : null;

  Future<void> _searchOne(SpiderApi api, SpiderSite site) async {
    try {
      final page = await api.search(site, keyword);
      if (_disposed) return;
      if (page.items.isNotEmpty) _results.add(SiteResults(site, page.items));
    } catch (e) {
      if (_disposed) return;
      _failures++;
      _firstError ??= e;
    }
    _answered++;
    if (_answered == _total) _done = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
