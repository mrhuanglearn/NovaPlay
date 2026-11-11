/// Mirror of the Dart <-> Node wire protocol (see node_host/src/protocol.js and ANALYSIS.md).
class Channels {
  static const status = 'status';
  static const catpaw = 'catpaw';
  static const manager = 'manager';
  static const netlog = 'netlog';
}

class Actions {
  static const start = 'start';
  static const stop = 'stop';
  static const list = 'list';
  static const install = 'install';
  static const uninstall = 'uninstall';
  static const setDartPort = 'setDartPort';
  static const reload = 'reload';
  static const reloadDanmu = 'reloadDanmu';
}

/// Actions a spider script can ask the Dart app to perform (observed list; payload shapes are inferred).
class DartActions {
  static const queryProfile = 'queryProfile';
  static const saveProfile = 'saveProfile';
  static const sniff = 'sniff';
  static const toast = 'toast';
  static const danmuPush = 'danmuPush';
  static const openInternalWebview = 'openInternalWebview';
  static const openExternalWebview = 'openExternalWebview';
  static const openVodDetail = 'openVodDetail';
  static const queryTabs = 'queryTabs';
  static const switchTab = 'switchTab';
  static const openSearch = 'openSearch';
  static const queryHistory = 'queryHistory';
  static const openVideoPlayer = 'openVideoPlayer';
}

class CatpawInstance {
  const CatpawInstance({required this.name, required this.running, this.port, this.dataDir});

  factory CatpawInstance.fromJson(Map<String, dynamic> j) => CatpawInstance(
        name: j['name'] as String,
        running: j['running'] as bool? ?? false,
        port: j['port'] as int?,
        dataDir: j['dataDir'] as String?,
      );

  final String name;
  final bool running;
  final int? port;
  final String? dataDir;
}

sealed class CatpawEvent {
  const CatpawEvent();

  static CatpawEvent? parse(Map<String, dynamic> j) {
    switch (j['type']) {
      case 'port':
        return CatpawPort(j['name'] as String, j['port'] as int);
      case 'list':
        return CatpawList(((j['services'] as List?) ?? const [])
            .map((e) => CatpawInstance.fromJson((e as Map).cast<String, dynamic>()))
            .toList());
      case 'result':
        return CatpawResult(
          action: j['action'] as String?,
          name: j['name'] as String?,
          ok: j['ok'] as bool? ?? false,
          error: j['error'] as String?,
        );
    }
    return null;
  }
}

class CatpawPort extends CatpawEvent {
  const CatpawPort(this.name, this.port);
  final String name;
  final int port;
}

class CatpawList extends CatpawEvent {
  const CatpawList(this.services);
  final List<CatpawInstance> services;
}

class CatpawResult extends CatpawEvent {
  const CatpawResult({this.action, this.name, required this.ok, this.error});
  final String? action;
  final String? name;
  final bool ok;
  final String? error;
}
