#!/usr/bin/env bash
# Test harness for playwright-proxy. Subcommands:
#   ./harness.sh up              Create kind cluster, install agent-sandbox, build+load proxy image.
#   ./harness.sh test BACKEND    Smoke test against BACKEND with a lightweight echo upstream.
#                                BACKEND is one of: agent-sandbox, openshell, substrate, kars, isola
#   ./harness.sh e2e             Real Playwright e2e: spins up the real image, drives a browser
#                                through the proxy with the Playwright Node SDK.
#   ./harness.sh down            Delete kind cluster.
#   ./harness.sh up-kars         Create kars kind cluster, build+install kars controller.
#   ./harness.sh down-kars       Delete kars kind cluster.
#   ./harness.sh up-isola        Install isola (operator + CRDs) into the existing cluster.
#   ./harness.sh down-isola      Uninstall isola from the cluster.
#
# Smoke test substitutes a lightweight `traefik/whoami` container for Playwright; the
# routing logic in the proxy is identical regardless of the upstream image. To run a
# real Playwright e2e, apply deploy/examples/<backend>/ instead of test/echo-*.yaml.
#
# The kars and isola backend tests run a full Playwright e2e (not echo/whoami) because
# their sandbox specs are built around the Playwright image. kars requires the kars
# cluster to be up (./harness.sh up-kars) and the kars repo accessible at KARS_REPO;
# isola requires ./harness.sh up-isola and a gVisor RuntimeClass on cluster nodes (see
# the up-isola KNOWN LIMITATION note below re: gVisor-in-kind).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLUSTER="${CLUSTER:-playwright-proxy}"
NAMESPACE="${NAMESPACE:-pw-test}"
AGENT_SANDBOX_VERSION="${AGENT_SANDBOX_VERSION:-v0.5.4}"
PROXY_IMAGE="${PROXY_IMAGE:-playwright-proxy:dev}"

# ── kars-specific variables ────────────────────────────────────────────────────
# KARS_REPO: path to the kars source tree. Defaults to the `kars` symlink at the
# repo root (ln -s /path/to/azure/kars kars). Override if your layout differs.
KARS_REPO="${KARS_REPO:-$ROOT/kars}"
# Reuse the same kind cluster as agent-sandbox: kars installs into kars-system
# alongside agent-sandbox, and the kars test uses a separate namespace (pw-kars).
# This avoids spinning up a third kind node container when Docker resources are
# already shared with the substrate cluster.
KARS_CLUSTER="${KARS_CLUSTER:-$CLUSTER}"
KARS_NS="${KARS_NS:-pw-kars}"
# Use a distinct tag so this harness does not collide with kars' own e2e tags.
KARS_CONTROLLER_IMAGE="kars-controller:e2e-pw"
KARS_ROUTER_IMAGE="kars-inference-router:e2e-pw"

# ── isola-specific variables ───────────────────────────────────────────────────
# isola ships a published OCI Helm chart, so (unlike kars) there is no local
# build step — just `helm install` from ghcr.io.
# Reuse the same kind cluster as agent-sandbox/kars, same rationale as KARS_CLUSTER.
ISOLA_CLUSTER="${ISOLA_CLUSTER:-$CLUSTER}"
ISOLA_CHART="${ISOLA_CHART:-oci://ghcr.io/isola-run/charts/isola}"
# Namespace isola's control plane (operator + api-gateway) installs into.
ISOLA_SYSTEM_NS="${ISOLA_SYSTEM_NS:-isola-system}"
# Single shared namespace where every Sandbox CR (and its pod) lives, regardless
# of playwright-id — must match Config.IsolaNamespace / ISOLA_NAMESPACE.
ISOLA_SANDBOX_NS="${ISOLA_SANDBOX_NS:-isola-sandboxes}"
# The proxy's own namespace for this backend's test, distinct from ISOLA_SANDBOX_NS.
ISOLA_NS="${ISOLA_NS:-pw-isola}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

cmd_up() {
  log "creating kind cluster '$CLUSTER'"
  if ! kind get clusters | grep -qx "$CLUSTER"; then
    kind create cluster --config "$HERE/kind-config.yaml" --wait 120s
  else
    log "cluster '$CLUSTER' already exists; reusing"
  fi
  kubectl config use-context "kind-$CLUSTER" >/dev/null

  log "installing agent-sandbox $AGENT_SANDBOX_VERSION"
  # v0.5.2 renamed the core release asset from manifest.yaml to sandbox.yaml
  # (extensions.yaml, carrying the sandboxclaim/template/warmpool CRDs, kept its
  # name). v0.5.1 and earlier ship manifest.yaml, so an older override would 404
  # on the sandbox.yaml apply below — reject it up front with a clear message.
  # Encode vMAJOR.MINOR.PATCH as a comparable integer (dots -> printf args).
  local ver_bare="${AGENT_SANDBOX_VERSION#v}"
  local ver_num; ver_num=$(printf '%d%03d%03d' ${ver_bare//./ } 2>/dev/null) || ver_num=0
  if [ "${ver_num:-0}" -lt 5002 ]; then
    fail "AGENT_SANDBOX_VERSION must be >= v0.5.2 (got $AGENT_SANDBOX_VERSION): older releases ship manifest.yaml, not sandbox.yaml"
  fi
  local base="https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}"
  kubectl apply --server-side=true -f "$base/sandbox.yaml"
  kubectl apply --server-side=true -f "$base/extensions.yaml"
  kubectl -n agent-sandbox-system rollout status deploy --timeout=180s

  log "building proxy image $PROXY_IMAGE"
  (cd "$ROOT" && docker build -t "$PROXY_IMAGE" .)

  log "loading image into kind"
  kind load docker-image "$PROXY_IMAGE" --name "$CLUSTER"

  log "creating namespace $NAMESPACE"
  kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE"

  log "applying proxy RBAC"
  sed "s/NAMESPACE/$NAMESPACE/g" "$ROOT/deploy/rbac.yaml" | kubectl apply -f -
}

# Render the proxy Deployment with overrides for the kind environment.
# Substitute "namespace: NAMESPACE" (not just NAMESPACE — the manifest also
# contains POD_NAMESPACE, which has NAMESPACE as a substring).
deploy_proxy() {
  local warmpool="$1"
  local sandbox_port="${2:-8080}"
  local mcp_port="${3:-}"   # when set, dual-protocol: proxy dials this for plain HTTP/MCP
  local rendered
  rendered=$(sed \
      -e "s|namespace: NAMESPACE|namespace: $NAMESPACE|g" \
      -e "s|image: ghcr.io/carlossg/playwright-k8s-sandbox:latest|image: $PROXY_IMAGE|g" \
      -e "s|value: \"playwright\"        # agent-sandbox SandboxWarmPool name|value: \"$warmpool\"|g" \
      -e "s|value: \"9222\"|value: \"$sandbox_port\"|" \
      -e "s|imagePullPolicy: IfNotPresent|imagePullPolicy: Never|" \
      "$ROOT/deploy/proxy.yaml")
  # Uncomment + set SANDBOX_MCP_PORT so the proxy routes plain HTTP (MCP) to the
  # sandbox's second port while WS upgrades still go to SANDBOX_PORT.
  if [ -n "$mcp_port" ]; then
    rendered=$(printf '%s\n' "$rendered" \
      | sed -e "s|# - name: SANDBOX_MCP_PORT|- name: SANDBOX_MCP_PORT|" \
            -e "s|#   value: \"9223\"|  value: \"$mcp_port\"|")
    # Fail loudly if the substitution didn't land (e.g. deploy/proxy.yaml drifted
    # away from the commented-out placeholder): a silently un-rendered manifest
    # would leave the proxy single-port and the MCP leg would fail confusingly.
    printf '%s\n' "$rendered" | grep -qE '^\s*- name: SANDBOX_MCP_PORT\s*$' \
      || fail "SANDBOX_MCP_PORT env name not active in rendered proxy manifest"
    printf '%s\n' "$rendered" | grep -qE "^\s*value: \"$mcp_port\"\s*$" \
      || fail "SANDBOX_MCP_PORT value \"$mcp_port\" missing from rendered proxy manifest"
  fi
  printf '%s\n' "$rendered" | kubectl apply -f -
  kubectl -n "$NAMESPACE" rollout restart deploy/playwright-proxy >/dev/null 2>&1 || true
  kubectl -n "$NAMESPACE" rollout status  deploy/playwright-proxy --timeout=120s

  # `rollout status` returns as soon as the new pod is Ready, but the old
  # (terminating) pod may still be draining and its Service EndpointSlice entry
  # not yet reaped. A client that connects in that window has its SYN routed to
  # the dead pod and dropped (ETIMEDOUT). Actively wait until exactly one proxy
  # pod remains and the EndpointSlice addresses match its IP before returning,
  # so callers never launch client Jobs against a half-settled Service.
  wait_for_proxy_endpoints_settled
}

# Poll until the playwright-proxy Service's ready endpoints are exactly the set
# of Running (non-terminating) proxy pod IPs. Fails loudly on timeout.
# go-templates are used (not jsonpath) so absent fields like deletionTimestamp
# degrade gracefully, and the pipelines end in sort|tr so they never return
# non-zero under `set -euo pipefail` even when the set is momentarily empty.
wait_for_proxy_endpoints_settled() {
  local sel="app.kubernetes.io/name=playwright-proxy"
  local live_ips ep_ips
  for _ in $(seq 1 60); do
    # IPs of proxy pods that are Running and not terminating.
    live_ips=$(kubectl -n "$NAMESPACE" get pods -l "$sel" -o go-template='{{range .items}}{{if not .metadata.deletionTimestamp}}{{if eq .status.phase "Running"}}{{.status.podIP}}{{"\n"}}{{end}}{{end}}{{end}}' 2>/dev/null | sort | tr '\n' ',' || true)
    # Ready endpoint addresses from the Service's EndpointSlices.
    ep_ips=$(kubectl -n "$NAMESPACE" get endpointslices -l "kubernetes.io/service-name=playwright-proxy" -o go-template='{{range .items}}{{range .endpoints}}{{if .conditions.ready}}{{range .addresses}}{{.}}{{"\n"}}{{end}}{{end}}{{end}}{{end}}' 2>/dev/null | sort | tr '\n' ',' || true)
    if [ -n "$live_ips" ] && [ "$live_ips" = "$ep_ips" ]; then
      log "proxy endpoints settled ($ep_ips)"
      probe_proxy_dataplane_reachability
      return 0
    fi
    sleep 1
  done
  kubectl -n "$NAMESPACE" get pods -l "$sel" -o wide || true
  kubectl -n "$NAMESPACE" get endpointslices -l "kubernetes.io/service-name=playwright-proxy" -o wide || true
  fail "proxy Service endpoints never settled after rollout"
}

# probe_proxy_dataplane_reachability is a best-effort DIAGNOSTIC that tries to
# TCP-connect to the Service ClusterIP:9000 from inside the cluster. The
# EndpointSlice match above is a control-plane signal only: kube-proxy still has
# to program the node's iptables/ipvs rules before ClusterIP:9000 forwards to the
# new pod. Measurement on kind shows that reprogramming completes in ~2s (a
# single dropped SYN during a rollout), so this is a fast sanity check, not a
# hard barrier.
#
# It is deliberately NON-FATAL. A raw TCP connect from a warm pod recovers within
# ~2s of a rollout, and fresh probe pods connect in well under a second — but a
# throwaway `kubectl run --rm -i` probe is an unreliable *reporter* of that
# fact: in the harness's non-interactive, piped stdout context the attach can
# miss the child's first stdout line, so a healthy dataplane can read as a false
# negative. Aborting the whole run on that would be wrong. The real resilience
# lives in the client Jobs, which retry ETIMEDOUT/ECONNRESET/1006 for their full
# connect budget ("a real client tolerates a bouncing proxy; the test must
# too"). So we probe, log the result for diagnostics, and always return success.
#
# The probe is a raw TCP connect, not an HTTP request, on purpose: a completed
# handshake proves kube-proxy DNAT'd the SYN to a live backend, and it sidesteps
# the proxy's Identify.Lookup fallback (a rate-limited API-server List for an
# unidentified probe pod that can take many seconds to return 403), which would
# make an HTTP probe read as a timeout even on a perfectly healthy dataplane.
probe_proxy_dataplane_reachability() {
  local probe="pw-dataplane-probe"
  kubectl -n "$NAMESPACE" delete pod "$probe" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  log "probing proxy dataplane reachability (TCP connect to Service ClusterIP:9000; advisory)"
  # Cap the wait for the probe pod to start. deploy_proxy also runs for the
  # echo-pool tests, where $PLAYWRIGHT_IMAGE may not be loaded into the cluster;
  # with --image-pull-policy=Never that pod never starts, and `kubectl run -i`
  # would otherwise block for the default 60s before reaching the WARN branch.
  if kubectl -n "$NAMESPACE" run "$probe" --rm -i --restart=Never \
      --pod-running-timeout=20s \
      --image="$PLAYWRIGHT_IMAGE" --image-pull-policy=Never --command -- \
      node -e '
        const net = require("net");
        const deadline = Date.now() + 30000;
        function retry() {
          if (Date.now() < deadline) { setTimeout(tryOnce, 1000); }
          else { console.log("UNREACHABLE"); process.exit(1); }
        }
        function tryOnce() {
          let settled = false;
          const s = net.connect({ host: "playwright-proxy", port: 9000 });
          s.setTimeout(5000);
          const giveUp = () => { if (settled) return; settled = true; s.destroy(); retry(); };
          s.on("connect", () => { if (settled) return; settled = true; console.log("REACHABLE tcp"); s.destroy(); process.exit(0); });
          s.on("timeout", giveUp);
          s.on("error", giveUp);
        }
        // Delay the first attempt so `kubectl run -i` has attached our stdout
        // before a fast success prints REACHABLE (else the line is lost).
        setTimeout(tryOnce, 1500);
      ' 2>/dev/null | grep -q REACHABLE; then
    log "proxy dataplane reachable ✓"
  else
    log "WARN: dataplane probe did not confirm ClusterIP:9000 reachability (advisory only; clients retry transient connect errors) — proceeding"
  fi
  return 0
}

# Apply the echo SandboxTemplate + WarmPool under the given name. The proxy will
# claim from the warm pool, which adopts a pre-warmed pod.
apply_echo_pool() {
  local name="$1"
  sed -e "s/NAMESPACE/$NAMESPACE/g" -e "s/NAME/$name/g" \
    "$HERE/echo-sandboxtemplate.yaml" | kubectl apply -f -
  sed -e "s/NAMESPACE/$NAMESPACE/g" -e "s/NAME/$name/g" \
    "$HERE/echo-warmpool.yaml" | kubectl apply -f -

  log "waiting for warmpool '$name' replicas to become ready"
  for _ in $(seq 1 60); do
    ready=$(kubectl -n "$NAMESPACE" get sandboxwarmpool "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    [ "${ready:-0}" -ge 1 ] && return 0
    sleep 2
  done
  kubectl -n "$NAMESPACE" describe sandboxwarmpool "$name" || true
  kubectl -n "$NAMESPACE" get pods -o wide
  fail "warmpool '$name' never became ready"
}

apply_client() {
  local id="$1"
  sed -e "s/NAMESPACE/$NAMESPACE/g" -e "s/CLIENTID/$id/g" \
    "$HERE/test-client.yaml" | kubectl apply -f -
  kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/"client-$id" --timeout=60s
}

# Run an HTTP request from inside the client pod against the proxy and return
# the response body. The body from traefik/whoami includes the upstream pod's
# Hostname, which we use to assert routing.
client_curl() {
  local id="$1"; shift
  kubectl -n "$NAMESPACE" exec "client-$id" -c curl -- \
    curl -sS --max-time 20 "http://playwright-proxy:9000/" "$@"
}

assert_routes_to_distinct_sandboxes() {
  local id_a="$1" id_b="$2"
  log "client $id_a hits proxy"
  local out_a; out_a=$(client_curl "$id_a")
  printf '%s\n' "$out_a" | sed 's/^/    [a] /'
  local host_a; host_a=$(printf '%s\n' "$out_a" | awk -F': ' '/^Hostname/ {print $2; exit}')

  log "client $id_b hits proxy"
  local out_b; out_b=$(client_curl "$id_b")
  printf '%s\n' "$out_b" | sed 's/^/    [b] /'
  local host_b; host_b=$(printf '%s\n' "$out_b" | awk -F': ' '/^Hostname/ {print $2; exit}')

  [ -n "$host_a" ] && [ -n "$host_b" ] || fail "missing Hostname in responses"
  [ "$host_a" != "$host_b" ] || fail "expected distinct upstream hosts, got $host_a == $host_b"
  log "client $id_a → $host_a ; client $id_b → $host_b  (distinct ✓)"

  log "second request from $id_a is sticky (must land on $host_a)"
  local out_a2; out_a2=$(client_curl "$id_a")
  local host_a2; host_a2=$(printf '%s\n' "$out_a2" | awk -F': ' '/^Hostname/ {print $2; exit}')
  [ "$host_a2" = "$host_a" ] || fail "sticky routing broken: $id_a hit $host_a then $host_a2"
  log "stickiness ✓"
}

assert_sandboxclaim_exists() {
  local id="$1"
  kubectl -n "$NAMESPACE" get sandboxclaim "pw-$id" >/dev/null \
    || fail "expected SandboxClaim pw-$id to exist"
  log "SandboxClaim pw-$id ✓"
}

cmd_test() {
  local backend="${1:-}"
  case "$backend" in
    agent-sandbox|openshell)
      log "running smoke test against backend=sandboxclaim (flavour: $backend)"
      local pool="echo-${backend}"
      apply_echo_pool "$pool"
      deploy_proxy "$pool"
      # New deployment manifest → restart so it picks up the WARMPOOL_NAME env.
      kubectl -n "$NAMESPACE" rollout restart deploy/playwright-proxy
      kubectl -n "$NAMESPACE" rollout status  deploy/playwright-proxy --timeout=120s

      apply_client "alpha"
      apply_client "beta"
      assert_routes_to_distinct_sandboxes alpha beta
      assert_sandboxclaim_exists alpha
      assert_sandboxclaim_exists beta
      log "$backend smoke test PASSED"
      ;;
    substrate) cmd_test_substrate ;;
    kars)      cmd_test_kars ;;
    isola)     cmd_test_isola ;;
    *)
      fail "usage: $0 test {agent-sandbox|openshell|substrate|kars|isola}"
      ;;
  esac
}

PLAYWRIGHT_IMAGE="${PLAYWRIGHT_IMAGE:-localhost:5001/playwright-substrate:slim-1.53.0}"

# Apply the real Playwright SandboxTemplate + WarmPool + scripts ConfigMap.
apply_playwright_pool() {
  local name="$1"
  sed "s/NAMESPACE/$NAMESPACE/g" "$HERE/playwright-scripts.yaml" | kubectl apply -f -
  sed -e "s/NAMESPACE/$NAMESPACE/g" -e "s/NAME/$name/g" \
    "$HERE/playwright-sandboxtemplate.yaml" | kubectl apply -f -
  sed -e "s/NAMESPACE/$NAMESPACE/g" -e "s/NAME/$name/g" \
    "$HERE/playwright-warmpool.yaml" | kubectl apply -f -

  log "waiting for Playwright warmpool '$name' (image pull can take several minutes)"
  for _ in $(seq 1 180); do
    ready=$(kubectl -n "$NAMESPACE" get sandboxwarmpool "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    [ "${ready:-0}" -ge 1 ] && return 0
    # Actively surface a crashing sandbox instead of silently waiting out the
    # full timeout: a two-process server.js (WS + MCP) that fails to launch
    # shows up as CrashLoopBackOff/Error/RunContainerError. Bail immediately
    # with the container logs so the failure reason is front-and-centre.
    local bad
    bad=$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name="$name" \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[*].state.waiting.reason}{" "}{.status.containerStatuses[*].state.terminated.reason}{"\n"}{end}' 2>/dev/null \
      | grep -E 'CrashLoopBackOff|RunContainerError|Error|ImagePullBackOff|ErrImagePull|CreateContainerError' | head -1 || true)
    if [ -n "$bad" ]; then
      local bad_pod; bad_pod=$(printf '%s' "$bad" | awk '{print $1}')
      log "sandbox pod '$bad_pod' is failing: $bad"
      kubectl -n "$NAMESPACE" logs "$bad_pod" --tail=40 2>&1 | sed 's/^/    [crash] /' || true
      kubectl -n "$NAMESPACE" logs "$bad_pod" --previous --tail=40 2>&1 | sed 's/^/    [crash prev] /' || true
      fail "Playwright sandbox pod '$bad_pod' failed to launch ($bad)"
    fi
    sleep 2
  done
  kubectl -n "$NAMESPACE" get pods -o wide
  kubectl -n "$NAMESPACE" describe sandboxwarmpool "$name" || true
  fail "Playwright warmpool '$name' never became ready"
}

apply_playwright_client() {
  local id="$1"
  # Allow re-running the e2e command: drop any prior Job + pods for this id.
  kubectl -n "$NAMESPACE" delete job "playwright-e2e-$id" --ignore-not-found --wait=true >/dev/null
  sed -e "s/NAMESPACE/$NAMESPACE/g" -e "s/CLIENTID/$id/g" \
    -e "s|image: PLAYWRIGHT_IMAGE|image: $PLAYWRIGHT_IMAGE|" \
    "$HERE/playwright-client-job.yaml" | kubectl apply -f -
}

# MCP-over-HTTP counterpart of apply_playwright_client: drives the sandbox
# through the proxy's plain-HTTP path (routed to SANDBOX_MCP_PORT).
apply_playwright_mcp_client() {
  local id="$1"
  kubectl -n "$NAMESPACE" delete job "playwright-mcp-e2e-$id" --ignore-not-found --wait=true >/dev/null
  sed -e "s/NAMESPACE/$NAMESPACE/g" -e "s/CLIENTID/$id/g" \
    -e "s|image: PLAYWRIGHT_IMAGE|image: $PLAYWRIGHT_IMAGE|" \
    "$HERE/playwright-mcp-client-job.yaml" | kubectl apply -f -
}

wait_for_job_success() {
  local job="$1"
  local timeout_s="${2:-300}"
  for _ in $(seq 1 "$timeout_s"); do
    if kubectl -n "$NAMESPACE" get job "$job" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null | grep -q True; then
      return 0
    fi
    if kubectl -n "$NAMESPACE" get job "$job" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null | grep -q True; then
      kubectl -n "$NAMESPACE" logs "job/$job" --tail=80 || true
      fail "Job $job failed"
    fi
    sleep 1
  done
  kubectl -n "$NAMESPACE" describe job "$job" || true
  kubectl -n "$NAMESPACE" logs "job/$job" --tail=80 || true
  fail "Job $job did not complete within ${timeout_s}s"
}

cmd_e2e() {
  log "real Playwright e2e against backend=sandboxclaim"

  # The proxy's Ensure is Get-first and never recreates an existing claim, so a
  # claim left behind by a previous (possibly buggy) proxy build — e.g. one that
  # stamped an unqualified additionalPodMetadata label and is now stuck
  # Ready=False/InvalidMetadata — would be reused verbatim and silently block the
  # run. Delete stale managed claims up front so every e2e starts from scratch.
  log "clearing stale proxy-managed SandboxClaims"
  kubectl -n "$NAMESPACE" delete sandboxclaim \
    -l playwright-proxy/managed=true --ignore-not-found --wait=true >/dev/null 2>&1 || true

  log "deploying in-cluster fetch target (traefik/whoami)"
  sed "s/NAMESPACE/$NAMESPACE/g" "$HERE/test-target.yaml" | kubectl apply -f -
  kubectl -n "$NAMESPACE" rollout status deploy/test-target --timeout=60s

  log "building slim Playwright image $PLAYWRIGHT_IMAGE (shared by all three backends)"
  # Build from the same Dockerfile/server.js the substrate flavour uses. The
  # Dockerfile expects ./server.js relative to the build context, so copy the
  # versioned playwright-substrate-server.js in place for the build then drop it.
  cp "$HERE/playwright-substrate-server.js" "$HERE/server.js"
  docker build --platform "linux/$(go env GOARCH)" \
    -t "$PLAYWRIGHT_IMAGE" \
    -f "$HERE/playwright-substrate.Dockerfile" "$HERE" >/dev/null
  rm -f "$HERE/server.js"
  log "loading $PLAYWRIGHT_IMAGE into kind via docker save (matches the substrate flavour's load path)"
  docker save "$PLAYWRIGHT_IMAGE" | docker exec -i "$CLUSTER-control-plane" ctr --namespace=k8s.io images import --no-unpack -
  docker exec "$CLUSTER-control-plane" ctr --namespace=k8s.io images ls -q | grep -q "$PLAYWRIGHT_IMAGE" \
    || fail "Playwright image did not land in containerd"

  local pool="playwright"
  apply_playwright_pool "$pool"
  # Dual-protocol: WS on 9222, MCP-over-HTTP on 9223. The proxy routes WS
  # upgrades to 9222 and plain HTTP (MCP) to 9223.
  deploy_proxy "$pool" 9222 9223

  # ── WebSocket protocol (native Playwright) ─────────────────────────────────
  apply_playwright_client "alpha"
  apply_playwright_client "beta"

  log "waiting for WS client Jobs (Playwright handshake + page nav)"
  wait_for_job_success "playwright-e2e-alpha"
  wait_for_job_success "playwright-e2e-beta"

  log "WS client logs:"
  kubectl -n "$NAMESPACE" logs job/playwright-e2e-alpha | sed 's/^/    [ws alpha] /'
  kubectl -n "$NAMESPACE" logs job/playwright-e2e-beta  | sed 's/^/    [ws beta]  /'

  assert_sandboxclaim_exists alpha
  assert_sandboxclaim_exists beta
  # Read the adopted sandbox names from claim status to confirm distinct upstreams.
  local sb_a sb_b
  sb_a=$(kubectl -n "$NAMESPACE" get sandboxclaim pw-alpha -o jsonpath='{.status.sandbox.name}' 2>/dev/null || true)
  sb_b=$(kubectl -n "$NAMESPACE" get sandboxclaim pw-beta  -o jsonpath='{.status.sandbox.name}' 2>/dev/null || true)
  [ -n "$sb_a" ] && [ -n "$sb_b" ] || fail "claim status missing sandbox.name"
  [ "$sb_a" != "$sb_b" ]            || fail "alpha and beta share a sandbox: $sb_a"
  log "pw-alpha → $sb_a ; pw-beta → $sb_b  (distinct ✓)"
  log "WebSocket protocol PASSED"

  # ── MCP-over-HTTP protocol (@playwright/mcp) ───────────────────────────────
  # gamma exercises the proxy's plain-HTTP path (routed to the sandbox's MCP
  # port) via the MCP streamable-HTTP transport, proving two-port routing.
  apply_playwright_mcp_client "gamma"

  log "waiting for MCP client Job (MCP handshake + browser_navigate)"
  wait_for_job_success "playwright-mcp-e2e-gamma"

  log "MCP client log:"
  kubectl -n "$NAMESPACE" logs job/playwright-mcp-e2e-gamma | sed 's/^/    [mcp gamma] /'

  assert_sandboxclaim_exists gamma
  local sb_g
  sb_g=$(kubectl -n "$NAMESPACE" get sandboxclaim pw-gamma -o jsonpath='{.status.sandbox.name}' 2>/dev/null || true)
  [ -n "$sb_g" ] || fail "claim status missing sandbox.name for gamma"
  [ "$sb_g" != "$sb_a" ] && [ "$sb_g" != "$sb_b" ] || fail "gamma shares a sandbox with a WS client: $sb_g"
  log "pw-gamma → $sb_g  (MCP, distinct from WS sandboxes ✓)"
  log "MCP-over-HTTP protocol PASSED"

  log "Playwright e2e PASSED (WebSocket + MCP-over-HTTP)"
}

# ── kars backend ──────────────────────────────────────────────────────────────

kars_ctx() { echo "--context=kind-$KARS_CLUSTER"; }

require_kars_repo() {
  if [ ! -f "$KARS_REPO/deploy/helm/kars/Chart.yaml" ]; then
    cat <<EOF >&2
kars Helm chart not found at $KARS_REPO/deploy/helm/kars/Chart.yaml.
Point KARS_REPO at the kars source tree:

  export KARS_REPO=/path/to/azure/kars
  $0 up-kars

Or symlink it at the repo root:

  ln -s /path/to/azure/kars kars
EOF
    fail "kars repo not found"
  fi
}

build_kars_images() {
  # ── Fast path: pre-built images ──────────────────────────────────────────
  # If KARS_CONTROLLER_IMAGE_SRC and KARS_ROUTER_IMAGE_SRC are set, retag them
  # into the harness tags and load into kind — no compilation required. This is
  # the path for CI or any environment that already has Linux images available.
  #
  #   KARS_CONTROLLER_IMAGE_SRC=karsacr.azurecr.io/kars-controller:latest
  #   KARS_ROUTER_IMAGE_SRC=karsacr.azurecr.io/kars-inference-router:latest
  if [ -n "${KARS_CONTROLLER_IMAGE_SRC:-}" ] && [ -n "${KARS_ROUTER_IMAGE_SRC:-}" ]; then
    log "retagging pre-built kars images"
    docker tag "$KARS_CONTROLLER_IMAGE_SRC" "$KARS_CONTROLLER_IMAGE"
    docker tag "$KARS_ROUTER_IMAGE_SRC"     "$KARS_ROUTER_IMAGE"
    kind load docker-image "$KARS_CONTROLLER_IMAGE" --name "$KARS_CLUSTER"
    kind load docker-image "$KARS_ROUTER_IMAGE"     --name "$KARS_CLUSTER"
    return 0
  fi

  # ── Build path: compile + package ────────────────────────────────────────
  # Requires Linux cross-compilation from macOS (aarch64-unknown-linux-gnu or
  # aarch64-unknown-linux-musl target) or running on a Linux host. On macOS,
  # `cargo build` produces Mach-O (Darwin) binaries; kind nodes run Linux ELF.
  # If only the Darwin toolchain is available, use the pre-built image path above
  # or run this script on a Linux host / CI runner.
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64)        arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) fail "unsupported arch: $arch" ;;
  esac

  if [ -x "$KARS_REPO/bin/$arch/kars-controller" ] && \
     [ -x "$KARS_REPO/bin/$arch/kars-inference-router" ]; then
    local fmt
    fmt=$(file "$KARS_REPO/bin/$arch/kars-controller" 2>/dev/null || echo "unknown")
    if echo "$fmt" | grep -q "Mach-O"; then
      fail "kars binaries in bin/$arch/ are macOS Mach-O — cannot run in Linux containers.
Set KARS_CONTROLLER_IMAGE_SRC + KARS_ROUTER_IMAGE_SRC to use pre-built Linux images,
or build on a Linux host with: cd $KARS_REPO && cargo build --release"
    fi
    log "reusing existing kars binaries in bin/$arch/"
  else
    log "building kars Rust binaries (cargo build --release)"
    (cd "$KARS_REPO" && cargo build --release --workspace \
      --package kars-controller \
      --package kars-inference-router)
    mkdir -p "$KARS_REPO/bin/$arch"
    cp "$KARS_REPO/target/release/kars-controller"       "$KARS_REPO/bin/$arch/"
    cp "$KARS_REPO/target/release/kars-inference-router" "$KARS_REPO/bin/$arch/"
  fi

  # The kars Dockerfiles default to mcr.microsoft.com/azurelinux/distroless/base:3.0.
  # Allow the caller to override the base image; fall back to ubuntu:20.04 which
  # is available in the local cache when external registries are unreachable.
  local base_override="${KARS_BASE_IMAGE:-ubuntu:20.04}"

  log "building controller image $KARS_CONTROLLER_IMAGE (base: $base_override)"
  docker build -t "$KARS_CONTROLLER_IMAGE" \
    --platform "linux/$(go env GOARCH)" \
    --build-arg "AZURELINUX_DISTROLESS=$base_override" \
    --build-arg "BIN_PATH_PREFIX=bin" \
    -f "$KARS_REPO/controller/Dockerfile" "$KARS_REPO"
  kind load docker-image "$KARS_CONTROLLER_IMAGE" --name "$KARS_CLUSTER"

  log "building inference-router image $KARS_ROUTER_IMAGE (base: $base_override)"
  docker build -t "$KARS_ROUTER_IMAGE" \
    --platform "linux/$(go env GOARCH)" \
    --build-arg "AZURELINUX_DISTROLESS=$base_override" \
    --build-arg "BIN_PATH_PREFIX=bin" \
    -f "$KARS_REPO/inference-router/Dockerfile" "$KARS_REPO"
  kind load docker-image "$KARS_ROUTER_IMAGE" --name "$KARS_CLUSTER"
}

install_kars_helm() {
  log "installing kars Helm chart into kars-system"
  # If kars-system exists but isn't owned by this Helm release (e.g. from a
  # failed prior install), adopt it so the chart's namespace.yaml template
  # doesn't conflict.
  if kubectl $(kars_ctx) get ns kars-system >/dev/null 2>&1; then
    kubectl $(kars_ctx) annotate ns kars-system \
      meta.helm.sh/release-name=kars \
      meta.helm.sh/release-namespace=kars-system \
      --overwrite >/dev/null
    kubectl $(kars_ctx) label ns kars-system \
      app.kubernetes.io/managed-by=Helm \
      --overwrite >/dev/null
  fi
  helm --kube-context "kind-$KARS_CLUSTER" upgrade --install kars "$KARS_REPO/deploy/helm/kars" \
    --namespace kars-system \
    --create-namespace \
    --set controller.image.repository=kars-controller \
    --set controller.image.tag=e2e-pw \
    --set controller.image.pullPolicy=Never \
    --set inferenceRouter.image.repository=kars-inference-router \
    --set inferenceRouter.image.tag=e2e-pw \
    --set inferenceRouter.image.pullPolicy=Never \
    --set-string "inferenceRouter.azure.openai.endpoint=https://e2e-fake.invalid/" \
    --set-string "foundry.endpoint=https://e2e-fake.invalid/" \
    --set-string "foundry.projectEndpoint=https://e2e-fake.invalid/" \
    --set "controller.replicas=1" \
    --set "controller.extraEnv[0].name=LEADER_ELECTION_ENABLED" \
    --set-string "controller.extraEnv[0].value=false" \
    --wait --timeout 5m
}

cmd_up_kars() {
  require_kars_repo

  # Require the cluster to exist. The kars backend test runs inside the same
  # kind cluster as agent-sandbox (default: $CLUSTER = playwright-proxy) to
  # avoid spinning up a third node container when Docker resources are shared
  # with the substrate cluster. Run `./harness.sh up` first.
  if ! kind get clusters 2>/dev/null | grep -qx "$KARS_CLUSTER"; then
    fail "cluster '$KARS_CLUSTER' not found — run './harness.sh up' first"
  fi
  log "installing kars into existing cluster '$KARS_CLUSTER'"

  # Label the control-plane node so the kars controller's nodeSelector
  # (kars.azure.com/pool=sandbox) can match it.
  log "labelling control-plane node kars.azure.com/pool=sandbox"
  kubectl $(kars_ctx) label node "${KARS_CLUSTER}-control-plane" \
    kars.azure.com/pool=sandbox --overwrite

  build_kars_images
  install_kars_helm

  log "building proxy image $PROXY_IMAGE"
  (cd "$ROOT" && docker build -q -t "$PROXY_IMAGE" .)
  kind load docker-image "$PROXY_IMAGE" --name "$KARS_CLUSTER"

  log "building Playwright image $PLAYWRIGHT_IMAGE"
  cp "$HERE/playwright-substrate-server.js" "$HERE/server.js"
  docker build --platform "linux/$(go env GOARCH)" \
    -t "$PLAYWRIGHT_IMAGE" \
    -f "$HERE/playwright-substrate.Dockerfile" "$HERE" >/dev/null
  rm -f "$HERE/server.js"
  log "loading $PLAYWRIGHT_IMAGE into kars cluster"
  docker save "$PLAYWRIGHT_IMAGE" \
    | docker exec -i "$KARS_CLUSTER-control-plane" \
        ctr --namespace=k8s.io images import --no-unpack - >/dev/null

  log "creating namespace $KARS_NS"
  kubectl $(kars_ctx) get ns "$KARS_NS" >/dev/null 2>&1 \
    || kubectl $(kars_ctx) create ns "$KARS_NS"

  log "applying proxy RBAC"
  sed "s/NAMESPACE/$KARS_NS/g" "$ROOT/deploy/rbac.yaml" \
    | kubectl $(kars_ctx) apply -f -
  sed "s/NAMESPACE/$KARS_NS/g" "$ROOT/deploy/examples/kars/rbac-patch.yaml" \
    | kubectl $(kars_ctx) apply -f -

  log "applying InferencePolicy"
  sed "s/NAMESPACE/$KARS_NS/g" "$ROOT/deploy/examples/kars/inferencepolicy.yaml" \
    | kubectl $(kars_ctx) apply -f -

  log "applying playwright scripts ConfigMap"
  sed "s/NAMESPACE/$KARS_NS/g" "$HERE/playwright-scripts.yaml" \
    | kubectl $(kars_ctx) apply -f -

  log "deploying in-cluster fetch target (traefik/whoami)"
  sed "s/NAMESPACE/$KARS_NS/g" "$HERE/test-target.yaml" \
    | kubectl $(kars_ctx) apply -f -
  kubectl $(kars_ctx) -n "$KARS_NS" rollout status deploy/test-target --timeout=60s
}

cmd_test_kars() {
  local ctx ns
  ctx=$(kars_ctx)
  ns="$KARS_NS"

  log "kars backend e2e: deploying proxy"
  sed -e "s|namespace: NAMESPACE|namespace: $ns|g" \
      -e "s|PROXY_IMAGE|$PROXY_IMAGE|g" \
      -e "s|PLAYWRIGHT_IMAGE|$PLAYWRIGHT_IMAGE|g" \
      "$HERE/proxy-kars.yaml" | kubectl $ctx apply -f -
  kubectl $ctx -n "$ns" rollout restart deploy/playwright-proxy >/dev/null 2>&1 || true
  kubectl $ctx -n "$ns" rollout status  deploy/playwright-proxy --timeout=120s

  # The kars proxy ENSURE_TIMEOUT is 180s (no warmpool; full Chromium cold
  # start). Use a generous job deadline so the first sandbox creation doesn't
  # race the job timeout.
  local deadline=300

  for id in alpha beta; do
    kubectl $ctx -n "$ns" delete job "playwright-e2e-$id" --ignore-not-found --wait=true >/dev/null
    sed -e "s/NAMESPACE/$ns/g" -e "s/CLIENTID/$id/g" \
      -e "s|image: PLAYWRIGHT_IMAGE|image: $PLAYWRIGHT_IMAGE|" \
      "$HERE/playwright-client-job.yaml" | kubectl $ctx apply -f -
  done

  log "waiting for playwright client Jobs (alpha + beta)"
  for id in alpha beta; do
    local end=$(($(date +%s) + deadline))
    while [ "$(date +%s)" -lt "$end" ]; do
      if kubectl $ctx -n "$ns" get job "playwright-e2e-$id" \
           -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null \
           | grep -q True; then
        break
      fi
      if kubectl $ctx -n "$ns" get job "playwright-e2e-$id" \
           -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null \
           | grep -q True; then
        log "kars: job playwright-e2e-$id failed — proxy + controller logs:"
        kubectl $ctx -n "$ns" logs deploy/playwright-proxy --tail=40 || true
        kubectl $ctx -n kars-system logs \
          -l app.kubernetes.io/component=controller --tail=40 || true
        fail "playwright-e2e-$id failed"
      fi
      sleep 2
    done
    [ "$(date +%s)" -lt "$end" ] || fail "playwright-e2e-$id timed out after ${deadline}s"
  done

  log "client logs:"
  kubectl $ctx -n "$ns" logs job/playwright-e2e-alpha | sed 's/^/    [alpha] /'
  kubectl $ctx -n "$ns" logs job/playwright-e2e-beta  | sed 's/^/    [beta]  /'

  # Assert that KarsSandbox CRs exist.
  for id in alpha beta; do
    kubectl $ctx -n "$ns" get karssandbox "pw-$id" >/dev/null \
      || fail "expected KarsSandbox pw-$id to exist in $ns"
    log "KarsSandbox pw-$id ✓"
  done

  # Assert distinct sandbox namespaces.
  local ns_a ns_b
  ns_a=$(kubectl $ctx -n "$ns" get karssandbox pw-alpha \
    -o jsonpath='{.status.namespace}' 2>/dev/null || true)
  ns_b=$(kubectl $ctx -n "$ns" get karssandbox pw-beta \
    -o jsonpath='{.status.namespace}' 2>/dev/null || true)
  [ -n "$ns_a" ] && [ -n "$ns_b" ] || fail "KarsSandbox status.namespace not populated"
  [ "$ns_a" != "$ns_b" ]           || fail "alpha and beta share namespace: $ns_a"
  log "pw-alpha → $ns_a ; pw-beta → $ns_b  (distinct ✓)"

  log "kars e2e PASSED"
}

cmd_down_kars() {
  # kars installs into the shared cluster ($KARS_CLUSTER = $CLUSTER by default);
  # we only uninstall kars, not delete the cluster.
  log "uninstalling kars from cluster '$KARS_CLUSTER'"
  helm --kube-context "kind-$KARS_CLUSTER" uninstall kars --namespace kars-system 2>/dev/null || true
  kubectl $(kars_ctx) delete ns "$KARS_NS" --ignore-not-found >/dev/null || true
}

# ── isola backend ──────────────────────────────────────────────────────────────

isola_ctx() { echo "--context=kind-$ISOLA_CLUSTER"; }

cmd_up_isola() {
  # Require the cluster to exist. isola reuses the same kind cluster as
  # agent-sandbox/kars, same rationale as cmd_up_kars.
  if ! kind get clusters 2>/dev/null | grep -qx "$ISOLA_CLUSTER"; then
    fail "cluster '$ISOLA_CLUSTER' not found — run './harness.sh up' first"
  fi
  log "installing isola into existing cluster '$ISOLA_CLUSTER'"

  # KNOWN LIMITATION: isola requires a gVisor (runsc) RuntimeClass on cluster
  # nodes for real sandbox isolation. Stock kind nodes don't ship containerd
  # configured for runsc (see isola's hack/setup.sh for the full node config),
  # which is out of scope for this harness. We still install the RuntimeClass
  # object so Sandbox CRs don't fail admission, but without a working runsc
  # shim, sandbox pods will fail to start — the same failure mode kars hits
  # without its controller installed. Treat `up-isola` as sufficient for
  # exercising the proxy's Ensure/Delete/List wiring against the Sandbox CR
  # API, not as a full isolation smoke test, until a gVisor-capable node is
  # available (e.g. a real cluster with gVisor installed per isola's README).
  log "installing gVisor RuntimeClass (isolation itself requires runsc on nodes; see comment above)"
  cat <<'EOF' | kubectl $(isola_ctx) apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
EOF

  log "installing isola Helm chart into $ISOLA_SYSTEM_NS (sandbox namespace: $ISOLA_SANDBOX_NS)"
  helm --kube-context "kind-$ISOLA_CLUSTER" upgrade --install isola "$ISOLA_CHART" \
    --namespace "$ISOLA_SYSTEM_NS" \
    --create-namespace \
    --set sandboxNamespace.name="$ISOLA_SANDBOX_NS" \
    --set sandboxNamespace.create=true \
    --wait --timeout 5m

  log "building proxy image $PROXY_IMAGE"
  (cd "$ROOT" && docker build -q -t "$PROXY_IMAGE" .)
  kind load docker-image "$PROXY_IMAGE" --name "$ISOLA_CLUSTER"

  log "building Playwright image $PLAYWRIGHT_IMAGE"
  cp "$HERE/playwright-substrate-server.js" "$HERE/server.js"
  docker build --platform "linux/$(go env GOARCH)" \
    -t "$PLAYWRIGHT_IMAGE" \
    -f "$HERE/playwright-substrate.Dockerfile" "$HERE" >/dev/null
  rm -f "$HERE/server.js"
  log "loading $PLAYWRIGHT_IMAGE into isola cluster"
  docker save "$PLAYWRIGHT_IMAGE" \
    | docker exec -i "$ISOLA_CLUSTER-control-plane" \
        ctr --namespace=k8s.io images import --no-unpack - >/dev/null

  log "creating namespace $ISOLA_NS"
  kubectl $(isola_ctx) get ns "$ISOLA_NS" >/dev/null 2>&1 \
    || kubectl $(isola_ctx) create ns "$ISOLA_NS"

  log "applying proxy RBAC"
  sed "s/NAMESPACE/$ISOLA_NS/g" "$ROOT/deploy/rbac.yaml" \
    | kubectl $(isola_ctx) apply -f -
  sed "s/NAMESPACE/$ISOLA_NS/g" "$ROOT/deploy/examples/isola/rbac-patch.yaml" \
    | kubectl $(isola_ctx) apply -f -

  # Mandatory: without this, the proxy can never reach a sandbox's Playwright
  # port — see deploy/examples/isola/networkpolicy-allow-proxy.yaml for why.
  log "applying mandatory proxy-ingress NetworkPolicy in $ISOLA_SANDBOX_NS"
  sed -e "s/ISOLA_NAMESPACE/$ISOLA_SANDBOX_NS/g" \
      -e "s/PROXY_NAMESPACE/$ISOLA_NS/g" \
      -e "s/SANDBOX_PORT/9222/g" \
      "$ROOT/deploy/examples/isola/networkpolicy-allow-proxy.yaml" \
    | kubectl $(isola_ctx) apply -f -

  log "applying playwright scripts ConfigMap"
  sed "s/NAMESPACE/$ISOLA_NS/g" "$HERE/playwright-scripts.yaml" \
    | kubectl $(isola_ctx) apply -f -

  log "deploying in-cluster fetch target (traefik/whoami)"
  sed "s/NAMESPACE/$ISOLA_NS/g" "$HERE/test-target.yaml" \
    | kubectl $(isola_ctx) apply -f -
  kubectl $(isola_ctx) -n "$ISOLA_NS" rollout status deploy/test-target --timeout=60s
}

cmd_test_isola() {
  local ctx ns
  ctx=$(isola_ctx)
  ns="$ISOLA_NS"

  log "isola backend e2e: deploying proxy"
  sed -e "s|namespace: NAMESPACE|namespace: $ns|g" \
      -e "s|PROXY_IMAGE|$PROXY_IMAGE|g" \
      -e "s|PLAYWRIGHT_IMAGE|$PLAYWRIGHT_IMAGE|g" \
      "$HERE/proxy-isola.yaml" | kubectl $ctx apply -f -
  kubectl $ctx -n "$ns" rollout restart deploy/playwright-proxy >/dev/null 2>&1 || true
  kubectl $ctx -n "$ns" rollout status  deploy/playwright-proxy --timeout=120s

  # The isola proxy ENSURE_TIMEOUT is 180s (no warmpool; full Chromium cold
  # start), same rationale as kars.
  local deadline=300

  for id in alpha beta; do
    kubectl $ctx -n "$ns" delete job "playwright-e2e-$id" --ignore-not-found --wait=true >/dev/null
    sed -e "s/NAMESPACE/$ns/g" -e "s/CLIENTID/$id/g" \
      -e "s|image: PLAYWRIGHT_IMAGE|image: $PLAYWRIGHT_IMAGE|" \
      "$HERE/playwright-client-job.yaml" | kubectl $ctx apply -f -
  done

  log "waiting for playwright client Jobs (alpha + beta)"
  for id in alpha beta; do
    local end=$(($(date +%s) + deadline))
    while [ "$(date +%s)" -lt "$end" ]; do
      if kubectl $ctx -n "$ns" get job "playwright-e2e-$id" \
           -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null \
           | grep -q True; then
        break
      fi
      if kubectl $ctx -n "$ns" get job "playwright-e2e-$id" \
           -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null \
           | grep -q True; then
        log "isola: job playwright-e2e-$id failed — proxy + operator logs:"
        kubectl $ctx -n "$ns" logs deploy/playwright-proxy --tail=40 || true
        kubectl $ctx -n "$ISOLA_SYSTEM_NS" logs \
          -l app.kubernetes.io/component=operator --tail=40 || true
        fail "playwright-e2e-$id failed"
      fi
      sleep 2
    done
    [ "$(date +%s)" -lt "$end" ] || fail "playwright-e2e-$id timed out after ${deadline}s"
  done

  log "client logs:"
  kubectl $ctx -n "$ns" logs job/playwright-e2e-alpha | sed 's/^/    [alpha] /'
  kubectl $ctx -n "$ns" logs job/playwright-e2e-beta  | sed 's/^/    [beta]  /'

  # Assert that Sandbox CRs exist, in the shared sandbox namespace.
  for id in alpha beta; do
    kubectl $ctx -n "$ISOLA_SANDBOX_NS" get sandbox "pw-$id" >/dev/null \
      || fail "expected Sandbox pw-$id to exist in $ISOLA_SANDBOX_NS"
    log "Sandbox pw-$id ✓"
  done

  # Assert distinct pod IPs (all Sandbox CRs share one namespace, unlike kars,
  # so isolation is verified by IP rather than by namespace).
  local ip_a ip_b
  ip_a=$(kubectl $ctx -n "$ISOLA_SANDBOX_NS" get sandbox pw-alpha \
    -o jsonpath='{.status.podIP}' 2>/dev/null || true)
  ip_b=$(kubectl $ctx -n "$ISOLA_SANDBOX_NS" get sandbox pw-beta \
    -o jsonpath='{.status.podIP}' 2>/dev/null || true)
  [ -n "$ip_a" ] && [ -n "$ip_b" ] || fail "Sandbox status.podIP not populated"
  [ "$ip_a" != "$ip_b" ]           || fail "alpha and beta share podIP: $ip_a"
  log "pw-alpha → $ip_a ; pw-beta → $ip_b  (distinct ✓)"

  log "isola e2e PASSED"
}

cmd_down_isola() {
  # isola installs into the shared cluster ($ISOLA_CLUSTER = $CLUSTER by default);
  # we only uninstall isola, not delete the cluster.
  log "uninstalling isola from cluster '$ISOLA_CLUSTER'"
  helm --kube-context "kind-$ISOLA_CLUSTER" uninstall isola --namespace "$ISOLA_SYSTEM_NS" 2>/dev/null || true
  kubectl $(isola_ctx) delete ns "$ISOLA_NS" --ignore-not-found >/dev/null || true
  kubectl $(isola_ctx) delete ns "$ISOLA_SANDBOX_NS" --ignore-not-found >/dev/null || true
}

# ── substrate backend ──────────────────────────────────────────────────────────

SUBSTRATE_REPO="${SUBSTRATE_REPO:-$ROOT/../substrate}"
SUBSTRATE_CLUSTER="${SUBSTRATE_CLUSTER:-kind}"          # substrate's default
SUBSTRATE_NS="${SUBSTRATE_NS:-pw-substrate}"
SUBSTRATE_TEMPLATE_NAME="${SUBSTRATE_TEMPLATE_NAME:-playwright}"

substrate_ctx_args() { echo "--context=kind-$SUBSTRATE_CLUSTER"; }

# Asserts substrate's ate-system is installed in the substrate kind cluster.
require_substrate() {
  if ! kubectl $(substrate_ctx_args) get ns ate-system >/dev/null 2>&1; then
    cat <<EOF >&2
Substrate's ate-system namespace was not found in cluster '$SUBSTRATE_CLUSTER'.
Install it first using substrate's own scripts:

  cd "$SUBSTRATE_REPO"
  hack/create-kind-cluster.sh                       # creates the 'kind' cluster + local registry
  PATH="\$PATH:\$(go env GOPATH)/bin" \\
    hack/install-ate-kind.sh --deploy-ate-system    # builds and applies ate-system (needs ko)

Prerequisites: ko (\`go install github.com/google/ko@latest\`).
Then re-run: $0 test substrate
EOF
    fail "substrate not installed"
  fi
}

# Build + push the substrate worker (ateom-gvisor) into the local registry that
# substrate's kind cluster is wired to read from. Idempotent.
ensure_ateom_image() {
  local img
  img=$(cd "$SUBSTRATE_REPO" && \
    PATH="$PATH:$(go env GOPATH)/bin" \
    KO_DOCKER_REPO=localhost:5001 \
    KO_DEFAULTPLATFORMS="linux/$(go env GOARCH)" \
    ko publish ./cmd/ateom-gvisor 2>&1 | tail -1)
  case "$img" in
    localhost:5001/*) ;;
    *) fail "ko publish ateom-gvisor did not return a localhost:5001 reference (got: $img)" ;;
  esac
  echo "$img"
}

cmd_test_substrate() {
  # SUBSTRATE_FLAVOUR=playwright runs Chromium-under-gVisor (heavier, slower);
  # default flavour uses traefik/whoami to exercise the proxy's gRPC + Host
  # routing path without dragging Chromium into the test budget.
  local flavour="${SUBSTRATE_FLAVOUR:-whoami}"
  log "substrate backend smoke test (flavour=$flavour) against cluster '$SUBSTRATE_CLUSTER'"
  require_substrate

  log "building + loading proxy image into substrate cluster"
  (cd "$ROOT" && docker build -q -t "$PROXY_IMAGE" .) >/dev/null
  kind load docker-image "$PROXY_IMAGE" --name "$SUBSTRATE_CLUSTER" >/dev/null

  log "pushing ateom-gvisor worker image to local registry"
  local ateom_image
  ateom_image=$(ensure_ateom_image)
  log "ateom worker image: $ateom_image"

  log "creating namespace $SUBSTRATE_NS"
  kubectl $(substrate_ctx_args) get ns "$SUBSTRATE_NS" >/dev/null 2>&1 \
    || kubectl $(substrate_ctx_args) create ns "$SUBSTRATE_NS"

  log "applying proxy RBAC"
  sed "s/NAMESPACE/$SUBSTRATE_NS/g" "$ROOT/deploy/rbac.yaml" | kubectl $(substrate_ctx_args) apply -f -

  log "applying WorkerPool + ActorTemplate"
  sed -e "s|NAMESPACE|$SUBSTRATE_NS|g" \
      -e "s|NAME|$SUBSTRATE_TEMPLATE_NAME|g" \
      -e "s|ATEOM_IMAGE|$ateom_image|g" \
      "$HERE/substrate-workerpool.yaml" | kubectl $(substrate_ctx_args) apply -f -

  case "$flavour" in
    whoami)
      sed -e "s|NAMESPACE|$SUBSTRATE_NS|g" -e "s|NAME|$SUBSTRATE_TEMPLATE_NAME|g" \
        "$HERE/substrate-actortemplate.yaml" | kubectl $(substrate_ctx_args) apply -f -
      ;;
    playwright)
      log "building custom Playwright image (server.js baked in, --single-process)"
      cp "$HERE/playwright-substrate-server.js" "$HERE/server.js"
      docker build --platform "linux/$(go env GOARCH)" \
        -t localhost:5001/playwright-substrate:slim-1.53.0 \
        -f "$HERE/playwright-substrate.Dockerfile" "$HERE" >/dev/null
      rm -f "$HERE/server.js"
      log "pushing to local registry that substrate's atelet reads from"
      docker push localhost:5001/playwright-substrate:slim-1.53.0 >/dev/null
      local pw_digest
      pw_digest=$(docker inspect localhost:5001/playwright-substrate:slim-1.53.0 --format '{{index .RepoDigests 0}}')
      log "image: $pw_digest"
      sed -e "s|NAMESPACE|$SUBSTRATE_NS|g" \
          -e "s|NAME|$SUBSTRATE_TEMPLATE_NAME|g" \
          -e "s|PLAYWRIGHT_IMAGE|$pw_digest|" \
          "$HERE/substrate-actortemplate-playwright.yaml" | kubectl $(substrate_ctx_args) apply -f -
      ;;
    *) fail "unknown SUBSTRATE_FLAVOUR=$flavour (want whoami|playwright)" ;;
  esac

  local upstream_port=80
  [ "$flavour" = playwright ] && upstream_port=9222
  log "deploying proxy (BACKEND=substrate, SANDBOX_PORT=$upstream_port)"
  sed -e "s|namespace: NAMESPACE|namespace: $SUBSTRATE_NS|g" \
      -e "s|image: PROXY_IMAGE|image: $PROXY_IMAGE|g" \
      -e "s|value: \"ACTOR_TEMPLATE\"|value: \"$SUBSTRATE_NS/$SUBSTRATE_TEMPLATE_NAME\"|" \
      -e "s|value: \"80\"|value: \"$upstream_port\"|" \
      "$HERE/proxy-substrate.yaml" | kubectl $(substrate_ctx_args) apply -f -
  kubectl $(substrate_ctx_args) -n "$SUBSTRATE_NS" rollout restart deploy/playwright-proxy >/dev/null 2>&1 || true
  kubectl $(substrate_ctx_args) -n "$SUBSTRATE_NS" rollout status  deploy/playwright-proxy --timeout=120s

  log "creating test-client pods"
  for id in alpha beta; do
    kubectl $(substrate_ctx_args) -n "$SUBSTRATE_NS" delete pod "client-$id" --ignore-not-found >/dev/null
    sed -e "s/NAMESPACE/$SUBSTRATE_NS/g" -e "s/CLIENTID/$id/g" \
      "$HERE/test-client.yaml" | kubectl $(substrate_ctx_args) apply -f -
  done
  for id in alpha beta; do
    kubectl $(substrate_ctx_args) -n "$SUBSTRATE_NS" wait --for=condition=Ready pod/"client-$id" --timeout=60s
  done

  local id status out host
  for id in alpha beta; do
    log "client $id hits proxy (substrate ensures an actor on first request)"
    set +e
    out=$(kubectl $(substrate_ctx_args) -n "$SUBSTRATE_NS" exec "client-$id" -c curl -- \
      curl -sS --max-time 60 "http://playwright-proxy:9000/")
    status=$?
    set -e
    printf '%s\n' "$out" | sed "s/^/    [$id] /"
    if [ $status -ne 0 ] || [ -z "$out" ]; then
      log "request failed — dumping proxy + api-server logs"
      kubectl $(substrate_ctx_args) -n "$SUBSTRATE_NS" logs deploy/playwright-proxy --tail=40 || true
      kubectl $(substrate_ctx_args) -n ate-system logs deploy/ate-api-server-deployment --tail=20 || true
      fail "substrate request from client-$id failed"
    fi
    host=$(printf '%s\n' "$out" | awk -F': ' '/^Hostname/ {print $2; exit}')
    [ "$host" = "runsc" ] || log "WARN: expected response from runsc (gVisor) actor, got hostname=$host"
  done

  log "verifying actors exist via ate-api-server"
  if command -v kubectl-ate >/dev/null 2>&1; then
    for id in alpha beta; do
      kubectl-ate --context "kind-$SUBSTRATE_CLUSTER" get actor "pw-$id" 2>&1 | sed "s/^/    [actor $id] /" \
        || fail "actor pw-$id not found"
    done
  else
    log "kubectl-ate not installed; install with 'cd substrate && go install ./cmd/kubectl-ate' to verify actors"
  fi

  log "substrate smoke test PASSED"
}

cmd_down() {
  log "deleting kind cluster '$CLUSTER'"
  kind delete cluster --name "$CLUSTER" >/dev/null
}

case "${1:-}" in
  up)        shift; cmd_up        "$@" ;;
  test)      shift; cmd_test      "$@" ;;
  e2e)       shift; cmd_e2e       "$@" ;;
  down)      shift; cmd_down      "$@" ;;
  up-kars)   shift; cmd_up_kars   "$@" ;;
  down-kars) shift; cmd_down_kars "$@" ;;
  up-isola)   shift; cmd_up_isola   "$@" ;;
  down-isola) shift; cmd_down_isola "$@" ;;
  ""|-h|--help)
    sed -n '2,16p' "$0"
    ;;
  *) fail "unknown subcommand: $1" ;;
esac
