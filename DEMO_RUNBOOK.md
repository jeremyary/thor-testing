# This project was developed with assistance from AI tools.

# Physical AI Edge Flywheel — Demo Runbook

> [!NOTE]
> This project was developed with assistance from AI tools.

~15-minute demo. Two screens: hub console/Perses (left), Thor terminal + output (right). Thor on the table with power meter inline.

## Pre-Demo Checklist

- [ ] Thor powered on, booted, MicroShift healthy (`oc get nodes` shows Ready)
- [ ] Cosmos3-Edge model loaded and warm (check `curl http://thor:30800/v1/models`)
- [ ] Flywheel workloads scaled to 0 (no GPU coil whine)
- [ ] OCP console open: ACM cluster view, Edge Management, Argo CD
- [ ] Tempo/tracing UI accessible
- [ ] MinIO console open (episodes-curated bucket)
- [ ] Kafka topic `episode-manifests` visible
- [ ] Terminal SSH sessions ready: `ssh root@thor`
- [ ] Fallback: full-run video recording available

### Warm-Up Commands (run 5 min before demo)

```bash
# Verify MicroShift
ssh root@thor "KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig oc get nodes; oc get pods -A --no-headers | grep -v Completed | wc -l"

# Verify Cosmos3-Edge is serving
curl -s http://thor:30800/v1/models | python3 -m json.tool

# Verify hub connectivity
ssh root@thor "curl -sk https://otlp-http-edge-gateway-route-observability.apps.g4h4d3j7q1c9f7m.cimo.p1.openshiftapps.com/v1/traces -o /dev/null -w '%{http_code}'"

# Clear old episode data
ssh root@thor "rm -rf /var/lib/episodes/raw/* /var/lib/episodes/curated/* /var/lib/episodes/rejected/* /var/lib/episodes/sent/*"
```

---

## Act 1 — The Managed Brain (~4 min)

**Story:** Thor is a managed edge device. Show the management stack, then demonstrate inference.

### 1.1 Show the Management Stack

1. **ACM console** → Infrastructure → Clusters → `thor`
   - Show: Joined, Available, labels (environment: edge, device: jetson-thor)
   - Show: Addons running (application-manager, cluster-proxy, work-manager)

2. **Edge Management (RHEM)** → Devices → `thor`
   - Show: Enrolled, lifecycle status, system info
   - Show: Fleet management capability

3. **Argo CD** → Applications
   - Show: `vllm-cosmos3-thor`, `edge-workloads-thor`, `flywheel-thor` — all Synced/Healthy
   - Point: "Everything on this device is GitOps-delivered through ACM's cluster-proxy tunnel. Zero inbound connections."

### 1.2 Show the Device OS

```bash
ssh root@thor
bootc status  # shows derived image layers
systemctl status microshift flightctl-agent opentelemetry-collector nvidia-gpu-reset
```

**Talk track:** "The device runs a derived bootc image — our layer on top of the sidecar team's CentOS Stream 10 Thor image. MicroShift, flightctl-agent, OTel collector, GPU reset service — all baked in. OS updates are transactional with automatic rollback."

### 1.3 Live Inference

```bash
# Generator mode — predicted rollout video
curl -X POST http://thor:30800/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "nvidia/Cosmos3-Edge",
    "messages": [{"role": "user", "content": "A humanoid robot picks up a red box from a shelf and places it on a conveyor belt"}],
    "max_tokens": 100
  }'
```

**Talk track:** "This is Cosmos3-Edge — a 4B omni-modal world foundation model running on the Thor's Blackwell GPU. No camera — it shows you what it *believes* will happen. This is the model that the flywheel trains."

### 1.4 Resilience Demo (Optional)

```bash
# Kill MicroShift mid-inference
ssh root@thor "systemctl stop microshift"
# Inference completes (vLLM runs in the container, not in the control plane)
# MicroShift recovers
ssh root@thor "systemctl start microshift"
```

Show ACM: cluster blips to Unknown, then recovers to Available.

---

## Act 2 — The Flywheel Turns (~5 min)

**Story:** The device generates training data, curates it on-device, and pushes to the hub.

### 2.1 Start the Flywheel

```bash
ssh root@thor "KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig oc scale deployment robot-sim curator -n flywheel --replicas=1"
```

**Talk track:** "The robot-sim replays control loop ticks at 1 Hz, calling Cosmos3-Edge each tick. The curator scores every episode — bad ones never leave the device."

### 2.2 Watch the Pipeline

Split terminal view:
```bash
# Terminal 1: curator decisions
ssh root@thor "KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig oc logs -f deployment/curator -n flywheel"

# Terminal 2: sync-agent uploads
ssh root@thor "KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig oc logs -f deployment/sync-agent -n flywheel"
```

Show:
- Curator PASS/REJECT decisions scrolling (planted rejects visible)
- Sync-agent uploading to MinIO, publishing to Kafka
- MinIO console: episodes appearing in `episodes-curated` bucket
- Kafka topic: manifests arriving

### 2.3 Prove the Gate

```bash
# Show rejected episodes stayed on device
ssh root@thor "ls /var/lib/episodes/rejected/"

# Show only clean episodes reached MinIO
ssh root@thor "ls /var/lib/episodes/sent/"
```

**Talk track:** "The 30% failure-injected episodes were caught by the on-device curator and never left. Only quality data reaches the hub. This is bandwidth savings and data hygiene at the edge."

### 2.4 Stop the Flywheel

```bash
ssh root@thor "KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig oc scale deployment robot-sim curator -n flywheel --replicas=0"
```

---

## Act 3 — Trust and Observability (~4 min)

**Story:** Everything is signed, verified, and observable.

### 3.1 Trust Plane

Show RHTAS:
- Rekor search UI: `rekor-search-ui-trusted-artifact-signer.apps.<cluster>`
- Show the Rekor transparency log entry for the signed bootc image

Show device policy (both files are required — D018/D019):
```bash
ssh root@thor "cat /etc/containers/policy.json"
# sigstoreSigned rule for internal-registry — declares WHAT to require
ssh root@thor "cat /etc/containers/registries.d/internal-registry.yaml"
# use-sigstore-attachments: true — tells containers/image WHERE to find the signature
# Both CRI-O (workload pulls) and bootc (OS image pulls) enforce this identically
```

### 3.2 Telemetry

Show OTel data flowing:
- Tempo UI: traces from robot-sim → Cosmos3-Edge inference
- Host metrics: CPU, memory, GPU utilization
- Journald logs: MicroShift, CRI-O events

**Talk track:** "The OTel collector runs as a systemd service — not a Kubernetes workload. It has host-level access to everything: journald, GPU telemetry, host metrics. When the device is disconnected, telemetry spools to NVMe and drains when connectivity returns."

### 3.3 Disconnect Tolerance (Optional)

```bash
# Pull the uplink
ssh root@thor "ip link set enP2p1s0 down"
# Run flywheel briefly — telemetry spools
# Restore
ssh root@thor "ip link set enP2p1s0 up"
# Watch telemetry backfill in Tempo
```

---

## Stinger — GitOps in Action (~2 min)

**Story:** A git commit changes the device. No SSH, no manual intervention.

```bash
# From your laptop — change a workload parameter
cd ~/redhat/git/thor-testing
# Edit gitops/edge-workloads/smoke-test.yaml — change a value
git commit -am "Live demo: GitOps workload update"
git push
```

Watch Argo sync → show the change on Thor:
```bash
ssh root@thor "KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig oc get configmap edge-smoke-test -n edge-demo -o jsonpath='{.data}'"
```

**Talk track:** "Git push to GitHub, Argo picks it up, syncs through ACM's cluster-proxy to Thor. Zero inbound connections. That's how you manage a fleet of robot brains."

---

## Failure Recovery

| Problem | Fix |
|---------|-----|
| Cosmos3-Edge not responding | `ssh root@thor "KUBECONFIG=... oc delete pod -n vllm -l app=cosmos3-edge"` — wait 5 min for model reload |
| GPU compute failure (error 100) | `ssh root@thor "systemctl restart nvidia-gpu-reset"` |
| MicroShift not starting | `ssh root@thor "systemctl restart microshift"` — wait 2 min |
| Thor unreachable | Power cycle, wait 3 min for boot + GPU reset + MicroShift |
| Argo not syncing | `oc patch application.argoproj.io <app> -n openshift-gitops --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'` |
| Flywheel won't stop (coil whine) | `ssh root@thor "KUBECONFIG=... oc scale deployment robot-sim curator -n flywheel --replicas=0"` |
| Catastrophic failure | Switch to pre-recorded video |
