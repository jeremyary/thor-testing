#!/bin/bash
# This project was developed with assistance from AI tools.
# Reset the GPU on Jetson AGX Thor
# Use when cuInit returns 100 (CUDA_ERROR_NO_DEVICE) or nvidia-smi shows ERR!
set -euo pipefail

echo "Killing containers..."
podman kill -a 2>/dev/null || true
sleep 1

echo "Unloading nvidia modules..."
modprobe -r nvidia_uvm 2>/dev/null || true
modprobe -r nvidia_drm 2>/dev/null || true
modprobe -r nvidia_modeset 2>/dev/null || true
modprobe -r nvidia 2>/dev/null || true

echo "Reloading nvidia modules..."
modprobe nvidia
modprobe nvidia_uvm
sleep 2

echo "Regenerating CDI..."
nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml 2>/dev/null

echo "Testing..."
python3 -c "
import ctypes
cuda = ctypes.CDLL('libcuda.so.1')
r = cuda.cuInit(0)
if r == 0:
    print('GPU: OK')
else:
    print(f'GPU: FAILED (error {r}) — try full power cycle')
"
