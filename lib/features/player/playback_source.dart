import 'dart:async';
import 'dart:collection';

import '../../models/vod.dart';
import '../catpaw/spider_api.dart';
import '../library/watch_repository.dart';
import 'native_player_api.g.dart' show EpgProgramme;
import 'video_format_probe.dart';

/// Where a playback session gets its lines, its URLs and its progress bookkeeping from.
///
/// The native player only speaks the Pigeon protocol (lines / episodes in, "give me the URL of line x episode y"
/// out). Spider videos, live channels, Emby items, sniffed pages and downloaded files all feed it the same way, so
/// they only differ in how an (line, episode) pair becomes a [PlayResult] and where progress is written.
abstract class PlaybackSource {
  String get title;
  String? get cover => null;
  List<PlayLine> get lines;

  bool get isMovie => lines.isNotEmpty && lines.first.episodes.length == 1;

  /// Key under which the user's danmaku match is remembered (danmu_refs.json). Null = do not remember.
  String? get memoryKey => null;

  /// Programme guide shown for live channels (initial channel only).
  List<EpgProgramme>? get epg => null;

  Future<PlayResult> resolve(int lineIndex, int episodeIndex);

  Future<double> resumeSeconds(int lineIndex, int episodeIndex, {double outroSeconds = 0}) async => 0;

  /// The source quality to start with (index into the play result's qualities).
  Future<int> resumeQuality() async => 0;

  /// Known display dimensions of this specific video/item before stream resolution finishes (null when unknown).
  Future<VideoDimensions?> fallbackDimensions(int lineIndex, int episodeIndex) async =>
      VideoFormatProbe.shared.cachedVod(memoryKey);

  /// Records actual probed or decoded display dimensions of this video/item for instant adaptive launch next time.
  void onVideoDimensionsKnown(int width, int height) {
    if (width > 0 && height > 0) {
      VideoFormatProbe.shared.rememberVod(memoryKey, (width: width, height: height));
    }
  }

  /// Drops any prewarmed URL for `(lineIndex, episodeIndex)` so a subsequent retry fetches a fresh token/URL.
  void invalidateEpisodeCache(int lineIndex, int episodeIndex) {}

  /// [quality] is the source quality being played (index into the play result's qualities).
  Future<void> saveProgress(int lineIndex, int episodeIndex, double position, double duration,
      {int quality = 0, bool flush = true}) async {}

  /// The player page closed at [position] seconds (after the last [saveProgress]).
  Future<void> finish(int lineIndex, int episodeIndex, double position) async {}
}

/// Short-lived pre-resolve + format-warmup cache populated while [DetailScreen] is visible for read-only (non-cloud-drive)
/// spider episodes so clicking「立即播放」already has both the stream URL and its `(width, height)` in memory.
class VodEpisodePrewarmCache {
  VodEpisodePrewarmCache({this.ttl = const Duration(seconds: 90), this.maxEntries = 32});

  static final VodEpisodePrewarmCache shared = VodEpisodePrewarmCache();

  static final RegExp _panSiteTagPattern = RegExp(r'[「\[【(（]\s*盘\s*[」\]】)）]');
  static final RegExp _directOrCmsSiteTagPattern = RegExp(r'[「\[【(（]\s*(?:直|采)\s*[」\]】)）]');

  static final RegExp _cloudDriveCorePattern = RegExp(
    r'(?:quark|夸克|(?<![a-z])uc(?![a-z])|alipan|aliyundrive|阿里|baidu|百度|123pan|123云盘|123网盘|123684|123865|123912|'
    r'(?<!\d)115(?!\d)|tianyi|天翼|189\.cn|yidong|移动|caiyun|139\.com|xunlei|迅雷|pikpak|guangya|光鸭|网盘|云盘|'
    r'pansou|cloudseek|全盘搜|(?<![a-z])pan(?![a-z]))',
    caseSensitive: false,
  );

  static final RegExp _panSiteNicknamesPattern = RegExp(
    r'(?:wogg|玩偶|ouge|讴歌|欧歌|tudou|土豆|ergou|二狗|erxiao|二小|xiaoban|小斑|mogg|木偶|mihdr|至臻|zhizhen|4kzn|'
    r'蜡笔|labi|闪电|shandian|虎斑|huban|下饭|xiafan|多多|duoduo|huajuan|花卷|woniu|蜗牛)',
    caseSensitive: false,
  );

  final Duration ttl;
  final int maxEntries;
  final Map<String, Future<PlayResult>> _inflight = {};
  final LinkedHashMap<String, ({PlayResult result, DateTime expiresAt})> _ready = LinkedHashMap();

  static String _key(SpiderApi api, SpiderSite site, String lineName, String episodeUrl) =>
      '${identityHashCode(api)}\x00${site.key}\x00$lineName\x00$episodeUrl';

  /// True for read-only VOD / short-drama / CMS spiders; false for cloud-drive shares (whose `play` mutates drive quota)
  /// and internal webpage entries.
  static bool canWarmupSpiderEpisode({
    required SpiderSite site,
    required String lineName,
    required String episodeUrl,
  }) {
    final ep = episodeUrl.trim();
    if (ep.isEmpty || site.type == 7 || site.indexs) return false;
    if (lineName == '配置入口' || lineName == '内置网页') return false;
    if (ep == 'openInternalWebsite' || ep.startsWith('webpage:') || ep.startsWith('uzv-web:') || ep.startsWith('push://')) {
      return false;
    }
    if (_panSiteTagPattern.hasMatch(site.name)) return false;
    final coreTarget = '${site.key} ${site.api} $lineName $ep';
    if (_cloudDriveCorePattern.hasMatch(coreTarget)) return false;
    if (_directOrCmsSiteTagPattern.hasMatch(site.name)) return true;
    final fullTarget = '${site.key} ${site.name} ${site.api} $lineName';
    return !_cloudDriveCorePattern.hasMatch(site.name) && !_panSiteNicknamesPattern.hasMatch(fullTarget);
  }

  void warmUp({
    required SpiderSite site,
    required SpiderApi api,
    required String lineName,
    required String episodeUrl,
    String? memoryKey,
    int preferredQualityIndex = 0,
    VideoFormatProbe? probe,
  }) {
    if (!canWarmupSpiderEpisode(site: site, lineName: lineName, episodeUrl: episodeUrl)) return;
    final fmtProbe = probe ?? VideoFormatProbe.shared;
    final key = _key(api, site, lineName, episodeUrl);
    final now = DateTime.now();
    PlayResult selectTarget(PlayResult raw) {
      if (raw.qualities.isEmpty) return raw;
      return raw.withQuality(preferredQualityIndex.clamp(0, raw.qualities.length - 1));
    }

    final existingReady = _ready[key];
    if (existingReady != null && existingReady.expiresAt.isAfter(now)) {
      _ready.remove(key);
      _ready[key] = existingReady;
      final res = selectTarget(existingReady.result);
      if (!res.needsParse && fmtProbe.cached(res.url) == null && fmtProbe.cachedVod(memoryKey) == null) {
        unawaited(fmtProbe
            .probe(res.url, headers: res.effectiveHeaders, timeout: const Duration(milliseconds: 1800))
            .then((dims) {
          if (dims != null) fmtProbe.rememberVod(memoryKey, dims);
        }));
      }
      return;
    }
    if (existingReady != null) _ready.remove(key);
    if (_inflight.containsKey(key)) return;

    final fut = Future<PlayResult>.sync(() => api.play(site, lineName, episodeUrl));
    _inflight[key] = fut;
    unawaited(fut.then(
      (rawRes) async {
        if (identical(_inflight[key], fut)) _inflight.remove(key);
        if (rawRes.url.trim().isEmpty) return;
        _ready.remove(key);
        _ready[key] = (result: rawRes, expiresAt: DateTime.now().add(ttl));
        while (_ready.length > maxEntries) {
          _ready.remove(_ready.keys.first);
        }
        final res = selectTarget(rawRes);
        if (res.needsParse || res.url.trim().isEmpty) return; // never open invisible WebView before explicit user tap
        if (res.videoWidth != null && res.videoHeight != null && res.videoWidth! > 0 && res.videoHeight! > 0) {
          final dims = (width: res.videoWidth!, height: res.videoHeight!);
          fmtProbe.remember(res.url, dims);
          fmtProbe.rememberVod(memoryKey, dims);
          return;
        }
        final dims = await fmtProbe.probe(
          res.url,
          headers: res.effectiveHeaders,
          timeout: const Duration(milliseconds: 1800),
        );
        if (dims != null) fmtProbe.rememberVod(memoryKey, dims);
      },
      onError: (Object _) {
        if (identical(_inflight[key], fut)) _inflight.remove(key);
      },
    ));
  }

  void invalidate({
    required SpiderSite site,
    required SpiderApi api,
    required String lineName,
    required String episodeUrl,
  }) {
    final key = _key(api, site, lineName, episodeUrl);
    _ready.remove(key);
    _inflight.remove(key);
  }

  Future<PlayResult> takeOrResolve({
    required SpiderSite site,
    required SpiderApi api,
    required String lineName,
    required String episodeUrl,
  }) {
    final key = _key(api, site, lineName, episodeUrl);
    final ready = _ready[key];
    if (ready != null) {
      if (ready.expiresAt.isAfter(DateTime.now())) {
        _ready.remove(key);
        _ready[key] = ready;
        return Future<PlayResult>.value(ready.result);
      }
      _ready.remove(key);
    }
    final inflight = _inflight[key];
    if (inflight != null) return inflight;
    return api.play(site, lineName, episodeUrl);
  }
}

/// A video from a catpaw site: URLs come from the site's `play` route, progress goes to the watch history.
class VodPlaybackSource extends PlaybackSource {
  VodPlaybackSource(
      {required this.site, required this.api, required this.detail, required this.history, this.recordHistory = true});

  final SpiderSite site;
  final SpiderApi api;
  final VodDetail detail;
  final HistoryRepository history;

  /// 切换站点 → 站点设置 → 历史记录 of [site]: off keeps its videos out of 观看历史.
  final bool recordHistory;

  @override
  String get title => detail.item.name;

  @override
  String? get cover => detail.item.pic;

  @override
  List<PlayLine> get lines => detail.lines;

  @override
  String get memoryKey => vodKey(site.key, detail.item.id);

  VideoDimensions? _knownVideoSize;

  @override
  Future<PlayResult> resolve(int lineIndex, int episodeIndex) {
    final line = detail.lines[lineIndex];
    return VodEpisodePrewarmCache.shared.takeOrResolve(
      site: site,
      api: api,
      lineName: line.name,
      episodeUrl: line.episodes[episodeIndex].url,
    );
  }

  @override
  void invalidateEpisodeCache(int lineIndex, int episodeIndex) {
    if (lineIndex < 0 || lineIndex >= detail.lines.length) return;
    final line = detail.lines[lineIndex];
    if (episodeIndex < 0 || episodeIndex >= line.episodes.length) return;
    VodEpisodePrewarmCache.shared.invalidate(
      site: site,
      api: api,
      lineName: line.name,
      episodeUrl: line.episodes[episodeIndex].url,
    );
  }

  @override
  Future<VideoDimensions?> fallbackDimensions(int lineIndex, int episodeIndex) async {
    final mem = VideoFormatProbe.shared.cachedVod(memoryKey);
    if (mem != null) return mem;
    final e = await history.find(site.key, detail.item.id);
    if (e?.videoWidth != null && e?.videoHeight != null && e!.videoWidth! > 0 && e.videoHeight! > 0) {
      final dims = (width: e.videoWidth!, height: e.videoHeight!);
      VideoFormatProbe.shared.rememberVod(memoryKey, dims);
      return dims;
    }
    return null;
  }

  @override
  void onVideoDimensionsKnown(int width, int height) {
    super.onVideoDimensionsKnown(width, height);
    if (width > 0 && height > 0) {
      _knownVideoSize = (width: width, height: height);
    }
  }

  /// An episode left within its last 5 seconds counts as watched and starts again from 0 (INFERRED: starting at the
  /// saved end made the player report 'ended' at once and close).
  @override
  Future<double> resumeSeconds(int lineIndex, int episodeIndex, {double outroSeconds = 0}) async {
    final e = await history.find(site.key, detail.item.id);
    if (e == null || e.lineIndex != lineIndex || e.episodeIndex != episodeIndex) return 0;
    if (e.durationSeconds > 0 && e.durationSeconds - e.positionSeconds < 5) return 0;
    if (outroSeconds > 0 &&
        e.durationSeconds >= 180 &&
        outroSeconds <= e.durationSeconds / 3 &&
        e.durationSeconds - e.positionSeconds <= outroSeconds + 5) {
      return 0;
    }
    return e.positionSeconds;
  }

  /// The quality is remembered per video, not per episode: the player keeps it across episodes as well.
  @override
  Future<int> resumeQuality() async => (await history.find(site.key, detail.item.id))?.qualityIndex ?? 0;

  @override
  Future<void> saveProgress(int lineIndex, int episodeIndex, double position, double duration,
      {int quality = 0, bool flush = true}) async {
    if (!recordHistory) return;
    final eps = detail.lines[lineIndex].episodes;
    await history.record(
      ProgressEntry(
        item: detail.item,
        lineIndex: lineIndex,
        episodeIndex: episodeIndex,
        episodeName: episodeIndex < eps.length ? eps[episodeIndex].name : '',
        positionSeconds: position,
        durationSeconds: duration,
        updatedAt: 0, // stamped by the repository
        qualityIndex: quality,
        videoWidth: _knownVideoSize?.width,
        videoHeight: _knownVideoSize?.height,
      ),
      flush: flush,
    );
    await _replaceEntryUnderAnsweredId();
  }

  bool _replacedOld = false;

  /// Builds before 2026-11-10 saved the history under the detail answer's id ([VodDetail.responseId]), which cannot
  /// be opened again. Once this video is saved under its own id, that entry goes if it is this same video.
  Future<void> _replaceEntryUnderAnsweredId() async {
    final old = detail.responseId;
    if (_replacedOld || old == null) return;
    _replacedOld = true;
    final e = await history.find(site.key, old);
    if (e != null && e.item.name == detail.item.name) await history.remove(site.key, old);
  }
}

/// Episode URLs are playable as they are (live channels, sniffed streams, local files, `openVideoPlayer` callbacks).
class DirectPlaybackSource extends PlaybackSource {
  DirectPlaybackSource({required this.title, required this.lines, this.cover, this.headers = const {}, this.epg});

  DirectPlaybackSource.single(
      {required String title, required String url, Map<String, String> headers = const {}, String? cover})
      : this(title: title, cover: cover, headers: headers, lines: [
          PlayLine('Default', [PlayEpisode(title, url)])
        ]);

  @override
  final String title;
  @override
  final String? cover;
  @override
  final List<PlayLine> lines;
  @override
  final List<EpgProgramme>? epg;
  final Map<String, String> headers;

  @override
  Future<PlayResult> resolve(int lineIndex, int episodeIndex) async =>
      PlayResult(url: lines[lineIndex].episodes[episodeIndex].url, headers: headers);
}
