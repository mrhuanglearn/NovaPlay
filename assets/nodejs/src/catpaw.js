'use strict';
/**
 * "catpaw" instance manager. One instance = one sandboxed worker running a spider-server script
 * (a CatPawOpen style `index.js`) supplied by a subscription.
 *
 * Dart -> Node commands arrive on the `catpaw` channel as JSON: {action, name, ...}.
 * Node -> Dart events: {type:'port'|'result'|'list', ...}.
 */

const fs = require('fs');
const net = require('net');
const path = require('path');
const {
  Channel, Action, WorkerMsg, LoaderMsg, SharedPath, STOP_GRACE_MS, RELOAD_TIMEOUT_MS,
  parseCatpawStart, resultEvent, portEvent, listEvent, sanitizeName,
} = require('./protocol');
const { spawnWorker, removeDir } = require('./spawn');

const DEFAULT_CATPAW_PORT = 2333;

/**
 * If caller did not specify a port, check whether default catpaw port (2333) is already bound
 * (e.g. by another app or instance). If 2333 is free, return null so DEV_HTTP_PORT stays unset;
 * if 2333 is busy, allocate and return an ephemeral free port for DEV_HTTP_PORT.
 */
function resolveAvailablePort(requestedPort) {
  if (requestedPort) return Promise.resolve(requestedPort);
  return new Promise((resolve) => {
    const probe = net.createServer();
    probe.unref();
    probe.once('error', () => {
      const fallback = net.createServer();
      fallback.unref();
      fallback.once('error', () => resolve(null));
      fallback.listen(0, '0.0.0.0', () => {
        const addr = fallback.address();
        const freePort = addr && typeof addr.port === 'number' ? addr.port : null;
        fallback.close(() => resolve(freePort));
      });
    });
    probe.listen(DEFAULT_CATPAW_PORT, '0.0.0.0', () => {
      probe.close(() => resolve(null));
    });
  });
}

function loadConfig(configPath) {
  if (!configPath) return {};
  try { delete require.cache[require.resolve(configPath)]; } catch { /* not cached */ }
  const cfg = require(configPath);
  return cfg && typeof cfg === 'object' && cfg.default ? cfg.default : cfg;
}

/**
 * @param {{bridge: object, workerEntryPath: string}} deps
 */
function createCatpawHost({ bridge, workerEntryPath }) {
  const root = bridge.getDataDir();
  const runtimeDataDir = SharedPath.runtimeDataDir;
  /** @type {Record<string, {worker: import('worker_threads').Worker, port: number|null, dataDir: string, running: boolean}>} */
  const instances = {};
  let dartServerPort = 0;
  let chain = Promise.resolve();

  const status = (text) => bridge.channel(Channel.status).send(text);
  const emit = (event) => bridge.channel(Channel.catpaw).send(JSON.stringify(event));

  function report() {
    emit(listEvent(Object.keys(instances).map((name) => ({ name, ...instances[name] }))));
  }

  function dataDirOf(name) { return path.join(root, runtimeDataDir, sanitizeName(name)); }

  /**
   * Forget an instance whose start failed or that reported a fatal error. The original host only deleted
   * the table entry and left the thread running; this version also terminates it so nothing lingers
   * invisibly (deliberate deviation, see ANALYSIS.md).
   */
  function dropInstance(name) {
    const inst = instances[name];
    delete instances[name];
    if (inst) inst.worker.terminate().catch(() => {});
  }

  function onWorkerMessage(name) {
    return (msg) => {
      switch (msg && msg.type) {
        case WorkerMsg.port:
          if (instances[name]) { instances[name].port = msg.port; instances[name].running = true; }
          emit(portEvent(name, msg.port));
          break;
        case WorkerMsg.result:
          emit(resultEvent({ action: msg.action, name, ok: !!msg.ok, error: msg.error || null }));
          if (msg.action === Action.start && !msg.ok) { dropInstance(name); report(); }
          break;
        case WorkerMsg.log:
          status(`[log] catpaw ${name}: ${msg.message}`);
          break;
        case WorkerMsg.netlog:
          bridge.channel(Channel.netlog).send(
            `[net] ${msg.method} ${msg.url} → ${msg.status != null ? msg.status : msg.error || '?'} (${msg.ms || 0}ms)`);
          break;
        case WorkerMsg.error:
          status(`catpaw ${name} error: ${msg.message}`);
          if (instances[name] && !instances[name].running) {
            emit(resultEvent({ action: Action.start, name, ok: false, error: msg.message || 'worker error' }));
            dropInstance(name);
            report();
          }
          break;
        default:
      }
    };
  }

  function onWorkerError(name, err) {
    const message = (err && err.message) || String(err);
    status(`catpaw ${name} worker crashed: ${message}`);
    const inst = instances[name];
    delete instances[name];
    if (inst && !inst.running) {
      emit(resultEvent({ action: Action.start, name, ok: false, error: message }));
    }
    report();
  }

  async function start(name, scriptPath, configPath, port, enableNetLog, enableLog, env) {
    const dataDir = dataDirOf(name);
    fs.mkdirSync(dataDir, { recursive: true });
    const config = loadConfig(configPath);
    const keyCount = config && typeof config === 'object' ? Object.keys(config).length : 0;
    status(`catpaw ${name}: config ${configPath ? `已加载(${keyCount} keys)` : '缺失(空 config 启动)'}`);
    const tempDir = path.join(path.dirname(scriptPath), 'Temp');
    fs.mkdirSync(tempDir, { recursive: true });
    const extraDirs = [];
    if (env && typeof env.profile_path === 'string' && env.profile_path.length > 0) {
      const profileDir = path.dirname(env.profile_path);
      try {
        fs.mkdirSync(profileDir, { recursive: true });
        extraDirs.push(profileDir);
      } catch {
        /* ignore invalid profile_path */
      }
    }
    const resolvedPort = await resolveAvailablePort(port || null);
    const worker = spawnWorker({
      workerEntryPath,
      name,
      workerData: {
        name, scriptPath, startArg: config, dataDir, port: resolvedPort, dartPort: dartServerPort,
        env: env || {}, allowWriteDirs: [dataDir, tempDir, ...extraDirs], allowReadDirs: [path.dirname(scriptPath), ...extraDirs],
        redirectRoot: tempDir, enableNetLog: !!enableNetLog, enableLog: enableLog !== false,
      },
      onMsg: onWorkerMessage(name),
      onError: (e) => onWorkerError(name, e),
      onStatus: status,
    });
    instances[name] = { worker, port: null, dataDir, running: false };
  }

  async function stop(name, { purge = false } = {}) {
    const inst = instances[name];
    if (!inst) { if (purge) removeDir(dataDirOf(name)); return; }
    const { worker } = inst;
    delete instances[name];
    await new Promise((resolve) => {
      let settled = false;
      const done = () => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve();
      };
      worker.once('exit', done);
      try { worker.postMessage({ type: LoaderMsg.stop }); } catch { /* worker gone */ }
      const timer = setTimeout(() => {
        try {
          Promise.resolve(worker.terminate()).catch(() => {}).finally(done);
        } catch {
          done();
        }
      }, STOP_GRACE_MS);
      timer.unref();
    });
    if (purge && !instances[name]) removeDir(dataDirOf(name));
  }

  /** Ask a worker to run one of its reload routines and wait for the acknowledgement. */
  function askWorker(name, request, replyType) {
    const inst = instances[name];
    if (!inst || !inst.worker) return Promise.resolve({ ok: false, error: 'no-worker' });
    const { worker } = inst;
    return new Promise((resolve) => {
      let settled = false;
      const finish = (value) => { if (settled) return; settled = true; clearTimeout(timer); worker.off('message', onMessage); resolve(value); };
      const onMessage = (m) => { if (m && m.type === replyType) finish({ ok: m.ok !== false, error: m.error || null }); };
      const timer = setTimeout(() => finish({ ok: false, error: 'loader-timeout' }), RELOAD_TIMEOUT_MS);
      worker.on('message', onMessage);
      try { worker.postMessage({ type: request }); } catch (e) {
        finish({ ok: false, error: 'postMessage-failed: ' + ((e && e.message) || e) });
      }
    });
  }

  async function handle(raw) {
    let cmd;
    try { cmd = JSON.parse(raw); } catch { status('catpaw error: bad json'); return; }
    const { action } = cmd;
    let name = cmd.name;
    try {
      if (action === Action.setDartPort) { dartServerPort = Number(cmd.port) || 0; return; }
      if (action === Action.reload || action === Action.reloadDanmu) {
        const isDanmu = action === Action.reloadDanmu;
        const result = await askWorker(cmd.name, isDanmu ? LoaderMsg.reloadDanmu : LoaderMsg.reload,
          isDanmu ? WorkerMsg.reloadedDanmu : WorkerMsg.reloaded);
        emit(resultEvent({ action, name: cmd.name, ok: result.ok, error: result.error }));
        return;
      }
      if (action === Action.start) {
        const p = parseCatpawStart(cmd);
        name = p.name;
        if (instances[p.name]) {
          if (!p.force) throw new Error(`already running: ${p.name}`);
          status(`catpaw: force-restarting ${p.name}`);
          await stop(p.name);
        }
        await start(p.name, p.path, p.configPath, p.port, p.enableNetLog, p.enableLog, p.env);
      } else if (action === Action.stop) {
        await stop(cmd.name);
      } else if (action === Action.uninstall) {
        await stop(cmd.name, { purge: true });
      }
    } catch (e) {
      const message = (e && e.message) || String(e);
      status(`catpaw error: ${message}`);
      emit(resultEvent({ action: action || null, name: name || null, ok: false, error: message }));
    }
    report();
  }

  function attach() {
    bridge.channel(Channel.catpaw).on((raw) => {
      chain = chain.then(() => handle(raw)).catch((e) => status(`catpaw error: ${(e && e.message) || e}`));
    });
  }

  /** Wait for queued commands to finish (used by tests and graceful shutdown). */
  const idle = () => chain;

  /** Hard-stop every worker, e.g. when the app is shutting the runtime down. */
  async function terminateAll() {
    await idle();
    const workers = Object.values(instances).map((i) => i.worker);
    for (const name of Object.keys(instances)) delete instances[name];
    await Promise.all(workers.map((w) => w.terminate().catch(() => {})));
  }

  return { attach, handle, report, instances, idle, terminateAll };
}

module.exports = { createCatpawHost, loadConfig };
