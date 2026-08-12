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
const { spawn } = require('child_process');
const { chromium } = require('playwright');

const PORT = Number(process.env.PORT || '80');
const PATH = process.env.PW_WS_PATH || '/';
const ARGS = (process.env.CHROMIUM_ARGS || '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);
const MCP_PORT = process.env.MCP_PORT ? Number(process.env.MCP_PORT) : 0;

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

(async () => {
  if (MCP_PORT) startMcp();
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
