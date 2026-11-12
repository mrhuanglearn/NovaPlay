'use strict';
/**
 * Worker entry: loads a catpaw / service script inside a worker_thread and gives it the globals the
 * script expects.
 *
 * Observed contract (see ANALYSIS.md section "Node worker contract"):
 *  - workerData: name, scriptPath, startArg, startMode ('config' | 'ctx'), dataDir, port, dartPort, env,
 *    allowWriteDirs, allowReadDirs, redirectRoot, enableNetLog, enableLog
 *  - env: NODE_PATH=dataDir, DEV_HTTP_PORT=port (or removed), plus caller supplied variables
 *  - globals: catServerFactory(handler), catDartServerPort(), DB_NAME, _catServers, _catDanmuServers
 *  - the script's exported `start(arg)` is awaited, its `stop()` is called on shutdown
 *  - servers listening on 9321 are registered as "danmu" servers so they can be reloaded independently
 */

const { parentPort, workerData } = require('worker_threads');
const http = require('http');
const https = require('https');
const { WorkerMsg, LoaderMsg, SUBSCRIPTION_DANMU_PORT } = require('./protocol');
const { createPolicy, installFsPolicy } = require('./sandbox');

const {
  name,
  scriptPath,
  startArg,
  startMode = 'config',
  dataDir,
  port,
  dartPort,
  env,
  allowWriteDirs = [],
  allowReadDirs = [],
  redirectRoot = null,
  enableNetLog = false,
  enableLog = true,
} = workerData || {};

function post(message) {
  try { parentPort.postMessage({ name, ...message }); } catch { /* parent already gone */ }
}

// --- console -> host log channel -------------------------------------------------------------
const origLog = console.log;
const origErr = console.error;
// With enableLog the line goes to the host once, as [log]. Writing it to stdout as well would forward it a second
// time, because the host also reports the worker's stdout ([stdout] lines).
console.log = (...args) => {
  if (enableLog) post({ type: WorkerMsg.log, message: args.map(String).join(' ') });
  else origLog(...args);
};
console.error = (...args) => {
  if (enableLog) post({ type: WorkerMsg.log, message: '[err] ' + args.map(String).join(' ') });
  else origErr(...args);
};

// --- environment -----------------------------------------------------------------------------
if (env && typeof env === 'object') for (const [k, v] of Object.entries(env)) process.env[k] = v;
if (dataDir) process.env.NODE_PATH = dataDir;
if (port) process.env.DEV_HTTP_PORT = String(port); else delete process.env.DEV_HTTP_PORT;

// --- file-system sandbox ---------------------------------------------------------------------
const policy = createPolicy({
  allowWriteDirs,
  allowReadDirs,
  redirectRoot,
  dataDir,
  onRedirect: (kind, from, to) => {
    if (enableLog) post({ type: WorkerMsg.log, message: `[redirect] ${kind} ${from} -> ${to}` });
  },
});
if (policy.redirectRoot) {
  try { require('fs').mkdirSync(policy.redirectRoot, { recursive: true }); } catch { /* best effort */ }
}
installFsPolicy(policy);

// --- network log -----------------------------------------------------------------------------
function isLoopback(host) {
  return !host || host === 'localhost' || host === '127.0.0.1' || host === '0.0.0.0' || host === '::1' || host === '[::1]';
}

function describeRequest(proto, args) {
  const first = args[0];
  try {
    if (typeof first === 'string' || first instanceof URL) {
      const u = first instanceof URL ? first : new URL(first, `${proto}://localhost`);
      return { method: 'GET', host: u.hostname, url: u.toString() };
    }
    if (first && typeof first === 'object') {
      const method = String(first.method || 'GET').toUpperCase();
      const host = first.hostname || (first.host || '').split(':')[0];
      return { method, host, url: `${proto}://${host || '?'}${first.path || '/'}` };
    }
  } catch { /* unparsable */ }
  return null;
}

function installNetLogger(mod, proto) {
  const originalRequest = mod.request;
  mod.request = function loggedRequest(...args) {
    const meta = describeRequest(proto, args);
    const req = originalRequest.apply(this, args);
    if (meta && !isLoopback(meta.host)) {
      const started = Date.now();
      let reported = false;
      const report = (extra) => {
        if (reported) return;
        reported = true;
        post({ type: WorkerMsg.netlog, method: meta.method, url: meta.url, ...extra });
      };
      req.on('response', (res) => {
        res.on('end', () => report({ status: res.statusCode, ms: Date.now() - started }));
        res.on('close', () => report({ status: res.statusCode, ms: Date.now() - started }));
      });
      req.on('error', (e) => report({ error: (e && e.message) || String(e), ms: Date.now() - started }));
    }
    return req;
  };
  mod.get = function loggedGet(...args) {
    const req = mod.request.apply(this, args);
    req.end();
    return req;
  };
}
if (enableNetLog) { installNetLogger(http, 'http'); installNetLogger(https, 'https'); }

// --- server registry & globals ---------------------------------------------------------------
globalThis._catServers = globalThis._catServers || [];
globalThis._catDanmuServers = globalThis._catDanmuServers || [];

const originalCreateServer = http.createServer;
http.createServer = function createServer(...args) {
  const server = originalCreateServer.apply(http, args);
  const originalListen = server.listen;
  server.listen = function listen(...largs) {
    const first = largs[0];
    const listenPort = typeof first === 'number' ? first
      : first && typeof first === 'object' && typeof first.port === 'number' ? first.port : null;
    if (listenPort === SUBSCRIPTION_DANMU_PORT && !globalThis._catDanmuServers.some((s) => s.server === server)) {
      let addr = null;
      server.on('listening', () => {
        try {
          const a = server.address();
          if (a && typeof a.port === 'number') addr = { port: a.port, host: a.address };
        } catch { /* ignore */ }
      });
      globalThis._catDanmuServers.push({ server, getAddr: () => addr });
      if (enableLog) {
        post({ type: WorkerMsg.log, message: `[danmu-hook] captured subscription danmu server (port ${listenPort}), registered for standalone reloadDanmu` });
      }
    }
    return originalListen.apply(server, largs);
  };
  return server;
};

globalThis.catServerFactory = (handler) => {
  const server = http.createServer(handler);
  let addr = null;
  let retriedEphemeral = false;
  const origEmit = server.emit.bind(server);
  server.emit = function emitWithPortFallback(event, ...args) {
    if (
      event === 'error' &&
      !addr &&
      !port &&
      !retriedEphemeral &&
      args[0] &&
      args[0].code === 'EADDRINUSE'
    ) {
      retriedEphemeral = true;
      if (enableLog) {
        post({ type: WorkerMsg.log, message: '[catpaw] default port in use, falling back to ephemeral port' });
      }
      try {
        server.listen(0, '0.0.0.0');
        return true;
      } catch {
        /* fall through to original error emission */
      }
    }
    return origEmit(event, ...args);
  };
  server.on('listening', () => {
    try {
      const a = server.address();
      if (a && typeof a.port === 'number') {
        addr = { port: a.port, host: a.address };
        post({ type: WorkerMsg.port, port: a.port });
      }
    } catch { /* ignore */ }
  });
  server.on('error', (e) => post({ type: WorkerMsg.error, message: 'listen error: ' + ((e && e.message) || e) }));
  globalThis._catServers.push({ server, handle: handler, getAddr: () => addr });
  return server;
};
globalThis.catDartServerPort = () => dartPort || 0;
if (!globalThis.DB_NAME) globalThis.DB_NAME = 'default';

// --- reload helpers --------------------------------------------------------------------------
/** Close one registered server and bind it again on the same address. Resolves with an error string or null. */
function relisten(entry) {
  return new Promise((resolve) => {
    const addr = entry.getAddr();
    if (!addr) { resolve('no-listened-addr'); return; }
    const server = entry.server;
    const bindAgain = () => {
      const onListening = () => { server.off('error', onError); resolve(null); };
      const onError = (e) => { server.off('listening', onListening); resolve((e && e.message) || String(e)); };
      server.once('listening', onListening);
      server.once('error', onError);
      try { server.listen(addr.port, addr.host || '0.0.0.0'); } catch (e) {
        server.off('listening', onListening);
        server.off('error', onError);
        resolve((e && e.message) || String(e));
      }
    };
    try {
      if (typeof server.closeAllConnections === 'function') server.closeAllConnections();
      server.close(bindAgain);
    } catch { bindAgain(); }
  });
}

async function reloadAll(entries, doneType, emptyError) {
  if (entries.length === 0) { post({ type: doneType, ok: false, error: emptyError }); return; }
  let firstError = null;
  const errors = await Promise.all(entries.map(relisten));
  for (const e of errors) if (e && !firstError) firstError = e;
  post({ type: doneType, ok: !firstError, error: firstError });
}

// --- load the script -------------------------------------------------------------------------
let mod;
try {
  mod = require(scriptPath);
} catch (e) {
  post({ type: WorkerMsg.result, action: 'start', ok: false, error: 'require bundle failed: ' + ((e && e.message) || e) });
  process.exit(1);
}
if (mod && typeof mod === 'object' && mod.default && typeof mod.start !== 'function') mod = mod.default;
const hasStart = !!mod && typeof mod.start === 'function';

parentPort.on('message', (msg) => {
  if (!msg) return;
  if (msg.type === LoaderMsg.stop) {
    Promise.resolve()
      .then(() => (mod && typeof mod.stop === 'function' ? mod.stop() : null))
      .catch(() => {})
      .finally(() => process.exit(0));
  } else if (msg.type === LoaderMsg.reload) {
    reloadAll(globalThis._catServers, WorkerMsg.reloaded, 'no-server');
  } else if (msg.type === LoaderMsg.reloadDanmu) {
    reloadAll(globalThis._catDanmuServers, WorkerMsg.reloadedDanmu, 'no-danmu-server');
  }
});

const startInput = startMode === 'ctx' && startArg && typeof startArg === 'object'
  ? { ...startArg, log: (...a) => console.log(`[${name}]`, ...a) }
  : startArg;

if (hasStart) {
  Promise.resolve()
    .then(() => mod.start(startInput))
    .then(() => post({ type: WorkerMsg.result, action: 'start', ok: true }))
    .catch((e) => post({ type: WorkerMsg.result, action: 'start', ok: false, error: (e && e.message) || String(e) }));
} else {
  post({ type: WorkerMsg.result, action: 'start', ok: true });
}

process.on('uncaughtException', (e) => post({ type: WorkerMsg.error, message: (e && e.message) || String(e), stack: e && e.stack }));
process.on('unhandledRejection', (e) => {
  const text = (e && (e.message || e.stack)) || String(e);
  if (/WebAssembly|undici|llhttp/.test(String(text))) return;
  post({ type: WorkerMsg.error, message: String(text) });
});
