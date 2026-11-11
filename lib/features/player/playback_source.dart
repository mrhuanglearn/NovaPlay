import '../../models/vod.dart';
import '../catpaw/spider_api.dart';
import '../library/watch_repository.dart';
import 'native_player_api.g.dart' show EpgProgramme;

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

  Future<double> resumeSeconds(int lineIndex, int episodeIndex) async => 0;

  /// The source quality to start with (index into the play result's qualities).
  Future<int> resumeQuality() async => 0;

  /// [quality] is the source quality being played (index into the play result's qualities).
  Future<void> saveProgress(int lineIndex, int episodeIndex, double position, double duration,
      {int quality = 0}) async {}

  /// The player page closed at [position] seconds (after the last [saveProgress]).
  Future<void> finish(int lineIndex, int episodeIndex, double position) async {}
}

/// A video from a catpaw site: URLs come from the site's `play` route, progress goes to the watch history.
class VodPlaybackSource extends PlaybackSource {
  VodPlaybackSource({required this.site, required this.api, required this.detail, required this.history});

  final SpiderSite site;
  final SpiderApi api;
  final VodDetail detail;
  final HistoryRepository history;

  @override
  String get title => detail.item.name;

  @override
  String? get cover => detail.item.pic;

  @override
  List<PlayLine> get lines => detail.lines;

  @override
  String get memoryKey => vodKey(site.key, detail.item.id);

  @override
  Future<PlayResult> resolve(int lineIndex, int episodeIndex) {
    final line = detail.lines[lineIndex];
    return api.play(site, line.name, line.episodes[episodeIndex].url);
  }

  /// An episode left within its last 5 seconds counts as watched and starts again from 0 (INFERRED: starting at the
  /// saved end made the player report 'ended' at once and close).
  @override
  Future<double> resumeSeconds(int lineIndex, int episodeIndex) async {
    final e = await history.find(site.key, detail.item.id);
    if (e == null || e.lineIndex != lineIndex || e.episodeIndex != episodeIndex) return 0;
    if (e.durationSeconds > 0 && e.durationSeconds - e.positionSeconds < 5) return 0;
    return e.positionSeconds;
  }

  /// The quality is remembered per video, not per episode: the player keeps it across episodes as well.
  @override
  Future<int> resumeQuality() async => (await history.find(site.key, detail.item.id))?.qualityIndex ?? 0;

  @override
  Future<void> saveProgress(int lineIndex, int episodeIndex, double position, double duration,
      {int quality = 0}) async {
    final eps = detail.lines[lineIndex].episodes;
    await history.record(ProgressEntry(
      item: detail.item,
      lineIndex: lineIndex,
      episodeIndex: episodeIndex,
      episodeName: episodeIndex < eps.length ? eps[episodeIndex].name : '',
      positionSeconds: position,
      durationSeconds: duration,
      updatedAt: 0, // stamped by the repository
      qualityIndex: quality,
    ));
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
