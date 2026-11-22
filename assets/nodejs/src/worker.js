'use strict';
/**
 * Worker entry: loads a catpaw / service script inside a worker_thread and gives it the globals the
 * script expects.
 *
 * Observed contract (see ANALYSIS.md section "Node worker contract"):
 *  - workerData: name, scriptPath, configPath, startArg, startMode ('config' | 'ctx'), dataDir, port, dartPort, env,
 *    allowWriteDirs, allowReadDirs, redirectRoot, enableNetLog, enableLog
 *  - env: NODE_PATH=dataDir, DEV_HTTP_PORT=port (or removed), plus caller supplied variables
 *  - globals: catServerFactory(handler), catDartServerPort(), DB_NAME, _catServers, _catDanmuServers
 *  - the script's exported `start(arg)` is awaited, its `stop()` is called on shutdown
 *  - servers listening on 9321 are registered as "danmu" servers so they can be reloaded independently
 */

const { parentPort, workerData } = require('worker_threads');
const http = require('http');
const https = require('https');
const path = require('path');
const Module = require('module');
const { WorkerMsg, LoaderMsg, SUBSCRIPTION_DANMU_PORT } = require('./protocol');
const { createPolicy, installFsPolicy } = require('./sandbox');
const { installJitlessPolyfill } = require('./jitless_polyfill');

const {
  name,
  scriptPath,
  configPath,
  startArg,
  startMode = 'config',
  dataDir,
  port,
  dartPort: initialDartPort,
  dartToken: initialDartToken,
  env,
  allowWriteDirs = [],
  allowReadDirs = [],
  redirectRoot = null,
  enableNetLog = false,
  enableLog = true,
} = workerData || {};
let currentDartPort = initialDartPort || 0;
let currentDartToken = initialDartToken || '';

const LOG_BATCH_MAX = 32;
const LOG_BATCH_MS = 20;
const pendingLogs = [];
let logFlushTimer = null;

function postRaw(message) {
  try { parentPort.postMessage({ name, ...message }); } catch { /* parent already gone */ }
}

function flushLogs() {
  if (logFlushTimer) {
    clearTimeout(logFlushTimer);
    logFlushTimer = null;
  }
  if (pendingLogs.length === 0) return;
  const batch = pendingLogs.splice(0);
  if (batch.length === 1) postRaw({ type: WorkerMsg.log, message: batch[0] });
  else postRaw({ type: WorkerMsg.log, messages: batch });
}

function enqueueLog(line) {
  pendingLogs.push(line);
  if (pendingLogs.length >= LOG_BATCH_MAX) {
    flushLogs();
  } else if (!logFlushTimer) {
    logFlushTimer = setTimeout(flushLogs, LOG_BATCH_MS);
    if (typeof logFlushTimer.unref === 'function') logFlushTimer.unref();
  }
}

function post(message) {
  if (message && message.type === WorkerMsg.log) {
    enqueueLog(message.message);
    return;
  }
  flushLogs();
  postRaw(message);
}

process.on('beforeExit', flushLogs);
process.on('exit', flushLogs);

// --- console -> host log channel -------------------------------------------------------------
const origLog = console.log;
const origErr = console.error;
// With enableLog the line goes to the host once, as [log]. Writing it to stdout as well would forward it a second
// time, because the host also reports the worker's stdout ([stdout] lines).
console.log = (...args) => {
  if (enableLog) enqueueLog(args.map(String).join(' '));
  else origLog(...args);
};
console.error = (...args) => {
  if (enableLog) enqueueLog('[err] ' + args.map(String).join(' '));
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
  installedConfigPath: startMode === 'config' ? configPath : null,
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

// --- automatic Dart callback token injection -------------------------------------------------
function isCurrentDartCallbackTarget(host, targetPort) {
  return currentDartPort > 0 && currentDartToken && isLoopback(host) && Number(targetPort) === currentDartPort;
}

const baseHttpRequest = http.request;
http.request = function callbackAuthedRequest(...args) {
  const req = baseHttpRequest.apply(this, args);
  try {
    const first = args[0];
    let host = '';
    let targetPort = 0;
    if (typeof first === 'string' || first instanceof URL) {
      const u = first instanceof URL ? first : new URL(first, 'http://127.0.0.1');
      host = u.hostname;
      targetPort = Number(u.port) || 80;
    } else if (first && typeof first === 'object') {
      host = first.hostname || (first.host || '').split(':')[0] || '127.0.0.1';
      targetPort = Number(first.port || (first.host && first.host.includes(':') ? first.host.split(':')[1] : 80));
    }
    if (isCurrentDartCallbackTarget(host, targetPort) && !req.getHeader('x-uzv-token')) {
      req.setHeader('x-uzv-token', currentDartToken);
    }
  } catch { /* ignore malformed options */ }
  return req;
};
http.get = function callbackAuthedGet(...args) {
  const req = http.request.apply(this, args);
  req.end();
  return req;
};

installJitlessPolyfill({ http, https });

if (typeof globalThis.fetch === 'function') {
  const baseFetch = globalThis.fetch.bind(globalThis);
  globalThis.fetch = function callbackAuthedFetch(input, init) {
    try {
      const rawUrl = typeof input === 'string' ? input : (input instanceof URL ? input.toString() : (input && input.url));
      if (rawUrl) {
        const u = new URL(rawUrl);
        if (isCurrentDartCallbackTarget(u.hostname, Number(u.port) || 80)) {
          const headers = new Headers((init && init.headers) || (input && input.headers) || undefined);
          if (!headers.has('x-uzv-token')) headers.set('x-uzv-token', currentDartToken);
          return baseFetch(input, { ...(init || {}), headers });
        }
      }
    } catch { /* fall through */ }
    return baseFetch(input, init);
  };
}

// --- server registry & globals ---------------------------------------------------------------
globalThis._catServers = globalThis._catServers || [];
globalThis._catDanmuServers = globalThis._catDanmuServers || [];

const originalCreateServer = http.createServer;
http.createServer = function createServer(...args) {
  const server = originalCreateServer.apply(http, args);
  const originalListen = server.listen;
  server.listen = function listen(...largs) {
    const first = largs[0];
    const rawPort = typeof first === 'number' || typeof first === 'string' ? Number(first)
      : first && typeof first === 'object' && first.port != null ? Number(first.port) : NaN;
    const listenPort = Number.isInteger(rawPort) ? rawPort : null;
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

/** Ports tried above the chosen one when it is taken between the host's check and the script's listen. */
const LISTEN_RETRY_LIMIT = 50;

globalThis.catServerFactory = (handler) => {
  const server = http.createServer(handler);
  let addr = null;
  let retries = 0;
  let allowFallback = true;
  let lastPort = port || 2333;
  let lastHost = '0.0.0.0';
  const originalListen = server.listen;
  server.listen = function listenTracked(...largs) {
    const first = largs[0];
    if (typeof first === 'number') lastPort = first;
    else if (first && typeof first === 'object' && typeof first.port === 'number') lastPort = first.port;
    if (typeof largs[1] === 'string') lastHost = largs[1];
    else if (first && typeof first === 'object' && typeof first.host === 'string') lastHost = first.host;
    return originalListen.apply(server, largs);
  };
  const origEmit = server.emit.bind(server);
  server.emit = function emitWithPortFallback(event, ...args) {
    // The host picked the first free port from 2333 up; if another app took it in the meantime (or during reload after
    // idle socket reclaim), go on upward (2334, 2335, …) instead of failing or picking a random port.
    if (event === 'error' && allowFallback && retries < LISTEN_RETRY_LIMIT && args[0] && args[0].code === 'EADDRINUSE') {
      retries++;
      const next = lastPort + 1;
      process.env.DEV_HTTP_PORT = String(next);
      if (enableLog) {
        post({ type: WorkerMsg.log, message: `[catpaw] port ${lastPort} in use, trying ${next}` });
      }
      try {
        server.listen(next, lastHost);
        return true;
      } catch {
        /* fall through to original error emission */
      }
    }
    return origEmit(event, ...args);
  };
  server.on('listening', () => {
    allowFallback = false;
    retries = 0;
    try {
      const a = server.address();
      if (a && typeof a.port === 'number') {
        addr = { port: a.port, host: a.address };
        process.env.DEV_HTTP_PORT = String(a.port);
        post({ type: WorkerMsg.port, port: a.port });
      }
    } catch { /* ignore */ }
  });
  server.on('error', (e) => post({ type: WorkerMsg.error, message: 'listen error: ' + ((e && e.message) || e) }));
  globalThis._catServers.push({
    server,
    handle: handler,
    getAddr: () => addr,
    prepareRelisten: (withFallback) => { allowFallback = !!withFallback; retries = 0; },
  });
  return server;
};
globalThis.catDartServerPort = () => currentDartPort;
if (!globalThis.DB_NAME) globalThis.DB_NAME = 'default';

// --- reload helpers --------------------------------------------------------------------------
/** Close one registered server (if still listening) and bind it again. Resolves with an error string or null. */
function relisten(entry, { allowPortFallback = false } = {}) {
  return new Promise((resolve) => {
    const addr = entry.getAddr();
    if (!addr) { resolve('no-listened-addr'); return; }
    const server = entry.server;
    if (typeof entry.prepareRelisten === 'function') entry.prepareRelisten(allowPortFallback);
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
    if (!server.listening) {
      bindAgain();
      return;
    }
    try {
      if (typeof server.closeAllConnections === 'function') server.closeAllConnections();
      server.close(() => bindAgain());
    } catch { bindAgain(); }
  });
}

async function reloadAll(entries, doneType, emptyError, opts = {}) {
  if (entries.length === 0) { post({ type: doneType, ok: false, error: emptyError }); return; }
  let firstError = null;
  const errors = await Promise.all(entries.map((entry) => relisten(entry, opts)));
  for (const e of errors) if (e && !firstError) firstError = e;
  post({ type: doneType, ok: !firstError, error: firstError });
}

// Load subscription code only after the worker's file policy is installed.
let startInput = startMode === 'config' && startArg === undefined ? {} : startArg;
if (startMode === 'config' && configPath) {
  try {
    const config = require(configPath);
    startInput = config && typeof config === 'object' && config.default ? config.default : config;
    const keyCount = startInput && typeof startInput === 'object' ? Object.keys(startInput).length : 0;
    post({ type: WorkerMsg.configLoaded, keyCount });
  } catch (e) {
    post({ type: WorkerMsg.result, action: 'start', ok: false, error: 'require config failed: ' + ((e && e.message) || e) });
    process.exit(1);
  }
} else if (startMode === 'ctx' && startArg && typeof startArg === 'object') {
  startInput = { ...startArg, log: (...a) => console.log(`[${name}]`, ...a) };
}

// Upgrade legacy remote CatPaw bundles in memory so outdated hosted scripts work with current pan/site layouts.
function patchLegacyCatpawBundle(src) {
  if (typeof src !== 'string' || !src.includes('function jbe(') || !src.includes('function Cg(')) return src;
  let out = src;
  out = out.replace(
    '[^\\s"\'<>)]*/gi;function jbe(e){let t=[];for(let n of ue().scanPanShares(e))t.push(n.passcode?`${n.url} \\u63D0\\u53D6\\u7801:${n.passcode}`:n.url);let r=mt(e);r("a[href]").each((n,s)=>{let i=String(r(s).attr("href")??"").trim(),o=r(s).parent().text().trim()||r(s).text().trim();i&&ra.test(i)&&t.push(`${o} ${i}`),ra.lastIndex=0});for(let n of e.match(ra)||[])t.push(n);return Array.from(new Set(t))}',
    '[^\\s"\'<>\\\\)]*/gi;function jbe(e){e=String(e??"").replace(/\\\\\\//g,"/").replace(/\\\\"/g,\'"\').replace(/\\\\u0026/gi,"&").replace(/&amp;/gi,"&");let t=[];for(let n of ue().scanPanShares(e)){let u=String(n.url??"").trim().replace(/\\|\\|\\d+$/,"");u&&t.push(n.passcode?`${u} \\u63D0\\u53D6\\u7801:${n.passcode}`:u)}let r=mt(e);r("a[href],[data-url],[data-clipboard-text]").each((n,s)=>{let i=String(r(s).attr("data-url")??r(s).attr("data-clipboard-text")??r(s).attr("href")??"").trim().replace(/\\|\\|\\d+$/,""),o=r(s).parent().text().trim()||r(s).text().trim();i&&ra.test(i)&&t.push(o?`${o} ${i}`:i),ra.lastIndex=0});for(let n of e.match(ra)||[]){let u=n.trim().replace(/\\|\\|\\d+$/,"");u&&t.push(u)}return Array.from(new Set(t))}'
  );
  out = out.replace(
    'function Cg(e,t,r){let n=mt(e),s=new Set,i=[];return n("a[href]").each((o,a)=>{let c=String(n(a).attr("href")??"").trim();if(!c||!r.test(c))return;let u=c;try{u=Yc(t,c),new URL(u)}catch{return}let l=ug(t,u);if(s.has(l))return;',
    'function Cg(e,t,r){let n=mt(e),s=new Set,i=[];if(n("a.block.h-full.flex.flex-col[href]").length>0){n("a.block.h-full.flex.flex-col[href]").each((o,a)=>{let c=String(n(a).attr("href")??"").trim();if(!c)return;let u=c;try{u=Yc(t,c),new URL(u)}catch{return}let l=ug(t,u),f=n(a).find("h3").first().text().replace(/\\s+/g," ").trim();if(!l||!f||!r.test(l)||s.has(l))return;let p=n(a).find("img").first()[0],m=Pr(t,$o(a.attribs,p?.attribs))||fj,g=n(a).find(".tag-container .tag").map((_,x)=>n(x).text().replace(/\\s+/g," ").trim()).get().filter(Boolean).slice(0,2).join(" \\xB7 ");s.add(l),i.push({vod_id:l,vod_name:f,vod_pic:m,vod_remarks:g})});if(i.length>0)return i.slice(0,60)}return n("a[href]").each((o,a)=>{let c=String(n(a).attr("href")??"").trim();if(!c||/^(?:javascript:|#|mailto:|tel:)/i.test(c))return;let u=c;try{u=Yc(t,c),new URL(u)}catch{return}let l=ug(t,u);if((!r.test(c)&&!r.test(l))||s.has(l))return;'
  );
  out = out.replace(
    'let u=c.startsWith("http")?new URL(c).pathname+new URL(c).search:c.startsWith("/")?c:`${e.defaultItemUrlPrefix||"/detail/"}${encodeURIComponent(c)}.html`',
    'let u=c.startsWith("http")?new URL(c).pathname+new URL(c).search:c.startsWith("/")?c:e.defaultItemUrlPrefix==="/"&&/^\\d+$/.test(c)?`/${c}`:`${e.defaultItemUrlPrefix||"/detail/"}${encodeURIComponent(c)}.html`'
  );
  out = out.replace(
    'g=f("h1, .module-info-heading h1, .stui-content__detail .title, title").first().text().replace(/\\s+/g," ").trim()||c',
    'g=f(".x-dbjs-title, h1, .module-info-heading h1, .stui-content__detail .title").first().text().replace(/\\s+/g," ").trim()||f("title").first().text().replace(/\\s+/g," ").trim()||c'
  );
  out = out.replace(
    'y=f(".module-item-pic img, .stui-content__thumb img, article img, img").first()[0]',
    'y=f(".x-dbjs-poster img")[0]||f("#js-poster-img")[0]||f(".module-item-pic img, .stui-content__thumb img")[0]||f("article img")[0]||f("img")[0]'
  );
  out = out.replace(
    'key:"pomo",name:"\\u300C\\u76D8\\u300DPomo",urls:["https://pomo.mom"],classes:[{type_id:"all",type_name:"\\u5168\\u90E8"},{type_id:"huayurm",type_name:"\\u534E\\u8BED\\u70ED\\u95E8"},{type_id:"jiating",type_name:"\\u5BB6\\u5EAD\\u5F71\\u9662"},{type_id:"donghuadadiany",type_name:"\\u52A8\\u753B\\u7535\\u5F71"},{type_id:"dianshiju",type_name:"\\u5267\\u96C6"},{type_id:"paihangbang",type_name:"TOP250"}]',
    'key:"pomo",name:"\\u300C\\u76D8\\u300DPomo",urls:["https://pomo.mom"],classes:[{type_id:"all",type_name:"\\u6700\\u65B0\\u4E0A\\u7EBF"},{type_id:"huayurm",type_name:"\\u534E\\u8BED\\u70ED\\u95E8"},{type_id:"jiating",type_name:"\\u5BB6\\u5EAD\\u5F71\\u9662"},{type_id:"donghuadadiany",type_name:"\\u52A8\\u753B\\u7535\\u5F71"},{type_id:"lengmenjiapian",type_name:"\\u51B7\\u95E8\\u4F73\\u7247"},{type_id:"paihangbang",type_name:"\\u699C\\u5355\\u4F73\\u4F5C"},{type_id:"bluray",type_name:"\\u84DD\\u5149\\u539F\\u76D8"},{type_id:"dianshiju",type_name:"\\u7CBE\\u5F69\\u5267\\u96C6"}]'
  );
  out = out.replace(
    'classes:[{type_id:"1",type_name:"\\u7535\\u5F71"},{type_id:"2",type_name:"\\u5267\\u96C6"},{type_id:"3",type_name:"\\u65E5\\u97E9\\u5267"},{type_id:"4",type_name:"\\u6B27\\u7F8E\\u5267"},{type_id:"15",type_name:"\\u52A8\\u6F2B"}],categoryPath:(e,t)=>`/type/${encodeURIComponent(e)}-${t}.html`,searchPath:(e,t)=>`/search/-------------.html?wd=${encodeURIComponent(e)}&page=${t}`',
    'classes:[{type_id:"1",type_name:"\\u7535\\u5F71"},{type_id:"2",type_name:"\\u5267\\u96C6"},{type_id:"3",type_name:"\\u7EFC\\u827A"},{type_id:"4",type_name:"\\u52A8\\u6F2B"},{type_id:"15",type_name:"\\u65E5\\u97E9\\u5267"},{type_id:"16",type_name:"\\u6B27\\u7F8E\\u5267"}],categoryPath:(e,t)=>`/show/${encodeURIComponent(e)}--------${t}---.html`,searchPath:(e,t)=>`/search/${encodeURIComponent(e)}----------${t}---.html`'
  );
  out = out.replaceAll('["https://pan1.me","https://123panfx.com"]', '["https://123panfx.com","https://pan1.me"]');
  return out;
}

// --- load the script -------------------------------------------------------------------------
let mod;
const fsModule = require('fs');
const resolvedScriptPath = scriptPath ? path.resolve(String(scriptPath)) : '';
let realScriptPath = resolvedScriptPath;
try {
  if (resolvedScriptPath) realScriptPath = fsModule.realpathSync(resolvedScriptPath);
} catch { /* keep resolvedScriptPath */ }
const origModuleCompile = Module.prototype._compile;
Module.prototype._compile = function patchedEntryCompile(content, filename) {
  let matchesEntry = filename === scriptPath || (resolvedScriptPath && path.resolve(filename) === resolvedScriptPath);
  if (!matchesEntry && realScriptPath) {
    try {
      matchesEntry = fsModule.realpathSync(filename) === realScriptPath;
    } catch { /* ignore */ }
  }
  if (matchesEntry) {
    content = patchLegacyCatpawBundle(content);
  }
  return origModuleCompile.call(this, content, filename);
};
try {
  mod = require(scriptPath);
} catch (e) {
  post({ type: WorkerMsg.result, action: 'start', ok: false, error: 'require bundle failed: ' + ((e && e.message) || e) });
  process.exit(1);
} finally {
  Module.prototype._compile = origModuleCompile;
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
    reloadAll(globalThis._catServers, WorkerMsg.reloaded, 'no-server', { allowPortFallback: true });
  } else if (msg.type === LoaderMsg.reloadDanmu) {
    reloadAll(globalThis._catDanmuServers, WorkerMsg.reloadedDanmu, 'no-danmu-server', { allowPortFallback: false });
  } else if (msg.type === LoaderMsg.setDartPort) {
    currentDartPort = Number(msg.port) || 0;
    if (typeof msg.token === 'string') currentDartToken = msg.token;
  }
});

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
