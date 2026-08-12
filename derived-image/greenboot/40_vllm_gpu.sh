#!/bin/bash
# This project was developed with assistance from AI tools.
# Greenboot health check: GPU is accessible via CUDA driver API.
# Does NOT check vLLM (that's a workload, not an OS concern).
# Exits 0 (healthy) or 1 (unhealthy — triggers rollback).
#
# Retries rather than single-shot: nvidia-gpu-reset.service (the Thor GCx
# workaround — GPU needs a module reload after boot) may not have finished
# by the time greenboot runs this check. Without a retry loop, a slow but
# otherwise-healthy boot would look identical to a genuinely broken GPU and
# trigger an unwarranted rollback. Mirrors 40_microshift.sh's pattern.

set -uo pipefail

MAX_ATTEMPTS=18
WAIT_SECONDS=10

check_gpu() {
    python3 -c "
import ctypes
cuda = ctypes.CDLL('libcuda.so.1')
r = cuda.cuInit(0)
if r == 0:
    count = ctypes.c_int()
    cuda.cuDeviceGetCount(ctypes.byref(count))
    print(f'ok:{count.value}')
else:
    print(f'fail:{r}')
" 2>/dev/null || echo "fail:import"
}

for i in $(seq 1 $MAX_ATTEMPTS); do
    RESULT=$(check_gpu)
    if [[ "$RESULT" == ok:* ]]; then
        GPU_COUNT="${RESULT#ok:}"
        echo "greenboot: GPU check passed ($GPU_COUNT device(s), attempt $i/$MAX_ATTEMPTS)"
        exit 0
    fi
    echo "greenboot: GPU not ready yet ($RESULT, attempt $i/$MAX_ATTEMPTS), waiting ${WAIT_SECONDS}s..."
    sleep $WAIT_SECONDS
done

echo "greenboot: GPU check FAILED after $((MAX_ATTEMPTS * WAIT_SECONDS))s ($RESULT)"
exit 1
