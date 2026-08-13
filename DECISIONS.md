# Decisions Log

> [!NOTE]
> This project was developed with assistance from AI tools.

## D001: MicroShift 4.22 el9 RPMs on CentOS Stream 10

**Date:** 2026-08-06
**Decision:** Install MicroShift 4.22 RC5 (el9 RPMs) on CentOS Stream 10 aarch64.
**Rationale:** MicroShift 4.22 enables ImageVolume by default (K8s 1.35 beta=true),
which is needed for KServe modelcar OCI image mounts without feature gate configuration.
No el10 RPMs exist for any MicroShift version on aarch64 (only el9 on the mirror).
MicroShift is Go (statically compiled), so el9 binaries run on el10.
**Risk:** CRI-O or networking plugins may have el9/el10 ABI mismatches. Mitigated by
`--nobest` during install and testing.
**Fallback:** MicroShift 4.18 el9 with manual ImageVolume feature gate enablement.

## D002: CUDA pre-initialization workaround for vLLM

**Date:** 2026-08-06
**Decision:** All vLLM workloads must call `torch.zeros(1, device="cuda")` before
importing vLLM. Implemented as an init script or container entrypoint wrapper.
**Rationale:** vLLM's model config creation calls CUDA in a sequence that fails on
Thor's OpenRM driver (595.78). Pre-initialization puts the runtime in a working state.
**Risk:** Fragile; may break with vLLM updates. Monitor on version changes.

## D003: VLLM_ENABLE_V1_MULTIPROCESSING=0

**Date:** 2026-08-06
**Decision:** Disable vLLM v1 engine multiprocessing on Thor.
**Rationale:** The EngineCore subprocess cannot see the GPU through CDI/CRI-O device
passthrough. Standalone spawned processes can see the GPU; the issue is specific to
vLLM's parent-process CUDA init poisoning child state. Running in-process avoids it.
**Risk:** Performance impact from no async engine core. Acceptable for edge single-model
serving.

## D004: NVIDIA device plugin envvar strategy (not CDI, not GPU Operator)

**Date:** 2026-08-06
**Decision:** Use k8s-device-plugin DaemonSet with `DEVICE_LIST_STRATEGY=envvar`, not the GPU Operator or CDI mode.
**Rationale:** Jetson doesn't support the CDI device-list mode ("CDI options are only supported on NVML-based systems"). GPU Operator is too heavy for MicroShift. Envvar strategy + hostPath mounts for `/usr/lib64/nvidia` is the working path.
**Fallback:** None needed — this is the NVIDIA-documented approach for Jetson + K8s.

## D005: RHEM org-admin role workaround (flightctl v1.1.0 bug)

**Date:** 2026-08-06
**Decision:** Use `flightctl-org-admin-flightctl` ClusterRole instead of `flightctl-admin-flightctl` for per-org RBAC.
**Rationale:** flightctl v1.1.0 `BuildReportedOrganizations()` silently drops `flightctl-admin` from per-org RoleBindings — it's treated as global-only, requiring `system:cluster-admins` group. OSD uses `cluster-admins` (different group). The `org-admin` role isn't filtered out.
**Risk:** Bug may be fixed in flightctl v1.2+. Remove workaround when upgrading.

## D006: Heuristic curation instead of model-based scoring

**Date:** 2026-08-07
**Decision:** On-device episode curator uses heuristic quality signals (failure flag, latency budget, inference errors) rather than LLM-based scoring.
**Rationale:** Cosmos3-Edge in omni mode treats all /v1/chat/completions requests as diffusion — text-only scoring is impossible without a separate Reasoner container (which would double GPU memory). Heuristic curation matches standard robotics on-device patterns.
**Fallback:** Deploy a separate Reasoner instance (no `--omni`) if memory budget allows.

## D007: Argo CD push via ACM cluster-proxy (not pull model)

**Date:** 2026-08-07
**Decision:** Use ACM cluster-proxy tunnel for Argo → Thor workload delivery, not the Argo pull-model agent.
**Rationale:** The cluster-proxy addon is already running on Thor for ACM management. It provides outbound-only connectivity (Thor → hub tunnel) that Argo syncs through. Achieves zero inbound connections without deploying a separate Argo agent on MicroShift.
**Risk:** Depends on ACM cluster-proxy stability. Brief preferred pull model but proxy achieves the same connectivity posture.

## D008: Static cosign keypair with RHTAS Rekor (not full keyless)

**Date:** 2026-08-07
**Decision:** Sign images with a static cosign keypair, upload signatures to RHTAS Rekor for transparency logging. Device verifies via public key in policy.json.
**Rationale:** Full keyless signing requires an OIDC client registered with OSD's OAuth server and browser-based auth flow. Static keys demonstrate the same trust mechanics (signed admits, unsigned refuses) while keeping Rekor entries for auditability. RHTAS is installed and running for the full infrastructure story.
**Fallback:** Upgrade to keyless when OIDC client registration is configured.

## D009: qemu-user-static cross-build for arm64 images

**Date:** 2026-08-07
**Decision:** Cross-build arm64 bootc images on x86 OSD nodes via qemu-user-static DaemonSet + OpenShift BuildConfig.
**Rationale:** No Graviton machinepools available on OSD. RHEM's ImageBuild API only injects flightctl-agent (can't handle custom Containerfiles). Mac builds work but are laptop-bound. qemu emulation on x86 is slower but fully automated and cluster-native.
**Fallback:** AWS CodeBuild arm64 fleet or ephemeral Graviton spot instances.

## D010: Embed workload images in bootc for air-gapped operation

**Date:** 2026-08-07
**Decision:** Pre-pull workload container images into the bootc OS image during build using `skopeo copy` to `dir:` layout. A systemd `ExecStartPre` on `microshift.service` loads them into CRI-O's `containers-storage:` at boot.
**Rationale:** This is Red Hat's documented pattern for disconnected MicroShift. Eliminates the need for a device-side registry. Images are available at boot with zero network access. Signature verification happens at build time in the pipeline, not at pull time on the device.
**Rejected:** Local registry:2 on device (not documented in RH MicroShift ecosystem), `oc mirror` (overkill for individual images — designed for full OCP release payloads).

## D011: OTel collector as RPM systemd service (not container)

**Date:** 2026-08-07
**Decision:** Install `opentelemetry-collector` RPM from CentOS Stream 10 AppStream into the bootc image. Run as a systemd service, not a Kubernetes Deployment.
**Rationale:** The upstream contrib container fails on arm64 (dynamic library issues). The RPM is the Red Hat-documented approach for edge devices — gives host-level access to journald, hostmetrics, and GPU telemetry without Kubernetes RBAC or hostPath mounts. Includes SELinux policy for journald access.
**Fallback:** MicroShift 4.20+ built-in observability service (if available in 4.22).

## D012: BuildConfig output to internal registry (not Quay)

**Date:** 2026-08-07
**Decision:** Push built bootc images to the OSD cluster's internal OpenShift registry, not Quay.io. Images are mirrored to devices via the embedded-in-bootc pattern.
**Rationale:** The internal registry is the hub-side source of truth. Air-gapped devices receive images embedded in the OS image, not pulled from an external registry.

## D013: Single delivery vehicle — bootc image contains everything

**Date:** 2026-08-07
**Decision:** The bootc image is the only delivery mechanism. All workload container images, configuration, trust anchors, and eventually model weights are embedded in the bootc image at build time. There is no separate "connected mode" that pulls from registries at runtime.
**Rationale:** Maintaining two delivery paths (embedded for air-gapped, pull for connected) creates divergence. One image, one path, one verification. The only external pull is the bootc image itself, from the internal registry to the device, managed by RHEM.

## D014: Model weights as modelcar OCI artifact in internal registry

**Date:** 2026-08-07 (implemented 2026-08-10)
**Decision:** Model checkpoints will be packaged as KServe modelcar OCI artifacts and stored in the internal OpenShift registry. Delivery to the device is via embedding in the bootc image (air-gapped) or via MicroShift ImageVolume mount (if supported). HuggingFace downloads at runtime are eliminated.
**Rationale:** Model provenance is a safety-relevant property. An ungoverned HuggingFace download bypasses the trust plane. Packaging as an OCI artifact enables signing (RHTAS), versioning, and the same sigstore verification used for all other artifacts.
**Status:** Implemented for the currently-running Cosmos3-Edge checkpoint (see `modelcar/`). Full production wiring (post-training pipeline outputs auto-packaged as modelcars) still deferred to Phase 4.
**Implementation notes:**
- `modelcar/Containerfile` packages the actual runtime dependency set — `nvidia/Cosmos3-Edge` plus the guardrail/safety models vLLM-Omni loads internally (`nvidia/Cosmos-1.0-Guardrail`, `Qwen/Qwen3Guard-Gen-0.6B`), ~10.2GB total — not the full HF cache on Thor, which also holds `ibm-granite/granite-3.2-2b-instruct` for the unrelated `serve-granite.sh` bare-podman deployment.
- MicroShift's ImageVolume (native OCI-image-as-volume mount) wasn't attempted — likely alpha/unavailable on 4.22 RC5 — so delivery uses the more portable **initContainer copy** pattern instead: the modelcar image (based on `python:3.12-slim`, already cached on Thor, so it has `cp`) is pulled as an initContainer that copies its baked-in `/models/huggingface` into a shared `emptyDir`, which the main vLLM container mounts at `/root/.cache/huggingface`. `HF_HUB_OFFLINE=1` on the main container prevents any runtime network fallback. `HF_TOKEN`/`hf-credentials` Secret dependency removed from the Deployment.
- Built and pushed directly on Thor via `podman` (avoids transferring ~10GB over the network twice); signed via `cosign` v2.4.1 from the Mac against the image digest (signing only touches the small manifest, not the layers).
- **Gotcha:** cosign v3.1.3 (current Homebrew release) defaults to the OCI 1.1 "referrers" tag scheme (`sha256-<digest>`) for pushing signatures, which this OpenShift internal registry version rejects with a 500 `UNKNOWN` error. The existing signed OS image (`thor-edge`) uses the older cosign v2.x tag convention (`sha256-<digest>.sig`), matching the Tekton pipeline's pinned `COSIGN_VERSION: v2.4.1`. Fix: use cosign v2.4.1 for any manual/local signing against this registry until it's confirmed to support OCI 1.1 referrers (or the registry is upgraded).
- **Gotcha:** the deployment's default `RollingUpdate` strategy can't roll a single-GPU pod — the surge pod fails to schedule (`Insufficient nvidia.com/gpu`) while the outgoing pod still holds it. Changed to `strategy: type: Recreate`.
- **Gotcha:** an accidental first sign attempt omitted `--rekor-url`, so it logged to the public `rekor.sigstore.dev` instead of the internal RHTAS Rekor route before being corrected. Both signatures now exist on the image (cosign appends rather than replaces); the public entry contains only the image digest and public key, nothing sensitive, but is a process reminder to always pass `--rekor-url` explicitly for internal-registry artifacts per D015.
- **Gotcha:** `cp -a /models/huggingface /hf-cache/` copies `huggingface` in *as a subdirectory* of the destination (`/hf-cache/huggingface/...`), not its contents directly into it. Since the main container mounts the same emptyDir at `/root/.cache/huggingface`, this produced a double-nested `/root/.cache/huggingface/huggingface/hub/...` that `snapshot_download()` couldn't find, failing with `LocalEntryNotFoundError` even though the modelcar image itself had a complete, correctly-structured cache (verified independently via `podman run` against the image). Fixed with `cp -a /models/huggingface/. /hf-cache/` (trailing `/.` copies contents, not the directory itself).
- **Gotcha (accepted, not fully closed):** with `HF_HUB_OFFLINE=1`, the pod loaded the top-level Cosmos3-Edge model successfully (proving the modelcar is a viable primary source) but then crashed inside `vllm_omni`'s `DiffusionWorker` subprocess, which loads the tokenizer/VAE via `AutoTokenizer.from_pretrained(model_path, subfolder="text_tokenizer", local_files_only=os.path.exists(model_path))` in `pipeline_cosmos3.py`. In that worker process, `model_path` is apparently still the unresolved repo id (`"nvidia/Cosmos3-Edge"`), not the `snapshot_download()`-resolved absolute path, so `os.path.exists(model_path)` is `False` and it falls through to `local_files_only=False` — which `HF_HUB_OFFLINE=1` then hard-fails outright rather than letting normal HF cache-first resolution find the (fully present) local files. This looks like an upstream `vllm-omni` framework quirk, not something worth patching in the vendor image under demo time pressure. **Resolution:** dropped `HF_HUB_OFFLINE=1`, restored `HF_TOKEN`/`hf-credentials` as a narrow fallback. The modelcar is still the primary, governed weight-delivery path (initContainer populates the full local cache before the main container starts, and normal `huggingface_hub` cache-first resolution finds everything there without hitting the network in practice) — the token now only covers this one internal-subprocess edge case rather than being the primary download mechanism. Fully closing this (removing the HF_TOKEN fallback entirely) would need either an upstream vllm-omni fix or pre-resolving `od_config.model` to an absolute path before it's handed to the worker subprocess.

## D017: crane, not buildah, for packaging the modelcar in Tekton

**Date:** 2026-08-10
**Decision:** The Tekton pipeline that builds the modelcar (`tekton/05-modelcar-pipeline.yaml`) uses `crane append` (`tekton/07-package-modelcar-task.yaml`) to append the downloaded HF weights as a single layer onto a base image, instead of the `buildah-cross-arch` Task the OS image pipeline uses. Everything else about the pipeline matches the OS image's process and controls exactly: built on the hub cluster in `thor-builds`, pushed to the same internal OpenShift registry, signed by the same `cosign-sign` Task against the same internal RHTAS Rekor.
**Rationale:** The modelcar has no build logic — no `RUN` steps, just one `COPY` of pre-downloaded weights — so `buildah bud`'s full build-graph machinery is the wrong tool for it. Measured directly: two full `buildah bud` attempts (first with the default `vfs` storage driver, then with `overlay` explicitly set) each took over an hour and were still not finished pushing a single ~10-27GB layer when cancelled — confirmed via `/proc/net/dev` byte counters showing near-zero sustained throughput (tens of KB/s) rather than genuine progress. Root cause: `buildah` inside this Tekton pod uses `fuse-overlayfs` (userspace FUSE), not native kernel overlay — every read of the huge layer during commit/push round-trips through FUSE's userspace daemon, which is catastrophic at this data scale. This is unrelated to buildah's use for the OS image, which is built from many small RPM-install layers (KB-MB range each) where this bottleneck never surfaces.
`crane append` operates purely on OCI blobs/manifests streamed directly to/from the registry API, with no container storage driver, no overlay/FUSE layer, and no `Containerfile` at all. The same ~10GB of data pushed in under 5 minutes once switched.
**Risk:** `crane`/`go-containerregistry` is a different toolchain than `buildah` (Apache-2.0 licensed, no distribution concerns using the CLI). Since the modelcar is the only artifact in this repo built this way, there's no toolchain fragmentation across the *other* pipelines (OS image still uses buildah as before) — this is scoped narrowly to artifacts with no real build step.
**Fallback if this stops being viable:** revisit whether the workspace PVC's CSI driver can be swapped for one that supports native overlay mounts (would let `buildah` work as expected); or use `skopeo copy` against a manually-assembled `dir:` OCI layout, matching this repo's existing air-gapped embedded-image pattern (D010).
**Also fixed in this pass:** the CI-side HF download (`tekton/04-download-weights-task.yaml`) was over-fetching `nvidia/Cosmos-1.0-Guardrail` as its full ~17GB repo via unfiltered `snapshot_download()`, versus the ~130MB Thor's live runtime cache actually materializes (confirmed via `find .../snapshots -type f -o -type l` on Thor: only `face_blur_filter/*` and `blocklist/*` are read by `vllm-omni`'s Cosmos3 guardrails). Added `allow_patterns` scoped to that one repo.

## D015: Sigstore policy scoped to internal registry

**Date:** 2026-08-07
**Decision:** The device's `policy.json` enforces `sigstoreSigned` for the internal OpenShift registry route, not Quay.io. All governed artifacts (OS images, model images) flow through the internal registry.
**Rationale:** The internal registry is the single source of truth. Scoping trust enforcement to it ensures nothing reaches the device without passing through the hub's signing pipeline. External registries (Docker Hub, Quay, NGC) are only consumed at build time, never at device runtime.

## D016: Perses replaces Grafana for observability dashboards

**Date:** 2026-08-07
**Decision:** Use Perses (GA in COO 1.5) for observability dashboards instead of the community Grafana operator. Dashboards are console-integrated and declared via `PersesDashboard` CRs.
**Rationale:** Red Hat deprecated the built-in Grafana and does not support the community operator. Perses is the forward path — GA, console-integrated, with Grafana dashboard import tooling. COO UIPlugins provide distributed tracing and logging views in the console.

## D018: registries.d `use-sigstore-attachments: true` required alongside policy.json

**Date:** 2026-08-10
**Decision:** Ship `derived-image/config/registries.d-internal-registry.yaml` in the bootc image, setting `use-sigstore-attachments: true` for the internal OpenShift registry route, alongside the existing `policy.json`.
**Rationale:** `policy.json`'s `sigstoreSigned` policy type declares *what* to require, but `containers/image` has a **separate** configuration surface (`/etc/containers/registries.d/*.yaml`) that controls *whether it even looks for* a cosign-style signature at all. Without `use-sigstore-attachments: true`, every pull from a `sigstoreSigned`-policed registry is treated as if it has no attachments and is rejected with `"A signature was required, but no signature exists"` — even when a valid, independently-verifiable signature is present in the registry.
**How this was found:** discovered 2026-08-10 while validating the Tekton-built modelcar's live deployment on Thor — the initContainer's image pull failed with `SignatureValidationFailed`. Root-caused via `skopeo copy --debug`, which logged the exact reason: `"Not looking for sigstore attachments: disabled by configuration"`. Before taking any action, verified this was **not** caused by the buildah→crane packaging change (D017) by reproducing the identical failure pulling the already-shipping OS image (`thor-edge`, built via `buildah`, signed by the same `cosign-sign` Task) through the same `skopeo copy --policy /etc/containers/policy.json` path. Also confirmed via raw `curl` against the registry's `/v2/.../manifests/sha256-<digest>.sig` endpoint that the signature itself is present and well-formed (`HTTP 200`), and via `cosign verify` that it's cryptographically valid.
**Why this was invisible until now:** this is a genuine, pre-existing gap that has existed since the very first bootc image build (`/etc/containers/registries.d/default.yaml` on Thor was confirmed byte-identical to the base image's `/usr/etc/containers/registries.d/default.yaml` — the derived image never touched it). It was never exercised because (1) every previously-pulled workload image is public and hits `policy.json`'s `insecureAcceptAnything` default branch, never touching the `sigstoreSigned` path; (2) the one internal-registry image tested before (the modelcar's first manually-built `:v1` tag) happened to already be resident in Thor's local CRI-O/podman shared storage from being built directly on Thor, so `imagePullPolicy: IfNotPresent` skipped the pull-and-verify cycle entirely, never actually exercising a real authenticated, signature-checked pull; and (3) the OS image itself reaches the device via `bootc switch`, a separate ostree-based pull mechanism, not CRI-O's kubelet pull path, and was never confirmed to go through this same policy.json/registries.d enforcement.
**Verification:** after applying the fix live on Thor (and baking it into the Containerfile for future images), `skopeo copy --policy /etc/containers/policy.json` against both `thor-edge` and `cosmos3-edge-modelcar` succeeded; the modelcar's initContainer pulled and completed (`exitCode: 0`) via a genuine Kubernetes pod pull/verify cycle; live inference confirmed working end to end (`HTTP 200`, valid generated image).
**Open question, resolved in D019:** whether the OS image's own `bootc switch` pull path is subject to the same `registries.d` requirement, or uses different defaults/mechanism entirely. **Answer: yes, it uses the same `policy.json` + `registries.d` enforcement as CRI-O/podman. See D019 for full investigation.**

## D019: bootc switch enforces policy.json per-registry rules (trust chain confirmed intact)

**Date:** 2026-08-11
**Decision:** The OS image pull via `bootc switch` / `bootc upgrade` **does** enforce `policy.json` per-registry rules, including `sigstoreSigned`, via the same `containers/image` library (skopeo) that CRI-O and podman use. The `ostree-unverified-registry` transport prefix visible in `rpm-ostree status` is misleading — it only affects bootc's own pre-flight validation (which does not *require* the `default` policy to enforce signatures), but does not bypass skopeo's per-registry policy enforcement during the actual image pull. **No gap exists in the current configuration.** The D018 fix (`registries.d/internal-registry.yaml` with `use-sigstore-attachments: true`) is required by bootc for the same reason it's required by CRI-O.

**Rationale / investigation:**

1. **Initial (incorrect) hypothesis:** the `ostree-unverified-registry` transport prefix in `rpm-ostree status` suggested bootc was bypassing `policy.json` entirely. The `bootc switch` on 2026-08-10 from `quay.io/jary/thor-edge:latest` to the internal OpenShift registry succeeded at 15:50 UTC, but `registries.d/internal-registry.yaml` was not created until 22:11 UTC — appearing to prove the pull succeeded without signature enforcement.

2. **Corrected root cause:** the Aug 10 `bootc switch` was executed while the **old** quay.io-based OS image was running. That image was built from the initial Containerfile (pre-`f1dbe9f` commit of Aug 7), whose `policy.json` contained only `default: insecureAcceptAnything` — no `sigstoreSigned` rule for the internal registry existed at all. The pull succeeded because there was **no signature requirement to enforce**, not because bootc bypassed enforcement.

3. **Definitive live test (2026-08-11):** with the current running image (which has the `sigstoreSigned` policy for the internal registry), temporarily removing `registries.d/internal-registry.yaml` and running `skopeo copy` (without `--insecure-policy`, matching bootc's proxy invocation) against the internal registry produced: `"Source image rejected: A signature was required, but no signature exists"` — the same error CRI-O produced before D018. Restoring the file made the copy succeed and verify the signature. This proves the per-registry `sigstoreSigned` rule is enforced identically in the bootc pull path.

4. **Source code confirmation:** bootc invokes `containers-image-proxy` (skopeo `experimental-image-proxy`) **without** `--insecure-policy` for the `ContainerPolicyAllowInsecure` variant (`crates/lib/src/deploy.rs:new_proxy_config()`). The only difference between `ContainerPolicy` (strict) and `ContainerPolicyAllowInsecure` (default) is that `ContainerPolicy` adds a bootc-side pre-check rejecting `default: insecureAcceptAnything` before the pull starts (`crates/ostree-ext/src/container/store.rs:prepare_internal()`). Skopeo's own per-registry policy enforcement runs in both cases.

5. **`--enforce-container-sigpolicy` is not needed for our use case.** This flag maps to `ContainerPolicy` (strict), which rejects any `policy.json` where the `default` is `insecureAcceptAnything`. Our `policy.json` has `default: insecureAcceptAnything` (necessary for public images), with a per-registry `sigstoreSigned` override for the internal registry. The per-registry rule is what provides security, and it's enforced without the flag.

**Current trust chain status (all verified on the live system):**
- **CRI-O workload/modelcar pulls from internal registry:** `policy.json` `sigstoreSigned` rule + `registries.d` `use-sigstore-attachments: true` → signature verified at pull time. Confirmed by D018 testing.
- **bootc OS image pull from internal registry:** same `policy.json` + `registries.d` → signature verified at pull time. Confirmed by the live `skopeo copy` test in this investigation.
- **Public image pulls (Docker Hub, Quay, NGC):** hit `default: insecureAcceptAnything` → no signature required. This is intentional for public images not in our signing scope.

**Note on `ostree-unverified-registry` prefix:** this is a cosmetic/naming artifact of bootc using `ContainerPolicyAllowInsecure` as its default `SignatureSource`. It does not indicate that signatures are not verified — only that bootc does not pre-reject an `insecureAcceptAnything` default. The actual enforcement happens in skopeo. This naming has caused confusion in the ostree/bootc community before (see upstream `security.md` which addresses this explicitly).

**Status:** Investigation complete. No gap. No code changes needed. D018's `registries.d` fix is confirmed necessary and sufficient for both CRI-O and bootc pull paths.

## D020: Pre-resolve model path in entrypoint to close HF_TOKEN fallback gap

**Date:** 2026-08-11
**Decision:** Resolve the HF repo id (`nvidia/Cosmos3-Edge`) to its absolute local snapshot path in the entrypoint script *before* passing it to `vllm serve`, restoring `HF_HUB_OFFLINE=1` and eliminating the `HF_TOKEN`/`hf-credentials` Secret dependency entirely.
**Rationale:** D014's modelcar OCI artifact delivers model weights as the primary, governed source, but left `HF_TOKEN` as a narrow fallback for a vllm-omni framework quirk: the `DiffusionWorker` subprocess (`pipeline_cosmos3.py:866-867`) sets `local_files_only = os.path.exists(od_config.model)`, where `od_config.model` is the bare repo id `"nvidia/Cosmos3-Edge"` — which doesn't exist as a filesystem path, so `os.path.exists()` returns `False` and `local_files_only` becomes `False`. Under `HF_HUB_OFFLINE=1`, the subsequent `AutoTokenizer.from_pretrained(..., local_files_only=False)` hard-fails because HF hub rejects any network call in offline mode.

The fix is a single `snapshot_download('nvidia/Cosmos3-Edge', local_files_only=True)` call in the entrypoint, which returns the absolute snapshot path (e.g. `/root/.cache/huggingface/hub/models--nvidia--Cosmos3-Edge/snapshots/2a00e87e...`) without any network access. This resolved path is passed to `vllm serve` instead of the bare repo id. Now `os.path.exists(od_config.model)` returns `True` in the DiffusionWorker, all `from_pretrained` calls use `local_files_only=True`, and `HF_HUB_OFFLINE=1` works correctly.

**Note:** vllm-omni already has `_resolve_model_to_local_path()` in `stage_init_utils.py:66` that does exactly this resolution — but it's only invoked when `model_subdir` or `tokenizer_subdir` is set in the engine args, not in the default path. This is an upstream gap; resolving in the entrypoint is a clean workaround that doesn't require patching the vendor image.

**Verification:** deployed to Thor, confirmed via logs (`Resolved model path: /root/.cache/...`), vLLM serving from absolute path, guardrails initialized from local cache, live inference returned HTTP 200 with valid generated image — all with `HF_HUB_OFFLINE=1` and no HF_TOKEN network fallback.

**Files changed:** `gitops/vllm-cosmos3/entrypoint-configmap.yaml` (add `snapshot_download` resolution), `gitops/vllm-cosmos3/deployment.yaml` (restore `HF_HUB_OFFLINE=1`, remove `HF_TOKEN`/`hf-credentials`).

**Status:** Implemented and verified. D014's trust story for model weights is now fully closed — no ungoverned HuggingFace network access at any point in the serving path.

## D021: Perses dashboard manifests for edge flywheel observability

**Date:** 2026-08-11
**Decision:** Create `gitops/observability/` with `PersesDashboard`, `PersesDatasource`, and `Perses` instance CRs for the edge flywheel observability stack. The dashboard queries robot-sim episode/inference trace spans from Tempo via the `TempoDatasource` plugin, keyed on `resource.service.name="robot-sim"` and span names `episode`/`inference`. Three panels: episode trace table, inference latency table, and failed-episode filter (`span.episode.has_failure=true`).
**Rationale:** D016 decided on Perses over Grafana for observability dashboards (GA in COO 1.5, console-integrated). The Perses instance, Tempo datasource, and a placeholder dashboard (`edge-flywheel`) were created manually on the hub cluster on 2026-08-07 but were not committed to this repo and had a configuration gap: the Perses CR lacked the `app.kubernetes.io/name: edge-perses` label that the `instanceSelector` on the datasource and dashboard require.
**Implementation notes:**
- The `Perses` CR spec is empty (`spec: {}`); the operator handles Perses server deployment. On COO 1.5.1, the operator creates a Service but **does not create a Deployment or Pod** for the Perses server — the Service endpoint has no backing pod, and all dashboard/datasource reconciliation fails with `connection refused`. This appears to be a COO/Perses operator issue, not a configuration error. The `Perses` CR status reports "created successfully" despite no server being functional. To be investigated separately.
- The dashboard and datasource CRs are structurally correct (validated by the operator's reconciler reaching the API-call stage, not failing on schema validation). Once the Perses server is running, they should bind automatically.
- All three CRs use `instanceSelector: matchLabels: app.kubernetes.io/name: edge-perses` to bind to the Perses instance.

**Status:** Manifests committed in `gitops/observability/`. Dashboard will become functional once the Perses server deployment issue is resolved.

## D022: Cosign v2.6.5 and pinned flightctl-agent 1.2.0 for CVE remediation

**Date:** 2026-08-12
**Decision:** Bump the Tekton signing task's `COSIGN_VERSION` default from `v2.4.1` to `v2.6.5`, and pin `flightctl-agent` to an explicit NVR (`flightctl-agent-1.2.0-1.el10`) in the derived image Containerfile instead of an unversioned `dnf install`.

**Rationale (cosign):** GHSA-fx35-mq7g-6g98 (High, CVSS 7.4) is a verification-bypass bug in `cosign verify-blob`/`verify-blob-attestation` when consuming legacy JSON bundles with a bare public key in the `cert` field — it lets an attacker skip OIDC identity/issuer pinning. Patched in v2.6.5 / v3.1.3.

**Audit findings:** thor-testing's actual exposure was minimal — the advisory explicitly excludes OCI image verification (`cosign verify`), which is the only verification path this repo uses (via `policy.json`/`registries.d`, not the cosign CLI). `tekton/01-cosign-sign-task.yaml` only calls `cosign sign` against OCI images. A repo-wide grep confirmed zero usage of `--bundle`, `verify-blob`, or legacy `LocalSignedPayload` handling. The Mac's Homebrew cosign was already v3.1.3 (patched). Still bumped the Tekton pin to close the gap defensively and stay off an unsupported version. Stayed in the v2.x line (not v3.x) per D014's existing registry tag-scheme constraint — v2.6.5 is a patch release, not expected to change signature format, but this should be re-verified against the internal registry the first time the pipeline runs post-upgrade.

**Rationale (flightctl-agent):** intel-scan flagged v1.1.3 as fixing CVE-2026-32280, CVE-2026-33186 (gRPC), CVE-2026-33815, CVE-2026-39821, plus an "updating" state hang when `boot-complete.target` exists without greenboot (directly relevant — Thor runs both). The Containerfile's `dnf install flightctl-agent` was unversioned, which is how Thor ended up running `1.3.0~rc1` — a pre-release build — simply because it was the newest package in the repo at enrollment time, not a deliberate choice.

**Audit findings:** Thor's live agent (`1.3.0~rc1`) already postdates and supersedes the `1.1.3` fixes, so there was no live vulnerability at the time of this audit. The real gap was the *lack of pinning*, which is non-reproducible and could just as easily have landed on an older, vulnerable RC at a different build time. Chose to pin to `1.2.0-1.el10` — the latest **stable** (non-RC) release available in the repo — rather than downgrading to exactly `1.1.3`, since 1.2.0 is a superset of the 1.1.3 fixes and avoids shipping a pre-release build in a demo-facing image. This is a deliberate deviation from the literal "upgrade to v1.1.3" inbox item text in favor of the better outcome.

**Risk:** Rebuilding the bootc image with a pinned (older than currently-running) flightctl-agent will be an effective downgrade from `1.3.0~rc1` to `1.2.0` stable on next `bootc switch`. Acceptable — RC builds should not be running in what is otherwise being treated as a demo-stable environment, and `1.2.0` still carries all target CVE fixes.

**Verification:** confirmed both `flightctl-agent-1.2.0-1.el10.aarch64` resolves cleanly against the live `rpm.flightctl.io` EPEL10 repo, and Mac cosign version, via direct queries at implementation time. Full end-to-end verification (image build, sign, `bootc switch`, agent health, image pull signature verification) pending next pipeline run — see PROJECT_STATUS.md "What's not yet done" until closed out.

**Files changed:** `tekton/01-cosign-sign-task.yaml` (COSIGN_VERSION default), `derived-image/Containerfile` (flightctl-agent pin).

**Addendum (discovered during implementation):** the first attempt to pin `flightctl-agent-1.2.0-1.el10` failed the Tekton build with `nothing provides greenboot needed by flightctl-agent`. Confirmed via `dnf repoquery --requires` across versions that `1.1.3` and `1.2.0` both hard-`Requires: greenboot`, while `1.3.0~rc1` dropped that requirement — explaining why the previously-unpinned install silently landed on the RC without issue. The `greenboot` package itself was never installed in this image (confirmed via `rpm -q greenboot` on the live device: not installed) and is not present in the flightctl EPEL10 repo or any other repo already configured in the Containerfile (only the distinct `flightctl-greenboot` package is, which does not `Provide: greenboot`). Sourced it directly from the CentOS Stream 10 AppStream mirror instead (`greenboot-0.16.3-0.el10.aarch64.rpm`), the same direct-RPM-URL pattern already used for `unbound-libs` earlier in the Containerfile.

**Second-order risk found and fixed:** installing real `greenboot` for the first time activates its rollback-on-failure health check subsystem, which had been silently inert since `40_microshift.sh`/`40_vllm_gpu.sh` were added to `/etc/greenboot/check/required.d/` (files present, but greenboot itself never installed to execute them). Reviewing both scripts before shipping this live: `40_microshift.sh` already has a generous 300s retry loop. `40_vllm_gpu.sh` was a single-shot check with no retry — a real hazard given `nvidia-gpu-reset.service`'s documented Thor GCx workaround (GPU needs a module reload after boot, see D-series gotchas in PROJECT_STATUS.md) means the GPU may not be immediately usable at the moment greenboot runs its checks. A slow-but-healthy boot could have looked identical to a broken GPU and triggered an unwarranted automatic rollback, undoing this entire security fix on next boot. Added the same retry-loop pattern (18 attempts × 10s = 180s) to `40_vllm_gpu.sh` before activating greenboot for the first time.

**Files changed (addendum):** `derived-image/Containerfile` (greenboot RPM install step), `derived-image/greenboot/40_vllm_gpu.sh` (retry loop).

## D023: Mask flightctl's greenboot auto-configure service; fix a latent `oc` path bug it had been hiding

**Date:** 2026-08-12
**Decision:** Mask `flightctl-configure-greenboot.service` in the derived image, and fix `40_microshift_running.sh`'s hardcoded `/usr/bin/oc` path to `/usr/local/bin/oc` (where the Containerfile actually installs `oc`).

**Background:** PROJECT_STATUS.md's D022 follow-up item described the two custom greenboot checks as disabled via "a pre-existing, undocumented local override... that isn't tracked anywhere in this repo and predates this session." That characterization was wrong. Live investigation on Thor found the real mechanism: `flightctl-configure-greenboot.service` (shipped by `flightctl-agent`, `Before=greenboot-healthcheck.service`) runs on **every boot** and unconditionally rewrites `/etc/greenboot/greenboot.conf`'s `DISABLED_HEALTHCHECKS`, via a hardcoded function (`find_third_party_scripts` in `/usr/share/flightctl/functions/greenboot.sh`) that disables anything under `required.d/` it doesn't recognize as core greenboot or its own (`*flightctl*`-named). There is no allowlist/config knob in flightctl-agent 1.2.0 for a device owner to mark a custom check as trusted. A manual edit to `greenboot.conf` is a no-op — it gets overwritten before greenboot even runs, on every single boot, by design.

**What was tried and rejected:** editing `greenboot.conf` directly (reverts every boot, confirmed live); renaming the scripts to match `*flightctl*` (works but is dishonest metadata and fragile against future pattern changes in flightctl-agent).

**Decision made:** mask `flightctl-configure-greenboot.service` in the Containerfile (`RUN systemctl mask ...`), baked into the image rather than a local `/etc` override so it isn't subject to ostree's three-way merge behavior on future `bootc switch`. Trade-off: this also disables flightctl's gating of any *other* future third-party checks this image might ship — accepted since these two are the only third-party checks today, both already reviewed and hardened with bounded retry loops (D022 addendum).

**Critical bug found during live verification:** with the service masked and the checks actually running for the first time (they had never executed for real — flightctl's blanket-disable hid this), `40_microshift_running.sh` failed its full 300-second retry loop and exited 1, because it hardcodes `/usr/bin/oc`, but the Containerfile installs `oc` to `/usr/local/bin/oc` (`/usr/bin/oc` has never existed on this image). This triggered a real greenboot-initiated reboot (`boot_success=0`, `boot_counter` set) — caught and fixed live, before a second consecutive failure could trigger an actual bootc rollback (`MAX_BOOT_ATTEMPTS=3`). Fixed the path in `40_microshift.sh`, applied it live to `/etc/greenboot/check/required.d/40_microshift_running.sh` (survives plain reboots — this directory isn't ostree/ochre-merged), rebooted, and confirmed both checks now genuinely pass: `40_microshift_running.sh` in ~20s, `40_vllm_gpu.sh` in ~4s, `boot_success=1`, no rollback, same image digest booted throughout (`sha256:e3b8c9...`).

**This means neither custom check had ever actually been exercised in this image's history** until this session — greenboot was effectively a no-op safety net since it was first installed (D022), silently disabled every boot by flightctl-agent's default behavior, with a real bug (`oc` path) sitting undetected inside the one check that would have run if it were ever enabled.

**Verification:** post-fix reboot confirmed clean: MicroShift active, flightctl-agent active, ACM `ManagedClusterConditionAvailable=True`, Cosmos3-Edge pod reaches `1/1 Running` within ~90s of boot. Pre-existing stale/`UnexpectedAdmissionError` Cosmos3-Edge pods observed churning across the two reboots this session are a known, separate GitOps/single-GPU-`Recreate`-strategy issue (see PROJECT_STATUS.md gotchas) — not caused by this change, not addressed here.

**Files changed:** `derived-image/Containerfile` (mask flightctl-configure-greenboot.service), `derived-image/greenboot/40_microshift.sh` (`/usr/bin/oc` → `/usr/local/bin/oc`). Live device state (`/etc/greenboot/greenboot.conf`, masked service, corrected `/etc/greenboot/check/required.d/40_microshift_running.sh`) matches the repo changes; not yet re-verified against a fresh Tekton-built image (next rebuild will be the first to bake this in from a clean build rather than live patching).

**Addendum, 2026-08-12 (clean-image verification, closing the loop above):** rebuilt the OS image (Tekton `thor-edge-build-qr8nh`, includes both the flightctl-mask and the `oc`-path fix baked in from a clean build, digest `sha256:c69b050b1e64920534fd348182a9105c8b2833c9177a5d270910c296a1fd101d`), `bootc switch`ed Thor to it, and rebooted. Confirmed genuinely clean this time, from a fresh image rather than a live-patched one:
- `sudo bootc status`: booted digest matches the new image, `rollback` correctly points to the previous (pre-rebuild) digest, no rollback occurred.
- `greenboot-healthcheck` journal: all three required checks (`20_check_flightctl_agent.sh`, `40_microshift_running.sh`, `40_vllm_gpu.sh`) ran and logged genuine `success!` lines in sequence, `boot_success=1` set, `boot_counter` cleared — this is the first time these checks have ever executed against an image where the fixes were baked in rather than patched live on top of the previous image.
- MicroShift active, all workload pods `Running`/`Completed` within ~2 min of boot (one pre-existing stale `UnexpectedAdmissionError` pod from before the reboot, cleaned up — the known cosmetic issue, unrelated, see PROJECT_STATUS.md gotchas).
- Cosmos3-Edge: `1/1 Running`, inference endpoint `http://10.0.0.42:30800/health` returns `200` (from Thor itself — the documented `localhost:30800` OVN-hairpin gotcha still applies and was hit again here, using the real IP resolved it as expected).
- ACM: `oc get managedcluster thor` shows `JOINED=True`, `AVAILABLE=True` from the hub.

D023 is now fully closed — both the flightctl-mask and the `oc`-path fix are verified end-to-end from a clean pipeline build, not just live `/etc` patches. See D029 for a real, unrelated bug hit and fixed during this same verification pass (a stale ServiceAccount reference in Thor's `bootc` pull credentials, plus a reproducible `bootc switch` crash worth a paper trail).

## D024: Consolidate redundant thor-puller / thor-edge-puller ServiceAccounts

**Date:** 2026-08-12
**Decision:** Deleted `thor-puller` (SA, its `system:image-puller` RoleBinding, and its auto-generated `dockercfg` secret) from `thor-builds` on the hub. Kept `thor-edge-puller`.

**Investigation:** Both SAs grant `system:image-puller` scoped to `thor-builds`, created 3 days apart (`thor-puller` 2026-08-07, `thor-edge-puller` 2026-08-10). Traced `thor-edge-puller` to a real, active dependency: its token backs the `thor-registry-pull` Secret placed manually in Thor's own MicroShift `vllm` namespace (see `gitops/vllm-cosmos3/deployment.yaml`'s `imagePullSecrets`, and the commit that introduced it — Thor's CRI-O had no credentials for the hub's internal registry, needed for the pipeline-built modelcar's authenticated pull). Confirmed live: this token is a 1-year grant (expires 2027-08-10), currently in use. `thor-puller`, by contrast, has zero references anywhere — not in any manifest, not backing any Secret on the hub or on Thor, not used by any live pod/deployment/pipelinerun/taskrun (checked both clusters). It was an earlier, abandoned attempt before the naming settled on `thor-edge-puller`.

**Verification:** post-deletion, Cosmos3-Edge pod remains `1/1 Running` on Thor, unaffected (as expected — it never touched the deleted SA).

**Files changed:** none in-repo (`thor-puller` and its RoleBinding were never GitOps-managed — created manually on the hub, matching the `thor-registry-pull`/`hf-credentials`/`cosign-signing-key` convention of hand-created, non-declarative cluster resources).

## D025: vLLM-Omni v0.26.0 upgrade path researched (not implemented)

**Date:** 2026-08-12
**Status:** Research/proposal only. **No live changes made** — this environment has no cluster/SSH/Thor access. See `VLLM_OMNI_UPGRADE_RESEARCH.md` for the full writeup and the `research/vllm-omni-v0.26-upgrade` branch for the proposed (unmerged) `deployment.yaml` diff.

**Task:** evaluate whether `docker.io/vllm/vllm-omni:cosmos3` (currently deployed) should move toward the feature set in upstream vLLM PR [#48952](https://github.com/vllm-project/vllm/pull/48952) ("Cosmos3 FP8 ModelOpt/Diffusers remapping"), described in the task as a "v0.27.x-era" feature.

**Key findings:**
- `:cosmos3` is not one of vllm-omni's own release tags (its official pipeline only ever produces `latest`/`v<version>`/`nightly[-sha]`). Cross-referenced against this repo's own `VLLM_ON_THOR.md` (written from live Thor investigation): `:cosmos3` is pinned to vLLM 0.25.0 + vllm-omni **0.25.0rc2** — an unreleased release candidate, one stable release behind current.
- vllm-omni only stabilizes **even**-numbered vLLM minors (0.24, 0.26, ...). `v0.27.0` exists only as an rc1 tag and, per the project's stated policy, will not be promoted to stable — the "v0.27.x-era" framing in the task doesn't map onto any real stable vllm-omni release.
- The actual fix that matters here — PR #48952 is a vanilla-vLLM fix for the *Reasoner* (`Cosmos3ForConditionalGeneration`) text model, not the `--omni` diffusion Generator path this deployment runs — already has its diffusion-path equivalent (vllm-omni PRs #5076/#5087, same author) shipped in the already-released **stable v0.26.0** (2026-08-03). No v0.27.x needed.
- Bonus: v0.26.0 pins `torch==2.11.0` vs v0.27.0's `torch==2.13.0` — recommending v0.26.0 also avoids the PyTorch/Triton/FlashAttention-4 breaking-change risk called out in the task's own context, for free.
- Verified against the v0.26.0 tag directly: the D020 `os.path.exists(model_path)`/`local_files_only` quirk this repo's custom entrypoint works around is **unchanged, byte-for-byte**, through v0.26.0. The entrypoint needs **no functional changes** for this upgrade — removing its `snapshot_download` pre-resolution step would be wrong and would reintroduce the `HF_HUB_OFFLINE=1` breakage D020 closed.
- Docker Hub itself was unreachable from this research environment (confirmed via multiple failed transport-level probes, including a control test against `example.com`) — the existence/digest/arch-compatibility of a `v0.26.0` tag on `docker.io/vllm/vllm-omni` could not be directly confirmed, only inferred from the vllm-omni release pipeline's own publish scripts. This, and whether the generic multi-arch build is actually Thor/SM_110-compatible (vs. only server-class aarch64), are the biggest open risks — see the checklist in `VLLM_OMNI_UPGRADE_RESEARCH.md` §6.

**Recommendation:** candidate bump to `docker.io/vllm/vllm-omni:v0.26.0`, proposed as an unmerged diff on `research/vllm-omni-v0.26-upgrade`. Do not merge/sync until the live-validation checklist in `VLLM_OMNI_UPGRADE_RESEARCH.md` is closed out on real Thor hardware — none of GPU behavior, inference correctness, or the version-coupling risk `VLLM_ON_THOR.md` already documents between vLLM/vllm-omni minor versions has been (or could be) empirically checked here.

**Files changed:** `VLLM_OMNI_UPGRADE_RESEARCH.md` (new), this entry. `gitops/vllm-cosmos3/deployment.yaml` change lives only on the unmerged `research/vllm-omni-v0.26-upgrade` branch.

---

**Addendum: live-validated 2026-08-12, then reverted — real crash-loop regression found.**

Resolved the digest (`crane digest docker.io/vllm/vllm-omni:v0.26.0` →
`sha256:5cba1538c6f8ee81e8bea6708c24e68d7b2640f466a9fbf2ef15e68f2168b48b`),
confirmed a genuine arm64 manifest entry via `crane manifest` (closing the
biggest open risk above), and pinned by digest per D014 convention.

**First pass (manual, out-of-band `oc set image`, before any GitOps merge):**
clean Recreate rollout, pod reached `1/1 Running` in ~40s, CUDA pre-init OK,
weights loaded (311/311), "Cosmos3 guardrails initialized." No errors. Looked
like a clean pass. In hindsight this test window was too short — the crash
below happens ~90s into the *server* startup phase, which this manual test's
brief observation window didn't reach before Argo CD's `selfHeal: true`
(on the `vllm-cosmos3-thor` Application, correctly, since main didn't yet
have this change) reverted the manual edit back to `:cosmos3`.

**Second pass (real GitOps merge to `main`, Argo CD sync):** merged the
digest-pinned change, force-refreshed the `vllm-cosmos3-thor` Application,
watched it actually apply. This time the pod ran long enough to reach real
engine startup and **crash-looped**: `RuntimeError: Orchestrator
initialization failed: You have disabled the safety checker for
CosmosSafetyChecker. This is in violation of the NVIDIA Open Model License
Agreement ... Please install cosmos-guardrail package to enable safety
checks.` Confirmed via 2 consecutive restarts with identical tracebacks,
~90s apart. **v0.26.0's guardrails implementation hard-requires a separate
`cosmos-guardrail` PyPI package that this image does not have installed**,
and refuses to silently disable the safety checker (unlike whatever the
`:cosmos3` (0.25.0rc2) snapshot's guardrails did, which never hit this).

**Immediately reverted** `deployment.yaml` back to `docker.io/vllm/vllm-omni:cosmos3`,
force-refreshed Argo CD again, confirmed the pod returned to `1/1 Running`
with 0 restarts and a real inference request (`POST /v1/chat/completions`)
returned `HTTP 200` with a valid PNG. Total incident window: real service
disruption from the crash-loop was brief (one Argo sync cycle plus
diagnosis time) and self-contained to the `vllm` namespace's Cosmos3-Edge
deployment — no impact to MicroShift, other flywheel workloads, or the OS
image plane.

**Lesson reinforced (matches the "verify against reality, not documentation"
theme from this session's other findings, e.g. D023's flightctl-greenboot
discovery):** a short manual smoke test that "looks clean" is not the same
as an actual live-validation pass — the real bug only surfaced once the
pod ran long enough, via the real deployment path, to reach the specific
code path that broke. The research doc's own checklist was right to
demand real hardware validation before merging; the mistake was treating
the abbreviated manual test as satisfying that bar.

**Next attempt, if pursued:** this is very likely fixable by adding the
`cosmos-guardrail` PyPI package to the entrypoint's `pip install` step (or
to a derived image layer) rather than the tag itself being wrong — v0.26.0
still has the FP8 fix and the safer PyTorch pin, both still correct
findings above. Re-attempt only with that dependency addressed, and budget
enough live-observation time (several minutes past `1/1 Running`, not
seconds) to actually reach and exercise the server-startup and
inference-serving code paths before calling it validated.

**Files changed (addendum):** `gitops/vllm-cosmos3/deployment.yaml`
(bumped to the resolved digest, then reverted to `:cosmos3`), this entry.

## D026: Cosign v4 deprecation pre-audit — no actionable usage found, pipeline pin unaffected

**Date:** 2026-08-12
**Trigger:** intel-scan 2026-08-11, Supply Chain Security lens — cosign v3.1.2/v3.1.3 flagged as potentially the last v3.1.x line before v4 removes deprecated, legacy-bundle-era flags/subcommands (`--payload`, `cosign triangulate`, `cosign copy`, and similar).
**Scope:** static, repo-wide grep for every `cosign` CLI invocation or flag/subcommand reference — Tekton YAML, shell scripts (inline Tekton `script:` blocks), markdown docs (including inline shell snippets), and code comments. No cluster access; nothing applied/deployed; this is a text-only audit.

**Decision:** No code or doc changes required. A full inventory of every actual `cosign` CLI invocation in the repo (table below) found zero usage of anything on the v4 deprecation list (`--payload`, `cosign triangulate`, `cosign copy`, `--bundle`, legacy `verify-blob`/`verify-blob-attestation` bundle handling, `LocalSignedPayload`). One unrelated, pre-existing doc gap was flagged (not fixed — out of scope, see below).

**Inventory — every actual `cosign` CLI invocation found in the repo:**

| # | Location | Invocation | On v4 deprecation list? | Verdict |
|---|----------|------------|--------------------------|---------|
| 1 | `tekton/01-cosign-sign-task.yaml:53` | `cosign login "$REGISTRY_LOGIN" -u ignored -p "$SA_TOKEN"` | No | Fine, unaffected |
| 2 | `tekton/01-cosign-sign-task.yaml:57-62` | `cosign sign --key=... --rekor-url=... --tlog-upload=true -y "$(params.IMAGE)"` | No | Fine, current OCI-image sign flow |
| 3 | `DEPLOYMENT_GUIDE.md:533` | `cosign generate-key-pair --output-key-prefix=thor-signing` | No | Fine |
| 4 | `DEPLOYMENT_GUIDE.md:534` | `cosign initialize --mirror=$TUF_URL --root=$TUF_URL/root.json` | No | Fine, current TUF-root API |
| 5 | `DEPLOYMENT_GUIDE.md:541-543` | `COSIGN_PASSWORD="" cosign sign --key=thor-signing.key --rekor-url=$REKOR_URL --tlog-upload=true -y <image>` | No | Fine |
| 6 | `modelcar/Containerfile:27-28` (comment) | `cosign sign --key ~/redhat/thor-signing.key --tlog-upload=true <registry>/...@<digest>` | No | Fine as-is; see adjacent finding below |

No fixes were applied because there was nothing on the deprecation list to fix.

**Reviewed and confirmed non-actionable (reference `cosign` but are not CLI invocations):** `tekton/02-pipeline.yaml`, `03-pipelinerun.yaml`, `05-modelcar-pipeline.yaml`, `06-modelcar-pipelinerun.yaml` (workspace name `cosign-key` / Secret name `cosign-signing-key` only); `derived-image/Containerfile:128` and `derived-image/config/policy.json:12` (`cosign-signing.pub` file path only); `derived-image/config/registries.d-internal-registry.yaml` (generic prose comment, no CLI syntax); `gitops/vllm-cosmos3/deployment.yaml:31` (naming-convention comment only). `DECISIONS.md` D008/D014/D015/D017/D018/D019/D022's `cosign verify` / `cosign sign` / `verify-blob` / `verify-blob-attestation` / `--bundle` / `--rekor-url` mentions are narrative prose (CVE scope discussion, gotcha writeups, or — in D022's case — an explicit statement that the repo does *not* use `--bundle`/`verify-blob`/`LocalSignedPayload`), not runnable invocations. D014's and PROJECT_STATUS.md's "cosign v3 vs v2 tag scheme" gotcha is likewise informational (explains the v2.x pin) and contains no v3/v4 CLI syntax of its own.

**Explicitly confirmed absent, repo-wide:** `--payload`, `cosign triangulate`, `cosign copy`, `--bundle`, `verify-blob`/`verify-blob-attestation` usage, `LocalSignedPayload`, `cosign save`/`cosign load`, `cosign upload`/`cosign attach`. Zero hits on any real invocation of these.

**Adjacent finding, flagged not fixed (out of scope for a v4-deprecation audit):** `modelcar/Containerfile:27-28`'s manual-sign comment omits `--rekor-url`, reproducing the exact mistake D014 already logged as a gotcha ("always pass `--rekor-url` explicitly for internal-registry artifacts per D015" — an earlier manual sign attempt without it logged to the public `rekor.sigstore.dev` instead of the internal RHTAS Rekor). This isn't a deprecated flag — omitting a flag isn't a v4 compatibility issue — so it wasn't touched here, but it's the same "human copy-pastes a stale/incomplete example" risk this audit was checking for, just for a different underlying reason. Left for a future doc pass; noting it here so it isn't rediscovered from scratch.

**Pipeline pin confirmation:** the repo's own signing pipeline (`tekton/01-cosign-sign-task.yaml`, `COSIGN_VERSION: v2.6.5`, per D022) is **not** affected by this advisory and needs no change. v4's deprecation list targets v3.1.x-era legacy-bundle flags/subcommands; the pinned v2.6.5 line predates and never used those flags (confirmed independently in D022's own CVE audit). This entry does not revisit or challenge D022's version-pin decision — that pin stays in the v2.x line per the OpenShift registry tag-scheme constraint (D014), unrelated to this audit's scope.

**Status:** Audit complete. No gap. No code changes needed anywhere in the repo for cosign v4 deprecation risk.

**Files changed:** `DECISIONS.md` (this entry) only.

## D027: Perses server root-caused — likely owner-reference gap in COO's `uiplugin` controller, not a generic operator bug

**Date:** 2026-08-12
**Trigger:** picking up the long-standing "Perses server pod never deploys" item from D021/PROJECT_STATUS.md ("COO 1.5.1 operator issue — Service exists, no Deployment/Pod"). That description was accurate but shallow — this entry replaces it with a specific, evidenced mechanism.

**Investigation:**
- The `edge-perses` `Perses` CR (`perses.dev/v1alpha2`) reports `status.conditions: Available=True, Degraded=False` — a **false-positive**. Live-confirmed: `Service/edge-perses` exists with **zero endpoints**, no Deployment/StatefulSet/Pod backs it anywhere in the `observability` namespace.
- The `cluster-observability-operator` pod (`openshift-operators`, running continuously since 2026-08-08) has produced **121 total log lines across its entire 4+ day lifetime**. Its only registered controller is named `uiplugin`. At startup it registers `EventSource` watches for `*v1alpha2.Perses`, `PersesDashboard`, `PersesDatasource`, and `PersesGlobalDatasource` alongside `UIPlugin` itself — but **zero reconcile log lines exist for `edge-perses` across its entire 3-day lifetime**, including immediately after a live, direct annotation edit made during this investigation specifically to force a reconcile attempt. No log output at all followed that edit.
- The one `UIPlugin` object that does exist (`dashboards`, type `Dashboards`) reconciles fine and is `Available: True` — but it's the OpenShift **console** dashboards UI plugin, unrelated to provisioning a standalone Perses backend server. The `UIPlugin` CRD's `spec.type` enum (`Dashboards`, `TroubleshootingPanel`, `DistributedTracing`, `Logging`, `Monitoring`) has no `Perses`/server-provisioning option either.
- No newer operator version is available to try: the catalog's only channel currently offers `cluster-observability-operator.v1.5.1` (the version already installed) — no upgrade path exists to chase.

**Root-cause hypothesis (well-evidenced, not just plausible):** the `uiplugin` controller's actual `Reconcile()` loop is almost certainly keyed to `UIPlugin` objects. The `Perses`/`PersesDashboard`/etc. `EventSource` watches exist only to **re-enqueue an owning `UIPlugin`** when one of its owned child resources changes (the standard controller-runtime `Owns()` pattern) — not to independently reconcile any `Perses` object that shows up in the cluster. Our `edge-perses` CR was hand-created directly (D021, `spec: {}`), with **no owner reference to any `UIPlugin`**. An event on it therefore maps to zero owning `UIPlugin`s and enqueues nothing — explaining the total silence perfectly. The CR's `Available: True` status is most likely stamped by a lightweight admission webhook or CRD default, not by genuine reconciliation logic; nothing in this operator's actual control loop has ever processed it.

**Conclusion:** creating a standalone `Perses` CR by hand was never a supported/working provisioning path against this specific installed operator version — the CRD schema permits it, but nothing consumes it. This is not fixable by tweaking our own YAML alone, and no operator upgrade is available to try instead.

**Practical path forward (not implemented in this session — scoped as its own follow-up, not a quick fix):** hand-roll our own Perses server `Deployment`/`Service` in `gitops/observability/`, reusing the exact image the operator itself would have used (`registry.redhat.io/cluster-observability-operator/perses-rhel9@sha256:a811b9345d884ba1c575584bec9be1d2a237902164a99887458a82d07e7c2376`, read directly from the operator pod's own startup args). This matches this repo's established pattern of solving gaps in our own layer rather than chasing upstream (D004's NVIDIA device-plugin envvar strategy, D010's embedded workload images). Scoped separately because it requires understanding Perses's own Kubernetes-CR storage-backend config/RBAC to correctly wire up `PersesDashboard`/`PersesDatasource` consumption — a real feature build, not a config fix, and deserves its own dedicated pass rather than being improvised here.

**Files changed:** `DECISIONS.md` (this entry), `PROJECT_STATUS.md` (tightened Perses bullet with this root cause).

## D028: Perses fixed for real — D027's root cause was wrong (missed a second, separate operator); server now deploys and serves the dashboard

**Date:** 2026-08-12
**Supersedes:** D027's root-cause hypothesis and "not fixable by tweaking our own YAML" conclusion, both wrong. D027's *symptom description* (Service exists, no Deployment/Pod, false-positive `Available: True`) was accurate and is not being revisited — only the mechanism and the fix.

**What D027 missed:** the investigation only looked at the main `cluster-observability-operator` pod (`uiplugin` controller). There is a **second, separate operator Deployment**, `perses-operator`, also running in `openshift-operators`, that actually owns `Perses`/`PersesDashboard`/`PersesDatasource` reconciliation — the `uiplugin` controller's watches on those types really are just the `Owns()` re-enqueue pattern D027 described, but that's irrelevant, because a *different* controller was doing the real work the whole time. Confirmed by finding the pod, reading its own logs (actively reconciling `edge-perses` on every change), and cloning its source (`perses-operator`, `perses`, `rhobs/observability-operator`, `rhobs/perses`) to read the actual reconcile logic rather than guess from behavior alone.

**Actual root cause** (in `perses-operator`'s `controllers/perses/deployment_controller.go` / `statefulset_controller.go`): `RequiresDeployment()` and `RequiresStatefulSet()` both gate workload creation on `spec.config.database` being set on the `Perses` CR. D021's CR shipped with `spec: {}` — matching neither condition — so the operator created the `Service` and a `ConfigMap` (holding `config.yaml: "{}"`) but **silently skipped creating any Deployment or StatefulSet**, while still stamping `status.conditions: Available=True` (a genuine bug/gap in the operator's status logic, not a webhook artifact as D027 guessed — the operator itself sets this status directly after the (incomplete) reconcile, unconditionally).

**Fix, applied and live-verified end to end (each step below is a real bug caught only by actually trying it, not predicted in advance):**
1. `gitops/observability/perses-instance.yaml`: added `spec.config.database.file: {folder: /perses, extension: json}` and `spec.storage.emptyDir: {}` (Deployment path, not StatefulSet — no PVC, ephemeral by design: dashboards/datasources are CR-sourced and get re-pushed by the operator's own controllers after any pod restart, and this is a demo dashboard, not a system of record). → Deployment got created, but the pod failed to schedule.
2. **SCC rejection**: the operator hardcodes `fsGroup: 65534` on the pod spec it creates (mirroring Red Hat's own console-plugin-integrated Perses pattern, which grants its ServiceAccount `use` on `nonroot`/`nonroot-v2` via a ClusterRole this standalone CR-based install doesn't have). Every SCC on this cluster rejected it (`restricted-v2`: "65534 is not an allowed group"). Fixed by adding `spec.podSecurityContext: {runAsNonRoot: true}` to the CR — per the CRD doc, omitting `fsGroup` here means "the Kubelet will not modify the ownership and permissions of any volume," letting `restricted-v2` auto-assign a valid non-root UID/GID from the namespace's allocated range instead. Pod came up `1/1 Running`. The Red Hat-built `perses-rhel9` image is already OpenShift-convention-friendly (group-0 writable), so no `fsGroup` was actually needed for it to work.
3. With the server actually running, `PersesDatasource/tempo-edge` pushed successfully on the very next reconcile with no further changes needed — `Available: True`, genuine this time (confirmed via the live API).
4. `PersesDashboard/edge-flywheel` then surfaced a real `400` from the server: `reference "#/panels/episodeTraces" is pointing to the void`. Traced in Perses's own source (`dashboard.go`'s `checkAndSetRef`): a panel `$ref` must be the full JSON-pointer path `#/spec/panels/<name>`, not `#/panels/<name>` (D021's dashboard YAML had all three panel refs missing the `spec` segment). Fixed all three.
5. Dashboard then surfaced a second real `400`: `schema not found for plugin TraceQuery`. Traced in the actual Tempo plugin source (`package.json`/CUE schema): `TraceQuery` is the **query-plugin category**, not a plugin name — the real plugin is `TempoTraceQuery`. Also had two shape mistakes copied from the (wrong) assumption that it matched the `TimeSeriesQuery`/Prometheus pattern used elsewhere: `datasource: {name: tempo-edge}` → `datasource: {kind: TempoDatasource}` (resolves to the `default: true` datasource), and `searchQuery` → `query` (the plugin's CUE schema is closed — no other field names are accepted). Fixed all three query blocks in `edge-flywheel-dashboard.yaml`.
6. Dashboard reconciled successfully after that — genuine `Available: True`, confirmed via a direct authenticated fetch of `GET /api/v1/projects/observability/dashboards/edge-flywheel` through the live Route (below), correct JSON content returned, `HTTP 200`.
7. Added `gitops/observability/perses-route.yaml` (new file, edge TLS, `Redirect` policy, **no auth**) to actually expose the dashboard — a `Perses` CR alone never provisions a `Route`. Deliberate choice to leave it unauthenticated: matches this PoC's existing posture (the actual demo centerpiece, the Cosmos3-Edge inference NodePort, also has no auth) — locking down only the secondary observability dashboard while leaving the primary workload API open would be inconsistent, not meaningfully safer. Perses's built-in OIDC/Kubernetes-native auth is a real, low-effort option to add later if this stack moves past PoC status (flagged as a Phase 7 "Demo hardening" candidate). Confirmed working from outside the cluster: `HTTP 200` through the Route's public hostname.

**GitOps wiring:** created a new ApplicationSet, `thor-testing-observability` (hub-targeted list generator, single `hub` element — unlike the other three thor-testing ApplicationSets, which target edge-device placement, everything in `gitops/observability/` runs on the hub itself, not on Thor), matching the `automated: {prune: true, selfHeal: true}` pattern the other three use. Not committed as a standalone YAML file, per this repo's existing convention (the other three ApplicationSets are documented as templates in `DEPLOYMENT_GUIDE.md` rather than checked into `gitops/`) — created directly against the hub's `openshift-gitops` namespace.

**Incident during this work, fully repaired, noted for the record:** the first attempt at creating this ApplicationSet used the name `observability`, which collided with a **pre-existing, unrelated ApplicationSet** on this same shared hub belonging to a different project (`RHPhysicalAI/industrial-ai-showcase`). Applying overwrote its generator, and Argo pruned 4 of that project's Applications (`observability-loki`, `observability-rules`, `observability-storage`, `observability-ui-plugins`) before this was caught. Repair: restored the original ApplicationSet spec verbatim (captured earlier during unrelated read-only investigation of the hub), confirmed 3 of the 4 pruned Applications were already `OutOfSync`/`Missing` *before* this incident (cross-checked against a pre-session snapshot — not caused here), and manually triggered a sync for the 4th (`observability-storage`, backing that project's MinIO — it has no `automated` syncPolicy so it needed a manual nudge) and confirmed MinIO came back `Running` and healthy. Cross-checked all ~50 other Applications on the shared hub against the pre-session snapshot afterward — nothing else was collaterally affected. Then re-created the ApplicationSet under the collision-free name `thor-testing-observability` used above. **Lesson generalized for this repo: this hub is multi-tenant; always check `oc get applications.argoproj.io -n openshift-gitops <name>` for an existing object before creating anything cluster-scoped with a generic name.**

**Files changed:** `gitops/observability/perses-instance.yaml`, `gitops/observability/edge-flywheel-dashboard.yaml`, `gitops/observability/perses-route.yaml` (new), `DECISIONS.md` (this entry), `PROJECT_STATUS.md` (Perses bullet rewritten to reflect the fix, no longer an open item).

## D029: D024's SA consolidation missed a consumer — Thor's `bootc` pull credentials still referenced the deleted `thor-puller` SA; also, a reproducible `bootc switch` crash worth documenting

**Date:** 2026-08-12
**Trigger:** the D023 clean-image verification rebuild (see D023's addendum above) — `bootc switch` to the newly built image failed immediately with `unable to retrieve auth token: invalid username/password: authentication required`.

**Root cause:** Thor's `/etc/ostree/auth.json` (the credentials file `bootc`/`skopeo` use for registry pulls of OS images, separate from CRI-O's own pull-secret path) had a stale `auth` entry whose username decoded to `thor-puller` — the ServiceAccount D024 identified as orphaned and deleted from `thor-builds` earlier in this same session. D024's investigation correctly found and removed every *in-repo* and *live-cluster* reference to `thor-puller`, but didn't check Thor's own `bootc` auth config, which isn't tracked in this repo (set up manually, out of band, when the internal-registry pull path was first wired up — see D018/D019). This was a real gap in that consolidation's verification scope, not caught until it broke a real operation.

**Fix:** regenerated `/etc/ostree/auth.json` on Thor from `thor-edge-puller`'s live `.dockercfg` secret (`oc get secret thor-edge-puller-dockercfg-<hash> -n thor-builds`), extracting just the `default-route-openshift-image-registry...` host entry (the hostname `bootc status` shows Thor's current image using) and writing it as the sole entry in a fresh `auths` block, `chmod 600`. `bootc switch` then authenticated successfully.

**Secondary, separable bug hit during the retry — a reproducible `bootc` crash:** the first (post-auth-fix) `bootc switch` invocation authenticated fine, pulled the full 20.6 GB new layer over ~10 minutes, logged `Successfully imported image` and `Staging image for deployment`, then the `bootc` process itself terminated with `SIGABRT` (confirmed via `coredumpctl list`, no message printed to the journal beyond the abort notice, no coredump retained). `bootc status` showed `staged: null` afterward — the switch had not taken effect. `coredumpctl list` showed an **identical** `SIGABRT` crash for `/usr/bin/bootc` earlier the same day (14:02 UTC, during this session's live D023 investigation), suggesting this is a reproducible issue tied to something about this image or environment (possibly related to the `Image contains non-ostree compatible file paths: rhsm: 1` warning logged immediately before both crashes — not confirmed as causal, just the only common signal found), not a one-off transient failure. No `bootc` GitHub issue search was done to check if this is a known upstream bug (no internet access from this environment) — worth checking next time this comes up. **Workaround, worked cleanly:** simply re-ran `bootc switch` with the identical command. Since the image layer was already fully pulled/cached from the crashed attempt, the retry completed in ~16 seconds (`No changes in ... => <digest>` — skipped straight to the already-cached content, then `Created deployment`, `Queued for next boot`) with no further issues. Ran the retry via `systemd-run --collect` rather than directly over the SSH session this time, both to get clean success/failure semantics independent of the SSH connection's own lifetime, and to rule out the (unlikely, but worth eliminating) possibility that the crash was an SSH-disconnect-triggered `SIGHUP`-derived abort rather than a genuine `bootc` bug — the retry's success independent of any SSH timing continues to point at a real, reproducible `bootc` issue rather than an artifact of how this session drove it.

**Verification:** post-retry, `bootc status` showed `staged` correctly populated with the new digest; reboot completed cleanly (see D023's addendum for full post-reboot verification — greenboot, MicroShift, ACM, Cosmos3-Edge all confirmed healthy on the new image).

**Follow-up not done here, flagged for later:** (1) audit whether any *other* out-of-repo, manually-configured credential file on Thor or the hub still references `thor-puller` (this repo's own `gitops/` and live-cluster checks in D024 were thorough, but by definition can't cover config that lives only on the device and isn't tracked anywhere — `/etc/ostree/auth.json` was exactly this kind of blind spot); (2) if this `bootc` `SIGABRT` recurs, capture a coredump (`sudo coredumpctl dump <pid>` before it's pruned, or set `ulimit -c unlimited` for the invoking shell) and consider filing upstream against `containers/bootc` — two occurrences in one day with no obvious environmental trigger (disk space was never the issue — 627G free) is enough of a pattern to be worth a real report if it happens again.

**Files changed:** none in-repo. `DECISIONS.md` (this entry) is the only artifact.

## D030: Flywheel redesign — Reasoner SFT over DROID policy post-training; Forward Dynamics as no-robot centerpiece

**Date:** 2026-08-13

**Context:** After completing Phase 3-5 infrastructure (Kafka consumer, KFP pipeline skeleton, blue/green, OTel, Perses), a design review surfaced two problems with the original approach: (1) robot-sim was calling the Cosmos3-Edge Reasoner via `/v1/chat/completions` in a text-chatbot pattern, which does not demonstrate any capability unique to a world model; and (2) the KFP `finetune_cosmos3` step targeted DROID policy post-training — a recipe that requires 758 GB of training data, 8×H100 multi-node HSDP, and action-head initialization from scratch — none of which is feasible on the single L40S (g6e.2xlarge) available on this OSD cluster. Had that path continued, the "training" step would have been emulated (stubbed loss, fake checkpoint) while presenting itself as genuine robot-policy learning. That would have undermined the "RH understands this world" thesis this PoC exists to prove.

**Decisions made:**

**D030-A: Reasoner SFT replaces DROID policy post-training.**
The fine-tuning target is the Cosmos3-Edge Reasoner (Nemotron-2B-Dense-VL) via cosmos-framework's Reasoner SFT pattern (analogous to `launch_sft_videophy2_edge.sh`). This recipe loads weights directly from `nvidia/Cosmos3-Edge` with no DCP conversion, trains the 2B language model with the vision tower frozen, and is documented by NVIDIA as feasible on 4-GPU configurations — making a single L40S with gradient checkpointing tractable for a truncated demo run. The fine-tuning signal is **embodied reasoning quality** on our curated (frame, instruction, reasoning) episodes, which directly measures the model's action-selection and scene-interpretation improvement — the genuine output of the flywheel. DROID policy post-training is explicitly deferred as a "real arm" future milestone; see D030-D below.

**D030-B: Forward Dynamics is the no-robot centerpiece ("dream before deploy").**
Cosmos3-Edge's Forward Dynamics mode (image + action chunk → rollout video) requires no physical robot and runs on-device at 2.59s E2E on the Thor T5000 in MAXN mode (benchmarked by NVIDIA, `[32,8]` action chunk, real-time at 5Hz). This is the capability no other model in the stack can replicate. The Act-3 demo beat — "here is what the trained model believes will happen before we deploy it" — is grounded entirely in genuine world-model inference, not simulation. Forward Dynamics runs on Thor to keep the edge-device story coherent; GPU-contention with the Reasoner is managed by sequencing (Reasoner pauses during dream).

**D030-C: Action-chunk selection drives the flywheel signal (option ii-b).**
The flywheel improves *which* action chunk the curated/trained selector picks for a given scene — not the action chunk values themselves. This avoids the text→joint-vector bridge that option (i) would have required (a fictitious mapping from Reasoner text output to DROID 8-DOF trajectories). Under (ii-b), action chunks are sourced from real DROID trajectories (BridgeData2 / NVIDIA example data); the Reasoner's job is embodied scene interpretation and action-selection quality. If (ii-b) proves insufficiently demonstrable in practice, fallback (ii) uses canned real action chunks from the NVIDIA `example_action_fd_umi_action_chunks.json` asset directly. Option (i) is permanently rejected.

**D030-D: DROID policy post-training is deferred — explicit roadmap item, not abandoned.**
The DROID recipe (`cosmos-framework` `launch_sft_action_policy_droid_nano.sh`) is technically correct and is NVIDIA's documented path for adapting Cosmos to a specific robot embodiment. Its requirements (758 GB `nvidia/Cosmos3-DROID` dataset in LeRobotDataset v3.0 format, 8×H100 multi-node training, action-head fresh initialization) are incompatible with the current compute envelope. The right trigger for this path is: a physical robot arm integrated with Thor (or a Jetson-attached manipulator), plus access to multi-GPU training capacity. The existing KFP pipeline skeleton, Kueue LocalQueue, and L40S node are preserved for that moment. This deferral is stated explicitly in the demo — "next step is a real arm" — which is a stronger product roadmap statement than faking the training.

**D030-E: BridgeData2 seed frames sourced (5 frames, one per scene archetype).**
Five first-frames extracted from `nvidia/BridgeData2-Subset-Synthetic-Captions` (OpenMDW 1.1, commercial-OK, Walke et al. 2023) and stored in `assets/bridgedata2/frames/`. Robot-sim scenes updated to tabletop manipulation archetypes matching BridgeData2's WidowX distribution (replacing the two non-applicable scenes: "delivery robot on sidewalk" and "humanoid robot in hallway"). Full provenance in `assets/bridgedata2/ATTRIBUTION.md`.

**Feasibility evidence:**
- Cosmos3-Edge-Policy-DROID README, vLLM-Omni latency table: "NVIDIA Jetson AGX Thor T5000, 128 GB, MAXN — 2.59s E2E, real-time at 5Hz" for `[32,8]` action chunk forward dynamics.
- cosmos-framework `docs/training.md`: Edge Reasoner SFT "Only 2B, so it runs on a 4-GPU (e.g. GB200×4) or 8-GPU allocation" — single-GPU feasible with `NPROC_PER_NODE=1` and gradient checkpointing.
- All three model assets (Cosmos3-Edge, Cosmos3-Edge-Policy-DROID, BridgeData2-Subset-Synthetic-Captions) confirmed publicly available, ungated, OpenMDW 1.1.

**Files changed:** `DECISIONS.md` (this entry), `assets/bridgedata2/ATTRIBUTION.md` (new), `assets/bridgedata2/frames/` (5 first-frames, new).

**Files changed:** none in-repo — both the auth.json fix and the bootc retry are live device-only changes, matching D018/D019/D024's precedent that Thor's manually-configured, non-GitOps credential files aren't tracked in this repo. `DECISIONS.md` (this entry) is the only artifact.

## D031: Generator-native flywheel (Option E) -- vLLM-Omni is Generator-only, Reasoner text output is structurally impossible

**Date:** 2026-08-13
**Supersedes:** D030-A (Reasoner SFT) for the fine-tuning approach; D030-B/C (Forward Dynamics centerpiece, ii-b action selection) are preserved unchanged.

**Finding:** Source-code analysis of `vllm_omni/diffusion/models/cosmos3/pipeline_cosmos3.py` (the `Cosmos3OmniDiffusersPipeline` class loaded by `vllm serve --omni`) confirmed that vLLM-Omni is a **Generator-only pipeline**:

1. The `lm_head` (the layer that converts hidden states into text tokens) is **explicitly discarded** during weight loading: `if k.startswith("lm_head."): return None`. Without an lm_head, text generation is structurally impossible.
2. The "Understanding" (UND) pathway is internal conditioning only -- it encodes the text prompt into K/V cache for the Generator's cross-attention. It never emits text to the user.
3. `modalities=["text"]` is accepted syntactically but silently falls through to video generation.
4. System prompts are hardcoded to Generator: `"You are a helpful assistant who will generate videos from a give prompt."`
5. Every `forward()` return is image, video, audio, or action tensors -- never text.

This was confirmed empirically: even a pure text question ("What is 2+2?") sent to `/v1/chat/completions` on Thor's vLLM-Omni returned a base64 PNG image.

Running both Reasoner (standard vLLM) and Generator (vLLM-Omni) simultaneously on Thor's single GPU was investigated and ruled out: CUDA compute contention on Jetson unified memory makes dual-inference unpredictable for live demo latency. Mode-switching (5-min model reload between acts) was rejected as too disruptive.

**Decision (Option E):** The flywheel operates entirely within the Generator's native capabilities:
- **Text-to-Image** (`POST /v1/images/generations`): robot-sim generates scene images from text prompts. Proves the Generator is alive and producing coherent visual output.
- **Action Policy** (`POST /v1/videos` with `action_mode: policy`): robot-sim predicts DROID action chunks from BridgeData2 conditioning frames. This is Cosmos3-Edge's core Physical AI capability.
- **Forward Dynamics** (unchanged from D030-B): dreamer renders rollout videos from conditioning frames + action chunks. The "dream before deploy" centerpiece.
- **Curation** scores generation quality (image coherence, action smoothness) rather than text reasoning quality.
- **Training** targets cosmos-framework **Vision SFT** (`launch_sft_vision_edge.sh` recipe) instead of Reasoner SFT, directly improving T2I/I2V/action generation quality.

**What this preserves from D030:** Forward Dynamics as the no-robot centerpiece (D030-B), real BridgeData2 seed frames (D030-E), DROID/UMI action chunks from the pool (D030-C variant), the dream video side-by-side comparison (Gate 2). The flywheel signal shifts from "text reasoning quality" to "generation quality + action trajectory quality" -- which is what the Generator actually does and what Vision SFT actually improves.

**Files changed:** `robot-sim.yaml` (rewritten for Generator-native), `curator.yaml` (Generator quality scoring), `sync-agent.yaml` (updated manifest schema), `DECISIONS.md` (this entry).
