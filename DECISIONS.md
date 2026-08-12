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
