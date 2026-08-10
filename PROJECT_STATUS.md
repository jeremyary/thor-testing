---
project: thor-testing
repo: git@github.com:jeremyary/thor-testing.git
last_activity: 2026-08-10
first_activity: 2026-08-07
category: poc
tags: [nvidia-thor, jetson, bootc, microshift, vllm, cosmos3, rhtas, sigstore, tekton, acm, rhem, flightctl, edge-ai, physical-ai, gitops, argo-cd, opentelemetry, kafka]
---

# Physical AI Edge Flywheel — Thor Testing

## Summary
PoC demonstrating an edge-to-cluster MLOps flywheel for Physical AI on NVIDIA Jetson AGX Thor. A derived CentOS Stream 10 bootc image runs MicroShift, vLLM-Omni (Cosmos3-Edge 4B world model), and data flywheel workloads on the Thor device. An OSD hub cluster provides ACM fleet management, RHEM (flightctl) device lifecycle, OpenShift GitOps (Argo CD) workload delivery, RHTAS image signing (cosign + Rekor), and observability (OTel → Tempo/Perses). The system is fully operational through Phase 5 (trust plane), with Phase 4 (training pipeline) deferred pending L40S GPU availability.

## Architecture

### Device (NVIDIA Jetson AGX Thor — 10.0.0.42)
- **SoC:** T5000, Blackwell GPU (SM_110), 128GB unified LPDDR5X, 14 ARM Cortex-A720AE cores
- **OS:** CentOS Stream 10 bootc image (derived FROM internal sidecar team's base), kernel 6.12, NVIDIA OpenRM driver 595.78
- **Baked into OS image:** MicroShift 4.22, flightctl-agent, greenboot health checks, OTel collector (RPM/systemd), GPU reset service, embedded workload container images (air-gapped via skopeo dir: pattern), sigstore trust anchor (cosign pubkey + policy.json)
- **Workloads (GitOps-delivered via Argo CD):** Cosmos3-Edge via vLLM-Omni (NodePort 30800), edge Kafka, robot-sim, curator, sync-agent
- **Management:** RHEM-enrolled, ACM ManagedCluster (Joined/Available), Argo CD via ACM cluster-proxy push model

### Hub (OSD on AWS — api.g4h4d3j7q1c9f7m.cimo.p1.openshiftapps.com)
- ACM 2.17, RHEM (flightctl), OpenShift GitOps (Argo CD)
- RHTAS (Fulcio, Rekor, CTlog, TUF) in `trusted-artifact-signer` namespace
- OpenShift Pipelines 1.23 — Tekton build+sign pipeline in `thor-builds` namespace
- AMQ Streams (Kafka) in `fleet-ops`, MinIO in `robotics-data`
- COO 1.5 (Tempo, Perses) in `observability`
- qemu-user-static DaemonSet (all nodes) for arm64 cross-builds

### Build Pipeline (Tekton)
Three-task pipeline: `git-clone` → `buildah` (arm64 cross-build, privileged SCC) → `cosign-sign` (static keypair + RHTAS Rekor). Pushes to internal OCP registry. Image digest flows to cosign for by-digest signing. Manifests in `tekton/`.

### Repo Layout
```
derived-image/           # Containerfile + configs for the bootc OS image
  config/                # policy.json, cosign-signing.pub, otel, microshift, embedded-images.txt
  greenboot/             # Health check scripts (microshift, vllm_gpu)
  manifests/             # Day-0 MicroShift manifests (nvidia-device-plugin)
gitops/
  vllm-cosmos3/          # Cosmos3-Edge deployment, service, entrypoint
  flywheel/              # robot-sim, curator, sync-agent, edge-kafka, mirrormaker2
  edge-workloads/        # Smoke test, namespace
tekton/                  # Build pipeline (cosign-sign task, pipeline, pipelinerun)
action-preview/          # Early PoC: text→video generation demo
centos-bootc-tegra/      # Upstream kernel patch project (Nick Cao, reference only)
nvidia-jetson-sidecar/   # Upstream sidecar RPM build project (reference only)
```

## Status

**Phase: testing/demo-ready** — all infrastructure operational, Tekton pipeline validated end-to-end.

### What's working
- Tekton pipeline: git-clone → buildah arm64 cross-build → cosign sign + Rekor log (full run ~75 min)
- `bootc switch` from internal registry → Thor boots new image, MicroShift + all workloads come up
- Cosmos3-Edge inference serving (text→image generation confirmed, 640x640 PNG output)
- GPU operational: NVIDIA Thor SM_110, driver 595.78, CUDA 13.x
- flightctl-agent enrolled, ACM klusterlet running, Argo CD syncing workloads
- Edge Kafka + sync-agent running in flywheel namespace
- OTel collector running as systemd service, exporting to hub Tempo
- Trust plane: cosign keypair generated, image signed, signature in Rekor (tlog entry #3), policy.json enforces sigstoreSigned for internal registry

### What's not yet done
- Phase 4 (training pipeline): deferred — needs L40S GPU pool on OSD
- Model weights as modelcar OCI artifact (D014): architecture decided, not implemented
- Perses dashboards: COO installed, dashboards not yet created
- NodePort loopback on Thor: `localhost:30800` doesn't work (OVN hairpin issue), must use `10.0.0.42:30800`
- Flywheel workloads default to replicas=0 — scale up for demos

### Gotchas discovered
- **Privileged SCC required for cross-arch builds:** buildah + qemu-user-static segfaults under `pipelines-scc`. Created `buildah-cross-arch` Task (copy of standard buildah with `privileged: true`), granted `pipeline` SA `privileged` SCC in `thor-builds` namespace.
- **SA token expiry in registry auth:** The auto-generated `pipeline-dockercfg-*` Secret tokens expire after ~24h. Created `combined-registry-auth` Secret with a fresh 30-day token (`oc create token pipeline --duration=720h`) merged with GitLab pull credentials.
- **ostree /etc/ three-way merge:** Files COPY'd to `/etc/` in the Containerfile (policy.json, cosign-signing.pub) are treated as config by ostree. If they were manually modified on the device, `bootc switch` preserves the old versions. Fix: `cp /usr/etc/<path> /etc/<path>` to reset to image defaults.
- **OpenShift Pipelines 1.23 removed ClusterTasks:** Must use `resolver: cluster` with params `kind: task`, `name: <task>`, `namespace: openshift-pipelines`. Parameter names are uppercase (`URL`, `REVISION`, `TLS_VERIFY` not `TLSVERIFY`). git-clone workspace is `output` not `source`.
- **Cosmos3-Edge is a world model, not a text LLM:** `/v1/chat/completions` returns `image_url` with base64 PNG, not text. Text-only scoring for curation is impossible without a separate Reasoner container (D006).
- **vLLM on Thor requires workarounds:** CUDA pre-init (`torch.zeros(1, device="cuda")`), `VLLM_ENABLE_V1_MULTIPROCESSING=0`, `HF_HUB_DISABLE_XET=1`. See D002/D003.
- **NVIDIA device plugin must use envvar strategy:** CDI mode unsupported on Jetson (D004). Requires hostPath mount of `/usr/lib64/nvidia`.

## Key Decisions / Learnings

Sixteen decisions documented in DECISIONS.md (D001–D016). Most impactful:
- **D008:** Static cosign keypair + RHTAS Rekor (not full keyless) — pragmatic trust plane without OIDC complexity
- **D009:** qemu cross-build on x86 OSD nodes — no Graviton available, works with privileged SCC
- **D010:** Embed workload images in bootc — Red Hat's documented air-gapped MicroShift pattern, single delivery vehicle
- **D013:** Bootc image is the only delivery mechanism — no dual connected/disconnected paths
- **D015:** Sigstore policy scoped to internal registry — single source of truth for governed artifacts

Key learning: the gap between "BuildConfig works" and "Tekton pipeline works" for cross-arch builds is significant. Docker strategy in BuildConfig runs fully privileged; Tekton buildah does not by default. Production cross-arch Tekton pipelines need explicit privileged SCC and a custom Task.

## Items of Interest

- **Cosign private key** is stored as `cosign-signing-key` Secret in `thor-builds` namespace (also was at `/tmp/thor-signing.key` on the build desktop — may need backup)
- **Rekor transparency log** has entries at `https://rekor-server-trusted-artifact-signer.apps.g4h4d3j7q1c9f7m.cimo.p1.openshiftapps.com`
- **Thor SSH:** `ssh thor` (10.0.0.42), key-based auth, root sudo
- **Hub cluster:** `api.g4h4d3j7q1c9f7m.cimo.p1.openshiftapps.com:6443`, user `jary@redhat.com`
- **Internal registry route:** `default-route-openshift-image-registry.apps.g4h4d3j7q1c9f7m.cimo.p1.openshiftapps.com`
- **Image currently on Thor:** `sha256:b3eb729e7d771683af726de97d5f7e6a584a12fb32ec03d0ed1ecb6e2eef6bf6`
- **Flywheel workloads** are defaulted to replicas=0 in gitops manifests — scale up with `oc scale` or edit manifests for demos
- **combined-registry-auth** Secret expires in ~30 days (token created 2026-08-10) — will need refresh
- **Demo runbook** exists at DEMO_RUNBOOK.md — 15-minute three-act demo structure with pre-flight checklist

## Related Docs

- `PROJECT-BRIEF.md` — full architecture vision, phased build plan, demo script outline
- `DEPLOYMENT_GUIDE.md` — step-by-step reproducible setup (all phases)
- `DECISIONS.md` — D001–D016 decision log with rationale
- `DEMO_RUNBOOK.md` — demo script with pre-flight checklist
- `PHASE0-FINDINGS.md` — initial Thor audit (OS, GPU, networking, storage)
- `UNDERSTANDING_THE_BUILD.md` — deep-dive on the centos-bootc-tegra + sidecar build chain
- `VLLM_ON_THOR.md` — full path from boxed Thor to serving inference, all blockers and fixes
