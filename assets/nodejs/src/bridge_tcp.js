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
 * @param {{port: number, token: string, dataDir: string, host?: string,
 *          reconnect?: boolean, reconnectDelayMs?: number, onReconnect?: () => void}} opts
 * @returns {Promise<{bridge: object, close: () => void}>}
 */
function connectTcpBridge({
  port,
  token,
  dataDir,
  host = '127.0.0.1',
  reconnect = false,
  reconnectDelayMs = 200,
  onReconnect = null,
}) {
  return new Promise((resolve, reject) => {
    const bus = new EventEmitter();
    const outbox = [];
    let currentSocket = null;
    let closedByCaller = false;
    let initialResolved = false;
    let reconnectTimer = null;
    let attempt = 0;

    function writeFrame(frame) {
      const line = JSON.stringify(frame) + '\n';
      if (currentSocket && !currentSocket.destroyed && currentSocket.writable) {
        currentSocket.write(line);
      } else if (reconnect && !closedByCaller) {
        if (outbox.length < 128) outbox.push(line);
      }
    }

    function scheduleReconnect() {
      if (!reconnect || closedByCaller || reconnectTimer) return;
      const delay = Math.min(reconnectDelayMs * Math.pow(2, Math.min(attempt, 4)), 3000);
      attempt++;
      reconnectTimer = setTimeout(() => {
        reconnectTimer = null;
        if (!closedByCaller) dial(true);
      }, delay);
      if (typeof reconnectTimer.unref === 'function') reconnectTimer.unref();
    }

    function dial(isReconnect) {
      const socket = net.connect({ port, host });
      currentSocket = socket;
      let buffer = '';

      socket.setEncoding('utf8');
      socket.setNoDelay(true);
      if (typeof socket.setKeepAlive === 'function') socket.setKeepAlive(true, 15000);

      const onInitialError = (err) => {
        if (!initialResolved && !isReconnect) {
          reject(err);
        } else {
          scheduleReconnect();
        }
      };
      socket.once('error', onInitialError);

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

      socket.on('close', () => {
        if (currentSocket === socket) currentSocket = null;
        if (closedByCaller || !reconnect) {
          bus.emit('__closed__');
        } else if (initialResolved) {
          scheduleReconnect();
        }
      });

      socket.once('connect', () => {
        socket.off('error', onInitialError);
        socket.on('error', () => {});
        attempt = 0;
        socket.write(JSON.stringify({ hello: token }) + '\n');
        while (outbox.length > 0 && !socket.destroyed) {
          socket.write(outbox.shift());
        }
        if (!initialResolved) {
          initialResolved = true;
          const bridge = {
            getDataDir: () => dataDir,
            send(name, message) { writeFrame({ c: name, m: String(message) }); },
            channel(name) {
              return {
                send(message) { writeFrame({ c: name, m: String(message) }); },
                on(handler) { bus.on(name, handler); },
              };
            },
            onClose(handler) { bus.once('__closed__', handler); },
            onReconnect(handler) { bus.on('__reconnected__', handler); },
          };
          const close = () => {
            closedByCaller = true;
            if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
            if (currentSocket) currentSocket.destroy();
          };
          resolve({ bridge, close });
        } else {
          bus.emit('__reconnected__');
          if (typeof onReconnect === 'function') {
            try { onReconnect(); } catch { /* ignore */ }
          }
        }
      });
    }

    dial(false);
  });
}

module.exports = { connectTcpBridge };
