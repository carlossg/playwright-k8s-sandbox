// Package session owns the playwright-id → sandbox endpoint mapping, serializes
// Ensure calls per id, tracks liveness for the idle reaper, and drives Delete
// on the backend when a session goes idle.
package session

import (
	"context"
	"errors"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/carlossg/playwright-k8s-sandbox/internal/backend"
)

type Session struct {
	ID         string
	Endpoint   backend.Endpoint
	created    time.Time
	lastActive atomic.Int64 // unix nanos
	activeConn atomic.Int32

	// ready is closed once Endpoint is populated. Allows concurrent Get callers to
	// wait on the single Ensure in flight.
	ready chan struct{}
	err   error // populated iff ready is closed and Ensure failed
}

func (s *Session) MarkActive()  { s.lastActive.Store(time.Now().UnixNano()) }
func (s *Session) ConnOpened()  { s.activeConn.Add(1); s.MarkActive() }
func (s *Session) ConnClosed()  { s.activeConn.Add(-1); s.MarkActive() }
func (s *Session) ActiveConns() int32 { return s.activeConn.Load() }
func (s *Session) LastActive() time.Time {
	return time.Unix(0, s.lastActive.Load())
}

type Manager struct {
	backend       backend.Backend
	ensureTimeout time.Duration
	idleTTL       time.Duration
	log           *slog.Logger

	mu       sync.Mutex
	sessions map[string]*Session
}

func New(b backend.Backend, ensureTimeout, idleTTL time.Duration, log *slog.Logger) *Manager {
	return &Manager{
		backend:       b,
		ensureTimeout: ensureTimeout,
		idleTTL:       idleTTL,
		log:           log,
		sessions:      map[string]*Session{},
	}
}

// Reconcile populates the session map from existing backend resources on startup.
// Endpoints are not pre-resolved; the first request for each id will Ensure and
// fill in the endpoint, which is a no-op when the resource already exists.
func (m *Manager) Reconcile(ctx context.Context) error {
	ids, err := m.backend.List(ctx)
	if err != nil {
		return err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	now := time.Now()
	for _, id := range ids {
		if _, ok := m.sessions[id]; ok {
			continue
		}
		sess := &Session{ID: id, created: now, ready: make(chan struct{})}
		sess.lastActive.Store(now.UnixNano())
		// Eagerly resolve in the background so the first request doesn't pay the
		// full Ensure latency.
		go m.resolve(context.Background(), sess)
		m.sessions[id] = sess
	}
	return nil
}

// Get returns a ready session for the given playwright-id, kicking off a new one
// if needed. Blocks until ready or ctx times out.
func (m *Manager) Get(ctx context.Context, playwrightID string) (*Session, error) {
	m.mu.Lock()
	sess, ok := m.sessions[playwrightID]
	if !ok {
		sess = &Session{ID: playwrightID, created: time.Now(), ready: make(chan struct{})}
		sess.lastActive.Store(time.Now().UnixNano())
		m.sessions[playwrightID] = sess
		go m.resolve(context.Background(), sess)
	}
	m.mu.Unlock()

	select {
	case <-sess.ready:
		if sess.err != nil {
			// On failure, drop the broken session so the next caller retries.
			m.mu.Lock()
			if m.sessions[playwrightID] == sess {
				delete(m.sessions, playwrightID)
			}
			m.mu.Unlock()
			return nil, sess.err
		}
		return sess, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (m *Manager) resolve(ctx context.Context, sess *Session) {
	ctx, cancel := context.WithTimeout(ctx, m.ensureTimeout)
	defer cancel()
	ep, err := m.backend.Ensure(ctx, sess.ID)
	if err != nil {
		sess.err = err
		m.log.Error("ensure failed", "id", sess.ID, "err", err)
	} else {
		sess.Endpoint = ep
		m.log.Info("session ready", "id", sess.ID, "endpoint", ep.Addr())
	}
	close(sess.ready)
}

// ReapLoop runs until ctx is done, deleting sessions that have been idle longer than idleTTL.
// "Idle" = no active connections AND lastActive older than idleTTL.
func (m *Manager) ReapLoop(ctx context.Context, interval time.Duration) {
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			m.reapOnce(ctx)
		}
	}
}

func (m *Manager) reapOnce(ctx context.Context) {
	cutoff := time.Now().Add(-m.idleTTL)
	m.mu.Lock()
	victims := make([]*Session, 0)
	for id, sess := range m.sessions {
		// Skip sessions still resolving.
		select {
		case <-sess.ready:
		default:
			continue
		}
		if sess.ActiveConns() > 0 {
			continue
		}
		if sess.LastActive().After(cutoff) {
			continue
		}
		victims = append(victims, sess)
		delete(m.sessions, id)
	}
	m.mu.Unlock()

	for _, sess := range victims {
		if err := m.backend.Delete(ctx, sess.ID); err != nil {
			m.log.Error("reap delete failed", "id", sess.ID, "err", err)
			continue
		}
		m.log.Info("reaped idle session", "id", sess.ID, "idle_for", time.Since(sess.LastActive()).Round(time.Second))
	}
}

// ErrNoSession is returned by Get when the backend is misconfigured for this id.
var ErrNoSession = errors.New("no session")
