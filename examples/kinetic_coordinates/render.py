#!/usr/bin/env python3
"""Plot recorded convergence results; no simulation quantities are computed."""
import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import NullLocator

HERE = Path(__file__).resolve().parent


def main():
    data = json.loads((HERE / "results/verification.json").read_text())
    if not data["passed"]:
        raise ValueError("render only verified results")
    colors = {"cartesian": "#265b9a", "stretched": "#cb7428", "curved": "#13846c"}
    labels = {"cartesian": "Cartesian", "stretched": "Stretched", "curved": "Curved"}
    markers = {"cartesian": "o", "stretched": "s", "curved": "^"}
    plt.rcParams.update({"font.size": 10, "axes.spines.top": False,
                         "axes.spines.right": False, "svg.fonttype": "none"})
    fig, axes = plt.subplots(1, 2, figsize=(10, 4.2), layout="constrained")
    for chart, values in data["transport"].items():
        axes[0].loglog(values["grids"], values["final_max_population_error"],
                       marker=markers[chart], color=colors[chart], label=labels[chart],
                       markersize=8 if chart == "cartesian" else 4,
                       markerfacecolor="white" if chart == "cartesian" else colors[chart])
    for chart, values in data["shear"].items():
        axes[1].loglog(values["grids"], values["mode_difference_from_cartesian"],
                       marker=markers[chart], color=colors[chart], label=labels[chart],
                       markersize=7 if chart == "stretched" else 4,
                       markerfacecolor="white" if chart == "stretched" else colors[chart])
    # A slope guide on the plot, not an additional physical prediction.
    for ax, section, key in zip(axes, ("transport", "shear"),
                                ("final_max_population_error", "mode_difference_from_cartesian")):
        values = data[section]["curved"]
        grids = values["grids"]
        anchor = values[key][0] * 1.35
        ax.loglog(grids, [anchor*(grids[0]/n)**2 for n in grids],
                  "--", color="#777777", linewidth=1, label="Second-order slope")
        ax.set_xticks(grids, [str(n) for n in grids])
        ax.xaxis.set_minor_locator(NullLocator())
        ax.set_xlabel("Grid points per coordinate")
        ax.grid(True, which="major", alpha=0.2)
        ax.legend(frameon=False, fontsize=9)
    axes[0].set_title("Transport: comparison with the exact solution", loc="left")
    axes[0].set_ylabel("Maximum population-vector error")
    axes[1].set_title("Shear: agreement between coordinate systems", loc="left")
    axes[1].set_ylabel("Mode amplitude difference from Cartesian")
    svg = HERE / "results/convergence.svg"
    fig.savefig(svg)
    svg.write_text("\n".join(line.rstrip() for line in svg.read_text().splitlines()) + "\n")
    fig.savefig(HERE / "results/convergence.png", dpi=180)
    plt.close(fig)


if __name__ == "__main__":
    main()
