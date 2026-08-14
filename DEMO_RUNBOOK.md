# This project was developed with assistance from AI tools.

# Physical AI Edge Flywheel — Demo Runbook

> [!NOTE]
> This project was developed with assistance from AI tools.

Quick recording showcasing the full stack. Dashboard-driven — minimal terminal. ~10-12 minutes.

> [!WARNING]
> **`combined-registry-auth` Secret expires 2026-09-11.** Refresh before demo if needed.

## Pre-Demo (5 min before recording)

```bash
# Thor up and serving
curl -s http://10.0.0.42:30800/v1/models | python3 -m json.tool

# MirrorMaker2 running (edge->hub replication)
ssh thor "KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig \
  oc scale deployment mirrormaker2 -n flywheel --replicas=1"

# Manifest consumer running on hub
oc get pod -n vla-training -l app=manifest-consumer

# Dashboard open
open http://10.0.0.42:30801
```

Hit **Clear Data** on the dashboard for a fresh start.

Have these tabs ready: dashboard (primary), Argo CD, DSP pipeline UI, GitHub PR page.

---

## Part 1 — The Platform (~2 min)

Quick tour. Don't linger — the dashboard is the star.

**Argo CD** — show three apps synced: `vllm-cosmos3-thor`, `edge-workloads-thor`, `flywheel-thor`. "Everything on this device is GitOps-delivered through a cluster-proxy tunnel. Zero inbound connections."

**Terminal** (brief):
```bash
ssh thor "bootc status --format=human | head -5"
```
"Derived bootc image. Transactional OS updates with rollback. MicroShift, GPU reset service, OTel collector — all baked in."

**Dashboard** — point at the model badge: `cosmos3-edge-v1`. "Cosmos3-Edge is NVIDIA's 4-billion parameter omnimodal world model — a Mixture-of-Transformers that jointly generates video, images, audio, and robot action commands. It's running right here on this Jetson Thor."

---

## Part 2 — The Flywheel (~4 min)

This is all dashboard. Click **Start Flywheel**.

**What happens on screen:**
- The flywheel-running indicator lights up green
- Scene/Frame panel populates with a real 256×256 BridgeData2 robot image (WidowX arm on a tabletop)
- Generator Output panel shows:
  - A **looping video clip** — the model imagining the scene in motion from the conditioning frame
  - **Image→Video** stats: status, clip size (~200KB), latency (~2.5s)
  - **Action Policy** stats: status, chunk size (16 joint-position steps), smoothness score
  - Curation verdict pill: green (pass) or red (reject)
- Curation Log fills with entries — green PASS rows and red REJECT rows
- Progress bar advances toward the training trigger (10 curated episodes)

**Talk track as it runs:**

"Each cycle, two things happen. First — Image-to-Video: the model takes this real robot frame and generates a short video clip predicting what the scene looks like in motion. Second — Action Policy: the model predicts the next 16 steps of 7-DOF joint positions for the robot arm.

The curator scores both on-device. Watch the curation log — green means the generation was coherent and the predicted action trajectory was smooth. Red means it was caught. Those red episodes never leave the device. Only quality data flows to the hub.

Thirty percent of episodes are deliberately injected failures — bad action trajectories. The curator catches them every time. The flywheel is only as good as the data that feeds it."

Point at the progress bar: "When 10 curated episodes reach the hub via Kafka, the manifest consumer triggers the training pipeline."

**When the progress bar fills**, switch briefly to the **DSP pipeline UI** to show the `cosmos3-edge-finetune` run starting. "The pipeline downloads NVIDIA's BridgeData2 training dataset, runs their real Vision SFT recipe — `launch_sft_vision_edge.sh` — on a single L40S GPU. Real loss, real gradients, real checkpoint. This isn't a stub."

Click **Stop Flywheel** on the dashboard.

---

## Part 3 — Dream Before Deploy (~3 min)

Back on the dashboard. Scroll to the **Dream Before Deploy** panel.

"Before we promote the fine-tuned model, let's see what the current model predicts. Forward Dynamics takes a real robot image and a real action trajectory — 16 steps of joint positions — and the world model computes what would happen. No physics engine. Pure learned understanding."

Click **Dream v1**. Wait for the rollout video to appear (~3-6s on Thor).

"That's the baseline. Now let's promote the new model and see if the flywheel improved it."

### Show the PR

Switch to GitHub. Show the auto-opened PR:
- Training loss from the real Vision SFT run
- Signed modelcar digest
- Dream comparison placeholders

"The pipeline assessed the training, packaged the checkpoint into a signed OCI artifact, and opened this PR. Gate 3 is ours."

**Merge the PR.** Switch to Argo CD briefly — show the sync starting. "Git merge → Argo syncs → green pod starts → CRI-O verifies the sigstore signature → port 30800 now serves the fine-tuned model. No reboot."

Wait for the model badge on the dashboard to flip to `cosmos3-edge-v2` (~5 min for model load — can narrate or fast-forward in recording).

Click **Dream v2**. Compare side-by-side with v1.

"Same frame, same action trajectory. Different model. The flywheel trained the Generator on robot manipulation data, and the prediction changed. This is what 'dream before deploy' means — you see the difference before it touches a fleet."

---

## Part 4 — Trust (Optional, ~1 min)

"One more thing. What if someone pushes an unsigned model?"

Show terminal briefly:
```bash
# Point deployment-green at an unsigned digest → Argo syncs → CRI-O refuses
ssh thor "KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig \
  oc describe pod -n vllm -l color=green | grep -A2 SignatureMissing"
```

"SignatureMissing. The policy is real. Git revert, Argo syncs back, service restored. No reboot."

---

## What's Real (know this if asked)

**Real, running, genuine:** Cosmos3-Edge (4B) on the actual Thor T5000 • Image-to-Video + Action Policy + Forward Dynamics via documented endpoints • on-device curation with injected failure detection • edge→hub Kafka pipeline • NVIDIA's real cosmos-framework Vision SFT on a single L40S (empirically confirmed) • sigstore signing + RHTAS Rekor • GitOps blue/green promotion

**Simulated:** No physical robot arm — robot-sim uses BridgeData2 frames and a pre-built action pool. Training data is NVIDIA's reference BridgeData2 subset, not the flywheel's own generated episodes. Be upfront about both.

---

## Failure Recovery

| Problem | Fix |
|---------|-----|
| Cosmos3-Edge not responding | Delete the vLLM pod, wait 5 min for reload |
| Dashboard not updating | Delete dashboard pod: `oc delete pod -n flywheel -l app=dashboard` |
| Generated video not showing | Verify `latest_generated.mp4` exists in robot-sim pod |
| Dream button does nothing | Check dreamer logs; GPU may be contended with vLLM |
| Flywheel buttons unresponsive | Refresh the dashboard page; check dashboard pod logs |
| Pipeline not triggering | Check manifest-consumer logs; verify TRAINING_PIPELINE_ID is set |
| No GPU node for training | L40S machinepool must exist with autoscaler enabled |
| v1/v2 dreams look similar | Expected for short training runs; use pre-baked videos from a longer run |
| Catastrophic failure | Switch to pre-recorded video |
