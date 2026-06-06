// SandboxClaim backend covers both the agent-sandbox warmpool path and openshell
// (which itself is built on agent-sandbox). The proxy creates one SandboxClaim per
// playwright-id, all referencing the same configured SandboxWarmPool. The agent-sandbox
// controller adopts a pre-warmed Sandbox; the claim's status.sandbox.podIPs[0] is the
// upstream IP. To switch between agent-sandbox and openshell, point WARMPOOL_NAME at
// the openshell-flavoured pool instead.
package backend

import (
	"context"
	"errors"
	"fmt"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/util/wait"
	"k8s.io/client-go/dynamic"
)

const (
	managedByLabel    = "playwright-proxy/managed"
	playwrightIDLabel = "playwright-id"
)

// SandboxClaim lives in the extensions API group; the core Sandbox / SandboxStatus
// types in agents.x-k8s.io are referenced transitively through the claim status.
// agent-sandbox releases up to v0.4.6 serve v1alpha1 for the extensions CRDs; the
// schema is unchanged through v1beta1 (which is in the source tree but not yet
// released), so bumping the version when it ships is a constant change.
var sandboxClaimGVR = schema.GroupVersionResource{
	Group:    "extensions.agents.x-k8s.io",
	Version:  "v1alpha1",
	Resource: "sandboxclaims",
}

const sandboxClaimAPIVersion = "extensions.agents.x-k8s.io/v1alpha1"

type SandboxClaim struct {
	client       dynamic.NamespaceableResourceInterface
	namespace    string
	templateName string
	warmPoolName string
	port         int
}

func NewSandboxClaim(dc dynamic.Interface, namespace, templateName, warmPoolName string, port int) *SandboxClaim {
	return &SandboxClaim{
		client:       dc.Resource(sandboxClaimGVR),
		namespace:    namespace,
		templateName: templateName,
		warmPoolName: warmPoolName,
		port:         port,
	}
}

func claimName(playwrightID string) string { return "pw-" + playwrightID }

func (s *SandboxClaim) Ensure(ctx context.Context, playwrightID string) (Endpoint, error) {
	name := claimName(playwrightID)
	nsClient := s.client.Namespace(s.namespace)

	// Try get first; if absent, create.
	obj, err := nsClient.Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		if !isNotFound(err) {
			return Endpoint{}, fmt.Errorf("get SandboxClaim %s: %w", name, err)
		}
		obj = s.buildClaim(name, playwrightID)
		obj, err = nsClient.Create(ctx, obj, metav1.CreateOptions{})
		if err != nil && !isAlreadyExists(err) {
			return Endpoint{}, fmt.Errorf("create SandboxClaim %s: %w", name, err)
		}
		// AlreadyExists: re-get to read status set by another caller.
		if err != nil {
			obj, err = nsClient.Get(ctx, name, metav1.GetOptions{})
			if err != nil {
				return Endpoint{}, fmt.Errorf("re-get SandboxClaim %s: %w", name, err)
			}
		}
	}
	_ = obj // status comes from the poll loop below

	// Poll for readiness (Ready condition true + podIP set).
	var ep Endpoint
	pollErr := wait.PollUntilContextCancel(ctx, 500*time.Millisecond, true, func(ctx context.Context) (bool, error) {
		cur, err := nsClient.Get(ctx, name, metav1.GetOptions{})
		if err != nil {
			return false, err
		}
		ip, ready := extractClaimEndpoint(cur)
		if !ready {
			return false, nil
		}
		ep = Endpoint{Host: ip, Port: s.port}
		return true, nil
	})
	if pollErr != nil {
		return Endpoint{}, fmt.Errorf("SandboxClaim %s not ready: %w", name, pollErr)
	}
	return ep, nil
}

func (s *SandboxClaim) Delete(ctx context.Context, playwrightID string) error {
	name := claimName(playwrightID)
	err := s.client.Namespace(s.namespace).Delete(ctx, name, metav1.DeleteOptions{})
	if err != nil && !isNotFound(err) {
		return fmt.Errorf("delete SandboxClaim %s: %w", name, err)
	}
	return nil
}

func (s *SandboxClaim) List(ctx context.Context) ([]string, error) {
	list, err := s.client.Namespace(s.namespace).List(ctx, metav1.ListOptions{
		LabelSelector: managedByLabel + "=true",
	})
	if err != nil {
		return nil, fmt.Errorf("list SandboxClaims: %w", err)
	}
	ids := make([]string, 0, len(list.Items))
	for _, it := range list.Items {
		if id := it.GetLabels()[playwrightIDLabel]; id != "" {
			ids = append(ids, id)
		}
	}
	return ids, nil
}

func (s *SandboxClaim) buildClaim(name, playwrightID string) *unstructured.Unstructured {
	return &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": sandboxClaimAPIVersion,
		"kind":       "SandboxClaim",
		"metadata": map[string]any{
			"name":      name,
			"namespace": s.namespace,
			"labels": map[string]any{
				managedByLabel:    "true",
				playwrightIDLabel: playwrightID,
			},
		},
		"spec": map[string]any{
			"sandboxTemplateRef": map[string]any{
				"name": s.templateName,
			},
			"warmpool": s.warmPoolName,
			"additionalPodMetadata": map[string]any{
				"labels": map[string]any{
					playwrightIDLabel: playwrightID,
				},
			},
		},
	}}
}

// extractClaimEndpoint reads the adopted pod IP and ready condition from claim status.
func extractClaimEndpoint(claim *unstructured.Unstructured) (ip string, ready bool) {
	st, found, err := unstructured.NestedMap(claim.Object, "status")
	if err != nil || !found {
		return "", false
	}

	// Ready condition.
	conds, _, _ := unstructured.NestedSlice(st, "conditions")
	for _, c := range conds {
		cm, ok := c.(map[string]any)
		if !ok {
			continue
		}
		if cm["type"] == "Ready" && cm["status"] == "True" {
			ready = true
			break
		}
	}
	if !ready {
		return "", false
	}

	ips, _, _ := unstructured.NestedSlice(st, "sandbox", "podIPs")
	for _, v := range ips {
		if s, ok := v.(string); ok && s != "" {
			return s, true
		}
	}
	return "", false
}

func isNotFound(err error) bool {
	var statusErr interface{ Status() metav1.Status }
	if errors.As(err, &statusErr) {
		return statusErr.Status().Code == 404
	}
	return false
}

func isAlreadyExists(err error) bool {
	var statusErr interface{ Status() metav1.Status }
	if errors.As(err, &statusErr) {
		return statusErr.Status().Code == 409
	}
	return false
}
