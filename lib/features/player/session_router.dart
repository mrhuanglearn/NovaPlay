import 'native_player_api.g.dart';
import 'player_session.dart';

/// The one object registered as `NativePlayerFlutterApi`. Pigeon's `setUp` is global, so with several players alive
/// at once (a picture-in-picture window plus a live channel, a script's `openVideoPlayer`, ...) the session that
/// registered last would receive everything. Every call carries a session id; this router hands it to the right
/// [PlayerSession] and drops calls for sessions it does not know (e.g. late events of one that already closed).
class PlayerSessionRouter implements NativePlayerFlutterApi {
  PlayerSessionRouter();

  static final shared = PlayerSessionRouter();

  final _sessions = <String, PlayerSession>{};
  bool _installed = false;

  /// Most recently opened session that is still registered.
  PlayerSession? get latest => _sessions.values.isEmpty ? null : _sessions.values.last;

  int get length => _sessions.length;

  /// Registers this router with Pigeon (once; needs the Flutter binding, so tests skip it).
  void install() {
    if (_installed) return;
    _installed = true;
    NativePlayerFlutterApi.setUp(this);
  }

  void register(PlayerSession s) => _sessions[s.sessionId] = s;

  void unregister(PlayerSession s) {
    if (identical(_sessions[s.sessionId], s)) _sessions.remove(s.sessionId);
  }

  @override
  Future<void> onEpisodeRequest(EpisodeRequest request) async => _sessions[request.sessionId]?.onEpisodeRequest(request);

  @override
  Future<void> onDanmakuRequest(DanmakuRequest request) async => _sessions[request.sessionId]?.onDanmakuRequest(request);

  @override
  Future<void> onDanmakuSearchRequest(DanmakuSearchRequest request) async => _sessions[request.sessionId]?.onDanmakuSearchRequest(request);

  @override
  Future<void> onDanmakuEpisodesRequest(String sessionId, int animeId) async => _sessions[sessionId]?.onDanmakuEpisodesRequest(sessionId, animeId);

  @override
  Future<DanmakuPromptInfo> getDanmakuPromptInfo(String sessionId) async =>
      await _sessions[sessionId]?.getDanmakuPromptInfo(sessionId) ?? DanmakuPromptInfo(keyword: '');

  @override
  Future<void> onHeartbeat(Heartbeat heartbeat) async => _sessions[heartbeat.sessionId]?.onHeartbeat(heartbeat);

  @override
  Future<void> onStateChanged(StateEvent event) async => _sessions[event.sessionId]?.onStateChanged(event);

  @override
  Future<void> onErrorReported(ErrorReport report) async => _sessions[report.sessionId]?.onErrorReported(report);

  @override
  Future<void> onPreferenceReported(PreferenceReport report) async => _sessions[report.sessionId]?.onPreferenceReported(report);

  @override
  Future<void> onPageClosed(PageClosedEvent event) async => _sessions[event.sessionId]?.onPageClosed(event);

  @override
  Future<void> onHeadTailMarked(String sessionId, String type, double seconds) async =>
      _sessions[sessionId]?.onHeadTailMarked(sessionId, type, seconds);
}
