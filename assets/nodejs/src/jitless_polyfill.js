'use strict';
/**
 * Compatibility polyfill for iOS `NodeMobile --jitless`.
 *
 * When V8 starts with `--jitless` (required on iOS without dynamic-codesign JIT entitlements),
 * `globalThis.WebAssembly` is `undefined`. That breaks:
 *   1. Node's built-in `globalThis.fetch` (Undici compiles `llhttp.wasm` via `WebAssembly` and rejects every
 *      request with `TypeError: fetch failed`, `cause: ReferenceError: WebAssembly is not defined`).
 *   2. CatPaw subscription bundles that embed a standalone WebAssembly helper module (URL validation, M3U8
 *      rewriting, HTML stripping, play-group normalization, HMAC, subtitle charset/normalization).
 *
 * When native `WebAssembly` is already present (Android / desktop), `installJitlessPolyfill` is a no-op.
 */

const httpModule = require('http');
const httpsModule = require('https');
const { Readable, Transform } = require('stream');
const zlib = require('zlib');

// --- Native C++ http/https + zlib fetch for --jitless ------------------------------------------

const keepAliveHttpAgent = new httpModule.Agent({ keepAlive: true, maxSockets: 64 });
const keepAliveHttpsAgent = new httpsModule.Agent({ keepAlive: true, maxSockets: 64 });

function makeAbortError(reason) {
  if (reason instanceof Error) return reason;
  if (typeof DOMException === 'function') {
    return new DOMException(reason ? String(reason) : 'This operation was aborted', 'AbortError');
  }
  const err = new Error(reason ? String(reason) : 'This operation was aborted');
  err.name = 'AbortError';
  return err;
}

function makeFetchFailed(cause) {
  const err = new TypeError('fetch failed');
  err.cause = cause;
  return err;
}

/** Handles both RFC 1950 zlib-wrapped deflate and RFC 1951 raw deflate used by legacy CMS servers. */
function createAutoDeflateStream() {
  let inner = null;
  let headBuf = Buffer.alloc(0);
  const attach = (useZlibHeader, initial) => {
    inner = useZlibHeader ? zlib.createInflate() : zlib.createInflateRaw();
    inner.on('data', (chunk) => wrapper.push(chunk));
    inner.on('end', () => wrapper.push(null));
    inner.on('error', (err) => wrapper.destroy(err));
    if (initial.length > 0) inner.write(initial);
  };
  const wrapper = new Transform({
    transform(chunk, _enc, cb) {
      if (inner) {
        inner.write(chunk, cb);
        return;
      }
      headBuf = headBuf.length === 0 ? chunk : Buffer.concat([headBuf, chunk]);
      if (headBuf.length < 2) {
        cb();
        return;
      }
      const b0 = headBuf[0];
      const b1 = headBuf[1];
      const isZlib = (b0 & 0x0f) === 0x08 && (b0 >> 4) <= 7 && (((b0 << 8) | b1) % 31 === 0);
      attach(isZlib, headBuf);
      headBuf = Buffer.alloc(0);
      cb();
    },
    flush(cb) {
      if (!inner) {
        if (headBuf.length === 0) {
          cb();
          return;
        }
        attach(false, headBuf);
        headBuf = Buffer.alloc(0);
      }
      inner.once('end', () => cb());
      inner.end();
    },
  });
  return wrapper;
}

async function normalizeBody(body, headers) {
  if (body == null) return null;
  if (typeof body === 'string') {
    if (!headers.has('content-type')) headers.set('content-type', 'text/plain;charset=UTF-8');
    return Buffer.from(body, 'utf8');
  }
  if (Buffer.isBuffer(body)) return body;
  if (body instanceof ArrayBuffer) return Buffer.from(body);
  if (ArrayBuffer.isView(body)) return Buffer.from(body.buffer, body.byteOffset, body.byteLength);
  if (typeof URLSearchParams === 'function' && body instanceof URLSearchParams) {
    if (!headers.has('content-type')) headers.set('content-type', 'application/x-www-form-urlencoded;charset=UTF-8');
    return Buffer.from(body.toString(), 'utf8');
  }
  if (typeof Blob === 'function' && body instanceof Blob) {
    if (body.type && !headers.has('content-type')) headers.set('content-type', body.type);
    return Buffer.from(await body.arrayBuffer());
  }
  if ((typeof FormData === 'function' && body instanceof FormData) || (body && body[Symbol.toStringTag] === 'FormData')) {
    const serialized = new Response(body);
    const ct = serialized.headers.get('content-type');
    if (ct) headers.set('content-type', ct);
    return Buffer.from(await serialized.arrayBuffer());
  }
  if (typeof body.getReader === 'function' || typeof body[Symbol.asyncIterator] === 'function') {
    const chunks = [];
    for await (const part of body) {
      chunks.push(Buffer.isBuffer(part) ? part : Buffer.from(part));
    }
    return Buffer.concat(chunks);
  }
  return Buffer.from(String(body), 'utf8');
}

function createJitlessFetch({ http = httpModule, https = httpsModule } = {}) {
  const MAX_REDIRECTS = 20;

  return async function jitlessFetch(input, init = {}) {
    let rawUrl;
    let method = 'GET';
    let headersInit;
    let rawBody;
    let redirectMode = 'follow';
    let signal = init && init.signal;

    if (typeof Request === 'function' && input instanceof Request) {
      rawUrl = input.url;
      method = input.method || 'GET';
      headersInit = input.headers;
      redirectMode = input.redirect || 'follow';
      if (!signal) signal = input.signal;
      if (init && init.body !== undefined) rawBody = init.body;
      else if (input.body != null) rawBody = Buffer.from(await input.arrayBuffer());
    } else if (typeof input === 'string') {
      rawUrl = input;
    } else if (input instanceof URL) {
      rawUrl = input.toString();
    } else if (input && typeof input.url === 'string') {
      rawUrl = input.url;
      headersInit = input.headers;
    } else {
      rawUrl = String(input);
    }

    if (init) {
      if (init.method) method = String(init.method);
      if (init.headers !== undefined) headersInit = init.headers;
      if (init.body !== undefined) rawBody = init.body;
      if (init.redirect) redirectMode = init.redirect;
    }
    method = method.toUpperCase();

    if (signal && signal.aborted) {
      throw makeAbortError(signal.reason);
    }

    const reqHeaders = new Headers(headersInit || undefined);
    let bodyBuf = await normalizeBody(rawBody, reqHeaders);
    if ((method === 'GET' || method === 'HEAD') && bodyBuf && bodyBuf.length > 0) {
      throw new TypeError('Request with GET/HEAD method cannot have body');
    }

    let currentUrl;
    try {
      currentUrl = new URL(rawUrl);
    } catch (e) {
      throw new TypeError(`Failed to parse URL from ${rawUrl}`, { cause: e });
    }

    for (let redirects = 0; ; redirects++) {
      if (signal && signal.aborted) throw makeAbortError(signal.reason);

      const isHttps = currentUrl.protocol === 'https:';
      if (!isHttps && currentUrl.protocol !== 'http:') {
        throw makeFetchFailed(new Error(`Unsupported protocol: ${currentUrl.protocol}`));
      }

      const outHeaders = {};
      reqHeaders.forEach((value, key) => {
        outHeaders[key] = value;
      });
      if (typeof reqHeaders.getSetCookie === 'function') {
        const sc = reqHeaders.getSetCookie();
        if (sc.length > 0) outHeaders['set-cookie'] = sc;
      }
      if (!outHeaders.accept) outHeaders.accept = '*/*';
      if (!outHeaders['accept-encoding']) outHeaders['accept-encoding'] = 'gzip, deflate, br';
      if (!outHeaders['user-agent']) outHeaders['user-agent'] = 'node';
      if (bodyBuf != null && outHeaders['content-length'] === undefined) {
        outHeaders['content-length'] = String(bodyBuf.length);
      }
      if (!outHeaders.authorization && (currentUrl.username || currentUrl.password)) {
        const creds = `${decodeURIComponent(currentUrl.username)}:${decodeURIComponent(currentUrl.password)}`;
        outHeaders.authorization = 'Basic ' + Buffer.from(creds, 'utf8').toString('base64');
      }

      const sendOnce = (allowReuseRetry) => new Promise((resolve, reject) => {
        let settled = false;
        const client = isHttps ? https : http;
        const req = client.request(
          {
            protocol: currentUrl.protocol,
            hostname: currentUrl.hostname.replace(/^\[|\]$/g, ''),
            port: currentUrl.port ? Number(currentUrl.port) : (isHttps ? 443 : 80),
            path: (currentUrl.pathname || '/') + (currentUrl.search || ''),
            method,
            headers: outHeaders,
            agent: allowReuseRetry ? (isHttps ? keepAliveHttpsAgent : keepAliveHttpAgent) : false,
          },
          (incoming) => {
            if (settled) {
              incoming.resume();
              return;
            }
            settled = true;
            if (signal) signal.removeEventListener('abort', onAbort);
            resolve(incoming);
          },
        );
        const onAbort = () => {
          if (settled) return;
          settled = true;
          const err = makeAbortError(signal.reason);
          req.destroy(err);
          reject(err);
        };
        if (signal) {
          if (signal.aborted) {
            onAbort();
            return;
          }
          signal.addEventListener('abort', onAbort, { once: true });
        }
        req.on('error', (err) => {
          if (settled) return;
          settled = true;
          if (signal) signal.removeEventListener('abort', onAbort);
          if (signal && signal.aborted) {
            reject(makeAbortError(signal.reason));
          } else if (allowReuseRetry && req.reusedSocket && err && (err.code === 'ECONNRESET' || err.code === 'EPIPE')) {
            sendOnce(false).then(resolve, reject);
          } else {
            reject(makeFetchFailed(err));
          }
        });
        if (bodyBuf != null && bodyBuf.length > 0) req.write(bodyBuf);
        req.end();
      });
      const res = await sendOnce(true);

      const status = res.statusCode || 200;
      const location = res.headers.location;
      const isRedirect = (status === 301 || status === 302 || status === 303 || status === 307 || status === 308) && !!location;

      if (isRedirect && redirectMode !== 'manual') {
        res.resume();
        if (redirectMode === 'error' || redirects >= MAX_REDIRECTS) {
          throw makeFetchFailed(new Error(redirectMode === 'error' ? 'unexpected redirect' : 'redirect count exceeded'));
        }
        const nextUrl = new URL(location, currentUrl);
        if (nextUrl.origin !== currentUrl.origin) {
          reqHeaders.delete('authorization');
          reqHeaders.delete('cookie');
        }
        if (status === 303 || ((status === 301 || status === 302) && method === 'POST')) {
          method = 'GET';
          bodyBuf = null;
          reqHeaders.delete('content-length');
          reqHeaders.delete('content-type');
        }
        currentUrl = nextUrl;
        continue;
      }

      const respHeaders = new Headers();
      for (const [k, v] of Object.entries(res.headers)) {
        if (v === undefined) continue;
        if (Array.isArray(v)) {
          for (const item of v) respHeaders.append(k, item);
        } else {
          respHeaders.set(k, String(v));
        }
      }

      const nullBody = method === 'HEAD' || status === 204 || status === 205 || status === 304;
      let webBody = null;
      if (nullBody) {
        res.resume();
      } else {
        const encoding = (respHeaders.get('content-encoding') || '').trim().toLowerCase();
        let bodyStream = res;
        if (encoding === 'gzip' || encoding === 'x-gzip') {
          respHeaders.delete('content-encoding');
          respHeaders.delete('content-length');
          bodyStream = res.pipe(zlib.createGunzip());
        } else if (encoding === 'deflate') {
          respHeaders.delete('content-encoding');
          respHeaders.delete('content-length');
          bodyStream = res.pipe(createAutoDeflateStream());
        } else if (encoding === 'br') {
          respHeaders.delete('content-encoding');
          respHeaders.delete('content-length');
          bodyStream = res.pipe(zlib.createBrotliDecompress());
        }
        if (signal) {
          const abortBody = () => bodyStream.destroy(makeAbortError(signal.reason));
          if (signal.aborted) abortBody();
          else {
            signal.addEventListener('abort', abortBody, { once: true });
            bodyStream.once('close', () => signal.removeEventListener('abort', abortBody));
          }
        }
        res.on('error', (err) => {
          if (bodyStream !== res) bodyStream.destroy(err);
        });
        webBody = Readable.toWeb(bodyStream);
      }

      const response = new Response(webBody, {
        status,
        statusText: res.statusMessage || '',
        headers: respHeaders,
      });
      const finalUrl = currentUrl.toString();
      const wasRedirected = redirects > 0;
      Object.defineProperty(response, 'url', { value: finalUrl, configurable: true });
      Object.defineProperty(response, 'redirected', { value: wasRedirected, configurable: true });
      return response;
    }
  };
}

// --- Pure-JS WebAssembly 1.0 (+ bulk-memory / sign-ext / sat-trunc) interpreter ----------------

class WasmCompileError extends Error {
  constructor(msg) { super(msg); this.name = 'CompileError'; }
}
class WasmLinkError extends Error {
  constructor(msg) { super(msg); this.name = 'LinkError'; }
}
class WasmRuntimeError extends Error {
  constructor(msg) { super(msg); this.name = 'RuntimeError'; }
}

const PAGE_SIZE = 65536;
const U64_MASK = 0xffffffffffffffffn;
const I64_MIN = -9223372036854775808n;
const I64_MAX = 9223372036854775807n;
const scratchBuf = new ArrayBuffer(8);
const scratchView = new DataView(scratchBuf);

const s64 = (v) => BigInt.asIntN(64, v);
const u64 = (v) => v & U64_MASK;

function popcnt32(x) {
  let v = x - ((x >>> 1) & 0x55555555);
  v = (v & 0x33333333) + ((v >>> 2) & 0x33333333);
  return (((v + (v >>> 4)) & 0x0f0f0f0f) * 0x01010101) >>> 24;
}

function ctz32(x) {
  return x === 0 ? 32 : 31 - Math.clz32(x & -x);
}

function nearestFloat(x) {
  if (!Number.isFinite(x) || x === 0) return x;
  const f = Math.floor(x);
  const d = x - f;
  let r;
  if (d < 0.5) r = f;
  else if (d > 0.5) r = f + 1;
  else r = f % 2 === 0 ? f : f + 1;
  return r === 0 && x < 0 ? -0 : r;
}

function copysignFloat(x, y) {
  const signNeg = y < 0 || Object.is(y, -0);
  const mag = Math.abs(x);
  return signNeg ? -mag : mag;
}

function minFloat(a, b) {
  if (Number.isNaN(a) || Number.isNaN(b)) return NaN;
  if (a === 0 && b === 0) return (Object.is(a, -0) || Object.is(b, -0)) ? -0 : 0;
  return a < b ? a : b;
}

function maxFloat(a, b) {
  if (Number.isNaN(a) || Number.isNaN(b)) return NaN;
  if (a === 0 && b === 0) return (Object.is(a, -0) && Object.is(b, -0)) ? -0 : 0;
  return a > b ? a : b;
}

function defaultVal(vt) {
  if (vt === 0x7e) return 0n;
  if (vt === 0x7f || vt === 0x7d || vt === 0x7c) return 0;
  return null;
}

function toBytes(source) {
  if (source instanceof Uint8Array) return source;
  if (source instanceof ArrayBuffer) return new Uint8Array(source);
  if (ArrayBuffer.isView(source)) return new Uint8Array(source.buffer, source.byteOffset, source.byteLength);
  throw new TypeError('WebAssembly buffer source must be an ArrayBuffer or ArrayBufferView');
}

class WasmMemory {
  constructor(desc) {
    if (!desc || typeof desc !== 'object') throw new TypeError('Memory descriptor must be an object');
    const initial = desc.initial >>> 0;
    const maximum = desc.maximum !== undefined ? desc.maximum >>> 0 : null;
    if (maximum !== null && maximum < initial) throw new RangeError('Memory maximum < initial');
    this._max = maximum;
    this._buf = new ArrayBuffer(initial * PAGE_SIZE);
    this._u8 = new Uint8Array(this._buf);
    this._dv = new DataView(this._buf);
  }
  get buffer() { return this._buf; }
  grow(delta) {
    const d = delta >>> 0;
    const curPages = this._buf.byteLength >>> 16;
    const nextPages = curPages + d;
    if (nextPages > 65536 || (this._max !== null && nextPages > this._max)) {
      throw new RangeError('WebAssembly.Memory.grow(): maximum memory size exceeded');
    }
    if (d === 0) return curPages;
    const nextBuf = new ArrayBuffer(nextPages * PAGE_SIZE);
    const nextU8 = new Uint8Array(nextBuf);
    nextU8.set(this._u8);
    this._buf = nextBuf;
    this._u8 = nextU8;
    this._dv = new DataView(nextBuf);
    return curPages;
  }
}

class WasmTable {
  constructor(desc, initVal = null) {
    if (!desc || typeof desc !== 'object') throw new TypeError('Table descriptor must be an object');
    const initial = desc.initial >>> 0;
    const maximum = desc.maximum !== undefined ? desc.maximum >>> 0 : null;
    if (maximum !== null && maximum < initial) throw new RangeError('Table maximum < initial');
    this._max = maximum;
    this._elems = new Array(initial).fill(initVal);
  }
  get length() { return this._elems.length; }
  get(idx) {
    const i = idx >>> 0;
    if (i >= this._elems.length) throw new RangeError('Table.get out of bounds');
    return this._elems[i];
  }
  set(idx, val) {
    const i = idx >>> 0;
    if (i >= this._elems.length) throw new RangeError('Table.set out of bounds');
    this._elems[i] = val ?? null;
  }
  grow(delta, val = null) {
    const d = delta >>> 0;
    const oldLen = this._elems.length;
    const nextLen = oldLen + d;
    if (this._max !== null && nextLen > this._max) throw new RangeError('Table.grow maximum exceeded');
    for (let i = 0; i < d; i++) this._elems.push(val);
    return oldLen;
  }
}

class WasmGlobal {
  constructor(desc, val) {
    this._type = desc.value;
    this._mut = !!desc.mutable;
    this._val = val !== undefined ? val : (desc.value === 'i64' ? 0n : 0);
  }
  get value() { return this._val; }
  set value(v) {
    if (!this._mut) throw new TypeError('Cannot set immutable WebAssembly.Global');
    this._val = this._type === 'i64' ? s64(BigInt(v)) : (this._type === 'i32' ? v | 0 : Number(v));
  }
}

function parseWasmModule(rawBytes) {
  const bytes = toBytes(rawBytes);
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (bytes.length < 8 || bytes[0] !== 0x00 || bytes[1] !== 0x61 || bytes[2] !== 0x73 || bytes[3] !== 0x6d) {
    throw new WasmCompileError('Invalid WASM magic header');
  }
  if (bytes[4] !== 1 || bytes[5] !== 0 || bytes[6] !== 0 || bytes[7] !== 0) {
    throw new WasmCompileError('Unsupported WASM version');
  }

  let pos = 8;
  const u8 = () => {
    if (pos >= bytes.length) throw new WasmCompileError('Unexpected EOF');
    return bytes[pos++];
  };
  const uleb = () => {
    let res = 0;
    let shift = 0;
    for (let i = 0; i < 5; i++) {
      const b = u8();
      res |= (b & 0x7f) << shift;
      if ((b & 0x80) === 0) return res >>> 0;
      shift += 7;
    }
    throw new WasmCompileError('Invalid uleb128');
  };
  const sleb32 = () => {
    let res = 0;
    let shift = 0;
    let b = 0;
    for (let i = 0; i < 5; i++) {
      b = u8();
      res |= (b & 0x7f) << shift;
      shift += 7;
      if ((b & 0x80) === 0) {
        if (shift < 32 && (b & 0x40) !== 0) res |= (~0 << shift);
        return res | 0;
      }
    }
    throw new WasmCompileError('Invalid sleb32');
  };
  const sleb64 = () => {
    let res = 0n;
    let shift = 0n;
    for (let i = 0; i < 10; i++) {
      const b = u8();
      res |= BigInt(b & 0x7f) << shift;
      shift += 7n;
      if ((b & 0x80) === 0) {
        if (shift < 64n && (b & 0x40) !== 0) res |= (-1n << shift);
        return s64(res);
      }
    }
    throw new WasmCompileError('Invalid sleb64');
  };
  const readStr = () => {
    const len = uleb();
    if (pos + len > bytes.length) throw new WasmCompileError('String out of bounds');
    const s = Buffer.from(bytes.buffer, bytes.byteOffset + pos, len).toString('utf8');
    pos += len;
    return s;
  };
  const readLimits = () => {
    const flags = u8();
    const initial = uleb();
    const maximum = (flags & 0x01) ? uleb() : undefined;
    return { initial, maximum };
  };
  const readInitExpr = () => {
    const expr = [];
    while (true) {
      const op = u8();
      if (op === 0x0b) break;
      if (op === 0x41) expr.push({ op, v: sleb32() });
      else if (op === 0x42) expr.push({ op, v: sleb64() });
      else if (op === 0x43) { const v = dv.getFloat32(pos, true); pos += 4; expr.push({ op, v }); }
      else if (op === 0x44) { const v = dv.getFloat64(pos, true); pos += 8; expr.push({ op, v }); }
      else if (op === 0x23 || op === 0xd2) expr.push({ op, v: uleb() });
      else if (op === 0xd0) expr.push({ op, v: u8() });
      else throw new WasmCompileError(`Unsupported init expr opcode 0x${op.toString(16)}`);
    }
    return expr;
  };

  const types = [];
  const imports = [];
  const funcTypeIdxs = [];
  const tables = [];
  const memories = [];
  const globals = [];
  const exports = [];
  let startFunc = -1;
  const elems = [];
  const codes = [];
  const datas = [];

  while (pos < bytes.length) {
    const secId = u8();
    const secLen = uleb();
    const secEnd = pos + secLen;
    if (secEnd > bytes.length) throw new WasmCompileError('Section out of bounds');

    if (secId === 0 || secId === 12) {
      pos = secEnd;
      continue;
    }
    if (secId === 1) {
      const count = uleb();
      for (let i = 0; i < count; i++) {
        const form = u8();
        if (form !== 0x60) throw new WasmCompileError('Invalid functype form');
        const plen = uleb();
        const params = new Array(plen);
        for (let j = 0; j < plen; j++) params[j] = u8();
        const rlen = uleb();
        const results = new Array(rlen);
        for (let j = 0; j < rlen; j++) results[j] = u8();
        types.push({ params, results });
      }
    } else if (secId === 2) {
      const count = uleb();
      for (let i = 0; i < count; i++) {
        const modName = readStr();
        const name = readStr();
        const kind = u8();
        if (kind === 0) imports.push({ module: modName, name, kind: 'function', typeIdx: uleb() });
        else if (kind === 1) { const et = u8(); imports.push({ module: modName, name, kind: 'table', elemType: et, limits: readLimits() }); }
        else if (kind === 2) imports.push({ module: modName, name, kind: 'memory', limits: readLimits() });
        else if (kind === 3) imports.push({ module: modName, name, kind: 'global', valType: u8(), mutable: u8() === 1 });
        else throw new WasmCompileError(`Unknown import kind ${kind}`);
      }
    } else if (secId === 3) {
      const count = uleb();
      for (let i = 0; i < count; i++) funcTypeIdxs.push(uleb());
    } else if (secId === 4) {
      const count = uleb();
      for (let i = 0; i < count; i++) {
        const elemType = u8();
        tables.push({ elemType, limits: readLimits() });
      }
    } else if (secId === 5) {
      const count = uleb();
      for (let i = 0; i < count; i++) memories.push(readLimits());
    } else if (secId === 6) {
      const count = uleb();
      for (let i = 0; i < count; i++) {
        const valType = u8();
        const mutable = u8() === 1;
        globals.push({ valType, mutable, init: readInitExpr() });
      }
    } else if (secId === 7) {
      const count = uleb();
      for (let i = 0; i < count; i++) {
        const name = readStr();
        const kindByte = u8();
        const index = uleb();
        const kind = kindByte === 0 ? 'function' : kindByte === 1 ? 'table' : kindByte === 2 ? 'memory' : 'global';
        exports.push({ name, kind, index });
      }
    } else if (secId === 8) {
      startFunc = uleb();
    } else if (secId === 9) {
      const count = uleb();
      for (let i = 0; i < count; i++) {
        const flags = uleb();
        const passive = (flags & 1) !== 0;
        const hasTableIdx = flags === 2 || flags === 6;
        const exprMode = (flags & 4) !== 0;
        const tableIdx = hasTableIdx ? uleb() : 0;
        const offset = passive ? null : readInitExpr();
        if (flags === 1 || flags === 2 || flags === 3) u8(); // elemkind
        else if (flags === 5 || flags === 6 || flags === 7) u8(); // reftype
        const n = uleb();
        const items = new Array(n);
        for (let j = 0; j < n; j++) items[j] = exprMode ? readInitExpr() : uleb();
        elems.push({ passive, declarative: (flags & 3) === 3, tableIdx, offset, exprMode, items });
      }
    } else if (secId === 10) {
      const count = uleb();
      for (let i = 0; i < count; i++) {
        const bodyLen = uleb();
        const bodyEnd = pos + bodyLen;
        const localGroups = uleb();
        const locals = [];
        for (let g = 0; g < localGroups; g++) {
          const cnt = uleb();
          const vt = u8();
          for (let k = 0; k < cnt; k++) locals.push(vt);
        }
        const ops = [];
        const immA = [];
        const immB = [];
        const immExtra = [];
        const ctlStack = [];

        while (pos < bodyEnd) {
          const op = u8();
          const idx = ops.length;
          ops.push(op);
          immA.push(0);
          immB.push(0);
          immExtra.push(null);

          if (op === 0x02 || op === 0x03 || op === 0x04) {
            const btByte = bytes[pos];
            let pCnt = 0;
            let rCnt = 0;
            if (btByte === 0x40) { pos++; }
            else if (btByte === 0x7f || btByte === 0x7e || btByte === 0x7d || btByte === 0x7c || btByte === 0x70 || btByte === 0x6f) {
              pos++;
              rCnt = 1;
            } else {
              const tidx = sleb32();
              const ft = types[tidx];
              pCnt = ft.params.length;
              rCnt = ft.results.length;
            }
            immB[idx] = (pCnt << 16) | rCnt;
            ctlStack.push({ op, startIdx: idx, elseIdx: -1 });
          } else if (op === 0x05) {
            const top = ctlStack[ctlStack.length - 1];
            top.elseIdx = idx;
          } else if (op === 0x0b) {
            if (ctlStack.length === 0) {
              // Function end
              break;
            }
            const top = ctlStack.pop();
            const afterEnd = ops.length;
            immA[top.startIdx] = afterEnd;
            if (top.op === 0x04) {
              immExtra[top.startIdx] = top.elseIdx >= 0 ? top.elseIdx + 1 : -1;
              if (top.elseIdx >= 0) immA[top.elseIdx] = afterEnd;
            }
          } else if (op === 0x0c || op === 0x0d || op === 0x10 || (op >= 0x20 && op <= 0x26) || op === 0xd2) {
            immA[idx] = uleb();
          } else if (op === 0x0e) {
            const cnt = uleb();
            const tbl = new Int32Array(cnt + 1);
            for (let k = 0; k <= cnt; k++) tbl[k] = uleb();
            immExtra[idx] = tbl;
          } else if (op === 0x11) {
            immA[idx] = uleb();
            immB[idx] = uleb();
          } else if (op === 0x1c) {
            const cnt = uleb();
            pos += cnt;
          } else if (op >= 0x28 && op <= 0x3e) {
            immB[idx] = uleb(); // align
            immA[idx] = uleb(); // offset
          } else if (op === 0x3f || op === 0x40 || op === 0xd0) {
            immA[idx] = u8();
          } else if (op === 0x41) {
            immA[idx] = sleb32();
          } else if (op === 0x42) {
            immExtra[idx] = sleb64();
          } else if (op === 0x43) {
            immExtra[idx] = dv.getFloat32(pos, true);
            pos += 4;
          } else if (op === 0x44) {
            immExtra[idx] = dv.getFloat64(pos, true);
            pos += 8;
          } else if (op === 0xfc) {
            const sub = uleb();
            immA[idx] = sub;
            if (sub === 8 || sub === 12) { immB[idx] = uleb(); u8(); }
            else if (sub === 9 || sub === 13 || sub === 15 || sub === 16 || sub === 17) { immB[idx] = uleb(); }
            else if (sub === 10) { u8(); u8(); }
            else if (sub === 11) { u8(); }
            else if (sub === 14) { immB[idx] = uleb(); immExtra[idx] = uleb(); }
          } else if (op === 0xfd) {
            throw new WasmCompileError('WASM SIMD (0xfd) is not supported in jitless interpreter');
          }
        }
        pos = bodyEnd;
        codes.push({
          locals,
          ops: Int32Array.from(ops),
          immA: Int32Array.from(immA),
          immB: Int32Array.from(immB),
          immExtra,
        });
      }
    } else if (secId === 11) {
      const count = uleb();
      for (let i = 0; i < count; i++) {
        const mode = uleb();
        let memIdx = 0;
        let offset = null;
        if (mode === 0) offset = readInitExpr();
        else if (mode === 2) { memIdx = uleb(); offset = readInitExpr(); }
        const len = uleb();
        const slice = bytes.slice(pos, pos + len);
        pos += len;
        datas.push({ passive: mode === 1, memIdx, offset, bytes: slice });
      }
    } else {
      pos = secEnd;
    }
  }

  return { types, imports, funcTypeIdxs, tables, memories, globals, exports, startFunc, elems, codes, datas };
}

class WasmModule {
  constructor(bytes) {
    this._ir = parseWasmModule(bytes);
  }
  static imports(mod) {
    return mod._ir.imports.map((i) => ({ module: i.module, name: i.name, kind: i.kind }));
  }
  static exports(mod) {
    return mod._ir.exports.map((e) => ({ name: e.name, kind: e.kind }));
  }
  static customSections() { return []; }
}

class WasmInstance {
  constructor(mod, importObject = {}) {
    if (!(mod instanceof WasmModule)) throw new TypeError('First argument must be a WebAssembly.Module');
    const ir = mod._ir;

    const funcs = [];
    const funcTypes = [];
    const tables = [];
    const memories = [];
    const globalCells = [];

    for (const imp of ir.imports) {
      const ns = importObject && importObject[imp.module];
      if (!ns || !(imp.name in ns)) {
        throw new WasmLinkError(`Missing import ${imp.module}.${imp.name}`);
      }
      const val = ns[imp.name];
      if (imp.kind === 'function') {
        if (typeof val !== 'function') throw new WasmLinkError(`Import ${imp.module}.${imp.name} is not a function`);
        const ft = ir.types[imp.typeIdx];
        funcTypes.push(ft);
        funcs.push({ host: true, type: ft, fn: val });
      } else if (imp.kind === 'table') {
        tables.push(val);
      } else if (imp.kind === 'memory') {
        memories.push(val);
      } else if (imp.kind === 'global') {
        if (val instanceof WasmGlobal) globalCells.push(val);
        else globalCells.push(new WasmGlobal({ value: imp.valType === 0x7e ? 'i64' : 'i32', mutable: imp.mutable }, val));
      }
    }

    for (const t of ir.tables) tables.push(new WasmTable(t.limits));
    for (const m of ir.memories) memories.push(new WasmMemory(m));

    const evalInit = (expr) => {
      let v = 0;
      for (const ins of expr) {
        if (ins.op === 0x41 || ins.op === 0x42 || ins.op === 0x43 || ins.op === 0x44) v = ins.v;
        else if (ins.op === 0x23) v = globalCells[ins.v]._val;
        else if (ins.op === 0xd0) v = null;
        else if (ins.op === 0xd2) v = funcs[ins.v];
      }
      return v;
    };

    const internalOffset = funcs.length;
    for (let i = 0; i < ir.codes.length; i++) {
      const ft = ir.types[ir.funcTypeIdxs[i]];
      funcTypes.push(ft);
      const entry = { host: false, type: ft, code: ir.codes[i], jsWrapper: null };
      funcs.push(entry);
    }

    for (const g of ir.globals) {
      const vtStr = g.valType === 0x7e ? 'i64' : 'i32';
      globalCells.push(new WasmGlobal({ value: vtStr, mutable: g.mutable }, evalInit(g.init)));
    }

    const mem0 = memories[0] || null;
    const dataSegs = ir.datas.map((d) => ({ passive: d.passive, bytes: d.bytes, dropped: false }));
    const elemSegs = ir.elems.map((e) => ({
      passive: e.passive,
      dropped: e.declarative,
      items: e.items.map((it) => (e.exprMode ? evalInit(it) : funcs[it])),
    }));

    // Reusable operand/label stacks across non-reentrant calls (auto-allocated if reentrant)
    let stackBusy = false;
    const sharedValStack = new Array(4096);
    const sharedLblTarget = new Int32Array(512);
    const sharedLblArity = new Int32Array(512);
    const sharedLblBase = new Int32Array(512);
    const sharedLblLoop = new Uint8Array(512);
    let callDepth = 0;

    const invokeInternal = (funcEntry, args) => {
      if (++callDepth > 1024) {
        callDepth--;
        throw new WasmRuntimeError('call stack exhausted');
      }
      const useShared = !stackBusy;
      if (useShared) stackBusy = true;
      const valStack = useShared ? sharedValStack : new Array(1024);
      const lblTarget = useShared ? sharedLblTarget : new Int32Array(256);
      const lblArity = useShared ? sharedLblArity : new Int32Array(256);
      const lblBase = useShared ? sharedLblBase : new Int32Array(256);
      const lblLoop = useShared ? sharedLblLoop : new Uint8Array(256);

      try {
        const { type, code } = funcEntry;
        const pLen = type.params.length;
        const lTypes = code.locals;
        const locals = new Array(pLen + lTypes.length);
        for (let i = 0; i < pLen; i++) locals[i] = args[i];
        for (let i = 0; i < lTypes.length; i++) locals[pLen + i] = defaultVal(lTypes[i]);

        const { ops, immA, immB, immExtra } = code;
        const opsLen = ops.length;
        let sp = 0;
        let lp = 0;
        let pc = 0;

        const doBranch = (depth) => {
          const idx = lp - 1 - depth;
          if (idx < 0) return -1; // return from function
          const arity = lblArity[idx];
          const base = lblBase[idx];
          if (arity > 0) {
            const srcStart = sp - arity;
            for (let k = 0; k < arity; k++) valStack[base + k] = valStack[srcStart + k];
          }
          sp = base + arity;
          const target = lblTarget[idx];
          if (lblLoop[idx]) lp = idx + 1;
          else lp = idx;
          return target;
        };

        const checkMem = (ptr, offset, size) => {
          const ea = (ptr >>> 0) + (offset >>> 0);
          if (!mem0 || ea + size > mem0._buf.byteLength) {
            throw new WasmRuntimeError('memory access out of bounds');
          }
          return ea;
        };

        while (pc < opsLen) {
          const op = ops[pc];
          const a = immA[pc];
          pc++;

          switch (op) {
            case 0x00: throw new WasmRuntimeError('unreachable');
            case 0x01: break;
            case 0x02: { // block
              const b = immB[pc - 1];
              lblTarget[lp] = a;
              lblArity[lp] = b & 0xffff;
              lblBase[lp] = sp - (b >>> 16);
              lblLoop[lp] = 0;
              lp++;
              break;
            }
            case 0x03: { // loop
              const b = immB[pc - 1];
              lblTarget[lp] = pc;
              lblArity[lp] = b >>> 16;
              lblBase[lp] = sp - (b >>> 16);
              lblLoop[lp] = 1;
              lp++;
              break;
            }
            case 0x04: { // if
              const cond = valStack[--sp];
              const b = immB[pc - 1];
              if (cond !== 0) {
                lblTarget[lp] = a;
                lblArity[lp] = b & 0xffff;
                lblBase[lp] = sp - (b >>> 16);
                lblLoop[lp] = 0;
                lp++;
              } else {
                const elseTarget = immExtra[pc - 1];
                if (elseTarget >= 0) {
                  lblTarget[lp] = a;
                  lblArity[lp] = b & 0xffff;
                  lblBase[lp] = sp - (b >>> 16);
                  lblLoop[lp] = 0;
                  lp++;
                  pc = elseTarget;
                } else {
                  pc = a;
                }
              }
              break;
            }
            case 0x05: { // else (reached from end of `then` branch)
              lp--;
              pc = a;
              break;
            }
            case 0x0b: { // end
              if (lp === 0) pc = opsLen;
              else lp--;
              break;
            }
            case 0x0c: { // br
              const nextPc = doBranch(a);
              if (nextPc < 0) pc = opsLen;
              else pc = nextPc;
              break;
            }
            case 0x0d: { // br_if
              if (valStack[--sp] !== 0) {
                const nextPc = doBranch(a);
                if (nextPc < 0) pc = opsLen;
                else pc = nextPc;
              }
              break;
            }
            case 0x0e: { // br_table
              const idxVal = valStack[--sp] >>> 0;
              const tbl = immExtra[pc - 1];
              const depth = idxVal < tbl.length - 1 ? tbl[idxVal] : tbl[tbl.length - 1];
              const nextPc = doBranch(depth);
              if (nextPc < 0) pc = opsLen;
              else pc = nextPc;
              break;
            }
            case 0x0f: // return
              pc = opsLen;
              break;
            case 0x10: { // call
              const callee = funcs[a];
              const cpl = callee.type.params.length;
              const callArgs = new Array(cpl);
              sp -= cpl;
              for (let k = 0; k < cpl; k++) callArgs[k] = valStack[sp + k];
              const res = callee.host ? callHost(callee, callArgs) : invokeInternal(callee, callArgs);
              const crl = callee.type.results.length;
              if (crl === 1) valStack[sp++] = res;
              else if (crl > 1) for (let k = 0; k < crl; k++) valStack[sp++] = res[k];
              break;
            }
            case 0x11: { // call_indirect
              const elemIdx = valStack[--sp] >>> 0;
              const tbl = tables[immB[pc - 1]];
              if (!tbl || elemIdx >= tbl._elems.length) throw new WasmRuntimeError('undefined element');
              const callee = tbl._elems[elemIdx];
              if (!callee) throw new WasmRuntimeError('uninitialized element');
              const expType = ir.types[a];
              if (!sameFuncType(callee.type, expType)) throw new WasmRuntimeError('indirect call type mismatch');
              const cpl = expType.params.length;
              const callArgs = new Array(cpl);
              sp -= cpl;
              for (let k = 0; k < cpl; k++) callArgs[k] = valStack[sp + k];
              const res = callee.host ? callHost(callee, callArgs) : invokeInternal(callee, callArgs);
              const crl = expType.results.length;
              if (crl === 1) valStack[sp++] = res;
              else if (crl > 1) for (let k = 0; k < crl; k++) valStack[sp++] = res[k];
              break;
            }
            case 0x1a: sp--; break; // drop
            case 0x1b:
            case 0x1c: { // select
              const c = valStack[--sp];
              const v2 = valStack[--sp];
              const v1 = valStack[--sp];
              valStack[sp++] = c !== 0 ? v1 : v2;
              break;
            }
            case 0x20: valStack[sp++] = locals[a]; break;
            case 0x21: locals[a] = valStack[--sp]; break;
            case 0x22: locals[a] = valStack[sp - 1]; break;
            case 0x23: valStack[sp++] = globalCells[a]._val; break;
            case 0x24: globalCells[a]._val = valStack[--sp]; break;
            case 0x25: valStack[sp++] = tables[a].get(valStack[--sp]); break;
            case 0x26: { const v = valStack[--sp]; const i = valStack[--sp]; tables[a].set(i, v); break; }

            // Memory loads
            case 0x28: valStack[sp - 1] = mem0._dv.getInt32(checkMem(valStack[sp - 1], a, 4), true); break;
            case 0x29: valStack[sp - 1] = mem0._dv.getBigInt64(checkMem(valStack[sp - 1], a, 8), true); break;
            case 0x2a: valStack[sp - 1] = mem0._dv.getFloat32(checkMem(valStack[sp - 1], a, 4), true); break;
            case 0x2b: valStack[sp - 1] = mem0._dv.getFloat64(checkMem(valStack[sp - 1], a, 8), true); break;
            case 0x2c: valStack[sp - 1] = mem0._dv.getInt8(checkMem(valStack[sp - 1], a, 1)); break;
            case 0x2d: valStack[sp - 1] = mem0._u8[checkMem(valStack[sp - 1], a, 1)]; break;
            case 0x2e: valStack[sp - 1] = mem0._dv.getInt16(checkMem(valStack[sp - 1], a, 2), true); break;
            case 0x2f: valStack[sp - 1] = mem0._dv.getUint16(checkMem(valStack[sp - 1], a, 2), true); break;
            case 0x30: valStack[sp - 1] = BigInt(mem0._dv.getInt8(checkMem(valStack[sp - 1], a, 1))); break;
            case 0x31: valStack[sp - 1] = BigInt(mem0._u8[checkMem(valStack[sp - 1], a, 1)]); break;
            case 0x32: valStack[sp - 1] = BigInt(mem0._dv.getInt16(checkMem(valStack[sp - 1], a, 2), true)); break;
            case 0x33: valStack[sp - 1] = BigInt(mem0._dv.getUint16(checkMem(valStack[sp - 1], a, 2), true)); break;
            case 0x34: valStack[sp - 1] = BigInt(mem0._dv.getInt32(checkMem(valStack[sp - 1], a, 4), true)); break;
            case 0x35: valStack[sp - 1] = BigInt(mem0._dv.getUint32(checkMem(valStack[sp - 1], a, 4), true)); break;

            // Memory stores
            case 0x36: { const v = valStack[--sp]; const p = valStack[--sp]; mem0._dv.setInt32(checkMem(p, a, 4), v, true); break; }
            case 0x37: { const v = valStack[--sp]; const p = valStack[--sp]; mem0._dv.setBigInt64(checkMem(p, a, 8), v, true); break; }
            case 0x38: { const v = valStack[--sp]; const p = valStack[--sp]; mem0._dv.setFloat32(checkMem(p, a, 4), v, true); break; }
            case 0x39: { const v = valStack[--sp]; const p = valStack[--sp]; mem0._dv.setFloat64(checkMem(p, a, 8), v, true); break; }
            case 0x3a: { const v = valStack[--sp]; const p = valStack[--sp]; mem0._u8[checkMem(p, a, 1)] = v & 0xff; break; }
            case 0x3b: { const v = valStack[--sp]; const p = valStack[--sp]; mem0._dv.setUint16(checkMem(p, a, 2), v & 0xffff, true); break; }
            case 0x3c: { const v = valStack[--sp]; const p = valStack[--sp]; mem0._u8[checkMem(p, a, 1)] = Number(v & 0xffn); break; }
            case 0x3d: { const v = valStack[--sp]; const p = valStack[--sp]; mem0._dv.setUint16(checkMem(p, a, 2), Number(v & 0xffffn), true); break; }
            case 0x3e: { const v = valStack[--sp]; const p = valStack[--sp]; mem0._dv.setUint32(checkMem(p, a, 4), Number(v & 0xffffffffn), true); break; }

            case 0x3f: valStack[sp++] = mem0._buf.byteLength >>> 16; break;
            case 0x40: {
              const delta = valStack[sp - 1] >>> 0;
              try { valStack[sp - 1] = mem0.grow(delta); } catch { valStack[sp - 1] = -1; }
              break;
            }

            // Constants
            case 0x41: valStack[sp++] = a; break;
            case 0x42: valStack[sp++] = immExtra[pc - 1]; break;
            case 0x43: valStack[sp++] = immExtra[pc - 1]; break;
            case 0x44: valStack[sp++] = immExtra[pc - 1]; break;

            // i32 comparisons
            case 0x45: valStack[sp - 1] = valStack[sp - 1] === 0 ? 1 : 0; break;
            case 0x46: { const r = valStack[--sp]; valStack[sp - 1] = (valStack[sp - 1] | 0) === (r | 0) ? 1 : 0; break; }
            case 0x47: { const r = valStack[--sp]; valStack[sp - 1] = (valStack[sp - 1] | 0) !== (r | 0) ? 1 : 0; break; }
            case 0x48: { const r = valStack[--sp]; valStack[sp - 1] = (valStack[sp - 1] | 0) < (r | 0) ? 1 : 0; break; }
            case 0x49: { const r = valStack[--sp]; valStack[sp - 1] = (valStack[sp - 1] >>> 0) < (r >>> 0) ? 1 : 0; break; }
            case 0x4a: { const r = valStack[--sp]; valStack[sp - 1] = (valStack[sp - 1] | 0) > (r | 0) ? 1 : 0; break; }
            case 0x4b: { const r = valStack[--sp]; valStack[sp - 1] = (valStack[sp - 1] >>> 0) > (r >>> 0) ? 1 : 0; break; }
            case 0x4c: { const r = valStack[--sp]; valStack[sp - 1] = (valStack[sp - 1] | 0) <= (r | 0) ? 1 : 0; break; }
            case 0x4d: { const r = valStack[--sp]; valStack[sp - 1] = (valStack[sp - 1] >>> 0) <= (r >>> 0) ? 1 : 0; break; }
            case 0x4e: { const r = valStack[--sp]; valStack[sp - 1] = (valStack[sp - 1] | 0) >= (r | 0) ? 1 : 0; break; }
            case 0x4f: { const r = valStack[--sp]; valStack[sp - 1] = (valStack[sp - 1] >>> 0) >= (r >>> 0) ? 1 : 0; break; }

            // i64 comparisons
            case 0x50: valStack[sp - 1] = valStack[sp - 1] === 0n ? 1 : 0; break;
            case 0x51: { const r = valStack[--sp]; valStack[sp - 1] = valStack[sp - 1] === r ? 1 : 0; break; }
            case 0x52: { const r = valStack[--sp]; valStack[sp - 1] = valStack[sp - 1] !== r ? 1 : 0; break; }
            case 0x53: { const r = valStack[--sp]; valStack[sp - 1] = valStack[sp - 1] < r ? 1 : 0; break; }
            case 0x54: { const r = valStack[--sp]; valStack[sp - 1] = u64(valStack[sp - 1]) < u64(r) ? 1 : 0; break; }
            case 0x55: { const r = valStack[--sp]; valStack[sp - 1] = valStack[sp - 1] > r ? 1 : 0; break; }
            case 0x56: { const r = valStack[--sp]; valStack[sp - 1] = u64(valStack[sp - 1]) > u64(r) ? 1 : 0; break; }
            case 0x57: { const r = valStack[--sp]; valStack[sp - 1] = valStack[sp - 1] <= r ? 1 : 0; break; }
            case 0x58: { const r = valStack[--sp]; valStack[sp - 1] = u64(valStack[sp - 1]) <= u64(r) ? 1 : 0; break; }
            case 0x59: { const r = valStack[--sp]; valStack[sp - 1] = valStack[sp - 1] >= r ? 1 : 0; break; }
            case 0x5a: { const r = valStack[--sp]; valStack[sp - 1] = u64(valStack[sp - 1]) >= u64(r) ? 1 : 0; break; }

            // f32 / f64 comparisons
            case 0x5b: case 0x61: { const r = valStack[--sp]; valStack[sp - 1] = valStack[sp - 1] === r ? 1 : 0; break; }
            case 0x5c: case 0x62: { const r = valStack[--sp]; valStack[sp - 1] = valStack[sp - 1] !== r ? 1 : 0; break; }
            case 0x5d: case 0x63: { const r = valStack[--sp]; valStack[sp - 1] = valStack[sp - 1] < r ? 1 : 0; break; }
            case 0x5e: case 0x64: { const r = valStack[--sp]; valStack[sp - 1] = valStack[sp - 1] > r ? 1 : 0; break; }
            case 0x5f: case 0x65: { const r = valStack[--sp]; valStack[sp - 1] = valStack[sp - 1] <= r ? 1 : 0; break; }
            case 0x60: case 0x66: { const r = valStack[--sp]; valStack[sp - 1] = valStack[sp - 1] >= r ? 1 : 0; break; }

            // i32 numeric
            case 0x67: valStack[sp - 1] = Math.clz32(valStack[sp - 1]); break;
            case 0x68: valStack[sp - 1] = ctz32(valStack[sp - 1]); break;
            case 0x69: valStack[sp - 1] = popcnt32(valStack[sp - 1]); break;
            case 0x6a: { const r = valStack[--sp]; valStack[sp - 1] = (valStack[sp - 1] + r) | 0; break; }
            case 0x6b: { const r = valStack[--sp]; valStack[sp - 1] = (valStack[sp - 1] - r) | 0; break; }
            case 0x6c: { const r = valStack[--sp]; valStack[sp - 1] = Math.imul(valStack[sp - 1], r); break; }
            case 0x6d: {
              const r = valStack[--sp] | 0;
              const l = valStack[sp - 1] | 0;
              if (r === 0) throw new WasmRuntimeError('integer divide by zero');
              if (l === -2147483648 && r === -1) throw new WasmRuntimeError('integer overflow');
              valStack[sp - 1] = (l / r) | 0;
              break;
            }
            case 0x6e: {
              const r = valStack[--sp] >>> 0;
              const l = valStack[sp - 1] >>> 0;
              if (r === 0) throw new WasmRuntimeError('integer divide by zero');
              valStack[sp - 1] = ((l / r) >>> 0) | 0;
              break;
            }
            case 0x6f: {
              const r = valStack[--sp] | 0;
              const l = valStack[sp - 1] | 0;
              if (r === 0) throw new WasmRuntimeError('integer divide by zero');
              valStack[sp - 1] = l === -2147483648 && r === -1 ? 0 : (l % r) | 0;
              break;
            }
            case 0x70: {
              const r = valStack[--sp] >>> 0;
              const l = valStack[sp - 1] >>> 0;
              if (r === 0) throw new WasmRuntimeError('integer divide by zero');
              valStack[sp - 1] = ((l % r) >>> 0) | 0;
              break;
            }
            case 0x71: { const r = valStack[--sp]; valStack[sp - 1] &= r; break; }
            case 0x72: { const r = valStack[--sp]; valStack[sp - 1] |= r; break; }
            case 0x73: { const r = valStack[--sp]; valStack[sp - 1] ^= r; break; }
            case 0x74: { const r = valStack[--sp]; valStack[sp - 1] = valStack[sp - 1] << (r & 31); break; }
            case 0x75: { const r = valStack[--sp]; valStack[sp - 1] = valStack[sp - 1] >> (r & 31); break; }
            case 0x76: { const r = valStack[--sp]; valStack[sp - 1] = (valStack[sp - 1] >>> (r & 31)) | 0; break; }
            case 0x77: {
              const k = valStack[--sp] & 31;
              const v = valStack[sp - 1];
              valStack[sp - 1] = k === 0 ? v | 0 : ((v << k) | (v >>> (32 - k))) | 0;
              break;
            }
            case 0x78: {
              const k = valStack[--sp] & 31;
              const v = valStack[sp - 1];
              valStack[sp - 1] = k === 0 ? v | 0 : ((v >>> k) | (v << (32 - k))) | 0;
              break;
            }

            // i64 numeric
            case 0x79: {
              const u = u64(valStack[sp - 1]);
              const hi = Number(u >> 32n);
              valStack[sp - 1] = BigInt(hi !== 0 ? Math.clz32(hi) : 32 + Math.clz32(Number(u & 0xffffffffn)));
              break;
            }
            case 0x7a: {
              const u = u64(valStack[sp - 1]);
              const lo = Number(u & 0xffffffffn);
              valStack[sp - 1] = BigInt(lo !== 0 ? ctz32(lo) : 32 + ctz32(Number(u >> 32n)));
              break;
            }
            case 0x7b: {
              const u = u64(valStack[sp - 1]);
              valStack[sp - 1] = BigInt(popcnt32(Number(u & 0xffffffffn)) + popcnt32(Number(u >> 32n)));
              break;
            }
            case 0x7c: { const r = valStack[--sp]; valStack[sp - 1] = s64(valStack[sp - 1] + r); break; }
            case 0x7d: { const r = valStack[--sp]; valStack[sp - 1] = s64(valStack[sp - 1] - r); break; }
            case 0x7e: { const r = valStack[--sp]; valStack[sp - 1] = s64(valStack[sp - 1] * r); break; }
            case 0x7f: {
              const r = valStack[--sp];
              const l = valStack[sp - 1];
              if (r === 0n) throw new WasmRuntimeError('integer divide by zero');
              if (l === I64_MIN && r === -1n) throw new WasmRuntimeError('integer overflow');
              valStack[sp - 1] = s64(l / r);
              break;
            }
            case 0x80: {
              const r = u64(valStack[--sp]);
              const l = u64(valStack[sp - 1]);
              if (r === 0n) throw new WasmRuntimeError('integer divide by zero');
              valStack[sp - 1] = s64(l / r);
              break;
            }
            case 0x81: {
              const r = valStack[--sp];
              const l = valStack[sp - 1];
              if (r === 0n) throw new WasmRuntimeError('integer divide by zero');
              valStack[sp - 1] = l === I64_MIN && r === -1n ? 0n : s64(l % r);
              break;
            }
            case 0x82: {
              const r = u64(valStack[--sp]);
              const l = u64(valStack[sp - 1]);
              if (r === 0n) throw new WasmRuntimeError('integer divide by zero');
              valStack[sp - 1] = s64(l % r);
              break;
            }
            case 0x83: { const r = valStack[--sp]; valStack[sp - 1] = s64(valStack[sp - 1] & r); break; }
            case 0x84: { const r = valStack[--sp]; valStack[sp - 1] = s64(valStack[sp - 1] | r); break; }
            case 0x85: { const r = valStack[--sp]; valStack[sp - 1] = s64(valStack[sp - 1] ^ r); break; }
            case 0x86: { const r = valStack[--sp] & 63n; valStack[sp - 1] = s64(valStack[sp - 1] << r); break; }
            case 0x87: { const r = valStack[--sp] & 63n; valStack[sp - 1] = s64(valStack[sp - 1] >> r); break; }
            case 0x88: { const r = valStack[--sp] & 63n; valStack[sp - 1] = s64(u64(valStack[sp - 1]) >> r); break; }
            case 0x89: {
              const k = valStack[--sp] & 63n;
              const u = u64(valStack[sp - 1]);
              valStack[sp - 1] = k === 0n ? s64(u) : s64(((u << k) & U64_MASK) | (u >> (64n - k)));
              break;
            }
            case 0x8a: {
              const k = valStack[--sp] & 63n;
              const u = u64(valStack[sp - 1]);
              valStack[sp - 1] = k === 0n ? s64(u) : s64((u >> k) | ((u << (64n - k)) & U64_MASK));
              break;
            }

            // f32 numeric
            case 0x8b: valStack[sp - 1] = Math.abs(valStack[sp - 1]); break;
            case 0x8c: valStack[sp - 1] = -valStack[sp - 1]; break;
            case 0x8d: valStack[sp - 1] = Math.fround(Math.ceil(valStack[sp - 1])); break;
            case 0x8e: valStack[sp - 1] = Math.fround(Math.floor(valStack[sp - 1])); break;
            case 0x8f: valStack[sp - 1] = Math.fround(Math.trunc(valStack[sp - 1])); break;
            case 0x90: valStack[sp - 1] = Math.fround(nearestFloat(valStack[sp - 1])); break;
            case 0x91: valStack[sp - 1] = Math.fround(Math.sqrt(valStack[sp - 1])); break;
            case 0x92: { const r = valStack[--sp]; valStack[sp - 1] = Math.fround(valStack[sp - 1] + r); break; }
            case 0x93: { const r = valStack[--sp]; valStack[sp - 1] = Math.fround(valStack[sp - 1] - r); break; }
            case 0x94: { const r = valStack[--sp]; valStack[sp - 1] = Math.fround(valStack[sp - 1] * r); break; }
            case 0x95: { const r = valStack[--sp]; valStack[sp - 1] = Math.fround(valStack[sp - 1] / r); break; }
            case 0x96: { const r = valStack[--sp]; valStack[sp - 1] = Math.fround(minFloat(valStack[sp - 1], r)); break; }
            case 0x97: { const r = valStack[--sp]; valStack[sp - 1] = Math.fround(maxFloat(valStack[sp - 1], r)); break; }
            case 0x98: { const r = valStack[--sp]; valStack[sp - 1] = Math.fround(copysignFloat(valStack[sp - 1], r)); break; }

            // f64 numeric
            case 0x99: valStack[sp - 1] = Math.abs(valStack[sp - 1]); break;
            case 0x9a: valStack[sp - 1] = -valStack[sp - 1]; break;
            case 0x9b: valStack[sp - 1] = Math.ceil(valStack[sp - 1]); break;
            case 0x9c: valStack[sp - 1] = Math.floor(valStack[sp - 1]); break;
            case 0x9d: valStack[sp - 1] = Math.trunc(valStack[sp - 1]); break;
            case 0x9e: valStack[sp - 1] = nearestFloat(valStack[sp - 1]); break;
            case 0x9f: valStack[sp - 1] = Math.sqrt(valStack[sp - 1]); break;
            case 0xa0: { const r = valStack[--sp]; valStack[sp - 1] = valStack[sp - 1] + r; break; }
            case 0xa1: { const r = valStack[--sp]; valStack[sp - 1] = valStack[sp - 1] - r; break; }
            case 0xa2: { const r = valStack[--sp]; valStack[sp - 1] = valStack[sp - 1] * r; break; }
            case 0xa3: { const r = valStack[--sp]; valStack[sp - 1] = valStack[sp - 1] / r; break; }
            case 0xa4: { const r = valStack[--sp]; valStack[sp - 1] = minFloat(valStack[sp - 1], r); break; }
            case 0xa5: { const r = valStack[--sp]; valStack[sp - 1] = maxFloat(valStack[sp - 1], r); break; }
            case 0xa6: { const r = valStack[--sp]; valStack[sp - 1] = copysignFloat(valStack[sp - 1], r); break; }

            // Conversions
            case 0xa7: valStack[sp - 1] = Number(valStack[sp - 1] & 0xffffffffn) | 0; break;
            case 0xa8: case 0xaa: {
              const t = Math.trunc(valStack[sp - 1]);
              if (Number.isNaN(t) || t < -2147483648 || t > 2147483647) throw new WasmRuntimeError('invalid conversion to integer');
              valStack[sp - 1] = t | 0;
              break;
            }
            case 0xa9: case 0xab: {
              const t = Math.trunc(valStack[sp - 1]);
              if (Number.isNaN(t) || t < 0 || t > 4294967295) throw new WasmRuntimeError('invalid conversion to integer');
              valStack[sp - 1] = (t >>> 0) | 0;
              break;
            }
            case 0xac: valStack[sp - 1] = BigInt(valStack[sp - 1] | 0); break;
            case 0xad: valStack[sp - 1] = BigInt(valStack[sp - 1] >>> 0); break;
            case 0xae: case 0xb0: {
              const v = valStack[sp - 1];
              if (!Number.isFinite(v) || v < -9223372036854775808.0 || v >= 9223372036854775808.0) {
                throw new WasmRuntimeError('invalid conversion to integer');
              }
              valStack[sp - 1] = s64(BigInt(Math.trunc(v)));
              break;
            }
            case 0xaf: case 0xb1: {
              const v = valStack[sp - 1];
              if (!Number.isFinite(v) || v <= -1.0 || v >= 18446744073709551616.0) {
                throw new WasmRuntimeError('invalid conversion to integer');
              }
              valStack[sp - 1] = s64(BigInt(Math.trunc(v)));
              break;
            }
            case 0xb2: valStack[sp - 1] = Math.fround(valStack[sp - 1] | 0); break;
            case 0xb3: valStack[sp - 1] = Math.fround(valStack[sp - 1] >>> 0); break;
            case 0xb4: valStack[sp - 1] = Math.fround(Number(valStack[sp - 1])); break;
            case 0xb5: valStack[sp - 1] = Math.fround(Number(u64(valStack[sp - 1]))); break;
            case 0xb6: valStack[sp - 1] = Math.fround(valStack[sp - 1]); break;
            case 0xb7: valStack[sp - 1] = Number(valStack[sp - 1] | 0); break;
            case 0xb8: valStack[sp - 1] = Number(valStack[sp - 1] >>> 0); break;
            case 0xb9: valStack[sp - 1] = Number(valStack[sp - 1]); break;
            case 0xba: valStack[sp - 1] = Number(u64(valStack[sp - 1])); break;
            case 0xbb: valStack[sp - 1] = Number(valStack[sp - 1]); break;

            // Reinterpretations
            case 0xbc: scratchView.setFloat32(0, valStack[sp - 1], true); valStack[sp - 1] = scratchView.getInt32(0, true); break;
            case 0xbd: scratchView.setFloat64(0, valStack[sp - 1], true); valStack[sp - 1] = scratchView.getBigInt64(0, true); break;
            case 0xbe: scratchView.setInt32(0, valStack[sp - 1], true); valStack[sp - 1] = scratchView.getFloat32(0, true); break;
            case 0xbf: scratchView.setBigInt64(0, valStack[sp - 1], true); valStack[sp - 1] = scratchView.getFloat64(0, true); break;

            // Sign extensions
            case 0xc0: valStack[sp - 1] = (valStack[sp - 1] << 24) >> 24; break;
            case 0xc1: valStack[sp - 1] = (valStack[sp - 1] << 16) >> 16; break;
            case 0xc2: valStack[sp - 1] = BigInt.asIntN(8, valStack[sp - 1]); break;
            case 0xc3: valStack[sp - 1] = BigInt.asIntN(16, valStack[sp - 1]); break;
            case 0xc4: valStack[sp - 1] = BigInt.asIntN(32, valStack[sp - 1]); break;

            // Reference instructions
            case 0xd0: valStack[sp++] = null; break;
            case 0xd1: valStack[sp - 1] = valStack[sp - 1] === null ? 1 : 0; break;
            case 0xd2: valStack[sp++] = funcs[a]; break;

            // 0xfc prefix (saturating truncations + bulk memory/table)
            case 0xfc: {
              const b = immB[pc - 1];
              if (a === 0 || a === 2) { // i32.trunc_sat_f32_s / f64_s
                const v = valStack[sp - 1];
                if (Number.isNaN(v)) valStack[sp - 1] = 0;
                else if (v <= -2147483648.0) valStack[sp - 1] = -2147483648;
                else if (v >= 2147483647.0) valStack[sp - 1] = 2147483647;
                else valStack[sp - 1] = Math.trunc(v) | 0;
              } else if (a === 1 || a === 3) { // i32.trunc_sat_f32_u / f64_u
                const v = valStack[sp - 1];
                if (Number.isNaN(v) || v <= 0.0) valStack[sp - 1] = 0;
                else if (v >= 4294967295.0) valStack[sp - 1] = -1;
                else valStack[sp - 1] = (Math.trunc(v) >>> 0) | 0;
              } else if (a === 4 || a === 6) { // i64.trunc_sat_f32_s / f64_s
                const v = valStack[sp - 1];
                if (Number.isNaN(v)) valStack[sp - 1] = 0n;
                else if (v <= -9223372036854775808.0) valStack[sp - 1] = I64_MIN;
                else if (v >= 9223372036854775808.0) valStack[sp - 1] = I64_MAX;
                else valStack[sp - 1] = s64(BigInt(Math.trunc(v)));
              } else if (a === 5 || a === 7) { // i64.trunc_sat_f32_u / f64_u
                const v = valStack[sp - 1];
                if (Number.isNaN(v) || v <= 0.0) valStack[sp - 1] = 0n;
                else if (v >= 18446744073709551616.0) valStack[sp - 1] = -1n;
                else valStack[sp - 1] = s64(BigInt(Math.trunc(v)));
              } else if (a === 8) { // memory.init
                const len = valStack[--sp] >>> 0;
                const src = valStack[--sp] >>> 0;
                const dst = valStack[--sp] >>> 0;
                const seg = dataSegs[b];
                const segLen = seg.dropped ? 0 : seg.bytes.length;
                if (src + len > segLen || dst + len > mem0._buf.byteLength) {
                  throw new WasmRuntimeError('memory access out of bounds');
                }
                if (len > 0) mem0._u8.set(seg.bytes.subarray(src, src + len), dst);
              } else if (a === 9) { // data.drop
                dataSegs[b].dropped = true;
              } else if (a === 10) { // memory.copy
                const len = valStack[--sp] >>> 0;
                const src = valStack[--sp] >>> 0;
                const dst = valStack[--sp] >>> 0;
                if (src + len > mem0._buf.byteLength || dst + len > mem0._buf.byteLength) {
                  throw new WasmRuntimeError('memory access out of bounds');
                }
                if (len > 0) mem0._u8.copyWithin(dst, src, src + len);
              } else if (a === 11) { // memory.fill
                const len = valStack[--sp] >>> 0;
                const val = valStack[--sp] & 0xff;
                const dst = valStack[--sp] >>> 0;
                if (dst + len > mem0._buf.byteLength) {
                  throw new WasmRuntimeError('memory access out of bounds');
                }
                if (len > 0) mem0._u8.fill(val, dst, dst + len);
              } else if (a === 12) { // table.init
                const len = valStack[--sp] >>> 0;
                const src = valStack[--sp] >>> 0;
                const dst = valStack[--sp] >>> 0;
                const seg = elemSegs[b];
                const tbl = tables[0];
                const segLen = seg.dropped ? 0 : seg.items.length;
                if (src + len > segLen || dst + len > tbl._elems.length) throw new WasmRuntimeError('out of bounds table access');
                for (let k = 0; k < len; k++) tbl._elems[dst + k] = seg.items[src + k];
              } else if (a === 13) { // elem.drop
                elemSegs[b].dropped = true;
              } else if (a === 14) { // table.copy
                const len = valStack[--sp] >>> 0;
                const src = valStack[--sp] >>> 0;
                const dst = valStack[--sp] >>> 0;
                const dstTbl = tables[b];
                const srcTbl = tables[immExtra[pc - 1]];
                if (src + len > srcTbl._elems.length || dst + len > dstTbl._elems.length) {
                  throw new WasmRuntimeError('out of bounds table access');
                }
                if (dst <= src) for (let k = 0; k < len; k++) dstTbl._elems[dst + k] = srcTbl._elems[src + k];
                else for (let k = len - 1; k >= 0; k--) dstTbl._elems[dst + k] = srcTbl._elems[src + k];
              } else if (a === 15) { // table.grow
                const n = valStack[--sp] >>> 0;
                const val = valStack[sp - 1];
                try { valStack[sp - 1] = tables[b].grow(n, val); } catch { valStack[sp - 1] = -1; }
              } else if (a === 16) { // table.size
                valStack[sp++] = tables[b]._elems.length;
              } else if (a === 17) { // table.fill
                const n = valStack[--sp] >>> 0;
                const val = valStack[--sp];
                const dst = valStack[--sp] >>> 0;
                const tbl = tables[b];
                if (dst + n > tbl._elems.length) throw new WasmRuntimeError('out of bounds table access');
                tbl._elems.fill(val, dst, dst + n);
              } else {
                throw new WasmRuntimeError(`Unsupported 0xfc subopcode ${a}`);
              }
              break;
            }

            default:
              throw new WasmRuntimeError(`Unsupported WASM opcode 0x${op.toString(16)}`);
          }
        }

        const rLen = type.results.length;
        if (rLen === 0) return undefined;
        if (rLen === 1) return valStack[sp - 1];
        return valStack.slice(sp - rLen, sp);
      } finally {
        callDepth--;
        if (useShared) stackBusy = false;
      }
    };

    const coerceIn = (v, vt) => {
      if (vt === 0x7e) return s64(BigInt(v ?? 0n));
      if (vt === 0x7f) return (v ?? 0) | 0;
      if (vt === 0x7d) return Math.fround(Number(v ?? 0));
      if (vt === 0x7c) return Number(v ?? 0);
      return v ?? null;
    };
    const coerceOut = (v, vt) => {
      if (vt === 0x7e) return s64(v);
      if (vt === 0x7f) return v | 0;
      return v;
    };
    const callHost = (entry, args) => {
      const jsRes = entry.fn(...args);
      const rLen = entry.type.results.length;
      if (rLen === 0) return undefined;
      if (rLen === 1) return coerceIn(jsRes, entry.type.results[0]);
      return entry.type.results.map((rt, k) => coerceIn(jsRes[k], rt));
    };
    const sameFuncType = (t1, t2) => {
      if (t1 === t2) return true;
      if (t1.params.length !== t2.params.length || t1.results.length !== t2.results.length) return false;
      for (let i = 0; i < t1.params.length; i++) if (t1.params[i] !== t2.params[i]) return false;
      for (let i = 0; i < t1.results.length; i++) if (t1.results[i] !== t2.results[i]) return false;
      return true;
    };
    const wrapFuncForJs = (entry) => {
      if (entry.jsWrapper) return entry.jsWrapper;
      if (entry.host) { entry.jsWrapper = entry.fn; return entry.fn; }
      const pTypes = entry.type.params;
      const rTypes = entry.type.results;
      entry.jsWrapper = (...jsArgs) => {
        const wasmArgs = new Array(pTypes.length);
        for (let i = 0; i < pTypes.length; i++) wasmArgs[i] = coerceIn(jsArgs[i], pTypes[i]);
        const out = invokeInternal(entry, wasmArgs);
        if (rTypes.length === 0) return undefined;
        if (rTypes.length === 1) return coerceOut(out, rTypes[0]);
        return out.map((v, i) => coerceOut(v, rTypes[i]));
      };
      return entry.jsWrapper;
    };

    // Initialize active element segments
    for (let i = 0; i < ir.elems.length; i++) {
      const e = ir.elems[i];
      if (e.passive) continue;
      const tbl = tables[e.tableIdx];
      const off = evalInit(e.offset) >>> 0;
      const items = elemSegs[i].items;
      if (!tbl || off + items.length > tbl._elems.length) {
        throw new WasmRuntimeError('out of bounds table access in active elem segment');
      }
      for (let k = 0; k < items.length; k++) tbl._elems[off + k] = items[k];
      elemSegs[i].dropped = true;
    }

    // Initialize active data segments
    for (let i = 0; i < ir.datas.length; i++) {
      const d = ir.datas[i];
      if (d.passive) continue;
      const m = memories[d.memIdx];
      const off = evalInit(d.offset) >>> 0;
      if (!m || off + d.bytes.length > m._buf.byteLength) {
        throw new WasmRuntimeError('memory access out of bounds in active data segment');
      }
      m._u8.set(d.bytes, off);
      dataSegs[i].dropped = true;
    }

    if (ir.startFunc >= 0) {
      const sf = funcs[ir.startFunc];
      if (sf.host) callHost(sf, []);
      else invokeInternal(sf, []);
    }

    const expObj = {};
    for (const ex of ir.exports) {
      if (ex.kind === 'function') expObj[ex.name] = wrapFuncForJs(funcs[ex.index]);
      else if (ex.kind === 'table') expObj[ex.name] = tables[ex.index];
      else if (ex.kind === 'memory') expObj[ex.name] = memories[ex.index];
      else if (ex.kind === 'global') expObj[ex.name] = globalCells[ex.index];
    }
    this.exports = Object.freeze(expObj);
    void internalOffset;
  }
}

function createWasmNamespace() {
  return {
    Module: WasmModule,
    Instance: WasmInstance,
    Memory: WasmMemory,
    Table: WasmTable,
    Global: WasmGlobal,
    CompileError: WasmCompileError,
    LinkError: WasmLinkError,
    RuntimeError: WasmRuntimeError,
    validate(bytes) {
      try { parseWasmModule(bytes); return true; } catch { return false; }
    },
    async compile(bytes) {
      return new WasmModule(bytes);
    },
    async instantiate(bytesOrModule, importObject) {
      if (bytesOrModule instanceof WasmModule) {
        return new WasmInstance(bytesOrModule, importObject);
      }
      const module = new WasmModule(bytesOrModule);
      const instance = new WasmInstance(module, importObject);
      return { module, instance };
    },
  };
}

function installJitlessPolyfill(opts = {}) {
  if (typeof globalThis.WebAssembly !== 'undefined') return false;
  globalThis.WebAssembly = createWasmNamespace();
  globalThis.fetch = createJitlessFetch(opts);
  return true;
}

module.exports = {
  installJitlessPolyfill,
  createJitlessFetch,
  createWasmNamespace,
};
