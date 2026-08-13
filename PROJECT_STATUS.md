---
project: thor-testing
repo: git@github.com:jeremyary/thor-testing.git
last_activity: 2026-08-12
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
- **Baked into OS image:** MicroShift 4.22, flightctl-agent (pinned 1.2.0, D022), greenboot (D022/D023 — health checks were previously inert, now genuinely enforced: flightctl's `flightctl-configure-greenboot.service` masked so it can no longer blanket-disable them every boot, see gotchas), OTel collector (RPM/systemd), GPU reset service, embedded workload container images (air-gapped via skopeo dir: pattern), sigstore trust anchor (cosign pubkey + policy.json + registries.d)
- **Workloads (GitOps-delivered via Argo CD):** Cosmos3-Edge via vLLM-Omni (NodePort 30800), edge Kafka, robot-sim, curator, sync-agent
- **Management:** RHEM-enrolled, ACM ManagedCluster (Joined/Available), Argo CD via ACM cluster-proxy push model

### Hub (OSD on AWS — api.g4h4d3j7q1c9f7m.cimo.p1.openshiftapps.com)
- ACM 2.17, RHEM (flightctl), OpenShift GitOps (Argo CD)
- RHTAS (Fulcio, Rekor, CTlog, TUF) in `trusted-artifact-signer` namespace
- OpenShift Pipelines 1.23 — Tekton build+sign pipeline in `thor-builds` namespace
- AMQ Streams (Kafka) in `fleet-ops`, MinIO in `robotics-data`
- COO 1.5 (Tempo, Perses) in `observability`
- qemu-user-static DaemonSet (all nodes) for arm64 cross-builds

### Build Pipelines (Tekton)
**OS image pipeline** (3 tasks): `git-clone` → `buildah` (arm64 cross-build, privileged SCC) → `cosign-sign` (static keypair + RHTAS Rekor). Pushes to internal OCP registry. Image digest flows to cosign for by-digest signing. Full run ~75 min.

**Modelcar pipeline** (3 tasks): `git-clone` → `download-weights` (HuggingFace `snapshot_download` with scoped `allow_patterns`) → `package-modelcar` (`crane append`, not buildah — D017) → `cosign-sign`. Same signing controls as the OS image pipeline. Uses `crane` instead of `buildah` because the modelcar has no build logic (just one `COPY` of pre-downloaded weights), and `buildah`'s FUSE-backed storage is catastrophically slow for multi-GB single-layer pushes (D017).

All manifests in `tekton/`.

### Repo Layout
```
derived-image/           # Containerfile + configs for the bootc OS image
  config/                # policy.json, cosign-signing.pub, registries.d, otel, microshift
  greenboot/             # Health check scripts (microshift, vllm_gpu)
  manifests/             # Day-0 MicroShift manifests (nvidia-device-plugin)
gitops/
  vllm-cosmos3/          # Cosmos3-Edge deployment (modelcar initContainer), service, entrypoint
  flywheel/              # robot-sim, curator, sync-agent, edge-kafka, mirrormaker2
  edge-workloads/        # Smoke test, namespace
  observability/         # Perses instance, Tempo datasource, edge-flywheel dashboard
modelcar/                # Containerfile + stage script for Cosmos3-Edge modelcar OCI artifact
tekton/
  00-buildah-cross-arch-task  # Privileged buildah for arm64 cross-builds
  01-cosign-sign-task         # Shared cosign sign + Rekor log task
  02-pipeline / 03-pipelinerun  # OS image pipeline
  04-download-weights-task    # HF snapshot_download with scoped allow_patterns
  05-modelcar-pipeline / 06-modelcar-pipelinerun  # Modelcar pipeline
  07-package-modelcar-task    # crane append (not buildah — D017)
action-preview/          # Early PoC: text→video generation demo
```

## Status

**Phase: testing/demo-ready** — all infrastructure operational, Tekton pipeline validated end-to-end.

### What's working
- **OS image pipeline:** Tekton git-clone → buildah arm64 cross-build → cosign sign + Rekor log (full run ~75 min)
- **Modelcar pipeline:** Tekton git-clone → download-weights → crane append → cosign sign + Rekor log (~15 min)
- **Model weights delivery:** Cosmos3-Edge + guardrail models packaged as signed modelcar OCI artifact (D014); delivered to device via initContainer copy pattern; entrypoint pre-resolves model path so `HF_HUB_OFFLINE=1` works correctly, no `HF_TOKEN`/network fallback (D020)
- `bootc switch` from internal registry → Thor boots new image, MicroShift + all workloads come up
- Cosmos3-Edge inference serving (text→image generation confirmed, 640x640 PNG output)
- GPU operational: NVIDIA Thor SM_110, driver 595.78, CUDA 13.x
- flightctl-agent enrolled, ACM klusterlet running, Argo CD syncing workloads
- Edge Kafka + sync-agent running in flywheel namespace
- OTel collector running as systemd service, exporting to hub Tempo
- **Perses dashboards (D028):** fixed end to end 2026-08-12 — server deploys, dashboard/datasource reconcile genuinely, dashboard reachable via Route (no auth, matches PoC-wide posture). Root cause was a second, separate `perses-operator` Deployment gating workload creation on `spec.config.database` being set (D021's CR shipped `spec: {}`); D027's owner-reference hypothesis for the main COO operator was accurate as far as it went but missed this second operator entirely and is superseded. GitOps-managed via the `thor-testing-observability` ApplicationSet (hub-targeted, not edge-placement like the other three). See `DECISIONS.md` D028.
- **Trust plane:** cosign keypair generated, both OS image and modelcar signed, signatures in RHTAS Rekor. `policy.json` + `registries.d` enforce `sigstoreSigned` for internal registry — verified to work identically for both CRI-O workload pulls and bootc OS image pulls (D018/D019)

### What's not yet done
- **Phase 4 (training pipeline):** deferred — needs L40S GPU pool on OSD
- **JetPack 7.2.1 / T3000 emulation mode (APPENG-6009):** deliberately pinned/deferred, not blocked-and-forgotten. JetPack/driver/kernel come from the sidecar team's `BASE_IMAGE` (`derived-image/Containerfile`'s `FROM` tag `a66617e5-thor`), not anything we control in our own layers — bumping it is a much bigger-blast-radius change than anything else pending (CUDA pre-init workarounds, NVIDIA device-plugin envvar strategy, GPU reset timing were all tuned against the current driver stack). Decision (2026-08-12): wait for the sidecar team to publish an updated base image tag rather than chase JetPack ourselves; revisit once that lands.
- NodePort loopback on Thor: `localhost:30800` doesn't work (OVN hairpin issue), must use `10.0.0.42:30800`
- Flywheel workloads default to replicas=0 — scale up for demos
- Stale/`UnexpectedAdmissionError` Cosmos3-Edge pods accumulate across reboots (single-GPU `Recreate` strategy + repeated reboots this session left several old ReplicaSet pods lingering in `Init:ContainerStatusUnknown`/`UnexpectedAdmissionError`) — cosmetic, the current pod always reaches `1/1 Running`, but worth a `kubectl delete` sweep before a demo and possibly a GitOps-side fix (pod GC / TTL) if it keeps recurring.
- **vLLM-Omni image upgrade (D025) — attempted and reverted:** `docker.io/vllm/vllm-omni:cosmos3` (currently deployed, an unreleased `0.25.0rc2` snapshot) was live-validated against `v0.26.0` (digest-pinned) via a real GitOps merge/sync on 2026-08-12. **Crash-looped**: v0.26.0's guardrails hard-require a separate `cosmos-guardrail` PyPI package not present in this image, and refuse to silently disable the safety checker (NVIDIA Open Model License compliance). Reverted to `:cosmos3`, confirmed serving again (`HTTP 200`, valid inference). See `VLLM_OMNI_UPGRADE_RESEARCH.md` and `DECISIONS.md` D025's addendum for the full incident and the likely fix (add `cosmos-guardrail` to the image, not a different tag) before retrying.

### Gotchas discovered
- **Privileged SCC required for cross-arch builds:** buildah + qemu-user-static segfaults under `pipelines-scc`. Created `buildah-cross-arch` Task (copy of standard buildah with `privileged: true`), granted `pipeline` SA `privileged` SCC in `thor-builds` namespace.
- **SA token expiry in registry auth:** The auto-generated `pipeline-dockercfg-*` Secret tokens expire after ~24h. Created `combined-registry-auth` Secret with a fresh 30-day token (`oc create token pipeline --duration=720h`) merged with GitLab pull credentials.
- **ostree /etc/ three-way merge:** Files COPY'd to `/etc/` in the Containerfile (policy.json, cosign-signing.pub) are treated as config by ostree. If they were manually modified on the device, `bootc switch` preserves the old versions. Fix: `cp /usr/etc/<path> /etc/<path>` to reset to image defaults.
- **OpenShift Pipelines 1.23 removed ClusterTasks:** Must use `resolver: cluster` with params `kind: task`, `name: <task>`, `namespace: openshift-pipelines`. Parameter names are uppercase (`URL`, `REVISION`, `TLS_VERIFY` not `TLSVERIFY`). git-clone workspace is `output` not `source`.
- **Cosmos3-Edge is a world model, not a text LLM:** `/v1/chat/completions` returns `image_url` with base64 PNG, not text. Text-only scoring for curation is impossible without a separate Reasoner container (D006).
- **vLLM on Thor requires workarounds:** CUDA pre-init (`torch.zeros(1, device="cuda")`), `VLLM_ENABLE_V1_MULTIPROCESSING=0`, `HF_HUB_DISABLE_XET=1`. See D002/D003.
- **NVIDIA device plugin must use envvar strategy:** CDI mode unsupported on Jetson (D004). Requires hostPath mount of `/usr/lib64/nvidia`.
- **registries.d required alongside policy.json (D018):** `policy.json`'s `sigstoreSigned` rule declares *what* to require, but `registries.d` with `use-sigstore-attachments: true` is required for `containers/image` to actually look for the cosign signature. Without it, signed pulls fail silently. This was a pre-existing gap since the first bootc image, invisible because earlier images had no `sigstoreSigned` rule and the OS image was always pulled under `insecureAcceptAnything`.
- **cosign v3 vs v2 tag scheme:** cosign v3.1.3 (Homebrew) defaults to OCI 1.1 referrers tag scheme, which this OpenShift registry version rejects with 500 `UNKNOWN`. Use cosign v2.6.5+ (matching the Tekton pipeline, D022) for manual signing against this registry.
- **flightctl-agent's hard `greenboot` dependency (D022):** pinning `flightctl-agent` to any stable release (1.1.x/1.2.x) requires the `greenboot` package to be installed — it's a hard `Requires`, dropped only in the `1.3.0~rc1` pre-release. `greenboot` isn't available from the flightctl EPEL10 repo or any other repo already configured in this Containerfile; it has to be pulled directly from the CentOS Stream 10 AppStream mirror.
- **crane vs buildah for modelcar packaging (D017):** `buildah bud` with FUSE-backed `fuse-overlayfs` in Tekton pods has catastrophic throughput for multi-GB single-layer images (tens of KB/s sustained). `crane append` streams directly to/from the registry API and pushed ~10GB in under 5 minutes.
- **Deployment strategy for single-GPU pods:** `RollingUpdate` can't roll a single-GPU pod — the surge pod fails to schedule (`Insufficient nvidia.com/gpu`). Changed to `strategy: type: Recreate`.
- **flightctl-agent silently disables all third-party greenboot checks, every boot (D023, closed):** `flightctl-configure-greenboot.service` runs before `greenboot-healthcheck.service` on every boot and unconditionally adds any `required.d/` script it doesn't recognize (core greenboot names or `*flightctl*`-named) to `DISABLED_HEALTHCHECKS` — no allowlist mechanism exists in flightctl-agent 1.2.0. A direct edit to `greenboot.conf` is a no-op; it gets overwritten before greenboot runs. Fix: mask `flightctl-configure-greenboot.service` in the image. Doing this surfaced a second, previously-undetectable bug: `40_microshift_running.sh` hardcoded `/usr/bin/oc`, but `oc` is installed to `/usr/local/bin/oc` — the check had never actually passed because it had never actually run. Both fixes verified end-to-end from a clean Tekton-built image (not just live `/etc` patches) — all three required checks now genuinely pass every boot, confirmed via `boot_success=1` in the grubenv and real `success!` log lines in the greenboot journal. See D023.

## Key Decisions / Learnings

Twenty-nine decisions documented in DECISIONS.md (D001–D029). Most impactful:
- **D008:** Static cosign keypair + RHTAS Rekor (not full keyless) — pragmatic trust plane without OIDC complexity
- **D009:** qemu cross-build on x86 OSD nodes — no Graviton available, works with privileged SCC
- **D010:** Embed workload images in bootc — Red Hat's documented air-gapped MicroShift pattern, single delivery vehicle
- **D013:** Bootc image is the only delivery mechanism — no dual connected/disconnected paths
- **D014:** Model weights as signed modelcar OCI artifact — eliminates ungoverned HuggingFace downloads, same sigstore verification as all other artifacts
- **D015:** Sigstore policy scoped to internal registry — single source of truth for governed artifacts
- **D017:** crane (not buildah) for modelcar packaging in Tekton — order-of-magnitude faster for pure data artifacts with no build logic
- **D018:** `registries.d` `use-sigstore-attachments` required alongside `policy.json` — both config surfaces needed for sigstore verification
- **D019:** bootc enforces `policy.json` per-registry rules identically to CRI-O — the `ostree-unverified-registry` transport prefix is misleading; trust chain is intact for both OS image and workload pulls
- **D020:** Pre-resolve model path in entrypoint — closes D014's HF_TOKEN fallback gap, fully air-gapped model serving with `HF_HUB_OFFLINE=1`
- **D022:** cosign v2.6.5 + pinned flightctl-agent 1.2.0 — CVE remediation (GHSA-fx35-mq7g-6g98, CVE-2026-32280/33186/33815/39821); surfaced and fixed a real greenboot rollback hazard along the way
- **D023:** Masked flightctl's `configure-greenboot.service` (it silently disabled the two custom greenboot checks every boot, with no allowlist mechanism) and fixed a latent `oc` path bug the masking had been hiding — neither custom check had ever actually run before this session. Verified end-to-end from a clean pipeline-built image (not just live `/etc` patches) same session.
- **D028:** Perses server never deployed because a second, separate `perses-operator` (not the main COO `uiplugin` controller D027 first suspected) gates workload creation on `spec.config.database` being set — D021's CR shipped `spec: {}`. Fixed, plus two more real bugs found getting the dashboard to actually render (a `$ref` path convention, a query-plugin name/shape mismatch); dashboard now genuinely reachable and GitOps-managed.
- **D029:** D024's SA consolidation missed Thor's own `bootc` pull credentials (still referenced the deleted `thor-puller` SA) — a real gap in that cleanup's verification scope, only surfaced when it broke a live `bootc switch`. Also documents a reproducible `bootc` `SIGABRT` crash during image staging (workaround: simple retry, image was already cached).

Key learning: the gap between "BuildConfig works" and "Tekton pipeline works" for cross-arch builds is significant. Docker strategy in BuildConfig runs fully privileged; Tekton buildah does not by default. Production cross-arch Tekton pipelines need explicit privileged SCC and a custom Task.

## Items of Interest

- **Cosign private key** is stored as `cosign-signing-key` Secret in `thor-builds` namespace (also was at `/tmp/thor-signing.key` on the build desktop — may need backup)
- **Rekor transparency log** has entries at `https://rekor-server-trusted-artifact-signer.apps.g4h4d3j7q1c9f7m.cimo.p1.openshiftapps.com`
- **Thor SSH:** `ssh thor` (10.0.0.42), key-based auth, root sudo
- **Hub cluster:** `api.g4h4d3j7q1c9f7m.cimo.p1.openshiftapps.com:6443`, user `jary@redhat.com`
- **Internal registry route:** `default-route-openshift-image-registry.apps.g4h4d3j7q1c9f7m.cimo.p1.openshiftapps.com`
- **Image currently on Thor:** `sha256:c69b050b1e64920534fd348182a9105c8b2833c9177a5d270910c296a1fd101d` (2026-08-12 rebuild — D023's greenboot fix baked in from a clean Tekton build and verified end-to-end, cosign v2.6.5-signed, flightctl-agent 1.2.0, CRI-O `1.35.6-4...git41f610b`). Rollback target on the device is the previous image, `sha256:e3b8c951...` (D022).
- **Flywheel workloads** are defaulted to replicas=0 in gitops manifests — scale up with `oc scale` or edit manifests for demos
- **combined-registry-auth** Secret refreshed 2026-08-12 (APPENG-6007) — new 30-day token, expires 2026-09-11, will need another refresh before then
- **Demo runbook** exists at DEMO_RUNBOOK.md — 15-minute three-act demo structure with pre-flight checklist

## Related Docs

- `PROJECT-BRIEF.md` — full architecture vision, phased build plan, demo script outline
- `DEPLOYMENT_GUIDE.md` — step-by-step reproducible setup (all phases)
- `DECISIONS.md` — D001–D025 decision log with rationale
- `DEMO_RUNBOOK.md` — demo script with pre-flight checklist
- `PHASE0-FINDINGS.md` — initial Thor audit (OS, GPU, networking, storage)
- `UNDERSTANDING_THE_BUILD.md` — deep-dive on the centos-bootc-tegra + sidecar build chain
- `VLLM_ON_THOR.md` — full path from boxed Thor to serving inference, all blockers and fixes
- `VLLM_OMNI_UPGRADE_RESEARCH.md` — vLLM-Omni v0.26.0 upgrade research (D025), proposal only
