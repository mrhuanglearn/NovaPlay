'use strict';
/**
 * Wire protocol between the Dart side and the embedded Node host.
 *
 * Observed in the shipped bundle (assets/flutter_assets/nodejs/f.cjs and e.cjs):
 *  - four string channels on the `flutter-bridge` module
 *  - JSON-encoded commands Dart -> Node on `catpaw` and `manager`
 *  - JSON-encoded events Node -> Dart on the same channels, tagged with `type`
 *  - worker_threads messages between the host and a sandboxed worker
 *
 * This file is a re-statement of that contract, not a copy of the original source.
 */

const Channel = Object.freeze({
  status: 'status',
  catpaw: 'catpaw',
  manager: 'manager',
  netlog: 'netlog',
});

const Action = Object.freeze({
  start: 'start',
  stop: 'stop',
  list: 'list',
  install: 'install',
  uninstall: 'uninstall',
  setDartPort: 'setDartPort',
  reload: 'reload',
  reloadDanmu: 'reloadDanmu',
});

/** `type` tag of events the host sends to Dart. */
const EventType = Object.freeze({
  port: 'port',
  list: 'list',
  result: 'result',
});

/** Actions a catpaw script may ask the Dart side to perform (Dart-side handler names). */
const DartAction = Object.freeze({
  queryProfile: 'queryProfile',
  saveProfile: 'saveProfile',
  sniff: 'sniff',
  toast: 'toast',
  danmuPush: 'danmuPush',
  openInternalWebview: 'openInternalWebview',
  openExternalWebview: 'openExternalWebview',
  openVodDetail: 'openVodDetail',
  queryTabs: 'queryTabs',
  switchTab: 'switchTab',
  openSearch: 'openSearch',
  queryHistory: 'queryHistory',
  openVideoPlayer: 'openVideoPlayer',
});

/** worker -> host */
const WorkerMsg = Object.freeze({
  port: 'port',
  result: 'result',
  log: 'log',
  netlog: 'netlog',
  error: 'error',
  reloaded: 'reloaded',
  reloadedDanmu: 'reloadedDanmu',
});

/** host -> worker */
const LoaderMsg = Object.freeze({
  stop: 'stop',
  reload: 'reload',
  reloadDanmu: 'reloadDanmu',
  setDartPort: 'setDartPort',
});

/** Directory (below the app data dir) that holds per-instance catpaw data. */
const SharedPath = Object.freeze({ runtimeDataDir: 'catpaw-data' });

/** Port that the subscription-provided danmu service listens on (observed constant). */
const SUBSCRIPTION_DANMU_PORT = 9321;

/** Grace period before a worker is force-terminated after a stop request. */
const STOP_GRACE_MS = 3000;
/** Time the host waits for a worker to answer reload / reloadDanmu. */
const RELOAD_TIMEOUT_MS = 4000;

function omitNil(obj) {
  const out = {};
  for (const [k, v] of Object.entries(obj)) if (v !== null && v !== undefined) out[k] = v;
  return out;
}

/** Normalise a `start` command from Dart. */
function parseCatpawStart(json) {
  return {
    name: json.name,
    path: json.path,
    configPath: json.configPath ?? null,
    port: json.port ?? null,
    force: json.force ?? false,
    enableNetLog: json.enableNetLog ?? false,
    enableLog: json.enableLog ?? false,
    env: json.env ?? null,
  };
}

function resultEvent({ action = null, name = null, ok, error = null }) {
  return { type: EventType.result, ...omitNil({ action, name }), ok: !!ok, ...omitNil({ error }) };
}

function portEvent(name, port) {
  return { type: EventType.port, name, port };
}

function instanceInfo({ name, port = null, running, dataDir = null }) {
  return { name, ...omitNil({ port }), running: !!running, ...omitNil({ dataDir }) };
}

function listEvent(instances) {
  return { type: EventType.list, services: instances.map(instanceInfo) };
}

function sanitizeName(name) {
  return String(name).replace(/[^a-zA-Z0-9_-]/g, '_');
}

module.exports = {
  Channel,
  Action,
  EventType,
  DartAction,
  WorkerMsg,
  LoaderMsg,
  SharedPath,
  SUBSCRIPTION_DANMU_PORT,
  STOP_GRACE_MS,
  RELOAD_TIMEOUT_MS,
  omitNil,
  parseCatpawStart,
  resultEvent,
  portEvent,
  instanceInfo,
  listEvent,
  sanitizeName,
};
