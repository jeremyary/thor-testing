# Physical AI Edge Flywheel — Project Brief & Build Plan

**Audience:** Claude Code instance (Opus 4.6, 1M context) working interactively with Jeremy.
**Operator context:** Jeremy is `cluster-admin` on an OpenShift Dedicated (OSD) cluster on AWS and will be `oc` logged in during sessions. A Jetson AGX Thor dev kit is on his local network, already running CentOS Stream 10 from a bootc image, with Cosmos 3 Edge served via vLLM-Omni.
**Ground rule for this document:** it conveys concept, architecture, decisions, and phased steps. It intentionally contains no code, no YAML, and no command transcripts — those are yours to produce during the build, phase by phase, with Jeremy's approval.

---

## 1. Mission

Build a working, demoable **edge-to-cluster MLOps flywheel for Physical AI**: a Jetson Thor acting as a managed robot-brain edge device, and an OSD cluster acting as the training/promotion/observability hub. The demo is the executable version of the inner/outer-loop + fleet-data-flywheel framing from the Red Hat/Intel humanoid robotics reference architecture paper (Section 6) that Jeremy co-authored — every component here maps to a box in that diagram.

The story has **two promotion planes and one data plane**, all rooted in Git, all signed:

- **OS plane:** the Thor boots a derived bootc image (child of an internal Red Hat team's CentOS Stream 10 Thor image from GitLab). OS updates are transactional, health-gated, auto-rollback, managed by Red Hat Edge Manager (RHEM).
- **Model plane:** Cosmos 3 Edge checkpoints are packaged as **modelcar OCI images**, promoted via GitOps (Argo CD), verified by sigstore policy on the device, and hot-swapped into vLLM-Omni via blue/green — no reboot.
- **Data plane (the flywheel):** a simulated robot workload generates episodes on the device; a curator triages them on-device using the same vLLM-Omni endpoint in Reasoner mode; curated episodes flow to hub object storage; manifests on Kafka trip a training pipeline; the pipeline post-trains, evaluates, packages, signs, and opens a promotion PR. Merge closes the loop.

Plus a **telemetry plane**: OpenTelemetry end to end, with one trace per control-loop tick and every signal stamped with the live model version, so promotions are visible as step changes in Grafana.

Success is a ~15-minute live demo (three acts + stinger, described in §7) and a reference-architecture write-up. This is a lab/demo system for one device, built as if it were a fleet.

## 2. Current state (assets you can assume)

- **Thor:** CentOS Stream 10 booted from a bootc image built by an internal Red Hat team (pulled from their GitLab repo). SBSA platform, unified CUDA 13 stack. Cosmos 3 Edge (4B omnimodal world model: Reasoner mode + Generator mode) is running under vLLM-Omni and answering requests. Exact contents of the base image (driver, container toolkit, CDI handling, whether vLLM-Omni currently runs as a systemd unit, a podman container, or bare process) must be **audited in Phase 0 — do not assume**.
- **Hub:** OSD on AWS, cluster-admin, machinepool control. RHOAI 3.4 EA1 installed. Existing GPU experience: L40S and L4 node types. OSD control plane is Red Hat-managed — plan around worker capacity and operators only.
- **Episode source:** a library of Isaac Sim–generated robot episodes (GR00T/GEAR-SONIC lineage) exists or can be produced on Jeremy's other hardware. No camera on the Thor; the device is stationary. This is by design — the demo's visuals come from Generator-mode predicted-rollout video, not from a camera.
- **Base image relationship (constraint):** we consume the internal team's published image as a registry artifact (`FROM` line) and nothing more. We do not build inside their repo, modify their code, or create work for them. All audit of the base happens at the image level (inspecting the running system and the pulled image); anything we can't determine that way gets solved in our own layer. Findings that would interest them can be noted for Jeremy to share at his discretion — never a blocker.

## 3. Target architecture

### Hub (OSD on AWS)

Three machinepool roles, separated by labels/taints:

- **platform pool** (x86, always-on, 2–3 nodes): RHACM hub with RHEM plugin, OpenShift GitOps (Argo CD), AMQ Streams (Kafka), MinIO or ODF object storage, Red Hat Trusted Artifact Signer (RHTAS: private Fulcio/Rekor/TUF), OTel gateway collector, TempoStack + LokiStack, model registry if used.
- **training pool** (L40S, tainted, **autoscaling min 0**): KFP/Data Science Pipelines training steps, fronted by Kueue so pipeline steps queue while capacity scales up. Scale-to-zero between runs is a first-class demo point, not just cost hygiene.
- **staging pool** (L4, min 0 or 1): KServe InferenceService hosting the *candidate* checkpoint for the world-model-in-the-loop validation gate.

Namespaces (hub): `robotics-data` (buckets: episodes-raw, episodes-curated, checkpoints, eval-reports), `robotics-train` (DSP/KFP + Kueue LocalQueue), `robotics-serve-staging` (KServe candidate + validation harness), `openshift-gitops`, Kafka namespace, RHTAS namespace, observability namespaces, plus the ACM-created managed-cluster namespace for the Thor.

### Device (Thor)

- **OS:** derived bootc image — `FROM` the internal team's image, adding: MicroShift (RPM install) + greenboot, the RHEM `flightctl-agent` (with bootc auto-update timer masked, since RHEM owns OS updates), sigstore verification config (`policy.json` + registries.d) as the baked-in trust anchor, CDI generation for the iGPU at boot, and day-0 manifests (klusterlet import for RHACM, Argo bootstrap).
- **Workloads (all GitOps-delivered, none baked into the image):**
  - `vLLM-Omni` serving Cosmos 3 Edge — blue/green pair of Deployments with a Service selector flip; model weights come from the modelcar OCI image (ImageVolume mount preferred, initContainer-copy fallback), never baked into the OS image and never re-downloaded on OS updates (persistent storage on NVMe under a bootc-preserved path).
  - `robot-sim` — the simulated workload: replays Isaac Sim episodes as a timed control loop (5 Hz / 200 ms tick budget), calls vLLM-Omni each tick, records episodes, has a failure-injection knob so the curator has rejects to show. It is simultaneously load generator, episode source, SLO subject, and trace root.
  - `curator` — scores completed episodes via Reasoner-mode calls to the *same* vLLM-Omni endpoint; below-threshold episodes are dropped locally (Gate 0).
  - `sync agent` — pushes curated episodes to hub S3 (bandwidth-capped), then publishes a small JSON manifest (claim check: S3 URI, score, task label, generating checkpoint version) to the hub Kafka topic.
  - `OTel edge collector` — see §6.

### Management split (who owns what)

- **RHEM (flightctl):** device enrollment, OS image rollout by fleet/device template in Git, lifecycle hooks (e.g., drain/spool-flush before OS update), automatic rollback on failed health checks. Greenboot checks (including "vLLM-Omni answers an action-chunk request within budget") are the on-device verdict RHEM's rollback consumes.
- **RHACM:** ManagedCluster registration of the Thor's MicroShift (auto-registered via RHEM fleet config), ManagedClusterSets/labels for ring promotion (staging→prod is a label change), Placement feeding Argo ApplicationSets, policy enforcement (image signature verification posture), fleet search/console.
- **Argo CD (OpenShift GitOps):** what actually runs — syncs device workloads and hub apps from the Git repo. RHACM decides *where*, Argo decides *what*. Prefer the ACM **pull model** for device applications (see §4).

## 3.5 Image build stream (aarch64)

The derived bootc image is an ordinary OCI container build — a Containerfile whose `FROM` is the team's published image — but it must be built **natively on aarch64** (images run 8–15 GB; qemu-emulated cross-builds at that size are ruled out). Two build products exist: the recurring **container image** (what `bootc switch` and RHEM consume — this is the stream) and a rare **disk image** via bootc-image-builder as a break-glass reflash artifact (build once, refresh occasionally, not part of the loop).

**Decided approach, two stages:**

1. **Bootstrap (Phase 1):** build on Jeremy's Apple Silicon Mac — `podman machine` on macOS runs a native arm64 Linux VM, so builds are native, fast, free, and ideal for the tight iterate/boot/fix loop. Manual and laptop-bound by design; not the steady-state answer.
2. **Steady state (from Phase 2):** **cluster-orchestrated ephemeral Graviton builder.** A Tekton pipeline (or Job) on the OSD hub calls the AWS API in Jeremy's work account to launch a Graviton **spot** instance whose user-data clones the derived-image repo, builds, pushes to the registry, signs against RHTAS, and self-terminates. Guardrails required: IAM role scoped to launch/terminate within a tagged sandbox, hard timeout so a hung build can't strand an instance, everything tagged, and Jeremy confirms account-owner blessing before this is automated. This mirrors the L40S scale-from-zero pattern — the hub materializes compute of whatever architecture the artifact needs, then evaporates it.
3. **Fallback:** AWS CodeBuild on its managed arm64 fleet (webhook/API-triggered, privileged builds, pay-per-minute) if the ephemeral-EC2 orchestration proves more trouble than it's worth. Swapping to it changes nothing downstream.

**Rejected options (do not resurface without new information):** building on the Thor itself (device builds its own OS = recovery hazard; build competes with inference for unified memory); Graviton machinepools on this OSD cluster (checked — not offered); building inside the base team's GitLab (excluded by the consume-only constraint); GitHub-hosted arm64 runners (would place internal-registry pull credentials in external CI).

**Rebuild trigger matrix:** rebuild on (a) new upstream base-image tag (registry poll or manual), (b) changes to our Containerfile/repo, (c) deliberate bumps of pinned MicroShift/agent RPM versions. MicroShift is **pinned**, never floating — an unpinned install means non-reproducible images and surprise Kubernetes minor bumps on the device.

## 4. Connectivity model — read this before reaching for ngrok

**Design principle: pull-first.** The Thor sits behind home NAT. Nearly every flow in this architecture is *outbound from the device*, which means the default answer to "how does the cluster reach the Thor" is: **it doesn't need to.**

Outbound-only flows (no tunnel required):
- RHEM `flightctl-agent` → hub (enrollment, status, update polling)
- ACM klusterlet → hub (managed-cluster registration and heartbeat)
- Argo **pull model** — the ApplicationSet/Application definitions are propagated to the spoke and reconciled by an agent on the device, so no hub→device API access is needed. This is the reason to prefer pull over push for device apps.
- sync agent → MinIO S3 endpoint (exposed via hub Route)
- sync agent → Kafka (exposed via hub Route/listener)
- OTel edge collector → hub gateway (OTLP over TLS via Route)
- CRI-O / bootc image pulls ← hub-reachable registry (Quay or the OSD internal registry exposed externally; verify pull path + auth from the Thor early)

The only flows that genuinely want inbound access to the Thor, none of which are architecturally required:
1. Argo **push** model (hub Argo reaching the MicroShift API) — avoided by choosing pull.
2. Developer convenience: `oc`/`kubectl` against MicroShift from a laptop — Jeremy is on the same LAN as the Thor, so this is local, not tunneled.
3. Demo-time dashboards served from the device — better solved by pushing that data to the hub (OTel) and demoing from hub Grafana, plus a local screen on the LAN.

**Recommendation:** build with zero inbound exposure. If a concrete gap emerges (e.g., a tool that only supports push), prefer **Tailscale** (persistent, WireGuard, stable identity, free tier, fits a long-lived lab) over ngrok (ephemeral URLs, per-session). Treat any tunnel as a flagged deviation: note in the decision log why pull didn't work for that flow. Corporate-network caveat: if the Thor ever moves onto an RH network, revisit egress rules before assuming outbound-anything.

## 5. Decisions already made (do not relitigate without new information)

| Decision | Choice | One-line rationale |
|---|---|---|
| Edge Kubernetes | MicroShift, not Single-Node OpenShift | SNO requires RHCOS (destroys the team's bootc substrate) and its control plane taxes unified memory/CPU that belongs to 5–15 Hz inference; MicroShift layers onto the existing OS, ~1 core / few GB, workloads survive control-plane restarts. |
| OS lifecycle | RHEM (flightctl) on bootc, not hand-rolled `bootc switch` CI | GA product; fleet templates in Git, lifecycle hooks, auto-rollback; agent masks bootc's own update timer. |
| Fleet/cluster mgmt | RHACM + RHEM plugin + Argo (pull model) | RHEM = device plane, RHACM = cluster/policy/placement/observability plane, Argo = sync engine; RHEM auto-registers MicroShift into RHACM. |
| Model packaging | KServe **modelcar** OCI images (ubi9-micro base, model files with root-group read perms) | Supported RHOAI feature (2.14+); same signed image consumed by hub KServe (`oci://` connection) and by the device. |
| Model delivery on device | ImageVolume mount (preferred, check feature gate/k8s version in the MicroShift build) with initContainer-copy fallback | No double disk usage, kubelet handles pull/cache/auth; symmetry with hub consumption. |
| Model vs OS coupling | Model **never** baked into bootc image | Preserves independent cadences: model promotes with a service flip (no reboot); OS promotes transactionally. Weights live on bootc-preserved persistent storage. |
| Signing | RHTAS (private Fulcio/Rekor/TUF), cosign keyless from pipelines, for **both** planes | One `policy.json` on the device verifies both bootc pulls and CRI-O workload/modelcar pulls; fallback if RHTAS fights: cosign static keypair, same policy mechanics. v1 image is the hand-installed trust anchor; v2+ verified. |
| Data plane | Claim-check pattern: episodes → S3, manifests → Kafka | Blobs never touch Kafka; events never carry data; manifests double as a drift-signal time series per checkpoint version. |
| Training | KFP/DSP on RHOAI, Kueue-fronted, L40S pool autoscaling min 0 | Queue-then-scale is the cost story and a demo beat; Cosmos post-training recipes are ~day-scale, demo uses truncated live run + real pre-completed artifacts. |
| Validation gates | Gate 0 curation threshold (edge) → Gate 1 eval metrics (pipeline) → Gate 2 world-model-in-the-loop rollout scoring on staging KServe → Gate 3 human PR merge → Gate 4 on-device signature check + smoke + blue/green flip | Gate 2 uses Generator-mode forward dynamics scored by Reasoner mode: "dream before deploy." |
| Image build stream | Mac (Apple Silicon, native podman) for bootstrap → cluster-triggered ephemeral Graviton spot builder for steady state; CodeBuild arm64 as fallback | Native aarch64 required; no Graviton machinepools on this OSD; Thor-as-builder and base-team-GitLab excluded (§3.5). |
| Workload | `robot-sim` replay control loop at 5 Hz | No camera/actuators needed; Generator-mode video is the demo visual; failure-injection feeds the curation story. |
| Telemetry | Two-tier OTel (edge agent collector → hub gateway), trace-per-tick, `model.version` resource attribute on everything | Promotion visible as a step change in one Grafana panel; disconnect tolerance via persistent sending queue on NVMe. |
| Observability backends | TempoStack (traces), LokiStack (logs), user-workload monitoring (metrics), Grafana | Skip ACM multicluster-observability addon on the device; the OTel pipeline is the portable answer. |

## 6. Telemetry design (summary for implementation)

Edge collector (Deployment on MicroShift, Red Hat build of OpenTelemetry): receivers = OTLP (robot-sim SDK + vLLM-Omni's OTLP tracing), Prometheus scrape of vLLM-Omni `/metrics`, hostmetrics, filelog. Processors = memory_limiter FIRST (hard cap — this device's RAM belongs to inference), batch, resource attributes (`device.id`, bootc image digest, `model.version` from live checkpoint tag). Exporter = OTLP/HTTP to hub gateway over TLS with a file-storage-backed persistent sending queue on NVMe (disconnected-tolerance story). Hub gateway fans out to Tempo/Loki/UWM.

Trace semantics: robot-sim opens a root span per 200 ms control tick and propagates W3C context into the vLLM-Omni request; vLLM's tracing nests queue/prefill/decode spans beneath it. Target artifact: a Tempo waterfall of one tick against the budget line, and a Grafana panel of p95 tick latency + curation score split by `model.version`, where the promotion moment is a visible step change.

Jetson caveats to resolve during build: DCGM does not cover Jetson — test NVML on the Thor SBSA stack, else use a tegrastats/jtop exporter sidecar for GPU metrics.

## 7. Demo shape (what "done" looks like)

~15 minutes, two screens (hub console/Grafana left, Thor terminal + output panel right), Thor on the table with a power meter inline.

- **Act 1 — the managed brain:** ACM shows the Thor as a managed cluster; `bootc status` shows the team's image + our derived layer. Live Reasoner-mode scene description, then the money shot: Generator-mode predicted-rollout video from a conditioning frame + action chunk ("no camera — it shows you what it *believes* will happen"). Kill MicroShift mid-generation; inference completes; control plane recovers; ACM blips and clears.
- **Act 2 — the flywheel turns:** start robot-sim replay; curator scores scroll (with planted rejects); manifests appear on Kafka; threshold trips; a KFP run materializes; L40S capacity scales from zero. Training is time-compressed live (token-truncated) with the *real* pre-completed run's eval report shown — never fake output, only compressed time.
- **Act 3 — promotion:** pipeline's MR (modelcar built, RHTAS-signed, Gate 1/2 reports attached) merged live; Argo syncs; green vLLM-Omni pulls the modelcar; signature policy admits it; smoke passes; selector flips. Re-run the identical Act 1 request → visibly better predicted rollout. Grafana shows the step change by `model.version`.
- **Stinger — trust and rollback:** unsigned modelcar tag refused by device policy; `git revert` walks the model back with no reboot. Optional OS-plane finale: RHEM rolls a deliberately broken image, greenboot fails the inference health check, device auto-rolls-back, RHEM fleet view shows attempted→failed→reverted.

Demo hygiene requirements to build in: everything pre-pulled, model pre-warmed, scripted prompts with rehearsed photogenic conditioning frames, full-run video recording as catastrophic fallback.

## 8. Phased build plan

Work phase-by-phase. Each phase ends with its acceptance criteria demonstrated to Jeremy before starting the next. Phases 2+ can partially parallelize with 1 where hub-only.

**Phase 0 — Audit & de-risk (no building).**
Audit the base **at the image and running-system level only** (no repo interaction): inspect the pulled image and live Thor for what's baked — driver stack, container toolkit, CDI handling, how vLLM-Omni currently runs, users, partition/persistence layout, systemd units, update expectations. Inventory the Thor as-running. Verify the early-risk list (§9) items marked P0. Produce a short findings doc; anything unknowable from the image gets solved in our layer rather than asked upstream.
*Accept when:* we can state exactly what the derived image must add vs. what it inherits, and every P0 risk has an answer or an owner.

**Phase 1 — Derived image & MicroShift.**
Define the derived Containerfile (MicroShift pinned + greenboot, flightctl-agent with bootc timer masked, CDI-at-boot mechanism, day-0 manifest slots, policy.json placeholder until Phase 5). Bootstrap builds run natively on the Apple Silicon Mac per §3.5. Build, push, `bootc switch`, boot. Bring up MicroShift; prove a GPU workload under CRI-O via CDI; prove vLLM-Omni runs *as a MicroShift workload* (migrating it from however it runs today) with weights on persistent storage surviving an OS update.
*Accept when:* Thor boots the derived image; vLLM-Omni serves under MicroShift with GPU; an OS update+rollback cycle leaves weights and episodes intact.

**Phase 2 — Hub foundation & enrollment.**
Machinepools (platform/L40S/L4) with labels/taints and autoscaler bounds; Kueue; OpenShift GitOps; ACM hub + RHEM plugin; MinIO + buckets; AMQ Streams + topics; registry decision (Quay vs. exposed internal) verified pullable from the Thor. Stand up the steady-state build stream per §3.5 (ephemeral Graviton builder triggered from the hub, guardrails included) and retire the Mac from the loop. Enroll the Thor in RHEM; fleet template in Git; auto-registration into ACM; Argo pull-model bootstrap delivering a hello workload to the device.
*Accept when:* a Git commit to the fleet repo changes something on the Thor via RHEM; a Git commit to the app repo changes a device workload via Argo, with zero inbound connections to the Thor; and a commit to the derived-image repo produces a pushed, signed image with the builder instance provably terminated afterward.

**Phase 3 — Flywheel data path.**
robot-sim (replay loop, tick budget, failure injection), recorder, curator (Reasoner-mode scoring against the shared endpoint), sync agent (S3 push + Kafka claim-check manifests). Blue/green vLLM-Omni structure lands here (even before promotion exists). Hub-side manifest consumer that counts toward a trigger threshold.
*Accept when:* episodes replay → get scored → curated ones land in MinIO with manifests on Kafka → planted-bad episodes provably never leave the device.

**Phase 4 — Training pipeline & modelcar.**
KFP pipeline: ingest (dedupe/split) → post-train (Cosmos recipe, Kueue on L40S, scale-from-zero) → Gate 1 eval with hard thresholds → package modelcar (ubi9-micro layout, permissions) → push → open MR against the GitOps repo with reports attached. Gate 2 (staging KServe `oci://` + Generator-rollout scoring) can land late in this phase or early in 5.
*Accept when:* a Kafka-threshold trip produces, unattended, a signed-ready modelcar and an MR containing real eval artifacts, with L40S nodes provably scaling 0→N→0.

**Phase 5 — Trust plane.**
RHTAS on hub; keyless cosign signing added to both the OS-image pipeline and the modelcar pipeline; device policy.json + registries.d enforcing sigstoreSigned for both bootc and CRI-O scopes, shipped in a new derived image (the trust-anchor bootstrap moment — document it, don't hide it). Negative test is mandatory: unsigned tag must be refused at the device.
*Accept when:* signed artifacts admit, unsigned artifacts refuse, on both planes, and each accepted artifact has a Rekor entry we can show.

**Phase 6 — Telemetry.**
Edge collector per §6; hub gateway + TempoStack/LokiStack/UWM wiring; robot-sim instrumented (trace-per-tick, context propagation into vLLM-Omni); model.version attribution end to end; the two named Grafana artifacts (tick waterfall, promotion step-change panel); disconnect test (pull the Thor's uplink mid-run, verify spool-and-drain).
*Accept when:* one trace shows tick→inference→action against the 200 ms budget, and a model promotion is visible as a step change in a version-split panel.

**Phase 7 — Demo hardening.**
End-to-end rehearsal against the §7 storyboard; runbook with per-act command sequences, timings, and fallback branches; failure-injection tuning; pre-pull/pre-warm automation; fallback recording. Decision-log and deviations list cleaned up for the write-up.
*Accept when:* two consecutive full rehearsals succeed without improvisation.

## 9. Verify-early risk register

P0 (answer before Phase 1 ends):
- **Build stream residuals** (approach is decided — §3.5 — but verify): podman machine on the Mac has disk/memory headroom for a 15 GB image build; the Mac can pull the base image (registry auth from a laptop) and push to our registry; work AWS account owner blesses tagged ephemeral spot instances and the IAM scoping; Graviton spot capacity exists in the cluster's region.
- **flightctl-agent on CentOS Stream 10 / aarch64.** RHEM docs assume RHEL bootc images; confirm the agent package availability and behavior on the CS10 base. If blocked: proceed with ACM+Argo-only management for OS *workloads* and hand-rolled bootc rollout as interim; flag to Jeremy (this is also a conversation the RHEM team will want to have).
- **Registry reachability + auth from the Thor** for bootc and CRI-O pulls (including the RHEM-expected pull-secret location for private repos).
- **NVIDIA driver survival across derived-image rebuilds** and CS10 kernel updates (open kernel modules; Jeremy has prior scar tissue from exactly this failure class on Ubuntu).

P1 (answer during the phase that touches them):
- **ImageVolume feature gate** in the MicroShift build's Kubernetes version (else initContainer fallback).
- **vLLM-Omni OTLP tracing support** parity with upstream vLLM's tracing flags (else wrap with span-emitting client-side instrumentation only).
- **NVML on Thor SBSA** for GPU metrics (else tegrastats/jtop exporter).
- **RHOAI staging: custom ServingRuntime for vLLM-Omni** vs. raw-deployment KServe for Gate 2 (a prototype ServingRuntime is a valuable byproduct — surface the option, let Jeremy pick scope).
- **Kafka + S3 Route exposure** patterns on OSD (external listeners, TLS termination) reachable from a home network.
- **Cosmos post-training recipe availability/maturity** for the chosen fine-tune task, and a fine-tune task design with an *obvious visual delta* for the Act 3 before/after (needs the longest lead time of anything in this plan — raise it early).

## 10. Working agreements for the Claude Code instance

1. **Plan before code, per phase.** At the start of each phase, produce a short execution plan (files, resources, sequence, test) and get Jeremy's OK. This document is concept-stable; your plans are where implementation detail lives.
2. **Supported path first.** Prefer shipped Red Hat product mechanisms over clever custom ones; when we must deviate (CS10-on-Thor is already one), record it in `DECISIONS.md` with rationale — the deviations list is raw material for the eventual paper.
3. **Verify versions against docs, don't recall them.** Product APIs, operator channels, feature gates, and support matrices here move fast; check current documentation rather than trusting training memory. When docs and reality disagree, reality (the cluster/device) wins; note the discrepancy.
4. **The Thor is a pet.** Before any `bootc switch`, kernel-adjacent change, or storage re-layout: confirm rollback path and that episode/weight data lives on preserved paths. Never leave the device in a state Jeremy can't recover without reflashing.
5. **Everything in Git.** Cluster and device state changes flow through the repos (fleet repo, GitOps app repo, pipeline repo). Direct `oc apply` is for debugging only and gets reconciled back.
6. **Outbound-only until proven otherwise.** No tunnels without a logged justification (§4).
7. **Ask Jeremy, don't assume, at the seams:** anything that would require interaction with the base-image team or their repo (default answer: solve it in our layer instead), anything spending real AWS money (GPU pool bounds, builder instances), anything with license implications (model weights are OpenMDW 1.1; motion-data lineage constraints from the GEAR-SONIC context apply to any *training* shortcuts).
8. **Keep the demo storyboard (§7) as the acceptance oracle.** If a technical choice makes a demo beat weaker, surface the tension instead of optimizing silently.
