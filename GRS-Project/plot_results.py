#!/usr/bin/env python3
"""
plot_results.py — GRS Experiment Visualiser
Works with OR without matplotlib — falls back to ASCII chart if not available.

Usage:  python3 plot_results.py
"""

import sys
import csv
from pathlib import Path

RESULTS_DIR = Path(__file__).parent / "results"

def load(name):
    path = RESULTS_DIR / name
    if not path.exists():
        print(f"  WARNING: {name} not found")
        return []
    rows = []
    with open(path) as f:
        reader = csv.reader(f)
        next(reader)  # skip header
        for row in reader:
            try:
                ts, lat = int(row[0]), float(row[1])
                rows.append((ts, lat))
            except (ValueError, IndexError):
                continue
    return rows

def stats(data, label):
    if not data:
        return
    lats = sorted(r[1] * 1000 for r in data)
    n = len(lats)
    mean = sum(lats) / n
    median = lats[n // 2]
    p95 = lats[int(n * 0.95)]
    mx = lats[-1]
    spikes = sum(1 for x in lats if x > 100)
    print(f"  {label:15s}  n={n:3d}  mean={mean:8.2f}ms  "
          f"median={median:8.2f}ms  p95={p95:8.1f}ms  "
          f"max={mx:8.1f}ms  spikes(>100ms)={spikes}")

b = load("baseline.csv")
d = load("delay.csv")
l = load("loss.csv")

print("\n── GRS Experiment Results ──────────────────────────────")
stats(b, "Baseline")
stats(d, "200ms Delay")
stats(l, "20% Loss")

# ── Try matplotlib first ──────────────────────────────────────
try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import matplotlib.ticker as ticker

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(13, 8),
                                    gridspec_kw={"height_ratios": [2.5, 1]})
    fig.suptitle("GRS — Kubernetes eBPF Networking\n"
                 "Latency: Baseline vs 200ms Delay vs 20% Packet Loss",
                 fontsize=13, fontweight="bold")

    COLORS = {"Baseline":"#27ae60","200ms Delay":"#e67e22","20% Loss":"#e74c3c"}

    for data, lbl in [(b,"Baseline"),(d,"200ms Delay"),(l,"20% Loss")]:
        if not data:
            continue
        t0 = data[0][0]
        xs = [(r[0]-t0)/1000 for r in data]
        ys = [r[1]*1000 for r in data]
        mean_ms = sum(ys)/len(ys)
        ax1.plot(xs, ys, label=f"{lbl} (mean={mean_ms:.1f}ms)",
                 color=COLORS[lbl], lw=1.5, marker="o", ms=3, alpha=0.85)

    ax1.set_yscale("log")
    ax1.yaxis.set_major_formatter(
        ticker.FuncFormatter(lambda x,_: f"{x:.0f}ms"))
    ax1.set_xlabel("Elapsed (s)")
    ax1.set_ylabel("Latency (ms) log scale")
    ax1.set_title("Latency over time")
    ax1.legend(fontsize=9)
    ax1.grid(True, ls="--", alpha=0.4)

    box_data, box_labels, box_colors = [], [], []
    for data, lbl in [(b,"Baseline"),(d,"200ms Delay"),(l,"20% Loss")]:
        if data:
            box_data.append([r[1]*1000 for r in data])
            box_labels.append(lbl)
            box_colors.append(COLORS[lbl])

    bp = ax2.boxplot(box_data, tick_labels=box_labels,
                     patch_artist=True, widths=0.4)
    for patch, c in zip(bp["boxes"], box_colors):
        patch.set_facecolor(c); patch.set_alpha(0.7)
    ax2.set_ylabel("Latency (ms)")
    ax2.set_title("Distribution")
    ax2.grid(True, ls="--", alpha=0.4, axis="y")

    plt.tight_layout()
    out = RESULTS_DIR / "latency_comparison.png"
    RESULTS_DIR.mkdir(exist_ok=True)
    plt.savefig(out, dpi=150, bbox_inches="tight")
    print(f"\n  Plot saved → {out}")
    print("  View with:  feh results/latency_comparison.png")
    print("         or:  eog results/latency_comparison.png")
    print("         or:  xdg-open results/latency_comparison.png")

except ImportError:
    # ── ASCII fallback ────────────────────────────────────────
    print("\n  matplotlib not installed — showing ASCII chart\n")
    print("  (Install later: sudo apt install python3-matplotlib -y)\n")

    WIDTH = 60
    for data, lbl in [(b,"Baseline"),(d,"200ms Delay"),(l,"20% Loss")]:
        if not data:
            continue
        lats = [r[1]*1000 for r in data]
        mx = max(lats) if lats else 1
        print(f"  {lbl}")
        print(f"  {'─'*WIDTH}")
        for i, v in enumerate(lats):
            bar_len = int((v / mx) * WIDTH)
            bar = "█" * bar_len
            print(f"  {i+1:3d} │{bar:<{WIDTH}}│ {v:.1f}ms")
        print()

print("\n── How to read eBPF logs ───────────────────────────────")
print("  cat results/retransmissions.log   # TCP retransmit events")
print("  cat results/packet_drops.log      # Kernel drop events")
print("  cat results/pipeline.log          # Full run history")
print()
