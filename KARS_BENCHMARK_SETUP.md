# KARS Benchmark Setup Guide

This document explains how to set up and run the KARS benchmark, including solutions to common issues encountered during setup.

## Prerequisites

1. **KARS Repository**: Clone or symlink the KARS repo
   ```bash
   export KARS_REPO=/path/to/azure/kars
   # OR
   ln -s /path/to/azure/kars kars
   ```

2. **Working Docker Registry Access**: Required to pull base images for building KARS controller and router

3. **Base Cluster**: Run `./proxy/test/harness.sh up` first to create the `playwright-proxy` cluster

## Cross-Compilation Issue on macOS

The KARS controller and router are Rust binaries that must run as Linux ELF binaries inside kind (Kubernetes in Docker). On macOS, this presents a cross-compilation challenge documented as **fix #3** in the implementation.

### Problem

- `cargo build` on macOS produces Mach-O (Darwin) binaries
- These fail with "exec format error" when run in Linux containers
- The existing binaries in `/Users/sanchezg/dev/azure/kars/bin/arm64/` are macOS binaries

### Solutions

#### Option 1: Docker Multi-Stage Build (Recommended)

Use the provided multi-stage Dockerfiles that compile inside a Linux container:

```bash
cd $KARS_REPO
docker build --platform linux/arm64 \
  -t kars-controller:local \
  -f controller/Dockerfile.multistage .

docker build --platform linux/arm64 \
  -t kars-inference-router:local \
  -f inference-router/Dockerfile.multistage .
```

**Requires**: Network access to pull base images (mcr.microsoft.com/azurelinux or docker.io)

#### Option 2: Pre-Built Images (Fast Path)

If you have access to pre-built Linux images (from CI or Azure Container Registry):

```bash
export KARS_CONTROLLER_IMAGE_SRC=karsacr.azurecr.io/kars-controller:latest
export KARS_ROUTER_IMAGE_SRC=karsacr.azurecr.io/kars-inference-router:latest
./proxy/test/harness.sh up-kars
```

The harness will retag and load these images into kind without compilation.

#### Option 3: Install Rust Cross-Compilation Toolchain

Install Rust and add the Linux target:

```bash
# Install Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Add Linux target for ARM64
rustup target add aarch64-unknown-linux-gnu

# Or for x86_64
rustup target add x86_64-unknown-linux-gnu

# Install cross-compilation linker
brew install messense/macos-cross-toolchains/aarch64-unknown-linux-gnu

# Build
cd $KARS_REPO
cargo build --release --target aarch64-unknown-linux-gnu

# Binaries will be in target/aarch64-unknown-linux-gnu/release/
```

#### Option 4: Build on Linux

Run the build on a Linux machine or in CI where native compilation produces Linux binaries directly.

## Network Timeout Issues

If you encounter timeouts pulling images:

```
ERROR: failed to do request: Head "https://registry-1.docker.io/...": dial tcp ...: i/o timeout
ERROR: mcr.microsoft.com/azurelinux/base/core:3.0: not found
```

### Solutions:

1. **Check network connectivity**:
   ```bash
   curl -I https://registry-1.docker.io
   curl -I https://mcr.microsoft.com
   ```

2. **Use alternative base image** (documented in fix #3):
   ```bash
   export KARS_BASE_IMAGE=ubuntu:22.04
   # Then rebuild
   ```

3. **Pre-pull base images** when network is available:
   ```bash
   docker pull mcr.microsoft.com/azurelinux/base/core:3.0
   docker pull mcr.microsoft.com/azurelinux/distroless/base:3.0
   ```

4. **Use cached images**: If you have local images, use them directly

## Running the Benchmark

Once images are built:

```bash
# 1. Ensure base cluster exists
./proxy/test/harness.sh up

# 2. Set up KARS cluster (installs controller, proxy, etc.)
export KARS_REPO=/path/to/azure/kars
export KARS_CONTROLLER_IMAGE_SRC=kars-controller:local
export KARS_ROUTER_IMAGE_SRC=kars-inference-router:local
./proxy/test/harness.sh up-kars

# 3. Run benchmarks
./proxy/test/bench.sh kars

# 4. Cleanup
./proxy/test/harness.sh down-kars
```

## Expected Results

Based on the architecture, KARS benchmarks should show:

- **Cold start**: ~2-4s (namespace creation + pod scheduling + Chromium boot)
  - Slower than agent-sandbox (~600ms with warmpool)
  - Faster than substrate (~3.6s with gVisor + boot-from-spec)
  
- **Warm**: ~60-100ms (similar to other backends once connected)

- **Restore**: ~2-4s (same as cold - no checkpoint/restore like substrate)

**Key difference**: KARS provides namespace-level isolation (stronger than pod-only) but with on-demand provisioning (no warmpool), making it ideal for Azure/AKS environments with InferencePolicy support for AI/GPU workloads.

## Troubleshooting

### "exec format error" in KARS controller pod

```bash
kubectl logs -n kars-system kars-controller-xxx
# Output: exec /usr/local/bin/kars-controller: exec format error
```

**Cause**: macOS binary loaded into Linux container

**Fix**: Use one of the cross-compilation options above

### "cluster 'playwright-proxy' not found"

**Fix**: Run `./proxy/test/harness.sh up` first

### Helm install timeout / CrashLoopBackOff

**Check logs**:
```bash
kubectl get pods -n kars-system
kubectl logs -n kars-system kars-controller-xxx
kubectl describe pod -n kars-system kars-controller-xxx
```

Most common issues:
- Wrong image architecture (see "exec format error" above)
- Missing RBAC permissions
- Network policies blocking controller access

## Infrastructure Requirements Summary

To successfully run KARS benchmarks, you need **one of**:

1. ✅ Network access to Docker registries + Docker multi-stage build
2. ✅ Pre-built Linux KARS images (from ACR or CI)
3. ✅ Rust cross-compilation toolchain installed
4. ✅ Linux machine for native compilation

Without any of these, the benchmark cannot run due to the Linux/macOS binary incompatibility.
