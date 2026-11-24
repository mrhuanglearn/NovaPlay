'use strict';
/**
 * Transparent Blu-ray / DVD `.iso` (UDF 2.01/2.50/2.60) main-feature stream unwrapper for CatPaw workers.
 *
 * Cloud-drive sites such as `4kzn`（「盘」指南）frequently share raw 20 GB – 100 GB Blu-ray `.iso` disc images on
 * Quark / UC / Baidu / 115 / 123 / Ali. Neither ExoPlayer, AVPlayer, libmpv, nor MobileVLCKit can mount a UDF `.iso`
 * over HTTP. When `/spider/:site/:type/play` returns a binary stream whose leading 64 bytes are all `0x00` (ECMA-167
 * System Area), we parse the UDF volume & metadata partition in 4–6 small HTTP Range reads, locate the main-feature
 * `/BDMV/STREAM/*.m2ts` (or `/BDAV/STREAM/*.m2ts` / `/VIDEO_TS/*.VOB`) byte extents, and serve it as a seekable
 * local HTTP/1.1 `206 Partial Content` stream (`/uzv-iso/:token/main.m2ts`).
 */

const crypto = require('crypto');
const http = require('http');
const https = require('https');

const BLOCK_SIZE = 2048;
const META_CHUNK_BYTES = 64 * 1024;
const MAX_META_CHUNKS = 64;
const INITIAL_STREAM_CHUNK = 256 * 1024;
const STREAM_CHUNK_BYTES = 1024 * 1024;
const STREAM_CONCURRENCY = 8;
const SESSION_TTL_MS = 6 * 3600 * 1000;
const META_CACHE_TTL_MS = 30 * 60 * 1000;
const MAX_SESSIONS = 32;
const DEFAULT_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

const NON_ISO_PATH_RE = /\.(?:m3u8|m3u|mp4|mkv|webm|flv|avi|ts|m2ts|mts|mov|wmv|rmvb|mp3|flac|aac|vtt|srt|ass)(?:[?#]|$)/i;
const PLAY_ROUTE_RE = /^\/spider\/[^/?#]+\/\d+\/play(?:[?#]|$)/;
const ISO_STREAM_ROUTE_RE = /^\/uzv-iso\/([a-f0-9]{16,32})\/([^/?#]+)(?:[?#]|$)/i;

const httpAgent = new http.Agent({ keepAlive: true, keepAliveMsecs: 30000, maxSockets: 32, maxFreeSockets: 8 });
const httpsAgent = new https.Agent({ keepAlive: true, keepAliveMsecs: 30000, maxSockets: 32, maxFreeSockets: 8 });

const isoSessions = new Map();
const parsedIsoCache = new Map();

function registrableDomain(hostname) {
  const clean = String(hostname || '').trim().toLowerCase().replace(/^\[|\]$/g, '');
  if (!clean || clean === 'localhost' || /^\d+\.\d+\.\d+\.\d+$/.test(clean) || clean.includes(':')) return clean;
  const parts = clean.split('.');
  if (parts.length < 2) return clean;
  const lastTwo = `${parts[parts.length - 2]}.${parts[parts.length - 1]}`;
  if (parts.length >= 3 && /^(?:com|net|org|gov)\.cn$|^co\.(?:uk|jp)$|^com\.(?:hk|tw)$/.test(lastTwo)) {
    return `${parts[parts.length - 3]}.${lastTwo}`;
  }
  return lastTwo;
}

function isLoopbackHost(hostname) {
  const h = String(hostname || '').toLowerCase();
  return h === '127.0.0.1' || h === 'localhost' || h === '::1' || h === '[::1]';
}

function sanitizeHeaders(rawHeaders) {
  const out = {};
  if (!rawHeaders || typeof rawHeaders !== 'object') return out;
  for (const [k, v] of Object.entries(rawHeaders)) {
    if (typeof v !== 'string' || !v) continue;
    const lower = k.toLowerCase();
    if (lower === 'host' || lower === 'connection' || lower === 'content-length' || lower === 'range') continue;
    out[k] = v;
  }
  return out;
}

function filterRedirectHeaders(headers, fromUrl, toUrl) {
  const fromDom = registrableDomain(fromUrl.hostname);
  const toDom = registrableDomain(toUrl.hostname);
  let sameSite = Boolean(fromDom && fromDom === toDom);
  if (!sameSite && isLoopbackHost(fromUrl.hostname)) {
    const refEntry = Object.entries(headers).find(([k]) => k.toLowerCase() === 'referer');
    if (refEntry) {
      try {
        sameSite = registrableDomain(new URL(refEntry[1]).hostname) === toDom;
      } catch { /* ignore */ }
    }
  }
  if (sameSite) return { ...headers };
  const trimmed = {};
  for (const [k, v] of Object.entries(headers)) {
    const lower = k.toLowerCase();
    if (lower === 'user-agent' || lower === 'accept' || lower === 'accept-language' || lower === 'range' || lower === 'accept-encoding') {
      trimmed[k] = v;
    } else if (lower === 'referer') {
      try { trimmed[k] = `${new URL(v).origin}/`; } catch { /* omit */ }
    }
  }
  return trimmed;
}

function openUpstreamStream(rawUrl, headers, { method = 'GET', range = '', timeoutMs = 10000, signal } = {}) {
  return new Promise((resolve, reject) => {
    let settled = false;
    let activeReq = null;
    const fail = (err) => {
      if (settled) return;
      settled = true;
      reject(err);
    };
    const onAbort = () => {
      if (activeReq) activeReq.destroy(new Error('aborted'));
      fail(new Error('aborted'));
    };
    if (signal) {
      if (signal.aborted) return fail(new Error('aborted'));
      signal.addEventListener('abort', onAbort, { once: true });
    }
    const cleanup = () => {
      if (signal) signal.removeEventListener('abort', onAbort);
    };

    const step = (urlStr, curHeaders, redirectsLeft) => {
      let u;
      try { u = new URL(urlStr); } catch (e) { cleanup(); return fail(e); }
      const isHttps = u.protocol === 'https:';
      const mod = isHttps ? https : http;
      const reqHeaders = { ...curHeaders, 'Accept-Encoding': 'identity' };
      if (!Object.keys(reqHeaders).some((k) => k.toLowerCase() === 'user-agent')) {
        reqHeaders['User-Agent'] = DEFAULT_UA;
      }
      if (range) reqHeaders.Range = range;
      else delete reqHeaders.Range;

      const req = mod.request(u, {
        method,
        headers: reqHeaders,
        agent: isHttps ? httpsAgent : httpAgent,
      }, (res) => {
        const code = res.statusCode || 502;
        if ([301, 302, 303, 307, 308].includes(code) && res.headers.location) {
          res.resume();
          if (redirectsLeft <= 0) {
            cleanup();
            return fail(new Error('Too many redirects'));
          }
          let nextUrl;
          try { nextUrl = new URL(res.headers.location, u); } catch (e) { cleanup(); return fail(e); }
          const nextHeaders = filterRedirectHeaders(curHeaders, u, nextUrl);
          return step(nextUrl.toString(), nextHeaders, redirectsLeft - 1);
        }
        cleanup();
        settled = true;
        resolve({ res, statusCode: code, finalUrl: u.toString() });
      });
      activeReq = req;
      req.setTimeout(timeoutMs, () => req.destroy(new Error('Upstream timeout')));
      req.once('error', (err) => {
        cleanup();
        fail(err);
      });
      req.end();
    };

    step(rawUrl, sanitizeHeaders(headers), 5);
  });
}

function readExactOrEof(res, maxBytes, signal) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    let done = false;
    const finish = (err, buf) => {
      if (done) return;
      done = true;
      if (signal) signal.removeEventListener('abort', onAbort);
      if (err) reject(err);
      else resolve(buf);
    };
    const onAbort = () => {
      res.destroy();
      finish(new Error('aborted'));
    };
    if (signal) {
      if (signal.aborted) {
        res.destroy();
        return reject(new Error('aborted'));
      }
      signal.addEventListener('abort', onAbort, { once: true });
    }
    res.on('data', (chunk) => {
      const b = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      const need = maxBytes - total;
      if (b.length >= need) {
        chunks.push(b.subarray(0, need));
        total += need;
        if (b.length > need) res.destroy();
        finish(null, Buffer.concat(chunks, total));
      } else {
        chunks.push(b);
        total += b.length;
      }
    });
    res.once('end', () => finish(null, Buffer.concat(chunks, total)));
    res.once('error', (err) => {
      if (done) return;
      finish(err);
    });
    res.once('close', () => {
      if (!done) finish(null, Buffer.concat(chunks, total));
    });
  });
}

function parseTotalFromHeaders(resHeaders, statusCode) {
  const cr = /^bytes\s+\d+-\d+\/(\d+)$/i.exec(String(resHeaders['content-range'] || ''));
  if (cr) {
    const n = Number(cr[1]);
    if (Number.isSafeInteger(n) && n > 0) return n;
  }
  if (statusCode === 200) {
    const cl = Number(resHeaders['content-length'] || 0);
    if (Number.isSafeInteger(cl) && cl > 0) return cl;
  }
  return 0;
}

function sliceExtents(extents, relOffset, byteLength) {
  if (!Number.isSafeInteger(relOffset) || !Number.isSafeInteger(byteLength) || relOffset < 0 || byteLength < 0) {
    throw new Error('Invalid UDF extent slice range');
  }
  const out = [];
  let skip = relOffset;
  let rem = byteLength;
  for (const ext of extents) {
    if (rem <= 0) break;
    if (skip >= ext.length) {
      skip -= ext.length;
      continue;
    }
    const seg = { offset: ext.offset + skip, length: Math.min(rem, ext.length - skip) };
    const prev = out[out.length - 1];
    if (prev && prev.offset + prev.length === seg.offset) prev.length += seg.length;
    else out.push(seg);
    rem -= seg.length;
    skip = 0;
  }
  if (rem > 0) throw new Error('UDF extent slice out of bounds');
  return out;
}

function hasM2tsOrTsSync(buf) {
  if (!buf || buf.length < 576) return false;
  for (const stride of [192, 188]) {
    for (let off = 0; off < stride && off + stride * 2 < buf.length; off++) {
      if (buf[off] === 0x47 && buf[off + stride] === 0x47 && buf[off + stride * 2] === 0x47) return true;
    }
  }
  return false;
}

async function parseUdfIsoMainStream(fetchRange, initialTotalBytes) {
  let totalBytes = initialTotalBytes || 0;
  const chunkCache = new Map();

  function getChunk(alignedOffset) {
    if (chunkCache.has(alignedOffset)) return chunkCache.get(alignedOffset);
    if (chunkCache.size >= MAX_META_CHUNKS) {
      throw new Error('ISO UDF metadata exceeded maximum read budget');
    }
    const end = totalBytes > 0
      ? Math.min(alignedOffset + META_CHUNK_BYTES, totalBytes) - 1
      : alignedOffset + META_CHUNK_BYTES - 1;
    const p = fetchRange(alignedOffset, end).then(({ buf, total }) => {
      if (total > 0) totalBytes = total;
      return buf;
    });
    chunkCache.set(alignedOffset, p);
    return p;
  }

  async function readAbs(offset, length) {
    if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length < 0) {
      throw new Error('Invalid ISO read offset');
    }
    if (length === 0) return Buffer.alloc(0);
    const parts = [];
    let cur = offset;
    let rem = length;
    while (rem > 0) {
      const aligned = Math.floor(cur / META_CHUNK_BYTES) * META_CHUNK_BYTES;
      const chunk = await getChunk(aligned);
      const offInChunk = cur - aligned;
      const avail = chunk.length - offInChunk;
      if (avail <= 0) throw new Error('Unexpected EOF while reading ISO metadata');
      const take = Math.min(rem, avail);
      parts.push(chunk.subarray(offInChunk, offInChunk + take));
      cur += take;
      rem -= take;
    }
    return parts.length === 1 ? parts[0] : Buffer.concat(parts);
  }

  async function readFromExtents(extents, relOffset, byteLen) {
    const spans = sliceExtents(extents, relOffset, byteLen);
    if (spans.length === 1) return readAbs(spans[0].offset, spans[0].length);
    const bufs = await Promise.all(spans.map((s) => readAbs(s.offset, s.length)));
    return Buffer.concat(bufs);
  }

  let avdp = await readAbs(256 * BLOCK_SIZE, BLOCK_SIZE);
  if (avdp.length < BLOCK_SIZE || avdp.readUInt16LE(0) !== 2) {
    const totalSectors = Math.floor(totalBytes / BLOCK_SIZE);
    const backups = totalSectors > 300 ? [totalSectors - 1, totalSectors - 257, 512] : [512];
    for (const sec of backups) {
      if (sec <= 0) continue;
      try {
        const cand = await readAbs(sec * BLOCK_SIZE, BLOCK_SIZE);
        if (cand.length >= BLOCK_SIZE && cand.readUInt16LE(0) === 2) {
          avdp = cand;
          break;
        }
      } catch { /* try next backup AVDP */ }
    }
  }
  if (avdp.length < BLOCK_SIZE || avdp.readUInt16LE(0) !== 2) {
    throw new Error('UDF Anchor Volume Descriptor Pointer not found');
  }

  let lvd = null;
  const physParts = new Map();
  for (const [lenOff, locOff] of [[16, 20], [24, 28]]) {
    const vdsLen = avdp.readUInt32LE(lenOff);
    const vdsLoc = avdp.readUInt32LE(locOff);
    if (!vdsLen || !vdsLoc || vdsLen > 512 * 1024) continue;
    try {
      const vds = await readAbs(vdsLoc * BLOCK_SIZE, Math.min(vdsLen, 256 * 1024));
      for (let off = 0; off + BLOCK_SIZE <= vds.length; off += BLOCK_SIZE) {
        const sec = vds.subarray(off, off + BLOCK_SIZE);
        const tag = sec.readUInt16LE(0);
        if (tag === 8) break;
        if (tag === 6) lvd = sec;
        if (tag === 5) {
          const start = sec.readUInt32LE(188) * BLOCK_SIZE;
          const len = sec.readUInt32LE(192) * BLOCK_SIZE;
          if (len > 0) physParts.set(sec.readUInt16LE(22), [{ offset: start, length: len }]);
        }
      }
      if (lvd && physParts.size > 0) break;
    } catch { /* try reserve VDS */ }
  }
  if (!lvd || lvd.readUInt32LE(212) !== BLOCK_SIZE) {
    throw new Error('Valid UDF Logical Volume Descriptor (2048-byte sector) not found');
  }

  const mapTableLen = lvd.readUInt32LE(264);
  const numPartMaps = lvd.readUInt32LE(268);
  if (!numPartMaps || numPartMaps > 16 || 440 + mapTableLen > lvd.length) {
    throw new Error('Invalid UDF partition map table');
  }

  const partExtents = [];
  const metaMaps = [];
  let pOff = 440;
  for (let i = 0; i < numPartMaps; i++) {
    const pType = lvd[pOff];
    const pLen = lvd[pOff + 1];
    if (pLen < 6 || pOff + pLen > 440 + mapTableLen) throw new Error('Malformed UDF partition map entry');
    if (pType === 1 && pLen === 6) {
      partExtents[i] = physParts.get(lvd.readUInt16LE(pOff + 4));
    } else if (pType === 2 && pLen === 64) {
      const ident = lvd.toString('ascii', pOff + 5, pOff + 28).replace(/\0.*$/, '');
      const phys = physParts.get(lvd.readUInt16LE(pOff + 38));
      if (ident === '*UDF Metadata Partition') {
        metaMaps.push({
          index: i,
          phys,
          block: lvd.readUInt32LE(pOff + 40),
          mirrorBlock: lvd.readUInt32LE(pOff + 44),
        });
      } else {
        partExtents[i] = phys;
      }
    }
    pOff += pLen;
  }

  async function readFileEntry(pExts, block) {
    if (!pExts || pExts.length === 0) throw new Error('Missing UDF partition extents');
    let fe = await readFromExtents(pExts, block * BLOCK_SIZE, BLOCK_SIZE);
    const tag = fe.readUInt16LE(0);
    if (tag !== 261 && tag !== 266) throw new Error(`Unexpected UDF File Entry tag ${tag}`);
    const base = tag === 266 ? 216 : 176;
    const lEa = fe.readUInt32LE(base - 8);
    const lAd = fe.readUInt32LE(base - 4);
    const adStart = base + lEa;
    const adEnd = adStart + lAd;
    if (adEnd > 64 * 1024) throw new Error('UDF File Entry AD exceeds safety cap');
    if (adEnd > fe.length) fe = await readFromExtents(pExts, block * BLOCK_SIZE, adEnd);
    const infoLen = fe.readUInt32LE(56) + fe.readUInt32LE(60) * 4294967296;
    if (!Number.isSafeInteger(infoLen) || infoLen < 0) throw new Error('Invalid UDF file length');
    const adMode = fe.readUInt16LE(34) & 7;
    const fileType = fe[27];
    if (adMode === 3) {
      return { fileType, length: infoLen, inline: fe.subarray(adStart, adStart + infoLen), extents: [] };
    }
    if (adMode !== 0 && adMode !== 1) throw new Error(`Unsupported UDF AD mode ${adMode}`);
    const stride = adMode === 0 ? 8 : 16;
    const rawExts = [];
    let chainDepth = 0;

    async function walkAds(curPartExts, buf) {
      for (let q = 0; q + stride <= buf.length; q += stride) {
        const rawLen = buf.readUInt32LE(q);
        const extType = rawLen >>> 30;
        const byteLen = rawLen & 0x3fffffff;
        if (!byteLen) continue;
        const extBlock = buf.readUInt32LE(q + 4);
        const targetPart = adMode === 0 ? curPartExts : partExtents[buf.readUInt16LE(q + 8)];
        if (!targetPart) throw new Error('Missing target UDF partition for AD');
        if (extType === 3) {
          if (++chainDepth > 64) throw new Error('UDF AED continuation chain too deep');
          const aed = await readFromExtents(targetPart, extBlock * BLOCK_SIZE, BLOCK_SIZE);
          if (aed.readUInt16LE(0) !== 258) throw new Error('Invalid UDF AED tag');
          const nextLen = aed.readUInt32LE(20);
          await walkAds(targetPart, aed.subarray(24, Math.min(aed.length, 24 + nextLen)));
        } else if (extType === 0) {
          for (const s of sliceExtents(targetPart, extBlock * BLOCK_SIZE, byteLen)) {
            const prev = rawExts[rawExts.length - 1];
            if (prev && prev.offset + prev.length === s.offset) prev.length += s.length;
            else rawExts.push(s);
          }
        }
      }
    }

    await walkAds(pExts, fe.subarray(adStart, adEnd));
    return {
      fileType,
      length: infoLen,
      extents: infoLen > 0 && rawExts.length > 0 ? sliceExtents(rawExts, 0, infoLen) : [],
    };
  }

  for (const m of metaMaps) {
    let metaFe = null;
    try {
      metaFe = await readFileEntry(m.phys, m.block);
    } catch {
      if (m.mirrorBlock && m.mirrorBlock !== m.block) {
        metaFe = await readFileEntry(m.phys, m.mirrorBlock);
      }
    }
    if (!metaFe || !metaFe.extents.length) throw new Error('Failed to resolve UDF Metadata Partition');
    partExtents[m.index] = metaFe.extents;
  }

  const readLongAd = (buf, off) => ({ block: buf.readUInt32LE(off + 4), ref: buf.readUInt16LE(off + 8) });
  const fsdIcb = readLongAd(lvd, 248);
  const fsd = await readFromExtents(partExtents[fsdIcb.ref], fsdIcb.block * BLOCK_SIZE, BLOCK_SIZE);
  if (fsd.readUInt16LE(0) !== 256) throw new Error('Invalid UDF File Set Descriptor');
  const rootIcb = readLongAd(fsd, 400);

  async function listDir(icb) {
    const dirFe = await readFileEntry(partExtents[icb.ref], icb.block);
    if (dirFe.fileType !== 4 || dirFe.length > 2 * 1024 * 1024) throw new Error('Invalid UDF directory entry');
    const data = dirFe.inline || await readFromExtents(dirFe.extents, 0, dirFe.length);
    const out = [];
    for (let k = 0; k + 38 <= data.length; ) {
      if (data.readUInt16LE(k) !== 257) break;
      const lIu = data.readUInt16LE(k + 36);
      const lFi = data[k + 19];
      const nameStart = k + 38 + lIu;
      const nameEnd = nameStart + lFi;
      const next = (nameEnd + 3) & ~3;
      if (nameEnd > data.length || next <= k) break;
      const chars = data[k + 18];
      if (!(chars & 12) && nameEnd > nameStart) {
        const raw = data.subarray(nameStart + 1, nameEnd);
        const name = data[nameStart] === 16 && raw.length % 2 === 0
          ? Buffer.from(raw).swap16().toString('utf16le')
          : raw.toString('latin1');
        out.push({ name, directory: Boolean(chars & 2), ...readLongAd(data, k + 20) });
      }
      k = next;
    }
    return out;
  }

  const rootEntries = await listDir(rootIcb);
  for (const bdRootName of ['BDMV', 'BDAV']) {
    const bdDir = rootEntries.find((e) => e.directory && e.name.toUpperCase() === bdRootName);
    if (!bdDir) continue;
    const streamDir = (await listDir(bdDir)).find((e) => e.directory && e.name.toUpperCase() === 'STREAM');
    if (!streamDir) continue;
    const m2tsEntries = (await listDir(streamDir)).filter((e) => !e.directory && /\.(?:m2ts|mts)$/i.test(e.name));
    if (m2tsEntries.length === 0) continue;
    const resolved = await Promise.all(m2tsEntries.map(async (entry) => {
      const fe = await readFileEntry(partExtents[entry.ref], entry.block);
      return { name: entry.name, length: fe.length, extents: fe.extents };
    }));
    const validCandidates = resolved.filter((r) => r.length >= 576 && r.extents.length > 0);
    validCandidates.sort((a, b) => b.length - a.length);
    if (validCandidates.length === 0) continue;
    const main = validCandidates[0];
    const head = await readFromExtents(main.extents, 0, Math.min(2048, main.length));
    if (!hasM2tsOrTsSync(head)) {
      if (head.subarray(0, 576).every((b) => b === 0)) {
        const err = new Error('该蓝光原盘片源前段数据缺失（网盘原文件不完整），请切换其他片源');
        err.isCorruptIso = true;
        throw err;
      }
      throw new Error('Selected Blu-ray M2TS lacks valid MPEG-TS sync bytes');
    }
    return {
      name: main.name,
      length: main.length,
      extents: main.extents,
      contentType: 'video/mp2t',
      extension: 'm2ts',
    };
  }

  // DVD VIDEO_TS fallback (`VTS_XX_1.VOB` .. `VTS_XX_9.VOB`)
  const videoTsDir = rootEntries.find((e) => e.directory && e.name.toUpperCase() === 'VIDEO_TS');
  if (videoTsDir) {
    const vobs = (await listDir(videoTsDir)).filter((e) => !e.directory && /^VTS_\d{2}_[1-9]\.VOB$/i.test(e.name));
    if (vobs.length > 0) {
      const groups = new Map();
      for (const v of vobs) {
        const prefix = v.name.slice(0, 6).toUpperCase();
        if (!groups.has(prefix)) groups.set(prefix, []);
        groups.get(prefix).push(v);
      }
      let bestSet = null;
      for (const [, list] of groups) {
        list.sort((a, b) => a.name.localeCompare(b.name));
        const fes = await Promise.all(list.map((v) => readFileEntry(partExtents[v.ref], v.block)));
        const combined = [];
        let sum = 0;
        for (const fe of fes) {
          sum += fe.length;
          for (const s of fe.extents) {
            const prev = combined[combined.length - 1];
            if (prev && prev.offset + prev.length === s.offset) prev.length += s.length;
            else combined.push({ ...s });
          }
        }
        if (!bestSet || sum > bestSet.length) bestSet = { length: sum, extents: combined };
      }
      if (bestSet && bestSet.length > 0 && bestSet.extents.length > 0) {
        return {
          name: 'main.vob',
          length: bestSet.length,
          extents: bestSet.extents,
          contentType: 'video/mpeg',
          extension: 'vob',
        };
      }
    }
  }

  throw new Error('No playable Blu-ray BDMV/STREAM or DVD VIDEO_TS found in ISO');
}

function registerIsoSession({ upstreamUrl, headers, parsed }) {
  const now = Date.now();
  for (const [k, v] of isoSessions) {
    if (v.expiresAt <= now) isoSessions.delete(k);
  }
  while (isoSessions.size >= MAX_SESSIONS) {
    const oldest = isoSessions.keys().next().value;
    if (!oldest) break;
    isoSessions.delete(oldest);
  }
  const token = crypto.randomBytes(12).toString('hex');
  isoSessions.set(token, {
    token,
    upstreamUrl,
    headers: sanitizeHeaders(headers),
    extents: parsed.extents,
    length: parsed.length,
    contentType: parsed.contentType,
    extension: parsed.extension,
    expiresAt: now + SESSION_TTL_MS,
  });
  return token;
}

function pickUpstreamTargetFromPlayJson(playObj, localPort) {
  const rawUrl = playObj.url;
  const candidates = [];
  if (typeof rawUrl === 'string' && rawUrl.trim()) {
    candidates.push(rawUrl.trim());
  } else if (Array.isArray(rawUrl)) {
    for (let i = 1; i < rawUrl.length; i += 2) {
      if (typeof rawUrl[i] === 'string' && rawUrl[i].trim()) {
        candidates.push(rawUrl[i].trim());
      }
    }
  }
  if (candidates.length === 0) return null;

  let externalCandidate = null;
  let loopbackCandidate = null;
  for (const c of candidates) {
    let u;
    try { u = new URL(c); } catch { continue; }
    if (u.protocol !== 'http:' && u.protocol !== 'https:') continue;
    if (NON_ISO_PATH_RE.test(u.pathname) || /\/trans\//i.test(u.pathname)) continue;
    if (isLoopbackHost(u.hostname)) {
      if (!loopbackCandidate) {
        if (!u.port && localPort > 0) u.port = String(localPort);
        loopbackCandidate = u.toString();
      }
    } else if (!externalCandidate) {
      externalCandidate = u.toString();
    }
  }
  if (externalCandidate) {
    return { url: externalCandidate, headers: playObj.header || {} };
  }
  if (loopbackCandidate) {
    return { url: loopbackCandidate, headers: playObj.header || {} };
  }
  return null;
}

async function resolveIsoStreamIfApplicable(targetUrl, headers, signal) {
  let cacheKey = targetUrl;
  try {
    const parsedTarget = new URL(targetUrl);
    if (!isLoopbackHost(parsedTarget.hostname) && parsedTarget.pathname.length >= 16) {
      cacheKey = `${parsedTarget.origin}${parsedTarget.pathname}`;
    }
  } catch { /* keep full targetUrl */ }
  const now = Date.now();
  const cached = parsedIsoCache.get(cacheKey);
  if (cached && cached.expiresAt > now) {
    return cached.parsed;
  }

  const probe = await openUpstreamStream(targetUrl, headers, {
    method: 'GET',
    range: 'bytes=0-63',
    timeoutMs: 5000,
    signal,
  });
  if (probe.statusCode !== 206 && probe.statusCode !== 200) {
    probe.res.resume();
    return null;
  }
  const total = parseTotalFromHeaders(probe.res.headers, probe.statusCode);
  const head64 = await readExactOrEof(probe.res, 64, signal);
  if (head64.length < 64 || total < 600 * 1024 || !head64.every((b) => b === 0)) {
    return null;
  }
  // If upstream ignored Range and answered 200 without Content-Range, slicing is impossible.
  if (probe.statusCode !== 206) {
    return null;
  }

  const effectiveUrl = probe.finalUrl || targetUrl;
  const parsed = await parseUdfIsoMainStream(async (start, end) => {
    const r = await openUpstreamStream(effectiveUrl, headers, {
      method: 'GET',
      range: `bytes=${start}-${end}`,
      timeoutMs: 8000,
      signal,
    });
    if (r.statusCode !== 206) {
      r.res.destroy();
      throw new Error(`Upstream range read HTTP ${r.statusCode}`);
    }
    const subTotal = parseTotalFromHeaders(r.res.headers, r.statusCode) || total;
    const expected = end - start + 1;
    const buf = await readExactOrEof(r.res, expected, signal);
    return { buf, total: subTotal };
  }, total);

  while (parsedIsoCache.size >= 32) {
    const firstKey = parsedIsoCache.keys().next().value;
    if (!firstKey) break;
    parsedIsoCache.delete(firstKey);
  }
  parsedIsoCache.set(cacheKey, { parsed, expiresAt: now + META_CACHE_TTL_MS });
  return parsed;
}

async function maybeRewriteIsoPlayPayload(playObj, inReq, localPort, signal) {
  if (!playObj || typeof playObj !== 'object' || Number(playObj.parse || 0) !== 0 || !playObj.url) {
    return null;
  }
  const candidate = pickUpstreamTargetFromPlayJson(playObj, localPort);
  if (!candidate) return null;

  const parsed = await resolveIsoStreamIfApplicable(candidate.url, candidate.headers, signal);
  if (!parsed) return null;

  const token = registerIsoSession({
    upstreamUrl: candidate.url,
    headers: candidate.headers,
    parsed,
  });
  const hostHeader = String(inReq.headers['x-forwarded-host'] || inReq.headers.host || `127.0.0.1:${localPort}`).split(',')[0].trim();
  const protoHeader = String(inReq.headers['x-forwarded-proto'] || 'http').split(',')[0].trim().toLowerCase();
  const scheme = protoHeader === 'https' ? 'https' : 'http';
  const streamUrl = `${scheme}://${hostHeader}/uzv-iso/${token}/main.${parsed.extension}`;

  const next = { ...playObj, parse: 0, url: ['蓝光原盘', streamUrl] };
  delete next.header;
  return next;
}

function parseHttpByteRange(rangeHeader, totalLength) {
  if (!rangeHeader || typeof rangeHeader !== 'string') return null;
  const m = /^bytes=(\d*)-(\d*)$/i.exec(rangeHeader.trim());
  if (!m) return { invalid: true };
  const [, sStr, eStr] = m;
  if (!sStr && !eStr) return { invalid: true };
  let start;
  let end;
  if (!sStr) {
    const suffix = Number(eStr);
    if (!Number.isSafeInteger(suffix) || suffix <= 0) return { invalid: true };
    start = Math.max(0, totalLength - suffix);
    end = totalLength - 1;
  } else {
    start = Number(sStr);
    end = eStr ? Number(eStr) : totalLength - 1;
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || start >= totalLength || end < start) {
      return { invalid: true };
    }
    end = Math.min(end, totalLength - 1);
  }
  return { start, end };
}

function pipeSpanToResponse(upstreamRes, outRes, remainingRef, abortSignal) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const done = (err) => {
      if (settled) return;
      settled = true;
      abortSignal.removeEventListener('abort', onAbort);
      outRes.off('drain', onDrain);
      if (err) reject(err);
      else resolve();
    };
    const onAbort = () => {
      upstreamRes.destroy();
      done(new Error('aborted'));
    };
    const onDrain = () => {
      if (!settled) upstreamRes.resume();
    };
    abortSignal.addEventListener('abort', onAbort, { once: true });
    upstreamRes.on('data', (chunk) => {
      if (settled) return;
      const b = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      const allow = Math.min(b.length, remainingRef.bytes);
      if (allow <= 0) {
        upstreamRes.destroy();
        return done();
      }
      remainingRef.bytes -= allow;
      const slice = allow === b.length ? b : b.subarray(0, allow);
      if (!outRes.write(slice)) {
        upstreamRes.pause();
        outRes.once('drain', onDrain);
      }
      if (remainingRef.bytes <= 0) {
        upstreamRes.destroy();
        done();
      }
    });
    upstreamRes.once('end', () => done());
    upstreamRes.once('error', (err) => done(err));
  });
}

function writeChunkWithBackpressure(outRes, buf, signal) {
  if (signal.aborted || outRes.destroyed) throw new Error('aborted');
  if (outRes.write(buf)) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const onDrain = () => {
      cleanup();
      resolve();
    };
    const onAbort = () => {
      cleanup();
      reject(new Error('aborted'));
    };
    const cleanup = () => {
      outRes.off('drain', onDrain);
      signal.removeEventListener('abort', onAbort);
    };
    outRes.once('drain', onDrain);
    signal.addEventListener('abort', onAbort, { once: true });
  });
}

async function fetchExactRangeBuffer(upstreamUrl, headers, offset, length, signal) {
  let lastErr = null;
  const end = offset + length - 1;
  for (let attempt = 0; attempt < 2; attempt++) {
    if (signal.aborted) throw new Error('aborted');
    try {
      const r = await openUpstreamStream(upstreamUrl, headers, {
        method: 'GET',
        range: `bytes=${offset}-${end}`,
        timeoutMs: 12000,
        signal,
      });
      if (r.statusCode !== 206) {
        r.res.destroy();
        throw new Error(`Upstream HTTP ${r.statusCode}`);
      }
      const buf = await readExactOrEof(r.res, length, signal);
      if (buf.length !== length) {
        throw new Error(`Short upstream chunk (${buf.length}/${length})`);
      }
      return buf;
    } catch (e) {
      lastErr = e;
    }
  }
  throw lastErr || new Error('Parallel ISO chunk fetch failed');
}

async function handleIsoStreamHttp(inReq, outRes, token) {
  const session = isoSessions.get(token);
  if (!session || session.expiresAt <= Date.now()) {
    isoSessions.delete(token);
    outRes.writeHead(410, { 'Content-Type': 'text/plain; charset=utf-8', Connection: 'close' });
    outRes.end('ISO stream session expired');
    return;
  }
  session.expiresAt = Date.now() + SESSION_TTL_MS;

  const method = String(inReq.method || 'GET').toUpperCase();
  if (method !== 'GET' && method !== 'HEAD') {
    outRes.writeHead(405, { Connection: 'close' });
    outRes.end();
    return;
  }

  const parsedRange = parseHttpByteRange(inReq.headers.range, session.length);
  if (parsedRange && parsedRange.invalid) {
    outRes.writeHead(416, {
      'Content-Range': `bytes */${session.length}`,
      'Accept-Ranges': 'bytes',
      'Content-Length': '0',
    });
    outRes.end();
    return;
  }

  const start = parsedRange ? parsedRange.start : 0;
  const end = parsedRange ? parsedRange.end : session.length - 1;
  const contentLen = end - start + 1;
  const resHeaders = {
    'Content-Type': session.contentType,
    'Accept-Ranges': 'bytes',
    'Content-Length': String(contentLen),
    'Cache-Control': 'no-store',
  };
  if (parsedRange) {
    resHeaders['Content-Range'] = `bytes ${start}-${end}/${session.length}`;
  }

  if (method === 'HEAD') {
    outRes.writeHead(parsedRange ? 206 : 200, resHeaders);
    outRes.end();
    return;
  }

  const ac = new AbortController();
  outRes.once('close', () => {
    if (!outRes.writableFinished) ac.abort();
  });

  const spans = sliceExtents(session.extents, start, contentLen);
  let headersSent = false;
  let useParallelChunks = contentLen > INITIAL_STREAM_CHUNK;
  if (useParallelChunks) {
    try {
      if (isLoopbackHost(new URL(session.upstreamUrl).hostname)) useParallelChunks = false;
    } catch { useParallelChunks = false; }
  }

  try {
    for (const span of spans) {
      if (ac.signal.aborted) return;
      if (!useParallelChunks || span.length <= INITIAL_STREAM_CHUNK) {
        const spanEnd = span.offset + span.length - 1;
        let upstream = null;
        let lastErr = null;
        for (let attempt = 0; attempt < 2; attempt++) {
          try {
            upstream = await openUpstreamStream(session.upstreamUrl, session.headers, {
              method: 'GET',
              range: `bytes=${span.offset}-${spanEnd}`,
              timeoutMs: 12000,
              signal: ac.signal,
            });
            if (upstream.statusCode === 206) break;
            upstream.res.destroy();
            lastErr = new Error(`Upstream HTTP ${upstream.statusCode}`);
            upstream = null;
          } catch (e) {
            lastErr = e;
            if (ac.signal.aborted) return;
          }
        }
        if (!upstream) throw lastErr || new Error('Upstream ISO range failed');
        if (!headersSent) {
          headersSent = true;
          outRes.writeHead(parsedRange ? 206 : 200, resHeaders);
        }
        await pipeSpanToResponse(upstream.res, outRes, { bytes: span.length }, ac.signal);
        continue;
      }

      // Parallel chunked streaming for cloud-drive CDNs (Quark/UC/Baidu/115 throttle single sockets to ~150 KB/s):
      // stream the first 256 KB immediately while prefetching 1 MB chunks across up to 8 sockets (~4–12 MB/s).
      const firstLen = Math.min(INITIAL_STREAM_CHUNK, span.length);
      const firstEnd = span.offset + firstLen - 1;
      const initialUp = await openUpstreamStream(session.upstreamUrl, session.headers, {
        method: 'GET',
        range: `bytes=${span.offset}-${firstEnd}`,
        timeoutMs: 10000,
        signal: ac.signal,
      });
      if (initialUp.statusCode !== 206) {
        initialUp.res.destroy();
        throw new Error(`Upstream HTTP ${initialUp.statusCode}`);
      }
      if (!headersSent) {
        headersSent = true;
        outRes.writeHead(parsedRange ? 206 : 200, resHeaders);
      }

      const tailStart = span.offset + firstLen;
      const tailLen = span.length - firstLen;
      const totalTailChunks = Math.ceil(tailLen / STREAM_CHUNK_BYTES);
      const inFlight = new Map();
      let nextLaunchIdx = 0;

      const fillWindow = (consumerIdx) => {
        while (!ac.signal.aborted && nextLaunchIdx < totalTailChunks && nextLaunchIdx - consumerIdx < STREAM_CONCURRENCY) {
          const idx = nextLaunchIdx++;
          const cOff = tailStart + idx * STREAM_CHUNK_BYTES;
          const cLen = Math.min(STREAM_CHUNK_BYTES, tailStart + tailLen - cOff);
          const p = fetchExactRangeBuffer(session.upstreamUrl, session.headers, cOff, cLen, ac.signal);
          p.catch(() => {});
          inFlight.set(idx, p);
        }
      };

      fillWindow(0);
      await pipeSpanToResponse(initialUp.res, outRes, { bytes: firstLen }, ac.signal);

      for (let idx = 0; idx < totalTailChunks; idx++) {
        if (ac.signal.aborted) return;
        fillWindow(idx);
        const chunkBuf = await inFlight.get(idx);
        inFlight.delete(idx);
        fillWindow(idx + 1);
        await writeChunkWithBackpressure(outRes, chunkBuf, ac.signal);
      }
    }
    if (!outRes.writableEnded) outRes.end();
  } catch {
    if (!headersSent && !outRes.headersSent) {
      outRes.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8', Connection: 'close' });
      outRes.end('Upstream ISO stream interrupted');
    } else if (!outRes.destroyed) {
      outRes.destroy();
    }
  }
}

function wrapPlayResponseForIso(inReq, outRes, handler, getLocalPort) {
  const chunks = [];
  let totalBuffered = 0;
  let overflowed = false;
  let capturedStatus = null;
  let capturedStatusMsg;
  let capturedHeaders;

  const origWriteHead = outRes.writeHead.bind(outRes);
  const origWrite = outRes.write.bind(outRes);
  const origEnd = outRes.end.bind(outRes);

  const flushPassthrough = () => {
    outRes.writeHead = origWriteHead;
    outRes.write = origWrite;
    outRes.end = origEnd;
    if (capturedStatus !== null) {
      if (capturedStatusMsg !== undefined) origWriteHead(capturedStatus, capturedStatusMsg, capturedHeaders);
      else if (capturedHeaders !== undefined) origWriteHead(capturedStatus, capturedHeaders);
      else origWriteHead(capturedStatus);
      capturedStatus = null;
    }
    for (const c of chunks) origWrite(c);
    chunks.length = 0;
  };

  outRes.writeHead = function interceptedWriteHead(statusCode, arg1, arg2) {
    capturedStatus = statusCode;
    if (typeof arg1 === 'string') {
      capturedStatusMsg = arg1;
      capturedHeaders = arg2;
    } else {
      capturedStatusMsg = undefined;
      capturedHeaders = arg1;
    }
    return outRes;
  };

  outRes.write = function interceptedWrite(chunk, encoding, cb) {
    if (overflowed) return origWrite(chunk, encoding, cb);
    if (chunk != null) {
      const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk, typeof encoding === 'string' ? encoding : 'utf8');
      if (totalBuffered + buf.length > 262144) {
        overflowed = true;
        flushPassthrough();
        return origWrite(buf, cb);
      }
      chunks.push(buf);
      totalBuffered += buf.length;
    }
    if (typeof encoding === 'function') encoding();
    else if (typeof cb === 'function') cb();
    return true;
  };

  outRes.end = function interceptedEnd(chunk, encoding, cb) {
    const doneCb = typeof chunk === 'function' ? chunk : typeof encoding === 'function' ? encoding : cb;
    if (overflowed) return origEnd(chunk, encoding, cb);
    if (chunk != null && typeof chunk !== 'function') {
      const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk, typeof encoding === 'string' ? encoding : 'utf8');
      if (totalBuffered + buf.length > 262144) {
        overflowed = true;
        flushPassthrough();
        return origEnd(buf, doneCb);
      }
      chunks.push(buf);
      totalBuffered += buf.length;
    }

    const effectiveStatus = capturedStatus ?? outRes.statusCode ?? 200;
    const rawBody = Buffer.concat(chunks, totalBuffered);
    chunks.length = 0;

    let parsedJson = null;
    if (effectiveStatus >= 200 && effectiveStatus < 300 && rawBody.length > 2 && rawBody[0] === 0x7b) {
      try { parsedJson = JSON.parse(rawBody.toString('utf8')); } catch { parsedJson = null; }
    }

    if (!parsedJson || Number(parsedJson.parse || 0) !== 0 || !parsedJson.url) {
      outRes.writeHead = origWriteHead;
      outRes.write = origWrite;
      outRes.end = origEnd;
      if (capturedStatus !== null) {
        if (capturedStatusMsg !== undefined) origWriteHead(capturedStatus, capturedStatusMsg, capturedHeaders);
        else if (capturedHeaders !== undefined) origWriteHead(capturedStatus, capturedHeaders);
        else origWriteHead(capturedStatus);
      }
      return origEnd(rawBody, doneCb);
    }

    const ac = new AbortController();
    outRes.once('close', () => {
      if (!outRes.writableFinished) ac.abort();
    });
    const localPort = getLocalPort(inReq);

    maybeRewriteIsoPlayPayload(parsedJson, inReq, localPort, ac.signal)
      .then((rewritten) => {
        if (outRes.destroyed) return;
        outRes.writeHead = origWriteHead;
        outRes.write = origWrite;
        outRes.end = origEnd;
        const outBuf = rewritten ? Buffer.from(JSON.stringify(rewritten), 'utf8') : rawBody;
        if (rewritten) {
          if (capturedHeaders && typeof capturedHeaders === 'object' && !Array.isArray(capturedHeaders)) {
            for (const hk of Object.keys(capturedHeaders)) {
              if (hk.toLowerCase() === 'content-length') delete capturedHeaders[hk];
            }
            capturedHeaders['content-length'] = String(outBuf.length);
          } else {
            outRes.setHeader('content-length', String(outBuf.length));
          }
        }
        if (capturedStatus !== null) {
          if (capturedStatusMsg !== undefined) origWriteHead(capturedStatus, capturedStatusMsg, capturedHeaders);
          else if (capturedHeaders !== undefined) origWriteHead(capturedStatus, capturedHeaders);
          else origWriteHead(capturedStatus);
        }
        origEnd(outBuf, doneCb);
      })
      .catch((err) => {
        if (outRes.destroyed) return;
        outRes.writeHead = origWriteHead;
        outRes.write = origWrite;
        outRes.end = origEnd;
        if (err && err.isCorruptIso) {
          const errBuf = Buffer.from(JSON.stringify({ code: 502, error: err.message, message: err.message }), 'utf8');
          origWriteHead(502, {
            'Content-Type': 'application/json; charset=utf-8',
            'Content-Length': String(errBuf.length),
            'Cache-Control': 'no-store',
          });
          origEnd(errBuf, doneCb);
          return;
        }
        if (capturedStatus !== null) {
          if (capturedStatusMsg !== undefined) origWriteHead(capturedStatus, capturedStatusMsg, capturedHeaders);
          else if (capturedHeaders !== undefined) origWriteHead(capturedStatus, capturedHeaders);
          else origWriteHead(capturedStatus);
        }
        origEnd(rawBody, doneCb);
      });
    return true;
  };

  return handler(inReq, outRes);
}

function handleBlurayIsoHttp(inReq, outRes, handler, fallbackPort = 2333) {
  const url = String((inReq && inReq.url) || '');
  const isoMatch = ISO_STREAM_ROUTE_RE.exec(url);
  if (isoMatch) {
    handleIsoStreamHttp(inReq, outRes, isoMatch[1]);
    return true;
  }
  if (inReq && inReq.method === 'POST' && PLAY_ROUTE_RE.test(url)) {
    wrapPlayResponseForIso(
      inReq,
      outRes,
      handler,
      (req) => Number(req?.socket?.localPort || process.env.DEV_HTTP_PORT || fallbackPort) || 2333,
    );
    return true;
  }
  return false;
}

module.exports = {
  handleBlurayIsoHttp,
  parseUdfIsoMainStream,
  sliceExtents,
  parseHttpByteRange,
  registerIsoSession,
};
