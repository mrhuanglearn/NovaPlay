import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/vod.dart';
import '../catpaw/spider_api.dart';
import '../library/watch_repository.dart';
import '../sniffer/sniffer_service.dart';
import 'download_manager.dart';

/// Stable task id for one episode of one video.
String downloadId(String siteKey, String vodId, int line, int episode) => '${vodKey(siteKey, vodId)}|$line|$episode';

/// Directory name derived from the id (ids contain `|` and arbitrary site keys).
String downloadDirName(String id) => sha1.convert(id.codeUnits).toString().substring(0, 16);

/// Resolves an episode to a media URL (sniffing `parse: 1` pages) and queues it. Returns the task.
Future<DownloadTask> enqueueEpisode({
  required DownloadManager manager,
  required SnifferService sniffer,
  required SpiderSite site,
  required SpiderApi api,
  required VodDetail detail,
  required int lineIndex,
  required int episodeIndex,
}) async {
  final line = detail.lines[lineIndex];
  final episode = line.episodes[episodeIndex];
  final id = downloadId(site.key, detail.item.id, lineIndex, episodeIndex);
  final existing = manager.tasks[id];
  if (existing != null) {
    manager.resume(id);
    return existing;
  }
  var res = await api.play(site, line.name, episode.url);
  if (res.needsParse) {
    final found = await sniffer.sniffFirstVideo(res.url, headers: res.headers);
    if (found == null) throw StateError('no downloadable stream found on page');
    res = PlayResult(url: found.url, headers: {...res.headers, ...found.headers});
  }
  final base = await getApplicationSupportDirectory();
  return manager.enqueue(DownloadTask(
    id: id,
    title: '${detail.item.name} ${episode.name}',
    url: res.url,
    dir: p.join(base.path, 'downloads', downloadDirName(id)),
    headers: res.headers,
    group: detail.item.name,
  ));
}
