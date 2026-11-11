'use strict';
/**
 * Entry point of the embedded Node runtime (nodejs-mobile). It is started once by the Flutter app and
 * exposes the catpaw and service managers over the `flutter-bridge` channels.
 */

const path = require('path');
const { Channel } = require('./protocol');
const { createCatpawHost } = require('./catpaw');
const { createServiceManager } = require('./services');

const DEFAULT_WORKER = path.join(__dirname, 'worker.js');

/**
 * @param {{bridge?: object, workerEntryPath?: string, process?: NodeJS.Process}} [opts]
 */
function startHost(opts = {}) {
  const bridge = opts.bridge || require('flutter-bridge');
  const proc = opts.process || process;
  const workerEntryPath = opts.workerEntryPath || DEFAULT_WORKER;
  const status = (t) => bridge.channel(Channel.status).send(t);

  const onUncaught = (e) => status('error: ' + ((e && e.stack) || e));
  const onRejection = (e) => {
    const text = (e && (e.message || e.stack)) || String(e);
    if (/WebAssembly|undici|llhttp/.test(text)) return;
    status('rejection: ' + ((e && e.stack) || e));
  };
  proc.on('uncaughtException', onUncaught);
  proc.on('unhandledRejection', onRejection);

  const services = createServiceManager({ bridge, workerEntryPath });
  const catpaw = createCatpawHost({ bridge, workerEntryPath });
  services.attach();
  catpaw.attach();
  status('Node ready, version ' + proc.version);

  return {
    catpaw,
    services,
    /** Detach process hooks and terminate every worker. */
    async dispose() {
      proc.off('uncaughtException', onUncaught);
      proc.off('unhandledRejection', onRejection);
      await Promise.all([catpaw.terminateAll(), services.terminateAll()]);
    },
  };
}

module.exports = { startHost };

if (require.main === module) {
  startHost();
  // keep the event loop alive for the lifetime of the host
  setInterval(() => {}, 1 << 30);
}
