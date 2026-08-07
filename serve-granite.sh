#!/bin/bash
# This project was developed with assistance from AI tools.
# Serve Granite 3.2 2B via vLLM on Jetson AGX Thor
# Uses the Jetson Thor container (vLLM 0.19.0, CUDA 13.0)
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

echo "=== Starting Granite 3.2 2B on port 8000 ==="
podman kill -a 2>/dev/null || true

exec podman run --rm --security-opt label=disable --device nvidia.com/gpu=all \
  --network host --shm-size=16g \
  -v /usr/lib64/nvidia/libcuda.so.1:/usr/lib64/nvidia/libcuda.so.1:ro \
  -v /usr/lib64/nvidia/libcuda.so.1:/usr/lib/aarch64-linux-gnu/nvidia/libcuda.so.1:ro \
  -e LD_LIBRARY_PATH=/usr/lib64/nvidia:/usr/lib64:/usr/local/cuda/lib64 \
  -e NVIDIA_DRIVER_CAPABILITIES=compute,utility \
  -e TRITON_PTXAS_PATH=/usr/local/cuda/bin/ptxas \
  -e VLLM_ENABLE_V1_MULTIPROCESSING=0 \
  -e CUDA_VISIBLE_DEVICES=0 \
  -e HF_TOKEN="${HF_TOKEN}" \
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

print('Starting Granite 3.2 2B server on 0.0.0.0:8000...', flush=True)
uvicorn.run(app, host='0.0.0.0', port=8000)
"
