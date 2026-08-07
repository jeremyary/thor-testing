#!/bin/bash
set -e
pip install --upgrade transformers -q 2>&1 | tail -1

# CUDA pre-init inside the same Python process as vllm serve.
# Use vllm_omni's serve entry point which handles --omni flag.
exec python3 -u -c "
import torch
torch.zeros(1, device='cuda')
print('CUDA pre-init OK', flush=True)

import sys
sys.argv = [
    'vllm', 'serve', 'nvidia/Cosmos3-Edge', '--omni',
    '--host', '0.0.0.0', '--port', '8000',
    '--enforce-eager', '--gpu-memory-utilization', '0.5',
    '--max-model-len', '4096', '--init-timeout', '1800',
    '--trust-remote-code',
]

from vllm.scripts import main
main()
"
