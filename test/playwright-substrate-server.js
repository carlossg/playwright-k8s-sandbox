// Dual-protocol Playwright sandbox server, env-driven so the same baked image
// works for all three backends (agent-sandbox, OpenShell, substrate) and we can
// sweep gVisor-compatibility flags without rebuilding. Baked into the slim
// image at /server.js by proxy/test/playwright-substrate.Dockerfile.
//
// It always launches the native Playwright WebSocket server
// (chromium.launchServer) on PORT. When MCP_PORT is set it ALSO spawns
// @playwright/mcp as a second listener on that port — @playwright/mcp cannot
// share a process/port with chromium.launchServer, so the two protocols live
// on two ports and the proxy routes WS upgrades to PORT and plain HTTP (MCP)
// to MCP_PORT.
//
//   PORT             WS listen port (default 80 — required for substrate, atenet
//                    -router hardcodes upstream to :80; agent-sandbox/openshell
//                    can use any port)
//   PW_WS_PATH       wsPath for chromium.launchServer (default '/')
//   CHROMIUM_ARGS    comma-separated extra args, e.g.
//                    "--no-sandbox,--disable-setuid-sandbox,--single-process"
//   MCP_PORT         MCP-over-HTTP listen port; when unset, MCP is not started
//                    (single-protocol WS-only mode, e.g. substrate/gVisor)
const path = require('path');
const net = require('net');
const { spawn } = require('child_process');
const { chromium } = require('playwright');

const PORT = Number(process.env.PORT || '80');
const PATH = process.env.PW_WS_PATH || '/';
const ARGS = (process.env.CHROMIUM_ARGS || '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);
// Only an absent MCP_PORT selects WS-only mode; any value that IS set must be a
// valid TCP port, otherwise a typo (empty, non-numeric, zero, fractional, or
// out-of-range) would silently fall back to WS-only or hand @playwright/mcp a
// bogus --port. Fail fast instead.
function parseMcpPort(raw) {
  if (raw === undefined) return 0; // unset → single-protocol WS-only mode
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 1 || n > 65535) {
    throw new Error(
      'invalid MCP_PORT ' + JSON.stringify(raw) +
        ' (expected integer 1..65535, or unset for WS-only)'
    );
  }
  return n;
}
const MCP_PORT = parseMcpPort(process.env.MCP_PORT);

// Spawn @playwright/mcp on MCP_PORT. Resolve the CLI through the installed
// package (NODE_PATH points at the global modules dir); the package only
// exports "." so resolve via package.json and join cli.js.
function startMcp() {
  const pkgJson = require.resolve('@playwright/mcp/package.json');
  const cli = path.join(path.dirname(pkgJson), 'cli.js');
  const args = [
    cli,
    '--port', String(MCP_PORT),
    '--host', '0.0.0.0',
    '--headless',
    '--isolated',
    '--no-sandbox',
    // @playwright/mcp defaults to the branded "chrome" channel
    // (/opt/google/chrome/chrome), which the slim image does not ship — it only
    // bakes Playwright's bundled Chromium (`playwright install chromium`).
    // Pin the browser to chromium so browser_navigate launches the bundled
    // build instead of failing with "Chromium distribution 'chrome' is not
    // found".
    '--browser', 'chromium',
  ];
  console.log('spawning @playwright/mcp', { port: MCP_PORT, cli });
  const child = spawn(process.execPath, args, { stdio: 'inherit', env: process.env });
  child.on('exit', (code, signal) => {
    console.error('@playwright/mcp exited', { code, signal });
    process.exit(code === null ? 1 : code || 1);
  });
  return child;
}

// Poll a TCP port until it accepts a connection (or the deadline passes).
// @playwright/mcp binds its HTTP listener asynchronously after spawn, so we
// gate the WS launch below on the MCP port actually being up.
function waitForPort(port, host, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const attempt = () => {
      const remaining = deadline - Date.now();
      if (remaining <= 0) {
        reject(new Error('timed out waiting for ' + host + ':' + port));
        return;
      }
      const sock = net.connect({ port, host });
      // Bound each attempt by the time left until the deadline: a silently
      // dropped SYN never emits 'connect' or 'error', so without this the
      // socket — and this promise — could stay pending well past timeoutMs.
      sock.setTimeout(remaining);
      let done = false;
      const retry = () => {
        if (done) return; // 'timeout' + 'error' can both fire; settle once
        done = true;
        sock.destroy();
        if (Date.now() >= deadline) {
          reject(new Error('timed out waiting for ' + host + ':' + port));
        } else {
          setTimeout(attempt, 200);
        }
      };
      sock.once('connect', () => {
        if (done) return;
        done = true;
        sock.destroy();
        resolve();
      });
      sock.once('timeout', retry);
      sock.once('error', retry);
    };
    attempt();
  });
}

(async () => {
  if (MCP_PORT) {
    startMcp();
    // Kubernetes readiness gates on the WS port (PORT) only. To keep that a
    // valid proxy for "both listeners up", make sure the MCP port is actually
    // accepting connections BEFORE we launch the WS server that flips the pod
    // ready — otherwise the proxy could route an MCP request to a not-yet-bound
    // 9223. chromium.launchServer below then binds PORT strictly after this.
    console.log('waiting for @playwright/mcp to listen', { port: MCP_PORT });
    await waitForPort(MCP_PORT, '127.0.0.1', 60000);
    console.log('@playwright/mcp is listening', { port: MCP_PORT });
  }
  console.log('launching chromium', { port: PORT, wsPath: PATH, args: ARGS });
  const server = await chromium.launchServer({
    port: PORT,
    host: '0.0.0.0',
    wsPath: PATH,
    args: ARGS,
  });
  console.log('listening on', server.wsEndpoint());
  await new Promise(() => {});
})().catch((e) => {
  console.error('server error:', e && e.stack || e);
  process.exit(1);
});
