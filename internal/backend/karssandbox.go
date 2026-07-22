// KarsSandbox backend: manages one KarsSandbox CR (kars.azure.com/v1alpha1) per
// playwright-id using the BYO runtime kind. The kars controller creates a
// dedicated namespace (kars-{name}) and runs the Playwright container there
// alongside its inference-router sidecar.
//
// Lifecycle:
//   - Ensure: get-or-create the KarsSandbox CR, poll status.phase until
//     "Running", then look up the sandbox pod's IP in the dedicated namespace.
//   - Delete: delete the CR; the kars controller's finalizer cascades the
//     namespace deletion.
//   - List: list CRs in the proxy namespace labelled playwright-proxy/managed=true.
package backend

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/util/wait"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
)

var karsSandboxGVR = schema.GroupVersionResource{
	Group:   "kars.azure.com",
	Version: "v1alpha1",
	Resource: "karssandboxes",
}

const karsSandboxAPIVersion = "kars.azure.com/v1alpha1"

// pod label set by the kars controller on every sandbox Deployment pod template.
const karsSandboxComponentLabel = "kars.azure.com/component=sandbox"

type KarsSandboxBackend struct {
	dynClient             dynamic.NamespaceableResourceInterface
	k8s                   kubernetes.Interface
	namespace             string // namespace where the KarsSandbox CR lives
	inferenceRef          string // name of the InferencePolicy CR in that namespace
	image                 string // Playwright container image
	port                  int    // port the Playwright server listens on inside the pod
	playwrightIDLabelKey string // configurable label key for playwright-id
}

func NewKarsSandbox(
	dyn dynamic.Interface,
	k8s kubernetes.Interface,
	namespace, inferenceRef, image string,
	port int,
	labelKey string,
) *KarsSandboxBackend {
	return &KarsSandboxBackend{
		dynClient:             dyn.Resource(karsSandboxGVR),
		k8s:                   k8s,
		namespace:             namespace,
		inferenceRef:          inferenceRef,
		image:                 image,
		port:                  port,
		playwrightIDLabelKey: labelKey,
	}
}

func karsName(playwrightID string) string { return "pw-" + playwrightID }

func (k *KarsSandboxBackend) Ensure(ctx context.Context, playwrightID string) (Endpoint, error) {
	name := karsName(playwrightID)
	nsClient := k.dynClient.Namespace(k.namespace)

	if _, err := nsClient.Get(ctx, name, metav1.GetOptions{}); err != nil {
		if !isNotFound(err) {
			return Endpoint{}, fmt.Errorf("get KarsSandbox %s: %w", name, err)
		}
		obj := k.buildCR(name, playwrightID)
		if _, err := nsClient.Create(ctx, obj, metav1.CreateOptions{}); err != nil && !isAlreadyExists(err) {
			return Endpoint{}, fmt.Errorf("create KarsSandbox %s: %w", name, err)
		}
	}

	// Phase 1: wait for status.phase == "Running".
	sandboxNs, err := k.waitForRunning(ctx, name, nsClient)
	if err != nil {
		return Endpoint{}, err
	}

	// Phase 2: wait for pod to be ready (confirms sandbox is up).
	// Use Service DNS name instead of pod IP because KARS sandboxes run in
	// isolated namespaces with NetworkPolicies that block direct pod access.
	_, err = k.waitForPodIP(ctx, sandboxNs)
	if err != nil {
		return Endpoint{}, err
	}

	// Return Service DNS name: <sandbox-name>.<sandbox-namespace>.svc.cluster.local
	serviceFQDN := fmt.Sprintf("%s.%s.svc.cluster.local", name, sandboxNs)
	return Endpoint{Host: serviceFQDN, Port: k.port}, nil
}

// waitForRunning polls the KarsSandbox CR until status.phase is "Running"
// (or a terminal failure phase), then returns the sandbox namespace.
func (k *KarsSandboxBackend) waitForRunning(
	ctx context.Context,
	name string,
	nsClient dynamic.ResourceInterface,
) (string, error) {
	var sandboxNs string
	err := wait.PollUntilContextCancel(ctx, 500*time.Millisecond, true, func(ctx context.Context) (bool, error) {
		cur, err := nsClient.Get(ctx, name, metav1.GetOptions{})
		if err != nil {
			return false, err
		}
		phase, _, _ := unstructured.NestedString(cur.Object, "status", "phase")
		switch phase {
		case "Running":
			ns, _, _ := unstructured.NestedString(cur.Object, "status", "namespace")
			if ns == "" {
				// status.namespace not yet populated; keep polling.
				return false, nil
			}
			sandboxNs = ns
			return true, nil
		case "Degraded", "Failed":
			return false, fmt.Errorf("KarsSandbox %s reached terminal phase %q", name, phase)
		default:
			return false, nil
		}
	})
	if err != nil {
		return "", fmt.Errorf("KarsSandbox %s did not reach Running: %w", name, err)
	}
	return sandboxNs, nil
}

// waitForPodIP polls pods in the sandbox namespace (labelled
// kars.azure.com/component=sandbox) until one is Running with a pod IP.
func (k *KarsSandboxBackend) waitForPodIP(ctx context.Context, sandboxNs string) (string, error) {
	var ip string
	err := wait.PollUntilContextCancel(ctx, 500*time.Millisecond, true, func(ctx context.Context) (bool, error) {
		pods, err := k.k8s.CoreV1().Pods(sandboxNs).List(ctx, metav1.ListOptions{
			LabelSelector: karsSandboxComponentLabel,
		})
		if err != nil {
			return false, err
		}
		for i := range pods.Items {
			p := &pods.Items[i]
			if p.Status.Phase == corev1.PodRunning && p.Status.PodIP != "" {
				ip = p.Status.PodIP
				return true, nil
			}
		}
		return false, nil
	})
	if err != nil {
		return "", fmt.Errorf("no running pod found in %s: %w", sandboxNs, err)
	}
	slog.Info("karssandbox: pod ready", "namespace", sandboxNs, "ip", ip)
	return ip, nil
}

func (k *KarsSandboxBackend) Delete(ctx context.Context, playwrightID string) error {
	name := karsName(playwrightID)
	err := k.dynClient.Namespace(k.namespace).Delete(ctx, name, metav1.DeleteOptions{})
	if err != nil && !isNotFound(err) {
		return fmt.Errorf("delete KarsSandbox %s: %w", name, err)
	}
	return nil
}

func (k *KarsSandboxBackend) List(ctx context.Context) ([]string, error) {
	list, err := k.dynClient.Namespace(k.namespace).List(ctx, metav1.ListOptions{
		LabelSelector: managedByLabel + "=true",
	})
	if err != nil {
		return nil, fmt.Errorf("list KarsSandboxes: %w", err)
	}
	ids := make([]string, 0, len(list.Items))
	for _, it := range list.Items {
		if id := it.GetLabels()[k.playwrightIDLabelKey]; id != "" {
			ids = append(ids, id)
		}
	}
	return ids, nil
}

func (k *KarsSandboxBackend) buildCR(name, playwrightID string) *unstructured.Unstructured {
	return &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": karsSandboxAPIVersion,
		"kind":       "KarsSandbox",
		"metadata": map[string]any{
			"name":      name,
			"namespace": k.namespace,
			"labels": map[string]any{
				managedByLabel:          "true",
				k.playwrightIDLabelKey: playwrightID,
			},
		},
		"spec": map[string]any{
			"runtime": map[string]any{
				"kind": "BYO",
				"byo": map[string]any{
					"image":            k.image,
					"command":          []any{"node", "/server.js"},
					"contractVersion": "v1",
					"env": []any{
						map[string]any{"name": "PORT", "value": fmt.Sprintf("%d", k.port)},
						map[string]any{"name": "NODE_PATH", "value": "/usr/local/lib/node_modules"},
						map[string]any{"name": "PLAYWRIGHT_BROWSERS_PATH", "value": "/ms-playwright"},
						map[string]any{"name": "CHROMIUM_ARGS", "value": "--no-sandbox,--disable-setuid-sandbox,--disable-dev-shm-usage,--disable-gpu"},
					},
				},
			},
			"sandbox": map[string]any{
				"isolation":                "standard",
				"runAsNonRoot":             true,
				"allowPrivilegeEscalation": false,
			},
			"inferenceRef": map[string]any{
				"name": k.inferenceRef,
			},
			"networkPolicy": map[string]any{
				"defaultDeny": false,
				"egressMode":  "Learn",
			},
		},
	}}
}
