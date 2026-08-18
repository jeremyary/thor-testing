# vast.ai — proper Cosmos3-Edge Vision SFT (the "real improvement" asset)

This runs NVIDIA's **prescribed** Vision SFT recipe at NVIDIA's **documented scale**
(8×H100, `max_iter=500` — the exact number NVIDIA's own before/after demo uses) to
produce a genuinely fine-tuned Cosmos3-Edge whose I2V "dream" is *visibly* different
from the base model.

It replicates the identical recipe our Thor KFP pipeline runs — same pinned
cosmos-framework SHA, same `uv sync`, same `launch_sft_vision_edge.sh`, same
export→Edge-diffusers-convert (with all our Edge fixes). The only differences are
(a) 8 GPUs instead of 1, (b) 500 iterations instead of a smoke count, and (c) two
quality fixes to the shipped recipe (see below).

## Why this exists

Thor (single L40S) proves the *flywheel mechanism* works — real training, real weight
deltas, real signed modelcar. But at a demo-sized step count on one GPU the weight
change is too small to visibly alter the 256px bf16 video output (byte-identical mp4;
this is a known bf16-rounding property of NVIDIA's shipped AdamW+bf16 recipe, not a
bug — confirmed against cosmos-framework source). Running the prescribed 500 iters at
proper scale accumulates enough change to be *visible*. We bring that result back as
the pre-baked v2 the demo modal can show instantly.

Both are legitimate fine-tunes of the same model through the same pipeline — this box
just has the compute to reach a visible delta.

## Instance recommendation

8×H100 SXM 80GB, bare-metal (not QEMU), high download bandwidth, high reliability.
Between two seen options, the Japan bare-metal box (~$28/hr, 3881 Mbps down, 99.85%,
X13DEG-OAD) beat the cheaper Taiwan QEMU box (~$19/hr, 635 Mbps, 98.2%): faster ~13GB
download and clean NVLink for 8-GPU FSDP matter more than the hourly delta on a
sub-hour job. NVIDIA documents Edge as tested on 8×H100 and 4×GB200.

## Run it

```bash
# on the rented box:
export HF_TOKEN=<jeremyary token with gated nvidia/Cosmos-1.0-Guardrail access>
bash run_vision_sft_500.sh
# ~15-40 min training (estimate) + ~10 min setup/download + export/convert
```

Result: `/workspace/diffusers_out` (Diffusers pipeline dir) + training log with the
loss curve. During-training generation samples land under the run's output dir
(quality fix 2 enables them every 100 iters).

## Two quality fixes vs the shipped recipe (both applied by the script)

1. **`cycle_lengths = [max_iter]`** — the shipped toml has `cycle_lengths=[1000]` but
   `max_iter=500`, so the cosine LR schedule stops at ~54% of peak (never decays to
   `f_min`). Matching the cycle to the run length lets the LR fully anneal — proper
   convergence behavior.
2. **viz-sample callback `every_n = max_iter/5`** — the shipped default is 5000, which
   never fires in a 500-iter run, so you get no during-training samples. We enable it
   so you can eyeball generation quality at iter 100/200/…/500 (NVIDIA's before/after
   style), and use the 51-clip val split as a manual quality curve.

Everything else (lr=1e-4, betas, warmup=50, grad_accum=2, bf16, EMA, keys_to_select =
moe_gen/time_embedder/vae2llm/llm2vae/k_norm_und_for_gen) is NVIDIA's shipped config,
unchanged.

## Bring the result back into the demo

```bash
# on the box:
tar czf diffusers_out.tgz -C /workspace diffusers_out
# copy off the box (scp/rsync/vast copy), then on the hub cluster:
#   - stage diffusers_out into the modelcar package step (same as pipeline Step 6b
#     output) and package/sign as the v2 modelcar, OR
#   - drop it into the demo's pre-baked-asset location the modal reads from.
```

Then generate the v1-vs-v2 I2V pair on the same BridgeData2 frame/prompt/seed with the
Edge-correct params (`guidance_scale=5.0`, `flow_shift=3.0`, 256×256) and confirm they
are now visibly different.

## Provenance / legitimacy notes

- Same cosmos-framework SHA (`b28c027…`), same recipe, same dataset
  (`nvidia/BridgeData2-Subset-Synthetic-Captions`, 1222 clips — exactly what NVIDIA
  ships and demos with) as the on-Thor pipeline.
- `max_iter=500` is NVIDIA's own demonstrated number (`docs/dataset_jsonl.md` shows
  "after 500 iterations of SFT").
- The Edge diffusers conversion uses the same fixes documented in `DECISIONS.md` D033
  (Edge-detection alias, transformers/hub version stub, list_repo_templates) — these
  correct upstream string-match/version-guard bugs, never weight logic.
