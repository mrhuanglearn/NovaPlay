import '../../core/json_store.dart';
import '../../services/tmdb_client.dart';

/// "Tracking calendar" (changelog 1.1.4/1.1.5): weekly view of when followed shows air new episodes.
///
/// OBSERVED: tab + routes `/tracking/manage`, provider names trackingStoreProvider / trackingListProvider /
/// trackingCalendarProvider / trackingTmdbClientProvider / trackingHostProvider, data file tracking.json,
/// favorites auto-join the calendar (switch in auto_sync_favorites.json), long-press marks "watched" or removes,
/// unknown episodes jump to search. INFERRED: JSON layout and week logic.
class TrackedShow {
  TrackedShow({required this.tmdbId, required this.title, required this.season, Set<int>? watched, this.posterPath})
      : watched = watched ?? <int>{};

  factory TrackedShow.fromJson(Map<String, dynamic> j) => TrackedShow(
        tmdbId: j['tmdbId'] as int,
        title: j['title'] as String,
        season: j['season'] as int? ?? 1,
        watched: ((j['watched'] as List?) ?? const []).cast<int>().toSet(),
        posterPath: j['posterPath'] as String?,
      );

  final int tmdbId;
  final String title;
  final int season;
  final Set<int> watched;
  final String? posterPath;

  Map<String, dynamic> toJson() =>
      {'tmdbId': tmdbId, 'title': title, 'season': season, 'watched': watched.toList()..sort(), 'posterPath': posterPath};
}

class CalendarEntry {
  const CalendarEntry({required this.show, required this.episode, required this.date, required this.watched});
  final TrackedShow show;
  final TmdbEpisode episode;
  final DateTime date;
  final bool watched;
}

class TrackingStore {
  TrackingStore({JsonStore? store}) : _store = store ?? JsonStore('tracking.json');
  final JsonStore _store;

  Future<List<TrackedShow>> all() async {
    final raw = await _store.read<List<dynamic>>(const []);
    return raw.whereType<Map>().map((e) => TrackedShow.fromJson(e.cast<String, dynamic>())).toList();
  }

  Future<void> _save(List<TrackedShow> shows) => _store.write(shows.map((s) => s.toJson()).toList());

  Future<void> add(TrackedShow show) async {
    final list = (await all()).where((s) => s.tmdbId != show.tmdbId || s.season != show.season).toList()..add(show);
    await _save(list);
  }

  Future<void> remove(int tmdbId) async => _save((await all()).where((s) => s.tmdbId != tmdbId).toList());

  Future<void> markWatched(int tmdbId, int episodeNumber, {bool watched = true}) async {
    final list = await all();
    for (final s in list.where((s) => s.tmdbId == tmdbId)) {
      watched ? s.watched.add(episodeNumber) : s.watched.remove(episodeNumber);
    }
    await _save(list);
  }
}

/// Monday 00:00 of the week containing [day].
DateTime weekStart(DateTime day) {
  final d = DateTime(day.year, day.month, day.day);
  return d.subtract(Duration(days: d.weekday - DateTime.monday));
}

class TrackingCalendar {
  TrackingCalendar(this.store, this.tmdb);
  final TrackingStore store;
  final TmdbClient tmdb;

  /// Episodes airing between [from] (inclusive) and [from] + 7 days, ordered by date.
  Future<List<CalendarEntry>> week(DateTime from) async {
    final start = weekStart(from);
    final end = start.add(const Duration(days: 7));
    final out = <CalendarEntry>[];
    for (final show in await store.all()) {
      final eps = await tmdb.season(show.tmdbId, show.season);
      for (final ep in eps) {
        final d = ep.airDate;
        if (d == null || d.isBefore(start) || !d.isBefore(end)) continue;
        out.add(CalendarEntry(show: show, episode: ep, date: d, watched: show.watched.contains(ep.number)));
      }
    }
    out.sort((a, b) => a.date.compareTo(b.date));
    return out;
  }
}
