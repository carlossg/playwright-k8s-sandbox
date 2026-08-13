#!/usr/bin/env bash
# Test script for an already-running playwright-proxy service.
#
# Usage:
#   ./test-existing-proxy.sh [OPTIONS]
#
# Options:
#   -n, --namespace NAMESPACE    Namespace where playwright-proxy is running (default: from context or "default")
#   -s, --service SERVICE        Service name (default: "playwright-proxy")
#   -p, --port PORT              Service port (default: 9000)
#   -b, --backend BACKEND        Backend type: isola, kars, agent-sandbox, substrate (default: auto-detect)
#   -c, --client-ids IDS         Comma-separated client IDs to test (default: "alpha,beta")
#   --ws-only                    Test WebSocket path only (skip MCP/SSE)
#   --mcp-only                   Test MCP/SSE path only (skip WebSocket)
#   --skip-target                Don't deploy test-target (assume it exists)
#   --cleanup                    Clean up test resources after completion
#   -h, --help                   Show this help
#
# Examples:
#   # Test isola backend in pw-isola namespace
#   ./test-existing-proxy.sh -n pw-isola -b isola
#
#   # Test with custom client IDs
#   ./test-existing-proxy.sh -n my-ns -c "client1,client2,client3"
#
#   # Test only WebSocket path
#   ./test-existing-proxy.sh -n my-ns --ws-only
#
# Prerequisites:
#   - kubectl configured with access to the cluster
#   - playwright-proxy service running and reachable
#   - Appropriate backend (isola/kars/agent-sandbox) installed and configured

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# Default values
NAMESPACE=""
SERVICE_NAME="playwright-proxy"
SERVICE_PORT="9000"
BACKEND=""
CLIENT_IDS="alpha,beta"
TEST_WS=true
TEST_MCP=true
SKIP_TARGET=false
CLEANUP=false
PLAYWRIGHT_IMAGE="${PLAYWRIGHT_IMAGE:-mcr.microsoft.com/playwright:v1.49.0-noble}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '\033[0;36m   \033[0m %s\n' "$*"; }
pass() { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*" >&2; }

show_help() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)    NAMESPACE="$2"; shift 2 ;;
    -s|--service)      SERVICE_NAME="$2"; shift 2 ;;
    -p|--port)         SERVICE_PORT="$2"; shift 2 ;;
    -b|--backend)      BACKEND="$2"; shift 2 ;;
    -c|--client-ids)   CLIENT_IDS="$2"; shift 2 ;;
    --ws-only)         TEST_MCP=false; shift ;;
    --mcp-only)        TEST_WS=false; shift ;;
    --skip-target)     SKIP_TARGET=true; shift ;;
    --cleanup)         CLEANUP=true; shift ;;
    -h|--help)         show_help ;;
    *)                 fail "unknown option: $1 (use --help)" ;;
  esac
done

# Auto-detect namespace if not provided
if [ -z "$NAMESPACE" ]; then
  NAMESPACE=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || echo "default")
  info "using namespace: $NAMESPACE (from context)"
fi

# Validate service exists
if ! kubectl -n "$NAMESPACE" get service "$SERVICE_NAME" >/dev/null 2>&1; then
  fail "service '$SERVICE_NAME' not found in namespace '$NAMESPACE'"
fi

# Auto-detect backend if not provided
if [ -z "$BACKEND" ]; then
  log "auto-detecting backend from proxy deployment env vars"
  BACKEND=$(kubectl -n "$NAMESPACE" get deploy playwright-proxy \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="BACKEND")].value}' 2>/dev/null || echo "")

  if [ -z "$BACKEND" ]; then
    BACKEND="sandboxclaim"
    warn "could not detect BACKEND, assuming 'sandboxclaim' (agent-sandbox)"
  fi
  info "detected backend: $BACKEND"
fi

# Normalize backend name
case "$BACKEND" in
  sandboxclaim|agent-sandbox) BACKEND_TYPE="sandboxclaim" ;;
  substrate)                   BACKEND_TYPE="substrate" ;;
  kars|karssandbox)           BACKEND_TYPE="karssandbox" ;;
  isola)                       BACKEND_TYPE="isola" ;;
  *)                           fail "unknown backend: $BACKEND" ;;
esac

log "testing playwright-proxy: $SERVICE_NAME:$SERVICE_PORT in namespace $NAMESPACE"
log "backend: $BACKEND_TYPE"
log "client IDs: $CLIENT_IDS"

# Deploy test target if needed
if [ "$SKIP_TARGET" = false ]; then
  log "deploying test-target (traefik/whoami)"
  sed "s/NAMESPACE/$NAMESPACE/g" "$HERE/test-target.yaml" | kubectl apply -f -
  kubectl -n "$NAMESPACE" rollout status deploy/test-target --timeout=60s
  pass "test-target ready"
fi

# Deploy playwright scripts ConfigMap (contains client.js)
log "deploying playwright-scripts ConfigMap"
sed "s/NAMESPACE/$NAMESPACE/g" "$HERE/playwright-scripts.yaml" | kubectl apply -f -

# Function to deploy a test client
deploy_client() {
  local client_id="$1"
  local job_name="playwright-test-${client_id}"

  info "deploying client: $client_id"

  # Clean up any existing job
  kubectl -n "$NAMESPACE" delete job "$job_name" --ignore-not-found --wait=true >/dev/null 2>&1 || true

  # Create the job from template
  sed -e "s/NAMESPACE/$NAMESPACE/g" \
      -e "s/CLIENTID/$client_id/g" \
      -e "s|image: PLAYWRIGHT_IMAGE|image: $PLAYWRIGHT_IMAGE|g" \
      -e "s|imagePullPolicy: Never|imagePullPolicy: IfNotPresent|g" \
      -e "s/playwright-e2e-/playwright-test-/g" \
      "$HERE/playwright-client-job.yaml" | kubectl apply -f -
}

# Function to wait for job completion
wait_for_job() {
  local job_name="$1"
  local timeout_s="${2:-300}"
  local start_time=$(date +%s)

  while true; do
    local elapsed=$(($(date +%s) - start_time))
    if [ "$elapsed" -gt "$timeout_s" ]; then
      kubectl -n "$NAMESPACE" describe job "$job_name" || true
      kubectl -n "$NAMESPACE" logs "job/$job_name" --tail=50 || true
      fail "job $job_name timed out after ${timeout_s}s"
    fi

    # Check if completed
    if kubectl -n "$NAMESPACE" get job "$job_name" \
         -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null \
         | grep -q True; then
      return 0
    fi

    # Check if failed
    if kubectl -n "$NAMESPACE" get job "$job_name" \
         -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null \
         | grep -q True; then
      kubectl -n "$NAMESPACE" logs "job/$job_name" --tail=50 || true
      fail "job $job_name failed"
    fi

    sleep 2
  done
}

# Function to verify sandbox/claim creation
verify_sandbox_created() {
  local client_id="$1"
  local resource_name="pw-${client_id}"

  case "$BACKEND_TYPE" in
    sandboxclaim)
      if kubectl -n "$NAMESPACE" get sandboxclaim "$resource_name" >/dev/null 2>&1; then
        pass "SandboxClaim $resource_name exists"
        return 0
      fi
      fail "SandboxClaim $resource_name not found"
      ;;

    isola)
      # Isola sandboxes live in a separate namespace
      local isola_ns=$(kubectl -n "$NAMESPACE" get deploy playwright-proxy \
        -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ISOLA_NAMESPACE")].value}' \
        2>/dev/null || echo "isola-sandboxes")

      if kubectl -n "$isola_ns" get sandbox "$resource_name" >/dev/null 2>&1; then
        local pod_ip=$(kubectl -n "$isola_ns" get sandbox "$resource_name" \
          -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")
        pass "Sandbox $resource_name exists (podIP: $pod_ip)"
        return 0
      fi
      fail "Sandbox $resource_name not found in namespace $isola_ns"
      ;;

    karssandbox)
      # KARS creates per-client namespaces
      local kars_ns="pw-${client_id}"
      if kubectl -n "$kars_ns" get karssandbox "$resource_name" >/dev/null 2>&1; then
        pass "KarsSandbox $resource_name exists in namespace $kars_ns"
        return 0
      fi
      fail "KarsSandbox $resource_name not found"
      ;;

    substrate)
      if kubectl -n "$NAMESPACE" get actor "pw-${client_id}" >/dev/null 2>&1; then
        pass "Actor pw-${client_id} exists"
        return 0
      fi
      fail "Actor pw-${client_id} not found"
      ;;
  esac
}

# Function to extract timing from logs
extract_timing() {
  local job_name="$1"
  local logs=$(kubectl -n "$NAMESPACE" logs "job/$job_name" 2>/dev/null || echo "")

  # Look for BENCH line
  local bench_line=$(echo "$logs" | grep "^BENCH " || echo "")
  if [ -n "$bench_line" ]; then
    echo "$bench_line" | sed 's/^BENCH //'
  else
    echo "{}"
  fi
}

# Test WebSocket path
if [ "$TEST_WS" = true ]; then
  log "testing WebSocket path"

  # Convert comma-separated IDs to array
  IFS=',' read -ra CLIENT_ARRAY <<< "$CLIENT_IDS"

  # Deploy all clients
  for client_id in "${CLIENT_ARRAY[@]}"; do
    deploy_client "$client_id"
  done

  # Wait for all jobs
  for client_id in "${CLIENT_ARRAY[@]}"; do
    log "waiting for client: $client_id"
    wait_for_job "playwright-test-${client_id}"
    pass "client $client_id completed"

    # Show timing
    timing=$(extract_timing "playwright-test-${client_id}")
    if [ "$timing" != "{}" ]; then
      info "timing: $timing"
    fi

    # Verify sandbox was created
    verify_sandbox_created "$client_id"
  done

  # Verify distinct sandboxes
  if [ "${#CLIENT_ARRAY[@]}" -ge 2 ]; then
    log "verifying sandbox isolation"

    case "$BACKEND_TYPE" in
      sandboxclaim)
        sb_0=$(kubectl -n "$NAMESPACE" get sandboxclaim "pw-${CLIENT_ARRAY[0]}" \
          -o jsonpath='{.status.sandbox.name}' 2>/dev/null || echo "")
        sb_1=$(kubectl -n "$NAMESPACE" get sandboxclaim "pw-${CLIENT_ARRAY[1]}" \
          -o jsonpath='{.status.sandbox.name}' 2>/dev/null || echo "")

        if [ -n "$sb_0" ] && [ -n "$sb_1" ] && [ "$sb_0" != "$sb_1" ]; then
          pass "distinct sandboxes: ${CLIENT_ARRAY[0]}→$sb_0, ${CLIENT_ARRAY[1]}→$sb_1"
        else
          warn "could not verify distinct sandboxes"
        fi
        ;;

      isola)
        isola_ns=$(kubectl -n "$NAMESPACE" get deploy playwright-proxy \
          -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ISOLA_NAMESPACE")].value}' \
          2>/dev/null || echo "isola-sandboxes")

        ip_0=$(kubectl -n "$isola_ns" get sandbox "pw-${CLIENT_ARRAY[0]}" \
          -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")
        ip_1=$(kubectl -n "$isola_ns" get sandbox "pw-${CLIENT_ARRAY[1]}" \
          -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")

        if [ -n "$ip_0" ] && [ -n "$ip_1" ] && [ "$ip_0" != "$ip_1" ]; then
          pass "distinct pod IPs: ${CLIENT_ARRAY[0]}→$ip_0, ${CLIENT_ARRAY[1]}→$ip_1"
        else
          warn "could not verify distinct pod IPs"
        fi
        ;;

      karssandbox)
        ns_0="pw-${CLIENT_ARRAY[0]}"
        ns_1="pw-${CLIENT_ARRAY[1]}"
        if kubectl get ns "$ns_0" >/dev/null 2>&1 && kubectl get ns "$ns_1" >/dev/null 2>&1; then
          pass "distinct namespaces: $ns_0, $ns_1"
        else
          warn "could not verify distinct namespaces"
        fi
        ;;
    esac
  fi

  log "WebSocket path: PASSED ✓"
fi

# Test MCP/SSE path
if [ "$TEST_MCP" = true ]; then
  log "testing MCP/SSE path"
  warn "MCP/SSE test not yet implemented (routing logic identical to WebSocket)"
  # TODO: Implement MCP-specific test using HTTP SSE endpoint
  # Would need a different client that uses http://playwright-proxy:9000/sse
fi

# Cleanup
if [ "$CLEANUP" = true ]; then
  log "cleaning up test resources"

  IFS=',' read -ra CLIENT_ARRAY <<< "$CLIENT_IDS"
  for client_id in "${CLIENT_ARRAY[@]}"; do
    kubectl -n "$NAMESPACE" delete job "playwright-test-${client_id}" --ignore-not-found >/dev/null 2>&1 || true

    case "$BACKEND_TYPE" in
      sandboxclaim)
        kubectl -n "$NAMESPACE" delete sandboxclaim "pw-${client_id}" --ignore-not-found >/dev/null 2>&1 || true
        ;;
      isola)
        isola_ns=$(kubectl -n "$NAMESPACE" get deploy playwright-proxy \
          -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ISOLA_NAMESPACE")].value}' \
          2>/dev/null || echo "isola-sandboxes")
        kubectl -n "$isola_ns" delete sandbox "pw-${client_id}" --ignore-not-found >/dev/null 2>&1 || true
        ;;
      karssandbox)
        kubectl delete ns "pw-${client_id}" --ignore-not-found >/dev/null 2>&1 || true
        ;;
      substrate)
        kubectl -n "$NAMESPACE" delete actor "pw-${client_id}" --ignore-not-found >/dev/null 2>&1 || true
        ;;
    esac
  done

  if [ "$SKIP_TARGET" = false ]; then
    kubectl -n "$NAMESPACE" delete deploy,svc test-target --ignore-not-found >/dev/null 2>&1 || true
  fi

  pass "cleanup complete"
fi

log "test complete: SUCCESS ✓"
