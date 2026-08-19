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

### The story you're telling (read this first)

> **"A governed, self-improving lifecycle for Physical AI at the edge — built on
> Red Hat's platform."**
>
> A Jetson Thor runs a real world model. It watches itself work, throws out the
> bad attempts *on the device*, ships only the good data to the cluster, which
> retrains, signs, and promotes a better model back — and you can *see* the
> improvement before it's ever deployed to a fleet. **The model is NVIDIA's; the
> loop that makes it deployable, improvable, and governed is the story.** That's
> the flywheel.
>
> Six beats tell that arc: **(1)** why this exists (the edge lifecycle problem) →
> **(2)** the device curates its own data on-device → **(3)** the platform triggers
> retraining and produces a signed candidate → **(4)** you can measure it →
> **(5)** you can *see* the improvement before deploying → **(6)** every promotion
> is signed and GitOps-governed. Training is one orchestrated step in that loop —
> not the point; the *enablement* is.
>
> **The one honest shortcut:** real model training takes ~30 minutes and a model
> hot-swap takes ~5, which nobody wants to watch. So we run the *live* parts live
> (the model, on-device curation, the governed promotion), and for the training
> step we show the **real artifacts a real run already produced** (the pipeline's
> PR, the tracked metrics, the before/after prediction videos). Nothing is faked —
> it's time-compressed.

### Prerequisites — what you need before recording

- **Access:** you can `ssh thor` and you're `oc login`'d to the hub cluster.
- **Device is in the clean start state** (verify — see next block). It should be
  serving **v1** (the *baseline* model), flywheel idle, counts at zero.
- **A real promotion PR to show** — GitHub PR
  [#3 on jeremyary/thor-testing](https://github.com/jeremyary/thor-testing/pull/3)
  (a genuine merged `[promote] cosmos3-edge` PR from an earlier real run). You'll
  show it as the artifact the pipeline produced. Any merged `promote/cosmos3-edge-v2`
  PR works.
- **~4-5 minutes** and a screen recorder.

### Setup — verify state and open your tabs (2 min)

```bash
# 1. Confirm the device is serving the BASELINE (v1) model, idle and clean:
ssh thor 'curl -s http://10.0.0.42:30801/api/status | python3 -m json.tool' \
  | grep -E 'model_version|flywheel_running|"sent"'
#   expect: "model_version": "cosmos3-edge-v1", "flywheel_running": false, "sent": 0
#   If it says v2 or has counts > 0, the device isn't in start state -- see
#   "Reset to start state" at the end of this section before recording.
```

Open **four browser tabs**, in this left-to-right order (you'll move through them
in sequence — the demo never jumps around):

1. **Dashboard** (your main screen): `http://10.0.0.42:30801` — used in Beats 1, 2, 5
2. **The PR** (Beat 3): the merged promotion PR above
3. **Experiment tracking (MLflow)** (Beat 4): RHOAI console → **Experiments** →
   `cosmos3-edge-wam-flywheel`. If you're new to MLflow, read
   **§ MLflow, in plain language** once — it's the "training results" screen.
   Pre-select the two runs `v1-base` and `v2-500iter-graft` and click **Compare**.
4. **Argo CD** (optional — Beat 1 cutaway & Beat 6): the `flywheel-thor` app, Synced.

> Leave the dashboard on its default view. Do **not** click **Clear Data** during
> setup — the before/after prediction videos are pinned and you want them ready.

---

### Beat 1 — "Why this exists" (~45s)

**Screen:** you, or a title slide — *not* the empty dashboard yet. Set the frame
before showing anything on screen.

> "Physical AI — robots, autonomous machines — is moving to the edge, where the
> hard problem isn't the model, it's everything *around* it: how do you get a model
> onto a fleet of devices safely, watch how it does in the real world, improve it
> from that experience, and roll the better version back out — without ever
> shipping something unsigned or un-governed to a machine that moves in the
> physical world?
>
> That lifecycle is what we've built on Red Hat's platform: a device that runs a
> real world model at the edge, generates and quality-gates its own experience,
> triggers retraining in the cluster, and promotes a signed, better model back to
> the device — all through Git, all governed. The model here is NVIDIA's
> Cosmos3-Edge; **our part is the self-improving, governed loop that makes it
> deployable as a fleet.** Let me show you that loop closing."

**Now** bring up the Dashboard. Point at the model badge (top): **`cosmos3-edge-v1`**.

> "This is that world model — 4 billion parameters — running on a Jetson Thor on my
> desk, not a cloud API. Everything on it was delivered by GitOps with zero inbound
> connections. It's running the **baseline** model right now — hold onto that,
> because we're about to watch the platform improve it."

*(Optional 20-sec cutaway to the Argo CD tab: "everything on the device is synced
from Git — this is the control plane.")*

### Beat 2 — "It curates its own data, on the device" (~90s)

**Screen:** Dashboard. Click **Start Flywheel**. Let it run ~4-5 cycles (you do
**not** need the full 10 — just enough to see the log fill and the bar move).

> "Watch what each cycle does. From a real robot camera frame, the model does two
> things: it **generates** a short video of what it thinks happens next, and it
> **predicts** the arm's next 16 moves. Then a curator scores both — **right here
> on the device.** Green rows pass; red rows are rejected and *never leave the
> Thor*. About 30% of these are deliberately broken attempts, and the curator
> catches them every time. Only the good data earns a trip to the cluster. That's
> the 'flywheel': the device is generating its own training data and quality-gating
> it before it ever costs you bandwidth or trust."

Point at the **progress bar** climbing toward the training trigger, then click
**Stop Flywheel**.

> "When enough good episodes accumulate, it trips a training run automatically."

### Beat 3 — "The platform closes the loop, automatically" (~45s) — *the honest time-compress*

**Screen:** switch to the **PR** tab.

> "When enough good data lands, the platform takes over on its own: it stands up a
> GPU in the cluster, runs the training recipe, and — this is the part that matters
> for putting robots in production — it **packages the result as a signed artifact
> and opens a promotion request** for a human to approve. Here's the actual pull
> request a real run produced. The training itself takes about half an hour, so I'm
> not making you watch it — but nothing here is faked; this is the real output of
> the loop. The value isn't that we trained a model; it's that the whole path from
> field data to a governed, signed, promotable model happened without anyone
> hand-carrying files around."

Scroll the PR to show the changed model digest / the signed artifact reference.

### Beat 4 — "...and it's tracked and traceable" (~45s, optional but strong)

**Screen:** the **MLflow Compare** tab (`v1-base` vs `v2-500iter-graft`).

> "Every candidate the loop produces is tracked — you can always answer 'which
> model, trained on what, is running where.'"

Point at exactly two numbers:
1. **Training loss dropped** — `2.69 → 1.43` (~47%). "The run converged."
2. **Dream temporal stability** — `0.047` (v1) vs `0.018` (v2), ~61% smoother.
   "The new model's predictions are measurably more coherent — and in a second
   you'll *see* that number." *(The digest here also ties the experiment to the
   exact signed artifact deployed on the device.)*

*(Plotting tips + what-the-NaNs-mean are in **§ Reference: the numbers & screens
behind the beats** just below, if asked.)*

### Beat 5 — "See the improvement *before* you deploy it" — the money shot (~90s)

**Screen:** back to the Dashboard → scroll to **Forward Dynamics** (panel 2).
Press **Play v1**, then **Play v2**.

> "Same starting frame, same planned motion — the only thing different is the
> model. This is Forward Dynamics: the world model *imagines* what the arm would do
> if it executed that plan — no physics engine, no robot moving. On the left, the
> baseline. On the right, the model the flywheel just produced. Watch the early
> motion — the fine-tuned version holds together through the grasp and moves more
> smoothly; that's the 0.047-to-0.018 you just saw, now visible. **This is what
> 'dream before deploy' means** — you see whether the new model is better *before*
> it ever touches a real fleet."

### Beat 6 — "...and every promotion is governed" (~30s, optional close)

**Screen:** back on the PR (or Argo) tab.

> "One last thing: none of this is a hand-edit. Promoting that model was merging a
> pull request — Git is the control plane. Argo syncs it to the device, and before
> the new model can even load, the device verifies its **cryptographic signature**.
> A model that isn't signed by our pipeline simply won't run. Self-improving, and
> governed end to end."

That's the arc. Stop recording.

---

### Reference: the numbers & screens behind the beats

*You don't narrate this — it's here so you can answer follow-ups and set up the
MLflow tab correctly.*

**MLflow Compare (`v1-base` vs `v2-500iter-graft`) — what to point at:**
1. **Training loss** — `train_loss_start` **2.69** → `train_loss_end` **1.43**
   (~47% drop). "It learned."
2. **Dream temporal stability** — **0.047 (v1)** vs **0.018 (v2)**, ~61% smoother.
   The one metric that compares cleanly across both runs.
3. **`modelcar_digest`** differs per run (v1 `5c990c93…`, v2 `69da94f2…`) — each is
   the actual **signed** artifact on Thor; the experiment traces to what's deployed.

**Best on-camera loss visual:** experiment → **Chart view** (or the
`v2-500iter-graft` run's **Metrics** tab) → line chart, Y=`train_loss_window`,
X=step (descending 2.6→2.0 curve).

> **Avoid the Compare page's "Parallel Coordinates Plot"** — built for big
> hyperparameter sweeps; with 2 runs it's near-empty/confusing. Use the **Box/Scatter
> Plot** with `dream_temporal_stability`, or just the **Compare table**.

> **What the NaNs mean (if asked):** `v1-base` is the *untuned* baseline, so its
> training-only metrics (loss, weight-delta, iterations) are blank/NaN — correct,
> not a logging error. `dream_temporal_stability` is the shared, comparable metric.

> **Why the prediction videos are pre-baked:** the v1/v2 rollouts are pinned,
> deterministic outputs from the *real* base and 500-iter fine-tuned models (256×256,
> seed 42, same frame + action chunk) — so the recording is fast and identical every
> time. They're genuine model outputs, not mock-ups; reproduce either with
> `dream-comparison/gen_dream.py` (§ Reproducing the Pinned Dreams). The fully-live
> generation path is in the Full Live Demo below.

### Reset to start state (if the device isn't clean before recording)

```bash
# On the dashboard: click "Clear Data" to zero the episode counts/log.
# If the model badge shows v2 (not v1), the device is mid/post-promotion --
# roll it back to the v1 baseline (git revert of the promotion, Argo re-syncs):
#   see § "Full Live Demo" pre-demo notes, or revert the replica/selector values
#   in gitops/vllm-cosmos3/ and let Argo sync (blue up, green down, selector blue).
```

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
- Input Frame panel populates with a real 256×256 BridgeData2 robot image (WidowX arm on a tabletop)
- Panel 1 (Generate plan video + action policy) shows:
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

## Part 3 — Forward Dynamics / Dream Before Deploy (~3 min)

Back on the dashboard. Scroll to the **Forward Dynamics** panel (panel 2).

"Before we promote the fine-tuned model, let's see what the current model predicts. Forward Dynamics takes a real robot image and a real action trajectory — 16 steps of joint positions — and the world model computes what would happen. No physics engine. Pure learned understanding."

Press **Play v1**. The rollout video plays **on click** — the buttons play
the pinned, curated comparison pair (see § Reproducing the Pinned Dreams), not a
live GPU run. (Play toggles to **Stop** while a rollout is playing.) If you want a
genuinely-live rollout instead, scale the dreamer at 256×256 (see the resolution
note below) — but for a clean recording, pinned is deterministic.

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

Press **Play v2**. Compare side-by-side with v1 (pinned pair).

"Same frame, same action trajectory. Different model. The flywheel trained the Generator on robot manipulation data, and the prediction changed. This is what 'dream before deploy' means — you see the difference before it touches a fleet."

### Experiment tracking (optional)

> New to MLflow? Read **§ MLflow, in plain language** first (concepts + talk track
> + likely-questions), then **§ Experiment Tracking (MLflow)** for the logging how-to.

Cut to **RHOAI MLflow** → experiment `cosmos3-edge-wam-flywheel` → Compare
`v1-base` vs `v2-500iter-graft`: training loss 2.69→1.43, moe_gen weight-delta,
dream MP4 attached per run, and the `cosmos3-edge` registered model (v1/v2) tagged
with the deployed signed modelcar digest — experiment-to-artifact lineage. Use the
loss line-chart + Compare table (not the Parallel Coordinates plot) — see the
plain-language section for why.

---

## Reproducing the Pinned Dreams

The dashboard's **Play v1/v2** buttons play a pinned, curated pair on Thor at
`/var/lib/dreams/zzz-showcase-cosmos3-edge-v{1,2}.mp4` (immutable via `chattr +i`,
sort-last names so they always win the dashboard's `_dreams()` pick, and survive
Clear Data + pod restarts). Both are genuine model outputs at **256×256, seed 42**,
from the `pick_place` BridgeData2 frame + the `good` 16-step action chunk.

- **v1** = base (untuned) modelcar `sha256:5c990c93…` → snapshot `2a00e87e…`
- **v2** = grafted 500-iter Vision-SFT modelcar `sha256:69da94f2…` → snapshot `bfaf37f2…`
  (Vision-SFT `moe_gen` improvements + base action modules grafted back in — see
  DECISIONS.md D034)

To regenerate either side identically: serve that model, then run
`dream-comparison/gen_dream.py <tag>` on Thor (points at the cosmos3-edge clusterIP,
forward-dynamics, 256×256, seed 42, flow_shift 7.0 — see D036). Both snapshots are
staged on Thor's hostPath under
`/var/lib/models/huggingface/hub/models--nvidia--Cosmos3-Edge/snapshots/` so a
base⇄v2 swap needs no re-pull.

> **Resolution note (important):** generate dreams at **256×256** to match the
> BridgeData2 conditioning frame. The dreamer's default `size=320x192` produces
> visibly degraded, temporally-incoherent rollouts on these square frames — the
> pinned pair uses 256×256 for this reason.

---

## MLflow, in plain language (read this before presenting Beat 4)

If you're not steeped in MLOps, here's what you're actually showing — enough to
narrate it *and* answer the obvious follow-ups.

**What problem MLflow solves.** When you train models, you end up with a pile of
"I ran this with these settings and got these numbers" — easy to lose, impossible
to compare later. MLflow is a **lab notebook for model training**: every training
attempt is recorded so you can compare them and trace which one you actually shipped.

**The four nouns (this is the whole mental model):**
- **Experiment** — a folder for related attempts. Ours is `cosmos3-edge-wam-flywheel`.
- **Run** — one training attempt inside that folder. We have two: `v1-base`
  (the untuned starting point) and `v2-500iter-graft` (after fine-tuning).
- **Parameters** — the *inputs/settings* you chose (dataset, iterations, GPUs).
  Fixed before the run. In the UI these are the "Parameters" rows.
- **Metrics** — the *measured results* (training loss, our stability score).
  Produced by the run. In the UI these are the "Metrics" rows, and the only
  things you can chart.
  (Mnemonic: **parameters = knobs you set; metrics = numbers you got.**)
- **Artifacts** — files the run produced (here, the dream MP4s).
- **Model Registry** — a separate catalog of "official" models with versions
  (`cosmos3-edge` v1, v2). Each version is tagged with the **signed modelcar
  digest**, which is the exact thing running on Thor — that's the "traceability"
  claim: the experiment links to the deployed artifact, not just a name.

**Why there are only two runs (and why that shapes the visuals).** Real MLOps
teams have dozens/hundreds of runs, which is what tools like the *Parallel
Coordinates Plot* are built for. We deliberately have exactly two (baseline vs
fine-tuned) to tell one clear before/after story — so use the simple **Compare
table** and a **single loss line-chart**, not the sweep-oriented plots.

**Why some cells are blank/NaN.** `v1-base` was never trained, so it has no
training loss, no iteration count, etc. Blank there is *correct* — it's the
"before" picture. The one number that exists on *both* is `dream_temporal_stability`,
which is why that's the clean side-by-side comparison.

**The three things worth saying, and what each means:**
1. *"Training loss dropped 2.69 → 1.43."* Loss = how wrong the model's predictions
   are during training; lower = it learned the data better. A ~47% drop over 500
   steps is a real training signal (not a stub).
2. *"The dreams got ~61% smoother (0.044 → 0.017)."* Our `dream_temporal_stability`
   metric measures how much consecutive video frames jump around; lower = more
   temporally coherent. **Honest caveat if asked:** it measures *smoothness, not
   task success* — we pair it with the eyeball comparison, we don't claim it proves
   the robot would succeed.
3. *"Each run traces to a signed, deployed artifact."* The `modelcar_digest` tag is
   the cryptographically-signed image actually on the device — so this isn't a
   detached spreadsheet, it's lineage from experiment → registry → what's running.

**Likely questions & honest answers:**
- *"Why do the videos look rough / smeary, especially toward the end?"* — These are
  4-billion-parameter generative predictions running on a **single edge device**
  (Jetson Thor), not a render farm — so they're impressionistic by nature, and the
  rollout loosens in its back third as prediction uncertainty compounds over the
  16-step horizon. That's expected, not a defect. The demo's claim isn't
  photorealism — it's the **flywheel mechanism** and the **v1→v2 delta**: same
  frame, same action plan, only the model changed, and the fine-tuned version stays
  coherent longer and moves more smoothly (temporal-stability 0.047 → 0.018). The
  first-stage Generator Output clips are live per-episode generation on-device, so
  they're rough too — the signal there is coherent-vs-garbage, which is exactly what
  the on-device curator scores.
- *"Is this auto-logged by the pipeline?"* — Not yet. These two runs are a curated
  backfill for the recording; wiring `mlflow.log_*` into the KFP training pipeline
  so future runs log automatically is a planned next step.
- *"Why is v1's run duration 184ms?"* — Because v1 is a *logging* record of the
  untuned baseline, not a training run; the duration is just how long it took to
  write the record. The real 500-iter training happened on the 8×H100 box.
- *"Can I click the model and deploy it?"* — The registry version carries the
  digest; deployment is the GitOps blue/green flip (Beat 5), not a button here.

---

## Experiment Tracking (MLflow)

The runs shown in Beat 4 are logged to **RHOAI's MLflow** (experiment
`cosmos3-edge-wam-flywheel`, in the `vla-training` Data Science Project — legacy
namespace name; see DECISIONS.md D035). Logged via a CPU workbench in that project
(`cosmos3-wam-tracking`), which auto-injects `MLFLOW_TRACKING_URI` + SA-token auth
(the RHOAI MLflow uses a Kubernetes request-auth provider — the workbench needs
`mlflow` + `kubernetes` pip installed).

Two runs, genuine data:
- **`v1-base`** — untuned reference; dream MP4 artifact; digest `5c990c93…`;
  `dream_temporal_stability` **0.044**.
- **`v2-500iter-graft`** — 500-iter Vision SFT on 8×H100; `train_loss` 2.69→1.43,
  moe_gen weight-delta metrics, loss curve + dream MP4 artifacts; digest `69da94f2…`;
  `dream_temporal_stability` **0.017** (~61% smoother than v1).

`dream_temporal_stability` = mean absolute grayscale frame-to-frame difference of
the rollout (normalized 0-1; lower = smoother/more temporally coherent). It is the
one metric logged to **both** runs so the Compare view shows a real v1-vs-v2 bar
rather than NaN. Caveat: it measures smoothness, not task success — it pairs with
the visual coherence check, don't overclaim it as a quality score.

Both registered as **`cosmos3-edge`** v1/v2 with a `modelcar_digest` tag linking the
experiment to the signed artifact deployed on Thor. Source assets live in the repo
at `dream-comparison/` (`dream_diag_base.mp4`, `dream_diag_v2graft.mp4`,
`loss_curve.json`). To relog/refresh, re-run the logging cell (kept with the session
tooling) against the workbench. This is a curated backfill for the recording; wiring
`mlflow.log_*` into the KFP pipeline for auto-logging of future runs is a deferred
roadmap item.

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
| Play button does nothing | Pinned files missing? Check `/var/lib/dreams/zzz-showcase-*.mp4`. (Live path only: check dreamer logs; GPU may be contended with vLLM) |
| Flywheel buttons unresponsive | Refresh the dashboard page; check dashboard pod logs |
| Pipeline not triggering | Check manifest-consumer logs; verify TRAINING_PIPELINE_ID is set |
| No GPU node for training | L40S machinepool must exist with autoscaler enabled |
| v1/v2 dreams look similar | Use the pinned pair (default); it's from the real 500-iter run. Do NOT live-generate at 320×192 — that degrades quality. See § Reproducing the Pinned Dreams |
| Play buttons play nothing | Pinned files must exist + be immutable on Thor `/var/lib/dreams/zzz-showcase-*.mp4`; dashboard reads them via `_dreams()`. Restart dashboard pod if the configmap changed |
| Catastrophic failure | Switch to pre-recorded video |
