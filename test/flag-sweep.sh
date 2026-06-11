#!/usr/bin/env bash
# Sweep Chromium flag combinations to find the minimum set required to run
# Playwright under substrate's gVisor (runsc). Each test:
#   - Creates a fresh ActorTemplate referencing the slim Playwright image with
#     a specific CHROMIUM_ARGS env value.
#   - Waits for the golden actor to reach STATUS_RESUMING/RUNNING on a worker.
#   - Probes the actor's :80 directly; PASS if it opens within the deadline.
#   - Captures the workload's stderr from the ateom pod when it fails.
set -euo pipefail

CTX="${CTX:-kind-kind}"
NS="${NS:-pw-substrate}"
WORKERPOOL="${WORKERPOOL:-playwright}"
IMAGE="${IMAGE:-localhost:5001/playwright-substrate@sha256:df925b073cbee699aec4be5bfeb99b951d8b636ffb63186cb1072d70665f6104}"
PROBE_DEADLINE="${PROBE_DEADLINE:-90}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; }
pass() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

apply_template() {
  local name=$1 args=$2
  cat <<EOF | kubectl --context "$CTX" apply -f - >/dev/null
apiVersion: ate.dev/v1alpha1
kind: ActorTemplate
metadata:
  name: $name
  namespace: $NS
spec:
  goldenSnapshotWait: 180s
  runsc:
    amd64:
      url: "gs://gvisor/releases/nightly/2026-05-19/x86_64/runsc"
      sha256Hash: "a397be1abc2420d26bce6c70e6e2ff96c73aaaab929756c56f5e2089ea842b63"
    arm64:
      url: "gs://gvisor/releases/nightly/2026-05-19/aarch64/runsc"
      sha256Hash: "1ba2366ae2efceba166046f51a4104f9261c9cb72c6db8f5b3fe2dc57dea86b9"
  pauseImage: "registry.k8s.io/pause:3.10.2@sha256:f548e0e8e3dc1896ca956272154dde3314e8cc4fde0a57577ee9fa1c63f5baf4"
  containers:
    - name: payload
      image: $IMAGE
      command: ["node", "/server.js"]
      env:
        - { name: NODE_PATH,             value: /usr/local/lib/node_modules }
        - { name: PLAYWRIGHT_BROWSERS_PATH, value: /ms-playwright }
        - { name: PORT,                  value: "80" }
        - { name: CHROMIUM_ARGS,         value: "$args" }
      ports:
        - containerPort: 80
  workerPoolRef:
    namespace: $NS
    name: $WORKERPOOL
  snapshotsConfig:
    location: s3://ate-snapshots/sweep-$name/
EOF
}

wait_for_golden_actor() {
  local name=$1
  local end=$(($(date +%s) + 180))
  while [ "$(date +%s)" -lt "$end" ]; do
    local line
    line=$(kubectl-ate --context "$CTX" get actor 2>/dev/null | awk -v t="$name" '$2==t {print; exit}')
    if [ -n "$line" ]; then
      printf '%s' "$line"
      return 0
    fi
    sleep 3
  done
  return 1
}

# Returns 0 if the actor's port opens within deadline, 1 otherwise.
probe_port() {
  local ip=$1
  local end=$(($(date +%s) + PROBE_DEADLINE))
  while [ "$(date +%s)" -lt "$end" ]; do
    if kubectl --context "$CTX" -n "$NS" exec client-probe -c curl -- \
         nc -w 2 -z "$ip" 80 >/dev/null 2>&1; then
      printf 'opened after %ss\n' "$(( $(date +%s) - (end - PROBE_DEADLINE) ))"
      return 0
    fi
    sleep 5
  done
  return 1
}

ensure_probe_pod() {
  if ! kubectl --context "$CTX" -n "$NS" get pod client-probe >/dev/null 2>&1; then
    kubectl --context "$CTX" -n "$NS" run client-probe \
      --image=curlimages/curl:8.10.1 --restart=Never \
      --command -- sh -c 'sleep 86400' >/dev/null
    kubectl --context "$CTX" -n "$NS" wait --for=condition=Ready pod/client-probe --timeout=60s >/dev/null
  fi
}

run_one() {
  local name=$1 args=$2
  log "[$name] CHROMIUM_ARGS='$args'"
  apply_template "$name" "$args"
  local line
  if ! line=$(wait_for_golden_actor "$name"); then
    fail "[$name] no golden actor appeared within timeout"
    return
  fi
  local actor_id ip
  actor_id=$(awk '{print $3}' <<<"$line")
  ip=$(awk '{print $6}' <<<"$line")
  log "[$name] golden=$actor_id ateom_ip=$ip"
  if [ -z "$ip" ] || [ "$ip" = "<none>" ]; then
    # wait for ip
    local end=$(($(date +%s) + 60))
    while [ "$(date +%s)" -lt "$end" ]; do
      ip=$(kubectl-ate --context "$CTX" get actor "$actor_id" 2>/dev/null | awk 'NR==2 {print $6}')
      [ -n "$ip" ] && [ "$ip" != "<none>" ] && break
      sleep 3
    done
    log "[$name] resolved ateom_ip=$ip"
  fi
  if probe_port "$ip"; then
    pass "[$name] port opened"
  else
    fail "[$name] port stayed refused for ${PROBE_DEADLINE}s"
    # capture last interesting lines from ateom pod
    local ateom_pod
    ateom_pod=$(kubectl --context "$CTX" -n "$NS" get pod -o name 2>/dev/null \
      | grep playwright-deployment | head -1)
    if [ -n "$ateom_pod" ]; then
      kubectl --context "$CTX" -n "$NS" logs "$ateom_pod" --tail=200 2>/dev/null \
        | grep '"message"' \
        | grep -vE '"name":|gofer|Statistics|cli\.go|config\.go|NetNS|Eth0 link|Mapping host|container\.go|sandbox\.go' \
        | tail -10 | sed "s/^/    [$name] /"
    fi
  fi
}

ensure_probe_pod

run_one baseline   "--no-sandbox,--disable-setuid-sandbox,--single-process,--disable-dev-shm-usage,--disable-gpu"
run_one no-flags   ""
run_one no-sandbox "--disable-setuid-sandbox,--single-process,--disable-dev-shm-usage,--disable-gpu"
run_one no-setuid  "--no-sandbox,--single-process,--disable-dev-shm-usage,--disable-gpu"
run_one no-single  "--no-sandbox,--disable-setuid-sandbox,--disable-dev-shm-usage,--disable-gpu"
run_one no-shm     "--no-sandbox,--disable-setuid-sandbox,--single-process,--disable-gpu"
run_one no-gpu     "--no-sandbox,--disable-setuid-sandbox,--single-process,--disable-dev-shm-usage"
