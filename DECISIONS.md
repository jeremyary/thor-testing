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
