# This project was developed with assistance from AI tools.

# Physical AI Edge Flywheel — Demo Runbook

> [!NOTE]
> This project was developed with assistance from AI tools.

Two ways to run this:
- **Short Cut (~4-5 min)** — targeted internal recording. Pinned dream pair,
  no waiting on a live model flip. Use this for stakeholder/BU walkthroughs
  where the goal is "show me what it looks like" without tune-out. **Start here.**
- **Full Live Demo (~10-12 min)** — the complete live end-to-end (flywheel to
  10 episodes → real training → PR merge → live blue/green flip → live dreams).
  The legitimate path, kept intact below the short cut.

---

## Short Cut — Targeted Internal Recording (~4-5 min)

Goal: show internal stakeholders **what the flywheel looks like** — real model
on real hardware, on-device curation, and the "dream before deploy" v1-vs-v2
comparison — without the 5-minute live model-load wait. The dream videos are the
**pre-baked, curated comparison pair** from the real 500-iter Vision SFT run
(reproduction command below), played instantly by the dashboard buttons. Every
other thing on screen is live.

### Pre-record (2 min)
```bash
# Thor serving the promoted (v2) model
curl -s http://10.0.0.42:30800/v1/models | python3 -m json.tool   # HTTP 200
# Dashboard up
open http://10.0.0.42:30801
```
Do **NOT** hit Clear Data — the pinned dream files are immutable and survive it,
but skip it to keep the panel populated. Have two tabs ready: dashboard
(primary) and Argo CD (one 20-second cutaway).

### Beat 1 — "It's real, on the device" (~45s)
Point at the dashboard model badge: **`cosmos3-edge-v2-500iter-graft`**.
"This is NVIDIA's Cosmos3-Edge — a 4-billion-parameter omnimodal world model —
running on a Jetson Thor on my desk. Not a cloud endpoint. The whole stack is
GitOps-delivered; zero inbound connections to the device."
(Optional 20s Argo cutaway: three apps synced.)

### Beat 2 — "The flywheel curates on-device" (~90s)
Click **Start Flywheel**. Let it run ~4-5 cycles (don't wait for the full 10).
"Each cycle the model does two things from a real robot frame: generates a
short Image-to-Video clip, and predicts the next 16 steps of arm joint
positions. The curator scores both **on the device** — green passes, red is
caught and never leaves. ~30% are deliberately injected failures; the curator
catches them." Click **Stop Flywheel**.

### Beat 3 — "Dream before deploy" — the money shot (~90s)
Scroll to **Dream Before Deploy**. Click **Dream v1**, then **Dream v2** — both
play **instantly** (pinned pair, same 256×256 conditioning frame, same seed,
same 16-step action trajectory — only the model differs).
"Same frame, same action trajectory, different model. Forward Dynamics — the
world model computes what the arm *would* do, no physics engine. The left is the
baseline; the right is after the flywheel's fine-tuning. You see the difference
**before** it touches a fleet. That's dream-before-deploy."

### Beat 4 — "And it's governed" (~30s, optional)
"Promotion is a signed-modelcar + GitOps blue/green flip — merge a PR, Argo
syncs, CRI-O verifies the sigstore signature before the model ever loads. The
full live version of that flip is in the long-form demo."

> **Why pinned for the recording:** the dream pair is pre-generated from the real
> 500-iter Vision SFT model so the recording is deterministic and fast (no
> per-run seed variance, no 5-min live model load). They are genuine model
> outputs. Reproduce either side exactly with `gen_dream_fixed.py` (256×256,
> seed 42, pick_place frame + action chunk) against the base or grafted-v2
> deployment — see § Reproducing the Pinned Dreams. The live generation path
> remains fully available in the Full Live Demo below.

---

Full live version below. Dashboard-driven — minimal terminal. ~10-12 minutes.

> [!NOTE]
> The `combined-registry-auth` Secret (thor-builds) holds a time-limited registry
> token. If a build/push fails with a 401, refresh it per DEPLOYMENT_GUIDE.md
> § Registry Auth. Verify the embedded token's expiry with:
> `oc get secret combined-registry-auth -n thor-builds -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d`

## Full Live Demo (~10-12 min)

### Pre-Demo (5 min before recording)

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

Click **Dream v1**. The rollout video appears **instantly** — the buttons play
the pinned, curated comparison pair (see § Reproducing the Pinned Dreams), not a
live GPU run. If you want a genuinely-live rollout instead, scale the dreamer at
256×256 (see the resolution note below) — but for a clean recording, pinned is
deterministic.

"That's the baseline. Now let's promote the new model and see if the flywheel improved it."

### Show the PR

Switch to GitHub. Show the auto-opened PR:
- Training loss from the real Vision SFT run
- Signed modelcar digest
- Dream comparison (the pinned v1/v2 pair shown on the dashboard)

"The pipeline assessed the training, packaged the checkpoint into a signed OCI artifact, and opened this PR. Gate 3 is ours."

**Merge the PR.** Switch to Argo CD briefly — show the sync starting. "Git merge → Argo syncs → green pod starts → CRI-O verifies the sigstore signature → port 30800 now serves the fine-tuned model. No reboot."

Wait for the model badge on the dashboard to flip to `cosmos3-edge-v2-500iter-graft`
(~5 min for model load — **narrate or fast-forward in recording**; this is the
single longest wait in the live path, which is why the Short Cut skips it).

Click **Dream v2**. Compare side-by-side with v1 (both play instantly — pinned pair).

"Same frame, same action trajectory. Different model. The flywheel trained the Generator on robot manipulation data, and the prediction changed. This is what 'dream before deploy' means — you see the difference before it touches a fleet."

---

## Reproducing the Pinned Dreams

The dashboard's **Dream v1/v2** buttons play a pinned, curated pair on Thor at
`/var/lib/dreams/zzz-showcase-cosmos3-edge-v{1,2}.mp4` (immutable via `chattr +i`,
sort-last names so they always win the dashboard's `_dreams()` pick, and survive
Clear Data + pod restarts). Both are genuine model outputs at **256×256, seed 42**,
from the `pick_place` BridgeData2 frame + the `good` 16-step action chunk.

- **v1** = base (untuned) modelcar `sha256:5c990c93…` → snapshot `2a00e87e…`
- **v2** = grafted 500-iter Vision-SFT modelcar `sha256:69da94f2…` → snapshot `bfaf37f2…`
  (Vision-SFT `moe_gen` improvements + base action modules grafted back in — see
  DECISIONS.md D034)

To regenerate either side identically: deploy that model to green, then run
`gen_dream_fixed.py <tag>` on Thor (points at the green clusterIP, forward-dynamics,
256×256, seed 42). Both snapshots are staged on Thor's hostPath under
`/var/lib/models/huggingface/hub/models--nvidia--Cosmos3-Edge/snapshots/` so a
base⇄v2 swap needs no re-pull.

> **Resolution note (important):** generate dreams at **256×256** to match the
> BridgeData2 conditioning frame. The dreamer's default `size=320x192` produces
> visibly degraded, temporally-incoherent rollouts on these square frames — the
> pinned pair uses 256×256 for this reason.

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

**Simulated / pre-baked:** No physical robot arm — robot-sim uses BridgeData2 frames and a pre-built action pool. Training data is NVIDIA's reference BridgeData2 subset, not the flywheel's own generated episodes. The **dream v1/v2 videos are pre-generated** (genuine model outputs from the base and the real 500-iter grafted-v2 models, 256×256/seed 42) and played from a pinned pair for a deterministic recording — the live generation path remains available. Be upfront about all three.

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
| v1/v2 dreams look similar | Use the pinned pair (default); it's from the real 500-iter run. Do NOT live-generate at 320×192 — that degrades quality. See § Reproducing the Pinned Dreams |
| Dream buttons play nothing | Pinned files must exist + be immutable on Thor `/var/lib/dreams/zzz-showcase-*.mp4`; dashboard reads them via `_dreams()`. Restart dashboard pod if the configmap changed |
| Catastrophic failure | Switch to pre-recorded video |
