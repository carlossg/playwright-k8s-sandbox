package identify

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestClaimDiagnosticSuppressesUntilExpiry(t *testing.T) {
	index := &Index{}

	if !index.claimDiagnostic("10.0.0.1") {
		t.Fatal("first claim was rejected")
	}
	if index.claimDiagnostic("10.0.0.1") {
		t.Fatal("duplicate claim was accepted")
	}

	index.diagnosedMu.Lock()
	index.diagnosedIPs["10.0.0.1"] = time.Now().Add(-time.Second)
	index.diagnosedMu.Unlock()

	if !index.claimDiagnostic("10.0.0.1") {
		t.Fatal("expired claim was not accepted")
	}
}

func TestClaimDiagnosticIsAtomic(t *testing.T) {
	index := &Index{}
	var accepted atomic.Int32
	var callers sync.WaitGroup

	for range 100 {
		callers.Add(1)
		go func() {
			defer callers.Done()
			if index.claimDiagnostic("10.0.0.2") {
				accepted.Add(1)
			}
		}()
	}
	callers.Wait()

	if got := accepted.Load(); got != 1 {
		t.Fatalf("accepted %d concurrent claims, want 1", got)
	}
}

func TestReleaseDiagnosticAllowsRetry(t *testing.T) {
	index := &Index{}
	if !index.claimDiagnostic("10.0.0.3") {
		t.Fatal("first claim was rejected")
	}

	index.releaseDiagnostic("10.0.0.3")

	if !index.claimDiagnostic("10.0.0.3") {
		t.Fatal("released claim was not accepted")
	}
}
