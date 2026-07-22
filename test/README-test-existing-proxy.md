# Testing an Existing Playwright Proxy

The `test-existing-proxy.sh` script tests a playwright-proxy service that's already running in your cluster, without requiring a full harness setup.

## Quick Start

```bash
# Test proxy in the current namespace
./test/test-existing-proxy.sh

# Test isola backend in specific namespace
./test/test-existing-proxy.sh -n pw-isola -b isola

# Test with cleanup afterward
./test/test-existing-proxy.sh -n my-namespace --cleanup
```

## What It Tests

The script validates:

1. **WebSocket Path** (`ws://playwright-proxy:9000/`)
   - Connects Playwright client via WebSocket
   - Launches Chromium browser in sandbox
   - Navigates to test page
   - Verifies successful page load

2. **Sandbox Creation**
   - Confirms sandbox/claim resources created
   - Verifies correct backend-specific resources (SandboxClaim, Sandbox CR, KarsSandbox, Actor)

3. **Isolation**
   - Tests multiple clients with distinct `playwright-id` labels
   - Verifies each gets its own sandbox
   - Checks distinct pod IPs/namespaces/sandbox names

4. **MCP/SSE Path** (placeholder)
   - Same routing logic as WebSocket
   - Separate MCP client test not yet implemented

## Options

```
-n, --namespace NAMESPACE    Namespace where playwright-proxy is running
-s, --service SERVICE        Service name (default: "playwright-proxy")
-p, --port PORT              Service port (default: 9000)
-b, --backend BACKEND        Backend type: isola, kars, agent-sandbox, substrate
                             (default: auto-detect from deployment)
-c, --client-ids IDS         Comma-separated client IDs (default: "alpha,beta")
--ws-only                    Test WebSocket path only
--mcp-only                   Test MCP/SSE path only (not yet implemented)
--skip-target                Don't deploy test-target
--cleanup                    Clean up test resources after completion
-h, --help                   Show help
```

## Prerequisites

- `kubectl` configured with cluster access
- playwright-proxy service running
- Backend (isola/kars/agent-sandbox/substrate) installed and configured
- RBAC permissions to create Jobs and read backend resources

## Examples

### Test Isola Backend

```bash
# Assumes proxy is in pw-isola namespace
./test/test-existing-proxy.sh -n pw-isola -b isola

# With cleanup
./test/test-existing-proxy.sh -n pw-isola -b isola --cleanup
```

### Test KARS Backend

```bash
./test/test-existing-proxy.sh -n pw-kars -b kars
```

### Test with Custom Clients

```bash
# Test with 3 clients
./test/test-existing-proxy.sh -n my-ns -c "client1,client2,client3"
```

### Test Only WebSocket

```bash
./test/test-existing-proxy.sh -n my-ns --ws-only
```

## What Gets Created

The script creates:

1. **test-target** Deployment + Service (unless `--skip-target`)
   - `traefik/whoami` pod for browser to fetch
   - ClusterIP service at `http://test-target/`

2. **playwright-scripts** ConfigMap
   - Contains `client.js` for Playwright client

3. **playwright-test-{id}** Jobs (one per client ID)
   - Labeled pods with `playwright-id: {id}`
   - Runs Playwright client connecting to proxy
   - Navigates browser to test-target

4. **Backend Resources** (created by proxy)
   - **agent-sandbox**: `SandboxClaim` resources
   - **isola**: `Sandbox` CRs in isola-sandboxes namespace
   - **kars**: `KarsSandbox` + per-client namespace
   - **substrate**: `Actor` resources

## Output

The script shows:

- ✓ Green checkmarks for successful steps
- Blue arrows for progress
- Timing data from each client (connect, page load times)
- Pod IPs / sandbox names for isolation verification
- Logs from failed jobs (if any)

Example output:

```
==> testing playwright-proxy: playwright-proxy:9000 in namespace pw-isola
==> backend: isola
==> client IDs: alpha,beta
==> deploying test-target (traefik/whoami)
✓ test-target ready
==> deploying playwright-scripts ConfigMap
==> testing WebSocket path
    deploying client: alpha
    deploying client: beta
==> waiting for client: alpha
✓ client alpha completed
    timing: {"id":"alpha","connect_ms":1234,"newPage_ms":56,"goto_ms":789,"total_ms":2079,"hostname":"test-target-abc123"}
✓ Sandbox pw-alpha exists (podIP: 10.244.1.5)
==> waiting for client: beta
✓ client beta completed
    timing: {"id":"beta","connect_ms":987,"newPage_ms":45,"goto_ms":678,"total_ms":1710,"hostname":"test-target-abc123"}
✓ Sandbox pw-beta exists (podIP: 10.244.1.6)
==> verifying sandbox isolation
✓ distinct pod IPs: alpha→10.244.1.5, beta→10.244.1.6
==> WebSocket path: PASSED ✓
==> test complete: SUCCESS ✓
```

## Cleanup

Manual cleanup:

```bash
# Delete test jobs
kubectl -n <namespace> delete job -l app.kubernetes.io/name=playwright-e2e-client

# Delete backend resources
kubectl -n <namespace> delete sandboxclaim --all  # agent-sandbox
kubectl -n isola-sandboxes delete sandbox --all    # isola
kubectl delete ns pw-alpha pw-beta                 # kars
kubectl -n <namespace> delete actor --all          # substrate

# Delete test target
kubectl -n <namespace> delete deploy,svc test-target
```

Or use the `--cleanup` flag for automatic cleanup.

## Differences from harness.sh

| Feature | harness.sh | test-existing-proxy.sh |
|---------|-----------|------------------------|
| Cluster setup | ✓ Creates kind cluster | ✗ Assumes existing cluster |
| Backend install | ✓ Installs controllers | ✗ Assumes installed |
| Image build | ✓ Builds proxy image | ✗ Uses running proxy |
| Proxy deploy | ✓ Deploys proxy | ✗ Tests existing proxy |
| E2E test | ✓ Full e2e | ✓ Client-side test |
| Use case | Development/CI | Production validation |

## Troubleshooting

### Job fails with "connection refused"

Check proxy is running:
```bash
kubectl -n <namespace> get pod -l app.kubernetes.io/name=playwright-proxy
kubectl -n <namespace> logs -l app.kubernetes.io/name=playwright-proxy
```

### Job fails with "403 Forbidden"

Pod informer may not have synced yet. The client retries for 15s. If it still fails:
```bash
# Check proxy can see pods
kubectl -n <namespace> logs -l app.kubernetes.io/name=playwright-proxy | grep "pod added"
```

### Sandbox not created

Check proxy logs for backend errors:
```bash
kubectl -n <namespace> logs -l app.kubernetes.io/name=playwright-proxy --tail=50
```

For isola:
```bash
kubectl -n isola-system logs -l app.kubernetes.io/component=operator --tail=50
```

### Image pull failures

The script uses `mcr.microsoft.com/playwright:v1.49.0-noble` by default. Override:
```bash
PLAYWRIGHT_IMAGE=your/image:tag ./test/test-existing-proxy.sh -n <namespace>
```

For kind clusters with local registry:
```bash
PLAYWRIGHT_IMAGE=localhost:5001/playwright:slim ./test/test-existing-proxy.sh -n <namespace>
```
