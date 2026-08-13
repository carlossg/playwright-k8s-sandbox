// Package backend abstracts sandbox provisioning across agent-sandbox / openshell / substrate.
//
// One sandbox per playwright-id; Ensure is idempotent. Endpoint resolves to a host:port
// the proxy can dial.
package backend

import (
	"context"
	"fmt"
)

type Endpoint struct {
	Host string
	// Port is the native Playwright WebSocket port (chromium.launchServer).
	Port int
	// MCPPort is the port serving MCP-over-HTTP. @playwright/mcp cannot share a
	// process/port with chromium.launchServer, so a sandbox that offers both
	// protocols listens on two ports. When zero, MCPAddr falls back to Port
	// (single-port sandboxes and backends that route both protocols through one
	// upstream, e.g. substrate's router).
	MCPPort int
}

// Addr is the dial address for native Playwright WebSocket traffic.
func (e Endpoint) Addr() string { return fmt.Sprintf("%s:%d", e.Host, e.Port) }

// MCPAddr is the dial address for MCP-over-HTTP traffic, falling back to the
// WebSocket port when no separate MCP port is configured.
func (e Endpoint) MCPAddr() string {
	port := e.MCPPort
	if port == 0 {
		port = e.Port
	}
	return fmt.Sprintf("%s:%d", e.Host, port)
}

type Backend interface {
	// Ensure returns an Endpoint for the given playwright-id, creating the underlying
	// sandbox resource if it does not already exist. Blocks until the sandbox is ready
	// or ctx is cancelled. Safe to call concurrently for the same id; the session
	// manager serializes per-id callers, so implementations can rely on at-most-one
	// concurrent Ensure per id.
	Ensure(ctx context.Context, playwrightID string) (Endpoint, error)

	// Delete tears down the sandbox for the given playwright-id. Idempotent.
	Delete(ctx context.Context, playwrightID string) error

	// List returns playwright-ids that currently have a sandbox resource. Used on
	// proxy startup to repopulate the session map.
	List(ctx context.Context) ([]string, error)
}
