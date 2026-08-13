package backend

import "testing"

func TestEndpointAddr(t *testing.T) {
	// Addr always uses the native WebSocket port, independent of MCPPort.
	ep := Endpoint{Host: "10.0.0.1", Port: 9222, MCPPort: 9223}
	if got, want := ep.Addr(), "10.0.0.1:9222"; got != want {
		t.Fatalf("Addr() = %q, want %q", got, want)
	}
}

func TestEndpointMCPAddr(t *testing.T) {
	tests := []struct {
		name string
		ep   Endpoint
		want string
	}{
		{
			name: "separate mcp port",
			ep:   Endpoint{Host: "10.0.0.1", Port: 9222, MCPPort: 9223},
			want: "10.0.0.1:9223",
		},
		{
			name: "zero mcp port falls back to ws port",
			ep:   Endpoint{Host: "10.0.0.1", Port: 9222, MCPPort: 0},
			want: "10.0.0.1:9222",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := tt.ep.MCPAddr(); got != tt.want {
				t.Fatalf("MCPAddr() = %q, want %q", got, tt.want)
			}
		})
	}
}
