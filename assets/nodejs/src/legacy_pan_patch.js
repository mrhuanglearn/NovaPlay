'use strict';
/**
 * Runtime multi-drive share resolver upgrade for legacy remote CatPaw bundles (`index.js`) that only resolved
 * Quark/UC or lacked Baidu/Xunlei/Guangya/Tianyi/115-fid/123pan.cn share directory resolvers.
 */

const crypto = require('crypto');
const { scanPanSharesFast } = require('./jitless_polyfill');

const DEFAULT_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
const PAN123_UA =
  'Mozilla/5.0 (Linux; Android 13; 22081212C Build/TKQ1.220829.002; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/116.0.0.0 Mobile Safari/537.36';
const VIDEO_EXT_RE = /\.(?:mp4|mkv|avi|mov|flv|wmv|m4v|ts|m2ts|webm|rmvb|mpg|mpeg|iso|m3u8)$/i;
const SUBTITLE_EXT_RE = /\.(?:srt|ass|ssa|vtt|sub)$/i;

const EXT_DRIVE_NAMES = {
  quark: '夸克网盘',
  uc: 'UC网盘',
  ali: '阿里云盘',
  pan123: '123云盘',
  baidu: '百度网盘',
  115: '115网盘',
  tianyi: '天翼云盘',
  xunlei: '迅雷云盘',
  yidong: '移动云盘',
  guangyapan: '光鸭云盘',
};

const XUNLEI_CID = 'Xqp0kJBXWhwaTpB6';
const XUNLEI_CVER = '1.72.0.2940';
const XUNLEI_PKG = 'com.xunlei.browser';
const XUNLEI_DID = '28c5c199911741f7a18481d60c385152';
const XUNLEI_TS = '1757338961011';
const XUNLEI_SALT = [
  'uWRwO7gPfdPB/0NfPtfQO+71',
  'F93x+qPluYy6jdgNpq+lwdH1ap67+3193+61',
  '020055140487958268090944028408398739',
  '098409',
  '310643b10256171f23557a587e22c1b9',
  '2f592045c17d9a77',
  'd5279d7d96f9d25f3f729f2a3e8b9a5c',
];
const YIDONG_KEY = Buffer.from('PVGDwmcvfs1uV3d1', 'utf8');
const GUANGYA_API = 'https://api.guangyapan.com';

function formatBytes(bytes) {
  const n = Number(bytes || 0);
  if (!Number.isFinite(n) || n <= 0) return '';
  if (n >= 1073741824) return `${(n / 1073741824).toFixed(2)} GB`;
  if (n >= 1048576) return `${(n / 1048576).toFixed(1)} MB`;
  if (n >= 1024) return `${(n / 1024).toFixed(0)} KB`;
  return `${n} B`;
}

function decodeSafe(s) {
  try { return decodeURIComponent(String(s || '')); } catch { return String(s || ''); }
}

function defaultFolderId(provider) {
  if (provider === 'ali') return 'root';
  if (provider === 'baidu') return '/';
  if (provider === 'tianyi') return '-11';
  if (provider === 'xunlei') return '';
  return '0';
}

function extractLegacyShareLinks(lines) {
  const out = [];
  const indexByKey = new Map();
  for (const raw of Array.isArray(lines) ? lines : []) {
    const text = String(raw || '').replace(/\\\//g, '/').replace(/&amp;/gi, '&').trim();
    if (!text) continue;
    const hits = scanPanSharesFast(text);
    const fallbackPwd =
      hits.length === 1
        ? (/(?:提取码|访问码|密码|passcode|pwd)[：:=\s]*([a-zA-Z0-9]{4,8})/i.exec(text) || [])[1] || ''
        : '';
    for (const hit of hits) {
      if (!(hit.provider in EXT_DRIVE_NAMES)) continue;
      let domain;
      if (hit.provider === 'pan123') {
        try { domain = new URL(hit.url).hostname; } catch { domain = 'www.123pan.cn'; }
      }
      const entry = {
        provider: hit.provider,
        shareId: hit.shareId,
        folderId: hit.folderId || defaultFolderId(hit.provider),
        passcode: hit.passcode || fallbackPwd,
        rawUrl: hit.url,
        ...(domain ? { domain } : {}),
      };
      const key = `${entry.provider}:${entry.shareId}:${entry.folderId}`;
      const existing = indexByKey.get(key);
      if (existing !== undefined) {
        if (!out[existing].passcode && entry.passcode) out[existing] = entry;
      } else {
        indexByKey.set(key, out.length);
        out.push(entry);
      }
    }
  }
  return out;
}

async function fetchTimed(url, init = {}, timeoutMs = 6000) {
  return fetch(url, { ...init, signal: AbortSignal.timeout(timeoutMs) });
}

function sortVideos(videos) {
  videos.sort((a, b) => String(a.name || '').localeCompare(String(b.name || ''), undefined, { numeric: true, sensitivity: 'base' }));
}

function normalizePan123Host(rawDomain) {
  const clean = String(rawDomain || '').trim().toLowerCase();
  if (!clean || clean === 'www.123pan.com' || clean === '123pan.com' || clean === '123pan.cn') return 'www.123pan.cn';
  if (/^123\d{3}\.com$/.test(clean)) return `www.${clean}`;
  return clean;
}

async function resolveAli(share) {
  let shareToken = '';
  let usedPwd = share.passcode || '';
  for (const pwd of share.passcode ? [share.passcode, ''] : ['']) {
    const r = await fetchTimed('https://api.aliyundrive.com/v2/share_link/get_share_token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'User-Agent': DEFAULT_UA },
      body: JSON.stringify({ share_id: share.shareId, share_pwd: pwd }),
    });
    const j = await r.json().catch(() => ({}));
    if (/ShareLink\.(?:NotFound|Cancelled|Expired|Forbidden)/i.test(String(j.code || ''))) {
      return { dead: true, items: [] };
    }
    if (j.share_token) {
      shareToken = j.share_token;
      usedPwd = pwd;
      break;
    }
  }
  if (!shareToken) return { items: [] };
  const videos = [];
  const subs = [];
  const walk = async (parentId, depth) => {
    if (depth > 4 || videos.length >= 200) return;
    let marker = '';
    for (let p = 0; p < 4; p++) {
      const r = await fetchTimed('https://api.aliyundrive.com/adrive/v3/file/list', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'User-Agent': DEFAULT_UA, 'x-share-token': shareToken },
        body: JSON.stringify({ share_id: share.shareId, parent_file_id: parentId, limit: 100, order_by: 'name', order_direction: 'ASC', marker }),
      });
      const j = await r.json().catch(() => ({}));
      for (const it of j.items || []) {
        const fid = String(it.file_id || '');
        const name = String(it.name || '');
        if (!fid || !name) continue;
        if (it.type === 'folder') await walk(fid, depth + 1);
        else if (it.category === 'video' || VIDEO_EXT_RE.test(name)) videos.push({ fileId: fid, name, size: Number(it.size || 0), subFileId: '', subName: '' });
        else if (SUBTITLE_EXT_RE.test(name)) subs.push({ fileId: fid, name });
      }
      marker = String(j.next_marker || '');
      if (!marker) break;
    }
  };
  await walk(share.folderId || 'root', 0);
  sortVideos(videos);
  return {
    items: videos.map((v) => ({
      name: v.name,
      size: v.size,
      epId: ['ext', 'ali', share.shareId, encodeURIComponent(shareToken), v.fileId, v.subFileId, encodeURIComponent(v.subName), encodeURIComponent(usedPwd)].join('*'),
    })),
  };
}

async function resolvePan123(share, token) {
  const hosts = Array.from(new Set(['www.123pan.cn', normalizePan123Host(share.domain)]));
  for (const host of hosts) {
    const videos = [];
    let dead = false;
    let hadResp = false;
    const walk = async (parentId, depth) => {
      if (depth > 5 || videos.length >= 200) return;
      let next = '0';
      for (let page = 1; page <= 5; page++) {
        const u = `https://${host}/b/api/share/get?limit=100&next=${encodeURIComponent(next)}&orderBy=file_name&orderDirection=asc&shareKey=${encodeURIComponent(share.shareId)}&SharePwd=${encodeURIComponent(share.passcode)}&ParentFileId=${encodeURIComponent(parentId)}&Page=${page}`;
        const r = await fetchTimed(u, {
          headers: { 'User-Agent': PAN123_UA, platform: 'android', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
        });
        if (r.status === 404) { if (host === 'www.123pan.cn') dead = true; return; }
        const j = await r.json().catch(() => ({}));
        hadResp = true;
        if (j.code !== undefined && Number(j.code) !== 0) {
          if (/不存在|失效|取消|过期|deleted|expired/i.test(String(j.message || ''))) dead = true;
          return;
        }
        if (j.data && j.data.Expired === true) { dead = true; return; }
        const list = (j.data && j.data.InfoList) || [];
        if (depth === 0 && page === 1 && list.length === 0 && Number(j.data?.Len ?? -1) === 0) {
          dead = true;
          return;
        }
        for (const it of list) {
          const fid = String(it.FileId ?? '');
          const name = String(it.FileName ?? '');
          if (!fid || !name) continue;
          if (Number(it.Type) === 1 || Number(it.Category) === 0) await walk(fid, depth + 1);
          else if (Number(it.Category) === 2 || VIDEO_EXT_RE.test(name)) {
            videos.push({
              fileId: fid,
              s3KeyFlag: String(it.S3KeyFlag ?? ''),
              etag: String(it.Etag ?? ''),
              size: Number(it.Size ?? 0),
              name,
              downloadUrl: String(it.DownloadUrl ?? it.DownloadURL ?? ''),
            });
          }
        }
        const nv = String(j.data?.Next ?? '-1');
        if (!list.length || list.length < 100 || nv === '-1' || !nv) break;
        next = nv;
      }
    };
    try { await walk('0', 0); } catch { continue; }
    if (videos.length > 0 || dead || hadResp) {
      sortVideos(videos);
      return {
        dead: dead && videos.length === 0,
        items: videos.map((v) => ({
          name: v.name,
          size: v.size,
          epId: [
            'ext', 'pan123', share.shareId, v.fileId, encodeURIComponent(v.s3KeyFlag),
            encodeURIComponent(v.etag), String(v.size), encodeURIComponent(v.name), encodeURIComponent(host),
            ...(v.downloadUrl ? [encodeURIComponent(v.downloadUrl)] : []),
          ].join('*'),
        })),
      };
    }
  }
  return { items: [] };
}

async function resolve115(share, cookie) {
  const videos = [];
  let dead = false;
  const walk = async (cid, depth) => {
    if (depth > 4 || videos.length >= 200) return;
    let offset = 0;
    const maxPages = depth === 0 ? 3 : 2;
    for (let p = 0; p < maxPages; p++) {
      const u = `https://webapi.115.com/share/snap?share_code=${encodeURIComponent(share.shareId)}&receive_code=${encodeURIComponent(share.passcode)}&cid=${encodeURIComponent(cid)}&offset=${offset}&limit=115`;
      const r = await fetchTimed(u, {
        headers: { 'User-Agent': DEFAULT_UA, Referer: 'https://115.com/', ...(cookie ? { Cookie: cookie } : {}) },
      });
      const j = await r.json().catch(() => ({}));
      if (!j.data) {
        if (!j.state && /不存在|失效|取消|过期|撤销/i.test(String(j.error || j.msg || ''))) dead = true;
        return;
      }
      const rows = j.data.list || [];
      const subs = [];
      for (const row of rows) {
        const name = String(row.n ?? '').trim();
        if (!name) continue;
        const isFolder = row.fc !== undefined ? String(row.fc) === '0' : !row.fid;
        if (isFolder && row.cid !== undefined && row.cid !== '') subs.push(String(row.cid));
        else if ((Number(row.iv) === 1 || VIDEO_EXT_RE.test(name)) && (row.fid || row.pc)) {
          videos.push({ fid: String(row.fid ?? ''), pc: String(row.pc ?? ''), name, size: Number(row.s ?? 0) });
        }
      }
      for (const sc of subs) await walk(sc, depth + 1);
      offset += rows.length;
      const total = Number(j.data.count ?? 0);
      if (rows.length < 115 || (total > 0 && offset >= total)) break;
    }
  };
  await walk('', 0);
  sortVideos(videos);
  return {
    dead: dead && videos.length === 0,
    items: videos.map((v) => ({
      name: v.name,
      size: v.size,
      epId: ['ext', '115', share.shareId, encodeURIComponent(share.passcode), v.fid, v.pc, encodeURIComponent(v.name)].join('*'),
    })),
  };
}

async function resolveBaidu(share, cookie) {
  const shorturl = share.shareId.startsWith('1') && share.shareId.length > 1 ? share.shareId.slice(1) : share.shareId;
  const referer = share.rawUrl || `https://pan.baidu.com/s/${share.shareId}`;
  let shareCookie = String(cookie || '').trim();
  if (!/BAIDUID=/i.test(shareCookie)) {
    try {
      const ir = await fetchTimed(
        `https://pan.baidu.com/s/${encodeURIComponent(share.shareId)}${share.passcode ? `?pwd=${encodeURIComponent(share.passcode)}` : ''}`,
        { headers: { 'User-Agent': DEFAULT_UA }, redirect: 'manual' },
        5000,
      );
      const cks = typeof ir.headers.getSetCookie === 'function' ? ir.headers.getSetCookie() : [ir.headers.get('set-cookie') || ''];
      const bid = cks.map((c) => c.split(';')[0].trim()).filter(Boolean).join('; ');
      if (bid) shareCookie = shareCookie ? `${shareCookie}; ${bid}` : bid;
    } catch { /* ignore */ }
  }
  if (share.passcode) {
    const vr = await fetchTimed(
      `https://pan.baidu.com/share/verify?surl=${encodeURIComponent(shorturl)}&pwd=${encodeURIComponent(share.passcode)}&channel=chunlei&web=1&app_id=250528&clienttype=0`,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'User-Agent': DEFAULT_UA,
          Referer: referer,
          ...(shareCookie ? { Cookie: shareCookie } : {}),
        },
        body: `pwd=${encodeURIComponent(share.passcode)}&vcode=&vcode_str=`,
      },
    );
    const vj = await vr.json().catch(() => ({}));
    if (vj.randsk) {
      const stripped = shareCookie.replace(/(?:^|;\s*)BDCLND=[^;]*/g, '').replace(/^;\s*|;\s*$/g, '');
      shareCookie = stripped ? `${stripped}; BDCLND=${vj.randsk}` : `BDCLND=${vj.randsk}`;
    } else if (vj.errno === -9 || vj.errno === 105) {
      return { items: [], dead: true };
    }
  }
  const videos = [];
  let dead = false;
  const walk = async (dirPath, isRoot, depth) => {
    if (depth > 4 || videos.length >= 200) return;
    for (let page = 1; page <= 2; page++) {
      const dp = isRoot ? '&root=1' : `&dir=${encodeURIComponent(dirPath)}&root=0`;
      const u = `https://pan.baidu.com/share/list?web=5&app_id=250528&desc=1&showempty=0&page=${page}&num=100&order=name&shorturl=${encodeURIComponent(shorturl)}${dp}&channel=chunlei&clienttype=0`;
      const r = await fetchTimed(u, {
        headers: { 'User-Agent': DEFAULT_UA, Referer: referer, ...(shareCookie ? { Cookie: shareCookie } : {}) },
      });
      const j = await r.json().catch(() => ({}));
      if (j.errno === -7 || j.errno === -9 || j.errno === -21 || j.errno === 105 || /取消|不存在|失效|过期/.test(String(j.show_msg || ''))) {
        dead = true;
        return;
      }
      if (j.errno !== 0 || !Array.isArray(j.list)) return;
      const uk = String(j.uk ?? '');
      const shareid = String(j.share_id ?? '');
      const dirs = [];
      for (const o of j.list) {
        const p = String(o.path ?? '');
        const name = String(o.server_filename || p.split('/').pop() || '');
        if (!name) continue;
        if (Number(o.isdir) === 1 || Number(o.category) === 6) {
          if (p) dirs.push(p);
        } else if (Number(o.category) === 1 || VIDEO_EXT_RE.test(name)) {
          const fsId = String(o.fs_id ?? o.fsid ?? '');
          if (fsId) videos.push({ name, size: Number(o.size ?? 0), uk, shareid, fsId, path: p });
        }
      }
      for (const sub of dirs) await walk(sub, false, depth + 1);
      if (!Number(j.has_more) || j.list.length < 100) break;
    }
  };
  await walk('/', true, 0);
  sortVideos(videos);
  return {
    dead: dead && videos.length === 0,
    items: videos.map((v) => ({
      name: v.name,
      size: v.size,
      epId: ['ext', 'baidu', share.shareId, v.uk, v.shareid, v.fsId, encodeURIComponent(v.path), encodeURIComponent(share.passcode)].join('*'),
    })),
  };
}

function buildXunleiSign() {
  let acc = `${XUNLEI_CID}${XUNLEI_CVER}${XUNLEI_PKG}${XUNLEI_DID}${XUNLEI_TS}`;
  for (const part of XUNLEI_SALT) acc = crypto.createHash('md5').update(`${acc}${part}`, 'utf8').digest('hex');
  return `1.${acc}`;
}

async function resolveXunlei(share) {
  const tr = await fetchTimed('https://xluser-ssl.xunlei.com/v1/shield/captcha/init', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'User-Agent': DEFAULT_UA },
    body: JSON.stringify({
      client_id: XUNLEI_CID,
      action: 'get:/drive/v1/share',
      device_id: XUNLEI_DID,
      meta: { package_name: XUNLEI_PKG, client_version: XUNLEI_CVER, captcha_sign: buildXunleiSign(), timestamp: XUNLEI_TS },
    }),
  });
  const tj = await tr.json().catch(() => ({}));
  const ctok = String(tj.captcha_token || '');
  if (!ctok) return { items: [] };
  const headers = {
    'User-Agent': DEFAULT_UA,
    'accept-language': 'zh,en-US;q=0.8,en;q=0.7,zh-CN;q=0.6',
    'x-captcha-token': ctok,
    'x-client-id': XUNLEI_CID,
    'x-device-id': XUNLEI_DID,
  };
  const videos = [];
  let passCodeToken = '';
  let dead = false;
  const walk = async (parentId, depth) => {
    if (depth > 4 || videos.length >= 200) return;
    let pageToken = '';
    for (let p = 0; p < 3; p++) {
      const u = parentId
        ? `https://api-pan.xunlei.com/drive/v1/share/detail?share_id=${encodeURIComponent(share.shareId)}&parent_id=${encodeURIComponent(parentId)}&pass_code_token=${encodeURIComponent(passCodeToken)}&limit=100&page_token=${encodeURIComponent(pageToken)}&thumbnail_size=SIZE_SMALL`
        : `https://api-pan.xunlei.com/drive/v1/share?share_id=${encodeURIComponent(share.shareId)}&pass_code=${encodeURIComponent(share.passcode)}&limit=100&page_token=${encodeURIComponent(pageToken)}&thumbnail_size=SIZE_SMALL`;
      const r = await fetchTimed(u, { headers });
      const j = await r.json().catch(() => ({}));
      if (j.pass_code_token) passCodeToken = String(j.pass_code_token);
      if (j.share_status && /EXPIRED|DELETED|NOT_FOUND|CANCEL/i.test(j.share_status)) { dead = true; return; }
      const folders = [];
      for (const f of j.files || []) {
        const fid = String(f.id ?? '').trim();
        const name = String(f.name ?? '').trim();
        if (!fid || !name) continue;
        if (f.kind === 'drive#folder' || f.mime_type === '') folders.push(fid);
        else if (f.file_category === 'VIDEO' || VIDEO_EXT_RE.test(name)) {
          videos.push({ id: fid, parentId: String(f.parent_id ?? parentId), name, size: Number(f.size ?? 0), passCodeToken });
        }
      }
      for (const sub of folders) await walk(sub, depth + 1);
      pageToken = String(j.next_page_token || '');
      if (!pageToken) break;
    }
  };
  await walk('', 0);
  sortVideos(videos);
  return {
    dead: dead && videos.length === 0,
    items: videos.map((v) => ({
      name: v.name,
      size: v.size,
      epId: ['ext', 'xunlei', share.shareId, v.id, v.parentId, encodeURIComponent(v.passCodeToken), encodeURIComponent(share.passcode)].join('*'),
    })),
  };
}

function getGuangyaDid(entry) {
  const raw = String((entry && entry.deviceId) || '').trim().toLowerCase().replace(/[^0-9a-f]/g, '');
  return raw.length === 32 ? raw : 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
}

function guangyaHeaders(did, bearer = '') {
  return {
    Accept: 'application/json, text/plain, */*',
    'Content-Type': 'application/json',
    'User-Agent': DEFAULT_UA,
    Did: did,
    Dt: '4',
    ...(bearer ? { Authorization: `Bearer ${bearer}` } : {}),
  };
}

async function resolveGuangya(share, entry) {
  const headers = guangyaHeaders(getGuangyaDid(entry));
  const tr = await fetchTimed(`${GUANGYA_API}/nd.bizuserres.s/v1/get_share_access_token`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ shareId: share.shareId }),
  });
  const tj = await tr.json().catch(() => ({}));
  const accessToken = String((tj.data && tj.data.accessToken) || '').trim();
  if (!accessToken) {
    return { items: [], dead: tr.status === 404 || /不存在|失效|取消|过期/.test(String(tj.msg || tj.message || '')) };
  }
  const videos = [];
  const walk = async (parentId, depth) => {
    if (depth > 4 || videos.length >= 200) return;
    let cursor = 0;
    for (let p = 0; p < 5; p++) {
      const r = await fetchTimed(`${GUANGYA_API}/nd.bizuserres.s/v1/get_share_page_files_list`, {
        method: 'POST',
        headers,
        body: JSON.stringify({ pageSize: 200, accessToken, parentId, orderBy: 0, sortType: 0, ...(cursor > 0 ? { cursor } : {}) }),
      });
      if (!r.ok) break;
      const j = await r.json().catch(() => ({}));
      const folders = [];
      for (const it of (j.data && j.data.list) || []) {
        const fid = String(it.fileId ?? '').trim();
        const name = String(it.fileName ?? '').trim();
        if (!fid || !name) continue;
        if (Number(it.resType) === 2) folders.push(fid);
        else if (VIDEO_EXT_RE.test(name)) videos.push({ fileId: fid, name, size: Number(it.fileSize ?? it.size ?? 0) });
      }
      for (const sub of folders) await walk(sub, depth + 1);
      const next = Number(j.data?.cursor ?? 0);
      if (!j.data?.hasMore || next <= cursor) break;
      cursor = next;
    }
  };
  await walk('', 0);
  sortVideos(videos);
  return {
    items: videos.map((v) => ({
      name: v.name,
      size: v.size,
      epId: ['ext', 'guangyapan', share.shareId, v.fileId, encodeURIComponent(accessToken)].join('*'),
    })),
  };
}

async function resolveTianyi(share) {
  const headers = { Accept: 'application/json;charset=UTF-8', 'User-Agent': DEFAULT_UA };
  if (share.passcode) {
    await fetchTimed(`https://cloud.189.cn/api/open/share/checkAccessCode.action?shareCode=${encodeURIComponent(share.shareId)}&accessCode=${encodeURIComponent(share.passcode)}`, { headers }, 5000).catch(() => {});
  }
  const ir = await fetchTimed(`https://cloud.189.cn/api/open/share/getShareInfoByCodeV2.action?key=noCache&shareCode=${encodeURIComponent(share.shareId)}`, { headers });
  if (ir.status === 404) return { items: [], dead: true };
  const info = await ir.json().catch(() => ({}));
  if (/ShareNotFound|ShareExpired|ShareAudit/i.test(String(info.res_code || ''))) return { items: [], dead: true };
  const numShareId = String(info.shareId ?? '');
  const rootFileId = String(info.fileId ?? '');
  if (!numShareId || !rootFileId) return { items: [] };
  const videos = [];
  if (!info.isFolder) {
    const fn = String(info.fileName ?? '');
    if (fn && VIDEO_EXT_RE.test(fn)) videos.push({ fileId: rootFileId, name: fn, size: Number(info.fileSize ?? 0) });
  } else {
    const shareMode = String(info.shareMode ?? 3);
    const walk = async (dirId, depth) => {
      if (depth > 4 || videos.length >= 200) return;
      const u = `https://cloud.189.cn/api/open/share/listShareDir.action?key=noCache&pageNum=1&pageSize=200&fileId=${encodeURIComponent(dirId)}&shareDirFileId=${encodeURIComponent(rootFileId)}&isFolder=true&shareId=${encodeURIComponent(numShareId)}&shareMode=${encodeURIComponent(shareMode)}&iconOption=5&orderBy=filename&descending=false&accessCode=${encodeURIComponent(share.passcode)}`;
      const r = await fetchTimed(u, { headers });
      if (!r.ok) return;
      const j = await r.json().catch(() => ({}));
      for (const f of j.fileListAO?.fileList || []) {
        const fid = String(f.id ?? '');
        const fn = String(f.name ?? '');
        if (fid && fn && VIDEO_EXT_RE.test(fn)) videos.push({ fileId: fid, name: fn, size: Number(f.size ?? 0) });
      }
      for (const d of j.fileListAO?.folderList || []) {
        const did = String(d.id ?? '');
        if (did) await walk(did, depth + 1);
      }
    };
    await walk(rootFileId, 0);
  }
  sortVideos(videos);
  return {
    items: videos.map((v) => ({
      name: v.name,
      size: v.size,
      epId: ['ext', 'tianyi', share.shareId, numShareId, v.fileId, encodeURIComponent(share.passcode)].join('*'),
    })),
  };
}

async function postYidongApi(endpoint, payload, authToken = '') {
  const iv = crypto.randomBytes(16);
  const cipher = crypto.createCipheriv('aes-128-cbc', YIDONG_KEY, iv);
  const enc = Buffer.concat([cipher.update(JSON.stringify(payload), 'utf8'), cipher.final()]);
  const body = JSON.stringify(Buffer.concat([iv, enc]).toString('base64'));
  const cleanAuth = String(authToken || '').replace(/^Basic\s+/i, '').trim();
  const r = await fetchTimed(`https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/IOutLink/${endpoint}`, {
    method: 'POST',
    headers: {
      'User-Agent': DEFAULT_UA,
      Accept: 'application/json, text/plain, */*',
      'Content-Type': 'application/json',
      'hcy-cool-flag': '1',
      'x-deviceinfo': '||3|12.27.0|chrome|131.0.0.0|5c7c68368f048245e1ce47f1c0f8f2d0||windows 10|1536X695|zh-CN|||',
      ...(cleanAuth ? { Authorization: `Basic ${cleanAuth}` } : {}),
    },
    body,
  }, 8000);
  if (!r.ok) return null;
  let text = (await r.text()).trim();
  if (!text) return null;
  if (text.startsWith('"')) { try { text = JSON.parse(text); } catch { /* keep */ } }
  try {
    const raw = Buffer.from(text, 'base64');
    if (raw.length > 16) {
      const dec = crypto.createDecipheriv('aes-128-cbc', YIDONG_KEY, raw.subarray(0, 16));
      return JSON.parse(Buffer.concat([dec.update(raw.subarray(16)), dec.final()]).toString('utf8'));
    }
  } catch { /* fall through */ }
  try { return JSON.parse(text); } catch { return null; }
}

async function resolveYidong(share, authToken = '') {
  const videos = [];
  const skipRe = /App|活动中心|免费|1T空间|免流/;
  const walk = async (pCaID, depth) => {
    if (depth > 3 || videos.length >= 200) return;
    const j = await postYidongApi('getOutLinkInfoV6', {
      getOutLinkInfoReq: { account: '', linkID: share.shareId, passwd: share.passcode || '', caSrt: 0, coSrt: 0, srtDr: 1, bNum: 1, pCaID, eNum: 200 },
      commonAccountInfo: { account: '', accountType: 1 },
    }, authToken);
    const data = j && j.data;
    if (!data) return;
    for (const co of data.coLst || []) {
      const cid = String(co.coID ?? '').trim();
      const name = String(co.coName ?? '').trim();
      if (!cid || !name) continue;
      if (co.coType === 3 || VIDEO_EXT_RE.test(name)) {
        videos.push({ name, size: Number(co.coSize ?? 0), contentId: cid, path: String(co.path ?? ''), coType: String(co.coType ?? '') });
      }
    }
    for (const ca of data.caLst || []) {
      const fp = String(ca.path ?? '').trim();
      if (fp && !skipRe.test(String(ca.caName ?? ''))) await walk(fp, depth + 1);
    }
  };
  await walk('root', 0);
  sortVideos(videos);
  return {
    items: videos.map((v) => ({
      name: v.name,
      size: v.size,
      epId: ['ext', 'yidong', share.shareId, v.contentId, encodeURIComponent(v.path), v.coType].join('*'),
    })),
  };
}

function selectDiverse(shares, maxCount = 16) {
  if (shares.length <= maxCount) return shares;
  const picked = [];
  const used = new Set();
  const seen = new Set();
  for (let i = 0; i < shares.length && picked.length < maxCount; i++) {
    if (!seen.has(shares[i].provider)) {
      seen.add(shares[i].provider);
      picked.push(shares[i]);
      used.add(i);
    }
  }
  for (let i = 0; i < shares.length && picked.length < maxCount; i++) {
    if (!used.has(i)) picked.push(shares[i]);
  }
  return picked;
}

async function resolveLegacyExtendedShares(fastify, shares) {
  const [pans, rawPanList] = await Promise.all([
    fastify?.db?.get?.('pans').then((v) => v || {}).catch(() => ({})),
    fastify?.db?.get?.('panListConfig').catch(() => null),
  ]);
  const panList = Array.isArray(rawPanList) ? rawPanList : [];
  const disabled = new Set(panList.filter((p) => p && p.enabled === false).map((p) => p.key));
  const orderMap = new Map(panList.map((p, idx) => [p && p.key, idx]));
  const nonCoreAll = (Array.isArray(shares) ? shares : []).filter(
    (s) => s && s.provider !== 'uc' && s.provider !== 'quark' && !disabled.has(s.provider),
  );
  if (nonCoreAll.length === 0) return [];
  const nonCore = selectDiverse(nonCoreAll, 16);

  const settled = await Promise.allSettled(
    nonCore.map(async (share) => {
      const entry = (pans && pans[share.provider]) || {};
      let outcome = { items: [] };
      try {
        if (share.provider === 'ali') outcome = await resolveAli(share);
        else if (share.provider === 'pan123') outcome = await resolvePan123(share, String(entry.token || '').trim());
        else if (share.provider === '115') outcome = await resolve115(share, String(entry.cookie || '').trim());
        else if (share.provider === 'yidong') outcome = await resolveYidong(share, String(entry.authorization || entry.token || '').trim());
        else if (share.provider === 'baidu') outcome = await resolveBaidu(share, String(entry.cookie || '').trim());
        else if (share.provider === 'xunlei') outcome = await resolveXunlei(share);
        else if (share.provider === 'guangyapan') outcome = await resolveGuangya(share, entry);
        else if (share.provider === 'tianyi') outcome = await resolveTianyi(share);
      } catch {
        outcome = { items: [] };
      }
      return { share, outcome };
    }),
  );

  const rows = settled
    .map((s, idx) => ({
      idx,
      share: nonCore[idx],
      outcome: s.status === 'fulfilled' ? s.value.outcome : { items: [] },
    }))
    .sort((a, b) => (orderMap.get(a.share.provider) ?? 999) - (orderMap.get(b.share.provider) ?? 999) || a.idx - b.idx);

  const counts = new Map();
  const results = [];
  for (const { share, outcome } of rows) {
    const label = EXT_DRIVE_NAMES[share.provider] || share.provider;
    let items = outcome.items || [];
    if (items.length === 0) {
      items = [{
        name: `${label}分享 (${share.shareId})`,
        size: 0,
        epId: ['ext', share.provider, share.shareId, encodeURIComponent(share.passcode || ''), encodeURIComponent(share.rawUrl || '')].join('*'),
      }];
    }
    const idx = (counts.get(label) || 0) + 1;
    counts.set(label, idx);
    const from = idx > 1 ? `${label}-${idx}` : label;
    const episodes = items.map((it) => {
      const clean = String(it.name || '').replace(/\.[^.]+$/, '');
      const tag = formatBytes(it.size);
      return `${tag ? `${clean} [${tag}]` : clean}$${it.epId}`;
    });
    results.push({ from, episodes });
  }
  return results;
}

async function playLegacyExtendedShare(fastify, req, spiderKey, spiderType, rawId, helpers, origPlayFn) {
  const parts = String(rawId || '').split('*');
  const provider = parts[1];
  const [pans, wanouDb] = await Promise.all([
    fastify?.db?.get?.('pans').then((v) => v || {}).catch(() => ({})),
    fastify?.db?.get?.('wanou').catch(() => null),
  ]);
  const entry = (pans && pans[provider]) || {};
  const preferProxy = Boolean(wanouDb && wanouDb.preferProxy);
  const baseOrigin = helpers.getOrigin(req);
  const secret = fastify?.config?.proxySecret;

  if (provider === 'pan123') {
    const [, , shareId, fileId, encS3, encEtag, rawSize, encName, encHost = 'www.123pan.cn', encDirect = ''] = parts;
    const host = normalizePan123Host(decodeSafe(encHost));
    const token = String(entry.token || '').trim();
    let directUrl = decodeSafe(encDirect);
    let errMsg = '';
    if (!directUrl && fileId && parts.length >= 8) {
      const r = await fetchTimed(`https://${host}/a/api/share/download/info`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json;charset=UTF-8', 'User-Agent': PAN123_UA, platform: 'android', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
        body: JSON.stringify({ ShareKey: shareId, FileID: Number(fileId) || fileId, S3KeyFlag: decodeSafe(encS3), Etag: decodeSafe(encEtag), Size: Number(rawSize) || 0 }),
      }, 8000);
      const j = await r.json().catch(() => ({}));
      directUrl = j.data?.DownloadURL || j.data?.DownloadUrl || '';
      errMsg = j.message || '';
    }
    if (!directUrl) {
      throw Object.assign(new Error(errMsg || `123云盘获取直链失败 (${decodeSafe(encName) || shareId})，请在设置确认 123 账号`), { statusCode: 502 });
    }
    const proxied = helpers.buildProxyUrl({ baseOrigin, key: spiderKey, type: spiderType, targetUrl: directUrl, secret });
    return { parse: 0, url: proxied && preferProxy ? ['代理', proxied, '原画', directUrl] : proxied ? ['原画', directUrl, '代理', proxied] : ['原画', directUrl] };
  }

  if (provider === '115' && parts.length >= 6 && parts[4] && !parts[5]) {
    const [, , shareId, encPwd, fid] = parts;
    const cookie = String(entry.cookie || '').trim();
    if (!cookie) throw Object.assign(new Error('115 网盘未配置 Cookie，请前往 /website 扫码登录'), { statusCode: 502 });
    const form = new URLSearchParams({ share_code: shareId, receive_code: decodeSafe(encPwd), file_id: fid });
    const r = await fetchTimed('https://webapi.115.com/share/downurl', {
      method: 'POST',
      headers: { Cookie: cookie, 'Content-Type': 'application/x-www-form-urlencoded', 'User-Agent': DEFAULT_UA, Referer: 'https://115.com/' },
      body: form.toString(),
    }, 8000);
    const j = await r.json().catch(() => ({}));
    const rawUrl = j.data?.url;
    const fileUrl = typeof rawUrl === 'string' ? rawUrl : String(rawUrl?.url || '');
    if (!fileUrl) throw Object.assign(new Error(j.msg || j.error || '115 网盘获取下载直链失败'), { statusCode: 502 });
    const hdrs = { Cookie: cookie, Referer: 'https://115.com/', 'User-Agent': DEFAULT_UA };
    const proxied = helpers.buildProxyUrl({ baseOrigin, key: spiderKey, type: spiderType, targetUrl: fileUrl, headers: hdrs, secret, opaque: Boolean(secret) });
    return { parse: 0, url: (wanouDb?.preferProxy ?? true) ? ['代理', proxied, '原画', fileUrl] : ['原画', fileUrl, '代理', proxied], header: hdrs };
  }

  if (provider === 'guangyapan' && parts.length >= 4 && parts[3] && !parts[3].startsWith('http')) {
    const [, , shareId, fileId, encTok = ''] = parts;
    const did = getGuangyaDid(entry);
    const tok = decodeSafe(encTok);
    const bearer = String(entry.token || '').trim();
    const r = await fetchTimed(`${GUANGYA_API}/nd.bizuserres.s/v1/get_share_download_url`, {
      method: 'POST',
      headers: guangyaHeaders(did, bearer),
      body: JSON.stringify({ fileId, accessToken: tok || shareId }),
    }, 8000);
    const j = await r.json().catch(() => ({}));
    const dlUrl = String(j.data?.downloadUrl || '').trim();
    if (!dlUrl) throw Object.assign(new Error(j.msg || j.message || '光鸭云盘获取播放直链失败，请前往 /website 扫码登录光鸭云盘后重试'), { statusCode: 502 });
    const proxied = helpers.buildProxyUrl({ baseOrigin, key: spiderKey, type: spiderType, targetUrl: dlUrl, secret });
    return { parse: 0, url: proxied && preferProxy ? ['代理', proxied, '原画', dlUrl] : proxied ? ['原画', dlUrl, '代理', proxied] : ['原画', dlUrl] };
  }

  return origPlayFn(fastify, req, spiderKey, spiderType, rawId);
}

function cleanWoniuText(raw) {
  return String(raw || '').replace(/\s+/g, ' ').trim();
}

function mergeCookies(base, setCookieList) {
  const map = new Map();
  for (const part of String(base || '').split(';')) {
    const idx = part.indexOf('=');
    if (idx > 0) {
      const k = part.slice(0, idx).trim();
      const v = part.slice(idx + 1).trim();
      if (k && v) map.set(k, v);
    }
  }
  for (const item of Array.isArray(setCookieList) ? setCookieList : []) {
    const first = String(item || '').split(';')[0] || '';
    const idx = first.indexOf('=');
    if (idx > 0) {
      const k = first.slice(0, idx).trim();
      const v = first.slice(idx + 1).trim();
      if (k) {
        if (v && v !== 'deleted') map.set(k, v);
        else map.delete(k);
      }
    }
  }
  return Array.from(map.entries()).map(([k, v]) => `${k}=${v}`).join('; ');
}

function collectResCookies(res) {
  const out = typeof res.headers?.getSetCookie === 'function' ? [...res.headers.getSetCookie()] : [];
  const sc = res.headers?.get?.('set-cookie');
  if (sc && out.length === 0) out.push(sc);
  const xsc = res.headers?.get?.('x-site-set-cookie');
  if (xsc) {
    try {
      const arr = JSON.parse(xsc);
      if (Array.isArray(arr)) out.push(...arr.filter((x) => typeof x === 'string'));
    } catch { /* ignore */ }
  }
  return out;
}

async function loginWoniuAccount(origin, username, password) {
  const base = String(origin || 'https://wn4k.com').replace(/\/+$/, '');
  const getRes = await fetchTimed(`${base}/user/login/`, {
    headers: { 'User-Agent': DEFAULT_UA, Referer: `${base}/` },
  }, 8000);
  const loginHtml = await getRes.text();
  let cookie = mergeCookies('', collectResCookies(getRes));
  const form = new URLSearchParams();
  for (const m of loginHtml.matchAll(/<input[^>]*type=["']hidden["'][^>]*name=["']([^"']+)["'][^>]*value=["']([^"']*)["'][^>]*>/gi)) {
    if (m[1]) form.set(m[1], m[2] || '');
  }
  form.set('user_name', username);
  form.set('user_pwd', password);
  const postRes = await fetchTimed(`${base}/user/login.html`, {
    method: 'POST',
    headers: {
      'User-Agent': DEFAULT_UA,
      Referer: `${base}/user/login/`,
      'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
      'X-Requested-With': 'XMLHttpRequest',
      ...(cookie ? { Cookie: cookie, 'X-Site-Cookie': cookie } : {}),
    },
    body: form.toString(),
  }, 8000);
  cookie = mergeCookies(cookie, collectResCookies(postRes));
  const body = await postRes.text();
  try {
    const json = JSON.parse(body);
    if (Number(json.code) === 1) {
      return { ok: Boolean(cookie), cookie, message: json.msg || '登录成功' };
    }
    return {
      ok: false,
      cookie: '',
      message:
        Number(json.code) === 1001 && /:\d+\/woniu$/i.test(base)
          ? '当前远程代理端需升级后才能转发表单登录，请直接粘贴浏览器登录后的 Cookie（含 user_id=...）'
          : json.msg || `登录失败 (${json.code ?? postRes.status})`,
    };
  } catch {
    const ok = /(?:^|;\s*)user_id=(?!0\b)\w+/.test(cookie);
    return { ok, cookie, message: ok ? '登录成功' : '登录响应异常，请检查账号或粘贴 Cookie' };
  }
}

async function getWoniuState(fastify) {
  if (fastify) globalThis.__uzvFastify = fastify;
  const f = fastify || globalThis.__uzvFastify;
  let dbCfg = {};
  try { dbCfg = (await f?.db?.get?.('woniu')) || {}; } catch { /* ignore */ }
  const memCfg = globalThis.__uzvWoniuAuth || {};
  return { ...dbCfg, ...memCfg };
}

async function saveWoniuState(nextCfg) {
  globalThis.__uzvWoniuAuth = nextCfg;
  const f = globalThis.__uzvFastify;
  try {
    await f?.db?.set?.('woniu', nextCfg);
    f?.cache?.clear?.();
  } catch { /* ignore */ }
}

async function resolveWoniuOrigin(fastify, kit) {
  const f = fastify || globalThis.__uzvFastify;
  try {
    const sites = (await f?.db?.get?.('sitesConfig')) || [];
    const entry = Array.isArray(sites) ? sites.find((s) => s && s.key === 'woniu') : null;
    const configured = entry?.urls?.find((u) => typeof u === 'string' && /^https?:\/\//i.test(u.trim()));
    if (configured) return configured.trim().replace(/\/+$/, '');
  } catch { /* ignore */ }
  try {
    const mirrors = await kit?.resolveMirrors?.(f);
    if (Array.isArray(mirrors) && mirrors[0]) return String(mirrors[0]).replace(/\/+$/, '');
  } catch { /* ignore */ }
  return 'https://wn4k.com';
}

async function buildLegacyWoniuDetail(fastify, kit, req, itemId, detailPath, helpers) {
  const cfg = await getWoniuState(fastify);
  let cookie = cleanWoniuText(cfg.cookie || '');
  const username = cleanWoniuText(cfg.username || '');
  const password = String(cfg.password || '');
  const origin = await resolveWoniuOrigin(fastify, kit);
  if (!cookie && username && password) {
    const auth = await loginWoniuAccount(origin, username, password).catch(() => ({ ok: false, cookie: '' }));
    if (auth.ok && auth.cookie) {
      cookie = auth.cookie;
      await saveWoniuState({ ...cfg, cookie, updatedAt: new Date().toISOString() });
    }
  }
  const extraHeaders = cookie ? { Cookie: cookie, 'X-Site-Cookie': cookie } : undefined;
  const page = await kit.fetchMirrorRaw(fastify, detailPath, extraHeaders ? { headers: extraHeaders } : {});
  const html = page.html;
  const baseUrl = page.baseUrl;
  const $ = helpers.mt(html);
  const lines = helpers.jbe(html, $);
  const { shareNotice, ...play } = await kit.resolveShareLines(fastify, lines);

  const name =
    cleanWoniuText($('h1.premium-title, h1.mobile-detail-title').first().text()) ||
    cleanWoniuText($('h1').first().text()) ||
    itemId;
  const picEl = $('.premium-poster img').first()[0];
  const histPic = $('.mac_history_set').first().attr('data-pic');
  const rawPic =
    picEl?.attribs?.['data-src'] || picEl?.attribs?.['data-original'] || picEl?.attribs?.src || histPic || '';
  const pic = rawPic ? helpers.Pr(baseUrl, rawPic) : '';

  let year = '';
  let area = '';
  let typeName = '';
  let tagRemark = '';
  $('.premium-tags-top .p-tag').each((_, el) => {
    if ($(el).hasClass('score')) return;
    const txt = cleanWoniuText($(el).text());
    if (!txt || /^★/.test(txt)) return;
    if (/^(?:19|20)\d{2}$/.test(txt)) year = txt;
    else if (/^\d{3,4}P|4K|HDR|WEB/i.test(txt)) tagRemark = txt;
    else if (!area && txt.length <= 8) area = txt;
    else if (!typeName) typeName = txt;
  });
  const metaMap = new Map();
  $('.premium-meta-grid .meta-item').each((_, el) => {
    const k = cleanWoniuText($(el).find('.m-label').first().text()).replace(/[：:]$/, '');
    const v = cleanWoniuText($(el).find('.m-val').first().text());
    if (k && v) metaMap.set(k, v);
  });
  const plot = cleanWoniuText($('#detailDescText').first().text()) || String($('meta[name="description"]').attr('content') || '').trim();
  const remarks = metaMap.get('备注') || tagRemark;

  const locked = ($('.pan-lock-box').length > 0 || $('.pan-link-item.is-locked').length > 0) && !play.vod_play_url;
  if (locked) {
    const localOrigin = String(helpers.getOrigin(req) || `http://127.0.0.1:${process.env.DEV_HTTP_PORT || 2333}`).replace(/\/+$/, '');
    play.vod_play_from = '配置入口';
    play.vod_play_url = `登录蜗牛账号$${localOrigin}/woniu-auth`;
  }
  const contentBody = locked
    ? `【提示：蜗牛影视网盘资源已锁定，点击「立即播放」配置蜗牛账号或 Cookie 后即可解锁全部网盘线路】\n${plot}`.trim()
    : shareNotice
      ? `${shareNotice}\n${plot}`.trim()
      : plot;

  return {
    vod_id: itemId,
    vod_name: name,
    vod_pic: pic,
    ...(year ? { vod_year: year } : {}),
    ...(area ? { vod_area: area } : {}),
    ...(typeName ? { type_name: typeName } : {}),
    ...(remarks ? { vod_remarks: remarks } : {}),
    ...(metaMap.get('导演') ? { vod_director: metaMap.get('导演') } : {}),
    ...(metaMap.get('主演') ? { vod_actor: metaMap.get('主演') } : {}),
    vod_content: contentBody,
    ...play,
  };
}

function handleWoniuAuthHttp(inReq, outRes) {
  if (inReq.method === 'GET') {
    getWoniuState().then((cfg) => {
      const hasAuth = Boolean((cfg.cookie && String(cfg.cookie).trim()) || (cfg.username && String(cfg.username).trim()));
      const safeUser = String(cfg.username || '').replace(/[&<>"']/g, '');
      const html = `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>蜗牛影视账号配置</title>
<style>
body{margin:0;padding:20px;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:#111318;color:#f3f4f6}
.card{max-width:420px;margin:12px auto;background:#1b1f27;border-radius:14px;padding:20px;box-shadow:0 8px 28px rgba(0,0,0,.35)}
h1{font-size:18px;margin:0 0 6px}p{font-size:13px;color:#9ca3af;margin:0 0 16px;line-height:1.5}
label{display:block;font-size:13px;color:#d1d5db;margin:12px 0 6px}
input,textarea{width:100%;box-sizing:border-box;background:#111318;border:1px solid #374151;color:#fff;border-radius:8px;padding:10px 12px;font-size:14px}
button{width:100%;margin-top:16px;height:42px;border:0;border-radius:8px;background:#2563eb;color:#fff;font-size:15px;font-weight:600}
button.sec{background:#374151;margin-top:10px}#msg{margin-top:12px;font-size:13px;line-height:1.5}
</style></head><body><div class="card">
<h1>蜗牛 I 4K 账号解锁</h1>
<p>蜗牛站点需登录会员账号后才能查看网盘分享链接。${hasAuth ? '当前状态：已保存凭据。' : '当前状态：未配置。'}</p>
<label>登录账号</label><input id="u" value="${safeUser}" placeholder="请输入蜗牛账号" autocomplete="username">
<label>登录密码</label><input id="p" type="password" placeholder="请输入蜗牛密码" autocomplete="current-password">
<label>或直接粘贴 Cookie（含 user_id=...，可选）</label><textarea id="c" rows="2" placeholder="user_id=...; user_check=..."></textarea>
<button id="sub" type="button">保存并登录</button>
<button id="clr" class="sec" type="button">清除已保存凭据</button>
<div id="msg"></div></div>
<script>
const msg=document.getElementById('msg');
document.getElementById('sub').onclick=async()=>{
  msg.style.color='#93c5fd';msg.textContent='正在验证并保存...';
  const r=await fetch('/woniu-auth',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:document.getElementById('u').value.trim(),password:document.getElementById('p').value,cookie:document.getElementById('c').value.trim()})});
  const j=await r.json().catch(()=>({ok:false,message:'请求失败'}));
  msg.style.color=j.ok?'#34d399':'#f87171';
  msg.textContent=j.message||(j.ok?'保存成功，请点击左上角返回详情页':'登录失败');
};
document.getElementById('clr').onclick=async()=>{
  await fetch('/woniu-auth',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({clear:true})});
  msg.style.color='#93c5fd';msg.textContent='已清除凭据';
};
</script></body></html>`;
      outRes.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
      outRes.end(html);
    });
    return;
  }
  if (inReq.method === 'POST') {
    const chunks = [];
    inReq.on('data', (c) => chunks.push(Buffer.from(c)));
    inReq.on('end', async () => {
      const sendJson = (code, obj) => {
        outRes.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
        outRes.end(JSON.stringify(obj));
      };
      try {
        const body = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
        if (body.clear) {
          await saveWoniuState({});
          return sendJson(200, { ok: true, message: '已清除蜗牛凭据' });
        }
        const username = String(body.username || '').trim();
        const password = String(body.password || '');
        const manualCookie = String(body.cookie || '').trim();
        if (manualCookie) {
          await saveWoniuState({ username, password, cookie: manualCookie, updatedAt: new Date().toISOString() });
          return sendJson(200, { ok: true, message: 'Cookie 已保存！请点击左上角返回详情页自动刷新' });
        }
        if (!username || !password) {
          return sendJson(400, { ok: false, message: '请填写蜗牛账号和密码（或直接粘贴 Cookie）' });
        }
        const origin = await resolveWoniuOrigin();
        const auth = await loginWoniuAccount(origin, username, password);
        await saveWoniuState({ username, password, ...(auth.cookie ? { cookie: auth.cookie } : {}), updatedAt: new Date().toISOString() });
        return sendJson(200, {
          ok: auth.ok,
          message: auth.ok ? '登录成功！请点击左上角返回详情页查看全部网盘线路' : auth.message,
        });
      } catch (err) {
        return sendJson(502, { ok: false, message: err instanceof Error ? `连接失败：${err.message}` : '连接失败' });
      }
    });
    return;
  }
  outRes.writeHead(405);
  outRes.end();
}

function installLegacyPanGlobals() {
  globalThis.__uzvExtractShareLinks = extractLegacyShareLinks;
  globalThis.__uzvResolveExtendedShares = resolveLegacyExtendedShares;
  globalThis.__uzvPlayExtendedShare = playLegacyExtendedShare;
  globalThis.__uzvBuildWoniuDetail = buildLegacyWoniuDetail;
  globalThis.__uzvHandleWoniuAuthHttp = handleWoniuAuthHttp;
}

module.exports = {
  installLegacyPanGlobals,
  extractLegacyShareLinks,
  resolveLegacyExtendedShares,
  playLegacyExtendedShare,
  buildLegacyWoniuDetail,
  handleWoniuAuthHttp,
};
