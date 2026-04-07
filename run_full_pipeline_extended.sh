#!/bin/bash
# run_full_pipeline_extended.sh
# Extended pipeline — runs all 6 fault experiments + report.
# Calls the original 3 steps then adds: bandwidth, reordering, cpu_stress.
#
# Existing steps 1–8 are preserved by sourcing the original pipeline up to
# the point where it would generate the report, then we add the new experiments,
# then generate the extended report.
#
# Usage: sudo ./run_full_pipeline_extended.sh

set -euo pipefail

# ── SUDO-SAFE KUBECONFIG ──────────────────────────────────────
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

if [ ! -f "$KUBECONFIG" ]; then
    echo "ERROR: kubeconfig not found at ${KUBECONFIG}"
    echo "Run as the ubuntu user with sudo, not as root directly."
    exit 1
fi

# ── SET KUBECTL CONTEXT ───────────────────────────────────────
KIND_CLUSTER="${KIND_CLUSTER:-grs}"
KIND_CONTEXT="kind-${KIND_CLUSTER}"

echo "Switching kubectl context → ${KIND_CONTEXT}"
if ! kubectl config use-context "$KIND_CONTEXT" 2>/dev/null; then
    echo "ERROR: Context '${KIND_CONTEXT}' not found."
    echo "Available contexts:"; kubectl config get-contexts 2>/dev/null || true
    echo "Available KIND clusters:"; kind get clusters 2>/dev/null || true
    echo "Tip: KIND_CLUSTER=<n> sudo ./run_full_pipeline_extended.sh"
    exit 1
fi

# ── VERIFY API SERVER ─────────────────────────────────────────
echo "Verifying Kubernetes API server..."
for i in $(seq 1 6); do
    if kubectl cluster-info &>/dev/null; then
        echo "✓ API server reachable."; break
    fi
    [ "$i" -eq 6 ] && { echo "ERROR: API server unreachable."; exit 1; }
    echo "  Waiting... (${i}/6)"; sleep 5
done

# ── PATHS ─────────────────────────────────────────────────────
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="${PROJECT_ROOT}/results"
mkdir -p "$RESULTS"

exec > >(tee -a "${RESULTS}/pipeline_extended.log") 2>&1

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   GRS Extended — Kubernetes eBPF Networking Fault Diagnosis  ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Started:    $(date)"
echo "║  Cluster:    ${KIND_CLUSTER}   Context: ${KIND_CONTEXT}"
echo "║  Experiments: baseline → delay → loss → bandwidth →         ║"
echo "║               reordering → cpu_stress                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ── STEP 1: DEPLOY ────────────────────────────────────────────
echo ""
echo "══ [1/11] Deploying Kubernetes workloads ════════════════════"
kubectl apply --validate=false -f "${PROJECT_ROOT}/deployment/web-deployment.yaml"
kubectl apply --validate=false -f "${PROJECT_ROOT}/deployment/web-service.yaml"
echo "Recreating traffic pod..."
kubectl delete pod traffic --ignore-not-found=true
kubectl apply --validate=false -f "${PROJECT_ROOT}/traffic/traffic.yaml"
echo "Waiting for pods to be Ready..."
kubectl wait --for=condition=ready pod -l app=web --timeout=120s
kubectl wait --for=condition=ready pod/traffic    --timeout=120s
echo ""; kubectl get pods -o wide; echo ""

# ── STEP 2: CONNECTIVITY CHECK ────────────────────────────────
echo "══ [2/11] Connectivity check ════════════════════════════════"
HTTP_CODE=$(kubectl exec traffic -- \
    curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://web/ 2>/dev/null)
[ "$HTTP_CODE" = "200" ] && echo "✓ HTTP ${HTTP_CODE} — confirmed." || \
    { echo "ERROR: Expected 200, got ${HTTP_CODE}"; exit 1; }
WEB_IP=$(kubectl get pod -l app=web -o jsonpath='{.items[0].status.podIP}')
TRAFFIC_IP=$(kubectl get pod traffic -o jsonpath='{.status.podIP}')
echo "  Web pod IP: ${WEB_IP}   Traffic pod IP: ${TRAFFIC_IP}"

# ── STEP 3: START eBPF TRACING ────────────────────────────────
echo ""
echo "══ [3/11] Starting eBPF kernel tracers (background) ═════════"
bpftrace "${PROJECT_ROOT}/ebpf/tcp_retransmissions.bt" \
    > "${RESULTS}/retransmissions.log" 2>&1 &
RETRANS_PID=$!
bpftrace "${PROJECT_ROOT}/ebpf/packet_drops.bt" \
    > "${RESULTS}/packet_drops.log" 2>&1 &
DROPS_PID=$!
echo "  tcp_retransmit_skb PID: ${RETRANS_PID}  kfree_skb PID: ${DROPS_PID}"
echo "  Waiting 3s for probes to attach..."
sleep 3

cleanup_ebpf() {
    echo ""; echo "── Stopping eBPF tracers ──"
    kill "$RETRANS_PID" 2>/dev/null || true
    kill "$DROPS_PID"   2>/dev/null || true
    wait "$RETRANS_PID" 2>/dev/null || true
    wait "$DROPS_PID"   2>/dev/null || true
    echo "   eBPF tracers stopped."
}
trap cleanup_ebpf EXIT

# ── STEP 4: BASELINE ──────────────────────────────────────────
echo ""
echo "══ [4/11] Baseline — 60s, no faults ════════════════════════"
bash "${PROJECT_ROOT}/experiments/run_baseline.sh"

# ── STEP 5: DELAY ─────────────────────────────────────────────
echo ""
echo "══ [5/11] Delay — 200ms, 60s ═══════════════════════════════"
bash "${PROJECT_ROOT}/experiments/run_delay.sh"

# ── STEP 6: LOSS ──────────────────────────────────────────────
echo ""
echo "══ [6/11] Packet loss — 20%, 60s ═══════════════════════════"
bash "${PROJECT_ROOT}/experiments/run_loss.sh"

# ── STEP 7: BANDWIDTH ─────────────────────────────────────────
echo ""
echo "══ [7/11] Bandwidth limit — 1mbit, 60s ══════════════════════"
bash "${PROJECT_ROOT}/experiments/run_bandwidth.sh"

# ── STEP 8: REORDERING ────────────────────────────────────────
echo ""
echo "══ [8/11] Packet reordering — 25%, 60s ══════════════════════"
bash "${PROJECT_ROOT}/experiments/run_reordering.sh"

# ── STEP 9: CPU STRESS ────────────────────────────────────────
echo ""
echo "══ [9/11] CPU stress — 4 workers, 60s ══════════════════════"
bash "${PROJECT_ROOT}/experiments/run_cpu_stress.sh"

# ── Stop eBPF ─────────────────────────────────────────────────
echo ""
echo "── Stopping eBPF tracers ──"
kill "$RETRANS_PID" 2>/dev/null || true
kill "$DROPS_PID"   2>/dev/null || true
wait "$RETRANS_PID" 2>/dev/null || true
wait "$DROPS_PID"   2>/dev/null || true
trap - EXIT
sleep 2

# ── STEP 10: SUMMARY ──────────────────────────────────────────
echo ""
echo "══ [10/11] Results summary ══════════════════════════════════"
echo ""
echo "── Latency CSV results ──"
for csv in baseline delay loss bandwidth reordering cpu_stress; do
    FILE="${RESULTS}/${csv}.csv"
    if [ -f "$FILE" ]; then
        STATS=$(tail -n +2 "$FILE" | grep -v timeout | \
            awk -F',' '{s+=$2; n++; if($2>m) m=$2} \
            END{printf "n=%-3d  mean=%.4fs  max=%.4fs", n, s/n, m}')
        echo "  ${csv}.csv  →  ${STATS}"
    else
        echo "  ${csv}.csv  →  NOT FOUND"
    fi
done

echo ""
echo "── eBPF kernel events ──"
RETRANS_COUNT=$(grep -c "RETRANSMIT" "${RESULTS}/retransmissions.log" 2>/dev/null || echo 0)
DROP_COUNT=$(grep -v "^TIME\|^Tracing\|^$\|\[eBPF\]" "${RESULTS}/packet_drops.log" 2>/dev/null | grep -c "[0-9]" || echo 0)
echo "  TCP retransmissions: ${RETRANS_COUNT} events"
echo "  Packet drops:        ${DROP_COUNT} events"

# ── STEP 11: REPORTS ──────────────────────────────────────────
echo ""
echo "══ [11/11] Generating reports ═══════════════════════════════"

# Extended HTML report
bash "${PROJECT_ROOT}/generate_report_extended.sh"

# Extended plot (all 6 faults)
python3 "${PROJECT_ROOT}/plot_results_extended.py" 2>/dev/null && \
    echo "  ✓ Extended plot saved → ${RESULTS}/latency_comparison_extended.png" || \
    echo "  (plot skipped — install matplotlib: sudo apt install python3-matplotlib -y)"

# Fault matrix markdown
bash "${PROJECT_ROOT}/generate_fault_matrix.sh"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Extended pipeline complete: $(date)"
echo "║  Results in: ${RESULTS}/"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  View reports:"
echo "║    python3 -m http.server 8080 --directory ${RESULTS}"
echo "║    http://localhost:8080/report_extended.html"
echo "║    http://localhost:8080/fault_matrix.md"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
ls -lh "${RESULTS}/"
