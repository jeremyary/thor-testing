#!/bin/bash
# This project was developed with assistance from AI tools.
# Serve Cosmos3-Edge via vllm-omni on Jetson AGX Thor
# Uses the cosmos3 container (vLLM 0.25.0, vllm-omni 0.25.0rc2)
set -euo pipefail

source /etc/environment 2>/dev/null || true

echo "=== Resetting GPU ==="
modprobe -r nvidia_uvm 2>/dev/null || true
modprobe -r nvidia_drm 2>/dev/null || true
modprobe -r nvidia_modeset 2>/dev/null || true
modprobe -r nvidia 2>/dev/null || true
modprobe nvidia
modprobe nvidia_uvm
sleep 2
nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml 2>/dev/null

echo "=== Starting Cosmos3-Edge on port 8000 ==="
podman kill -a 2>/dev/null || true

exec podman run --rm --security-opt label=disable --device nvidia.com/gpu=all \
  --network host --shm-size=16g \
  -v /usr/lib64/nvidia/libcuda.so.1:/usr/lib64/nvidia/libcuda.so.1:ro \
  -v /usr/lib64/nvidia/libcuda.so.1:/usr/lib/aarch64-linux-gnu/nvidia/libcuda.so.1:ro \
  -v /root/.cache/huggingface:/root/.cache/huggingface \
  -e LD_LIBRARY_PATH=/usr/lib64/nvidia:/usr/lib64:/usr/local/cuda/lib64 \
  -e NVIDIA_DRIVER_CAPABILITIES=compute,utility \
  -e VLLM_ENABLE_V1_MULTIPROCESSING=0 \
  -e CUDA_VISIBLE_DEVICES=0 \
  -e HF_TOKEN="${HF_TOKEN}" \
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
