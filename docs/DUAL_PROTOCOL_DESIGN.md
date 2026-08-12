# Dual-protocol sandbox serving (MCP over HTTP + native Playwright WS) — design notes

**Status:** Research / design only. Not implemented. Not currently prioritized.

**Scope of this document:** the *sandbox pod* side of dual-protocol support for the
agent-sandbox / `sandboxclaim` backend. The *proxy* side is already done (see
[Current state](#current-state)). The immediate port-mismatch issue is handled
separately by PR #788; this document exists so the "one sandbox port serves both
protocols" enhancement can be picked up later without re-deriving the research.

- [Motivation](#motivation)
- [Current state](#current-state)
- [Research conclusion](#research-conclusion)
- [Proposed architecture](#proposed-architecture)
- [Why not a single process/listener](#why-not-a-single-processlistener)
- [Implementation sketch (deferred)](#implementation-sketch-deferred)
- [Out of scope](#out-of-scope)
- [Open questions / risks](#open-questions--risks)

## Motivation

`config.SandboxPort` (`internal/config/config.go`) is documented as "the TCP port
on the sandbox pod that serves Playwright (MCP HTTP or WS)". `backend.Endpoint`
and every backend implementation resolve a client to a single `Host:Port`,
independent of protocol. The contract is therefore: **the sandbox container is
expected to multiplex both the native Playwright WebSocket protocol and MCP over
HTTP on one port**, the same way the proxy already multiplexes them on its own
listen port.

The test sandbox image does not honor this contract yet. It only runs
`chromium.launchServer({ port, wsPath, ... })` (native WS). There is no MCP
server anywhere in the image, so the MCP-over-HTTP half of the contract is
untested and unserved.

## Current state

**Proxy side (done, not in scope for this work):**

- `internal/proxy/proxy.go` routes both protocols on its single listen port. It
  detects WS upgrades via the `Connection`/`Upgrade` headers (`isWebsocketUpgrade`)
  and otherwise reverse-proxies plain HTTP (for MCP-over-HTTP / SSE), with
  `FlushInterval: -1` for immediate streaming flush.
- Backend selection is by client pod IP → `playwright-id`
  (`internal/identify/identify.go`), independent of protocol.

**Sandbox side (the gap):**

- `test/playwright-substrate-server.js` only calls `chromium.launchServer(...)`
  (native WS). No MCP server.
- `test/README-test-existing-proxy.md` lists "MCP/SSE Path (placeholder)" and
  "--mcp-only ... not yet implemented".
- `test/harness.sh` `cmd_e2e` (agent-sandbox path) only drives WS via
  `test/playwright-client-job.yaml` + `test/playwright-scripts.yaml`'s
  `client.js` (`chromium.connect(...)`).

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

**Therefore the path forward is a small in-container front dispatcher** that
mirrors `proxy.go`'s own `isWebsocketUpgrade` dispatch one hop downstream: it
listens on `SANDBOX_PORT`, and routes WS upgrades to `chromium.launchServer` and
plain HTTP to `@playwright/mcp`, each on a private loopback port. This keeps "one
port serves both" **true from the proxy's perspective** and requires **no Go code
changes** — `config.SandboxPort` / `backend.Endpoint` already model exactly this.

### Reference

- `@playwright/mcp` HTTP transport: `npx @playwright/mcp@latest --port <port>`;
  MCP endpoint at `/mcp` (streamable-http), legacy SSE at `/sse` + `/messages`.
- Relevant CLI flags: `--port`, `--host` (use `0.0.0.0` / here `127.0.0.1`),
  `--headless`, `--browser`, `--isolated`, `--no-sandbox`, `--cdp-endpoint`.
- Source: <https://github.com/microsoft/playwright-mcp>,
  <https://www.npmjs.com/package/@playwright/mcp>.

## Proposed architecture

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
- **`chromium.launchServer`** runs in-process on a loopback port (as today, but no
  longer bound to `0.0.0.0:9222`).
- **`@playwright/mcp`** runs as a spawned child process on a loopback port. Child
  exit ⇒ `process.exit(1)` so the pod restarts (matches the current fail-fast
  behaviour of `server.js`).
- **Readiness:** the front dispatcher should only `listen()` once both children
  report ready, so the existing `tcpSocket: {port: 9222}` probe stays meaningful;
  an HTTP probe of `/mcp` is a stronger alternative.

## Why not a single process/listener

Considered and rejected:

- **Embed MCP into `launchServer`'s server** — not possible; no public hook.
- **Embed `launchServer` into an MCP/Express server** — `launchServer` insists on
  owning its own listener; you cannot hand it an existing server object.
- **One `http.Server` hosting both via `createConnection` embed + a WS handler
  proxying to `launchServer`** — still needs `launchServer` on its own port, so
  you end up with the dispatcher anyway, plus more in-process coupling and a
  larger `server.js`. The child-process + dispatcher shape is smaller and more
  robust, and it directly mirrors the proxy's proven dispatch.

## Implementation sketch (deferred)

Recorded so the future implementer starts from the plan, not from scratch. **Do
not implement without explicit prioritization.** Test-only; no Go changes.

**(a) Image / dispatcher**
- Rewrite `test/playwright-substrate-server.js` into the front dispatcher
  described above (or add `playwright-sandbox-dispatch.js`; the harness bakes
  exactly one `server.js`, so rewriting in place is simplest).
- `test/playwright-substrate.Dockerfile`: add `@playwright/mcp` (and
  `@modelcontextprotocol/sdk` for the client) to the global npm install. No extra
  browser download — MCP reuses the installed chromium via
  `PLAYWRIGHT_BROWSERS_PATH`.

**(b) MCP server config (following the `PORT` / `PW_WS_PATH` / `CHROMIUM_ARGS`
env pattern)**
- New env: `PW_WS_INTERNAL_PORT` (default 9223), `PW_MCP_INTERNAL_PORT`
  (default 9224).
- Spawn: `mcp-server --host 127.0.0.1 --port $PW_MCP_INTERNAL_PORT --headless
  --isolated --no-sandbox` (map `CHROMIUM_ARGS` sandbox flags onto `--no-sandbox`).
- `PORT` (9222), `PW_WS_PATH`, `CHROMIUM_ARGS` keep their current meaning; the
  latter two still feed `chromium.launchServer`.

**(c) Test manifests + client**
- Add `mcp-client.js` to `test/playwright-scripts.yaml`. It uses
  `@modelcontextprotocol/sdk` streamable-http client against
  `http://playwright-proxy:9000/mcp` and drives a real action mirroring
  `client.js`: `initialize` → `tools/list` → `browser_navigate` → snapshot →
  assert the whoami `Hostname:` appears. Emit `BENCH {json}` for harness grep
  parity; reuse the 403-cold-informer retry from `client.js`.
- Parameterize `test/playwright-client-job.yaml` (sed tokens for script name +
  `PW_URL`) so one manifest renders either the WS or the MCP client.

**(d) `harness.sh`**
- Extend `apply_playwright_client()` to take a script + URL.
- In `cmd_e2e`, keep the WS assertions unchanged and add an MCP leg using a
  distinct `playwright-id` (e.g. `alpha-mcp`) so it gets its own claim and the
  isolation asserts extend naturally. Both legs run **through the proxy**.
- Gate the MCP leg behind `--with-mcp` (or `E2E_MCP=1`) during bring-up so a
  broken MCP path can't regress the WS flow; flip to default-on once green.

**(e) Manual verification checklist**
1. Image builds; `node -e "require('@playwright/mcp')"` succeeds.
2. `@playwright/mcp` version is compatible with the pinned Playwright/chromium.
3. `ss -ltnp` in the pod shows `:9222` (0.0.0.0) + two loopback ports.
4. Existing WS `client.js` job still passes (no regression).
5. `mcp-client.js` job passes through the proxy; proxy logs show the HTTP path
   (not a WS upgrade) for the MCP client's pod IP.
6. WS and MCP clients get distinct `sandboxclaim` `status.sandbox.name`.
7. MCP responses stream without buffering stalls.
8. Re-running `harness.sh e2e --with-mcp` is idempotent.

## Out of scope

- substrate, kars, and isola backends (dual-protocol comes to them later).
- `test/test-existing-proxy.sh`'s `--mcp-only` placeholder (wire only if it drops
  in trivially once `mcp-client.js` exists).
- The immediate port-mismatch fix — handled by PR #788.

## Open questions / risks

- **Version compatibility (main risk):** `@playwright/mcp` may require a newer
  Playwright than the pinned `playwright@1.49.0`. Bumping the shared slim image
  affects the substrate/kars/isola examples too (same image), so verify no
  breakage there even though they're out of scope for *testing*.
- **Whether to land the MCP e2e leg behind `--with-mcp` first (recommended) or
  default-on.**
