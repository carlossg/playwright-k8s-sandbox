# playwright-proxy

A per-namespace Kubernetes proxy that fronts Playwright (MCP over HTTP and the
native Playwright WebSocket server). It routes connections from agent pods to a
dedicated Playwright sandbox per agent, provisioned through one of three
backends, and reaps the sandbox after a configurable idle period.

## Identity model

Each agent pod that wants a sandbox sets a **label** on its pod spec:

```yaml
metadata:
  labels:
    playwright-id: my-app-prod    # any stable id; one sandbox per id
```

The proxy runs a shared informer on `pods -l playwright-id` in its namespace and
maintains an in-memory `podIP -> playwright-id` index. On every request:

1. Source IP is extracted from the TCP connection (`r.RemoteAddr`). In-cluster
   pod→ClusterIP traffic preserves the client pod IP on every modern CNI.
2. Index lookup yields the `playwright-id`. Unlabelled pods are rejected with
   `403`.
3. The session manager returns the existing sandbox endpoint, or kicks off a
   `Backend.Ensure` (singleflight per id) to create one.
4. Traffic is reverse-proxied to the sandbox. WebSocket upgrades are detected
   and bytes pumped both directions via hijacked TCP.

When the agent pod is rescheduled the new pod has the same label, so the same
`playwright-id` reuses the same sandbox.

## Backends

| `BACKEND`        | What it provisions                                        | Notes                                                                 |
|------------------|-----------------------------------------------------------|-----------------------------------------------------------------------|
| `sandboxclaim`   | One `SandboxClaim` (CRD `agents.x-k8s.io/v1beta1`) per id, claiming from `WARMPOOL_NAME` | Used for both **agent-sandbox** and **OpenShell** — point the warmpool at the OpenShell template for the latter. |
| `substrate`      | One `Actor` (CRD `ate.dev/v1alpha1`) per id                | Routes through the substrate router; `X-Substrate-Actor` header selects the actor. |
| `karssandbox`    | One `KarsSandbox` (CRD `kars.azure.com/v1alpha1`) per id  | Azure KARS controller with namespace isolation. Uses Service DNS for cross-namespace access. |

A warm pool is required for the `sandboxclaim` backend.

## Configuration

All via env vars on the Deployment:

| Variable                  | Default            | Required when                  | Meaning |
|---------------------------|--------------------|--------------------------------|---------|
| `POD_NAMESPACE`           | —                  | always (downward API)          | Namespace the proxy serves |
| `LISTEN_ADDR`             | `:9000`            |                                | Dataplane bind addr |
| `METRICS_ADDR`            | `:9090`            |                                | `/healthz` and `/readyz` |
| `PLAYWRIGHT_LABEL_KEY`    | `playwright-id`    |                                | Pod label key |
| `BACKEND`                 | `sandboxclaim`     |                                | `sandboxclaim`, `substrate`, or `karssandbox` |
| `WARMPOOL_NAME`           | —                  | `sandboxclaim`                 | `SandboxWarmPool` name |
| `SANDBOX_TEMPLATE_NAME`   | `$WARMPOOL_NAME`   |                                | `SandboxTemplate` name referenced by the `SandboxClaim` |
| `SANDBOX_PORT`            | `9222`             |                                | Port on the sandbox pod (sandboxclaim) or actor container (substrate) |
| `SUBSTRATE_API_ENDPOINT`  | `api.ate-system.svc.cluster.local:443` | `substrate`        | gRPC endpoint of `ate-api-server` |
| `SUBSTRATE_ROUTER_ADDR`   | `atenet-router.ate-system.svc.cluster.local:80` | `substrate` | `host:port` of `atenet-router` |
| `SUBSTRATE_ACTOR_TEMPLATE`| —                  | `substrate`                    | `namespace/name` of an `ActorTemplate` |
| `KARS_SANDBOX_IMAGE`      | —                  | `karssandbox`                  | Container image for KARS sandbox |
| `KARS_INFERENCE_REF`      | —                  |                                | Optional InferencePolicy name for KARS |
| `IDLE_TTL`                | `10m`              |                                | Reap after this idle period |
| `IDLE_CHECK_INTERVAL`     | `30s`              |                                | Reaper scan cadence |
| `ENSURE_TIMEOUT`          | `30s`              |                                | Max wait for sandbox ready |

The idle reaper uses a **soft** policy: a session is reaped only when both
`lastActive < now - IDLE_TTL` *and* `activeConnections == 0`. Long-lived but
silent WebSockets keep the sandbox alive.

## Deploy

Per-backend example manifests live under `deploy/examples/{agent-sandbox,openshell,substrate,kars}/`.
For agent-sandbox or OpenShell:

```sh
# 1. Install the agent-sandbox controller + CRDs.
kubectl apply --server-side -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.4.6/manifest.yaml
kubectl apply --server-side -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.4.6/extensions.yaml

# 2. Create the SandboxTemplate + SandboxWarmPool in your agent namespace:
sed "s/NAMESPACE/agents/g" deploy/examples/agent-sandbox/sandboxtemplate.yaml | kubectl apply -f -
sed "s/NAMESPACE/agents/g" deploy/examples/agent-sandbox/warmpool.yaml        | kubectl apply -f -

# 3. RBAC + Deployment + Service for the proxy:
sed "s/NAMESPACE/agents/g" deploy/rbac.yaml  | kubectl apply -f -
sed "s/NAMESPACE/agents/g" deploy/proxy.yaml | kubectl apply -f -

# 4. Label your agent pods with playwright-id and point them at the proxy:
#    PLAYWRIGHT_WS_ENDPOINT=ws://playwright-proxy:9000/
#    or for MCP:  PLAYWRIGHT_MCP_URL=http://playwright-proxy:9000/sse
```

For substrate, the install path differs because substrate ships its own ate.dev
control plane, gVisor runsc, and snapshot bucket. See
`deploy/examples/substrate/` and the substrate repo's `hack/install-ate-kind.sh`.

For KARS, you need the KARS controller installed. See `deploy/examples/kars/` for
configuration examples and `test/harness.sh up-kars` for a local test setup.

The proxy uses the `extensions.agents.x-k8s.io/v1alpha1` CRDs that the v0.4.x
agent-sandbox releases ship; the in-source v1beta1 schema is compatible but not
yet published.

## Test harness

```sh
# Cluster #1: agent-sandbox / openshell + real Playwright e2e
test/harness.sh up                  # create the kind 'playwright-proxy' cluster, install agent-sandbox v0.4.6, build+load proxy
test/harness.sh test agent-sandbox  # smoke test: 2 clients → 2 distinct sandboxes + sticky routing (traefik/whoami upstream)
test/harness.sh test openshell      # same code path, different warmpool name
test/harness.sh e2e                 # real Playwright: chromium.launchServer in-sandbox, Job-based clients drive a browser through the proxy

# Cluster #2: substrate (uses substrate's own kind 'kind' cluster)
# Prereq once:  go install github.com/google/ko@latest
# Prereq once:  cd ../substrate && hack/create-kind-cluster.sh && PATH=$PATH:$(go env GOPATH)/bin hack/install-ate-kind.sh --deploy-ate-system
test/harness.sh test substrate      # publishes ateom-gvisor via ko, applies WorkerPool + ActorTemplate + proxy, hits each actor through atenet-router

test/harness.sh down                # delete the agent-sandbox cluster (does not touch the substrate cluster)
```

| Mode                   | Cluster       | Upstream image                                                     | What it proves |
|------------------------|---------------|--------------------------------------------------------------------|----------------|
| `test agent-sandbox`   | `playwright-proxy` | `traefik/whoami` via agent-sandbox `SandboxTemplate`            | Per-id routing, stickiness, `SandboxClaim` lifecycle |
| `test openshell`       | `playwright-proxy` | `traefik/whoami` via a second `SandboxTemplate`/`SandboxWarmPool` | Backend identical to agent-sandbox; demonstrates the "swap the warmpool" pattern |
| `e2e`                  | `playwright-proxy` | `mcr.microsoft.com/playwright:v1.49.0-jammy` running Playwright WS server | Real WebSocket upgrade, real Chromium driven from a Playwright Node client through the proxy |
| `test substrate`       | `kind` (substrate) | `traefik/whoami` running inside a gVisor actor                  | gRPC `CreateActor` on `ate-api-server`, `Host: <actor>.actors.resources.substrate.ate.dev` routing through `atenet-router` |

Why `traefik/whoami` for substrate and not Playwright? Substrate runs each
actor inside a gVisor sandbox (runsc), and headless Chromium-under-gVisor
didn't come up in this environment.

`SUBSTRATE_FLAVOUR=playwright test/harness.sh test substrate` is included for
experimentation: it builds a custom image (`test/playwright-substrate.Dockerfile`)
that bakes the npm `playwright` package and `test/playwright-substrate-server.js`
into a derived layer of `mcr.microsoft.com/playwright:v1.49.0-jammy`, pushes
it to the local registry substrate's atelet reads from, and pins it by digest
in the `ActorTemplate`. Chromium is launched with
`--no-sandbox --disable-setuid-sandbox --single-process --disable-dev-shm-usage --disable-gpu`.

Empirical result in this repo (substrate `main` + runsc nightly `2026-05-19`,
arm64 Docker Desktop, 7.7 GiB VM):

- atelet OOM-killed on the first attempt when the agent-sandbox kind cluster
  was also running. Tearing the agent-sandbox cluster down freed the budget
  and atelet stayed healthy.
- Actor reached `STATUS_RESUMING` and never transitioned to `STATUS_RUNNING`.
  A direct probe inside the cluster (`curl http://<ateom-pod-ip>:9222/`)
  returned `Connection refused` — Chromium never opened its WS port.
- `kubectl-ate logs actor` only works once the actor is `RUNNING`, and the
  ateom worker container is distroless, so the actor's own stderr couldn't
  be inspected to pinpoint which Chromium / runsc interaction blocked the boot.

Net: this proxy's substrate code path works (gRPC `CreateActor`, Host
rewrite via atenet-router) — that's what the default `whoami` flavour
proves. The real Chromium + page-fetch validation lives in the `e2e` mode
against agent-sandbox, where Chromium runs in a normal container.

## Architecture

```
agent pod ───HTTP/WS───▶ playwright-proxy ──▶ playwright sandbox pod
   │                          │
   labels.playwright-id       │ informer (pods -l playwright-id)
                              │ singleflight per id
                              │ idle reaper (soft TTL)
                              ▼
                 backend.Ensure / Delete / List
                              │
                ┌─────────────┼──────────────┐
                ▼             ▼              ▼
            SandboxClaim  SandboxClaim   ate.dev/Actor
            (agent-sb)    (openshell)    (substrate)
```

## Caveats

- `hostNetwork` client pods share the node IP and cannot be identified; reject
  them at the pod-admission layer, or add SPIFFE/token validation.
- Source-IP identity assumes in-cluster pod→ClusterIP traffic. Going through an
  Ingress, LB, or `externalTrafficPolicy: Cluster` Service loses the source IP.
- Label values must satisfy Kubernetes label constraints (≤63 chars,
  `[a-zA-Z0-9._-]`). For longer/free-form ids, hash into the label and stash
  the original in an annotation.

## Build

```sh
go build ./...
docker build -t ghcr.io/carlossg/playwright-k8s-sandbox/proxy:dev .
```
