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
    plt.rcParams.update({"font.size": 10, "axes.spines.top": False,
                         "axes.spines.right": False, "svg.fonttype": "none",
                         "svg.hashsalt": "kinetic-fv"})
    fig, axes = plt.subplots(1, 2, figsize=(10, 4.2), layout="constrained")
    for method, style, marker, method_label in (("upwind", ":", "o", "Upwind"),
                                                ("muscl", "-", "s", "MUSCL")):
        for chart, label, color in zip(charts, labels, ("#265b9a", "#13846c")):
            values = sorted((r for r in runs if r["chart"] == chart and r["scenario"] == "smooth" and r["method"]==method),
                            key=lambda r: r["grid"])
            axes[0].loglog(grids, [r["final"]["error"] for r in values], marker=marker,
                          color=color, linestyle=style, label=f"{method_label}: {label}", markersize=5,
                          markerfacecolor="white" if method=="upwind" else color)
    anchor = next(r["final"]["error"] for r in runs
                  if r["grid"] == grids[0] and r["chart"] == "mapped"
                  and r["scenario"] == "smooth" and r["method"]=="muscl")
    axes[0].loglog(grids, [anchor*0.6*(grids[0]/n)**2 for n in grids], "--",
                  color="#777777", linewidth=1, label="Second-order slope")
    axes[0].set_xticks(grids, [str(n) for n in grids])
    axes[0].xaxis.set_minor_locator(NullLocator())
    axes[0].set_xlabel("Cells per coordinate")
    axes[0].set_ylabel("Maximum error in population / weight")
    axes[0].set_title("Smooth transport: improved accuracy", loc="left")
    axes[0].legend(frameon=False, fontsize=8, loc="lower left")
    axes[0].grid(True, which="major", alpha=0.2)

    maximum = 0
    for method, offset, color, label in (("upwind", -0.18, "#8592a3", "Upwind + Euler"),
                                         ("muscl", 0.18, "#265b9a", "MUSCL + SSPRK2")):
        values = [next(r["final"]["mixing"] for r in runs
                       if r["grid"] == grids[-1] and r["scenario"] == "sharp"
                       and r["chart"] == chart and r["method"] == method) for chart in charts]
        positions = [i+offset for i in range(2)]
        maximum = max(maximum, *values)
        axes[1].bar(positions, values, width=0.3, color=color, label=label, zorder=3)
        for x, value in zip(positions, values):
            axes[1].annotate(f"{value:.4f}", (x, value), xytext=(0, 7), textcoords="offset points",
                             ha="center", color=color, weight="bold", fontsize=9)
    axes[1].set_xticks([0, 1], labels)
    axes[1].set_ylabel("Mean q(1-q), with q = population / weight")
    axes[1].set_title(f"Sharp profile: less smearing ({grids[-1]} × {grids[-1]})", loc="left")
    axes[1].set_ylim(0, maximum*1.45)
    axes[1].legend(frameon=False, fontsize=9, loc="upper right")
    axes[1].grid(axis="y", alpha=0.2, zorder=0)
    svg = HERE / "results/comparison.svg"
    fig.savefig(svg, metadata={"Date": None})
    svg.write_text("\n".join(line.rstrip() for line in svg.read_text().splitlines())+"\n")
    fig.savefig(HERE / "results/comparison.png", dpi=180)
    plt.close(fig)


if __name__ == "__main__":
    main()
