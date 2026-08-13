# This project was developed with assistance from AI tools.

# Physical AI Edge Flywheel — Demo Runbook

> [!NOTE]
> This project was developed with assistance from AI tools.

~15-minute demo. Two screens: hub console/Perses (left), Thor terminal + output (right). Thor on the table with power meter inline.

> [!WARNING]
> **`combined-registry-auth` Secret expires 2026-09-11.** If running after that date, refresh it first:
> `oc create token pipeline --duration=720h -n thor-builds` and rebuild the combined secret per
> DEPLOYMENT_GUIDE.md § Registry Auth.

## Pre-Demo Checklist

**Hub-side (run from your laptop ~10 min before start)**

- [ ] Thor powered on, booted, MicroShift healthy (`oc get nodes` shows Ready on Thor's MicroShift)
- [ ] Combined-registry-auth Secret not expired (`oc get secret combined-registry-auth -n thor-builds`)
- [ ] Cosmos3-Edge model loaded and warm — `curl http://10.0.0.42:30800/v1/models` returns the model
- [ ] Flywheel workloads at replicas=0 (no GPU coil whine yet)
- [ ] **MirrorMaker2 running** — edge→hub episode replication is OFF by default (replicas=0). Scale it up:
  ```bash
  ssh root@thor "KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig \
    oc scale deployment mirrormaker2 -n flywheel --replicas=1"
  ```
- [ ] Manifest-consumer running in vla-training: `oc get pod -n vla-training -l app=manifest-consumer`
- [ ] DSP UI accessible: `oc get route -n vla-training | grep ds-pipeline`
- [ ] Hub Kafka topic ready: `oc get kafkatopic episode-manifests -n fleet-ops`
- [ ] **Blue vLLM pod is the active side**: `oc get svc cosmos3-edge -n vllm -o jsonpath='{.spec.selector}'` → should show `color:blue`
- [ ] Green deployment at replicas=0: `oc get deployment cosmos3-edge-green -n vllm -o jsonpath='{.spec.replicas}'` → `0`
- [ ] Stale pods pre-cleared: `oc delete pod -n vllm --field-selector status.phase!=Running 2>/dev/null || true`
- [ ] OCP console tabs open: ACM cluster view, Edge Management, Argo CD, DSP (vla-training)
- [ ] Perses dashboard open: model.version v1 panel (blank until flywheel runs)
- [ ] MinIO console open: `episodes-curated` bucket
- [ ] Kafka consumer view open (Argo CD UI or Kafka console)
- [ ] Terminal SSH sessions ready: `ssh thor` (all terminals pre-connected)
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

**Story:** The device generates training data, curates it on-device, pushes to the hub, and trips the training pipeline — with GPU nodes scaling from zero.

### 2.1 Start the Flywheel

```bash
ssh thor "KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig \
  oc scale deployment robot-sim curator sync-agent -n flywheel --replicas=1"
```

**Talk track:** "Robot-sim runs a 1 Hz control loop — each tick calls Cosmos3-Edge, records the action plan. Curator scores every episode on-device. Sync-agent batches curated episodes to the hub. Rejects never leave."

### 2.2 Watch the On-Device Pipeline

Split terminal view:
```bash
# Terminal 1: curator decisions scrolling (PASS / REJECT visible)
ssh thor "KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig \
  oc logs -f deployment/curator -n flywheel"

# Terminal 2: sync-agent uploads + Kafka publish
ssh thor "KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig \
  oc logs -f deployment/sync-agent -n flywheel"
```

Show:
- Curator PASS/REJECT decisions (planted 30% failure rate)
- Sync-agent: `[sync-agent] Uploaded <id> -> episodes-curated/<id>.json, manifest -> episode-manifests`
- MinIO console: curated bucket filling up
- Hub Kafka: `episode-manifests` consumer offset advancing (via Argo CD or `oc exec`)

### 2.3 Prove the Gate

```bash
# Rejected episodes on device — never uploaded
ssh thor "ls /var/lib/episodes/rejected/ | wc -l"

# Only clean episodes in MinIO
ssh thor "ls /var/lib/episodes/sent/ | wc -l"
```

**Talk track:** "Two different counts. The rejected ones stayed on the device. That's on-device intelligence as a data flywheel gate."

### 2.4 Hub Manifest Consumer Hits Threshold

Watch the hub-side consumer in vla-training:
```bash
oc logs -f deployment/manifest-consumer -n vla-training
```

Expected output (after 10 curated episodes):
```
[consumer] Received episode abc123 (score=1.0) [8/10]
[consumer] Received episode def456 (score=1.0) [9/10]
[consumer] Received episode ghi789 (score=1.0) [10/10]
[consumer] TRIGGER #1: threshold reached (10 curated episodes) -- initiating training pipeline
[consumer] Published training-trigger event -> training-triggers
[consumer] DSP run created: <run_id>
```

### 2.5 GPU Scales from Zero (requires L40S machinepool)

Switch to the DSP UI (vla-training):
- Show the `cosmos3-edge-finetune` pipeline run in "Running" state
- The `finetune-cosmos3` step is pending Kueue admission → GPU node is 0

```bash
# Watch nodes scale (takes ~3-4 min for EC2 instance to join)
watch oc get nodes -l nvidia.com/gpu=true
# Watch Kueue admit the workload
oc get workloads -n vla-training
```

**Talk track:** "No GPU nodes exist right now. Kueue is holding the finetune pod. The cluster autoscaler sees the pending workload and spins up an L40S node. Cost is zero until inference is needed."

Show the node appear: `STATUS: Ready, INSTANCE: g6.xlarge`

The remaining pipeline steps (eval, package, sign, PR) run automatically.

### 2.6 Stop the Flywheel

```bash
ssh thor "KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig \
  oc scale deployment robot-sim curator sync-agent -n flywheel --replicas=0"
```

---

## Act 3 — Model Promotion (~4 min)

**Story:** The pipeline produces a better checkpoint, packages it, signs it, and opens a PR. Merge → the device upgrades without a reboot.

> [!NOTE]
> For time-compressed demos: pipeline's `max_steps=50` produces a quick run. The PR shown contains
> real Gate 1 artifacts. Have the "real pre-completed" eval report pre-baked as a fallback if the
> live run hasn't finished — never show fake output, just compressed time.

### 3.1 Show the Promotion PR

After the KFP pipeline completes, a PR is automatically opened against this repo:

- PR title: `[promote] cosmos3-edge v2`
- PR body: Gate 1 eval table (loss, val pass-rate), modelcar digest by-digest
- Files changed: `gitops/vllm-cosmos3/deployment-green.yaml` (updated modelcar digest + MODEL_VERSION=v2)

```bash
# From your laptop:
gh pr list --repo jeremyary/thor-testing
```

**Talk track:** "The pipeline did this. No human assembled the PR. The eval artifacts are real. Gate 3 is ours — we review and merge."

### 3.2 Merge and Watch Argo Sync

Merge the PR from the GitHub UI (or `gh pr merge --squash`).

```bash
# Watch Argo pick it up
oc get application vllm-cosmos3-thor -n openshift-gitops -w
```

Argo syncs `deployment-green.yaml`. On the device:
```bash
ssh thor "KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig \
  oc get pods -n vllm -w"
```

The green initContainer pulls the new modelcar:
- CRI-O enforces `sigstoreSigned` policy — signature verified before pull
- Modelcar copy to `/root/.cache/huggingface` completes
- vLLM-Omni starts with the new checkpoint

### 3.3 The Selector Flips

The same PR set `deployment.yaml` replicas=0 (blue goes dark) and `service.yaml` selector=green. Confirm:
```bash
oc get svc cosmos3-edge -n vllm -o jsonpath='{.spec.selector}'
# -> {"app":"cosmos3-edge","color":"green"}

# Port 30800 now routes to v2
curl http://10.0.0.42:30800/v1/models
```

### 3.4 Before/After in Perses

Open the Perses dashboard — "Model Version Promotion" section:
- **v1 panel** (left): existing control-tick traces, MODEL_VERSION=cosmos3-edge-v1
- **v2 panel** (right): new traces starting now, MODEL_VERSION=cosmos3-edge-v2

Re-run the Act 1 inference request and compare response quality.

**Talk track:** "Same prompt. Different model. The difference is what the flywheel trained on — data generated by THIS device, curated by THIS model, promoted through THIS pipeline. It's self-improving."

---

## Stinger — Trust and Rollback (~2 min)

**Story:** The policy is real. Try to push an unsigned model — it gets refused. Git revert walks it back.

### Unsigned model refused

```bash
# Pull a model tag without signing it, try to force it onto the device
# (update deployment-green.yaml to an unsigned image digest)
# Argo syncs → CRI-O tries to pull → FAILS with:
#   "SignatureMissing: A signature was required, but no signature exists"
ssh thor "KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig \
  oc describe pod -n vllm -l color=green | grep -A5 Events"
```

### Git revert rolls the model back — no reboot

```bash
cd ~/redhat/git/thor-testing
git revert HEAD --no-edit
git push
```

Argo syncs → green goes back to the previous (signed, valid) modelcar → pod recovers → selector stays green → service restored. **No bootc switch, no reboot.**

---

## Disconnect Tolerance (Bonus — ~1 min)

```bash
# Pull Thor's uplink mid-run
ssh thor "ip link set enP2p1s0 down"
# Flywheel runs briefly — OTel collector spools to NVMe
# Restore
ssh thor "ip link set enP2p1s0 up"
# Watch telemetry backfill in Tempo/Perses — traces appear with past timestamps
```

---

## Failure Recovery

| Problem | Fix |
|---------|-----|
| Cosmos3-Edge not responding | `ssh thor "KUBECONFIG=... oc delete pod -n vllm -l app=cosmos3-edge"` — wait 5 min |
| GPU compute failure (error 100) | `ssh thor "systemctl restart nvidia-gpu-reset"` |
| MicroShift not starting | `ssh thor "systemctl restart microshift"` — wait 2 min |
| Thor unreachable | Power cycle, wait 3 min for boot + GPU reset + MicroShift |
| Argo not syncing | `oc annotate application <app> -n openshift-gitops argocd.argoproj.io/refresh=hard` |
| Flywheel won't stop | `ssh thor "KUBECONFIG=... oc scale deployment robot-sim curator sync-agent -n flywheel --replicas=0"` |
| MirrorMaker2 not running | `ssh thor "KUBECONFIG=... oc scale deployment mirrormaker2 -n flywheel --replicas=1"` |
| DSP run won't start | Check `oc logs deployment/manifest-consumer -n vla-training` — TRAINING_PIPELINE_ID must be set |
| No GPU node appears | L40S machinepool must exist + autoscaler enabled; confirm with `oc get machinesets` |
| Blue/green: wrong side active | `oc get svc cosmos3-edge -n vllm -o jsonpath='{.spec.selector}'` — flip via git commit if wrong |
| Stale UnexpectedAdmissionError pods | `oc delete pod -n vllm --field-selector status.phase!=Running` |
| Catastrophic failure | Switch to pre-recorded video |

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
