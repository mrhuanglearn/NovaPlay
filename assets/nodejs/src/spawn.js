'use strict';

const fs = require('fs');
const { Worker } = require('worker_threads');

/**
 * Start a worker thread and forward its stdout/stderr lines to `onStatus`.
 * @param {{workerEntryPath: string, workerData: object, name: string,
 *          onMsg?: (m: any) => void, onError?: (e: Error) => void,
 *          onExit?: (code: number) => void,
 *          onStatus?: (line: string) => void, captureStdout?: boolean}} opts
 */
function spawnWorker({ workerEntryPath, workerData, name, onMsg, onError, onExit, onStatus, captureStdout = true }) {
  const worker = new Worker(workerEntryPath, { workerData, stdout: captureStdout, stderr: captureStdout });
  if (onMsg) worker.on('message', onMsg);
  if (onError) worker.on('error', onError);
  if (onExit) worker.on('exit', onExit);
  if (captureStdout && onStatus) {
    worker.stdout.on('data', (d) => { const t = d.toString().trim(); if (t) onStatus(`[stdout] ${name}: ${t}`); });
    worker.stderr.on('data', (d) => { const t = d.toString().trim(); if (t) onStatus(`[stderr] ${name}: ${t}`); });
  }
  return worker;
}

function removeDir(dir) {
  try { fs.rmSync(dir, { recursive: true, force: true }); } catch { /* best effort */ }
}

module.exports = { spawnWorker, removeDir };
