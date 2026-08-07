#!/bin/bash
# This project was developed with assistance from AI tools.
# Greenboot health check: GPU is accessible via CUDA driver API.
# Does NOT check vLLM (that's a workload, not an OS concern).
# Exits 0 (healthy) or 1 (unhealthy — triggers rollback).

set -euo pipefail

RESULT=$(python3 -c "
import ctypes
cuda = ctypes.CDLL('libcuda.so.1')
r = cuda.cuInit(0)
if r == 0:
    count = ctypes.c_int()
    cuda.cuDeviceGetCount(ctypes.byref(count))
    print(f'ok:{count.value}')
else:
    print(f'fail:{r}')
" 2>/dev/null || echo "fail:import")

if [[ "$RESULT" == ok:* ]]; then
    GPU_COUNT="${RESULT#ok:}"
    echo "greenboot: GPU check passed ($GPU_COUNT device(s))"
    exit 0
else
    echo "greenboot: GPU check FAILED ($RESULT)"
    exit 1
fi
