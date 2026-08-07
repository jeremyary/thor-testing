# Understanding the Build: CentOS Bootc on NVIDIA Jetson AGX Thor

> [!NOTE]
> This project was developed with assistance from AI tools.

This document explains the full stack of how a CentOS 10 Stream bootc image is built for
the NVIDIA Jetson AGX Thor developer kit. It is written for a Red Hat engineer who knows
OpenShift and Kubernetes well but is new to OS-level kernel work, bootloader chains, and
Jetson hardware.

---

## Table of Contents

1. [The Hardware: Jetson AGX Thor](#1-the-hardware-jetson-agx-thor)
2. [NVIDIA's Software Stack (Upstream)](#2-nvidias-software-stack-upstream)
3. [The CentOS Bootc Base (centos-bootc-tegra)](#3-the-centos-bootc-base-centos-bootc-tegra)
4. [The NVIDIA Sidecar (nvidia-jetson-sidecar r38.4.0-wip)](#4-the-nvidia-sidecar-nvidia-jetson-sidecar-r3840-wip)
5. [What We Added (Our Patches)](#5-what-we-added-our-patches)
6. [The Boot Chain](#6-the-boot-chain)
7. [The Deployment Process](#7-the-deployment-process)
8. [Reading the Build Log](#8-reading-the-build-log)
9. [How This Relates to Red Hat Products](#9-how-this-relates-to-red-hat-products)
10. [Glossary](#10-glossary)

---

## 1. The Hardware: Jetson AGX Thor

### What is the Thor SoC

The Jetson AGX Thor (codename T5000) is NVIDIA's most powerful edge computing module. It is
a System-on-Chip (SoC) -- meaning the CPU, GPU, memory controller, and most I/O are all on
a single die, as opposed to a datacenter server where these are discrete components on a
motherboard.

Key specs of the Thor developer kit:

- **GPU:** Blackwell architecture, SM_110 (Streaming Multiprocessor generation 110). This is
  the same GPU architecture found in datacenter B200 cards, but integrated on-die with the
  CPU. It supports CUDA 13.0 and has hardware acceleration for FP4/FP8/BF16 inference.
- **CPU:** 14 ARM Cortex-A720AE cores (ARMv9). Not x86 -- every binary, kernel module, and
  container must be aarch64.
- **Memory:** 128 GB LPDDR5X unified memory. "Unified" means the CPU and GPU share the same
  physical memory pool. There is no separate VRAM. A 70B parameter model quantized to NVFP4
  (~35 GB) fits entirely in this shared memory with room to spare for the OS and application.
- **Storage:** 1 TB NVMe SSD (on the developer kit carrier board).
- **Networking:** 25 GbE (Realtek r8127) plus Wi-Fi 7.

### How it differs from datacenter hardware

If you have worked with NVIDIA A100 or H100 GPUs in OpenShift, Thor will feel familiar in
some ways and alien in others:

| Aspect | Datacenter (A100/H100) | Jetson AGX Thor |
|--------|----------------------|-----------------|
| GPU | Discrete PCIe/SXM card | Integrated on SoC die |
| CPU | x86_64 (Intel/AMD) | aarch64 (ARM Cortex-A720AE) |
| Memory | Separate system RAM + GPU VRAM | Unified 128 GB shared pool |
| GPU driver | Datacenter NVIDIA driver (`.run` installer or RPM) | Tegra-specific OOT kernel modules |
| OS | RHEL/RHCOS on standard server | L4T (Ubuntu) by default; CentOS/RHEL with effort |
| Platform | Standard ACPI/PCIe server | Tegra platform (custom I2C/SPI/pinctrl buses) |
| Boot | Standard UEFI + GRUB | UEFI (SBSA) + QSPI firmware + GRUB (or L4TLauncher) |

The key insight: Thor is not a GPU card you plug into a server. It **is** the server.
Everything -- CPU, GPU, memory, storage controller, display engine -- is one integrated
platform. The GPU is not a PCIe device you enumerate at boot; it is part of the SoC fabric,
accessed through Tegra-specific kernel drivers.

### UEFI/SBSA and why it matters

Historically, Jetson modules (TX2, Xavier, Orin) booted using a proprietary NVIDIA
bootloader chain that assumed Ubuntu. Running anything other than Ubuntu required extensive
reverse engineering of the boot process.

Starting with Orin and continuing with Thor, NVIDIA implemented **SBSA** (Server Base System
Architecture) and **UEFI** (Unified Extensible Firmware Interface) compliance. This means
the Thor firmware presents itself as a standard UEFI system, just like an x86 server would.
Any OS that boots on UEFI aarch64 systems -- RHEL, CentOS, Fedora -- can theoretically boot
on Thor without special boot-chain hacking.

This is the single most important architectural change that makes our PoC possible. Without
SBSA/UEFI, running CentOS on Thor would require rewriting the bootloader.

### Firmware (QSPI) vs OS (NVMe) separation

Thor has a strict separation between firmware and OS:

- **QSPI flash** (soldered to the module): Contains the UEFI firmware, device tree blobs
  (DTBs), TrustZone/OP-TEE, and other low-level boot components. This is flashed separately
  using NVIDIA's `l4t_initrd_flash.sh` tool and is **not** something we modify. Think of it
  like the BIOS ROM on a server motherboard.
- **NVMe SSD** (on the carrier board): Contains the operating system -- EFI System Partition,
  root filesystem, boot partition. This is where our CentOS bootc image lives.

The firmware on QSPI must match the JetPack version of the software on NVMe. Our build uses
JetPack R38.4.0 firmware, so the QSPI must have R38.4.0 firmware flashed. If the Thor
currently runs Ubuntu with R38.4 firmware, we only need to replace what is on NVMe; the QSPI
stays as-is.

---

## 2. NVIDIA's Software Stack (Upstream)

### L4T: Linux for Tegra

L4T (Linux for Tegra) is NVIDIA's customized Linux distribution for Jetson devices. At its
core, it is Ubuntu (currently Ubuntu 22.04 for JetPack 6.x, Ubuntu 24.04 for JetPack 7.x)
with:

- A patched kernel containing Tegra platform drivers
- Proprietary user-space libraries (CUDA, cuDNN, TensorRT, multimedia codecs)
- Out-of-tree (OOT) kernel modules for the GPU, display, camera, and other Tegra subsystems
- Firmware blobs for GPU, audio DSP, and other coprocessors
- Device tree blobs (DTBs) describing the hardware layout

L4T is to Jetson what RHCOS is to OpenShift -- the blessed OS that everything is tested
against. Running a non-L4T OS means you are doing what amounts to replacing RHCOS with a
custom Fedora build on an OpenShift node.

### JetPack: the SDK bundle

JetPack is the marketing/packaging name for the complete Jetson SDK. It bundles:

- L4T (the OS)
- CUDA toolkit
- cuDNN (neural network primitives)
- TensorRT (inference optimizer)
- VPI (vision programming interface)
- Multimedia API (hardware video encode/decode)
- Developer tools

**Version numbering:** The version scheme changed with Thor. Historically, JetPack used a
"R<major>.<minor>.<patch>" format where R mapped to the L4T branch:

| JetPack | L4T Release | Kernel | Target Hardware |
|---------|-------------|--------|-----------------|
| JetPack 5.x | R35.x | 5.10 | Xavier |
| JetPack 6.x | R36.x | 5.15 | Orin |
| JetPack 7.x | R38.x | 6.8 | Thor |

So when you see `R38.4.0` in our build, that means JetPack 7.1, targeting Thor, with an
NVIDIA kernel based on upstream 6.8. The `R38` is the L4T branch number, `4` is the point
release, and `0` is the patch level. The timestamp `20251230160601` in the spec file is the
exact build timestamp of that L4T release.

### OOT modules: what they are and why they exist

"OOT" stands for Out-Of-Tree -- kernel modules that are not part of the upstream Linux
kernel source tree. NVIDIA ships a large set of OOT modules because:

1. **Tegra hardware support is not fully upstreamed.** Drivers for Thor's PCIe controller,
   pinmux, power management, display engine, camera subsystem, and many other peripherals
   exist only in NVIDIA's out-of-tree source drops.
2. **The GPU driver is proprietary.** Unlike datacenter GPUs (which use the `nvidia.ko`
   driver from NVIDIA's `.run` installer), Jetson uses integrated GPU drivers that interact
   with the Tegra platform at the SoC level.
3. **Hardware-software co-evolution.** NVIDIA iterates on Tegra drivers faster than
   upstream kernel merge cycles. OOT modules let them ship updates without waiting for the
   kernel community to review and accept patches.

The OOT source comes as several tarballs:

- `kernel_oot_modules_src.tbz2` -- the main set of Tegra platform drivers (PCIe, thermal,
  power management, camera, audio, etc.)
- `nvidia_unified_gpu_display_driver_source.tbz2` -- the GPU compute and display driver
  (this is the "unifiedgpudisp" component)
- `nvidia_kernel_display_driver_source.tbz2` -- display-specific kernel components

### nvidia-oot vs nvgpu vs unifiedgpudisp

These names appear throughout the codebase, and understanding them saves confusion:

- **nvidia-oot** (`kernel_oot_modules_src.tbz2`): The umbrella set of all Tegra OOT
  modules -- hundreds of `.ko` files for every Tegra subsystem. This includes PCIe
  controllers, thermal sensors, audio, camera pipeline, GPIO, pinctrl, and many others. It
  does **not** include the GPU driver itself.
- **nvgpu**: The legacy Jetson GPU driver used on Xavier and Orin (JetPack 5.x/6.x). It is
  a Tegra-specific GPU driver that does not share code with NVIDIA's datacenter GPU driver.
  It was purpose-built for the older Tegra GPU architectures (Volta, Ampere integrated).
- **unifiedgpudisp** (`nvidia_unified_gpu_display_driver_source.tbz2`): The **new** GPU
  driver for Thor. Because Thor uses a Blackwell GPU (the same architecture as datacenter
  GPUs), NVIDIA unified the Jetson GPU driver with the datacenter driver codebase. This is
  why you see the `--with openrm` flag in our build -- it enables the "Open Resource
  Manager" (open-source GPU kernel module) that NVIDIA also uses for datacenter GPUs.
  Thor is the first Jetson to use this unified driver instead of nvgpu.

**In OpenShift terms:** Think of nvgpu as the old GPU Operator for a proprietary GPU, and
unifiedgpudisp/openrm as the new GPU Operator that shares code with the datacenter driver.
The architecture change (Blackwell) forced the driver unification.

### Why NVIDIA ships everything as Debian packages

NVIDIA's entire Jetson ecosystem -- firmware, drivers, libraries -- is packaged as `.deb`
files for Ubuntu. The L4T source tarballs themselves are extracted from `.deb` packages. The
build system, CI, documentation, and testing all assume `dpkg`/`apt`.

This is the fundamental reason the sidecar project exists: every NVIDIA `.deb` must be
repackaged as an `.rpm` for CentOS/RHEL. The RPM spec files in the sidecar are essentially
Debian-to-RPM translators.

---

## 3. The CentOS Bootc Base (centos-bootc-tegra)

### What is bootc

If you know OpenShift, you already understand bootc conceptually -- you just need to map the
terminology.

**bootc** is a tool and paradigm for managing bootable Linux systems as OCI container
images. Instead of installing an OS from an ISO and then mutating it with `yum install`,
you define the OS as a Containerfile, build it with `podman build`, and deploy it by writing
the container image to disk.

**OpenShift analogy:** A bootc image is like a MachineConfig that IS the entire node OS.
Instead of:

```
RHCOS base  +  MachineConfig (add files, enable services)  =  Node
```

With bootc it is:

```
Containerfile (define everything: kernel, packages, configs)  -->  podman build  -->  OCI image  -->  write to disk  =  Node
```

Key properties:

- **Immutable root filesystem:** The OS root is a read-only ostree deployment, just like
  RHCOS. Runtime changes go to `/etc` (config) and `/var` (data). You cannot `yum install`
  on a running bootc system (well, you can, but it does not persist across reboots).
- **Atomic updates:** Upgrading the OS means pulling a new container image and rebooting.
  The old image remains as a rollback target. This is like a MachineConfigPool rolling
  update in OpenShift.
- **OCI container format:** The OS image is a standard OCI container image, stored in a
  container registry (quay.io, ghcr.io). You push and pull OS images the same way you push
  and pull application containers.

The base CentOS bootc image lives at `quay.io/centos-bootc/centos-bootc:stream10`. This is
a vanilla CentOS 10 Stream bootable image -- equivalent to a minimal CentOS 10 install.

### How centos-bootc-tegra extends the base

The `centos-bootc-tegra` project (maintained by Nick Cao at Red Hat) takes the vanilla
CentOS 10 Stream bootc base and adds Thor hardware support at the kernel level.

**What it does:**

1. **Downloads the CentOS 10 Stream kernel source RPM** (`kernel-6.12.0-224.el10`)
2. **Applies a massive patch** (`kernel.patch`, 81,217 lines) containing 482 Tegra264
   patches that add hardware support for Thor
3. **Adds kernel config options** for Thor-specific subsystems:
   ```
   CONFIG_PCIE_TEGRA264=y       # Thor's PCIe controller
   CONFIG_PINCTRL_TEGRA238=y    # Pin multiplexer for Orin-class
   CONFIG_PINCTRL_TEGRA264=y    # Pin multiplexer for Thor
   CONFIG_DEVFREQ_GOV_*=y       # Dynamic frequency scaling governors
   ```
4. **Builds the patched kernel** as RPMs using `rpmbuild`
5. **Installs the patched kernel** into a clean CentOS bootc base image
6. **Publishes two images:**
   - `ghcr.io/nickcao/centos-bootc-tegra:stream10` -- bootable base with the patched kernel
   - `ghcr.io/nickcao/centos-bootc-tegra:stream10-devel` -- same, plus kernel-devel headers
     for compiling OOT modules

**Why the patches are needed:** The upstream Linux kernel 6.12 (which CentOS 10 Stream
ships) does not yet have support for Thor's hardware. Tegra264 (Thor's platform codename) is
a new SoC, and its drivers are still working through the upstream kernel submission process.
Until they land in mainline Linux, these 482 patches are how you get Thor to boot with a
non-NVIDIA kernel.

The patches cover:
- PCIe controller driver (`pcie-tegra264`)
- Pin controller / multiplexer (`pinctrl-tegra264`)
- Power management / DVFS (Dynamic Voltage and Frequency Scaling)
- Clock tree definitions
- Device tree bindings
- Platform bus drivers
- I2C/SPI controller support specific to the T5000 SoC

**The Dockerfile that builds this** (`centos-bootc-tegra/stream10/Dockerfile`):

```dockerfile
FROM quay.io/centos-bootc/centos-bootc:stream10 AS build
ARG KVER=6.12.0-224.el10
# Download and patch the kernel source
RUN dnf download --source kernel-${KVER}
RUN rpm --install ./kernel-${KVER}.src.rpm
# Add Tegra264 kernel config options
RUN cat <<EOF >> /root/rpmbuild/SOURCES/kernel-local
CONFIG_PCIE_TEGRA264=y
CONFIG_PINCTRL_TEGRA264=y
...
EOF
# Apply the 81K-line Tegra264 patch
COPY kernel.patch /root/rpmbuild/SOURCES/patch-6.12-redhat.patch
# Build the patched kernel
RUN rpmbuild -bb /root/rpmbuild/SPECS/kernel.spec

FROM quay.io/centos-bootc/centos-bootc:stream10 AS base
# Install the patched kernel RPMs into the clean base
RUN dnf install -y /kernel/aarch64/kernel-*.rpm
```

### How this relates to RHEL

CentOS 10 Stream is the upstream development branch of RHEL 10. They share the same kernel
source tree (kernel 6.12.x) and the same packaging. A kernel that builds and works on
CentOS 10 Stream will, with minor adjustments, build and work on RHEL 10 when it ships. This
is the productization path -- the centos-bootc-tegra work done today translates directly to
RHEL 10 on Thor in the future.

---

## 4. The NVIDIA Sidecar (nvidia-jetson-sidecar r38.4.0-wip)

### What "sidecar" means here

The name "sidecar" is unfortunately overloaded. In Kubernetes, a sidecar is a helper
container that runs alongside your application container. Here, "sidecar" means something
different: it is a **layer that adds NVIDIA's proprietary drivers and libraries on top of a
base OS image**.

Think of it this way:

```
centos-bootc-tegra (base OS with patched kernel, no GPU drivers)
        +
nvidia-jetson-sidecar (NVIDIA drivers, libraries, firmware, tools)
        =
Complete bootable OS image with GPU support
```

**OpenShift analogy:** The sidecar is like adding the NVIDIA GPU Operator on top of a base
RHCOS image, except instead of a Kubernetes operator it is baked into the OS image at build
time.

### The Debian-to-RPM conversion

NVIDIA publishes all JetPack components as `.deb` packages for Ubuntu. The sidecar project
converts these to `.rpm` packages for CentOS/RHEL. The process:

1. **NVIDIA source tarballs** (stored in the `nvidia-files-lfs` git-lfs submodule) contain
   the raw content extracted from NVIDIA's `.deb` packages. These tarballs include
   libraries, firmware blobs, configuration files, and build scripts.
2. **RPM spec files** (in `SPECS/`) define how to repackage this content. Each spec file
   takes one or more tarballs as input and produces an RPM that installs the same files into
   the correct Red Hat filesystem hierarchy (e.g., libraries go to `/usr/lib64/` instead of
   Debian's `/usr/lib/aarch64-linux-gnu/`).
3. **The Makefile** orchestrates building all ~55 RPM packages from their spec files.

### The RPM spec files

There are roughly 55 spec files in `SPECS/`, each producing one RPM package. The most
important ones:

| Package | What it provides |
|---------|-----------------|
| `nvidia-jetpack-kmod-openrm` | GPU and platform kernel modules (`.ko` files) |
| `nvidia-jetpack-bsp-openrm` | Top-level "BSP" metapackage -- depends on everything |
| `nvidia-jetpack-core` | Core user-space libraries (libcuda, libnvidia-ml, etc.) |
| `nvidia-jetpack-cuda` | CUDA runtime libraries |
| `nvidia-jetpack-firmware` | GPU firmware blobs |
| `nvidia-jetpack-firmware-openrm` | OpenRM-specific firmware |
| `nvidia-jetpack-init` | udev rules, systemd services, system configuration |
| `nvidia-jetpack-init-openrm` | OpenRM-specific init scripts |
| `nvidia-jetpack-gstreamer` | GStreamer plugins for hardware video encode/decode |
| `nvidia-jetpack-multimedia` | Multimedia libraries (V4L2, video codec) |
| `nvidia-jetpack-nvml` | NVIDIA Management Library (what `nvidia-smi` talks to) |

The `nvidia-jetpack-bsp-openrm` package is the top-level "install everything" metapackage.
Its spec file is essentially a list of `Requires:` dependencies on every other package:

```
Requires: nvidia-jetpack-core = %{version}
Requires: nvidia-jetpack-cuda = %{version}
Requires: nvidia-jetpack-firmware = %{version}
Requires: nvidia-jetpack-firmware-openrm = %{version}
Requires: nvidia-jetpack-kmod-openrm
Requires: nvidia-jetpack-init = %{version}
Requires: nvidia-jetpack-init-openrm = %{version}
...
```

### The kernel module compilation (kmod spec)

The most complex spec file is `nvidia-jetpack-kmod.spec`. This one does not just repackage
files -- it **compiles** NVIDIA's OOT kernel module source code against the CentOS kernel
headers. Here is what happens:

**Inputs** (six source tarballs plus seven patches):
```
Source0: kernel_oot_modules_src.tbz2        # Tegra platform OOT modules
Source1: nvidia_unified_gpu_display_driver_source.tbz2  # GPU driver (openrm)
Source2: nvidia_kernel_display_driver_source.tbz2        # Display driver
Source3: nvidia-l4t-firmware_38.4.0-..._arm64.tbz2      # Firmware blobs
Source4: nvidia-l4t-kernel-oot-modules-licenses_...      # License files
Source5: nvidia-l4t-display-kernel-licenses_...          # License files

Patch0-4: 0001-nvidia-oot.patch through 0005-nvdisplay.patch  # Red Hat compatibility patches
Patch5:   0006-fix-vblk-getgeo-signature.patch                # Our kernel 6.12 fix
Patch6:   0007-unifiedgpudisp-kernel-6.12-compat.patch         # Our kernel 6.12 fix
```

**Build process:**
1. Extract all source tarballs into a build directory
2. Apply all seven patches
3. Set `KDIR` to the CentOS kernel headers directory
4. Run `make modules` -- this compiles hundreds of kernel modules against the CentOS 10
   kernel headers
5. Run `make modules_install` -- installs compiled `.ko` files into the RPM buildroot
6. Remove unnecessary modules (virtualization, debugging, crypto modules that conflict with
   the kernel or are not needed)
7. Package the remaining modules, modprobe configs, and firmware into the RPM

**Output:** The RPM installs `.ko` files into `/lib/modules/<kernel-version>/updates/`,
where they take precedence over any in-tree modules with the same name.

### The `--with openrm` flag

When you see this in the Containerfile:

```
RUN QA_RPATHS=$(( 0x0001|0x0010|0x0002 )) make kmod-srpm kmod-rpm RPMBUILD_EXTRAS="--with openrm"
```

The `--with openrm` flag tells the kmod spec to build the **unifiedgpudisp** (open resource
manager) GPU driver instead of the legacy **nvgpu** driver. This flag controls:

1. **Package naming:** `nvidia-jetpack-kmod-openrm` instead of `nvidia-jetpack-kmod-nvgpu`
2. **GPU driver source:** Uses `nvidia_unified_gpu_display_driver_source.tbz2` (Blackwell
   GPU driver shared with datacenter) instead of the legacy nvgpu driver
3. **Build configuration:** Sets `OPENRM=1` which enables the open-source kernel module
   build path in NVIDIA's Makefile

Thor **requires** openrm because its Blackwell GPU is only supported by the unified driver.
The legacy nvgpu driver does not know about SM_110 (Blackwell's streaming multiprocessor
architecture). Orin (JetPack 6.x) could use either nvgpu or openrm; Thor can only use
openrm.

### The NVIDIA source tarballs (nvidia-files-lfs)

The NVIDIA source tarballs are too large for regular git. They live in a git-lfs submodule
at `SOURCES/nvidia-files-lfs/`. This submodule points to a GitLab repository that stores
the actual binary tarballs using git-lfs (Large File Storage).

The tarballs contain:
- Kernel module source code (C, headers, Kbuild files)
- Pre-compiled user-space libraries (`.so` files for CUDA, cuDNN, etc.)
- Firmware binary blobs (GPU microcode, audio DSP firmware)
- Configuration files and scripts
- License and copyright files

The `38.4.0_openrm` branch of the LFS repo has the R38.4.0 tarballs specifically for the
openrm (Thor) build.

### How the Containerfile multi-stage build works

The Containerfile in `scripts/bootc/Containerfile` uses a three-stage build:

#### Stage 1: Build (compile kernel modules, build RPMs)

```dockerfile
FROM ghcr.io/nickcao/centos-bootc-tegra:stream10-devel as build
```

This stage starts from the `-devel` image, which has the patched CentOS kernel **plus**
kernel-devel headers (needed for compiling OOT modules). It:

1. Installs build dependencies (`g++`, `make`, `rpmdevtools`, `git-lfs`, etc.)
2. Runs `make kmod-srpm kmod-rpm RPMBUILD_EXTRAS="--with openrm"` -- compiles all NVIDIA
   OOT kernel modules against the CentOS kernel and packages them as RPMs
3. Runs `make jetpack-srpms jetpack-rpms` -- builds all ~55 user-space JetPack RPMs
4. Runs `createrepo` to turn the RPMs directory into a yum repository

The `QA_RPATHS` environment variable suppresses rpmbuild warnings about non-standard RPATH
entries in NVIDIA's pre-compiled binaries. NVIDIA's libraries have RPATHs that do not follow
Fedora/RHEL conventions, but they are functional.

#### Stage 2: Repo (HTTP-served RPM repository)

```dockerfile
FROM registry.access.redhat.com/ubi10/httpd-24:latest as repo
COPY --from=build /repos/RPMS/ /var/www/html/RPMS/
COPY --from=build /repos/SRPMS/ /var/www/html/SRPMS/
```

This stage creates a container that serves the built RPMs over HTTP. You can `podman run`
this container and point `dnf` at it to install NVIDIA packages on a running system. This
is useful for development and debugging but is not used for the bootc image build.

#### Stage 3: Bootc (the final bootable OS image)

```dockerfile
FROM ghcr.io/nickcao/centos-bootc-tegra:stream10 as bootc
```

This is the stage that produces the actual bootable OS image. It starts from the non-devel
centos-bootc-tegra base (smaller, no kernel headers) and:

1. **Copies the built RPMs** from the build stage into `/srv/nvidia-jetpack/`
2. **Sets up a local yum repo** pointing at those RPMs
3. **Adds NVIDIA's container toolkit repo** (for nvidia-container-toolkit)
4. **Enables CRB** (CodeReady Builder) and **EPEL** repos for dependencies
5. **Installs key packages:**
   - `nvidia-jetpack-bsp-openrm` -- pulls in all NVIDIA drivers and libraries
   - `nvidia-jetpack-gstreamer` -- hardware video codec support
   - `nvidia-container-toolkit-base` -- enables GPU access in containers
6. **Removes problematic camera modules** that cause boot failures
7. **Runs `depmod`** to regenerate module dependency information
8. **Blacklists modules** that should not auto-load:
   ```
   blacklist tegra_camera_rtcpu
   blacklist hsp_mailbox_client
   blacklist tegra_camera_platform
   ...
   ```
9. **Configures dracut** to omit certain drivers from the initramfs:
   ```
   omit_drivers+=" host1x tegra_drm nvethernet nvidia nvgpu ... "
   ```
   These modules should load after the root filesystem is mounted, not during early boot
   from initramfs. Including large GPU modules in the initramfs would waste boot memory
   and slow down the boot process.
10. **Regenerates the initramfs** with `dracut -vf`
11. **Sets up nvidia-ctk service** -- a oneshot systemd service that runs
    `nvidia-ctk cdi generate` at boot to create the CDI (Container Device Interface)
    configuration at `/etc/cdi/nvidia.yaml`. This is what allows `podman run --device
    nvidia.com/gpu=all` to work.
12. **Configures the root partition to auto-expand** by removing the
    `ConditionVirtualization=vm` check from the growpart service (Thor is bare metal, not a
    VM, but we still want the root partition to fill the disk).
13. **Sets up serial console boot arguments** via `00-console.toml`:
    ```toml
    kargs = ["enforcing=0", "fbcon=map:0",
             "earlycon=tegra_utc,mmio32,0xc5a0000",
             "console=tty0", "console=ttyUTC0,115200",
             "clk_ignore_unused"]
    ```

**OpenShift analogy:** This three-stage build is conceptually similar to:
1. Building an Operator (compile Go code, produce binary)
2. Publishing the Operator catalog (serve it from a registry)
3. Installing the Operator on a cluster (the final running state)

Except here the "cluster" is a single bare-metal edge device, and the "Operator" is the
GPU driver stack baked into the OS image.

---

## 5. What We Added (Our Patches)

The `r38.4.0-wip` branch of the sidecar was a work-in-progress targeting kernel 6.8 (the
kernel NVIDIA ships with R38.4 L4T). The centos-bootc-tegra base uses CentOS 10 Stream
kernel 6.12. Between kernel 6.8 and 6.12, several internal kernel APIs changed, breaking
NVIDIA's OOT module builds. We created patches to fix these build failures.

### Patch 0006: vblk_getgeo signature + watchdog module disable

**File:** `SOURCES/0006-fix-vblk-getgeo-signature.patch`

This patch fixes two issues:

**1. vblk_getgeo function signature change:**

In the upstream kernel, the `block_device_operations.getgeo` callback signature changed
between 6.8 and 6.12. The first argument was changed from `struct block_device *device` to
`struct gendisk *disk`:

```c
// Old (kernel 6.8):
static int vblk_getgeo(struct block_device *device, struct hd_geometry *geo)
{
    geo->cylinders = get_capacity(device->bd_disk) / ...

// New (kernel 6.12):
static int vblk_getgeo(struct gendisk *disk, struct hd_geometry *geo)
{
    geo->cylinders = get_capacity(disk) / ...
```

This is a one-liner API change, but without the fix the module would not compile.

**2. Watchdog module removal:**

The patch also removes the `watchdog/` directory from the nvidia-oot drivers Makefile:

```diff
-obj-m += watchdog/
```

NVIDIA's OOT watchdog modules (`max77851_wdt.ko`, `softdog-platform.ko`,
`watchdog-tegra-t18x.ko`) conflict with the in-tree CentOS kernel watchdog drivers. Rather
than fix the conflicts, we simply do not build them -- the CentOS kernel's built-in watchdog
support is sufficient.

### Patch 0007: unifiedgpudisp kernel 6.12 compatibility

**File:** `SOURCES/0007-unifiedgpudisp-kernel-6.12-compat.patch`

This is the more interesting patch. It fixes two kernel API changes that break the GPU
driver (unifiedgpudisp) build on kernel 6.12:

**1. `dma_map_ops.map_resource` removal:**

In kernel 6.12, commit `14cb413af00c` removed the `map_resource` member from
`struct dma_map_ops`. NVIDIA's `nv-dma.c` checks `ops->map_resource != NULL` to determine
DMA capabilities. On 6.12, this field no longer exists.

The fix uses NVIDIA's own **conftest** pattern -- a compile-time feature detection system
(similar to autoconf's `configure` script):

```c
// conftest.sh addition -- tries to compile code that accesses map_resource
void conftest_dma_map_ops_has_map_resource(void) {
    struct dma_map_ops ops;
    (void)ops.map_resource;  // Fails if member does not exist
}
```

This generates a `#define NV_DMA_MAP_OPS_HAS_MAP_RESOURCE` (or not) at build time. The
driver code then uses it:

```c
#if defined(NV_DMA_MAP_OPS_HAS_MAP_RESOURCE)
    return (ops->map_resource != NULL);
#else
    return NV_TRUE;  // Assume DMA is capable on newer kernels
#endif
```

**2. `pci_resize_resource` gains a fourth argument:**

In kernel 6.12, commit `337b1b566db0` added an `exclude_bars` parameter to
`pci_resize_resource()`. NVIDIA's `nv-pci.c` calls this function to resize BAR1 (the GPU's
PCI memory aperture).

Again using conftest:

```c
// conftest.sh -- tries to compile a 4-argument call
void conftest_pci_resize_resource_has_four_args(void) {
    pci_resize_resource(NULL, 0, 0, 0);  // Fails if function takes 3 args
}
```

```c
// nv-pci.c
#if defined(NV_PCI_RESIZE_RESOURCE_HAS_FOUR_ARGS)
    r = pci_resize_resource(pci_dev, NV_GPU_BAR1, requested_size, 0);
#else
    r = pci_resize_resource(pci_dev, NV_GPU_BAR1, requested_size);
#endif
```

**Why conftest matters:** NVIDIA's driver source tree has its own compile-time feature
detection system (`conftest.sh`). Before building the driver, the build system runs dozens
of small test compilations to detect which kernel features and APIs are available, then
generates `#define` macros accordingly. Our patch follows this existing pattern rather than
using raw `#if LINUX_VERSION_CODE >= ...` checks, which is both more robust (it tests actual
API availability, not version numbers) and consistent with NVIDIA's codebase conventions.

The conftest tests are registered in `nvidia.Kbuild`:

```
NV_CONFTEST_TYPE_COMPILE_TESTS += dma_map_ops_has_map_resource
NV_CONFTEST_TYPE_COMPILE_TESTS += pci_resize_resource_has_four_args
```

### Containerfile fixes

Beyond the kernel module patches, we also needed to fix issues in the Containerfile itself:

**1. EPEL release URL fix:**

The original Containerfile referenced the EPEL 9 RPM URL. CentOS 10 Stream needs EPEL 10:

```dockerfile
dnf -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm
```

**2. Module blacklisting and dracut omit rules:**

We added blacklist entries for camera-related modules that cause kernel panics during boot
when the camera hardware is not connected (which it is not on the developer kit):

```
blacklist tegra_camera_rtcpu
blacklist hsp_mailbox_client
blacklist tegra_camera_platform
blacklist tegra_camera
blacklist capture_ivc
blacklist nvhost_capture
blacklist nvhost_vi5
blacklist nvhost_isp5
blacklist nvhost_nvcsi_t194
```

And dracut omit rules to keep large modules out of the initramfs:

```
omit_drivers+=" host1x tegra_drm nvethernet nvidia nvgpu host1x_fence host1x_nvhost "
```

**3. Systemd service masking:**

```dockerfile
RUN sudo systemctl mask nvfancontrol.service nvpmodel.service nvpower.service
```

These NVIDIA power management services expect an Ubuntu environment and fail on CentOS.
Masking them prevents boot failures. Fan control falls back to firmware-level management.

### Why these patches were needed (the version gap)

The root cause of all our patches is a version gap:

- **NVIDIA's R38.4.0 OOT sources** were developed and tested against **kernel 6.8**
  (the L4T kernel)
- **CentOS 10 Stream** ships **kernel 6.12**

Between kernel 6.8 and 6.12, the upstream Linux kernel made several API changes:
- `block_device_operations.getgeo` signature change
- `struct dma_map_ops` member removal
- `pci_resize_resource()` argument change
- Various watchdog driver refactoring

Each of these changes is individually small, but any one of them causes a compile failure
that blocks the entire OOT module build. Our patches fix these compile failures while
maintaining backward compatibility (the conftest approach means the same patched source can
still build against kernel 6.8 if needed).

---

## 6. The Boot Chain

### How Thor boots with our image

```
 QSPI Flash (firmware)          NVMe SSD (our image)
 ┌─────────────────┐            ┌────────────────────────────┐
 │ UEFI Firmware   │──────────> │ EFI System Partition       │
 │ (SBSA compliant)│            │ └── EFI/centos/grubaa64.efi│
 │                 │            │                            │
 │ Device Tree     │            │ /boot                      │
 │ Blobs (DTBs)    │            │ ├── vmlinuz-6.12.x         │
 │                 │            │ ├── initramfs-6.12.x.img   │
 │ OP-TEE / ATF    │            │ └── grub2/grub.cfg         │
 └─────────────────┘            │                            │
                                │ / (root filesystem)        │
                                │ ├── ostree deployment      │
                                │ ├── /usr/lib/modules/      │
                                │ │   └── nvidia .ko files   │
                                │ └── /usr/lib64/            │
                                │     └── libcuda.so etc.    │
                                └────────────────────────────┘
```

The boot sequence:

1. **Power on** -- UEFI firmware loads from QSPI flash. It initializes the SoC: clocks,
   memory controller, PCIe, USB, NVMe controllers.
2. **UEFI** -- Reads the NVMe's GPT partition table, finds the EFI System Partition (ESP),
   loads `EFI/centos/grubaa64.efi` (GRUB for aarch64).
3. **GRUB** -- Reads `grub.cfg`, loads the CentOS kernel (`vmlinuz`) and initial ramdisk
   (`initramfs`) into memory. Passes kernel command line arguments including
   `console=ttyTCU0` for serial output.
4. **Linux kernel** -- Takes over from GRUB. The patched CentOS 6.12 kernel initializes
   the Tegra264 platform drivers (PCIe, pinctrl, clocks) using the device tree blobs from
   QSPI firmware.
5. **initramfs** -- The initial ramdisk mounts the root filesystem (ostree deployment),
   pivots root, and hands off to systemd. Note: GPU modules are intentionally excluded
   from initramfs (dracut omit rules) to keep this stage fast.
6. **systemd** -- Starts services. `systemd-modules-load.service` loads NVIDIA kernel
   modules per `/etc/modules-load.d/nvidia-load.conf`. The `nvidia-ctk.service` runs
   `nvidia-ctk cdi generate` to create the CDI device specification.
7. **System ready** -- GPU is accessible via `/dev/nvidia*`, containers can use
   `--device nvidia.com/gpu=all`.

### How this differs from NVIDIA's default boot

On a stock Ubuntu L4T system, the boot chain is:

```
QSPI UEFI  -->  L4TLauncher (NVIDIA's custom EFI app)  -->  Ubuntu kernel  -->  Ubuntu systemd
```

L4TLauncher is NVIDIA's own EFI application that handles:
- Selecting between multiple boot entries (A/B rootfs)
- Applying device tree overlays for different carrier boards
- Showing a boot splash screen

With our CentOS image, we bypass L4TLauncher entirely and use standard GRUB. This works
because Thor's UEFI firmware is SBSA-compliant -- it does not require L4TLauncher. GRUB is
installed as the default EFI boot entry, and UEFI loads it directly.

### Why GRUB works on Thor

GRUB works because SBSA/UEFI compliance means the firmware presents standard EFI boot
services. GRUB does not need to know anything about Tegra hardware -- it just uses EFI
protocols to load the kernel, the same way it would on any aarch64 server.

The only Thor-specific piece in GRUB's configuration is the console kernel argument:
`console=ttyTCU0,115200` (or `console=ttyUTC0,115200` depending on firmware version). This
tells the kernel to send output to Thor's Tegra Combined UART, which is the debug serial
port accessible via the USB-C debug connector.

### Serial console (ttyTCU0) for debugging

Thor has a USB-C debug port that provides a serial console via the Tegra Combined UART
(TCU). This is configured in `scripts/bootc/00-console.toml`:

```toml
kargs = ["enforcing=0", "fbcon=map:0",
         "earlycon=tegra_utc,mmio32,0xc5a0000",
         "console=tty0", "console=ttyUTC0,115200",
         "clk_ignore_unused"]
```

- `earlycon=tegra_utc,mmio32,0xc5a0000` -- enables early console output before the full
  UART driver loads (shows kernel boot messages from the very first print)
- `console=ttyUTC0,115200` -- main console on Tegra UART at 115200 baud
- `clk_ignore_unused` -- prevents the kernel from disabling clocks it thinks are unused
  (some Tegra clocks appear unused to the kernel but are actually needed by coprocessors)

To connect: plug a USB-C cable into Thor's debug port, find the serial device on your
workstation (`/dev/ttyACM0` on Linux), and use `minicom` or `screen` at 115200 baud.

---

## 7. The Deployment Process

### Why bootc-image-builder failed on x86

The expected workflow is:

1. Build the bootc OCI image with `podman build`
2. Convert it to a disk image with `bootc-image-builder` (BIB)
3. Write the disk image to storage

Step 2 failed when running on an x86 desktop. `bootc-image-builder` needs to create disk
partitions and filesystems, which requires loopback device ioctls (`LOOP_SET_FD`,
`LOOP_SET_STATUS64`). When running inside a container under QEMU user-mode emulation (which
is how we cross-build for aarch64 on x86), these ioctls cannot be emulated -- they are
kernel-level operations that QEMU user-mode does not intercept.

The Makefile shows the workaround attempts (tmpfs mounts, `--privileged`, label disable) but
the fundamental issue is that BIB needs real block device operations that QEMU user-mode
cannot provide.

### Alternative: bootc install to-disk

Instead of using BIB on x86, the deployment path is:

1. **Build the bootc OCI image** on x86 with QEMU emulation (this works -- it is just
   container build operations, no block device ioctls)
2. **Push the image to a registry** (or transfer as a tar)
3. **On the Thor device (or USB live boot):** Run `bootc install to-disk` which writes
   the OCI image directly to a block device:
   ```bash
   podman run --rm --privileged --pid=host \
     -v /dev:/dev -v /var/lib/containers:/var/lib/containers \
     <registry>/jetpack-bootc:stream10 \
     bootc install to-disk /dev/nvme0n1
   ```
   This creates the GPT partition table, EFI system partition, root filesystem, and
   installs GRUB -- all in one command.

### The USB boot path

Because you cannot run `bootc install to-disk` on the same disk you are booted from (it
would overwrite the running OS), the typical path is:

1. **Write a minimal bootable image to a USB drive** (from a working OS on the Thor, or
   using `dd` from another machine)
2. **Boot Thor from USB** (via UEFI boot menu -- press the appropriate key during POST)
3. **From the USB-booted system**, run `bootc install to-disk /dev/nvme0n1` to install
   the full image to the internal NVMe
4. **Reboot** and remove USB -- Thor boots from NVMe with the complete CentOS + JetPack
   image

Alternatively, if Thor is currently running Ubuntu on NVMe, you can:

1. `scp` the OCI image tarball to Thor
2. Load it into podman
3. Run `bootc install to-disk` targeting a USB drive
4. Reboot from USB
5. Run `bootc install to-disk /dev/nvme0n1` to install to NVMe

### bootc upgrade workflow

Once the system is running, future OS updates follow the bootc upgrade pattern:

```bash
# On the Thor device:
bootc upgrade    # Pulls latest image from registry, stages it
systemctl reboot # Reboots into the new image
```

**OpenShift analogy:** This is like a MachineConfigPool rolling update. The new OS image is
staged alongside the current one, the system reboots into the new image, and the old image
is kept as a rollback target. If the new image fails to boot, you can select the previous
deployment from the GRUB menu.

---

## 8. Reading the Build Log

When you run `make jetpack-bootc` (or manually `podman build` the Containerfile), the build
log scrolls a lot of output. This section walks through what you see, in order, so you can
tell whether the build is healthy or where it went wrong.

### Phase 0: Pre-build setup (spectool warnings, image pulls)

Before the container build starts, the Makefile does some preparation:

**spectool warnings:** You will see warnings from `spectool` about sources it cannot
download. These are harmless. `spectool` is a helper that tries to download source files
listed in spec files, but our sources are local tarballs from the git-lfs submodule, not
URLs. The warnings look like:

```
error: File ... is not accessible: No such file or directory
```

Ignore these. They are the Makefile's `scripts/get_spec_sources.sh` checking which source
files each spec needs so it can set up Make dependencies correctly. It does not actually
need to download anything at this point.

**`buildah pull` of base images:** The Makefile pulls the centos-bootc-tegra base images
from ghcr.io:

```
buildah pull --arch arm64 ghcr.io/nickcao/centos-bootc-tegra:stream10
```

These are the pre-built CentOS 10 Stream images with the Tegra264-patched kernel. The
`stream10-devel` variant (used in Stage 1) includes kernel-devel headers; the plain
`stream10` variant (used in Stage 3) is a smaller bootable base.

**Kernel version detection:** The Makefile runs a quick `podman run` on the base image to
detect the installed kernel version:

```
podman run --rm --platform linux/arm64 <image> rpm -q kernel --qf '%{version}-%{release}'
```

This extracts the kernel version string (e.g., `6.12.0-224.el10`) that the OOT modules
must be compiled against. If this step fails, the rest of the build will use the wrong
kernel version and produce unusable modules.

### Phase 1: Stage 1 build (compiling kernel modules and RPMs)

This is the longest phase -- typically 1-3 hours under QEMU emulation, 30-60 minutes on
native aarch64.

**Container startup:**
```
FROM ghcr.io/nickcao/centos-bootc-tegra:stream10-devel as build
```

The build starts from the `-devel` image, which has everything the plain base has plus
kernel headers in `/usr/src/kernels/`.

**Installing build dependencies:**
```
dnf install -y createrepo g++ git-lfs make python3-devel rpmdevtools yum-utils
```

This installs the toolchain needed to compile C/C++ kernel modules and build RPMs. `g++` is
needed because some NVIDIA modules use C++ (unusual for kernel code, but NVIDIA's GPU driver
has C++ components in its open-source parts). `rpmdevtools` provides `rpmbuild`.

**`make clean`:** Clears any artifacts from a previous build attempt. Harmless if there is
nothing to clean.

**`make kmod-srpm kmod-rpm` -- the kernel module build:**

This is the critical step. It invokes `rpmbuild` on the kmod spec file, which has several
sub-phases visible in the log:

**rpmbuild %prep (source extraction and patching):**

```
Executing(%prep): ...
/usr/bin/tar xvf kernel_oot_modules_src.tbz2
/usr/bin/tar xvf nvidia_unified_gpu_display_driver_source.tbz2
/usr/bin/tar xvf nvidia_kernel_display_driver_source.tbz2
...
Applying patch 0001-nvidia-oot.patch
Applying patch 0002-nvgpu.patch
...
Applying patch 0006-fix-vblk-getgeo-signature.patch
Applying patch 0007-unifiedgpudisp-kernel-6.12-compat.patch
```

The source tarballs are extracted and all seven patches are applied. Patches 0001-0005 are
the Red Hat team's existing compatibility patches. Patches 0006-0007 are our kernel 6.12
fixes. If a patch fails to apply (e.g., because the source changed in a new release), you
will see a `FAILED` message with the hunk that did not match -- this is a common failure
mode when upgrading to a new JetPack version.

**rpmbuild %build (compilation):**

This is the loudest part of the log. It has two sub-phases:

*Conftest (feature detection):*

```
conftest: dma_map_ops_has_map_resource... yes
conftest: pci_resize_resource_has_four_args... yes
conftest: shrinker_alloc_present... yes
...
```

Conftest tests are like feature detection -- the build system compiles small test programs
to check if the running kernel has a particular API, then sets `#define` flags so the NVIDIA
code can adapt to different kernel versions. Each test is a tiny C file that gets compiled
with `gcc`; success means the feature exists, failure means it does not. The build system
generates a `conftest.h` header with all the results.

If you see a conftest test fail that you expect to pass (or vice versa), it usually means
the kernel headers do not match what you expect. Check that `KDIR` points to the right
kernel headers directory.

*Module compilation:*

```
CC [M] drivers/gpu/drm/nvidia/nv-frontend.o
CC [M] drivers/gpu/drm/nvidia/nv-pci.o
CC [M] drivers/platform/tegra/dce/dce-module.o
...
LD [M] drivers/gpu/drm/nvidia/nvidia.ko
LD [M] drivers/gpu/drm/nvidia/nvidia-drm.ko
LD [M] drivers/gpu/drm/nvidia/nvidia-modeset.ko
```

This is `gcc` compiling hundreds of C source files (`.c` to `.o`) and then linking them into
kernel modules (`.o` files to `.ko` files). Each `CC [M]` line is a successful compilation;
`LD [M]` lines are the linker combining object files into a final `.ko` module.

**What to watch for:** Compiler warnings are common and usually harmless (NVIDIA's code
generates many warnings with strict kernel compiler flags). Errors (lines starting with
`error:`) stop the build. The most common errors are undeclared identifiers or wrong function
signatures -- these indicate a kernel API mismatch that needs a new patch.

Under QEMU emulation, this phase is slow because every `gcc` invocation runs through QEMU's
binary translation. You will see one CPU core pegged at 100% for the duration. Native
aarch64 builds parallelize across all cores.

**rpmbuild %install:**

```
make modules_install INSTALL_MOD_PATH=/root/rpmbuild/BUILDROOT/...
```

This copies the compiled `.ko` files into the RPM's build root directory, arranged in the
filesystem layout they will have when installed (`/lib/modules/<kver>/updates/...`). The spec
file then removes unnecessary modules (virtualization, debug, crypto).

**RPM packaging:**

```
Creating package nvidia-jetpack-kmod-openrm-38.4.0_6_12_0_224~20251230160601-1.el10.aarch64.rpm
```

The compiled modules, modprobe configs, and firmware files are packaged into an RPM. If this
line appears, the kernel module build succeeded.

**`make jetpack-srpms jetpack-rpms` -- userspace RPM builds:**

After the kernel modules, the build moves on to the ~55 userspace packages. These are
faster because they are mostly repackaging (extracting NVIDIA's tarballs and rearranging
files into RPM layout) rather than compiling. You will see a rapid succession of:

```
rpmbuild -bb SPECS/nvidia-jetpack-core.spec
rpmbuild -bb SPECS/nvidia-jetpack-cuda.spec
rpmbuild -bb SPECS/nvidia-jetpack-firmware.spec
...
```

Each of these follows the same pattern: extract tarball, fix filesystem paths (Debian layout
to RPM layout), install files, package RPM. Failures here are usually missing dependencies
or spec file syntax errors.

**`createrepo` -- creating the yum repository:**

```
createrepo /app/rpmbuild/RPMS/
createrepo /app/rpmbuild/SRPMS/
```

This scans all the built RPMs and creates yum repository metadata (`repodata/` directory
with XML files describing available packages). Stage 3 uses this metadata to install
packages with `dnf`.

### Phase 2: Stage 3 build (assembling the bootable image)

Stage 2 (the repo image) is built in parallel or skipped depending on the build target.
The bootc target goes directly from Stage 1 to Stage 3.

**Container startup:**
```
FROM ghcr.io/nickcao/centos-bootc-tegra:stream10 as bootc
```

Note this uses the non-devel base -- no kernel headers, smaller image.

**Copying RPMs and setting up repos:**
```
COPY --from=build /repos/RPMS/ /srv/nvidia-jetpack/
```

The RPMs built in Stage 1 are copied into the image. A local yum repo file
(`nvidia-local.repo`) points `dnf` at this directory.

**Package installation:**
```
dnf install -y nvidia-container-toolkit-base nvidia-jetpack-bsp-openrm nvidia-jetpack-gstreamer rsync
```

This is where everything comes together. `nvidia-jetpack-bsp-openrm` is the metapackage
that depends on everything -- installing it triggers installation of the kernel modules,
CUDA libraries, firmware, and all other NVIDIA components. You will see a long list of
dependency resolution as `dnf` figures out the install order.

**OpenShift analogy:** This is like an Operator's dependency resolution -- installing the
top-level Operator triggers installation of all its operands and prerequisites.

**Module cleanup, blacklisting, and depmod:**
```
rm -f /usr/lib/modules/*/updates/drivers/platform/tegra/rtcpu/tegra-camera-rtcpu.ko
rm -f /usr/lib/modules/*/updates/drivers/platform/tegra/rtcpu/hsp-mailbox-client.ko
depmod -a $(ls /usr/lib/modules/)
```

Problematic camera modules are removed, and `depmod` regenerates the module dependency
database. `depmod` scans all installed `.ko` files and creates `modules.dep`, which tells
the kernel's module loader what order to load modules in and what dependencies each module
has.

**Blacklisting and dracut configuration:**
```
echo 'blacklist tegra_camera_rtcpu' > /etc/modprobe.d/nvidia-camera.conf
echo 'omit_drivers+=" host1x tegra_drm ... "' > /etc/dracut.conf.d/omit-nvidia.conf
```

Blacklisting prevents modules from auto-loading at boot. The dracut omit rules go further:
they exclude specified modules from the initramfs entirely.

**dracut -- building the initramfs:**
```
dracut -vf /usr/lib/modules/<kver>/initramfs.img <kver>
```

dracut builds the initramfs, which is a tiny filesystem loaded into RAM at boot before the
real root filesystem is mounted. It needs just enough kernel modules to find and mount the
NVMe drive (storage controllers, filesystem drivers) but should NOT include the large GPU
modules (which would waste boot memory and slow down early boot). The `-vf` flags mean
verbose and force (overwrite existing).

The dracut output is detailed -- you will see it pulling in modules for NVMe, filesystem
support, systemd, and basic networking, while skipping the NVIDIA modules we told it to
omit. If dracut fails, it usually means a required module has an unsatisfied dependency. The
verbose output tells you exactly what it tried to include and why it failed.

**Service enablement and final configuration:**
```
systemctl enable nvidia-ctk.service
systemctl mask nvfancontrol.service nvpmodel.service nvpower.service
```

The nvidia-ctk service is enabled so CDI device configuration is generated at every boot.
NVIDIA's power management services are masked because they expect an Ubuntu environment.

**Image commit:**

At the end, podman/buildah commits the final layer. The output image is a bootable OCI
container image containing: CentOS 10 Stream base + Tegra264-patched kernel + all NVIDIA
JetPack drivers and libraries + nvidia-container-toolkit + properly configured initramfs.

### Summary: what a healthy build looks like

A successful build produces output roughly in this order:

1. Image pulls complete without errors
2. Kernel version is detected (you see the version string printed)
3. `%prep` applies all 7 patches without `FAILED` hunks
4. Conftest tests run (a mix of "yes" and "no" results is normal)
5. Hundreds of `CC [M]` lines with no `error:` lines
6. `LD [M]` lines produce `.ko` files
7. RPM creation succeeds for all packages
8. `createrepo` completes
9. Stage 3 `dnf install` resolves all dependencies
10. `depmod` and `dracut` complete without errors
11. Final image is committed

The most common failure points are: patch application failure (Step 3), compile errors from
kernel API mismatches (Step 5), and dependency resolution failures in Stage 3 (Step 9). If
you see a failure, the phase it occurs in tells you where to look.

---

## 9. How This Relates to Red Hat Products

### Red Hat Device Edge on Jetson Orin (GA)

Red Hat Device Edge is the GA product for running RHEL on Jetson hardware. As of RHEL 9.8,
it supports Jetson Orin (JetPack 6.x). It provides:

- RHEL 9 bootc images for Orin
- MicroShift (single-node OpenShift) for edge Kubernetes
- Red Hat Edge Manager for fleet management

Device Edge uses the **same nvidia-jetson-sidecar project** we are using -- just the
`r36.x` branches for Orin instead of our `r38.4.0-wip` for Thor. The architecture is
identical: centos-bootc-tegra (or RHEL-bootc-tegra) base + sidecar NVIDIA driver layer.

**Why Thor is not supported yet:** Adding a new hardware platform to a GA product requires
Project Voyager approval (Red Hat's hardware enablement process). Thor is too new -- the
Tegra264 kernel patches are not upstream yet, the OOT driver situation is still evolving,
and the hardware itself was only recently available. Our PoC demonstrates feasibility to
build the case for Voyager approval.

### RHAIIS / Red Hat AI Inference Server

RHAIIS (Red Hat AI Inference Server) is Red Hat's enterprise AI inference product. It is
essentially a productized, hardened, supported build of vLLM. As of version 3.4.1:

- **Supported platforms:** x86_64 only, datacenter GPUs (A100, H100, etc.)
- **Deployment model:** Container image on OpenShift or standalone RHEL
- **Not available for aarch64 or Jetson**

For our Thor PoC, we use upstream vLLM instead. NVIDIA publishes Thor-optimized vLLM
containers at `ghcr.io/nvidia-ai-iot/vllm:latest-jetson-thor` with:
- vLLM 0.19.0
- PyTorch compiled for SM_110 (Blackwell)
- CUDA 13.0
- Optimizations for unified memory

Functionally, upstream vLLM and RHAIIS serve the same OpenAI-compatible API. If/when RHAIIS
adds aarch64 support, it would be a drop-in replacement.

### Red Hat ET edge-ai-image-pipelines

Red Hat Emerging Technologies has an experimental project (`edge-ai-image-pipelines`) that
builds bootc images with AI inference capabilities for Jetson. Currently:
- **Supports Orin only** (JetPack 6.x)
- **Bundles vLLM, Ollama, or Triton** as containerized inference servers
- **Experimental** -- not GA, not supported

Our PoC extends this concept to Thor hardware.

### Where our PoC fits

```
                        Datacenter (x86_64)           Edge (aarch64)
                    ┌───────────────────────────┬───────────────────────────┐
 Production (GA)    │  RHAIIS on OpenShift       │  Device Edge on Orin      │
                    │  (RHEL + GPU Operator)     │  (RHEL 9 + MicroShift)    │
                    ├───────────────────────────┼───────────────────────────┤
 Experimental       │                            │  ET edge-ai-pipelines     │
                    │                            │  (Orin only)              │
                    ├───────────────────────────┼───────────────────────────┤
 Our PoC            │                            │  CentOS 10 + JetPack +   │
                    │                            │  vLLM on Thor             │
                    │                            │  (THIS PROJECT)           │
                    └───────────────────────────┴───────────────────────────┘
```

We are demonstrating what the bottom-right cell of this matrix would look like as a
production product: immutable bootc OS + containerized AI inference on NVIDIA's newest edge
hardware. The path to productization:

1. **CentOS 10 Stream kernel 6.12** is the same kernel base as RHEL 10
2. **The sidecar RPM build process** is the same one used for Device Edge on Orin
3. **Tegra264 patches** will (eventually) land in the upstream kernel, at which point the
   centos-bootc-tegra patched kernel becomes unnecessary
4. **The bootc deployment model** is the same one Device Edge already uses
5. **nvidia-container-toolkit + CDI** is the same GPU-in-containers solution used across
   all NVIDIA platforms

The PoC proves that all the pieces work together. Productization means getting Voyager
approval, upstreaming the kernel patches, and running through QE.

---

## 10. Glossary

**bootc** -- A tool and paradigm for managing bootable Linux systems as OCI container
images. The OS is defined as a Containerfile, built with podman, and deployed by writing the
image to disk. Updates are pulled as new container image layers. Think: "the OS is a
container." In OpenShift terms, a bootc image is like a MachineConfig that IS the entire
node OS.

**CDI (Container Device Interface)** -- A specification for making hardware devices available
inside containers. `nvidia-ctk cdi generate` scans the host for NVIDIA devices and creates a
YAML file (`/etc/cdi/nvidia.yaml`) describing them. Container runtimes (podman, containerd)
read this file to set up device access. In OpenShift terms, CDI is the mechanism behind the
NVIDIA GPU Operator's device plugin -- it is how `--device nvidia.com/gpu=all` works.

**conftest** -- NVIDIA's compile-time feature detection system for their kernel drivers.
Before building, the build system runs small test compilations (`conftest.sh`) to detect
which kernel APIs are available, generating `#define` macros. This is analogous to
autoconf's `configure` script. It allows the same driver source to build against multiple
kernel versions.

**DTB (Device Tree Blob)** -- A binary data structure that describes the hardware layout of
a system: which peripherals exist, where they are mapped in memory, what interrupts they
use. On ARM systems (unlike x86 where ACPI serves this role), the bootloader passes a DTB
to the kernel so it knows what hardware is present. Thor's DTBs live in QSPI firmware.

**JetPack** -- NVIDIA's SDK bundle for Jetson. Includes L4T (the OS), CUDA, cuDNN,
TensorRT, multimedia APIs, and developer tools. Version numbering: JetPack 7.x = L4T R38.x
(Thor), JetPack 6.x = L4T R36.x (Orin), JetPack 5.x = L4T R35.x (Xavier).

**kmod** -- Short for "kernel module." In the RPM world, `kmod-*` packages contain compiled
`.ko` (kernel object) files that extend the kernel's functionality. The sidecar's
`nvidia-jetpack-kmod-openrm` package contains all the compiled NVIDIA GPU and platform
driver modules.

**L4T (Linux for Tegra)** -- NVIDIA's customized Linux distribution for Jetson devices.
Built on Ubuntu with a patched kernel, proprietary drivers, and Tegra-specific user-space
libraries. It is the "blessed" OS for Jetson, analogous to RHCOS for OpenShift.

**NVMe** -- Non-Volatile Memory Express. The storage interface and protocol used by Thor's
internal SSD. The OS lives on NVMe (`/dev/nvme0n1`).

**OOT (Out-Of-Tree)** -- Kernel modules whose source code is not part of the upstream Linux
kernel source tree. NVIDIA ships OOT modules for Tegra because the drivers are not (yet)
upstream. These modules are compiled against the installed kernel's headers and loaded at
runtime.

**openrm (Open Resource Manager)** -- NVIDIA's open-source kernel module for GPU resource
management. Originally developed for datacenter GPUs (Turing+), it was extended to Jetson
with Thor because Thor uses a Blackwell GPU (same architecture as datacenter). The `--with
openrm` build flag selects this driver instead of the legacy `nvgpu` driver. Thor requires
openrm; Orin supports either.

**ostree** -- A content-addressed filesystem layering system used by bootc to manage OS
deployments. Each OS version is a complete filesystem tree stored content-addressable (like
git for OS files). bootc stores its deployments as ostree commits. Multiple deployments can
coexist, enabling atomic rollback.

**QSPI (Quad SPI Flash)** -- A flash memory chip soldered to the Jetson module that stores
firmware: UEFI, device trees, TrustZone, and other boot-critical components. QSPI is to
Thor what the BIOS ROM is to a PC -- it is flashed separately from the OS and persists
across OS reinstalls.

**SBSA (Server Base System Architecture)** -- An ARM specification that defines requirements
for server-class ARM systems: UEFI boot, ACPI (or DT), standard interrupt controllers, etc.
Thor's SBSA compliance is what lets us boot GRUB and CentOS without NVIDIA-specific boot
hacks.

**SM_110** -- Streaming Multiprocessor generation 110, the compute unit designation for
NVIDIA's Blackwell GPU architecture. CUDA code compiled for SM_110 runs on Blackwell GPUs
(datacenter B200, Jetson Thor). Earlier Jetson GPUs used SM_87 (Orin/Ampere) or SM_72
(Xavier/Volta).

**tegra264** -- The internal NVIDIA codename for the Thor SoC platform. The number roughly
corresponds to the hardware generation: tegra194 = Xavier, tegra234 = Orin, tegra264 = Thor.
Kernel configs and driver code use this codename (e.g., `CONFIG_PCIE_TEGRA264`,
`pinctrl-tegra264`).

**UEFI (Unified Extensible Firmware Interface)** -- The standard firmware interface on
modern computers (replacing BIOS). UEFI provides a standardized boot process: the firmware
reads a GPT partition table, finds the EFI System Partition, and loads an EFI application
(typically GRUB). Thor's UEFI firmware lives in QSPI flash.
