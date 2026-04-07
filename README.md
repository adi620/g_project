# GRS — Diagnosing Kubernetes Networking Failures Using eBPF

**Tech:** Kubernetes + eBPF (bpftrace) + KIND + tc netem  
**Goal:** Use kernel-level eBPF probes to trace packet drops, TCP retransmissions, and latency across three fault scenarios.

---

## One command runs everything

```bash
sudo ./run_full_pipeline.sh
```

This single command:
1. Deploys web pod (nginx) and traffic pod (curl)
2. Verifies HTTP connectivity
3. Starts eBPF kernel tracers in the background
4. Runs 60s baseline (no faults)
5. Injects 200ms delay → runs 60s → clears fault
6. Injects 20% packet loss → runs 60s → clears fault
7. Prints summary to terminal
8. **Generates a professional HTML report** at `results/report.html`
9. Generates latency comparison chart at `results/latency_comparison.png`

---

## Prerequisites

```bash
sudo apt update --fix-missing
sudo apt install -y docker.io iproute2 bpftrace python3-matplotlib python3-pandas

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.22.0/kind-linux-amd64
sudo install -o root -g root -m 0755 kind /usr/local/bin/kind
```

---

## Setup

```bash
# Create KIND cluster
kind create cluster --name grs

# Clone project
git clone https://github.com/adi620/g_project.git
cd g_project/GRS-Project

# Make scripts executable
find . -name "*.sh" -exec chmod +x {} \;

# Run everything
sudo ./run_full_pipeline.sh
```

---

## View Results

```bash
# View HTML report in browser
python3 -m http.server 8080 --directory results
# Open: http://localhost:8080/report.html

# View latency chart — serve via HTTP (headless VM has no X display)
python3 -m http.server 8080 --directory results
# Then open in browser: http://localhost:8080/latency_comparison.png
# OR copy results/latency_comparison.png to your Windows host and open it

# View eBPF logs
cat results/retransmissions.log
cat results/packet_drops.log

# Count retransmission events
grep -c "RETRANSMIT" results/retransmissions.log
```

---

## Project Structure

```
GRS-Project/
├── run_full_pipeline.sh     ← SINGLE COMMAND — runs everything
├── generate_report.sh       ← Generates HTML report (called automatically)
├── plot_results.py          ← Generates PNG chart (called automatically)
├── deployment/              ← Kubernetes YAML files
├── traffic/                 ← Traffic generator pod
├── fault_injection/         ← tc netem injection scripts
├── measurement/             ← Latency measurement scripts
├── ebpf/                    ← bpftrace kernel probe scripts
├── experiments/             ← Individual experiment scripts
└── results/                 ← All outputs
    ├── baseline.csv
    ├── delay.csv
    ├── loss.csv
    ├── retransmissions.log  ← eBPF TCP retransmission events
    ├── packet_drops.log     ← eBPF kernel drop events
    ├── pipeline.log         ← Full run log
    ├── report.html          ← Professional HTML report
    └── latency_comparison.png
```

---

## Expected Results

| Experiment | Mean Latency | Max Latency | eBPF Events |
|---|---|---|---|
| Baseline | ~2ms | ~5ms | 0 retransmissions |
| 200ms Delay | ~402ms | ~404ms | ~0 retransmissions |
| 20% Loss | ~370ms | ~2000ms+ | 30+ retransmissions |

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `Context 'kind-grs' not found` | `kind create cluster --name grs` |
| `kubeconfig not found` | Use `sudo` from ubuntu user, not root |
| delay.csv shows no change | `sudo ./fault_injection/debug_network.sh` |
| `AF_INET` error in bpftrace | Already fixed — scripts use numeric `2` |
| `pip3: command not found` | `sudo apt install python3-pip -y` |
