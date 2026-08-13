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
- [ ] BridgeData2 frames on Thor: `ssh thor "ls /var/lib/robot-sim/frames/"` (5 JPEGs)
- [ ] Action pool on Thor: `ssh thor "ls /var/lib/robot-sim/action_pool.json"`
- [ ] Dreamer at replicas=0 (only scale up in Act 3 after promotion)
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

### 1.3 Live Inference — Embodied Reasoning Mode

**Premise (state this explicitly):** Thor is a stationary edge inference node simulating a robot control loop. There is no physical arm. This is the stated and honest framing — the platform, model, and flywheel are all real; the robot is simulated.

```bash
# Embodied reasoning: image + instruction -> structured action plan
# Uses the pick_place BridgeData2 frame as visual conditioning
FRAME_B64=$(ssh thor "base64 -w0 /var/lib/robot-sim/frames/pick_place.jpg")

curl -X POST http://10.0.0.42:30800/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"nvidia/Cosmos3-Edge\",
    \"messages\": [{
      \"role\": \"user\",
      \"content\": [
        {\"type\": \"image_url\", \"image_url\": {\"url\": \"data:image/jpeg;base64,${FRAME_B64}\"}},
        {\"type\": \"text\", \"text\": \"Scene: A robotic arm must pick up an object from a tray and place it in the target position.\n\nYou are a robot arm controller. Examine the scene and output structured JSON with keys: action_strategy, confidence (0.0-1.0), reasoning, select_action ('good' or 'bad').\"}
      ]
    }],
    \"max_tokens\": 200,
    \"temperature\": 0.6
  }"
```

**Talk track:** "This is Cosmos3-Edge's Reasoner — not a text chatbot, a world model. It's receiving a real image from NVIDIA's BridgeData2 robot dataset as visual context, the same images our flywheel uses. It reasons about the physical scene and selects an action strategy. That reasoning quality is what the flywheel improves."

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

**Talk track:** "Robot-sim runs a 1 Hz control loop. Each tick sends a real BridgeData2 robot image to Cosmos3-Edge's Reasoner — image + scene instruction → structured action reasoning. The Reasoner picks between two real robot action trajectories: a physically-plausible one and a jerky one. The curator scores that selection — confidence, action smoothness, valid JSON output. Bad selections and injected failures never leave the device."

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
- Curator: `PASS <id> score=0.780 (clean: smoothness=0.07 conf=0.82 good=5/5)` scrolling
- Curator: `REJECT <id> score=0.050 (injected-failure)` for the 30% bad episodes
- Sync-agent: `[sync-agent] Uploaded <id> -> episodes-curated/<id>.json, manifest -> episode-manifests`
- MinIO console: curated bucket filling with episode JSON files
- Hub Kafka: `episode-manifests` consumer offset advancing

### 2.3 Prove the Gate

```bash
# Rejected episodes on device — never uploaded
ssh thor "ls /var/lib/episodes/rejected/ | wc -l"

# Only clean episodes in MinIO
ssh thor "ls /var/lib/episodes/sent/ | wc -l"
```

**Talk track:** "Two different counts. The injected-failure and low-confidence episodes stayed on the device — the curator caught them. Only episodes where the Reasoner produced valid, confident, smooth action selections made it to the hub. The flywheel is only as good as the data that feeds it."

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

## Act 3 — "Dream Before Deploy" + Promotion (~5 min)

**Story:** The pipeline produces a fine-tuned Reasoner, packages it, signs it, opens a PR. But before merging — we let the world model dream. After merging — the device upgrades without a reboot and dreams again. The two dreams are the quantitative evidence of flywheel improvement.

> [!NOTE]
> For time-compressed demos: pipeline `max_steps=50` (~5-8 min on L40S). The PR contains real
> Gate 1 reasoning-quality artifacts and Gate 2 dream URIs. Have pre-baked dream videos ready
> as a fallback if the live dreamer run takes longer than expected. Never show fake output.

### 3.0 Pre-Act: Generate the v1 "Before" Dream

**This runs BEFORE the promotion PR is merged** — it shows what the current model dreams.

```bash
# Scale the dreamer to process curated episodes with the v1 model
ssh thor "KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig \
  oc scale deployment dreamer -n flywheel --replicas=1"

# Watch the dreamer produce the v1 rollout video
ssh thor "KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig \
  oc logs -f deployment/dreamer -n flywheel"
```

Expected output:
```
[dreamer] Submitting Forward Dynamics job (domain=umi frames=17 steps=20)
[dreamer] Polling job <id>...
[dreamer] Job <id> completed in 2.6s
[dreamer] Downloaded rollout: 892KB
[dreamer] Uploaded dream: s3://eval-reports/dreams/<episode_id>-cosmos3-edge-v1.mp4
[dreamer] DREAM COMPLETE <episode_id> scene=pick_place model=cosmos3-edge-v1 mp4=892KB
```

**Stop the dreamer after the v1 dream is generated** (GPU must be free for vLLM):
```bash
ssh thor "KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig \
  oc scale deployment dreamer -n flywheel --replicas=0"
```

**Talk track:** "Cosmos3-Edge's Forward Dynamics mode takes a real robot image and a real action trajectory, and simulates what would happen. This is the 'dream before deploy' capability. We're about to promote a new model — let's see what the current model predicts first."

Show the v1 rollout MP4 from MinIO (download from `s3://eval-reports/dreams/*-v1.mp4`).

### 3.1 Show the Promotion PR

The KFP pipeline opens a PR automatically:

```bash
gh pr list --repo jeremyary/thor-testing
```

PR body contains:
- Gate 1: reasoning parse rate + good-selection rate (reasoning quality metrics)
- Gate 2: v1 dream URI + "v2 generated post-merge" placeholder
- Modelcar digest (by-digest, sigstore-signed)

**Talk track:** "The pipeline assessed the fine-tuned Reasoner on reasoning quality — how often it produces valid structured output, how often it selects the physically-plausible action. Gate 2 references the dream we just saw. Gate 3 is ours."

### 3.2 Merge and Watch Argo Sync

Merge from GitHub UI (or `gh pr merge --squash`).

```bash
oc get application vllm-cosmos3-thor -n openshift-gitops -w
```

On Thor:
```bash
ssh thor "KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig \
  oc get pods -n vllm -w"
```

Green pod starts → initContainer pulls new modelcar → CRI-O enforces `sigstoreSigned` → vLLM-Omni loads the SFT checkpoint. ~5 min model load time (single GPU, Recreate strategy).

### 3.3 The Selector Flips

```bash
oc get svc cosmos3-edge -n vllm -o jsonpath='{.spec.selector}'
# -> {"app":"cosmos3-edge","color":"green"}
curl http://10.0.0.42:30800/v1/models
```

**Talk track:** "Git merge. That's it. Argo synced the change through ACM's cluster-proxy — zero inbound connections — CRI-O verified the signature against our private RHTAS Rekor, and now port 30800 serves the fine-tuned model."

### 3.4 Generate the v2 "After" Dream — THE MONEY SHOT

```bash
# Update dreamer to use v2 model version label
ssh thor "KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig \
  oc set env deployment/dreamer -n flywheel MODEL_VERSION=cosmos3-edge-v2 && \
  oc scale deployment dreamer -n flywheel --replicas=1"

# Watch
ssh thor "KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig \
  oc logs -f deployment/dreamer -n flywheel"
```

Show the v2 rollout MP4 from MinIO. Compare side-by-side with the v1 dream.

**What to look for:** the fine-tuned Reasoner selects the physically-plausible action chunk more reliably (higher good_selections rate). The Forward Dynamics rollout shows a smoother, more purposeful arm trajectory because the action quality input is better.

```bash
# Scale dreamer back to 0
ssh thor "KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig \
  oc scale deployment dreamer -n flywheel --replicas=0"
```

**Talk track:** "Before: the model's action selection was mixed — 60% good picks. After: the flywheel trained it on the device's own curated experience, and the selection improved. The dream shows you what the robot would do with the new model — before you actually deploy it to a fleet. This is what 'dream before deploy' means in practice."

### 3.5 Reasoning Quality in Perses

Open Perses → "Reasoning Quality Step-Change by Model Version":
- **v1 panel** (left): reasoning spans for cosmos3-edge-v1 — baseline confidence and selection quality
- **v2 panel** (right): reasoning spans for cosmos3-edge-v2 — higher confidence, more consistent good selections

**Talk track:** "The quantitative evidence. Same world model. The flywheel improved how it reasons about physical scenes."

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
| Dreamer hung / no output | Scale to 0, check GPU is free (cosmos3-edge must not be serving), scale back to 1 |
| Dreamer: "Frame not found" | `ssh thor "ls /var/lib/robot-sim/frames/"` — re-scp if missing |
| v1/v2 dream looks the same | Expected for max_steps=50 (minimal training); use pre-baked videos from full run |
| Catastrophic failure | Switch to pre-recorded video |


| Catastrophic failure | Switch to pre-recorded video |
