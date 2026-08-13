package config

import "testing"

func TestParsePort(t *testing.T) {
	tests := []struct {
		name      string
		raw       string
		allowZero bool
		want      int
		wantErr   bool
	}{
		{name: "valid port", raw: "9222", want: 9222},
		{name: "min", raw: "1", want: 1},
		{name: "max", raw: "65535", want: 65535},
		{name: "zero rejected without allowZero", raw: "0", wantErr: true},
		{name: "zero allowed as sentinel", raw: "0", allowZero: true, want: 0},
		{name: "negative rejected", raw: "-1", wantErr: true},
		{name: "above range rejected", raw: "65536", wantErr: true},
		{name: "non-numeric rejected", raw: "abc", wantErr: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parsePort("PORT", tt.raw, tt.allowZero)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("parsePort(%q) = %d, want error", tt.raw, got)
				}
				return
			}
			if err != nil {
				t.Fatalf("parsePort(%q) unexpected error: %v", tt.raw, err)
			}
			if got != tt.want {
				t.Fatalf("parsePort(%q) = %d, want %d", tt.raw, got, tt.want)
			}
		})
	}
}
