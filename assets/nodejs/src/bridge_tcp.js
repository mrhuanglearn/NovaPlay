'use strict';
/**
 * A `flutter-bridge` implementation over a loopback TCP socket.
 *
 * DESIGN CHOICE (not observed): the original ships a native `flutter-bridge` module inside its
 * libflutter_nodejs_mobile.so that was not recovered. This project's Kotlin plugin instead listens on
 * 127.0.0.1:<port> and the Node runtime connects to it. Frames are newline-delimited JSON:
 *     {"c": "<channel>", "m": "<string payload>"}
 * The first frame Node sends is {"hello": "<token>"} so the plugin can reject foreign local processes.
 */

const net = require('net');
const { EventEmitter } = require('events');

/**
 * @param {{port: number, token: string, dataDir: string, host?: string}} opts
 * @returns {Promise<{bridge: object, close: () => void}>}
 */
function connectTcpBridge({ port, token, dataDir, host = '127.0.0.1' }) {
  return new Promise((resolve, reject) => {
    const socket = net.connect({ port, host });
    const bus = new EventEmitter();
    let buffer = '';

    socket.setEncoding('utf8');
    socket.setNoDelay(true);
    socket.once('error', reject);
    socket.on('data', (chunk) => {
      buffer += chunk;
      let nl;
      while ((nl = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, nl);
        buffer = buffer.slice(nl + 1);
        if (!line) continue;
        let frame;
        try { frame = JSON.parse(line); } catch { continue; }
        if (typeof frame.c === 'string' && typeof frame.m === 'string') bus.emit(frame.c, frame.m);
      }
    });
    socket.on('close', () => bus.emit('__closed__'));

    socket.once('connect', () => {
      socket.off('error', reject);
      socket.on('error', () => {});
      socket.write(JSON.stringify({ hello: token }) + '\n');
      const bridge = {
        getDataDir: () => dataDir,
        channel(name) {
          return {
            send(message) { socket.write(JSON.stringify({ c: name, m: String(message) }) + '\n'); },
            on(handler) { bus.on(name, handler); },
          };
        },
        onClose(handler) { bus.once('__closed__', handler); },
      };
      resolve({ bridge, close: () => socket.destroy() });
    });
  });
}

module.exports = { connectTcpBridge };
