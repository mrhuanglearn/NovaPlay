'use strict';
/**
 * Entry used on Android: node main.js --bridge-port=N --bridge-token=T --data-dir=D
 * (the same three values are also read from UZV_BRIDGE_PORT / UZV_BRIDGE_TOKEN / UZV_DATA_DIR).
 * Connects the TCP bridge to the Kotlin plugin, then starts the host.
 *
 * The values travel as command-line arguments first because that is what survives everywhere: observed on Waydroid (ARM code
 * translated on an x86 host), variables set with Os.setenv() on the Java side were not visible to this process.
 */

const { connectTcpBridge } = require('./bridge_tcp');
const { startHost } = require('./index');

function readConfig(env = process.env, argv = process.argv.slice(2)) {
  const arg = (name) => {
    const prefix = `--${name}=`;
    const hit = argv.find((a) => a.startsWith(prefix));
    return hit === undefined ? undefined : hit.slice(prefix.length);
  };
  return {
    port: Number(arg('bridge-port') ?? env.UZV_BRIDGE_PORT),
    token: arg('bridge-token') ?? env.UZV_BRIDGE_TOKEN,
    dataDir: arg('data-dir') ?? env.UZV_DATA_DIR,
  };
}

/** @param {{exit?: (code: number) => void}} [opts] exit: what to do when the bridge closes (default: nothing, see the entry below). */
async function main(env = process.env, argv = process.argv.slice(2), { exit = () => {} } = {}) {
  const { port, token, dataDir } = readConfig(env, argv);
  if (!port || !token || !dataDir) {
    throw new Error('--bridge-port, --bridge-token and --data-dir (or UZV_BRIDGE_PORT, UZV_BRIDGE_TOKEN, UZV_DATA_DIR) are required');
  }
  const { bridge, close } = await connectTcpBridge({ port, token, dataDir, reconnect: true });
  const host = startHost({ bridge });
  bridge.onClose(async () => { await host.dispose(); close(); exit(0); });
  return host;
}

module.exports = { main, readConfig };

if (require.main === module) {
  // This process IS the app: process.exit() inside the embedded runtime aborts the whole application (observed: SIGABRT).
  // A failure is therefore logged and the runtime stays idle; Dart sees that "Node ready" never arrives and reports it.
  main().catch((e) => { console.error(e); });
  setInterval(() => {}, 1 << 30);
}
