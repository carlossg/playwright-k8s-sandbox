# Dual-protocol sandbox serving (MCP over HTTP + native Playwright WS) — design notes

**Status:** Implemented end-to-end for the `sandboxclaim` backend. The proxy
routes both protocols (two-port model), the shared slim sandbox image serves
both (native Playwright WS via `chromium.launchServer` + MCP-over-HTTP via
`@playwright/mcp`), and `harness.sh e2e` drives and asserts both.

Since `@playwright/mcp` cannot share a process/port with `chromium.launchServer`
(see [Research conclusion](#research-conclusion)), we chose the **two-port** model
over an in-container front dispatcher: the sandbox serves the native WebSocket
protocol on one port and MCP-over-HTTP on a second port, and the **proxy dials the
correct one per protocol** (WS upgrades → WS port, plain HTTP → MCP port). This is
simpler than a dispatcher — nothing new runs inside the container besides the
second server — and keeps the proxy's existing `isWebsocketUpgrade` split as the
single routing decision.

**Implemented (proxy, Go):**

- `backend.Endpoint` carries `Port` (WS) and `MCPPort` (MCP-over-HTTP); `MCPAddr()`
  falls back to `Port` when `MCPPort == 0`, so single-port sandboxes and
  Host-header-routed backends (substrate) are unchanged.
- `internal/proxy/proxy.go` `handleHTTP` dials `Endpoint.MCPAddr()`; `handleWS`
  still dials `Endpoint.Addr()`.
- `config.SandboxMCPPort` (env `SANDBOX_MCP_PORT`, optional) + `deploy/proxy.yaml`.
- Only the `sandboxclaim` backend populates `MCPPort` today (in scope);
  substrate/isola/kars leave it 0 and behave exactly as before.

**Implemented (sandbox image + e2e, test-only):**

- `test/playwright-substrate-server.js` launches `chromium.launchServer` on `PORT`
  and, when `MCP_PORT` is set, spawns `@playwright/mcp` on that port (see
  [As implemented](#as-implemented)).
- `test/playwright-scripts.yaml` gains `mcp-client.js`, and
  `test/playwright-mcp-client-job.yaml` runs it; `harness.sh cmd_e2e` drives WS
  (alpha, beta) and MCP (gamma) legs and asserts all three land on distinct
  sandboxes.

- [Motivation](#motivation)
- [Current state](#current-state)
- [Research conclusion](#research-conclusion)
- [Chosen architecture: two ports](#chosen-architecture-two-ports)
- [Alternative considered (not chosen): in-container front dispatcher](#alternative-considered-not-chosen-in-container-front-dispatcher)
- [Why not a single process/listener](#why-not-a-single-processlistener)
- [As implemented](#as-implemented)
- [Out of scope](#out-of-scope)
- [Notes / resolved risks](#notes--resolved-risks)

## Motivation

`config.SandboxPort` (`internal/config/config.go`) originally modelled a single
`Host:Port` per client, on the assumption that the sandbox container multiplexes
both the native Playwright WebSocket protocol and MCP over HTTP on one port — the
same way the proxy multiplexes them on its own listen port.

That assumption does not hold: `@playwright/mcp` cannot share a process or port
with `chromium.launchServer` (see below). The sandbox therefore has to serve the
two protocols on two ports, and the proxy has to learn which port to dial per
protocol — which is what `SANDBOX_MCP_PORT` / `Endpoint.MCPPort` now provide.

## Current state

**Proxy side:**

- `internal/proxy/proxy.go` routes both protocols on its single listen port. It
  detects WS upgrades via the `Connection`/`Upgrade` headers (`isWebsocketUpgrade`)
  and reverse-proxies plain HTTP (for MCP-over-HTTP / SSE) with `FlushInterval: -1`
  for immediate streaming flush. `handleWS` dials `Endpoint.Addr()` (WS port);
  `handleHTTP` dials `Endpoint.MCPAddr()` (MCP port, falling back to the WS port).
- Backend selection is by client pod IP → `playwright-id`
  (`internal/identify/identify.go`), independent of protocol.

**Sandbox side:**

- `test/playwright-substrate-server.js` runs `chromium.launchServer(...)` on `PORT`
  and, when `MCP_PORT` is set, also spawns `@playwright/mcp --port $MCP_PORT` as a
  second listener. The two protocols live on two ports; the proxy picks between
  them.
- `test/harness.sh` `cmd_e2e` (agent-sandbox path) drives both: WS via
  `test/playwright-client-job.yaml` + `client.js`, and MCP via
  `test/playwright-mcp-client-job.yaml` + `mcp-client.js`.

## Research conclusion

**`@playwright/mcp` (the official Microsoft Playwright MCP server) cannot share a
Node process or port with `chromium.launchServer`.** Two independent findings drive
this:

1. **Separate listeners.** `chromium.launchServer` owns its own internal HTTP
   server bound to its port; there is no public API to attach additional routes or
   an MCP handler to it. `@playwright/mcp` in HTTP mode (`--port`) starts its own
   HTTP listener. Two servers, two ports. The official package does expose a
   programmatic embed API (`createConnection` + `SSEServerTransport('/messages', res)`
   mounted on an existing `http.createServer`), but that lets you host *MCP* inside
   your own server — it does not let you host MCP inside `launchServer`'s server.

2. **Separate browsers.** `@playwright/mcp` launches (and drives) its *own* Chromium
   instance by default; it does not attach to the browser that `launchServer`
   exposes over WS. (It *can* attach to an external browser via `--cdp-endpoint`,
   but that is a different, heavier integration and unnecessary here.)

**Therefore the two protocols must be served on two ports.** We expose both ports
directly and let the proxy route between them (WS upgrade → WS port, plain HTTP →
MCP port). This keeps the proxy's existing `isWebsocketUpgrade` split as the single
routing decision and needs no in-container dispatcher — the proxy already models
"which port per protocol" via `Endpoint.Port` / `Endpoint.MCPAddr()`.

### Reference

- `@playwright/mcp` HTTP transport: `npx @playwright/mcp@latest --port <port>`;
  MCP endpoint at `/mcp` (streamable-http), legacy SSE at `/sse` + `/messages`.
- Relevant CLI flags: `--port`, `--host` (use `0.0.0.0`), `--headless`,
  `--browser` (pin to `chromium` — see [As implemented](#as-implemented)),
  `--isolated`, `--no-sandbox`, `--cdp-endpoint`.
- Source: <https://github.com/microsoft/playwright-mcp>,
  <https://www.npmjs.com/package/@playwright/mcp>.

## Chosen architecture: two ports

The sandbox runs two independent servers on two ports; the proxy routes to the
correct one per protocol:

```
        ┌─ playwright-proxy ─┐
        │ isWebsocketUpgrade │
   WS ──┤                    ├── plain HTTP (MCP)
        ▼                    ▼
  sandbox :PORT        sandbox :SANDBOX_MCP_PORT
  chromium.launchServer   @playwright/mcp
  (Endpoint.Addr)         (Endpoint.MCPAddr)
```

No in-container dispatcher is required: each server owns its own port, and the
proxy's existing `isWebsocketUpgrade` check is the only routing decision.

## Alternative considered (not chosen): in-container front dispatcher

Before opting for two ports, a single-port design was considered where one public
port is fronted by a small dispatcher that mirrors `proxy.go`. It was rejected as
more complex than simply exposing a second port. Kept here for reference:

A single container, three parts, one public port (9222):

```
                          :9222 (SANDBOX_PORT, 0.0.0.0)  ← proxy dials here
                                    │
                         ┌── front dispatcher (Node http.Server) ──┐
                         │  Upgrade: websocket?                     │
              yes ───────┤                                         ├─────── no (plain HTTP)
                         ▼                                         ▼
        chromium.launchServer                          @playwright/mcp (child proc)
        127.0.0.1:PW_WS_INTERNAL_PORT                  127.0.0.1:PW_MCP_INTERNAL_PORT
        wsPath = PW_WS_PATH                            streamable-http at /mcp
        (existing behaviour)                           (its own Chromium)
```

- **Dispatch logic** copies `proxy.go`'s `isWebsocketUpgrade`: `Connection`
  contains `upgrade` AND `Upgrade` equals `websocket`. WS path hijacks and
  TCP-splices to the internal WS port (same hijack + bidirectional `io.Copy`
  pattern as `proxy.go`'s `handleWS`). HTTP path pipes to the internal MCP port.
- Rejected because it duplicates the proxy's dispatch one hop downstream and grows
  `server.js`, for no benefit over exposing a second port that the proxy already
  knows how to dial.

## Why not a single process/listener

Considered and rejected:

- **Embed MCP into `launchServer`'s server** — not possible; no public hook.
- **Embed `launchServer` into an MCP/Express server** — `launchServer` insists on
  owning its own listener; you cannot hand it an existing server object.
- **One `http.Server` hosting both via `createConnection` embed + a WS handler
  proxying to `launchServer`** — still needs `launchServer` on its own port, so
  you end up with the dispatcher anyway, plus more in-process coupling and a
  larger `server.js`.

## As implemented

Test-only; no additional Go changes beyond the proxy two-port routing above.

**(a) Image (`test/playwright-substrate.Dockerfile`)**
- Global npm install pins `playwright` + `playwright-core` to **1.53.0** and adds
  `@playwright/mcp@0.0.29` + `@modelcontextprotocol/sdk@1.30.0` (the SDK is also
  used by the MCP client Job). `playwright-core` is installed at the global root
  because `@playwright/mcp` is ESM and its `import 'playwright-core'` walks
  `node_modules` from the package dir (ignoring `NODE_PATH`).
- No extra browser download — MCP reuses the single installed Chromium via
  `PLAYWRIGHT_BROWSERS_PATH`. Exposes `9222` (WS) and `9223` (MCP).

**(b) Server (`test/playwright-substrate-server.js`)**
- Always launches `chromium.launchServer` on `PORT`. When `MCP_PORT` is set, it
  also spawns `@playwright/mcp --port $MCP_PORT --host 0.0.0.0 --headless
  --isolated --no-sandbox --browser chromium`. `--browser chromium` is required:
  `@playwright/mcp` defaults to the branded `chrome` channel
  (`/opt/google/chrome/chrome`), which the slim image does not ship.
- When `MCP_PORT` is unset the image is WS-only (unchanged for substrate/gVisor).

**(c) Sandbox manifest (`test/playwright-sandboxtemplate.yaml`)**
- `PORT=9222`, `MCP_PORT=9223`, both container ports exposed. Readiness gates on
  the WS port (9222): `@playwright/mcp` binds its HTTP port immediately, whereas
  `chromium.launchServer` binds only after launching the browser, so a ready WS
  port implies the MCP port is already up.
- `test/playwright-warmpool.yaml` replicas = 3 (WS alpha + WS beta + MCP gamma each
  claim a distinct sandbox).

**(d) MCP client (`mcp-client.js` in `test/playwright-scripts.yaml`,
`test/playwright-mcp-client-job.yaml`)**
- Uses `@modelcontextprotocol/sdk` streamable-http client against
  `http://playwright-proxy:9000/mcp` and drives a real action mirroring
  `client.js`: connect → `tools/list` → `browser_navigate` → assert the whoami
  `Hostname:` appears in the snapshot. Emits `BENCH {json}` for harness grep
  parity and reuses the transient-error retry from `client.js`.
- `tools/list` is fetched with a **passthrough result schema**, not the strict
  `client.listTools()`: `@playwright/mcp@0.0.29` emits `inputSchema` without the
  mandatory `type: "object"`, which the SDK's strict Zod validation rejects with a
  `ZodError`. `callTool` stays on the strict high-level API, so the actual tool
  call + its result are still validated end-to-end through the proxy.

**(e) `harness.sh`**
- `deploy_proxy` takes an optional MCP port and uncomments `SANDBOX_MCP_PORT` in
  the rendered `deploy/proxy.yaml`.
- `cmd_e2e` clears stale managed claims, runs the WS legs (alpha, beta) then the
  MCP leg (gamma) — each with a distinct `playwright-id` so it gets its own claim —
  and asserts all three land on distinct `sandboxclaim` `status.sandbox.name`. Both
  protocols run **through the proxy**. The MCP leg is default-on (no gate): it was
  brought up green before landing.

## Out of scope

- substrate, kars, and isola backends (dual-protocol comes to them later).
- `test/test-existing-proxy.sh`'s `--mcp-only` placeholder.

## Notes / resolved risks

- **Version compatibility (was the main risk):** `@playwright/mcp` needs a newer
  Playwright than the previous `playwright@1.49.x`. Resolved by pinning the shared
  slim image to `playwright@1.53.0` to match `@playwright/mcp@0.0.29`; both share
  the single installed Chromium build. The shared image is also used by the
  substrate/kars/isola examples — the WS path is unaffected by the bump.
- **Newer `@playwright/mcp`:** 0.0.30/0.0.32 still emit the `type`-less
  `inputSchema`; 0.0.40+ need an alpha Playwright, and 0.0.60+ add a host allow-list
  that breaks proxying. 0.0.29 + the client-side passthrough schema is the least
  invasive combination that keeps the WS path on stable `playwright@1.53.0`.
