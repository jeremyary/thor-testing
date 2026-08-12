#!/bin/bash
# This project was developed with assistance from AI tools.
# Greenboot health check: MicroShift is running and API server responds.
# Exits 0 (healthy) or 1 (unhealthy — triggers rollback).

set -euo pipefail

KUBECONFIG="/var/lib/microshift/resources/kubeadmin/kubeconfig"
MAX_ATTEMPTS=30
WAIT_SECONDS=10

for i in $(seq 1 $MAX_ATTEMPTS); do
    if [ -f "$KUBECONFIG" ] && \
       KUBECONFIG="$KUBECONFIG" /usr/local/bin/oc get --raw /readyz 2>/dev/null | grep -q "ok"; then
        echo "greenboot: MicroShift API server is ready (attempt $i/$MAX_ATTEMPTS)"
        exit 0
    fi
    echo "greenboot: MicroShift not ready yet (attempt $i/$MAX_ATTEMPTS), waiting ${WAIT_SECONDS}s..."
    sleep $WAIT_SECONDS
done

echo "greenboot: MicroShift failed to become ready after $((MAX_ATTEMPTS * WAIT_SECONDS))s"
exit 1
