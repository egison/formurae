#!/usr/bin/env python3
"""Plot saved diagnostics; this does not perform simulation calculations."""
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import NullLocator

from gallery import load_report

HERE = Path(__file__).resolve().parent


def main():
    report = load_report()
    runs = report["runs"]
    grids = sorted({r["grid"] for r in runs})
    charts = ("cartesian", "mapped")
    labels = ("Cartesian", "Mapped")
    colors = ("#265b9a", "#13846c")
    plt.rcParams.update({"font.size": 10, "axes.spines.top": False,
                         "axes.spines.right": False, "svg.fonttype": "none",
                         "svg.hashsalt": "kinetic-fv"})
    fig, axes = plt.subplots(1, 2, figsize=(10, 4.2), layout="constrained")
    for chart, label, color, marker in zip(charts, labels, colors, ("o", "s")):
        values = sorted((r for r in runs if r["chart"] == chart and r["scenario"] == "smooth"),
                        key=lambda r: r["grid"])
        axes[0].loglog(grids, [r["final"]["error"] for r in values], marker=marker,
                      color=color, label=label, markersize=6)
    anchor = next(r["final"]["error"] for r in runs
                  if r["grid"] == grids[0] and r["chart"] == "mapped" and r["scenario"] == "smooth")
    axes[0].loglog(grids, [anchor*1.3*grids[0]/n for n in grids], "--",
                  color="#777777", linewidth=1, label="First-order slope")
    axes[0].set_xticks(grids, [str(n) for n in grids])
    axes[0].xaxis.set_minor_locator(NullLocator())
    axes[0].set_xlabel("Cells per coordinate")
    axes[0].set_ylabel("Maximum error in population / weight")
    axes[0].set_title("Smooth transport: error decreases", loc="left")
    axes[0].legend(frameon=False, fontsize=9)
    axes[0].grid(True, which="major", alpha=0.2)

    for method, offset, color, label in (("upwind", -0.18, "#265b9a", "Upwind + Euler"),
                                         ("centered", 0.18, "#cb7428", "Centered flux + Euler")):
        values = [next(r["final"]["lowest"] for r in runs
                       if r["grid"] == grids[-1] and r["scenario"] == "sharp"
                       and r["chart"] == chart and r["method"] == method) for chart in charts]
        positions = [i+offset for i in range(2)]
        axes[1].bar(positions, values, width=0.3, color=color, label=label, zorder=3)
        for x, value in zip(positions, values):
            if value == 0:
                axes[1].plot(x, value, "o", color=color, markersize=6, zorder=4)
            axes[1].annotate(f"{value:.3f}" if value else "0", (x, value),
                             xytext=(0, 9 if value == 0 else -16), textcoords="offset points",
                             ha="center", color=color, weight="bold")
    axes[1].axhline(0, color="#667085", linewidth=1)
    axes[1].set_xticks([0, 1], labels)
    axes[1].set_ylabel("Minimum population / weight over all steps")
    axes[1].set_title(f"Sharp profile: negative values ({grids[-1]} × {grids[-1]})", loc="left")
    axes[1].set_ylim(-1.35, 0.4)
    axes[1].legend(frameon=False, fontsize=9, loc="upper right")
    axes[1].grid(axis="y", alpha=0.2, zorder=0)
    svg = HERE / "results/comparison.svg"
    fig.savefig(svg, metadata={"Date": None})
    svg.write_text("\n".join(line.rstrip() for line in svg.read_text().splitlines())+"\n")
    fig.savefig(HERE / "results/comparison.png", dpi=180)
    plt.close(fig)


if __name__ == "__main__":
    main()
