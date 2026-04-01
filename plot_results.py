#!/usr/bin/env python3
"""
plot_results.py
Reads baseline.csv, delay.csv, loss.csv from the results/ directory
and produces a comparative latency plot.

Usage:
    python3 plot_results.py [--results-dir ./results] [--output ./results/latency_comparison.png]

Requirements:
    pip install matplotlib pandas
"""

import argparse
import sys
from pathlib import Path

try:
    import pandas as pd
    import matplotlib.pyplot as plt
    import matplotlib.ticker as ticker
except ImportError:
    print("ERROR: Install dependencies with:  pip install matplotlib pandas")
    sys.exit(1)


def load_csv(path: Path, label: str) -> pd.DataFrame:
    if not path.exists():
        print(f"WARNING: {path} not found, skipping '{label}'.")
        return pd.DataFrame()
    df = pd.read_csv(path)
    df.columns = ["timestamp_ms", "latency_s"]
    # Filter out 'timeout' rows
    df = df[df["latency_s"] != "timeout"].copy()
    df["latency_s"] = pd.to_numeric(df["latency_s"], errors="coerce")
    df = df.dropna(subset=["latency_s"])
    # Normalise time to seconds-from-start
    df["elapsed_s"] = (df["timestamp_ms"] - df["timestamp_ms"].iloc[0]) / 1000.0
    df["label"] = label
    return df


def main():
    parser = argparse.ArgumentParser(description="Plot latency comparison from GRS experiments.")
    parser.add_argument("--results-dir", default="results", help="Directory containing CSV files")
    parser.add_argument("--output", default=None, help="Output image path (default: results/latency_comparison.png)")
    args = parser.parse_args()

    results_dir = Path(args.results_dir)
    output_path = Path(args.output) if args.output else results_dir / "latency_comparison.png"

    datasets = {
        "Baseline":      load_csv(results_dir / "baseline.csv", "Baseline"),
        "100ms Delay":   load_csv(results_dir / "delay.csv",    "100ms Delay"),
        "10% Loss":      load_csv(results_dir / "loss.csv",     "10% Loss"),
    }

    fig, axes = plt.subplots(2, 1, figsize=(12, 8), gridspec_kw={"height_ratios": [2, 1]})
    fig.suptitle("Kubernetes Networking — Latency Under Fault Conditions", fontsize=14, fontweight="bold")

    colors = {"Baseline": "#2ecc71", "100ms Delay": "#e67e22", "10% Loss": "#e74c3c"}
    ax_line = axes[0]
    ax_box  = axes[1]

    box_data   = []
    box_labels = []

    for label, df in datasets.items():
        if df.empty:
            continue
        color = colors.get(label, "grey")
        ax_line.plot(df["elapsed_s"], df["latency_s"] * 1000,
                     label=label, color=color, linewidth=1.2, alpha=0.85)
        box_data.append(df["latency_s"].values * 1000)
        box_labels.append(label)

    ax_line.set_xlabel("Elapsed time (s)")
    ax_line.set_ylabel("Latency (ms)")
    ax_line.set_title("Latency over time")
    ax_line.legend()
    ax_line.grid(True, linestyle="--", alpha=0.4)
    ax_line.yaxis.set_minor_locator(ticker.AutoMinorLocator())

    if box_data:
        bp = ax_box.boxplot(box_data, labels=box_labels, patch_artist=True, notch=False)
        for patch, label in zip(bp["boxes"], box_labels):
            patch.set_facecolor(colors.get(label, "grey"))
            patch.set_alpha(0.7)
    ax_box.set_ylabel("Latency (ms)")
    ax_box.set_title("Latency distribution per experiment")
    ax_box.grid(True, linestyle="--", alpha=0.4, axis="y")

    plt.tight_layout()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(output_path, dpi=150)
    print(f"Plot saved to: {output_path}")

    # Print summary stats
    print("\n── Summary Statistics ──")
    for label, df in datasets.items():
        if df.empty:
            continue
        lat = df["latency_s"] * 1000
        print(f"  {label:15s}  mean={lat.mean():.1f}ms  median={lat.median():.1f}ms  "
              f"p95={lat.quantile(0.95):.1f}ms  max={lat.max():.1f}ms")


if __name__ == "__main__":
    main()
