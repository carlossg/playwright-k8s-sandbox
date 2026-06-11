// Headless Playwright server, env-driven so the same baked image works for
// all three backends (agent-sandbox, OpenShell, substrate) and we can sweep
// gVisor-compatibility flags without rebuilding. Baked into the slim image
// at /server.js by proxy/test/playwright-substrate.Dockerfile.
//
//   PORT             listen port (default 80 — required for substrate, atenet
//                    -router hardcodes upstream to :80; agent-sandbox/openshell
//                    can use any port)
//   PW_WS_PATH       wsPath for chromium.launchServer (default '/')
//   CHROMIUM_ARGS    comma-separated extra args, e.g.
//                    "--no-sandbox,--disable-setuid-sandbox,--single-process"
const { chromium } = require('playwright');

const PORT = Number(process.env.PORT || '80');
const PATH = process.env.PW_WS_PATH || '/';
const ARGS = (process.env.CHROMIUM_ARGS || '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);

(async () => {
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
