#!/usr/bin/env bash
# Page-fetch latency bench per backend × scenario.
#
# Scenarios:
#   cold     — no Playwright runtime exists for the playwright-id; first request
#              has to provision it (sandboxclaim → claim+sandbox, substrate →
#              CreateActor + restore-from-golden, kars → KarsSandbox CR create +
#              controller reconcile + pod schedule + Chromium start)
#   warm     — runtime already exists for the id; just connect+fetch
#   restore  — for substrate only as a *distinct* path: the actor was previously
#              running and then suspended; ResumeActor restores from the
#              per-actor snapshot (not the golden one). agent-sandbox, openshell,
#              and kars don't have a hibernate model, so 'restore' there is the
#              same code path as 'cold' (sandbox is destroyed and recreated).
#
# Per-backend usage:
#   ./bench.sh agent-sandbox
#   ./bench.sh openshell
#   ./bench.sh substrate
#   ./bench.sh kars
#   ./bench.sh all                  # runs all four, prints a combined markdown table
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

SLIM_IMAGE_TAG="localhost:5001/playwright-substrate:slim-1.49.1"
KARS_CLUSTER="${KARS_CLUSTER:-kars-playwright}"
KARS_NS="${KARS_NS:-pw-kars}"
RESULTS_FILE="${RESULTS_FILE:-/tmp/bench-results.csv}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

# Apply a one-off client Job in $ns with the given playwright-id, wait up to
# $deadline seconds for it to complete, and echo a single line: BENCH <json>
# Returns 0 on PASS, 1 on FAIL. The client.js itself emits the JSON timing.
run_client() {
  local backend=$1 scenario=$2 ns=$3 ctx=$4 id=$5 target=$6
  local deadline=${7:-180}
  local jobname="bench-${backend}-${scenario}-${id}"
  kubectl --context "$ctx" -n "$ns" delete job "$jobname" --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context "$ctx" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $jobname
  namespace: $ns
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      labels: { app.kubernetes.io/name: bench-client, playwright-id: $id }
    spec:
      restartPolicy: Never
      containers:
        - name: client
          image: $SLIM_IMAGE_TAG
          imagePullPolicy: Never
          command: ["node", "/scripts/client.js"]
          env:
            - { name: NODE_PATH, value: /usr/local/lib/node_modules }
            - { name: PLAYWRIGHT_BROWSERS_PATH, value: /ms-playwright }
            - { name: PW_URL, value: "ws://playwright-proxy:9000/" }
            - { name: PW_ID, value: "$id" }
            - { name: PW_TARGET_URL, value: "$target" }
          volumeMounts:
            - { name: scripts, mountPath: /scripts, readOnly: true }
      volumes:
        - { name: scripts, configMap: { name: playwright-scripts } }
EOF
  # Wait for Complete or Failed. On Failed, look at logs — a 403 means the
  # proxy's pod informer hadn't synced the client's playwright-id label yet
  # (races with Job pod creation). Retry once on 403.
  local attempts=2
  while [ "$attempts" -gt 0 ]; do
    attempts=$((attempts - 1))
    local end=$(($(date +%s) + deadline))
    while [ "$(date +%s)" -lt "$end" ]; do
      if kubectl --context "$ctx" -n "$ns" get job "$jobname" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null | grep -q True; then
        kubectl --context "$ctx" -n "$ns" logs "job/$jobname" 2>/dev/null | grep '^BENCH '
        return 0
      fi
      if kubectl --context "$ctx" -n "$ns" get job "$jobname" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null | grep -q True; then
        if [ "$attempts" -gt 0 ] && kubectl --context "$ctx" -n "$ns" logs "job/$jobname" --tail=30 2>/dev/null | grep -q '403 Forbidden\|not labelled with playwright-id'; then
          warn "[$backend/$scenario/$id] proxy 403 (informer race) — retrying once"
          kubectl --context "$ctx" -n "$ns" delete job "$jobname" --ignore-not-found >/dev/null 2>&1 || true
          sleep 5
          kubectl --context "$ctx" apply -f - >/dev/null <<EOF2
apiVersion: batch/v1
kind: Job
metadata:
  name: $jobname
  namespace: $ns
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      labels: { app.kubernetes.io/name: bench-client, playwright-id: $id }
    spec:
      restartPolicy: Never
      containers:
        - name: client
          image: $SLIM_IMAGE_TAG
          imagePullPolicy: Never
          command: ["node", "/scripts/client.js"]
          env:
            - { name: NODE_PATH, value: /usr/local/lib/node_modules }
            - { name: PLAYWRIGHT_BROWSERS_PATH, value: /ms-playwright }
            - { name: PW_URL, value: "ws://playwright-proxy:9000/" }
            - { name: PW_ID, value: "$id" }
            - { name: PW_TARGET_URL, value: "$target" }
          volumeMounts:
            - { name: scripts, mountPath: /scripts, readOnly: true }
      volumes:
        - { name: scripts, configMap: { name: playwright-scripts } }
EOF2
          break  # break inner; outer 'while attempts' retries
        fi
        warn "[$backend/$scenario/$id] job FAILED — logs:"
        kubectl --context "$ctx" -n "$ns" logs "job/$jobname" --tail=20 2>&1 | sed "s/^/      /" >&2
        return 1
      fi
      sleep 2
    done
  done
  warn "[$backend/$scenario/$id] deadline ${deadline}s exceeded"
  kubectl --context "$ctx" -n "$ns" logs "job/$jobname" --tail=20 2>&1 | sed "s/^/      /" >&2
  return 1
}

# Ensure scripts ConfigMap + test-target Service exist in the given namespace.
ensure_bench_deps() {
  local ns=$1 ctx=$2
  sed "s/NAMESPACE/$ns/g" "$HERE/playwright-scripts.yaml" | kubectl --context "$ctx" apply -f - >/dev/null
  sed "s/NAMESPACE/$ns/g" "$HERE/test-target.yaml" | kubectl --context "$ctx" apply -f - >/dev/null
  kubectl --context "$ctx" -n "$ns" rollout status deploy/test-target --timeout=60s >/dev/null
}

# Ensure the slim image is in the cluster's containerd (imagePullPolicy=Never).
ensure_image_in_cluster() {
  local cluster=$1
  if ! docker exec "${cluster}-control-plane" ctr --namespace=k8s.io images ls -q 2>/dev/null \
       | grep -q "playwright-substrate:slim-1.49.1\|playwright-substrate@sha256"; then
    log "loading $SLIM_IMAGE_TAG into kind cluster $cluster"
    docker save "$SLIM_IMAGE_TAG" | docker exec -i "${cluster}-control-plane" \
      ctr --namespace=k8s.io images import --no-unpack - >/dev/null
  fi
}

record() {
  local backend=$1 scenario=$2 result=$3 json=$4
  printf '%s,%s,%s,%s\n' "$backend" "$scenario" "$result" "$json" >> "$RESULTS_FILE"
}

# ---------------- sandboxclaim (agent-sandbox + openshell) -----------------

# Wipe any prior session+sandbox so the next client triggers a cold provision.
# Ensure a labelled probe pod exists in $ns; used by wait_for_proxy_ready as
# an end-to-end "is the data plane actually serving labelled clients" gate.
ensure_labelled_probe_pod() {
  local ns=$1 ctx=$2
  if ! kubectl --context "$ctx" -n "$ns" get pod bench-probe >/dev/null 2>&1; then
    kubectl --context "$ctx" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: bench-probe
  namespace: $ns
  labels: { playwright-id: bench-probe-id }
spec:
  restartPolicy: Always
  containers:
    - name: c
      image: curlimages/curl:8.10.1
      command: ["sh","-c","sleep 86400"]
EOF
    kubectl --context "$ctx" -n "$ns" wait --for=condition=Ready pod/bench-probe --timeout=60s >/dev/null
  fi
}

# Block until the proxy is actually serving from a peer pod's perspective.
# Proves: kube-proxy reprogrammed Service iptables (TCP connect succeeds),
# AND the proxy's pod informer is synced enough to identify a labelled pod
# (the probe gets past the 403 'not labelled with playwright-id' check —
# we accept 502/504 as success because they mean the auth check passed but
# the proxy has no upstream for this probe id, which is expected).
wait_for_proxy_ready() {
  local ns=$1 ctx=$2
  ensure_labelled_probe_pod "$ns" "$ctx"
  local end=$(($(date +%s) + 60)) code=000
  while [ "$(date +%s)" -lt "$end" ]; do
    code=$(kubectl --context "$ctx" -n "$ns" exec bench-probe -- \
      curl -sS -o /dev/null -w '%{http_code}' --max-time 3 \
      http://playwright-proxy:9000/__bench_probe 2>/dev/null || echo 000)
    case "$code" in
      000|403) ;;              # not ready: TCP failed (kube-proxy stale) or
                               # informer hasn't seen this probe pod yet
      *) return 0 ;;           # any HTTP response (200/502/503/504) → proxy
                               # identified us and the data path is up
    esac
    sleep 1
  done
  warn "proxy in $ns never became ready (last http_code=$code)"
  return 1
}

wipe_sandboxclaim() {
  local ns=$1 ctx=$2 id=$3
  kubectl --context "$ctx" -n "$ns" delete sandboxclaim "pw-$id" --ignore-not-found >/dev/null 2>&1 || true
  # Also restart the proxy to clear its in-memory session map for this id.
  # (cheap; ~10s rollout in kind)
  kubectl --context "$ctx" -n "$ns" rollout restart deploy/playwright-proxy >/dev/null 2>&1 || true
  kubectl --context "$ctx" -n "$ns" rollout status  deploy/playwright-proxy --timeout=120s >/dev/null
  wait_for_proxy_ready "$ns" "$ctx"
}

bench_sandboxclaim() {
  local backend=$1 ns=$2 ctx=$3 cluster=$4
  local id="bench-${backend}"
  local warmpool="playwright"
  if [ "$backend" = openshell ]; then warmpool="playwright-openshell"; fi
  log "[$backend] preparing (warmpool=$warmpool)"
  ensure_image_in_cluster "$cluster"
  ensure_bench_deps "$ns" "$ctx"
  # For openshell we also need its SandboxTemplate + WarmPool to exist; copy
  # from the agent-sandbox template name. The openshell example manifests use
  # name "playwright-openshell" which the proxy will reference below.
  if [ "$backend" = openshell ]; then
    sed -e "s/NAMESPACE/$ns/g" -e "s/NAME/$warmpool/g" \
      "$HERE/playwright-sandboxtemplate.yaml" | kubectl --context "$ctx" apply -f - >/dev/null
    sed -e "s/NAMESPACE/$ns/g" -e "s/NAME/$warmpool/g" \
      "$HERE/playwright-warmpool.yaml" | kubectl --context "$ctx" apply -f - >/dev/null
    log "[$backend] waiting for warmpool $warmpool to be ready"
    for _ in $(seq 1 60); do
      ready=$(kubectl --context "$ctx" -n "$ns" get sandboxwarmpool "$warmpool" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
      [ "${ready:-0}" -ge 1 ] && break
      sleep 2
    done
  fi
  # Make sure we have a labelled probe pod for the readiness gate.
  ensure_labelled_probe_pod "$ns" "$ctx"
  log "[$backend] deploying proxy (WARMPOOL_NAME=$warmpool, SANDBOX_PORT=9222)"
  sed -e "s|namespace: NAMESPACE|namespace: $ns|g" \
      -e "s|ghcr.io/carlossg/playwright-k8s-sandbox/proxy:latest|playwright-proxy:dev|g" \
      -e "s|value: \"playwright\"        # agent-sandbox SandboxWarmPool name|value: \"$warmpool\"|g" \
      -e "s|value: \"9222\"              # Playwright server / MCP port|value: \"9222\"|g" \
      -e "s|imagePullPolicy: IfNotPresent|imagePullPolicy: Never|" \
      "$ROOT/deploy/proxy.yaml" | kubectl --context "$ctx" apply -f - >/dev/null
  kubectl --context "$ctx" -n "$ns" rollout restart deploy/playwright-proxy >/dev/null 2>&1 || true
  kubectl --context "$ctx" -n "$ns" rollout status  deploy/playwright-proxy --timeout=120s >/dev/null

  # cold
  log "[$backend cold] wiping prior session"
  wipe_sandboxclaim "$ns" "$ctx" "$id"
  log "[$backend cold] running client"
  if out=$(run_client "$backend" cold "$ns" "$ctx" "$id" "http://test-target/" 180); then
    record "$backend" cold PASS "${out#BENCH }"
    log "[$backend cold] $out"
  else
    record "$backend" cold FAIL "{}"
  fi

  # warm — reuse the now-existing session
  log "[$backend warm] running client (same id, no wipe)"
  if out=$(run_client "$backend" warm "$ns" "$ctx" "$id" "http://test-target/" 60); then
    record "$backend" warm PASS "${out#BENCH }"
    log "[$backend warm] $out"
  else
    record "$backend" warm FAIL "{}"
  fi

  # restore — same code path as cold for sandboxclaim backends
  log "[$backend restore] wiping (same as cold for sandboxclaim)"
  wipe_sandboxclaim "$ns" "$ctx" "$id"
  # Give the warmpool time to replenish (cold consumed one of the 2 warm pods).
  for _ in $(seq 1 60); do
    ready=$(kubectl --context "$ctx" -n "$ns" get sandboxwarmpool "$warmpool" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    [ "${ready:-0}" -ge 1 ] && break
    sleep 2
  done
  if out=$(run_client "$backend" restore "$ns" "$ctx" "$id" "http://test-target/" 240); then
    record "$backend" restore PASS "${out#BENCH }"
    log "[$backend restore] $out"
  else
    record "$backend" restore FAIL "{}"
  fi
}

# --------------------------- substrate -------------------------------------

wipe_substrate_actor() {
  local id=$1
  kubectl-ate --context kind-kind suspend actor "pw-$id" 2>/dev/null | head -1 || true
  sleep 3
  kubectl-ate --context kind-kind delete actor "pw-$id" 2>/dev/null | head -1 || true
  kubectl --context kind-kind -n pw-substrate rollout restart deploy/playwright-proxy >/dev/null 2>&1 || true
  kubectl --context kind-kind -n pw-substrate rollout status deploy/playwright-proxy --timeout=60s >/dev/null
  wait_for_proxy_ready pw-substrate kind-kind
}

suspend_substrate_actor() {
  local id=$1
  kubectl-ate --context kind-kind suspend actor "pw-$id" 2>/dev/null | head -1 || true
  # Wait for actor to actually be SUSPENDED
  for _ in $(seq 1 30); do
    local st
    st=$(kubectl-ate --context kind-kind get actor "pw-$id" 2>/dev/null | awk 'NR==2 {print $4}')
    [ "$st" = STATUS_SUSPENDED ] && break
    sleep 2
  done
  if [ "$st" != STATUS_SUSPENDED ]; then
    warn "[substrate] actor pw-$id did not reach STATUS_SUSPENDED"
    return 1
  fi
  # Out-of-band suspend leaves the proxy with a stale cached session — restart
  # it so the next request re-Ensures (calls ResumeActor + the upstream
  # readiness probe) instead of forwarding to atenet against a not-yet-ready
  # upstream.
  kubectl --context kind-kind -n pw-substrate rollout restart deploy/playwright-proxy >/dev/null 2>&1 || true
  kubectl --context kind-kind -n pw-substrate rollout status  deploy/playwright-proxy --timeout=120s >/dev/null
  wait_for_proxy_ready pw-substrate kind-kind
}

bench_substrate() {
  local ns=pw-substrate ctx=kind-kind cluster=kind
  local id="bench-substrate"
  log "[substrate] preparing"
  ensure_image_in_cluster "$cluster"
  ensure_bench_deps "$ns" "$ctx"
  ensure_labelled_probe_pod "$ns" "$ctx"
  # The substrate proxy is left running by the harness; gate on it being
  # actually serving before any cold scenario.
  wait_for_proxy_ready "$ns" "$ctx"

  # cold — no actor exists; CreateActor + restore-from-golden
  log "[substrate cold] wiping prior actor"
  wipe_substrate_actor "$id"
  log "[substrate cold] running client"
  if out=$(run_client substrate cold "$ns" "$ctx" "$id" "http://test-target/" 180); then
    record substrate cold PASS "${out#BENCH }"
    log "[substrate cold] $out"
  else
    record substrate cold FAIL "{}"
  fi

  # warm
  log "[substrate warm] running client"
  if out=$(run_client substrate warm "$ns" "$ctx" "$id" "http://test-target/" 60); then
    record substrate warm PASS "${out#BENCH }"
    log "[substrate warm] $out"
  else
    record substrate warm FAIL "{}"
  fi

  # restore — suspend then re-request → restore from PER-ACTOR snapshot
  log "[substrate restore] suspending actor"
  if suspend_substrate_actor "$id"; then
    log "[substrate restore] running client (should restore from per-actor snapshot)"
    if out=$(run_client substrate restore "$ns" "$ctx" "$id" "http://test-target/" 180); then
      record substrate restore PASS "${out#BENCH }"
      log "[substrate restore] $out"
    else
      record substrate restore FAIL "{}"
    fi
  else
    record substrate restore FAIL "{}"
  fi
}

# -------------------------------- kars --------------------------------------

# Delete the KarsSandbox CR and wait for the controller to finish tearing down
# the sandbox namespace, then restart the proxy so its in-memory session map is
# cleared before the next cold scenario.
wipe_karssandbox() {
  local ns=$1 ctx=$2 id=$3
  local cr="pw-$id"
  local sandbox_ns="kars-$cr"

  kubectl --context "$ctx" -n "$ns" delete karssandbox "$cr" --ignore-not-found >/dev/null 2>&1 || true

  # Wait for the controller's finalizer to delete the sandbox namespace (up to 60s).
  local end=$(($(date +%s) + 60))
  while [ "$(date +%s)" -lt "$end" ]; do
    if ! kubectl --context "$ctx" get namespace "$sandbox_ns" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  # Clear proxy session cache.
  kubectl --context "$ctx" -n "$ns" rollout restart deploy/playwright-proxy >/dev/null 2>&1 || true
  kubectl --context "$ctx" -n "$ns" rollout status  deploy/playwright-proxy --timeout=120s >/dev/null
  wait_for_proxy_ready "$ns" "$ctx"
}

bench_kars() {
  local ctx="--context=kind-$KARS_CLUSTER"
  local ns="$KARS_NS"
  local id="bench-kars"

  log "[kars] preparing (cluster=$KARS_CLUSTER, ns=$ns)"

  # The kars cluster must already be up (harness.sh up-kars). Verify it.
  if ! kubectl $ctx get ns kars-system >/dev/null 2>&1; then
    warn "[kars] kars-system namespace not found in cluster '$KARS_CLUSTER'"
    warn "       Run: ./harness.sh up-kars"
    record kars cold  FAIL "{}"
    record kars warm  FAIL "{}"
    record kars restore FAIL "{}"
    return 1
  fi

  ensure_image_in_cluster "$KARS_CLUSTER"
  ensure_bench_deps "$ns" "$ctx"
  ensure_labelled_probe_pod "$ns" "$ctx"

  log "[kars] deploying proxy (BACKEND=karssandbox, SANDBOX_PORT=9222)"
  sed -e "s|namespace: NAMESPACE|namespace: $ns|g" \
      -e "s|PROXY_IMAGE|playwright-proxy:dev|g" \
      -e "s|PLAYWRIGHT_IMAGE|$SLIM_IMAGE_TAG|g" \
      "$HERE/proxy-kars.yaml" | kubectl $ctx apply -f - >/dev/null
  kubectl $ctx -n "$ns" rollout restart deploy/playwright-proxy >/dev/null 2>&1 || true
  kubectl $ctx -n "$ns" rollout status  deploy/playwright-proxy --timeout=120s >/dev/null

  # kars cold starts are slow (no warmpool; namespace + pod + Chromium). Give
  # the bench client 300s — well above the 180s ENSURE_TIMEOUT on the proxy.
  local cold_deadline=300

  # Use the FQDN for the target: the sandbox pod runs in kars-{id} namespace,
  # so a bare "test-target" hostname would not resolve there.
  local target_url="http://test-target.${ns}.svc.cluster.local/"

  # cold
  log "[kars cold] wiping prior sandbox"
  wipe_karssandbox "$ns" "$ctx" "$id"
  log "[kars cold] running client"
  if out=$(run_client kars cold "$ns" "$ctx" "$id" "$target_url" "$cold_deadline"); then
    record kars cold PASS "${out#BENCH }"
    log "[kars cold] $out"
  else
    record kars cold FAIL "{}"
  fi

  # warm — reuse the running sandbox
  log "[kars warm] running client (same id, sandbox already running)"
  if out=$(run_client kars warm "$ns" "$ctx" "$id" "$target_url" 60); then
    record kars warm PASS "${out#BENCH }"
    log "[kars warm] $out"
  else
    record kars warm FAIL "{}"
  fi

  # restore — same code path as cold for kars (no snapshot/hibernate)
  log "[kars restore] wiping (same as cold — kars has no snapshot)"
  wipe_karssandbox "$ns" "$ctx" "$id"
  if out=$(run_client kars restore "$ns" "$ctx" "$id" "$target_url" "$cold_deadline"); then
    record kars restore PASS "${out#BENCH }"
    log "[kars restore] $out"
  else
    record kars restore FAIL "{}"
  fi
}

# ----------------------------- main ----------------------------------------

print_table() {
  printf '\n| backend | scenario | result | connect_ms | newPage_ms | goto_ms | total_ms |\n'
  printf   '|---------|----------|--------|-----------:|-----------:|--------:|---------:|\n'
  while IFS=, read -r backend scenario result json; do
    if [ "$result" = PASS ] && [ -n "$json" ] && [ "$json" != '{}' ]; then
      c=$(echo  "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["connect_ms"])')
      n=$(echo  "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["newPage_ms"])')
      g=$(echo  "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["goto_ms"])')
      t=$(echo  "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["total_ms"])')
      printf '| %s | %s | %s | %d | %d | %d | %d |\n' "$backend" "$scenario" "$result" "$c" "$n" "$g" "$t"
    else
      printf '| %s | %s | %s | — | — | — | — |\n' "$backend" "$scenario" "$result"
    fi
  done < "$RESULTS_FILE"
}

main() {
  : > "$RESULTS_FILE"

  case "${1:-all}" in
    agent-sandbox) bench_sandboxclaim agent-sandbox pw-test kind-playwright-proxy playwright-proxy ;;
    openshell)     bench_sandboxclaim openshell     pw-test kind-playwright-proxy playwright-proxy ;;
    substrate)     bench_substrate ;;
    kars)          bench_kars ;;
    all)
      bench_sandboxclaim agent-sandbox pw-test kind-playwright-proxy playwright-proxy
      bench_sandboxclaim openshell     pw-test kind-playwright-proxy playwright-proxy
      bench_substrate
      bench_kars
      ;;
    *) fail "usage: $0 {agent-sandbox|openshell|substrate|kars|all}" ;;
  esac
  print_table
}

main "$@"
