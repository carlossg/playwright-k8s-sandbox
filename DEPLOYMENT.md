# Deployment Guide

This repository includes production-ready deployment configurations for the Playwright Kubernetes sandbox proxy.

## Quick Links

- **Deployment Documentation**: [deploy/README.md](deploy/README.md)
- **Docker Image**: `docker.io/csanchez/playwright-k8s-sandbox`
- **CI/CD Workflow**: [.github/workflows/docker-build.yml](.github/workflows/docker-build.yml)

## Setup GitHub Actions

Before the automated builds work, add these secrets to your GitHub repository:

1. Go to: `Settings` → `Secrets and variables` → `Actions` → `New repository secret`

2. Add two secrets:
   - **Name**: `DOCKERHUB_USERNAME`  
     **Value**: Your Docker Hub username (e.g., `csanchez`)
   
   - **Name**: `DOCKERHUB_TOKEN`  
     **Value**: Your Docker Hub access token
     - Create at: https://hub.docker.com/settings/security
     - Select: "New Access Token"
     - Permissions: "Read, Write, Delete"

## Deploy to Kubernetes

```bash
# Set your namespace
NAMESPACE="playwright-sandbox"

# Apply all manifests
cd deploy
for file in rbac.yaml proxy.yaml pdb.yaml networkpolicy.yaml; do
  sed "s/NAMESPACE/$NAMESPACE/g" "$file" | kubectl apply -f -
done

# Verify deployment
kubectl -n $NAMESPACE get pods -l app.kubernetes.io/name=playwright-proxy
kubectl -n $NAMESPACE logs -l app.kubernetes.io/name=playwright-proxy
```

## Architecture

```
┌─────────────────────────────────────────┐
│         GitHub Actions (CI/CD)          │
│  - Build on push to main                │
│  - Multi-arch (amd64/arm64)            │
│  - Push to Docker Hub                   │
└─────────────────┬───────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────┐
│         Docker Hub Registry             │
│  csanchez/playwright-k8s-sandbox       │
│  - latest, main-<sha>, v*.*.* tags     │
└─────────────────┬───────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────┐
│      Kubernetes Cluster                 │
│                                         │
│  ┌───────────────────────────────────┐ │
│  │  playwright-proxy Deployment      │ │
│  │  - Distroless image (non-root)    │ │
│  │  - Seccomp + restricted caps      │ │
│  │  - Read-only filesystem           │ │
│  │  - Resource limits                │ │
│  └───────────────────────────────────┘ │
│                                         │
│  ┌───────────────────────────────────┐ │
│  │  Service (ClusterIP)              │ │
│  │  - Port 9000 (data plane)         │ │
│  │  - Port 9090 (management)         │ │
│  └───────────────────────────────────┘ │
│                                         │
│  ┌───────────────────────────────────┐ │
│  │  NetworkPolicy (optional)         │ │
│  │  - Restrict traffic               │ │
│  └───────────────────────────────────┘ │
└─────────────────────────────────────────┘
```

## Security Highlights

✅ **Container Security**
- Distroless base image (no shell, no package manager)
- Non-root user (UID/GID 65532)
- Read-only root filesystem
- All Linux capabilities dropped
- No privilege escalation allowed

✅ **Kubernetes Security**
- Pod Security Standards compliant
- Seccomp profile (RuntimeDefault)
- Resource limits enforced
- Minimal RBAC permissions (namespace-scoped)
- Service account token auto-mounted only when needed

✅ **Network Security**
- Optional NetworkPolicy for traffic segmentation
- Controlled ingress/egress rules
- DNS and API server access only

✅ **Build Security**
- Multi-stage builds (minimal runtime)
- Dependency verification
- Static binary compilation
- Supply chain attestation
- GitHub Actions artifact signing

## Monitoring

Health endpoints exposed on port 9090:

- `GET /healthz` - Liveness probe
- `GET /readyz` - Readiness probe

Example port-forward for debugging:

```bash
kubectl -n $NAMESPACE port-forward svc/playwright-proxy 9090:9090
curl http://localhost:9090/healthz
```

## Troubleshooting

### Build Failures

Check GitHub Actions:
- Go to `Actions` tab in GitHub
- Click on the failed workflow run
- Review build logs

Common issues:
- Missing Docker Hub credentials
- Incorrect secret names
- Network issues during build

### Deployment Issues

```bash
# Check pod status
kubectl -n $NAMESPACE describe pod -l app.kubernetes.io/name=playwright-proxy

# Check logs
kubectl -n $NAMESPACE logs -l app.kubernetes.io/name=playwright-proxy --tail=100

# Check RBAC
kubectl -n $NAMESPACE auth can-i create sandboxclaims \
  --as=system:serviceaccount:$NAMESPACE:playwright-proxy
```

### Network Policy Issues

If NetworkPolicy blocks legitimate traffic:

```bash
# Temporarily remove
kubectl -n $NAMESPACE delete networkpolicy playwright-proxy

# Test connectivity
kubectl -n $NAMESPACE exec -it <pod-name> -- /bin/sh  # (won't work with distroless)

# Review and adjust policy based on actual pod labels
kubectl -n $NAMESPACE get pods --show-labels
```

## Production Checklist

- [ ] GitHub secrets configured (DOCKERHUB_USERNAME, DOCKERHUB_TOKEN)
- [ ] First successful build and push to Docker Hub
- [ ] Image pulled successfully in cluster
- [ ] RBAC applied and verified
- [ ] Deployment running with proper security contexts
- [ ] Health checks passing
- [ ] Service accessible from sandbox pods
- [ ] (Optional) NetworkPolicy tested and adjusted
- [ ] (Optional) PodDisruptionBudget configured for HA
- [ ] Resource limits tuned based on load testing
- [ ] Monitoring/alerting configured
- [ ] Backup of all manifests in version control

## Contributing

When making changes to the proxy:

1. Changes to `cmd/**`, `internal/**`, `go.mod`, `go.sum`, or `Dockerfile` automatically trigger builds
2. PRs build but don't push to Docker Hub
3. Merges to `main` push with `latest` and `main-<sha>` tags
4. GitHub releases create semantic version tags (`v1.2.3`)

## License

See [LICENSE](LICENSE) file.
