package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// Config is the proxy's runtime configuration, populated from env vars.
// The proxy is deployed per-namespace; Namespace must match the namespace it runs in.
type Config struct {
	// ListenAddr is the bind address for the dataplane HTTP/WS listener.
	ListenAddr string

	// MetricsAddr is the bind address for /metrics and /healthz.
	MetricsAddr string

	// Namespace is the namespace this proxy serves (also where sandbox CRs are created).
	Namespace string

	// LabelKey is the pod label that holds the playwright-id. Defaults to "playwright-id".
	LabelKey string

	// Backend selects the sandbox provisioner: "sandboxclaim" (agent-sandbox / openshell) or "substrate".
	Backend string

	// WarmPoolName is the SandboxWarmPool to claim from. Required for sandboxclaim backend.
	WarmPoolName string

	// TemplateName is the SandboxTemplate name referenced by the SandboxClaim.
	// Defaults to WarmPoolName when unset (matches how the included examples
	// name the template and pool identically).
	TemplateName string

	// SandboxPort is the TCP port on the sandbox pod that serves Playwright (MCP HTTP or WS).
	SandboxPort int

	// SubstrateAPIEndpoint is the host:port of ate-api-server's gRPC service
	// (substrate backend only). Typically "api.ate-system.svc.cluster.local:443".
	SubstrateAPIEndpoint string

	// SubstrateRouterAddr is the host:port of substrate's atenet-router (substrate backend only).
	// Typically "atenet-router.ate-system.svc.cluster.local:80".
	SubstrateRouterAddr string

	// SubstrateActorTemplate is "namespace/name" of an ActorTemplate (substrate backend only).
	SubstrateActorTemplate string

	// SubstrateForceBoot, when true, passes Boot=true to substrate's ResumeActor
	// so it boots from the ActorTemplate spec instead of restoring from a
	// snapshot. Workaround for substrate environments where snapshot restore is
	// unreliable (e.g. when checkpoint pause + restore pause/sub-container
	// leaves the app sub-container in `stopped` state).
	SubstrateForceBoot bool

	// KarsInferenceRef is the name of the InferencePolicy CR in the proxy
	// namespace that each Playwright KarsSandbox references. Required for
	// the karssandbox backend.
	KarsInferenceRef string

	// KarsSandboxImage is the Playwright container image used when creating
	// KarsSandbox CRs. Required for the karssandbox backend.
	KarsSandboxImage string

	// IdleTTL is how long a session must be idle (no traffic AND no open connections) before reaping.
	IdleTTL time.Duration

	// IdleCheckInterval is how often the reaper scans sessions.
	IdleCheckInterval time.Duration

	// EnsureTimeout caps how long a single Ensure call may wait for a sandbox to become ready.
	EnsureTimeout time.Duration
}

func FromEnv() (*Config, error) {
	c := &Config{
		ListenAddr:             envOr("LISTEN_ADDR", ":9000"),
		MetricsAddr:            envOr("METRICS_ADDR", ":9090"),
		Namespace:              os.Getenv("POD_NAMESPACE"),
		LabelKey:               envOr("PLAYWRIGHT_LABEL_KEY", "playwright-id"),
		Backend:                envOr("BACKEND", "sandboxclaim"),
		WarmPoolName:           os.Getenv("WARMPOOL_NAME"),
		TemplateName:           os.Getenv("SANDBOX_TEMPLATE_NAME"),
		SubstrateAPIEndpoint:   envOr("SUBSTRATE_API_ENDPOINT", "api.ate-system.svc.cluster.local:443"),
		SubstrateRouterAddr:    envOr("SUBSTRATE_ROUTER_ADDR", "atenet-router.ate-system.svc.cluster.local:80"),
		SubstrateActorTemplate: os.Getenv("SUBSTRATE_ACTOR_TEMPLATE"),
		SubstrateForceBoot:     envOr("SUBSTRATE_FORCE_BOOT", "") == "true",
		KarsInferenceRef:       os.Getenv("KARS_INFERENCE_REF"),
		KarsSandboxImage:       os.Getenv("KARS_SANDBOX_IMAGE"),
	}

	port, err := strconv.Atoi(envOr("SANDBOX_PORT", "9222"))
	if err != nil {
		return nil, fmt.Errorf("SANDBOX_PORT: %w", err)
	}
	c.SandboxPort = port

	c.IdleTTL, err = time.ParseDuration(envOr("IDLE_TTL", "10m"))
	if err != nil {
		return nil, fmt.Errorf("IDLE_TTL: %w", err)
	}
	c.IdleCheckInterval, err = time.ParseDuration(envOr("IDLE_CHECK_INTERVAL", "30s"))
	if err != nil {
		return nil, fmt.Errorf("IDLE_CHECK_INTERVAL: %w", err)
	}
	c.EnsureTimeout, err = time.ParseDuration(envOr("ENSURE_TIMEOUT", "30s"))
	if err != nil {
		return nil, fmt.Errorf("ENSURE_TIMEOUT: %w", err)
	}

	if c.Namespace == "" {
		return nil, fmt.Errorf("POD_NAMESPACE is required (set via downward API)")
	}
	switch c.Backend {
	case "sandboxclaim":
		if c.WarmPoolName == "" {
			return nil, fmt.Errorf("WARMPOOL_NAME is required for sandboxclaim backend")
		}
		if c.TemplateName == "" {
			c.TemplateName = c.WarmPoolName
		}
	case "substrate":
		if c.SubstrateActorTemplate == "" {
			return nil, fmt.Errorf("SUBSTRATE_ACTOR_TEMPLATE (namespace/name) is required for substrate backend")
		}
		if !strings.Contains(c.SubstrateActorTemplate, "/") {
			return nil, fmt.Errorf("SUBSTRATE_ACTOR_TEMPLATE must be 'namespace/name', got %q", c.SubstrateActorTemplate)
		}
	case "karssandbox":
		if c.KarsInferenceRef == "" {
			return nil, fmt.Errorf("KARS_INFERENCE_REF is required for karssandbox backend")
		}
		if c.KarsSandboxImage == "" {
			return nil, fmt.Errorf("KARS_SANDBOX_IMAGE is required for karssandbox backend")
		}
	default:
		return nil, fmt.Errorf("unknown BACKEND %q (want sandboxclaim, substrate, or karssandbox)", c.Backend)
	}
	return c, nil
}

func envOr(k, dflt string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return dflt
}
