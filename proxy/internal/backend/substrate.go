// Substrate backend: talks to substrate's Control gRPC service on
// ate-api-server to manage actor lifecycles. Data-plane traffic still flows
// through this proxy — we just rewrite the Host header to
// `<actor-id>.actors.resources.substrate.ate.dev` and forward to atenet-router,
// which substrate already runs as a multiplexing data plane.
//
// One actor per playwright-id. Ensure is idempotent: GetActor first, CreateActor
// on NotFound. Delete suspends then deletes (substrate only deletes suspended
// actors).
package backend

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/status"

	"github.com/carlossg/playwright-k8s-sandbox/proxy/internal/backend/ateapipb"
)

// readyPollInterval is how often Ensure polls GetActor while waiting for the
// actor to reach STATUS_RUNNING. readyDeadline is the per-request budget — if
// the actor isn't running by then, return the atenet endpoint anyway and let
// downstream decide (atenet will queue the WS upgrade or refuse).
const (
	readyPollInterval = 200 * time.Millisecond
	readyDeadline     = 60 * time.Second
	// upstreamReadyDeadline bounds the post-RUNNING probe to atenet — Substrate
	// reports STATUS_RUNNING as soon as `runsc restore` exits, but with
	// -direct/-background lazy paging the in-sandbox Chromium can still be
	// finishing its boot, so atenet returns 503 (upstream connection refused)
	// for a few seconds. We probe until the upstream stops failing so the
	// caller's WS upgrade isn't forwarded to a refusing socket.
	upstreamReadyDeadline = 30 * time.Second
	upstreamProbeInterval = 200 * time.Millisecond
)

// SubstrateActorHost is the Host header suffix substrate's atenet-router uses
// to dispatch traffic to a named actor. See substrate counter demo:
//
//	curl -H "Host: my-counter-1.actors.resources.substrate.ate.dev" http://atenet-router/
const SubstrateActorHost = "actors.resources.substrate.ate.dev"

type Substrate struct {
	control           ateapipb.ControlClient
	conn              *grpc.ClientConn
	actorTemplateNS   string
	actorTemplateName string
	atenetRouterHost  string
	atenetRouterPort  int
	probeClient       *http.Client
}

// NewSubstrate dials the ate-api-server's gRPC endpoint and returns a backend
// that creates one actor per playwright-id. apiEndpoint is "host:port"; the
// proxy is expected to talk to ate-api-server via TLS but the certs are
// self-signed inside the cluster, hence InsecureSkipVerify (consistent with
// kubectl-ate's behavior).
func NewSubstrate(apiEndpoint, atenetRouterAddr, actorTemplateRef string) (*Substrate, error) {
	if apiEndpoint == "" {
		return nil, fmt.Errorf("apiEndpoint required")
	}
	host, portStr, ok := strings.Cut(atenetRouterAddr, ":")
	if !ok {
		return nil, fmt.Errorf("atenetRouterAddr must be host:port, got %q", atenetRouterAddr)
	}
	port, err := strconv.Atoi(portStr)
	if err != nil {
		return nil, fmt.Errorf("atenetRouterAddr port: %w", err)
	}
	tns, tname, ok := strings.Cut(actorTemplateRef, "/")
	if !ok {
		return nil, fmt.Errorf("actorTemplateRef must be 'namespace/name', got %q", actorTemplateRef)
	}

	creds := credentials.NewTLS(&tls.Config{InsecureSkipVerify: true})
	conn, err := grpc.NewClient(apiEndpoint, grpc.WithTransportCredentials(creds))
	if err != nil {
		return nil, fmt.Errorf("dial ate-api-server: %w", err)
	}
	return &Substrate{
		control:           ateapipb.NewControlClient(conn),
		conn:              conn,
		actorTemplateNS:   tns,
		actorTemplateName: tname,
		atenetRouterHost:  host,
		atenetRouterPort:  port,
		probeClient: &http.Client{
			Timeout: 2 * time.Second,
			Transport: &http.Transport{
				DialContext: (&net.Dialer{Timeout: 1 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
				// Probe is a short HEAD — no pooling benefits, but disable
				// long-lived idle connections to atenet just to keep probe
				// traffic ephemeral.
				DisableKeepAlives: true,
			},
		},
	}, nil
}

// Close releases the gRPC connection.
func (s *Substrate) Close() { _ = s.conn.Close() }

func actorID(playwrightID string) string { return "pw-" + playwrightID }

func (s *Substrate) Ensure(ctx context.Context, playwrightID string) (Endpoint, error) {
	id := actorID(playwrightID)

	actor, err := s.getOrCreate(ctx, id)
	if err != nil {
		return Endpoint{}, err
	}

	// Drive to STATUS_RUNNING before returning the atenet endpoint. Without
	// this, the proxy would forward the client's WS upgrade to atenet-router
	// for an actor that's still RESUMING from snapshot, and atenet would close
	// the upgrade (the client sees a spurious 403/connection drop). Hold the
	// request here instead so the client only sees latency.
	if _, err := s.waitForRunning(ctx, id, actor); err != nil {
		return Endpoint{}, err
	}

	// STATUS_RUNNING is necessary but not sufficient: with -direct/-background
	// runsc restore returns before the in-sandbox process is actually serving on
	// port 80. Probe via atenet so we only hand the WS upgrade off after the
	// upstream is reachable.
	if err := s.waitUpstreamReady(ctx, id); err != nil {
		return Endpoint{}, err
	}

	// Substrate's atenet-router is the per-request data plane; the proxy hands
	// traffic to it with Host: <id>.actors.resources.substrate.ate.dev.
	return Endpoint{Host: s.atenetRouterHost, Port: s.atenetRouterPort}, nil
}

// waitUpstreamReady polls atenet-router until the upstream stops failing.
// atenet returns 503 with "remote connection failure" while the actor's
// Chromium hasn't bound to port 80 yet; anything else (200, 404, 405, even
// 500) indicates the request reached the actor process and substrate's data
// plane is wired up, so we let the caller's real request through.
func (s *Substrate) waitUpstreamReady(ctx context.Context, id string) error {
	start := time.Now()
	deadline := start.Add(upstreamReadyDeadline)
	url := fmt.Sprintf("http://%s:%d/", s.atenetRouterHost, s.atenetRouterPort)
	host := fmt.Sprintf("%s.%s", id, SubstrateActorHost)
	attempt := 0
	for {
		attempt++
		probeCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
		req, err := http.NewRequestWithContext(probeCtx, http.MethodHead, url, nil)
		if err != nil {
			cancel()
			return fmt.Errorf("build probe req: %w", err)
		}
		req.Host = host
		resp, err := s.probeClient.Do(req)
		cancel()
		if err == nil {
			code := resp.StatusCode
			resp.Body.Close()
			if code != http.StatusServiceUnavailable {
				slog.Info("substrate: upstream ready",
					"id", id, "attempt", attempt,
					"elapsed", time.Since(start).String(), "code", code)
				return nil
			}
		}
		if time.Now().After(deadline) {
			slog.Warn("substrate: upstream probe deadline; proceeding anyway",
				"id", id, "deadline", upstreamReadyDeadline, "attempts", attempt)
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(upstreamProbeInterval):
		}
	}
}

// getOrCreate returns the current Actor or creates a fresh one on NotFound.
// Handles the race where a concurrent caller created the actor between our
// GetActor and CreateActor.
func (s *Substrate) getOrCreate(ctx context.Context, id string) (*ateapipb.Actor, error) {
	if resp, err := s.control.GetActor(ctx, &ateapipb.GetActorRequest{ActorId: id}); err == nil {
		return resp.GetActor(), nil
	} else if st, _ := status.FromError(err); st.Code() != codes.NotFound {
		return nil, fmt.Errorf("GetActor %s: %w", id, err)
	}
	cResp, err := s.control.CreateActor(ctx, &ateapipb.CreateActorRequest{
		ActorId:                id,
		ActorTemplateNamespace: s.actorTemplateNS,
		ActorTemplateName:      s.actorTemplateName,
	})
	if err == nil {
		return cResp.GetActor(), nil
	}
	if st, _ := status.FromError(err); st.Code() == codes.AlreadyExists {
		// Another caller beat us to CreateActor; re-fetch the actor.
		resp, err := s.control.GetActor(ctx, &ateapipb.GetActorRequest{ActorId: id})
		if err != nil {
			return nil, fmt.Errorf("re-GetActor %s after AlreadyExists: %w", id, err)
		}
		return resp.GetActor(), nil
	}
	return nil, fmt.Errorf("CreateActor %s: %w", id, err)
}

// waitForRunning polls until the actor is STATUS_RUNNING. If the actor is
// SUSPENDED, we kick it via ResumeActor first. Returns the last observed
// Actor on success; on deadline, returns the last observed actor and an error
// so callers can decide whether to proceed (atenet may still queue traffic).
func (s *Substrate) waitForRunning(ctx context.Context, id string, actor *ateapipb.Actor) (*ateapipb.Actor, error) {
	deadline := time.Now().Add(readyDeadline)
	resumed := false
	for {
		switch actor.GetStatus() {
		case ateapipb.Actor_STATUS_RUNNING:
			return actor, nil
		case ateapipb.Actor_STATUS_SUSPENDED:
			if !resumed {
				if _, err := s.control.ResumeActor(ctx, &ateapipb.ResumeActorRequest{ActorId: id}); err != nil {
					st, _ := status.FromError(err)
					// FailedPrecondition can happen if the actor just left
					// SUSPENDED between our Get and Resume — fall through and
					// re-poll status.
					if st.Code() != codes.FailedPrecondition {
						return actor, fmt.Errorf("ResumeActor %s: %w", id, err)
					}
				}
				resumed = true
				slog.Info("substrate: resumed actor", "id", id)
			}
		case ateapipb.Actor_STATUS_RESUMING, ateapipb.Actor_STATUS_SUSPENDING, ateapipb.Actor_STATUS_UNSPECIFIED:
			// fall through to poll
		}
		if time.Now().After(deadline) {
			return actor, fmt.Errorf("actor %s did not reach STATUS_RUNNING within %s (last=%s)",
				id, readyDeadline, actor.GetStatus())
		}
		time.Sleep(readyPollInterval)
		resp, err := s.control.GetActor(ctx, &ateapipb.GetActorRequest{ActorId: id})
		if err != nil {
			return actor, fmt.Errorf("GetActor %s during wait: %w", id, err)
		}
		actor = resp.GetActor()
	}
}

func (s *Substrate) Delete(ctx context.Context, playwrightID string) error {
	id := actorID(playwrightID)
	// Substrate only deletes suspended actors. Suspend first; ignore the error
	// if it's already suspended.
	if _, err := s.control.SuspendActor(ctx, &ateapipb.SuspendActorRequest{ActorId: id}); err != nil {
		st, _ := status.FromError(err)
		if st.Code() != codes.NotFound && st.Code() != codes.FailedPrecondition {
			return fmt.Errorf("SuspendActor %s: %w", id, err)
		}
	}
	if _, err := s.control.DeleteActor(ctx, &ateapipb.DeleteActorRequest{ActorId: id}); err != nil {
		st, _ := status.FromError(err)
		if st.Code() != codes.NotFound {
			return fmt.Errorf("DeleteActor %s: %w", id, err)
		}
	}
	return nil
}

func (s *Substrate) List(ctx context.Context) ([]string, error) {
	var ids []string
	pageToken := ""
	for {
		resp, err := s.control.ListActors(ctx, &ateapipb.ListActorsRequest{
			PageSize:  500,
			PageToken: pageToken,
		})
		if err != nil {
			return nil, fmt.Errorf("ListActors: %w", err)
		}
		for _, a := range resp.GetActors() {
			id := a.GetActorId()
			if pid, ok := strings.CutPrefix(id, "pw-"); ok {
				ids = append(ids, pid)
			}
		}
		if resp.GetNextPageToken() == "" {
			break
		}
		pageToken = resp.GetNextPageToken()
	}
	return ids, nil
}

// IsConflict is a small helper for callers that want to distinguish "already
// present" from real failures.
func IsConflict(err error) bool {
	if err == nil {
		return false
	}
	if st, ok := status.FromError(err); ok {
		return st.Code() == codes.AlreadyExists
	}
	return errors.Is(err, errors.New("already exists"))
}
