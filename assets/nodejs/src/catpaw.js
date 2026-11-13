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
/** How many ports above the start port are tried before giving up and letting the OS pick one. */
const PORT_SCAN_LIMIT = 200;
const PROBE_TIMEOUT_MS = 300;

/**
 * Collects currently listening TCP ports within [minPort, maxPort] from /proc/net/tcp{,6}.
 * Fails open (returns empty Set) on non-Linux hosts or restricted environments (e.g. Android SELinux / iOS).
 */
function readProcListeningPorts(minPort, maxPort) {
  const occupied = new Set();
  for (const procPath of ['/proc/net/tcp', '/proc/net/tcp6']) {
    let content;
    try {
      content = fs.readFileSync(procPath, 'utf8');
    } catch {
      continue;
    }
    const lines = content.split('\n');
    for (let i = 1; i < lines.length; i++) {
      const line = lines[i].trim();
      if (!line) continue;
      const parts = line.split(/\s+/);
      if (parts.length < 4 || parts[3] !== '0A') continue; // 0A = TCP_LISTEN
      const colonIdx = parts[1].lastIndexOf(':');
      if (colonIdx < 0) continue;
      const p = parseInt(parts[1].slice(colonIdx + 1), 16);
      if (Number.isFinite(p) && p >= minPort && p <= maxPort) occupied.add(p);
    }
  }
  return occupied;
}

/** Whether something already answers on 127.0.0.1:port (another app, or an old instance). */
function somethingListens(port, host = '127.0.0.1') {
  return new Promise((resolve) => {
    const sock = net.connect({ port, host });
    const done = (busy) => { sock.removeAllListeners(); sock.destroy(); resolve(busy); };
    sock.setTimeout(PROBE_TIMEOUT_MS, () => done(false));
    sock.once('connect', () => done(true));
    sock.once('error', () => done(false));
  });
}

/** Whether this process can bind port on host right now (released again at once). */
function canBind(port, host) {
  return new Promise((resolve) => {
    const probe = net.createServer();
    probe.unref();
    probe.once('error', () => resolve(false));
    probe.listen({ port, host, exclusive: true }, () => probe.close(() => resolve(true)));
  });
}

/** Whether IPv6 wildcard bind succeeds (treats disabled IPv6 on host as non-blocking). */
function canBindIpv6(port) {
  return new Promise((resolve) => {
    const probe = net.createServer();
    probe.unref();
    probe.once('error', (err) => {
      if (err && (err.code === 'EAFNOSUPPORT' || err.code === 'EADDRNOTAVAIL')) resolve(true);
      else resolve(false);
    });
    probe.listen({ port, host: '::', ipv6Only: true, exclusive: true }, () => probe.close(() => resolve(true)));
  });
}

/**
 * A port is free when nobody answers on it and it can be bound on every interface. The connect probe matters on
 * iOS/BSD: there a wildcard bind with SO_REUSEADDR (libuv sets it) succeeds although another app holds
 * 127.0.0.1:port, and the script's requests would then reach that app.
 */
async function isPortFree(port) {
  if (await somethingListens(port, '127.0.0.1')) return false;
  if (!(await canBind(port, '0.0.0.0'))) return false;
  return canBindIpv6(port);
}

/**
 * The port a catpaw instance listens on (CatPawPlay 监听地址).
 *
 * Before 2026-11-13: 2333 when free, otherwise a random port picked by the OS. Now the ports from [startPort]
 * (2333 unless the caller asks for one) upward are checked one by one and the first free one is used, so the
 * address stays close to 2333 (2334, 2335, …) when another app or instance holds it. Ports used by this host's own
 * running instances or listed as listening in /proc/net/tcp{,6} are skipped. Only when [PORT_SCAN_LIMIT] ports in a
 * row are taken does the OS pick one.
 */
async function resolveAvailablePort(requestedPort, reserved = new Set()) {
  const startPort = Number(requestedPort) > 0 ? Number(requestedPort) : DEFAULT_CATPAW_PORT;
  const endPort = Math.min(65535, startPort + PORT_SCAN_LIMIT - 1);
  const occupied = readProcListeningPorts(startPort, endPort);
  for (let p = startPort; p <= endPort; p++) {
    if (reserved.has(p) || occupied.has(p)) continue;
    if (await isPortFree(p)) return p;
  }
  return new Promise((resolve) => {
    const fallback = net.createServer();
    fallback.unref();
    fallback.once('error', () => resolve(null));
    fallback.listen(0, '0.0.0.0', () => {
      const addr = fallback.address();
      const freePort = addr && typeof addr.port === 'number' ? addr.port : null;
      fallback.close(() => resolve(freePort));
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

  function onWorkerMessage(name, workerRef) {
    return (msg) => {
      if (workerRef && instances[name] && instances[name].worker !== workerRef) return;
      switch (msg && msg.type) {
        case WorkerMsg.port: {
          const inst = instances[name];
          const portChanged = !!(inst && inst.running && inst.port !== msg.port);
          if (inst) { inst.port = msg.port; inst.running = true; }
          emit(portEvent(name, msg.port));
          if (portChanged) report();
          break;
        }
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

  function onWorkerError(name, workerRef, err) {
    const message = (err && err.message) || String(err);
    status(`catpaw ${name} worker crashed: ${message}`);
    const inst = instances[name];
    if (!inst || (workerRef && inst.worker !== workerRef)) return;
    delete instances[name];
    if (!inst.running) {
      emit(resultEvent({ action: Action.start, name, ok: false, error: message }));
    }
    report();
  }

  function onWorkerExit(name, workerRef, code) {
    const inst = instances[name];
    if (!inst || (workerRef && inst.worker !== workerRef)) return;
    delete instances[name];
    status(`catpaw ${name} worker exited (code=${code})`);
    if (!inst.running) {
      emit(resultEvent({ action: Action.start, name, ok: false, error: `worker exited with code ${code}` }));
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
    const reserved = new Set();
    for (const inst of Object.values(instances)) {
      if (inst.port) reserved.add(inst.port);
      if (inst.requestedPort) reserved.add(inst.requestedPort);
    }
    const resolvedPort = await resolveAvailablePort(port || null, reserved);
    status(`catpaw ${name}: 监听端口 ${resolvedPort}${port && resolvedPort !== port ? `(请求 ${port} 已被占用)` : ''}`);
    let workerRef = null;
    const worker = spawnWorker({
      workerEntryPath,
      name,
      workerData: {
        name, scriptPath, startArg: config, dataDir, port: resolvedPort, dartPort: dartServerPort,
        env: env || {}, allowWriteDirs: [dataDir, tempDir, ...extraDirs], allowReadDirs: [path.dirname(scriptPath), ...extraDirs],
        redirectRoot: tempDir, enableNetLog: !!enableNetLog, enableLog: enableLog !== false,
      },
      onMsg: (m) => onWorkerMessage(name, workerRef)(m),
      onError: (e) => onWorkerError(name, workerRef, e),
      onExit: (code) => onWorkerExit(name, workerRef, code),
      onStatus: status,
    });
    workerRef = worker;
    instances[name] = { worker, port: null, requestedPort: resolvedPort, dataDir, running: false };
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
      const finish = (value) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        worker.off('message', onMessage);
        worker.off('exit', onExit);
        resolve(value);
      };
      const onMessage = (m) => { if (m && m.type === replyType) finish({ ok: m.ok !== false, error: m.error || null }); };
      const onExit = (code) => finish({ ok: false, error: `worker-exited(${code})` });
      const timer = setTimeout(() => finish({ ok: false, error: 'loader-timeout' }), RELOAD_TIMEOUT_MS);
      worker.on('message', onMessage);
      worker.once('exit', onExit);
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
      if (action === Action.setDartPort) {
        dartServerPort = Number(cmd.port) || 0;
        for (const inst of Object.values(instances)) {
          try { inst.worker.postMessage({ type: LoaderMsg.setDartPort, port: dartServerPort }); } catch { /* gone */ }
        }
        return;
      }
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

module.exports = { createCatpawHost, loadConfig, resolveAvailablePort, readProcListeningPorts, DEFAULT_CATPAW_PORT };
