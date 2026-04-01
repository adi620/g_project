#!/bin/bash
# run_full_pipeline.sh
# Master pipeline: deploys the system, runs all experiments with eBPF tracing,
# saves all outputs to results/, then cleans up.
#
# Usage: sudo ./run_full_pipeline.sh
#   (sudo is needed for bpftrace and tc)

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${PROJECT_ROOT}/results"
EBPF_DIR="${PROJECT_ROOT}/ebpf"
EXPERIMENTS_DIR="${PROJECT_ROOT}/experiments"
DEPLOY_DIR="${PROJECT_ROOT}/deployment"
TRAFFIC_DIR="${PROJECT_ROOT}/traffic"

# ── KIND CONTEXT: always point kubectl at the 'grs' cluster ──
KIND_CLUSTER="${KIND_CLUSTER:-grs}"
KIND_CONTEXT="kind-${KIND_CLUSTER}"

echo "Setting kubectl context to: ${KIND_CONTEXT}"
if ! kubectl config use-context "$KIND_CONTEXT" 2>/dev/null; then
    echo "ERROR: Context '${KIND_CONTEXT}' not found."
    echo "Available contexts:"
    kubectl config get-contexts
    echo ""
    echo "If your cluster has a different name, run:"
    echo "  KIND_CLUSTER=<name> sudo ./run_full_pipeline.sh"
    exit 1
fi

# ── API SERVER HEALTH CHECK ───────────────────────────────────
echo "Checking Kubernetes API server..."
for i in 1 2 3 4 5; do
    if kubectl cluster-info --context "$KIND_CONTEXT" &>/dev/null; then
        echo "API server is reachable."
        break
    fi
    echo "  Attempt ${i}/5: API server not ready, waiting 5s..."
    sleep 5
    if [ "$i" -eq 5 ]; then
        echo "ERROR: Kubernetes API server is not reachable after 25s."
        echo "Make sure your KIND cluster is running:"
        echo "  kind get clusters"
        echo "  kind create cluster --name ${KIND_CLUSTER}"
        exit 1
    fi
done

mkdir -p "$RESULTS_DIR"

LOG="${RESULTS_DIR}/pipeline.log"
exec > >(tee -a "$LOG") 2>&1

echo "========================================================"
echo " GRS eBPF Kubernetes Networking Pipeline"
echo " Started: $(date)"
echo " Cluster:  ${KIND_CLUSTER}"
echo " Context:  ${KIND_CONTEXT}"
echo "========================================================"

# ── 1. DEPLOY ────────────────────────────────────────────────
echo ""
echo "── [1/6] Deploying Kubernetes workloads ──"
kubectl apply --validate=false -f "${DEPLOY_DIR}/web-deployment.yaml"
kubectl apply --validate=false -f "${DEPLOY_DIR}/web-service.yaml"
kubectl apply --validate=false -f "${TRAFFIC_DIR}/traffic.yaml"

echo "Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -l app=web --timeout=120s
kubectl wait --for=condition=ready pod/traffic --timeout=120s

echo "Pods ready:"
kubectl get pods -o wide

# ── 2. CONNECTIVITY CHECK ────────────────────────────────────
echo ""
echo "── [2/6] Connectivity check ──"
kubectl exec traffic -- curl -s -o /dev/null -w "HTTP %{http_code}\n" web
echo "Connectivity OK."

# ── 3. START eBPF TRACING ────────────────────────────────────
echo ""
echo "── [3/6] Starting eBPF tracing (background) ──"
sudo bpftrace "${EBPF_DIR}/tcp_retransmissions.bt" \
    > "${RESULTS_DIR}/retransmissions.log" 2>&1 &
RETRANS_PID=$!

sudo bpftrace "${EBPF_DIR}/packet_drops.bt" \
    > "${RESULTS_DIR}/packet_drops.log" 2>&1 &
DROPS_PID=$!

echo "eBPF tracing PIDs: retransmissions=${RETRANS_PID}, drops=${DROPS_PID}"

# Give bpftrace time to attach probes
sleep 3

# ── 4. BASELINE ──────────────────────────────────────────────
echo ""
echo "── [4/6] Baseline experiment ──"
bash "${EXPERIMENTS_DIR}/run_baseline.sh"

# ── 5. DELAY ─────────────────────────────────────────────────
echo ""
echo "── [5/6] Delay experiment (100ms) ──"
bash "${EXPERIMENTS_DIR}/run_delay.sh"

# ── 6. PACKET LOSS ───────────────────────────────────────────
echo ""
echo "── [6/6] Packet loss experiment (10%) ──"
bash "${EXPERIMENTS_DIR}/run_loss.sh"

# ── CLEANUP ──────────────────────────────────────────────────
echo ""
echo "── Stopping eBPF tracing ──"
sudo kill "$RETRANS_PID" 2>/dev/null || true
sudo kill "$DROPS_PID"   2>/dev/null || true
wait "$RETRANS_PID" 2>/dev/null || true
wait "$DROPS_PID"   2>/dev/null || true

echo ""
echo "── Ensuring no residual tc rules ──"
"${PROJECT_ROOT}/fault_injection/clear_rules.sh" 2>/dev/null || true

echo ""
echo "========================================================"
echo " Pipeline complete: $(date)"
echo " Results saved in: ${RESULTS_DIR}/"
ls -lh "${RESULTS_DIR}/"
echo "========================================================"