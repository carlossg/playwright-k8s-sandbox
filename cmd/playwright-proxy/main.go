package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"

	"github.com/carlossg/playwright-k8s-sandbox/internal/backend"
	"github.com/carlossg/playwright-k8s-sandbox/internal/config"
	"github.com/carlossg/playwright-k8s-sandbox/internal/identify"
	"github.com/carlossg/playwright-k8s-sandbox/internal/proxy"
	"github.com/carlossg/playwright-k8s-sandbox/internal/session"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(log)

	if err := run(log); err != nil {
		log.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	cfg, err := config.FromEnv()
	if err != nil {
		return fmt.Errorf("config: %w", err)
	}
	log.Info("starting",
		"namespace", cfg.Namespace,
		"backend", cfg.Backend,
		"warmpool", cfg.WarmPoolName,
		"listen", cfg.ListenAddr,
		"idle_ttl", cfg.IdleTTL,
	)

	rc, err := rest.InClusterConfig()
	if err != nil {
		return fmt.Errorf("in-cluster config (run inside a pod): %w", err)
	}
	clientset, err := kubernetes.NewForConfig(rc)
	if err != nil {
		return fmt.Errorf("kubernetes client: %w", err)
	}
	dyn, err := dynamic.NewForConfig(rc)
	if err != nil {
		return fmt.Errorf("dynamic client: %w", err)
	}

	var bk backend.Backend
	switch cfg.Backend {
	case "sandboxclaim":
		bk = backend.NewSandboxClaim(dyn, cfg.Namespace, cfg.TemplateName, cfg.WarmPoolName, cfg.SandboxPort)
	case "substrate":
		bk, err = backend.NewSubstrateWithOptions(cfg.SubstrateAPIEndpoint, cfg.SubstrateRouterAddr, cfg.SubstrateActorTemplate, cfg.SubstrateForceBoot)
		if err != nil {
			return err
		}
	case "karssandbox":
		bk = backend.NewKarsSandbox(dyn, clientset, cfg.Namespace, cfg.KarsInferenceRef, cfg.KarsSandboxImage, cfg.SandboxPort)
	default:
		return fmt.Errorf("unknown backend %q", cfg.Backend)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	idx := identify.New(cfg.LabelKey, clientset, cfg.Namespace)
	go func() {
		if err := idx.Run(ctx); err != nil && ctx.Err() == nil {
			log.Error("pod informer stopped", "err", err)
			cancel()
		}
	}()

	sm := session.New(bk, cfg.EnsureTimeout, cfg.IdleTTL, log)

	// Best-effort reconcile on startup; failures here aren't fatal.
	rctx, rcancel := context.WithTimeout(ctx, 10*time.Second)
	if err := sm.Reconcile(rctx); err != nil {
		log.Warn("reconcile on startup failed", "err", err)
	}
	rcancel()

	go sm.ReapLoop(ctx, cfg.IdleCheckInterval)

	dataHandler := proxy.New(sm, idx, cfg.Backend, log)
	dataSrv := &http.Server{
		Addr:    cfg.ListenAddr,
		Handler: dataHandler,
		// No read/write timeouts on the dataplane: WS connections are long-lived.
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok")) })
	// /readyz returns 200 only once the pod informer has finished its initial
	// LIST. Until then, kube-proxy must keep this pod out of the Service
	// endpoints (avoids the startup race where the proxy 403s legitimate
	// clients while the cache is still warming).
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, _ *http.Request) {
		if !idx.Ready() {
			w.WriteHeader(http.StatusServiceUnavailable)
			w.Write([]byte("informer cache not synced"))
			return
		}
		w.Write([]byte("ok"))
	})
	mgmtSrv := &http.Server{
		Addr:         cfg.MetricsAddr,
		Handler:      mux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 5 * time.Second,
	}

	go func() {
		log.Info("data listener up", "addr", cfg.ListenAddr)
		if err := dataSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Error("data server", "err", err)
			cancel()
		}
	}()
	go func() {
		log.Info("mgmt listener up", "addr", cfg.MetricsAddr)
		if err := mgmtSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Error("mgmt server", "err", err)
		}
	}()

	<-ctx.Done()
	log.Info("shutting down")
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer shutdownCancel()
	_ = dataSrv.Shutdown(shutdownCtx)
	_ = mgmtSrv.Shutdown(shutdownCtx)
	return nil
}
