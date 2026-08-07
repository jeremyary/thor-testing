# vLLM and Cosmos3-Edge on NVIDIA Jetson AGX Thor with CentOS Stream 10

> [!NOTE]
> This project was developed with assistance from AI tools.

This document captures the complete path from a boxed Jetson AGX Thor developer kit to
running vLLM inference and Cosmos3-Edge omni-modal serving on a CentOS Stream 10 bootc
image. It covers text LLM inference (Granite 3.2 2B), omni-modal world model inference
(Cosmos3-Edge 4B via vllm-omni), and the action-preview PoC pipeline. It records every
blocker encountered, the root cause of each, and the exact workarounds applied.

---

## Hardware

- **NVIDIA Jetson AGX Thor** developer kit (T5000 SoC)
- Blackwell GPU (SM_110), 128 GB unified LPDDR5X memory
- 14 ARM Neoverse V3AE cores (aarch64), 1 TB NVMe
- Firmware: R39.2 (JetPack 7.2), flashed via `l4t_initrd_flash.sh`

## Software Stack

| Layer | Component | Version |
|-------|-----------|---------|
| OS | CentOS Stream 10 bootc | kernel 6.12.0-253.el10 |
| Sidecar | nvidia-jetson-sidecar | `feature/thor-tegra264-kernel` branch |
| Driver | NVIDIA OpenRM (OOT kmod) | 595.78 (NV_VERSION synced) |
| Container toolkit | nvidia-container-toolkit-base | 1.19.1 |
| CDI | nvidia-ctk cdi generate | CSV mode (auto-detected) |
| Container runtime | Podman | 6.0.2 |
| vLLM container (text) | ghcr.io/nvidia-ai-iot/vllm:latest-jetson-thor | vLLM 0.19.0, PyTorch 2.10.0, CUDA 13.0 |
| vLLM container (faster) | nvcr.io/nvidia/vllm:26.07-py3 | vLLM 0.24.0, CUDA 13.3 forward compat |
| Cosmos3 container | docker.io/vllm/vllm-omni:cosmos3 | vLLM 0.25.0 + vllm-omni 0.25.0rc2, arm64 |
| Text model | ibm-granite/granite-3.2-2b-instruct | 2B params, safetensors |
| Omni model | nvidia/Cosmos3-Edge | 4B params, BF16, world foundation model |

---

## Step 1: Flash the Thor with the Correct Bootc Image

The working bootc image comes from the sidecar team's `feature/thor-tegra264-kernel`
branch CI. This branch contains critical Thor-specific fixes that the base `jetpack7`
branch does not have.

### Why This Branch, Not jetpack7

The `jetpack7` base branch **kernel panics** on Thor during `tegra_camera_rtcpu` module
loading (NULL pointer deref in `camrtc_hsp_create`). The feature branch adds:

1. **Denylist for camera/HSP modules** — prevents `tegra_camera_rtcpu` and
   `hsp_mailbox_client` from loading and crashing
2. **nvgpu/nouveau denylist** — prevents the Orin-era GPU driver from racing OpenRM
3. **DEVFREQ governor fallback** — CentOS 10 lacks `CONFIG_DEVFREQ_GOV_PERFORMANCE`;
   without this patch, PCI probe panics
4. **NV_VERSION sync** — aligns kernel module version string (595.78) with userspace
5. **Display module setup** — enables `nv-load-display-modules.service`, masks
   `load-nvidia-drm.service` on Thor
6. **Platform-specific modprobe/dracut/depmod** — Thor-specific configs separate from Orin

### Critical Kernel Version Requirement

| Kernel | CUDA Runtime API Kernel Launches | Status |
|--------|----------------------------------|--------|
| 6.12.0-211 (RHEL 10.2) | **HANG** — torch.zeros blocks indefinitely | Broken |
| 6.12.0-253 (CentOS Stream 10) | Works — torch.zeros, torch.randn, matmul all pass | Working |

The RHEL 10.2 kernel (6.12.0-211) has a regression in how the NVIDIA OpenRM driver's
CUDA runtime API fatbin loading path interacts with the kernel. The CUDA driver API works
fine (cuCtxCreate, cuModuleLoadDataEx, cuLaunchKernel all succeed), but the CUDA runtime
API's `__cudaRegisterFatBinary` mechanism — used by every nvcc-compiled program and
PyTorch — hangs indefinitely. This is NOT a container issue; it reproduces on the bare
host.

**Use the CentOS Stream 10 image (kernel 6.12.0-253 or newer).**

### Getting the Image

Option A — pull from the team's GitLab Container Registry:

```bash
podman login registry.gitlab.com
podman pull registry.gitlab.com/redhat/rhel/sst/orin-sidecar/nvidia-jetson-sidecar/rhel-stream10:<commit-sha>-thor
```

Option B — build locally from the `feature/thor-tegra264-kernel` branch:

```bash
cd nvidia-jetson-sidecar
git checkout feature/thor-tegra264-kernel
make jetpack-bootc \
  JETPACK_PLATFORM=thor \
  JETPACK_BSP=nvidia-jetpack-bsp-openrm \
  BOOTC_IMAGE=quay.io/centos-bootc/centos-bootc:stream10 \
  IMAGE_TAG=stream10
```

### Installing the Image

From a USB-booted system or an existing OS on the Thor:

```bash
podman run --rm --privileged --pid=host \
  -v /dev:/dev -v /var/lib/containers:/var/lib/containers \
  <registry>/<image>:<tag> \
  bootc install to-disk /dev/nvme0n1
```

Or to switch an already-running bootc system:

```bash
cp /run/user/0/containers/auth.json /etc/ostree/auth.json  # if registry needs auth
bootc switch --transport registry <registry>/<image>:<tag>
systemctl reboot
```

---

## Step 2: Verify the GPU Stack After Boot

```bash
# Kernel version (must be 6.12.0-253 or newer)
uname -r

# NVIDIA driver loaded
nvidia-smi

# nvidia_uvm module loaded (required for CUDA compute)
lsmod | grep nvidia_uvm

# CDI spec generated (happens automatically via nvidia-ctk.service)
cat /etc/cdi/nvidia.yaml | head -20

# Device nodes present
ls -la /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm

# Quick CUDA sanity check
python3 -c "
import ctypes
cuda = ctypes.CDLL('libcuda.so.1')
r = cuda.cuInit(0)
print(f'cuInit: {r} (0=OK)')
"
```

### CDI Does Not Include libcuda.so.1

This is a known RHEL Tegra bug. The CDI spec generated by `nvidia-ctk` omits
`libcuda.so.1` because it expects Ubuntu-style library paths. Every `podman run` command
must include explicit bind mounts:

```
-v /usr/lib64/nvidia/libcuda.so.1:/usr/lib64/nvidia/libcuda.so.1:ro
-v /usr/lib64/nvidia/libcuda.so.1:/usr/lib/aarch64-linux-gnu/nvidia/libcuda.so.1:ro
```

---

## Step 3: Pull the vLLM Container Image

```bash
# The NVIDIA AI-IOT Jetson Thor container (vLLM 0.19.0, PyTorch 2.10.0 with SM_110)
podman pull ghcr.io/nvidia-ai-iot/vllm:latest-jetson-thor
```

This container includes:
- PyTorch compiled with native SM_110 cubins (no JIT compilation needed)
- vLLM 0.19.0 with Thor-specific MoE kernel configs
- CUDA 13.0 toolkit (forward-compatible with the host's 13.2 driver)

---

## Step 4: Run vLLM Inference

### Required Environment Variables and Flags

| Flag/Variable | Value | Why |
|---------------|-------|-----|
| `--device nvidia.com/gpu=all` | CDI GPU access | Standard podman GPU passthrough |
| `--security-opt label=disable` | Disable SELinux labels | Required for device access |
| `-v ...libcuda.so.1...` | Bind mount host libcuda | CDI bug workaround |
| `LD_LIBRARY_PATH` | `/usr/lib64/nvidia:/usr/lib64:/usr/local/cuda/lib64` | Host driver libs first |
| `NVIDIA_DRIVER_CAPABILITIES` | `compute,utility` | Avoid Tegra graphics bug |
| `TRITON_PTXAS_PATH` | `/usr/local/cuda/bin/ptxas` | Triton's bundled ptxas doesn't know SM_110a |
| `VLLM_ENABLE_V1_MULTIPROCESSING` | `0` | **Critical** — v1 EngineCore subprocess can't see GPU through CDI |
| `CUDA_VISIBLE_DEVICES` | `0` | Explicit device selection |
| Pre-init CUDA | `torch.zeros(1, device="cuda")` before LLM() | **Critical** — vLLM's init breaks CUDA if not pre-initialized |

### One-Shot Inference Test

```bash
podman run --rm --security-opt label=disable --device nvidia.com/gpu=all \
  --network host --shm-size=16g \
  -v /usr/lib64/nvidia/libcuda.so.1:/usr/lib64/nvidia/libcuda.so.1:ro \
  -v /usr/lib64/nvidia/libcuda.so.1:/usr/lib/aarch64-linux-gnu/nvidia/libcuda.so.1:ro \
  -e LD_LIBRARY_PATH=/usr/lib64/nvidia:/usr/lib64:/usr/local/cuda/lib64 \
  -e NVIDIA_DRIVER_CAPABILITIES=compute,utility \
  -e TRITON_PTXAS_PATH=/usr/local/cuda/bin/ptxas \
  -e VLLM_ENABLE_V1_MULTIPROCESSING=0 \
  -e CUDA_VISIBLE_DEVICES=0 \
  -e HF_TOKEN=$HF_TOKEN \
  ghcr.io/nvidia-ai-iot/vllm:latest-jetson-thor \
  python3 -u -c "
import torch
torch.zeros(1, device='cuda')  # MUST pre-init CUDA

from vllm import LLM, SamplingParams
llm = LLM(
    model='ibm-granite/granite-3.2-2b-instruct',
    max_model_len=2048,
    enforce_eager=True,
    gpu_memory_utilization=0.5,
)
out = llm.generate(
    ['What is Red Hat Enterprise Linux?'],
    SamplingParams(temperature=0.7, max_tokens=100),
)
print(out[0].outputs[0].text)
"
```

Model loading takes approximately 50-55 seconds. First inference takes ~16 seconds
(includes Triton kernel compilation). Subsequent inferences are faster (~6 tok/s output).

### OpenAI-Compatible API Server

For a persistent server accessible from other machines:

```bash
podman run -d --name vllm-server \
  --security-opt label=disable --device nvidia.com/gpu=all \
  --network host --shm-size=16g \
  -v /usr/lib64/nvidia/libcuda.so.1:/usr/lib64/nvidia/libcuda.so.1:ro \
  -v /usr/lib64/nvidia/libcuda.so.1:/usr/lib/aarch64-linux-gnu/nvidia/libcuda.so.1:ro \
  -e LD_LIBRARY_PATH=/usr/lib64/nvidia:/usr/lib64:/usr/local/cuda/lib64 \
  -e NVIDIA_DRIVER_CAPABILITIES=compute,utility \
  -e TRITON_PTXAS_PATH=/usr/local/cuda/bin/ptxas \
  -e VLLM_ENABLE_V1_MULTIPROCESSING=0 \
  -e CUDA_VISIBLE_DEVICES=0 \
  -e HF_TOKEN=$HF_TOKEN \
  ghcr.io/nvidia-ai-iot/vllm:latest-jetson-thor \
  python3 -u -c "
import torch, uvicorn
from fastapi import FastAPI
from pydantic import BaseModel
from typing import List

torch.zeros(1, device='cuda')

from vllm import LLM, SamplingParams

llm = LLM(
    model='ibm-granite/granite-3.2-2b-instruct',
    max_model_len=2048,
    enforce_eager=True,
    gpu_memory_utilization=0.5,
)

app = FastAPI()

class Message(BaseModel):
    role: str
    content: str

class ChatRequest(BaseModel):
    model: str = 'granite-3.2-2b-instruct'
    messages: List[Message]
    max_tokens: int = 256
    temperature: float = 0.7

@app.get('/health')
def health():
    return {'status': 'ok'}

@app.get('/v1/models')
def models():
    return {'data': [{'id': 'granite-3.2-2b-instruct', 'object': 'model'}]}

@app.post('/v1/chat/completions')
def chat(req: ChatRequest):
    prompt = '\n'.join([f'{m.role}: {m.content}' for m in req.messages]) + '\nassistant:'
    out = llm.generate([prompt], SamplingParams(temperature=req.temperature, max_tokens=req.max_tokens))
    return {
        'id': 'chatcmpl-thor',
        'object': 'chat.completion',
        'model': req.model,
        'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': out[0].outputs[0].text}, 'finish_reason': 'stop'}],
    }

print('Starting server on 0.0.0.0:8000...', flush=True)
uvicorn.run(app, host='0.0.0.0', port=8000)
"
```

Wait ~2 minutes for model loading, then test:

```bash
# From any machine on the network:
curl http://<thor-ip>:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite-3.2-2b-instruct",
    "messages": [{"role": "user", "content": "Hello, what can you do?"}],
    "max_tokens": 100
  }'
```

---

## Step 5: Cosmos3-Edge via vllm-omni (Omni-Modal World Model)

Cosmos3-Edge is NVIDIA's 4B parameter omni-modal world foundation model. It can reason
about physical scenes (text + images), generate prediction videos, predict action
trajectories, and serve as a robot policy — all from a single model on a single edge
device.

NVIDIA benchmarked Cosmos3-Edge on Jetson AGX Thor T5000 at 137.5s for image-to-video
generation (480p, 189 frames) and ~42 tok/s for text reasoning.

### Container

The `vllm/vllm-omni:cosmos3` container ships with arm64 support, vLLM 0.25.0, and
vllm-omni 0.25.0rc2 pre-installed.

```bash
podman pull docker.io/vllm/vllm-omni:cosmos3
```

### Serving Cosmos3-Edge

```bash
# Reset GPU first (see reset-gpu.sh)
source /etc/environment

podman run --rm --security-opt label=disable --device nvidia.com/gpu=all \
  --network host --shm-size=16g \
  -v /usr/lib64/nvidia/libcuda.so.1:/usr/lib64/nvidia/libcuda.so.1:ro \
  -v /usr/lib64/nvidia/libcuda.so.1:/usr/lib/aarch64-linux-gnu/nvidia/libcuda.so.1:ro \
  -v /root/.cache/huggingface:/root/.cache/huggingface \
  -e LD_LIBRARY_PATH=/usr/lib64/nvidia:/usr/lib64:/usr/local/cuda/lib64 \
  -e NVIDIA_DRIVER_CAPABILITIES=compute,utility \
  -e VLLM_ENABLE_V1_MULTIPROCESSING=0 \
  -e CUDA_VISIBLE_DEVICES=0 \
  -e HF_TOKEN=$HF_TOKEN \
  -e HF_HUB_DISABLE_XET=1 \
  --entrypoint "" \
  docker.io/vllm/vllm-omni:cosmos3 \
  bash -c "
pip install --upgrade transformers -q 2>&1 | tail -1
python3 -c \"import torch; torch.zeros(1, device=\\\"cuda\\\"); print(\\\"CUDA OK\\\")\"
vllm serve nvidia/Cosmos3-Edge --omni --host 0.0.0.0 --port 8000 \
  --enforce-eager --gpu-memory-utilization 0.5 --max-model-len 4096 \
  --init-timeout 1800 --trust-remote-code
"
```

First launch downloads the model (~8 GB). Subsequent launches use the HuggingFace cache
at `/root/.cache/huggingface`. Total startup time is approximately 3-4 minutes.

### Additional Environment Variables for Cosmos3

| Variable | Value | Why |
|----------|-------|-----|
| `HF_HUB_DISABLE_XET=1` | Disable xet download protocol | Avoids "hex hash" parse errors in huggingface_hub |
| `HF_TOKEN` | Your HuggingFace token | Required for gated Cosmos-1.0-Guardrail dependency |

### API Endpoints

Once running, Cosmos3-Edge exposes these endpoints on port 8000:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/health` | GET | Health check |
| `/v1/chat/completions` | POST | Text/visual reasoning (OpenAI-compatible) |
| `/v1/videos/sync` | POST | Synchronous video generation |
| `/v1/videos` | POST/GET | Async video generation with polling |
| `/v1/images/generations` | POST | Image generation |
| `/v1/audio/speech` | POST | Text-to-speech |
| `/v1/realtime/robot/openpi` | WebSocket | Robot policy (OpenPI) |
| `/v1/realtime` | WebSocket | Full-duplex realtime |

### Testing the Reasoner

```bash
curl http://<thor-ip>:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "nvidia/Cosmos3-Edge",
    "messages": [{"role": "user", "content": "What would happen if a robot pushed a glass off a table?"}],
    "max_tokens": 100
  }'
```

Cosmos3-Edge responds with multimodal output — it generates visual chain-of-thought
reasoning with embedded images alongside text. The `content` field in the response may be
a list of `{"type": "text", ...}` and `{"type": "image_url", ...}` items rather than a
plain string.

### Testing Video Generation

```bash
curl http://<thor-ip>:8000/v1/videos/sync \
  -F "prompt=A robot arm picks up a red cube from a table" \
  -F "model=nvidia/Cosmos3-Edge" \
  -F "num_frames=49" \
  -F "width=480" \
  -F "height=272" \
  --output predicted.mp4
```

### vllm-omni on NGC Container (Alternative)

If you only need vllm-omni with a text model (not Cosmos3-Edge), you can layer it on the
NGC 26.07 container which has vLLM 0.24.0 and runs ~4x faster than the Jetson container:

```bash
podman run --rm --security-opt label=disable --device nvidia.com/gpu=all \
  --network host --shm-size=16g \
  -v /usr/lib64/nvidia/libcuda.so.1:/usr/lib64/nvidia/libcuda.so.1:ro \
  -v /usr/lib64/nvidia/libcuda.so.1:/usr/lib/aarch64-linux-gnu/nvidia/libcuda.so.1:ro \
  -e LD_LIBRARY_PATH=/usr/lib64/nvidia:/usr/lib64:/usr/local/cuda/lib64 \
  -e NVIDIA_DRIVER_CAPABILITIES=compute,utility \
  -e VLLM_ENABLE_V1_MULTIPROCESSING=0 \
  -e CUDA_VISIBLE_DEVICES=0 \
  -e HF_TOKEN=$HF_TOKEN \
  --entrypoint "" \
  nvcr.io/nvidia/vllm:26.07-py3 \
  bash -c "
pip install vllm-omni==0.24.0 aenum omegaconf -q
python3 -u -c \"
import torch; torch.zeros(1, device='cuda')
import vllm_omni
from vllm import LLM, SamplingParams
llm = LLM(model='ibm-granite/granite-3.2-2b-instruct', max_model_len=2048, enforce_eager=True, gpu_memory_utilization=0.5)
out = llm.generate(['Hello'], SamplingParams(max_tokens=50))
print(out[0].outputs[0].text)
\"
"
```

vllm-omni versions must match the base vLLM version exactly (e.g., vllm-omni 0.24.0 on
vLLM 0.24.0). Mismatched versions fail on import due to tightly coupled internal APIs.

---

## Step 6: Persistent Credentials

Store tokens in `/etc/environment` on the Thor (survives reboots, writable on bootc):

```bash
cat >> /etc/environment << EOF
HF_TOKEN=hf_your_token
NGC_API_KEY=your_ngc_key
GITLAB_RO_TOKEN=glpat_your_token
EOF
```

These are picked up by SSH sessions and passed to containers via `-e HF_TOKEN=$HF_TOKEN`.

---

## Troubleshooting

### GPU Goes to CUDA_ERROR_NO_DEVICE (Error 100)

The GPU can enter a failed state (GCx failure loop in dmesg) after vLLM crashes or
container cleanup issues. A warm `systemctl reboot` does NOT always fix this on Jetson
because some GPU state survives in the SoC.

**Fix: Reload the NVIDIA kernel modules:**

```bash
modprobe -r nvidia_uvm
modprobe -r nvidia_drm
modprobe -r nvidia_modeset
modprobe -r nvidia
modprobe nvidia
modprobe nvidia_uvm
sleep 2

# Verify
python3 -c "import ctypes; cuda=ctypes.CDLL('libcuda.so.1'); print(cuda.cuInit(0))"
# Should print 0

# Regenerate CDI
nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
```

If module reload doesn't work, do a full power cycle (not just reboot — physically
disconnect power or use BMC/IPMI).

### torch.zeros Hangs Indefinitely

You are on the wrong kernel. Check `uname -r`:
- `6.12.0-211` = broken RHEL 10.2 kernel. Switch to CentOS Stream 10 image.
- `6.12.0-253` or newer = should work.

### vLLM EngineCore: "No CUDA GPUs are available"

This happens when vLLM's v1 engine spawns a child process that can't see the GPU. Two
causes:

1. **GPU is dead** — check `python3 -c "import ctypes; cuda=ctypes.CDLL('libcuda.so.1');
   print(cuda.cuInit(0))"`. If it returns 100, reload modules (see above).
2. **V1 multiprocessing** — set `VLLM_ENABLE_V1_MULTIPROCESSING=0` to run the engine
   in-process.

### vLLM Worker init_device Fails Even Without Multiprocessing

Pre-initialize CUDA before importing vLLM:

```python
import torch
torch.zeros(1, device="cuda")  # This line is required

from vllm import LLM  # Now this works
```

Without pre-initialization, vLLM's model config creation calls CUDA in a way that fails
on Thor's driver.

### nvidia-smi Shows ERR! / N/A for GPU Fields

The GPU is in a failed state. Reload modules (see above).

### CDI Missing libcuda.so.1

Known RHEL Tegra bug. Always add the bind mounts:

```
-v /usr/lib64/nvidia/libcuda.so.1:/usr/lib64/nvidia/libcuda.so.1:ro
-v /usr/lib64/nvidia/libcuda.so.1:/usr/lib/aarch64-linux-gnu/nvidia/libcuda.so.1:ro
```

### Display Modules Causing 97% GPU Utilization

If `nvidia_drm` and `nvidia_modeset` are loaded and consuming GPU, they should be masked.
The `feature/thor-tegra264-kernel` image handles this, but if you see it:

```bash
systemctl mask load-nvidia-drm.service
# Reboot
```

---

## What the Team CI Tests vs. What Actually Matters

The sidecar team's CI (`scripts/testing/jumpstarter-scripts/jetson-bootc-kmods.py`) runs
these CUDA tests:

| Test | What It Uses | Catches Kernel Bug? |
|------|-------------|-------------------|
| deviceQuery | CUDA driver API queries (cuInit, cuDeviceGet) | No |
| bandwidthTest | cudaMemcpy (driver-level DMA) | No |

Neither test launches a compiled CUDA kernel. The kernel 6.12.0-211 regression only
affects the CUDA runtime API's fatbin module loading path — the mechanism every
nvcc-compiled program and PyTorch uses. A simple `torch.zeros(1, device='cuda')` test
would catch it.

---

## Architecture Decisions and Context

### Why vLLM and vllm-omni (Not llama.cpp or TensorRT Edge-LLM)

vLLM is Red Hat's strategic choice — RHAIIS (Red Hat AI Inference Server) is built on
vLLM. vllm-omni extends vLLM with omni-modal capabilities (video, audio, action,
diffusion) required for physical AI use cases like Cosmos3-Edge. While llama.cpp and
TensorRT Edge-LLM both work on Thor and may offer better text performance, the
vLLM/vllm-omni stack is the only path that supports both RHAIIS alignment and
omni-modal world model serving.

### Why CentOS Stream 10 (Not RHEL 10.2)

RHEL 10.2 ships kernel 6.12.0-211 which has the CUDA kernel launch hang. CentOS Stream 10
has 6.12.0-253 which works. CentOS Stream 10 is the upstream of RHEL 10; the fix will
land in a future RHEL 10 update. The PoC runs on CentOS Stream 10 until then.

### Why Host Execution Doesn't Work Cleanly

The bootc image has a read-only `/usr` filesystem (by design). Running vLLM directly on
the host requires extracting CUDA headers, Python headers, and libs from the container
into `/var`. While possible, the container path is cleaner and matches the Red Hat Device
Edge architecture (native kernel modules + containerized compute).

### Why VLLM_ENABLE_V1_MULTIPROCESSING=0

vLLM 0.19.0's v1 engine forks an EngineCore subprocess. On Jetson Thor with CDI/Podman,
the spawned child process cannot initialize CUDA (torch says "No CUDA GPUs are
available"), even though a standalone spawned child CAN access the GPU. The issue appears
to be in how vLLM's parent process initializes CUDA before spawning, which poisons the
child's CUDA state. Disabling v1 multiprocessing runs everything in-process, avoiding
the problem.

### Which Container to Use

| Use Case | Container | vLLM | Notes |
|----------|-----------|------|-------|
| Text LLM (SM_110 native) | `ghcr.io/nvidia-ai-iot/vllm:latest-jetson-thor` | 0.19.0 | SM_110 cubins, CUDA 13.0, slower |
| Text LLM (faster) | `nvcr.io/nvidia/vllm:26.07-py3` | 0.24.0 | CUDA 13.3 forward compat, ~4x faster |
| vllm-omni + text model | NGC 26.07 + `pip install vllm-omni==0.24.0` | 0.24.0 | Omni patches, text models only |
| Cosmos3-Edge (full omni) | `docker.io/vllm/vllm-omni:cosmos3` | 0.25.0 | Video, audio, action, reasoning |

vllm-omni versions are tightly coupled to vLLM versions — 0.24.0 on 0.24.0, 0.25.0 on
0.25.0. Cross-version installs fail on import due to internal API changes.

### Why Pre-Initializing CUDA Is Required

vLLM's `create_engine_config()` calls functions that interact with CUDA in a sequence
that fails on Thor's OpenRM driver (595.78). When CUDA is pre-initialized with
`torch.zeros(1, device="cuda")` before vLLM imports, the CUDA runtime is already in a
working state and vLLM's subsequent calls succeed. The exact mechanism is unclear but
reproducible.

---

## Performance (Observed)

### Granite 3.2 2B (Text LLM)

| Metric | Jetson Container (0.19.0) | NGC 26.07 (0.24.0) |
|--------|--------------------------|---------------------|
| Model loading | ~53s | ~47s |
| Output speed | ~6.25 tok/s | ~23.7 tok/s |
| GPU memory used | 4.74 GiB | 4.74 GiB |
| Max concurrency (2048 ctx) | ~346x | ~791x |

### Cosmos3-Edge 4B (Omni World Model)

| Metric | Value |
|--------|-------|
| Model loading | ~47s |
| Video generation (49 frames, 480x272) | ~15.8s |
| Reasoner (text output) | ~42 tok/s (NVIDIA benchmark) |
| GPU memory used | ~4.74 GiB |
| Total GPU memory available | ~125 GiB (unified) |

---

## Key Files and Paths on the Thor

| Path | Content |
|------|---------|
| `/etc/cdi/nvidia.yaml` | CDI device spec (auto-generated at boot) |
| `/etc/modprobe.d/denylist-nvgpu.conf` | nvgpu/nouveau denylist for Thor |
| `/etc/modprobe.d/denylist-csi-orin.conf` | Orin CSI module denylist |
| `/etc/modprobe.d/nvidia-camera-blacklist.conf` | Camera RTC/HSP denylist |
| `/etc/dracut.conf.d/omit-nvgpu.conf` | Keep nvgpu out of initramfs |
| `/usr/lib64/nvidia/` | Host NVIDIA driver libraries |
| `/dev/nvidia0`, `/dev/nvidia1`, `/dev/nvidiactl` | GPU device nodes |
| `/dev/nvidia-uvm`, `/dev/nvidia-uvm-tools` | UVM device nodes |

---

## Reporting Issues

When filing bugs with the sidecar team, include:

1. `uname -r` (kernel version)
2. `modinfo nvidia | grep version` (driver version)
3. `nvidia-smi` output
4. `dmesg | grep -i nvrm` (driver errors)
5. The exact `podman run` command
6. Whether `torch.zeros(1, device="cuda")` works standalone
7. Whether `cuInit(0)` returns 0 via ctypes

The most common failure mode is a dead GPU (cuInit returns 100) that requires module
reload, not a software bug.
