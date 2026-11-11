'use strict';
/**
 * Path policy used inside catpaw workers.
 *
 * Observed behaviour: file-system calls made by a spider script are not rejected; paths that fall
 * outside the allow-lists are transparently redirected into `<redirectRoot>/_redirect/<abs path>`.
 * Write-class calls are only allowed in `allowWriteDirs`; read-class calls are allowed in
 * `allowWriteDirs` + `allowReadDirs`.
 */

const fs = require('fs');
const path = require('path');

const READ_ASYNC = ['readFile', 'readdir', 'stat', 'lstat', 'access', 'readlink', 'realpath', 'exists',
  'createReadStream', 'open', 'opendir', 'cp', 'copyFile'];
const READ_SYNC = ['readFileSync', 'readdirSync', 'statSync', 'lstatSync', 'accessSync', 'existsSync',
  'readlinkSync', 'realpathSync', 'openSync', 'opendirSync', 'cpSync', 'copyFileSync'];
const WRITE_ASYNC = ['writeFile', 'mkdir', 'rmdir', 'unlink', 'rename', 'createWriteStream', 'appendFile', 'rm',
  'truncate', 'chown', 'chmod', 'utimes', 'mkdtemp', 'link', 'symlink', 'lutimes', 'lchmod', 'lchown'];
const WRITE_SYNC = ['writeFileSync', 'mkdirSync', 'rmdirSync', 'unlinkSync', 'renameSync', 'appendFileSync', 'rmSync',
  'truncateSync', 'chownSync', 'chmodSync', 'utimesSync', 'mkdtempSync', 'linkSync', 'symlinkSync', 'lutimesSync',
  'lchmodSync', 'lchownSync'];
const FSP_READ = ['readFile', 'readdir', 'stat', 'lstat', 'access', 'readlink', 'realpath', 'open', 'opendir', 'cp', 'copyFile'];
const FSP_WRITE = ['writeFile', 'mkdir', 'rmdir', 'unlink', 'rename', 'appendFile', 'rm', 'truncate', 'chown', 'chmod',
  'utimes', 'mkdtemp', 'link', 'symlink', 'lutimes', 'lchmod', 'lchown'];

// Captured before any patching so the policy never recurses into itself.
const realpath = fs.realpathSync.native || fs.realpathSync;
const mkdirSyncOriginal = fs.mkdirSync;

/** Resolve a directory to an absolute, symlink-free path when possible. */
function normDir(p) {
  const abs = path.resolve(p);
  try { return realpath(abs); } catch { return abs; }
}

/** Like normDir, but for paths that may not exist yet: resolve the deepest existing ancestor. */
function normPath(p) {
  const abs = path.resolve(String(p));
  try { return realpath(abs); } catch { /* fall through */ }
  let head = path.dirname(abs);
  let tail = path.basename(abs);
  while (head !== path.dirname(head)) {
    try { return path.join(realpath(head), tail); } catch {
      tail = path.join(path.basename(head), tail);
      head = path.dirname(head);
    }
  }
  return path.join(head, tail);
}

function isInside(dir, target) {
  return target === dir || target.startsWith(dir.endsWith(path.sep) ? dir : dir + path.sep);
}

/**
 * Create a policy object.
 * @param {{allowWriteDirs?: string[], allowReadDirs?: string[], redirectRoot?: string|null, dataDir?: string|null,
 *          onRedirect?: (kind: 'write'|'read', from: string, to: string) => void}} cfg
 */
function createPolicy(cfg = {}) {
  const writeDirs = (cfg.allowWriteDirs || []).map(normDir);
  const readDirs = (cfg.allowReadDirs || []).map(normDir);
  const redirectBase = cfg.redirectRoot
    ? path.join(cfg.redirectRoot, '_redirect')
    : cfg.dataDir ? path.join(cfg.dataDir, '_redirect') : null;
  const redirectRoot = redirectBase ? normDir(redirectBase) : null;
  const seen = new Set();

  function resolve(input, isWrite) {
    if (typeof input !== 'string' && !(input instanceof URL) && !Buffer.isBuffer(input)) return input;
    const target = normPath(input instanceof URL ? input.pathname : Buffer.isBuffer(input) ? input.toString() : input);
    const allowed = isWrite ? writeDirs : [...writeDirs, ...readDirs];
    if (allowed.some((d) => isInside(d, target))) return input;
    if (!redirectRoot) return input;
    // Never redirect something that already lives under the redirect area.
    if (isInside(redirectRoot, target)) return target;
    const dest = path.join(redirectRoot, target);
    if (!seen.has(dest)) {
      seen.add(dest);
      if (cfg.onRedirect) cfg.onRedirect(isWrite ? 'write' : 'read', target, dest);
    }
    if (isWrite) {
      try { mkdirSyncOriginal(path.dirname(dest), { recursive: true }); } catch { /* best effort */ }
    }
    return dest;
  }

  return { resolve, redirectRoot, writeDirs, readDirs };
}

function patchMethods(target, names, isWrite, policy) {
  for (const name of names) {
    if (typeof target[name] !== 'function') continue;
    const original = target[name];
    target[name] = function patched(first, ...rest) {
      // rename/copy style calls carry a second path; protect it as a write target as well.
      const mapped = policy.resolve(first, isWrite);
      if ((name === 'rename' || name === 'renameSync' || name === 'copyFile' || name === 'copyFileSync' ||
        name === 'cp' || name === 'cpSync' || name === 'link' || name === 'linkSync') && typeof rest[0] === 'string') {
        rest[0] = policy.resolve(rest[0], true);
      }
      return original.call(this, mapped, ...rest);
    };
  }
}

/** Patch `fs` and `fs/promises` in the current realm. Call once per worker. */
function installFsPolicy(policy) {
  const fsp = fs.promises;
  patchMethods(fs, READ_ASYNC, false, policy);
  patchMethods(fs, READ_SYNC, false, policy);
  patchMethods(fs, WRITE_ASYNC, true, policy);
  patchMethods(fs, WRITE_SYNC, true, policy);
  patchMethods(fsp, FSP_READ, false, policy);
  patchMethods(fsp, FSP_WRITE, true, policy);
}

module.exports = { createPolicy, installFsPolicy, normDir, normPath, isInside };
