// Isola backend: manages one Sandbox custom resource (sandbox.isola.run/v1alpha1)
// per playwright-id, using isola's gVisor-isolated, Kubernetes-native sandbox
// platform (https://github.com/isola-run/isola). Unlike KarsSandbox, all Sandbox
// CRs live in a single shared, pre-existing namespace (ISOLA_NAMESPACE) — there
// is no per-sandbox namespace.
//
// Lifecycle:
//   - Ensure: get-or-create the Sandbox CR, poll status.conditions[type=Ready]
//     until status=True (treating PodFailed/PodSucceeded/PodCreationFailed/
//     StartupTimeoutExceeded/InvalidRuntime as terminal errors), then read
//     status.podIP directly — the isola operator sets it on the CR itself, so
//     no secondary Pods lookup is needed (unlike KarsSandbox).
//   - Delete: delete the CR; the isola operator tears down the pod under the
//     default TerminationPolicy (Delete — no rootfs snapshot).
//   - List: list CRs in the sandbox namespace labelled playwright-proxy/managed=true.
//
// IMPORTANT: isola's Helm chart installs a default-deny NetworkPolicy scoped to
// pods labeled isola.run/sandbox=true in the sandbox namespace, plus an
// allow-api-gateway-ingress policy that only opens port 10032 (the sidecar's
// control port) from isola's own api-gateway pod. playwright-proxy is not
// isola's api-gateway, so by default it cannot reach the sandbox's Playwright
// port. See deploy/examples/isola/networkpolicy-allow-proxy.yaml — apply once,
// cluster-side, before using this backend.
package backend

import (
	"context"
	"crypto/sha256"
	"fmt"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/util/wait"
	"k8s.io/client-go/dynamic"
)

var isolaSandboxGVR = schema.GroupVersionResource{
	Group:    "sandbox.isola.run",
	Version:  "v1alpha1",
	Resource: "sandboxes",
}

const isolaSandboxAPIVersion = "sandbox.isola.run/v1alpha1"

// isolaMaxNameLen is the CEL-enforced cap on Sandbox metadata.name
// (isola api/v1alpha1/sandbox_types.go: "size(self.metadata.name) <= 47").
const isolaMaxNameLen = 47

// isolaTerminalReasons are Ready-condition reasons the isola operator sets
// that must stop polling immediately rather than be treated as "not ready yet".
var isolaTerminalReasons = map[string]bool{
	"PodFailed":              true,
	"PodSucceeded":           true,
	"PodCreationFailed":      true,
	"StartupTimeoutExceeded": true,
	"InvalidRuntime":         true,
}

type IsolaBackend struct {
	dynClient          dynamic.NamespaceableResourceInterface
	namespace          string   // shared sandbox namespace (ISOLA_NAMESPACE), not the proxy's own namespace
	image              string   // Playwright container image
	port               int      // port the Playwright server listens on inside the pod
	allowedEgressCIDRs []string // additional egress CIDRs, e.g. for in-cluster fetch targets; see NewIsolaBackend
}

// NewIsolaBackend constructs an IsolaBackend. allowedEgressCIDRs is optional
// (nil is fine) and adds to the sandbox's egress policy alongside the default
// internet-egress allowance — isola excepts private/cluster-internal ranges
// from allowInternetEgress even when it's true, so reaching an in-cluster
// target (e.g. a test fixture Service) requires listing its CIDR here
// explicitly. Production deployments that only need general web browsing can
// leave this nil.
func NewIsolaBackend(dyn dynamic.Interface, namespace, image string, port int, allowedEgressCIDRs []string) *IsolaBackend {
	return &IsolaBackend{
		dynClient:          dyn.Resource(isolaSandboxGVR),
		namespace:          namespace,
		image:              image,
		port:               port,
		allowedEgressCIDRs: allowedEgressCIDRs,
	}
}

// isolaName derives the Sandbox CR name for a playwright-id. Sandbox's CEL
// validation caps metadata.name at 47 chars and requires a valid DNS-1123
// subdomain (lowercase alphanumeric, '-', '.'). playwright-id label values
// permissibly contain uppercase letters, underscores, etc. (Kubernetes label
// syntax is looser than a resource name), so IDs that fit as "pw-"+id are
// used verbatim only when they're also DNS-1123-clean (also readable via
// kubectl get sandbox); anything too long or containing invalid characters is
// hashed to a fixed-width name instead, consistent with the label-hashing
// guidance in docs/ARCHITECTURE.md's Caveats section. The full, unhashed id is
// always preserved in the playwrightIDLabel label and used by List to round-trip.
func isolaName(playwrightID string) string {
	const prefix = "pw-"
	name := prefix + playwrightID
	if len(name) <= isolaMaxNameLen && isDNS1123(playwrightID) {
		return name
	}
	sum := sha256.Sum256([]byte(playwrightID))
	return fmt.Sprintf("%s%x", prefix, sum)[:isolaMaxNameLen]
}

// isDNS1123 reports whether s contains only characters valid in a DNS-1123
// subdomain segment (lowercase alphanumeric, '-', '.').
func isDNS1123(s string) bool {
	for _, r := range s {
		if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-' || r == '.') {
			return false
		}
	}
	return true
}

func (b *IsolaBackend) Ensure(ctx context.Context, playwrightID string) (Endpoint, error) {
	name := isolaName(playwrightID)
	nsClient := b.dynClient.Namespace(b.namespace)

	if _, err := nsClient.Get(ctx, name, metav1.GetOptions{}); err != nil {
		if !isNotFound(err) {
			return Endpoint{}, fmt.Errorf("get Sandbox %s: %w", name, err)
		}
		obj := b.buildCR(name, playwrightID)
		if _, err := nsClient.Create(ctx, obj, metav1.CreateOptions{}); err != nil && !isAlreadyExists(err) {
			return Endpoint{}, fmt.Errorf("create Sandbox %s: %w", name, err)
		}
	}

	ip, err := b.waitForReady(ctx, name, nsClient)
	if err != nil {
		return Endpoint{}, err
	}
	return Endpoint{Host: ip, Port: b.port}, nil
}

// waitForReady polls the Sandbox CR until its Ready condition is True, or a
// terminal failure reason appears. Returns status.podIP, which the isola
// operator populates directly on the CR.
func (b *IsolaBackend) waitForReady(
	ctx context.Context,
	name string,
	nsClient dynamic.ResourceInterface,
) (string, error) {
	var podIP string
	err := wait.PollUntilContextCancel(ctx, 500*time.Millisecond, true, func(ctx context.Context) (bool, error) {
		cur, err := nsClient.Get(ctx, name, metav1.GetOptions{})
		if err != nil {
			return false, err
		}
		conds, _, _ := unstructured.NestedSlice(cur.Object, "status", "conditions")
		for _, c := range conds {
			cm, ok := c.(map[string]any)
			if !ok || cm["type"] != "Ready" {
				continue
			}
			if reason, _ := cm["reason"].(string); isolaTerminalReasons[reason] {
				return false, fmt.Errorf("Sandbox %s reached terminal condition %s: %v", name, reason, cm["message"])
			}
			if cm["status"] != "True" {
				return false, nil
			}
			ip, _, _ := unstructured.NestedString(cur.Object, "status", "podIP")
			if ip == "" {
				// Ready but podIP not yet propagated; keep polling.
				return false, nil
			}
			podIP = ip
			return true, nil
		}
		return false, nil
	})
	if err != nil {
		return "", fmt.Errorf("Sandbox %s did not become Ready: %w", name, err)
	}
	return podIP, nil
}

func (b *IsolaBackend) Delete(ctx context.Context, playwrightID string) error {
	name := isolaName(playwrightID)
	err := b.dynClient.Namespace(b.namespace).Delete(ctx, name, metav1.DeleteOptions{})
	if err != nil && !isNotFound(err) {
		return fmt.Errorf("delete Sandbox %s: %w", name, err)
	}
	return nil
}

func (b *IsolaBackend) List(ctx context.Context) ([]string, error) {
	list, err := b.dynClient.Namespace(b.namespace).List(ctx, metav1.ListOptions{
		LabelSelector: managedByLabel + "=true",
	})
	if err != nil {
		return nil, fmt.Errorf("list Sandboxes: %w", err)
	}
	ids := make([]string, 0, len(list.Items))
	for _, it := range list.Items {
		if id := it.GetLabels()[playwrightIDLabel]; id != "" {
			ids = append(ids, id)
		}
	}
	return ids, nil
}

func (b *IsolaBackend) buildCR(name, playwrightID string) *unstructured.Unstructured {
	return &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": isolaSandboxAPIVersion,
		"kind":       "Sandbox",
		"metadata": map[string]any{
			"name":      name,
			"namespace": b.namespace,
			"labels": map[string]any{
				managedByLabel:    "true",
				playwrightIDLabel: playwrightID,
			},
		},
		"spec": map[string]any{
			// podTemplate is a schemaless corev1.PodTemplateSpec; the operator
			// injects runtimeClassName (gVisor), security context, and the
			// isola.run/sandbox=true pod label itself, so only the user
			// container needs describing here.
			"podTemplate": map[string]any{
				"spec": map[string]any{
					"containers": []any{
						map[string]any{
							"name": "playwright",
							// The isola operator unconditionally sets Command =
							// [sleep, infinity] whenever this is empty — replacing
							// the image ENTRYPOINT/CMD entirely rather than only
							// filling in a default when both are unset — so an
							// explicit command is required to actually launch the
							// Playwright server (matches karssandbox.go's buildCR).
							"command": []any{"node", "/server.js"},
							"image":   b.image,
							"ports": []any{
								map[string]any{"containerPort": int64(b.port)},
							},
							"env": []any{
								map[string]any{"name": "PORT", "value": fmt.Sprintf("%d", b.port)},
								map[string]any{"name": "PLAYWRIGHT_BROWSERS_PATH", "value": "/ms-playwright"},
								map[string]any{"name": "CHROMIUM_ARGS", "value": "--no-sandbox,--disable-setuid-sandbox,--disable-dev-shm-usage,--disable-gpu"},
							},
						},
					},
				},
			},
			// network: the operator's default is deny-all egress *and* DNS sink,
			// which would leave the sandbox unable to resolve or reach anything
			// the caller navigates to. Playwright sandboxes exist to browse
			// arbitrary pages, so allow general internet egress and cluster DNS.
			// Note allowInternetEgress does NOT open private/cluster-internal
			// ranges (isola excepts them even with internet egress on) — an
			// in-cluster target (e.g. a test fixture Service) additionally needs
			// its CIDR in allowedEgressCIDRs, which is deployment-specific and
			// deliberately left to whoever wires this backend up, not hardcoded
			// here.
			"network": b.buildNetwork(),
			// terminationPolicy is omitted to take the operator's default
			// (Delete — no rootfs snapshot), matching the "no state across
			// reaps" behavior of the other CRD-based backends.
		},
	}}
}

// buildNetwork returns the Sandbox spec.network block: general internet
// egress + cluster DNS by default (see the comment at the call site), plus
// any operator-configured allowedEgressCIDRs for reaching in-cluster targets.
func (b *IsolaBackend) buildNetwork() map[string]any {
	n := map[string]any{
		"allowInternetEgress": true,
		"allowClusterDNS":     true,
	}
	if len(b.allowedEgressCIDRs) > 0 {
		cidrs := make([]any, len(b.allowedEgressCIDRs))
		for i, c := range b.allowedEgressCIDRs {
			cidrs[i] = c
		}
		n["allowedEgressCIDRs"] = cidrs
	}
	return n
}
