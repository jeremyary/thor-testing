#!/usr/bin/env python3
# This project was developed with assistance from AI tools.
#
# Deterministic Forward Dynamics ("dream") generator for the pinned demo pair.
#
# Runs ON THOR against the live cosmos3-edge vLLM-Omni endpoint. Holds every
# input fixed (seed, frame, action chunk, resolution) so the ONLY variable is
# the served model -- swap blue/green to change which checkpoint answers, then
# re-run. Output MP4 is written to /tmp; pin it into /var/lib/dreams to update
# the dashboard's Dream buttons (see README "Re-pinning" section).
#
# Usage (on Thor):
#   python3 gen_dream.py <tag> [flow_shift] [steps]
#     tag         output name -> /tmp/dream_<tag>.mp4  (e.g. base, v2)
#     flow_shift  denoising schedule over time; controls late-frame coherence.
#                 7.0 is the current pinned-v2 value (see README / DECISIONS).
#                 The original pair used 3.0. This is the lever that actually
#                 moves FD quality -- guidance_scale does not (FD is action-
#                 conditioned, not text-driven).
#     steps       num_inference_steps (default 20).
#
# Example -- regenerate the pinned v2 (with v2 checkpoint served):
#   python3 gen_dream.py v2 7.0 20
#
import json, time, pathlib, sys, urllib.request, urllib.error

# --- Fixed inputs (do not vary these for the pinned comparison) -------------
VLLM_URL = "http://10.43.75.23:8000"          # cosmos3-edge clusterIP:8000
SCENE    = "pick_place"
FRAME    = pathlib.Path(f"/var/lib/robot-sim/frames/{SCENE}.jpg")
POOL     = json.load(open("/var/lib/robot-sim/action_pool.json"))
SEED     = 42
SIZE     = "256x256"                            # MUST match the square frame (D034-C)

# --- Tunable knobs ----------------------------------------------------------
TAG        = sys.argv[1] if len(sys.argv) > 1 else "out"
FLOW_SHIFT = sys.argv[2] if len(sys.argv) > 2 else "7.0"
STEPS      = sys.argv[3] if len(sys.argv) > 3 else "20"
OUT        = pathlib.Path(f"/tmp/dream_{TAG}.mp4")

ep         = POOL[SCENE]
chunk      = ep["good"][:16]
domain     = ep.get("domain_name", "umi")
dims       = ep.get("dims", len(chunk[0]) if chunk else 10)
num_frames = len(chunk) + 1


def _resolve_model():
    with urllib.request.urlopen(f"{VLLM_URL}/v1/models", timeout=10) as r:
        return json.load(r)["data"][0]["id"]


model_name = _resolve_model()
print(f"[gen:{TAG}] served model = ...{model_name[-40:]}")

boundary = "----DreamBoundary" + str(int(time.time()))


def text_part(name, value):
    return (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="{name}"\r\n\r\n'
        f"{value}\r\n"
    ).encode()


extra_params = json.dumps({
    "action_mode": "forward_dynamics",
    "domain_name": domain,
    "raw_action_dim": dims,
    "action_chunk_size": len(chunk),
    "action": chunk,
    "guardrails": False,
    "use_resolution_template": False,
    "use_duration_template": False,
})

frame_bytes = FRAME.read_bytes()
file_part = (
    f"--{boundary}\r\n"
    f'Content-Disposition: form-data; name="input_reference"; '
    f'filename="frame.jpg"\r\n'
    f"Content-Type: image/jpeg\r\n\r\n"
).encode() + frame_bytes + b"\r\n"

parts = [
    text_part("model", model_name),
    text_part("prompt", "A robotic arm manipulating objects on a table"),
    text_part("size", SIZE),
    text_part("num_frames", str(num_frames)),
    text_part("fps", "5"),
    text_part("num_inference_steps", STEPS),
    text_part("guidance_scale", "1.0"),        # FD is action-conditioned; CFG has little effect
    text_part("flow_shift", FLOW_SHIFT),
    text_part("seed", str(SEED)),
    text_part("extra_params", extra_params),
    file_part,
    f"--{boundary}--\r\n".encode(),
]
body = b"".join(parts)

req = urllib.request.Request(
    f"{VLLM_URL}/v1/videos/sync", data=body,
    headers={"Content-Type": f"multipart/form-data; boundary={boundary}",
             "Accept": "video/mp4"})

print(f"[gen:{TAG}] seed={SEED} size={SIZE} frames={num_frames} "
      f"steps={STEPS} flow_shift={FLOW_SHIFT} guidance=1.0")
t0 = time.monotonic()
try:
    with urllib.request.urlopen(req, timeout=300) as resp:
        mp4 = resp.read()
    OUT.write_bytes(mp4)
    print(f"[gen:{TAG}] OK {len(mp4)//1024}KB in "
          f"{round(time.monotonic()-t0,1)}s -> {OUT}")
except urllib.error.HTTPError as e:
    print(f"[gen:{TAG}] HTTP {e.code}: {e.read().decode()[:600]}")
    raise
