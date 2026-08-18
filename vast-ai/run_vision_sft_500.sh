#!/usr/bin/env bash
# =============================================================================
# Cosmos3-Edge Vision SFT — proper 500-iteration fine-tune on rented 8xH100
# (vast.ai). Replicates the exact recipe our Thor pipeline runs, at NVIDIA's
# documented scale/hardware (docs/training.md: "Tested on 8x H100 (80GB)",
# max_iter=500 is NVIDIA's own demonstrated before/after number).
#
# Produces a genuinely fine-tuned Cosmos3-Edge in Diffusers format that we
# package as the v2 modelcar for the demo's visible v1-vs-v2 comparison.
#
# USAGE (on the vast.ai box, as root or a sudo user):
#   export HF_TOKEN=<jeremyary token with gated nvidia/Cosmos3-Edge access>
#   bash run_vision_sft_500.sh
#
# Only ONE credential is needed on the box: HF_TOKEN, for the gated
# nvidia/Cosmos3-Edge repo (base weights + reasoner snapshot the converter
# pulls). The guardrail repos and cluster registry are NOT touched here --
# packaging/signing the modelcar happens back on the hub cluster.
#
# Prereqs on the instance:
#   - 8x H100 80GB (or 4x; set NPROC below), CUDA >= 13.0, NVLink
#   - A PyTorch/CUDA base (vast.ai "pytorch" template is fine); git, curl, python3
#   - ~60GB free disk for venv + model + DCP + outputs
#
# Output: /workspace/diffusers_out  (the converted Diffusers pipeline dir)
#         plus /workspace/vision_sft_edge_sft.log (training log w/ loss curve)
# Pull /workspace/diffusers_out back to the cluster to package as the modelcar.
# =============================================================================
set -euo pipefail

# ---- config -----------------------------------------------------------------
CF_SHA="b28c027628db987d8eaa558faedc1d37d11125ae"   # pinned, matches Thor pipeline
MAX_ITER="${MAX_ITER:-500}"                          # NVIDIA's demonstrated number
NPROC="${NPROC:-8}"                                  # 8x H100
WORK="${WORK:-/workspace}"
DIFFUSERS_EDGE_REF="git+https://github.com/atharvajoshi10/diffusers.git@c3e62e55fec7df0d84f5aa46f98c8259e4f02897"

: "${HF_TOKEN:?export HF_TOKEN=<token with gated nvidia/Cosmos3-Edge access> first}"
export HF_TOKEN HF_HUB_DISABLE_XET=1
export HF_HOME="${WORK}/hf"
mkdir -p "$WORK" "$HF_HOME"
cd "$WORK"

echo ">>> [1/7] system deps + uv"
# ffprobe/ffmpeg: the cosmos-framework video dataloader shells out to them to
# read the BridgeData2 .mp4 clips; without ffprobe training dies in the
# DataLoader worker ("No such file or directory: 'ffprobe'").
command -v git ffprobe >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y git curl ffmpeg; }
command -v ffprobe >/dev/null || { apt-get update -qq && apt-get install -y ffmpeg; }
command -v uv   >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"

echo ">>> [2/7] clone cosmos-framework @ ${CF_SHA:0:12}"
if [[ ! -d cosmos-framework ]]; then
  git clone https://github.com/NVIDIA/cosmos-framework.git
fi
cd cosmos-framework
git checkout "$CF_SHA"
CF_DIR="$(pwd)"

echo ">>> [3/7] uv sync (cu130-train) — matches Thor pipeline"
uv sync --all-extras --group=cu130-train
VENV_PY="$CF_DIR/.venv/bin/python"
# HARDENING: --all-extras activates every CUDA group (cu128 AND cu130), so uv
# resolves torch to the newest (2.13.0), whose torchvision breaks with
# "operator torchvision::nms does not exist" and kills the transformers
# PreTrainedModel import at DCP-convert. Force the exact stack Thor validated
# (torch 2.10.0+cu130 / torchvision 0.25.0+cu130) from the pytorch cu130 index.
echo ">>> [3b/7] pin torch 2.10.0+cu130 stack (override --all-extras drift)"
uv pip install --python "$VENV_PY" \
  "torch==2.10.0+cu130" "torchvision==0.25.0+cu130" \
  --index-url https://download.pytorch.org/whl/cu130
"$VENV_PY" -c "from transformers import PreTrainedModel; import torchvision; print('[setup] torch/transformers import OK')"

echo ">>> [4/7] convert base Cosmos3-Edge HF -> DCP"
# IMPORTANT: use the venv python directly (NOT `uv run`). `uv run` re-syncs from
# uv.lock on every invocation, which re-pulls torch 2.13.0 and re-breaks
# torchvision -- undoing the [3b] pin. Direct venv python preserves the pinned
# stack. PYTHONPATH=. mirrors what the launcher/`uv run` set.
DCP_DIR="$CF_DIR/examples/checkpoints/Cosmos3-Edge"
if [[ ! -d "$DCP_DIR" ]]; then
  PYTHONPATH="$CF_DIR" "$VENV_PY" -m cosmos_framework.scripts.convert_model_to_dcp \
    -o "$DCP_DIR" --checkpoint-path "Cosmos3-Edge"
fi
WAN_VAE="$(find "$HF_HOME" -name 'Wan2.2_VAE.pth' | head -1)"
[[ -n "$WAN_VAE" ]] || { echo "ERROR: Wan2.2 VAE not found after DCP convert"; exit 1; }

echo ">>> [5/7] stage BridgeData2-Subset dataset"
DATA_ROOT="$CF_DIR/examples/data/BridgeData2-Subset-Synthetic-Captions"
SFT_DIR="$DATA_ROOT/sft_dataset_bridge"
if [[ ! -f "$SFT_DIR/train/video_dataset_file.jsonl" ]]; then
  "$VENV_PY" -c "
from huggingface_hub import snapshot_download
p = snapshot_download('nvidia/BridgeData2-Subset-Synthetic-Captions',
                      repo_type='dataset', local_dir='$DATA_ROOT')
print('dataset at', p)
"
fi
# Locate the sft_dataset_bridge dir wherever the snapshot placed it
if [[ ! -f "$SFT_DIR/train/video_dataset_file.jsonl" ]]; then
  FOUND="$(find "$DATA_ROOT" -name video_dataset_file.jsonl -path '*/train/*' | head -1)"
  [[ -n "$FOUND" ]] || { echo "ERROR: dataset jsonl not found"; exit 1; }
  SFT_DIR="$(dirname "$(dirname "$FOUND")")"
fi
echo "    dataset: $SFT_DIR"

echo ">>> [6/7] patch recipe for a proper ${MAX_ITER}-iter run"
TOML="$CF_DIR/examples/toml/sft_config/vision_sft_edge.toml"
python3 - "$TOML" "$MAX_ITER" <<'PYEOF'
import re, sys
toml, max_iter = sys.argv[1], int(sys.argv[2])
t = open(toml).read()
# memory knobs (match Thor pipeline; H100-80GB has headroom but keep parity)
t = t.replace("max_num_tokens_after_packing = 45056", "max_num_tokens_after_packing = 45056")
# run length
t = re.sub(r"max_iter\s*=\s*\d+",  f"max_iter                = {max_iter}", t)
t = re.sub(r"save_iter\s*=\s*\d+", f"save_iter            = {max(100, max_iter//5)}", t)
# QUALITY FIX 1: match the cosine cycle to the run length so the LR fully
# decays to f_min instead of stopping at ~54% of peak (shipped cycle_lengths
# =[1000] with max_iter=500 cuts the schedule off mid-decay).
t = re.sub(r"cycle_lengths\s*=\s*\[\s*\d+\s*\]", f"cycle_lengths      = [{max_iter}]", t)
# keep the shipped warmup of 50 (proper for a 500-iter run — clears in 10% of run)
open(toml, "w").write(t)
print(f"patched: max_iter={max_iter} cycle_lengths=[{max_iter}] save_iter={max(100,max_iter//5)}")
PYEOF

echo ">>> [7/7] launch Vision SFT on ${NPROC} GPUs (max_iter=${MAX_ITER})"
# QUALITY FIX 2: enable the visual-sample callback every save_iter so we get
# NVIDIA-style during-training generation samples (default every_n=5000 never
# fires in a 500-iter run). Passed as a Hydra tail override.
export DATASET_PATH="$SFT_DIR"
export BASE_CHECKPOINT_PATH="$DCP_DIR"
export WAN_VAE_PATH="$WAN_VAE"
export NPROC_PER_NODE="$NPROC"
export IMAGINAIRE_OUTPUT_ROOT="$WORK/outputs/train"
export TAIL_OVERRIDES=("trainer.callbacks.generation.every_n_sample_reg.every_n=$((MAX_ITER/5))")
# Put the venv bin first on PATH + activate it so the launcher's `torchrun`
# resolves to the venv's (pinned torch 2.10) instead of re-syncing via uv.
export VIRTUAL_ENV="$CF_DIR/.venv"
export PATH="$CF_DIR/.venv/bin:$PATH"

bash examples/launch_sft_vision_edge.sh

# ---- export + convert -------------------------------------------------------
RUN_SUBDIR="$WORK/outputs/train/cosmos3/sft/vision_sft_edge"
CKPT_ITER="$(cat "$RUN_SUBDIR/checkpoints/latest_checkpoint.txt")"
CKPT_PATH="$RUN_SUBDIR/checkpoints/$CKPT_ITER"
CONFIG_F="$RUN_SUBDIR/config.yaml"
echo ">>> exporting $CKPT_ITER -> safetensors"
PYTHONPATH="$CF_DIR" "$VENV_PY" -m cosmos_framework.scripts.export_model \
  --checkpoint-path "$CKPT_PATH" --config-file "$CONFIG_F" -o "$WORK/exported_model"

echo ">>> installing Edge-capable diffusers (PR #14272) for convert"
uv pip install --python "$VENV_PY" --no-deps \
  "huggingface-hub>=1.23,<2.0" "diffusers @ ${DIFFUSERS_EDGE_REF}"

echo ">>> convert safetensors -> Diffusers (Edge) with our detection+version fixes"
cat > "$WORK/convert_wrap.py" <<'PYW'
import types, sys, json, pathlib
# neutralize transformers hub version check (works stub, not empty)
_s = types.ModuleType("transformers.dependency_versions_check")
_s.dep_version_check = lambda *a, **k: None
sys.modules["transformers.dependency_versions_check"] = _s
# tolerate hub 1.x 404 on optional chat templates
import transformers.utils.hub as _tuh
from huggingface_hub.errors import EntryNotFoundError as _ENFE
_o = _tuh.list_repo_templates
def _safe(*a, **k):
    try: return _o(*a, **k)
    except _ENFE: return []
_tuh.list_repo_templates = _safe
import transformers.tokenization_utils_base as _tub
if hasattr(_tub, "list_repo_templates"): _tub.list_repo_templates = _safe
# fix upstream Edge-detection alias bug (nemotron3 vs nemotron_3)
import cosmos_framework.scripts._convert_model_to_diffusers as _cmd
_os = _cmd._is_edge_exported_checkpoint
def _fixed(cp):
    if _os(cp): return True
    p = pathlib.Path(cp) / "config.json"
    if not p.is_file(): return False
    mi = json.loads(p.read_text()).get("model",{}).get("config",{}).get("vlm_config",{}).get("model_instance",{})
    tgt = str(mi.get("_target_") or mi.get("_target") or "").lower()
    return "nemotron3_dense_vl" in tgt or "nemotron_3_dense_vl" in tgt
_cmd._is_edge_exported_checkpoint = _fixed
from cosmos_framework.scripts.convert_model_to_diffusers import main
main()
PYW
"$VENV_PY" "$WORK/convert_wrap.py" \
  --checkpoint-path "$WORK/exported_model" -o "$WORK/diffusers_out"

echo ""
echo "============================================================"
echo "DONE. Diffusers-format fine-tuned model at: $WORK/diffusers_out"
echo "Training log (loss curve): $RUN_SUBDIR/../logs/vision_sft_edge_sft.log"
echo ""
echo "Next: pull it back to the cluster, e.g.:"
echo "  tar czf diffusers_out.tgz -C $WORK diffusers_out"
echo "  # then scp/rsync diffusers_out.tgz off the box"
echo "============================================================"
