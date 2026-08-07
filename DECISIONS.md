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

**Date:** 2026-08-07
**Decision:** Model checkpoints will be packaged as KServe modelcar OCI artifacts and stored in the internal OpenShift registry. Delivery to the device is via embedding in the bootc image (air-gapped) or via MicroShift ImageVolume mount (if supported). HuggingFace downloads at runtime are eliminated.
**Rationale:** Model provenance is a safety-relevant property. An ungoverned HuggingFace download bypasses the trust plane. Packaging as an OCI artifact enables signing (RHTAS), versioning, and the same sigstore verification used for all other artifacts.
**Status:** Architecture decided, implementation deferred to Phase 4 (training pipeline).

## D015: Sigstore policy scoped to internal registry

**Date:** 2026-08-07
**Decision:** The device's `policy.json` enforces `sigstoreSigned` for the internal OpenShift registry route, not Quay.io. All governed artifacts (OS images, model images) flow through the internal registry.
**Rationale:** The internal registry is the single source of truth. Scoping trust enforcement to it ensures nothing reaches the device without passing through the hub's signing pipeline. External registries (Docker Hub, Quay, NGC) are only consumed at build time, never at device runtime.

## D016: Perses replaces Grafana for observability dashboards

**Date:** 2026-08-07
**Decision:** Use Perses (GA in COO 1.5) for observability dashboards instead of the community Grafana operator. Dashboards are console-integrated and declared via `PersesDashboard` CRs.
**Rationale:** Red Hat deprecated the built-in Grafana and does not support the community operator. Perses is the forward path — GA, console-integrated, with Grafana dashboard import tooling. COO UIPlugins provide distributed tracing and logging views in the console.
