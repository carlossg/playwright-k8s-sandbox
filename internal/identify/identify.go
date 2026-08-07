// Package identify maps a client pod IP to its playwright-id label value.
//
// A shared informer watches pods in the proxy's namespace that carry the
// configured label; the local index is updated on add/update/delete events
// so the hot path is an O(1) map lookup with no API round trip.
package identify

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/cache"
)

type Index struct {
	labelKey string

	mu      sync.RWMutex
	byPodIP map[string]string // podIP -> playwright-id
	ready   bool              // true after informer's initial LIST has synced

	// client + namespace let Lookup fall back to a direct API query on cache
	// miss, covering the race between a brand-new labelled pod making its
	// first request and the informer's UPDATE event delivering the new pod's
	// status.podIP.
	client    kubernetes.Interface
	namespace string

	// diagnosedIPs tracks IPs we've already logged diagnostics for to avoid
	// repeated warnings in the retry loop (podIP -> true).
	diagnosedIPs sync.Map
}

// New creates an Index. `client` and `namespace` are stored eagerly so the
// API-fallback path on Lookup works even before Run's informer cache has
// synced (e.g., the very first request after proxy startup).
func New(labelKey string, client kubernetes.Interface, namespace string) *Index {
	return &Index{
		labelKey:  labelKey,
		byPodIP:   map[string]string{},
		client:    client,
		namespace: namespace,
	}
}

// Lookup returns the playwright-id for a given pod IP. Returns ("", false) if unknown.
//
// On informer cache miss, falls back to a direct K8s API list and, if THAT
// also misses (because kubelet hasn't patched status.podIP yet on a brand new
// pod), keeps polling up to ~3 s. This absorbs the worst case where the
// container makes its first request before its own .status.podIP has propagated
// through kubelet → apiserver → etcd. Most lookups never hit either fallback
// (the informer cache is warm); when they do, only the very first lookup per
// new pod pays the cost — the resolved id is cached.
func (i *Index) Lookup(podIP string) (string, bool) {
	if id, ok := i.lookupCache(podIP); ok {
		return id, true
	}
	if i.client == nil || i.namespace == "" {
		return "", false
	}
	// Short backoff loop: 100ms × 100 = 10s. Each poll re-checks the cache
	// first in case the informer caught up between iterations. We've seen
	// substrate's apiserver event delivery lag ~5s on a busy cluster, so
	// 10s leaves headroom without blocking the WS upgrade indefinitely.
	for n := 0; n < 100; n++ {
		if id, ok := i.lookupCache(podIP); ok {
			return id, true
		}
		if id, ok := i.lookupViaAPI(podIP); ok {
			i.mu.Lock()
			i.byPodIP[podIP] = id
			i.mu.Unlock()
			return id, true
		}
		time.Sleep(100 * time.Millisecond)
	}
	return "", false
}

func (i *Index) lookupCache(podIP string) (string, bool) {
	i.mu.RLock()
	defer i.mu.RUnlock()
	id, ok := i.byPodIP[podIP]
	return id, ok
}

func (i *Index) lookupViaAPI(podIP string) (string, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	// First try with label selector - the expected case
	pods, err := i.client.CoreV1().Pods(i.namespace).List(ctx, metav1.ListOptions{
		LabelSelector: i.labelKey,
		FieldSelector: "status.podIP=" + podIP,
	})
	if err != nil {
		slog.Warn("identify: API fallback list error", "ip", podIP, "err", err)
		return "", false
	}
	if len(pods.Items) > 0 {
		pod := pods.Items[0]
		id := pod.Labels[i.labelKey]
		if id == "" {
			// Pod has the label key but empty value - log once and return failure
			if _, alreadyLogged := i.diagnosedIPs.LoadOrStore(podIP, true); !alreadyLogged {
				slog.Warn("identify: pod has empty label value",
					"ip", podIP,
					"pod", pod.Name,
					"namespace", pod.Namespace,
					"label_key", i.labelKey,
					"hint", "set non-empty value for label")
			}
			return "", false
		}
		slog.Info("identify: API fallback resolved pod", "ip", podIP, "id", id, "pod", pod.Name)
		return id, true
	}

	// Check if we've already diagnosed this IP to avoid repeated logging in retry loop
	if _, alreadyDiagnosed := i.diagnosedIPs.Load(podIP); alreadyDiagnosed {
		return "", false
	}

	// Mark as diagnosed before performing diagnostic checks
	i.diagnosedIPs.Store(podIP, true)

	// No labeled pod found - check if any pod exists with this IP (without label filter)
	allPods, err := i.client.CoreV1().Pods(i.namespace).List(ctx, metav1.ListOptions{
		FieldSelector: "status.podIP=" + podIP,
	})
	if err != nil {
		slog.Warn("identify: API fallback list error (unlabeled check)", "ip", podIP, "err", err)
		return "", false
	}

	if len(allPods.Items) > 0 {
		// Pod exists but lacks required label
		pod := allPods.Items[0]
		slog.Warn("identify: pod missing required label",
			"ip", podIP,
			"pod", pod.Name,
			"namespace", pod.Namespace,
			"label_key", i.labelKey,
			"hint", "add label to pod template spec")
		return "", false
	}

	// No pod with this IP exists at all
	slog.Info("identify: no pod found for IP", "ip", podIP, "namespace", i.namespace)
	return "", false
}

// Ready returns true once the pod informer has done its initial LIST and the
// in-memory cache is hot. The /readyz handler in main.go gates on this so
// kube-proxy won't add the proxy pod to the Service endpoints until lookups
// based on the cache are meaningful (i.e. no false-negative 403s on startup).
func (i *Index) Ready() bool {
	i.mu.RLock()
	defer i.mu.RUnlock()
	return i.ready
}

// Run starts a shared informer that populates the index. Blocks until ctx is done.
func (i *Index) Run(ctx context.Context) error {
	factory := informers.NewSharedInformerFactoryWithOptions(
		i.client,
		0, // no resync
		informers.WithNamespace(i.namespace),
		informers.WithTweakListOptions(func(opts *metav1.ListOptions) {
			// Require the label to be present; value is read at event time.
			// Do NOT field-select on status.podIP — the K8s watch wouldn't
			// emit a "now matches" event when a pod transitions from no-IP
			// to has-IP (it only notifies updates to objects that already
			// match), so newly-scheduled labelled pods would be missed.
			// The event handler skips pods with empty PodIP instead.
			opts.LabelSelector = i.labelKey
		}),
	)

	inf := factory.Core().V1().Pods().Informer()
	_, err := inf.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc:    func(obj any) { i.upsertFromObj(obj) },
		UpdateFunc: func(_, obj any) { i.upsertFromObj(obj) },
		DeleteFunc: func(obj any) { i.deleteFromObj(obj) },
	})
	if err != nil {
		return fmt.Errorf("add event handler: %w", err)
	}

	factory.Start(ctx.Done())
	if !cache.WaitForCacheSync(ctx.Done(), inf.HasSynced) {
		return fmt.Errorf("pod cache sync failed")
	}
	i.mu.Lock()
	i.ready = true
	i.mu.Unlock()
	slog.Info("identify: informer cache synced", "registered_pods", len(i.byPodIP))
	<-ctx.Done()
	return nil
}

func (i *Index) upsertFromObj(obj any) {
	pod, ok := obj.(*corev1.Pod)
	if !ok {
		return
	}
	id := pod.Labels[i.labelKey]
	if id == "" {
		slog.Debug("identify: pod has no playwright-id label", "pod", pod.Name)
		return
	}
	if pod.Status.PodIP == "" {
		slog.Info("identify: skipping labelled pod with no IP yet", "pod", pod.Name, "id", id)
		return
	}
	i.mu.Lock()
	i.byPodIP[pod.Status.PodIP] = id
	i.mu.Unlock()
	slog.Info("identify: registered pod", "ip", pod.Status.PodIP, "id", id, "pod", pod.Name)
}

func (i *Index) deleteFromObj(obj any) {
	pod, ok := obj.(*corev1.Pod)
	if !ok {
		// Tombstone case.
		if tomb, ok2 := obj.(cache.DeletedFinalStateUnknown); ok2 {
			pod, ok = tomb.Obj.(*corev1.Pod)
			if !ok {
				return
			}
		} else {
			return
		}
	}
	if pod.Status.PodIP == "" {
		return
	}
	i.mu.Lock()
	delete(i.byPodIP, pod.Status.PodIP)
	i.mu.Unlock()
}
