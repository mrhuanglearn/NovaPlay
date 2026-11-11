'use strict';
/**
 * Generic "manager" services: standalone Node scripts (danmu_api style) that are installed once and
 * started/stopped on demand. They run in the same sandboxed worker as catpaw but in 'ctx' start mode
 * (the script's `start()` receives {name, port, dataDir, log}).
 *
 * Commands arrive on the `manager` channel; every non-`list` command is acknowledged with a
 * {type:'result'} event followed by a fresh {type:'list'} snapshot.
 */

const fs = require('fs');
const path = require('path');
const {
  Channel, Action, WorkerMsg, LoaderMsg, STOP_GRACE_MS, resultEvent, listEvent, sanitizeName,
} = require('./protocol');
const { spawnWorker, removeDir } = require('./spawn');

function createServiceManager({ bridge, workerEntryPath }) {
  const root = bridge.getDataDir();
  const serviceRoot = path.join(root, 'service-data');
  /** installed definitions */
  const dynamic = {};
  /** running instances */
  const running = {};

  const status = (t) => bridge.channel(Channel.status).send(t);
  const send = (event) => bridge.channel(Channel.manager).send(JSON.stringify(event));

  function serviceDataDir(name) {
    const dir = path.join(serviceRoot, sanitizeName(name));
    fs.mkdirSync(dir, { recursive: true });
    return dir;
  }

  function report() {
    send(listEvent(Object.keys(dynamic).map((name) => ({
      name,
      port: running[name] ? running[name].port : null,
      running: !!running[name],
      dataDir: running[name] ? running[name].dataDir : null,
    }))));
  }

  function dropRunning(name) {
    const inst = running[name];
    delete running[name];
    if (inst) inst.worker.terminate().catch(() => {});
  }

  function onMessage(name) {
    return (m) => {
      switch (m && m.type) {
        case WorkerMsg.log: status(`[log] svc ${name}: ${m.message}`); break;
        case WorkerMsg.netlog:
          bridge.channel(Channel.netlog).send(`[net] ${m.method} ${m.url} → ${m.status != null ? m.status : m.error || '?'} (${m.ms || 0}ms)`);
          break;
        case WorkerMsg.result:
          if (m.action === Action.start && !m.ok) { status(`svc ${name} start failed: ${m.error || ''}`); dropRunning(name); report(); }
          break;
        case WorkerMsg.error:
          status(`svc ${name} error: ${m.message}`); dropRunning(name); report(); break;
        default:
      }
    };
  }

  function start(name, port, enableNetLog, enableLog = true, env) {
    const def = dynamic[name];
    if (!def) throw new Error(`unknown service: ${name}`);
    if (running[name]) return running[name];
    const listenPort = port || def.defaultPort;
    const dataDir = serviceDataDir(name);
    const tempDir = path.join(path.dirname(def.path), 'Temp');
    fs.mkdirSync(tempDir, { recursive: true });
    const worker = spawnWorker({
      workerEntryPath,
      name,
      workerData: {
        name, scriptPath: def.path, startArg: { name, port: listenPort, dataDir }, startMode: 'ctx', dataDir,
        port: null, dartPort: 0, env: env || {}, allowWriteDirs: [dataDir, tempDir],
        allowReadDirs: [path.dirname(def.path)], redirectRoot: tempDir, enableNetLog: !!enableNetLog, enableLog,
      },
      onMsg: onMessage(name),
      onError: (e) => { status(`svc ${name} worker crashed: ${(e && e.message) || e}`); delete running[name]; report(); },
      onStatus: status,
    });
    running[name] = { worker, port: listenPort, dataDir, env: env || {} };
    return running[name];
  }

  function stop(name) {
    const inst = running[name];
    if (!inst) return;
    delete running[name];
    try { inst.worker.postMessage({ type: LoaderMsg.stop }); } catch { /* gone */ }
    const timer = setTimeout(() => { try { inst.worker.terminate(); } catch { /* gone */ } }, STOP_GRACE_MS);
    timer.unref();
    inst.worker.once('exit', () => clearTimeout(timer));
  }

  function install(name, scriptPath, defaultPort) {
    if (running[name]) throw new Error(`service running, stop it first: ${name}`);
    dynamic[name] = { path: require.resolve(scriptPath), defaultPort: defaultPort || null };
  }

  function uninstall(name) {
    if (!dynamic[name]) throw new Error(`not installed: ${name}`);
    stop(name);
    delete dynamic[name];
    removeDir(serviceDataDir(name));
  }

  async function reload(name) {
    if (!dynamic[name]) throw new Error(`unknown service: ${name}`);
    const inst = running[name];
    if (!inst) return;
    const { port, env } = inst;
    stop(name);
    start(name, port, undefined, undefined, env);
  }

  async function reloadAll() {
    for (const name of Object.keys(running)) { try { await reload(name); } catch { /* keep going */ } }
  }

  async function handle(raw) {
    let cmd;
    try { cmd = JSON.parse(raw); } catch { status('manager error: bad json'); return; }
    const { action } = cmd;
    let name = cmd.name;
    let ok = true;
    let error = null;
    try {
      if (action === Action.start) start(cmd.name, cmd.port, cmd.enableNetLog, cmd.enableLog, cmd.env);
      else if (action === Action.stop) stop(cmd.name);
      else if (action === Action.install) install(cmd.name, cmd.path, cmd.defaultPort);
      else if (action === Action.uninstall) uninstall(cmd.name);
      else if (action === Action.reload) { name = cmd.name; if (cmd.name) await reload(cmd.name); else await reloadAll(); }
    } catch (e) {
      ok = false;
      error = (e && e.message) || String(e);
      status(`manager error: ${error}`);
    }
    if (action && action !== Action.list) send(resultEvent({ action, name, ok, error }));
    report();
  }

  function attach() {
    bridge.channel(Channel.manager).on((raw) => { handle(raw); });
  }

  async function terminateAll() {
    const workers = Object.values(running).map((r) => r.worker);
    for (const name of Object.keys(running)) delete running[name];
    await Promise.all(workers.map((w) => w.terminate().catch(() => {})));
  }

  return { attach, handle, report, running, dynamic, terminateAll };
}

module.exports = { createServiceManager };
