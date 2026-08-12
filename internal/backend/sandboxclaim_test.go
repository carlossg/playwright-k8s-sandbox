package backend

import (
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func TestPodMetadataLabelKey(t *testing.T) {
	tests := []struct {
		name     string
		labelKey string
		want     string
	}{
		{
			name:     "bare key is qualified with domain prefix",
			labelKey: "playwright-id",
			want:     podUserLabelDomain + "playwright-id",
		},
		{
			name:     "already-qualified key is used verbatim",
			labelKey: "example.com/playwright-id",
			want:     "example.com/playwright-id",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := &SandboxClaim{playwrightIDLabelKey: tt.labelKey}
			if got := s.podMetadataLabelKey(); got != tt.want {
				t.Fatalf("podMetadataLabelKey() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestBuildClaimLabelKeys(t *testing.T) {
	// A bare configured key must appear verbatim on the claim's own metadata
	// (that is the label the proxy selects on) while the additionalPodMetadata
	// labels carry the domain-qualified variant required by agent-sandbox.
	s := &SandboxClaim{
		namespace:            "ns",
		warmPoolName:         "wp",
		playwrightIDLabelKey: "playwright-id",
	}
	claim := s.buildClaim("pw-alpha", "alpha")

	claimLabel, found, err := unstructured.NestedString(claim.Object, "metadata", "labels", "playwright-id")
	if err != nil || !found {
		t.Fatalf("metadata.labels[playwright-id] not found (found=%v, err=%v)", found, err)
	}
	if claimLabel != "alpha" {
		t.Fatalf("metadata.labels[playwright-id] = %q, want %q", claimLabel, "alpha")
	}

	qualified := podUserLabelDomain + "playwright-id"
	podLabel, found, err := unstructured.NestedString(claim.Object, "spec", "additionalPodMetadata", "labels", qualified)
	if err != nil || !found {
		t.Fatalf("additionalPodMetadata.labels[%s] not found (found=%v, err=%v)", qualified, found, err)
	}
	if podLabel != "alpha" {
		t.Fatalf("additionalPodMetadata.labels[%s] = %q, want %q", qualified, podLabel, "alpha")
	}

	// The bare key must NOT leak into additionalPodMetadata (would fail v0.5.x validation).
	if _, found, _ := unstructured.NestedString(claim.Object, "spec", "additionalPodMetadata", "labels", "playwright-id"); found {
		t.Fatalf("additionalPodMetadata.labels unexpectedly contains bare key %q", "playwright-id")
	}
}
