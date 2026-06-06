// Package proxy is the HTTP/WebSocket reverse proxy. The hot path:
//
//  1. Extract the client pod IP from the connection.
//  2. Look up the playwright-id in the informer-backed index.
//  3. Get-or-create the session for that id (singleflight via session.Manager).
//  4. Route the request to the session's Endpoint, copying bytes both ways and
//     bumping the session's lastActive on every request / open connection.
//
// HTTP and WS share the same handler. WS is detected by the Upgrade header.
package proxy

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
	"time"

	"github.com/carlossg/playwright-k8s-sandbox/proxy/internal/backend"
	"github.com/carlossg/playwright-k8s-sandbox/proxy/internal/identify"
	"github.com/carlossg/playwright-k8s-sandbox/proxy/internal/session"
)

type Handler struct {
	Sessions  *session.Manager
	Identify  *identify.Index
	GetCtx    func(*http.Request) (context.Context, context.CancelFunc)
	Log       *slog.Logger
	Backend   string // "sandboxclaim" or "substrate"; controls actor-header injection
	httpProxy *httputil.ReverseProxy
}

func New(sessions *session.Manager, idx *identify.Index, backendKind string, log *slog.Logger) *Handler {
	h := &Handler{
		Sessions: sessions,
		Identify: idx,
		Log:      log,
		Backend:  backendKind,
	}
	h.httpProxy = &httputil.ReverseProxy{
		Director:     func(*http.Request) {}, // we rewrite in ServeHTTP before calling
		ErrorHandler: h.proxyError,
		FlushInterval: -1, // immediate flush for streaming / SSE / MCP
	}
	return h
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	clientIP, err := clientIPFromReq(r)
	if err != nil {
		http.Error(w, "cannot determine client IP", http.StatusBadRequest)
		return
	}

	id, ok := h.Identify.Lookup(clientIP)
	if !ok {
		h.Log.Warn("unknown client", "ip", clientIP, "path", r.URL.Path)
		http.Error(w, fmt.Sprintf("client pod %s not labelled with playwright-id", clientIP), http.StatusForbidden)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()
	sess, err := h.Sessions.Get(ctx, id)
	if err != nil {
		h.Log.Error("session get failed", "id", id, "err", err)
		http.Error(w, fmt.Sprintf("session unavailable: %v", err), http.StatusBadGateway)
		return
	}

	sess.MarkActive()

	if isWebsocketUpgrade(r) {
		h.handleWS(w, r, sess)
		return
	}
	h.handleHTTP(w, r, sess)
}

func (h *Handler) handleHTTP(w http.ResponseWriter, r *http.Request, sess *session.Session) {
	// Rewrite the request to point at the sandbox endpoint.
	target := &url.URL{Scheme: "http", Host: sess.Endpoint.Addr()}
	r2 := r.Clone(r.Context())
	r2.URL.Scheme = target.Scheme
	r2.URL.Host = target.Host
	r2.Host = substrateHostOrDefault(h.Backend, sess.ID, target.Host)
	r2.RequestURI = ""
	h.httpProxy.ServeHTTP(w, r2)
	sess.MarkActive()
}

func (h *Handler) handleWS(w http.ResponseWriter, r *http.Request, sess *session.Session) {
	// Hijack the client connection.
	hj, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "server does not support hijacking", http.StatusInternalServerError)
		return
	}

	// Dial the backend.
	dialer := &net.Dialer{Timeout: 10 * time.Second}
	backendConn, err := dialer.DialContext(r.Context(), "tcp", sess.Endpoint.Addr())
	if err != nil {
		http.Error(w, fmt.Sprintf("backend dial failed: %v", err), http.StatusBadGateway)
		return
	}
	defer backendConn.Close()

	// Forward the upgrade request to the backend (preserving headers, with
	// X-Forwarded-For and a substrate-routable Host when applicable).
	outReq := r.Clone(r.Context())
	outReq.URL.Scheme = "http"
	outReq.URL.Host = sess.Endpoint.Addr()
	outReq.Host = substrateHostOrDefault(h.Backend, sess.ID, sess.Endpoint.Addr())
	outReq.Header.Set("X-Forwarded-For", clientIPMust(r))
	outReq.Header.Set("Host", outReq.Host)
	if err := outReq.Write(backendConn); err != nil {
		http.Error(w, fmt.Sprintf("backend write failed: %v", err), http.StatusBadGateway)
		return
	}

	clientConn, brw, err := hj.Hijack()
	if err != nil {
		h.Log.Error("hijack failed", "err", err)
		return
	}
	defer clientConn.Close()

	sess.ConnOpened()
	defer sess.ConnClosed()

	// Pump bytes both directions until either side closes.
	errc := make(chan error, 2)
	go func() {
		// Drain anything already buffered in the bufio.Reader, then stream.
		if brw != nil && brw.Reader.Buffered() > 0 {
			if _, err := io.CopyN(backendConn, brw.Reader, int64(brw.Reader.Buffered())); err != nil {
				errc <- err
				return
			}
		}
		_, err := io.Copy(backendConn, clientConn)
		errc <- err
	}()
	go func() {
		_, err := io.Copy(clientConn, backendConn)
		errc <- err
	}()
	<-errc
}

func (h *Handler) proxyError(w http.ResponseWriter, r *http.Request, err error) {
	if errors.Is(err, context.Canceled) {
		return
	}
	h.Log.Warn("upstream error", "path", r.URL.Path, "err", err)
	http.Error(w, fmt.Sprintf("upstream error: %v", err), http.StatusBadGateway)
}

func isWebsocketUpgrade(r *http.Request) bool {
	conn := r.Header.Get("Connection")
	upg := r.Header.Get("Upgrade")
	return strings.Contains(strings.ToLower(conn), "upgrade") && strings.EqualFold(upg, "websocket")
}

func clientIPFromReq(r *http.Request) (string, error) {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return "", err
	}
	return host, nil
}

func clientIPMust(r *http.Request) string {
	ip, _ := clientIPFromReq(r)
	return ip
}

// substrateHostOrDefault returns the actor-routable Host header for substrate
// or the upstream addr for everything else.
func substrateHostOrDefault(backendKind, playwrightID, fallback string) string {
	if backendKind == "substrate" {
		return "pw-" + playwrightID + "." + backend.SubstrateActorHost
	}
	return fallback
}
