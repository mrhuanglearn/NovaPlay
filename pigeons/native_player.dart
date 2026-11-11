// Pigeon schema for the native player bridge.
//
// OBSERVED: the channel names `dev.flutter.pigeon.uzn.NativePlayerHostApi.*` and
// `dev.flutter.pigeon.uzn.NativePlayerFlutterApi.*`, the data-class names and the field-name fragments
// found in the shipped dex. INFERRED: which fields belong to which class and every field type; the
// original R8-minified classes were not recovered one by one.
//
// Generate with:
//   dart run pigeon --input pigeons/native_player.dart
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/features/player/native_player_api.g.dart',
  kotlinOut: 'android/app/src/main/kotlin/com/example/uzv/native_player/NativePlayerApi.g.kt',
  kotlinOptions: KotlinOptions(package: 'com.example.uzv.native_player'),
  swiftOut: 'packages/novaplay_ios/ios/Classes/Generated/NativePlayerApi.g.swift',
))
class LineInfo {
  // DEVIATION: `episodes` is this project's addition. `OpenPlayerRequest.episodes` (observed) only carries the
  // starting line, so the native side could not switch lines without a round trip to Dart; with every line's list
  // in the request it can.
  LineInfo({required this.lineIndex, required this.lineName, this.episodes = const []});
  int lineIndex;
  String lineName;
  List<EpisodeItem> episodes;
}

class EpisodeItem {
  EpisodeItem({required this.episodeIndex, required this.episodeName});
  int episodeIndex;
  String episodeName;
}

class QualityOption {
  QualityOption({required this.qualityIndex, required this.qualityName});
  int qualityIndex;
  String qualityName;
}

class TmdbEpisodeItem {
  TmdbEpisodeItem({
    required this.episodeNumber,
    required this.episodeName,
    this.overview,
    this.stillPath,
    this.durationMs,
  });
  int episodeNumber;
  String episodeName;
  String? overview;
  String? stillPath;
  int? durationMs;
}

class EpgProgramme {
  EpgProgramme({required this.startEpochMs, required this.endEpochMs, required this.title, this.description});
  int startEpochMs;
  int endEpochMs;
  String title;
  String? description;
}

class DanmakuConfig {
  DanmakuConfig({
    required this.enabled,
    required this.opacity,
    required this.fontSize,
    required this.scrollSpeed,
    required this.area,
    required this.colorMode,
    required this.gradientStyle,
    required this.showTop,
    required this.showBottom,
    required this.delaySeconds,
    required this.lineHeight,
    required this.strokeWidth,
    required this.blackList,
  });
  bool enabled;
  double opacity;
  double fontSize;
  double scrollSpeed; // 0.3 .. 2.0 (changelog 1.1.12)
  double area;
  String colorMode;
  String gradientStyle;
  bool showTop;
  bool showBottom;
  double delaySeconds;
  double lineHeight;
  double strokeWidth;
  List<String> blackList;
}

class PlaybackConfig {
  PlaybackConfig({
    required this.hwDecode,
    required this.fitMode,
    required this.speed,
    required this.longPressSpeed,
    required this.fastForwardSeconds,
    required this.autoPictureInPicture,
    required this.pauseOnBackground,
    required this.isPriorityLandscape,
    required this.isHiddenFastSeekBtn,
    required this.isShowStatsBar,
    required this.isShowAllDuration,
    required this.isShowEpisodeSwitchNotice,
    required this.showNetSpeed,
    required this.hapticEnabled,
    required this.skipNotice,
    required this.kernel, // 'exo' | 'mpv' | 'mdk'
    this.subtitleFontFamily,
    this.subtitleFontsDir,
    this.subtitleLang,
    this.uiLocale,
    this.accentColorHex,
    this.audioLang,
    this.isLongPressSpeedAdjustEnabled,
  });
  bool hwDecode;
  String fitMode;
  double speed;
  double longPressSpeed;
  int fastForwardSeconds;
  bool autoPictureInPicture;
  bool pauseOnBackground;
  bool isPriorityLandscape;
  bool isHiddenFastSeekBtn;
  bool isShowStatsBar;
  bool isShowAllDuration;
  bool isShowEpisodeSwitchNotice;
  bool showNetSpeed;
  bool hapticEnabled;
  bool skipNotice;
  String kernel;
  String? subtitleFontFamily;
  String? subtitleFontsDir;
  String? subtitleLang;
  String? uiLocale;
  String? accentColorHex;

  /// DEVIATION: this project's addition (preferred audio language, e.g. `ja`).
  String? audioLang;

  /// 长按滑动调节倍速 (OBSERVED in the original's PlaybackConfig as `isLongPressSpeedAdjustEnabled`; null = on, as the
  /// original only turns it off for an explicit false). Added last so files saved before it still load.
  bool? isLongPressSpeedAdjustEnabled;
}

/// Patch applied to a running player (all fields optional).
class RuntimeConfigPatch {
  RuntimeConfigPatch({this.playbackConfig, this.danmakuConfig});
  PlaybackConfig? playbackConfig;
  DanmakuConfig? danmakuConfig;
}

class OpenPlayerRequest {
  OpenPlayerRequest({
    required this.sessionId,
    required this.title,
    required this.isMovie,
    required this.lines,
    required this.episodes,
    required this.playbackConfig,
    required this.danmakuConfig,
    required this.startPositionSeconds,
    required this.startLineIndex,
    required this.startEpisodeIndex,
    this.coverUrl,
    this.tmdbEpisodes,
    this.currentTmdbEpisodeNumber,
    this.epgProgrammes,
    this.headTailSectionsJson,
    this.startQualityIndex,
  });
  String sessionId;
  String title;
  bool isMovie;
  List<LineInfo> lines;
  List<EpisodeItem> episodes;
  PlaybackConfig playbackConfig;
  DanmakuConfig danmakuConfig;
  int startPositionSeconds;
  int startLineIndex;
  int startEpisodeIndex;
  String? coverUrl;
  List<TmdbEpisodeItem>? tmdbEpisodes;
  int? currentTmdbEpisodeNumber;
  List<EpgProgramme>? epgProgrammes;

  /// JSON of intro/outro sections, see lib/models/head_tail.dart
  String? headTailSectionsJson;

  /// DEVIATION: this project's addition. The source quality the watch history remembers for this video (the index into
  /// `SourcePayload.qualities`), so 立即播放 / the history continue with the quality picked last time.
  int? startQualityIndex;
}

/// A subtitle file to load next to the video.
// DEVIATION: this class and `SourcePayload.subtitles` are this project's addition. Only the `qualities` field was
// observed on the original payload; how its sidecar subtitles reach the player is unknown.
class SubtitleOption {
  SubtitleOption({required this.url, required this.name, this.language, this.mimeType});
  String url;
  String name;
  String? language; // BCP-47 / ISO 639 tag
  String? mimeType; // optional; inferred from the file extension when absent
}

/// Answer to Kotlin's `onEpisodeRequest`.
class SourcePayload {
  SourcePayload({
    required this.requestId,
    required this.success,
    this.url,
    this.audioUrl,
    this.headers,
    this.qualities,
    this.subtitles,
    this.errorMessage,
  });
  int requestId;
  bool success;
  String? url;
  String? audioUrl; // separate audio track for DASH sources
  Map<String, String>? headers;
  List<QualityOption>? qualities;
  List<SubtitleOption>? subtitles;
  String? errorMessage;
}

class DanmakuPayload {
  DanmakuPayload({required this.sessionId, required this.commentsJson, this.animeTitle, this.episodeTitle});
  String sessionId;
  String commentsJson;
  String? animeTitle;
  String? episodeTitle;
}

class DanmakuSearchResultItem {
  DanmakuSearchResultItem({required this.animeId, required this.animeTitle, required this.episodeCount, this.imageUrl});
  int animeId;
  String animeTitle;
  int episodeCount;
  String? imageUrl;
}

class DanmakuPromptInfo {
  DanmakuPromptInfo({required this.keyword, this.episodeNumber});
  String keyword;
  int? episodeNumber;
}

// ---- Kotlin -> Dart events ----------------------------------------------------------------------
class Heartbeat {
  Heartbeat({required this.sessionId, required this.positionSeconds, required this.durationSeconds});
  String sessionId;
  double positionSeconds;
  double durationSeconds;
}

class StateEvent {
  StateEvent({required this.sessionId, required this.state});
  String sessionId;
  String state; // idle | buffering | playing | paused | ended
}

class ErrorReport {
  ErrorReport({required this.sessionId, required this.message, required this.fatal, this.code});
  String sessionId;
  String message;
  bool fatal;
  int? code;
}

class PreferenceReport {
  PreferenceReport({required this.sessionId, this.playbackConfig, this.danmakuConfig});
  String sessionId;
  PlaybackConfig? playbackConfig;
  DanmakuConfig? danmakuConfig;
}

class PageClosedEvent {
  PageClosedEvent({required this.sessionId, required this.positionSeconds, required this.completed});
  String sessionId;
  double positionSeconds;
  bool completed;
}

class EpisodeRequest {
  EpisodeRequest({required this.sessionId, required this.requestId, required this.lineIndex, required this.episodeIndex, required this.qualityIndex});
  String sessionId;
  int requestId;
  int lineIndex;
  int episodeIndex;
  int qualityIndex;
}

class DanmakuRequest {
  DanmakuRequest({required this.sessionId, required this.lineIndex, required this.episodeIndex});
  String sessionId;
  int lineIndex;
  int episodeIndex;
}

class DanmakuSearchRequest {
  DanmakuSearchRequest({required this.sessionId, required this.keyword});
  String sessionId;
  String keyword;
}

/// Dart -> Kotlin
@HostApi()
abstract class NativePlayerHostApi {
  void openPlayerPage(OpenPlayerRequest request);
  void provideSource(SourcePayload payload);
  void updateDanmaku(DanmakuPayload payload);
  void updateLineTmdbMatches(String sessionId, List<TmdbEpisodeItem> matches);
  void updateRuntimeConfig(String sessionId, RuntimeConfigPatch patch);
  void provideDanmakuSearchResults(String sessionId, List<DanmakuSearchResultItem> results);
  void provideDanmakuEpisodesResults(String sessionId, List<EpisodeItem> episodes);

  /// DEVIATION: this project's addition (2026-11-10). A script's `toast` callback while a player page is open: shown
  /// as a system toast over the page, where the Flutter one would be hidden. False = no page took it.
  bool showToast(String message, bool long);
}

/// Kotlin -> Dart
/// All callbacks are `@async` so the Dart implementation may return Futures.
@FlutterApi()
abstract class NativePlayerFlutterApi {
  @async
  void onEpisodeRequest(EpisodeRequest request);
  @async
  void onDanmakuRequest(DanmakuRequest request);
  @async
  void onDanmakuSearchRequest(DanmakuSearchRequest request);
  @async
  void onDanmakuEpisodesRequest(String sessionId, int animeId);
  @async
  DanmakuPromptInfo getDanmakuPromptInfo(String sessionId);
  @async
  void onHeartbeat(Heartbeat heartbeat);
  @async
  void onStateChanged(StateEvent event);
  @async
  void onErrorReported(ErrorReport report);
  @async
  void onPreferenceReported(PreferenceReport report);
  @async
  void onPageClosed(PageClosedEvent event);

  /// 记片头 / 记片尾 pressed in the player. [type] is 'intro' ([seconds] from the start: where the intro ends) or 'outro'
  /// ([seconds] before the end: where the outro starts). INFERRED shape: the original's call was not recovered; it has
  /// the buttons (seen in 1.1.7) and keeps the marks in video_head_tail.json.
  @async
  void onHeadTailMarked(String sessionId, String type, double seconds);
}
