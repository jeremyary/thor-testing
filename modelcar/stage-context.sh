#!/bin/bash
# This project was developed with assistance from AI tools.
#
# Stages a modelcar build context on Thor containing only the HF cache
# subtrees the vLLM-Omni/Cosmos3-Edge deployment actually loads at runtime:
# the model itself plus the guardrail/safety models it pulls in internally.
# Excludes ibm-granite/granite-3.2-2b-instruct (unrelated serve-granite.sh
# bare-podman deployment) and any other cache entries.
#
# Run on Thor as root (models live under /var/lib/models, root-owned):
#   sudo modelcar/stage-context.sh
#
# Produces modelcar/context/huggingface/hub/<the three model dirs>, ready for
# `podman build -f modelcar/Containerfile modelcar/context`.
set -euo pipefail

SRC="/var/lib/models/huggingface/hub"
DEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/context/huggingface/hub"

MODELS=(
  "models--nvidia--Cosmos3-Edge"
  "models--nvidia--Cosmos-1.0-Guardrail"
  "models--Qwen--Qwen3Guard-Gen-0.6B"
)

rm -rf "$(dirname "$(dirname "$DEST")")"
mkdir -p "$DEST"

for m in "${MODELS[@]}"; do
  if [ ! -d "$SRC/$m" ]; then
    echo "ERROR: expected model dir not found: $SRC/$m" >&2
    exit 1
  fi
  echo "Staging $m ..."
  cp -a "$SRC/$m" "$DEST/"
done

echo "Done. Context size:"
du -sh "$(dirname "$(dirname "$DEST")")"
