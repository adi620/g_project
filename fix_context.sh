#!/bin/bash
# fix_context.sh
# Run this BEFORE run_full_pipeline.sh if kubectl can't reach the API server.
# It sets the correct kubectl context for the KIND cluster.

set -euo pipefail

KIND_CLUSTER="${1:-grs}"
KIND_CONTEXT="kind-${KIND_CLUSTER}"

echo "── Checking available KIND clusters ──"
kind get clusters

echo ""
echo "── Switching kubectl context to: ${KIND_CONTEXT} ──"
kubectl config use-context "$KIND_CONTEXT"

echo ""
echo "── Verifying API server reachability ──"
kubectl cluster-info

echo ""
echo "── Current pods (if any) ──"
kubectl get pods -A 2>/dev/null || echo "(no pods yet)"

echo ""
echo "✅ Context is set. You can now run:"
echo "   sudo ./run_full_pipeline.sh"
