# Physical AI Edge Flywheel

> [!NOTE]
> This project was developed with assistance from AI tools.

An edge-to-cluster MLOps flywheel for **Physical AI**, built as a working, demoable
proof of concept. A NVIDIA Jetson AGX Thor acts as a managed robot-brain edge device;
an OpenShift Dedicated (OSD) cluster on AWS acts as the training, promotion, signing,
and observability hub. It implements the inner/outer-loop + fleet-data-flywheel
pattern for humanoid robotics.

![Physical AI Edge Flywheel architecture](assets/physical-ai-edge-flywheel.drawio.png)

## What it demonstrates

The system has **two promotion planes and one data plane**, all rooted in Git and
all signed:

- **OS plane** — the Thor boots a derived CentOS Stream 10 **bootc** image. OS
  updates are transactional, health-gated, and auto-rollback, managed by Red Hat
  Edge Manager (RHEM / flightctl).
- **Model plane** — Cosmos3-Edge checkpoints are packaged as **modelcar OCI images**,
  promoted via GitOps (Argo CD), verified by sigstore policy on the device, and
  hot-swapped into vLLM-Omni via blue/green — no reboot.
- **Data plane (the flywheel)** — a simulated robot workload generates episodes
  on-device; a curator triages them using the same vLLM-Omni endpoint; curated
  episodes flow to hub object storage; Kafka manifests trip a training pipeline
  that post-trains, evaluates, packages, signs, and opens a promotion PR. Merge
  closes the loop.

Plus a **telemetry plane**: OpenTelemetry end to end, one trace per control-loop
tick, every signal stamped with the live `model.version` — so promotions show up
as step changes in a dashboard.

## Architecture at a glance

### Device — NVIDIA Jetson AGX Thor
- **SoC:** T5000, Blackwell GPU (SM_110), 128GB unified LPDDR5X, 14 ARM cores
- **OS:** CentOS Stream 10 bootc image (derived `FROM` an internal team's base),
  NVIDIA OpenRM driver, CUDA 13.x
- **Baked into the OS image:** MicroShift 4.22 + greenboot, flightctl-agent,
  OTel collector, GPU reset service, embedded workload images (air-gapped),
  and the sigstore trust anchor (`policy.json` + `registries.d` + cosign pubkey)
- **Workloads (GitOps-delivered):** Cosmos3-Edge via vLLM-Omni, edge Kafka,
  robot-sim, curator, sync-agent
- **Management:** RHEM-enrolled, ACM ManagedCluster, Argo CD sync

### Hub — OpenShift Dedicated on AWS
- ACM + RHEM (flightctl), OpenShift GitOps (Argo CD)
- RHTAS (Fulcio, Rekor, CTlog, TUF) for signing
- OpenShift Pipelines (Tekton) — OS-image and modelcar build+sign pipelines
- AMQ Streams (Kafka), MinIO (object storage)
- Cluster Observability Operator (Tempo, Perses)

## Documentation

| Document | What it covers |
|----------|----------------|
| [`DEPLOYMENT_GUIDE.md`](DEPLOYMENT_GUIDE.md) | Step-by-step reproducible setup, all phases |
| [`DECISIONS.md`](DECISIONS.md) | Decision log (D001+) with rationale |
| [`DEMO_RUNBOOK.md`](DEMO_RUNBOOK.md) | Demo script: short cut (~4-5 min) + full live demo (~10-12 min) |

## Getting started

This is a lab/demo system for one device, built as if it were a fleet. To recreate
the stack, follow [`DEPLOYMENT_GUIDE.md`](DEPLOYMENT_GUIDE.md) in order (Phases 1–5).

**Prerequisites:**
- NVIDIA Jetson AGX Thor running CentOS Stream 10 bootc
- OSD cluster on AWS with cluster-admin
- SSH access to the Thor, `gh` CLI authenticated, internal OpenShift registry,
  and a GitLab read token for the base image

Copy `.env.example` to `.env` and fill in the registry/GitLab credentials before
running any build.

To run the demo, start with the **Short Cut** in [`DEMO_RUNBOOK.md`](DEMO_RUNBOOK.md).

## License note

Cosmos3-Edge model weights are governed by the NVIDIA Open Model License; motion-data
lineage constraints (GEAR-SONIC context) apply to any training use. See
[`DECISIONS.md`](DECISIONS.md) for how signing and license posture are handled.
```