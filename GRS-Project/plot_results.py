#!/usr/bin/env python3
"""
plot_results.py  —  Visualise GRS experiment results
Reads baseline.csv, delay.csv, loss.csv from results/ and produces
a side-by-side latency comparison chart.

Usage:
    python3 plot_results.py [--results-dir ./results] [--out ./results/plot.png]

Requirements:  pip install matplotlib pandas
"""

import argparse
import sys
from pathlib import Path

try:
    import pandas as pd
    import matplotlib.pyplot as plt
    import matplotlib.ticker as ticker
except ImportError:
    print("Install deps: pip install matplotlib pandas")
    sys.exit(1)


def load(path: Path, label: str) -> pd.DataFrame:
    if not path.exists():
        print(f"  WARNING: {path.name} not found — skipping '{label}'.")
        return pd.DataFrame()
    df = pd.read_csv(path)
    df.columns = ["ts_ms", "lat_s"]
    df = df[df["lat_s"] != "timeout"].copy()
    df["lat_s"] = pd.to_numeric(df["lat_s"], errors="coerce")
    df = df.dropna(subset=["lat_s"])
    df["elapsed_s"] = (df["ts_ms"] - df["ts_ms"].iloc[0]) / 1000.0
    df["label"] = label
    return df


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--results-dir", default="results")
    parser.add_argument("--out", default=None)
    args = parser.parse_args()

    rd = Path(args.results_dir)
    out = Path(args.out) if args.out else rd / "latency_comparison.png"

    datasets = {
        "Baseline":    load(rd / "baseline.csv", "Baseline"),
        "200ms Delay": load(rd / "delay.csv",    "200ms Delay"),
        "20% Loss":    load(rd / "loss.csv",     "20% Loss"),
    }

    COLORS = {"Baseline": "#27ae60", "200ms Delay": "#e67e22", "20% Loss": "#e74c3c"}

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(13, 8),
                                    gridspec_kw={"height_ratios": [2.5, 1]})
    fig.suptitle(
        "Kubernetes eBPF Networking — Latency Under Fault Injection",
        fontsize=13, fontweight="bold", y=0.98
    )

    box_data, box_labels = [], []

    for label, df in datasets.items():
        if df.empty:
            continue
        c = COLORS.get(label, "grey")
        lat_ms = df["lat_s"] * 1000
        ax1.plot(df["elapsed_s"], lat_ms,
                 label=f"{label}  (mean={lat_ms.mean():.1f}ms)",
                 color=c, linewidth=1.4, alpha=0.85)
        box_data.append(lat_ms.values)
        box_labels.append(label)

    ax1.set_xlabel("Elapsed time (s)", fontsize=10)
    ax1.set_ylabel("Latency (ms)", fontsize=10)
    ax1.set_title("Latency over time per experiment", fontsize=11)
    ax1.legend(fontsize=9)
    ax1.grid(True, linestyle="--", alpha=0.4)
    ax1.yaxis.set_minor_locator(ticker.AutoMinorLocator())

    if box_data:
        bp = ax2.boxplot(box_data, labels=box_labels,
                         patch_artist=True, notch=False, widths=0.4)
        for patch, label in zip(bp["boxes"], box_labels):
            patch.set_facecolor(COLORS.get(label, "grey"))
            patch.set_alpha(0.65)
    ax2.set_ylabel("Latency (ms)", fontsize=10)
    ax2.set_title("Latency distribution (box plot)", fontsize=11)
    ax2.grid(True, linestyle="--", alpha=0.4, axis="y")

    plt.tight_layout()
    out.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(out, dpi=150, bbox_inches="tight")
    print(f"\nPlot saved → {out}")

    print("\n── Summary Statistics ─────────────────────────────")
    for label, df in datasets.items():
        if df.empty:
            continue
        lat = df["lat_s"] * 1000
        print(f"  {label:15s}  "
              f"mean={lat.mean():7.2f}ms  "
              f"median={lat.median():7.2f}ms  "
              f"p95={lat.quantile(0.95):7.2f}ms  "
              f"max={lat.max():7.2f}ms  "
              f"n={len(lat)}")


if __name__ == "__main__":
    main()
