# Playwright Proxy Deployment

This directory contains Kubernetes manifests for deploying the Playwright proxy.

## Prerequisites

- Kubernetes cluster (1.24+)
- `kubectl` configured with cluster access
- GitHub Container Registry access (for CI/CD)

## Quick Start

### 1. Deploy to a namespace

Replace `NAMESPACE` with your target namespace (e.g., `playwright-sandbox`):

```bash
# Apply RBAC first
sed 's/NAMESPACE/playwright-sandbox/g' rbac.yaml | kubectl apply -f -

# Deploy the proxy
sed 's/NAMESPACE/playwright-sandbox/g' proxy.yaml | kubectl apply -f -

# (Optional) Add PodDisruptionBudget for production
sed 's/NAMESPACE/playwright-sandbox/g' pdb.yaml | kubectl apply -f -

# (Optional) Add NetworkPolicy for network segmentation
sed 's/NAMESPACE/playwright-sandbox/g' networkpolicy.yaml | kubectl apply -f -
```

### 2. Verify deployment

```bash
kubectl -n playwright-sandbox get pods -l app.kubernetes.io/name=playwright-proxy
kubectl -n playwright-sandbox logs -l app.kubernetes.io/name=playwright-proxy
```

### 3. Test the proxy

```bash
kubectl -n playwright-sandbox port-forward svc/playwright-proxy 9000:9000

# In another terminal, test the connection
curl http://localhost:9000/healthz
```

## Configuration

The proxy is configured via environment variables in `proxy.yaml`:

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKEND` | `sandboxclaim` | Backend type: `sandboxclaim` or `substrate` |
| `WARMPOOL_NAME` | `playwright` | SandboxWarmPool name (agent-sandbox) |
| `SANDBOX_TEMPLATE_NAME` | (from WARMPOOL_NAME) | Override sandbox template |
| `SANDBOX_PORT` | `9222` | Port exposed by sandbox containers |
| `IDLE_TTL` | `10m` | How long to keep idle sandboxes alive |
| `IDLE_CHECK_INTERVAL` | `30s` | How often to check for idle sandboxes |
| `ENSURE_TIMEOUT` | `30s` | Timeout for sandbox creation |

For substrate backend, also configure:
- `SUBSTRATE_ROUTER_ADDR`: Substrate router address
- `SUBSTRATE_ACTOR_TEMPLATE`: Actor template name

## Security Features

The deployment includes several security best practices:

### Dockerfile
- Multi-stage build with minimal runtime image (distroless)
- Non-root user (UID 65532)
- Static binary compilation (no dynamic dependencies)
- Build-time dependency verification
- Multi-architecture support (amd64/arm64)

### Pod Security
- Read-only root filesystem
- No privilege escalation
- All capabilities dropped
- Runs as non-root user (65532)
- Seccomp profile (RuntimeDefault)
- Resource limits enforced

### RBAC
- Minimal permissions (namespace-scoped Role)
- Service account with least privilege
- Only required API access granted

### Network Security (optional)
- NetworkPolicy restricts ingress/egress
- DNS and API server access allowed
- Pod-to-pod communication controlled

### High Availability (optional)
- PodDisruptionBudget ensures availability during disruptions
- RollingUpdate strategy (zero-downtime deployments)

## CI/CD Setup

### GitHub Actions

The repository includes a GitHub Actions workflow that automatically builds and pushes images to GitHub Container Registry (ghcr.io).

#### Required Secrets

**No additional secrets required!** The workflow uses `GITHUB_TOKEN` which is automatically available with permissions to push to GitHub Container Registry.

#### First-time Setup

After your first successful build, make the package public (optional):
1. Go to: `https://github.com/users/YOUR_USERNAME/packages/container/playwright-k8s-sandbox`
2. Click "Package settings"
3. Scroll to "Danger Zone" → "Change visibility" → "Public"

#### Trigger Conditions

The workflow runs on:
- Push to `main` branch (with changes to source code)
- Pull requests to `main` branch
- Release publication
- Manual trigger (workflow_dispatch)

#### Image Tags

Images are tagged as:
- `latest` - Latest build from main branch
- `main-<sha>` - Commit-based tags
- `pr-<number>` - Pull request builds
- `v1.2.3`, `v1.2`, `v1` - Semantic version tags (on releases)

### Manual Build

To build and push manually:

```bash
# Build the image
docker build -t ghcr.io/carlossg/playwright-k8s-sandbox:latest .

# Log in to GitHub Container Registry
echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin

# Push the image
docker push ghcr.io/carlossg/playwright-k8s-sandbox:latest
```

## Monitoring

The proxy exposes metrics and health endpoints on port 9090:

- `/healthz` - Liveness check
- `/readyz` - Readiness check

Add Prometheus scraping if needed:

```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "9090"
  prometheus.io/path: "/metrics"
```

## Troubleshooting

### Proxy pod not starting

```bash
kubectl -n playwright-sandbox describe pod -l app.kubernetes.io/name=playwright-proxy
kubectl -n playwright-sandbox logs -l app.kubernetes.io/name=playwright-proxy
```

### RBAC permission errors

Verify the service account has proper permissions:

```bash
kubectl -n playwright-sandbox get role playwright-proxy -o yaml
kubectl -n playwright-sandbox get rolebinding playwright-proxy -o yaml
```

### Connection issues

Check if the service is properly configured:

```bash
kubectl -n playwright-sandbox get svc playwright-proxy
kubectl -n playwright-sandbox get endpoints playwright-proxy
```

### NetworkPolicy blocking traffic

If you applied the NetworkPolicy and traffic is blocked:

```bash
# Temporarily remove to test
kubectl -n playwright-sandbox delete networkpolicy playwright-proxy

# Review and adjust the policy based on your pod labels
kubectl -n playwright-sandbox get pods --show-labels
```

## Production Considerations

1. **Multi-replica deployment**: Increase `replicas` in `proxy.yaml` for HA
2. **Resource tuning**: Adjust CPU/memory based on load
3. **Monitoring**: Add metrics collection and alerting
4. **Backup**: Ensure RBAC and config are version-controlled
5. **Image updates**: Pin specific image tags instead of `latest`
6. **Network policies**: Customize based on your cluster's network model
7. **Pod security standards**: Apply appropriate PSS labels to namespace

## License

See [LICENSE](../LICENSE) file in the repository root.
