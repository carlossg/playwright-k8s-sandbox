#!/usr/bin/env bash
# Test harness for playwright-proxy. Subcommands:
#   ./harness.sh up           Create kind cluster, install agent-sandbox, build+load proxy image.
#   ./harness.sh test BACKEND Smoke test against BACKEND with a lightweight echo upstream.
#                             BACKEND is one of: agent-sandbox, openshell, substrate
#   ./harness.sh e2e          Real Playwright e2e: spins up the real image, drives a browser
#                             through the proxy with the Playwright Node SDK.
#   ./harness.sh down         Delete kind cluster.
#
# Smoke test substitutes a lightweight `traefik/whoami` container for Playwright; the
# routing logic in the proxy is identical regardless of the upstream image. To run a
# real Playwright e2e, apply deploy/examples/<backend>/ instead of test/echo-*.yaml.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLUSTER="${CLUSTER:-playwright-proxy}"
NAMESPACE="${NAMESPACE:-pw-test}"
AGENT_SANDBOX_VERSION="${AGENT_SANDBOX_VERSION:-v0.4.6}"
PROXY_IMAGE="${PROXY_IMAGE:-playwright-proxy:dev}"

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
  kubectl apply --server-side=true -f "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/manifest.yaml"
  kubectl apply --server-side=true -f "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/extensions.yaml"
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
  sed -e "s|namespace: NAMESPACE|namespace: $NAMESPACE|g" \
      -e "s|ghcr.io/carlossg/playwright-k8s-sandbox/proxy:latest|$PROXY_IMAGE|g" \
      -e "s|value: \"playwright\"        # agent-sandbox SandboxWarmPool name|value: \"$warmpool\"|g" \
      -e "s|value: \"9222\"              # Playwright server / MCP port|value: \"$sandbox_port\"|g" \
      -e "s|imagePullPolicy: IfNotPresent|imagePullPolicy: Never|" \
      "$ROOT/deploy/proxy.yaml" | kubectl apply -f -
  kubectl -n "$NAMESPACE" rollout restart deploy/playwright-proxy >/dev/null 2>&1 || true
  kubectl -n "$NAMESPACE" rollout status  deploy/playwright-proxy --timeout=120s
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
    *)
      fail "usage: $0 test {agent-sandbox|openshell|substrate}"
      ;;
  esac
}

PLAYWRIGHT_IMAGE="${PLAYWRIGHT_IMAGE:-localhost:5001/playwright-substrate:slim-1.49.1}"

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
    "$HERE/playwright-client-job.yaml" | kubectl apply -f -
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
  deploy_proxy "$pool" 9222

  apply_playwright_client "alpha"
  apply_playwright_client "beta"

  log "waiting for client Jobs (Playwright handshake + page nav)"
  wait_for_job_success "playwright-e2e-alpha"
  wait_for_job_success "playwright-e2e-beta"

  log "client logs:"
  kubectl -n "$NAMESPACE" logs job/playwright-e2e-alpha | sed 's/^/    [alpha] /'
  kubectl -n "$NAMESPACE" logs job/playwright-e2e-beta  | sed 's/^/    [beta]  /'

  assert_sandboxclaim_exists alpha
  assert_sandboxclaim_exists beta
  # Read the adopted sandbox names from claim status to confirm distinct upstreams.
  local sb_a sb_b
  sb_a=$(kubectl -n "$NAMESPACE" get sandboxclaim pw-alpha -o jsonpath='{.status.sandbox.name}' 2>/dev/null || true)
  sb_b=$(kubectl -n "$NAMESPACE" get sandboxclaim pw-beta  -o jsonpath='{.status.sandbox.name}' 2>/dev/null || true)
  [ -n "$sb_a" ] && [ -n "$sb_b" ] || fail "claim status missing sandbox.name"
  [ "$sb_a" != "$sb_b" ]            || fail "alpha and beta share a sandbox: $sb_a"
  log "pw-alpha → $sb_a ; pw-beta → $sb_b  (distinct ✓)"

  log "Playwright e2e PASSED"
}

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
        -t localhost:5001/playwright-substrate:slim-1.49.1 \
        -f "$HERE/playwright-substrate.Dockerfile" "$HERE" >/dev/null
      rm -f "$HERE/server.js"
      log "pushing to local registry that substrate's atelet reads from"
      docker push localhost:5001/playwright-substrate:slim-1.49.1 >/dev/null
      local pw_digest
      pw_digest=$(docker inspect localhost:5001/playwright-substrate:slim-1.49.1 --format '{{index .RepoDigests 0}}')
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
  up)   shift; cmd_up   "$@" ;;
  test) shift; cmd_test "$@" ;;
  e2e)  shift; cmd_e2e  "$@" ;;
  down) shift; cmd_down "$@" ;;
  ""|-h|--help)
    sed -n '2,11p' "$0"
    ;;
  *) fail "unknown subcommand: $1" ;;
esac
