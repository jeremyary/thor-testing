#!/usr/bin/env bash
# upload_pipeline.sh — upload a compiled KFP pipeline YAML to DSP and print the pipeline_id.
#
# Usage:
#   ./upload_pipeline.sh [pipeline.yaml] [display_name]
#
# After upload, set the pipeline_id in the manifest-consumer deployment so it
# actually triggers runs:
#   oc set env deployment/manifest-consumer -n vla-training \
#       TRAINING_PIPELINE_ID=<pipeline_id>
#
# Prerequisites: oc logged in, pipeline SA token creatable in vla-training.

set -euo pipefail

PIPELINE_FILE="${1:-cosmos3_finetune_pipeline.yaml}"
DISPLAY_NAME="${2:-cosmos3_finetune_pipeline.yaml}"
NAMESPACE="vla-training"
DSP_ROUTE=$(oc get route -n "$NAMESPACE" --no-headers 2>/dev/null \
    | grep "^ds-pipeline-dspa" | head -1 | awk '{print $2}')

if [[ -z "$DSP_ROUTE" ]]; then
    echo "ERROR: DSP route not found in namespace $NAMESPACE" >&2
    exit 1
fi

echo "→ DSP endpoint: https://${DSP_ROUTE}"
TOKEN=$(oc create token pipeline -n "$NAMESPACE" --duration=1h)

# Upload pipeline (multipart form-data with the YAML file)
RESPONSE=$(curl -sk \
    -H "Authorization: Bearer $TOKEN" \
    -F "uploadfile=@${PIPELINE_FILE};type=application/yaml" \
    "https://${DSP_ROUTE}/apis/v2beta1/pipelines/upload?name=${DISPLAY_NAME}")

PIPELINE_ID=$(echo "$RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
pid = d.get('pipeline_id', '')
print(pid)
" 2>/dev/null)

if [[ -z "$PIPELINE_ID" ]]; then
    echo "ERROR: upload failed. Response:" >&2
    echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE" >&2
    exit 1
fi

echo "✓ Pipeline uploaded: $PIPELINE_ID"
echo ""
echo "Next step — wire the manifest-consumer to this pipeline:"
echo "  oc set env deployment/manifest-consumer -n $NAMESPACE TRAINING_PIPELINE_ID=$PIPELINE_ID"
echo ""
echo "Next step — create required Secrets if not already present:"
echo "  # cosign key (from the existing thor-signing.key or Tekton secret):"
echo "  oc get secret cosign-signing-key -n thor-builds -o json \\"
echo "    | python3 -c \"import sys,json; s=json.load(sys.stdin); s['metadata']={'name':'cosign-signing-key','namespace':'$NAMESPACE'}; print(json.dumps(s))\" \\"
echo "    | oc apply -f -"
echo ""
echo "  # GitHub PAT with repo write access:"
echo "  oc create secret generic github-token --from-literal=token=<PAT> -n $NAMESPACE"
