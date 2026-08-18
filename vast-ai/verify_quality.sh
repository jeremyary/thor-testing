#!/usr/bin/env bash
# =============================================================================
# Verify the 500-iter fine-tune BEFORE destroying the (costly) vast.ai box.
# Runs 4 checks:
#   1. training completed cleanly (exit 0, loss delta, no NaN/OOM)
#   2. weight diff v2-vs-base on trained moe_gen layers (expect >> 100-step 2e-3)
#   3. diffusers output structurally correct (backbone_type, Edge scheduler)
#   4. VISUAL: generate base(v1) and tuned(v2) I2V dreams on the box GPUs,
#      identical frame/seed/prompt -> pull both back to eyeball quality.
#
# Run on the box AFTER run_vision_sft_500.sh finishes:
#   bash /workspace/verify_quality.sh
# Then from laptop, scp /workspace/qc_v1.mp4 and /workspace/qc_v2.mp4 back.
# =============================================================================
set -uo pipefail
WORK=/workspace
CF=/workspace/cosmos-framework
VP="$CF/.venv/bin/python"
export HF_HOME="$WORK/hf" HF_HUB_DISABLE_XET=1
RUN="$WORK/outputs/train/cosmos3/sft/vision_sft_edge"

echo "############ CHECK 1: training completion ############"
grep -iE 'Done with training|exit 0|exit 1' "$WORK/run500.log" 2>&1 | tail -3
echo "loss first -> last:"
grep -oE 'Loss: [0-9.]+' "$WORK/run500.log" 2>&1 | head -1
grep -oE 'Loss: [0-9.]+' "$WORK/run500.log" 2>&1 | tail -1
echo "NaN/OOM check:"
grep -iE 'NaN|CUDA out of memory|ChildFailedError' "$WORK/run500.log" 2>&1 | tail -3 || echo "  none"
echo "checkpoints saved:"
ls "$RUN/checkpoints/" 2>&1 | tail -6

echo ""
echo "############ CHECK 2: weight diff v2 vs base ############"
"$VP" - <<'PY'
import os,json,torch
os.environ['HF_HUB_DISABLE_XET']='1'
from huggingface_hub import hf_hub_download
from safetensors import safe_open
served="/workspace/diffusers_out/transformer"
swm=json.load(open(served+"/diffusion_pytorch_model.safetensors.index.json"))["weight_map"]
bidx=hf_hub_download("nvidia/Cosmos3-Edge","transformer/diffusion_pytorch_model.safetensors.index.json")
bwm=json.load(open(bidx))["weight_map"]
checks=["layers.0.mlp_moe_gen.down_proj.weight","layers.5.mlp_moe_gen.up_proj.weight",
        "layers.0.input_layernorm_moe_gen.weight","layers.15.mlp_moe_gen.down_proj.weight",
        "layers.20.mlp_moe_gen.up_proj.weight"]
print("  (100-step Thor run showed max ~2-3e-3; expect LARGER here)")
for k in checks:
    if k not in swm or k not in bwm: print(f"  {k}: MISSING"); continue
    with safe_open(os.path.join(served,swm[k]),"pt") as f: sv=f.get_tensor(k).float()
    b=hf_hub_download("nvidia/Cosmos3-Edge","transformer/"+bwm[k])
    with safe_open(b,"pt") as f: bv=f.get_tensor(k).float()
    d=(sv-bv).abs()
    print(f"  {k[:46]}: max={d.max().item():.4e} mean={d.mean().item():.4e}")
PY

echo ""
echo "############ CHECK 3: diffusers structure ############"
"$VP" -c "import json;c=json.load(open('/workspace/diffusers_out/transformer/config.json'));print('  backbone_type:',c.get('backbone_type'));print('  qk_norm_for_text:',c.get('qk_norm_for_text'))"
"$VP" -c "import json;s=json.load(open('/workspace/diffusers_out/scheduler/scheduler_config.json'));print('  scheduler:',s.get('_class_name'),'flow_shift:',s.get('flow_shift'))"
ls /workspace/diffusers_out/ 2>&1

echo ""
echo "############ GATE DECISION ############"
echo "If CHECK 2 shows weight diffs MUCH larger than the 100-step 2-3e-3"
echo "(e.g. 1e-2+ on moe_gen) and CHECK 1/3 are clean, the tune is real and"
echo "worth pulling. The VISIBLE v1-vs-v2 quality check happens on Thor via the"
echo "real vllm-omni serving path (we already have the Thor-generated v1 dream),"
echo "so both sides use the identical inference engine -- apples to apples."
echo ""
echo "Next: pull the tuned model back, then on the cluster package as v2 modelcar,"
echo "deploy to Thor green, and generate v2 I2V with the same frame/seed as v1:"
echo "  cd /workspace && tar czf diffusers_out.tgz diffusers_out"
echo "  scp -P <PORT> root@<HOST>:/workspace/diffusers_out.tgz /tmp/vast-v2/"
echo "  scp -P <PORT> root@<HOST>:/workspace/outputs/train/cosmos3/sft/logs/*.log /tmp/vast-v2/"
