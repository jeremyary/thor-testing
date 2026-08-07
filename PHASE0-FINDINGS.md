# Phase 0 Findings — Thor Audit & De-risk

> [!NOTE]
> This project was developed with assistance from AI tools.

Audit date: 2026-08-06. All findings from the running system and pulled image inspection.

---

## 1. OS & Bootc State

| Item | Value |
|------|-------|
| Current image | `registry.gitlab.com/.../nvidia-jetson-sidecar/rhel-stream10:a66617e5-thor` |
| Image source branch | `feature/thor-tegra264-kernel` (sidecar team CI) |
| OS reports as | RHEL 10.2 (Coughlan) — despite being CentOS Stream 10 base |
| Kernel | 6.12.0-253.el10.aarch64 |
| Architecture | arm64 / aarch64 |
| Ostree deployments | 2 (current + rollback to previous `r39.2-team-ea`) |
| Partition scheme | 2 partitions: 512M EFI (p1) + 953.4G root ext4 (p2) |
| `/` | composefs, 15M, read-only (100% used — normal) |
| `/var` | ext4 on nvme0n1p2, 939G total, 180G used, 712G free, **read-write** |
| `/usr` | read-only (ostree-managed) |
| `/etc` | read-write (bootc-preserved overlay) |
| bootc update timer | **disabled** (service) but timer is **active** — needs masking for RHEM |

**What persists across `bootc switch`:** `/var` entirely (including `/var/lib/containers/storage`, `/var/home`, any data under `/var`). `/etc` is merged. `/usr` is replaced.

**For the derived image:** Models, episodes, and persistent workload data should live under `/var` paths. Container images (podman storage at `/var/lib/containers/storage`) persist. The `/root` home dir is at `/var/roothome` (bootc redirect).

## 2. Driver Stack

**All NVIDIA components are RPM-packaged** by the sidecar team, version `39.2.0~20260601141651`:
- 50 nvidia-jetpack RPMs installed (core, CUDA, firmware, kmod, multimedia, etc.)
- Kernel module: `nvidia-jetpack-kmod-openrm` built for kernel `6.12.0_253`
- Driver version: 595.78 (NV_VERSION synced via `0007-openrm-cs10-compat.patch`)
- Module path: `/lib/modules/6.12.0-253.el10.aarch64/updates/opensource-gpu-disp/nvidia.ko`
- OpenRM (not nvgpu) — Blackwell requires this

**Module management:**
- depmod overrides in `/etc/depmod.d/nvidia*` route `nvidia`, `nvidia-drm`, `nvidia-modeset`, `nvidia-uvm` to `updates/opensource-gpu-disp`
- Denylists: nvgpu, nouveau, tegra_camera_rtcpu, hsp_mailbox_client, Orin CSI stack
- Dracut omits: nvgpu, nouveau, camera stack, tegra_drm, nvethernet
- `nv-load-display-modules.service` and `nvidia-ctk.service` both **enabled**

**Driver survival concern:** The kmod RPM (`nvidia-jetpack-kmod-openrm-39.2.0_6.12.0_253`) is **compiled against the specific kernel NVR** (6.12.0-253). A derived image that changes the kernel NVR would need matching kmod RPMs. Our derived image should `FROM` this image without changing the kernel, inheriting the kmod. Kernel updates must be coordinated with kmod rebuilds — this is the sidecar team's responsibility for their base image.

## 3. Container Toolkit & CDI

| Item | Value |
|------|-------|
| Package | nvidia-container-toolkit-base 1.19.1 |
| CDI generation | `nvidia-ctk cdi generate` via `nvidia-ctk.service` (oneshot at boot) |
| CDI spec | `/etc/cdi/nvidia.yaml` (73K, regenerated each boot) |
| CDI mode | CSV (auto-detected for Tegra) |
| Known gap | **libcuda.so.1 not in CDI spec** — requires manual bind mounts |

**For derived image:** CDI generation happens at boot via systemd. The service is already enabled. The derived image inherits this. The libcuda gap must be documented as a podman flag requirement for GPU workloads, or we can add a post-boot script that creates a symlink CDI can discover (the base image already has `ln -sf` in the Containerfile for this).

## 4. How vLLM-Omni Currently Runs

**It does not run as a managed service.** There is:
- No vLLM systemd unit
- No vLLM container running
- No vLLM process on the host

vLLM-Omni is run **ad-hoc via `podman run`** from SSH sessions. This means:
- No automatic startup after reboot
- No health monitoring or restart
- No resource limits enforced
- No integration with any orchestrator

**Container images present** (10 images, ~168 GB total):
- 3 vLLM variants (Jetson, NGC, cosmos3)
- 1 Jetson bootc image (previous)
- 1 current bootc image
- Misc (Ubuntu, CUDA devel, PyTorch)

**For derived image:** MicroShift will manage vLLM-Omni as a Deployment. Container images should be pre-pulled or pulled via MicroShift's CRI-O (which uses CDI natively via the `nvidia.com/gpu` resource). The current ad-hoc podman approach will be replaced entirely.

## 5. Users & Security

| Item | Value |
|------|-------|
| Users with shells | root, redhat (uid 1000) |
| SELinux | **Permissive** |
| root access | SSH key (1 key), passwordless sudo for wheel group |
| Passwords | root:redhat, redhat:redhat (set in Containerfile) |
| Firewall | **Not running** (firewalld inactive) |

**For derived image:** MicroShift will want SELinux enforcing (or at least the CRI-O pieces). The current permissive mode is fine for dev but should be noted as a deviation. Default passwords are lab-only.

## 6. Systemd Units (GPU-related)

| Unit | State |
|------|-------|
| nvidia-ctk.service | enabled, runs at boot (CDI generation) |
| nv-load-display-modules.service | enabled, runs at boot |
| nvpower.service | loaded, inactive |
| display-manager.service | not-found (no GUI) |
| bootc-fetch-apply-updates.timer | **disabled but active** — needs masking for RHEM |

## 7. Network

| Item | Value |
|------|-------|
| Primary interface | enP2p1s0: 10.0.0.42/24 |
| WiFi | wlP1p1s0: DOWN (available but unused) |
| CAN buses | can0-can3: DOWN (robot interfaces, available) |
| DNS | 10.0.0.1 (local router) |
| Firewall | Not running |
| NTP | Synced (UTC) |
| Gateway | 10.0.0.1 (home NAT) |

**All outbound flows work.** Thor can reach Quay.io, Docker Hub, GitLab, and NGC registries.

## 8. Credentials

`/etc/environment` contains `HF_TOKEN`, `NGC_API_KEY`, `GITLAB_RO_TOKEN` (all set). These persist across reboots but NOT across `bootc switch` to a new image (they're in `/etc` which is merged, but new images may reset `/etc/environment`). The derived image should either bake a mechanism to restore these or use a MicroShift Secret.

---

## P0 Risk Assessment

### Registry reachability + auth from Thor ✅ RESOLVED

All registries reachable from Thor:
- Quay.io: ✅
- Docker Hub: ✅
- GitLab registry: ✅ (current image source)
- NGC (nvcr.io): ✅

Auth for GitLab is via `/etc/environment` `GITLAB_RO_TOKEN`. CRI-O will need pull secrets configured in MicroShift for private registries.

### NVIDIA driver survival across derived-image rebuilds ✅ RESOLVED

The kmod is compiled for a specific kernel NVR (6.12.0-253). As long as the derived image `FROM`s the base without changing the kernel, the kmod carries through. The derived image should **not** install a different kernel or kernel-devel package. Kernel updates are the base team's responsibility and come with new kmod builds.

### Mac build feasibility ⚠️ NEEDS WORK

| Item | Status |
|------|--------|
| Architecture | arm64 ✅ (Apple Silicon — native aarch64 builds) |
| Memory | 48 GB ✅ (plenty for 15 GB image builds) |
| Disk | 830 GB free ✅ |
| Podman | **NOT INSTALLED** — needs `brew install podman` + `podman machine init` |
| Registry auth | GitLab reachable, needs `podman login` with GITLAB_RO_TOKEN |

**Action needed:** Install podman on the Mac before Phase 1. This is a `brew install podman && podman machine init --cpus 4 --memory 8192 --disk-size 100` operation.

### flightctl-agent on CentOS Stream 10 aarch64 ✅ RESOLVED

The `flightctl-agent` RPM is available for CS10 aarch64 from `rpm.flightctl.io`. Key details:
- **Repo:** `https://rpm.flightctl.io/flightctl-epel10.repo` (NOT the `flightctl-epel.repo` — that one hardcodes el9)
- **Packages available:** `flightctl-agent`, `flightctl-cli`, `flightctl-greenboot`, `flightctl-selinux`
- **Latest version:** 1.2.0 stable, 1.3.0-rc1 pre-release
- **No RHEL subscription required** — public repo, no subscription-manager
- **Also on COPR:** `@redhat-et/flightctl-dev` has explicit CS10 aarch64 builds

For the derived Containerfile:
```dockerfile
RUN dnf config-manager addrepo --from-repofile=https://rpm.flightctl.io/flightctl-epel10.repo && \
    dnf -y install flightctl-agent flightctl-greenboot && \
    dnf -y clean all && \
    systemctl enable flightctl-agent.service
```

### bootc update timer ⚠️ NEEDS MASKING

`bootc-fetch-apply-updates.timer` is disabled at the service level but the timer itself is **active**. For RHEM ownership of OS updates, this must be explicitly masked in the derived image:

```dockerfile
RUN systemctl mask bootc-fetch-apply-updates.timer bootc-fetch-apply-updates.service
```

### AWS Graviton builder readiness 🔲 NOT ASSESSED

Per §9, needs Jeremy's confirmation:
- Work AWS account owner blessing for tagged ephemeral spot instances
- IAM role scoping
- Graviton spot capacity in the cluster's region

This is a Phase 2 item but flagged here per the brief's P0 risk list.

---

## What the Derived Image Must Add vs. What It Inherits

### Inherits from base (do not duplicate):
- CentOS Stream 10 kernel 6.12.0-253
- All 50 nvidia-jetpack RPMs (driver, CUDA libs, firmware, kmod)
- nvidia-container-toolkit-base 1.19.1
- nvidia-ctk.service (CDI generation at boot)
- nv-load-display-modules.service
- All Thor-specific modprobe/dracut/depmod configs
- Users (root, redhat) and SSH config
- EPEL, nvidia-container-toolkit repos

### Must add in derived layer:
1. **MicroShift** (pinned RPM version) + greenboot health checks
2. **flightctl-agent** (if available for CS10/aarch64) with bootc timer masked
3. **Day-0 manifests** for MicroShift: klusterlet import (RHACM), Argo bootstrap
4. **sigstore config**: `policy.json` + `registries.d` entries (placeholder in Phase 1, enforced in Phase 5)
5. **Mask** `bootc-fetch-apply-updates.timer` (RHEM owns updates)
6. **Persistent storage layout**: directories under `/var` for models, episodes, checkpoints
7. **CRI-O config** for GPU workloads (CDI resource annotation `nvidia.com/gpu`)

### Does NOT go in the derived image:
- vLLM-Omni container images (pulled at runtime by CRI-O)
- Model weights (pulled at runtime into persistent storage)
- Episode data (generated at runtime)
- Credentials (injected via MicroShift Secrets or `/etc/environment`)
