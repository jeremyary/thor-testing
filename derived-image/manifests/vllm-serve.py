# This project was developed with assistance from AI tools.
import os
os.environ["LD_PRELOAD"] = "/usr/lib64/nvidia/libcuda.so.1"

import torch
torch.zeros(1, device="cuda")

import uvicorn
from fastapi import FastAPI
from pydantic import BaseModel
from vllm import LLM, SamplingParams

llm = LLM(
    model="ibm-granite/granite-3.2-2b-instruct",
    max_model_len=2048,
    enforce_eager=True,
    gpu_memory_utilization=0.5,
)

app = FastAPI()


class Msg(BaseModel):
    role: str
    content: str


class Req(BaseModel):
    model: str = "granite"
    messages: list[Msg]
    max_tokens: int = 256
    temperature: float = 0.7


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/v1/models")
def models():
    return {"data": [{"id": "granite-3.2-2b-instruct", "object": "model"}]}


@app.post("/v1/chat/completions")
def chat(req: Req):
    prompt = "\n".join([f"{m.role}: {m.content}" for m in req.messages])
    prompt += "\nassistant:"
    out = llm.generate([prompt], SamplingParams(temperature=req.temperature, max_tokens=req.max_tokens))
    return {
        "choices": [
            {
                "message": {
                    "role": "assistant",
                    "content": out[0].outputs[0].text,
                }
            }
        ]
    }


if __name__ == "__main__":
    print("Starting vLLM server on 0.0.0.0:8000...", flush=True)
    uvicorn.run(app, host="0.0.0.0", port=8000)
