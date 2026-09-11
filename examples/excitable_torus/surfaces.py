#!/usr/bin/env python3
"""The same excitable-wave program on four surfaces.

Only the geometry declaration, the components of the unit direction vector
and the region of the initial stimulus change between surfaces; the flux
form, the reaction and the diagnostics are the lines of excitable_torus.fme.
Surfaces with walls in theta use Formura's mirror boundary (no time blocking).
This script builds, runs, checks the heat conservation without reaction, and
draws the unwrapped fields; all numerical work is in the generated solvers.
"""
import argparse
import csv
import json
from pathlib import Path
import struct

from run import HERE, ROOT, build, run

TAU = 6.283185307179586
SURFACES = {
    # name: (description, metric line, direction line, stimulus test, theta length, theta boundary,
    #        theta label, theta cells, time step)
    "torus": ("Torus R = 12, r = 6 (curvature changes sign)",
              "metric scale [r, R + r * cos θ]",
              "def direction alpha = [| cos alpha / r, sin alpha / (R + r * cos θ) |]",
              "cos θ > 0", TAU, "periodic", "theta (around the tube)", 96, 0.005),
    "sphere": ("Sphere band, radius 12 (positive curvature)",
               "metric scale [12, 12 * sin (0.6 + θ)]",
               "def direction alpha = [| cos alpha / 12, sin alpha / (12 * sin (0.6 + θ)) |]",
               "θ > 0.75 && θ < 1.2", 1.9415926535897931, "mirror", "theta (colatitude - 0.6)", 112, 0.002),
    "hyperbolic": ("Hyperbolic band, curvature -1/144 (negative curvature)",
                   "metric scale [12 / (1 + θ), 12 / (1 + θ)]",
                   "def direction alpha = [| cos alpha * (1 + θ) / 12, sin alpha * (1 + θ) / 12 |]",
                   "θ > 0.7 && θ < 1.3", 2.0, "mirror", "theta (height - 1)", 64, 0.002),
    "annulus": ("Flat annulus, radii 6 to 18 (zero curvature)",
                "metric scale [1, 6 + θ]",
                "def direction alpha = [| cos alpha, sin alpha / (6 + θ) |]",
                "θ > 4 && θ < 8", 12.0, "mirror", "theta (radius - 6)", 64, 0.004),
}


def substitutions(name):
    _, metric, direction, stimulus, _, _, _, _, _ = SURFACES[name]
    return {
        "metric scale [r, R + r * cos θ]": metric,
        "def direction alpha = [| cos alpha / r, sin alpha / (R + r * cos θ) |]": direction,
        "cos θ > 0": stimulus,
    }


def stats(directory):
    with (directory / "stats.csv").open() as file:
        return [{k: float(v) for k, v in row.items()} for row in csv.DictReader(file)]


def load(directory, step):
    path = next((directory / "data").glob(f"frame-{step:07d}-rank-*.bin"))
    data = path.read_bytes()
    nx, ny, _ = struct.unpack_from("=iii", data)
    grid = [[0.0] * ny for _ in range(nx)]
    for i, j, u, v in struct.iter_unpack("=iidd", data[12:]):
        grid[i][j] = u
    return grid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".build/excitable_torus/surfaces")
    parser.add_argument("--time", type=float, default=60.0)
    parser.add_argument("--figure", action="store_true", help="draw results/surfaces.png (needs numpy and matplotlib)")
    args = parser.parse_args()
    report = {}
    runs = {}
    for name, (label, metric, direction, stimulus, length, wall, ylabel, cells, dt) in SURFACES.items():
        grid = (cells, 192)
        # twelve outputs, each a multiple of the blocking interval, dividing the run
        steps = max(48, int(round(args.time / dt / 48)) * 48)
        every = steps // 12
        common = dict(substitutions=substitutions(name), length=(length, TAU), boundary=(wall, "periodic"),
                      blocking=4 if wall == "periodic" else 0, overrides={"dt": str(dt)})
        # heat conservation without reaction: the metric-weighted integral of u is exact
        directory = build(args.output / (name + "-diffusion"), "oblique", grid,
                          **common | {"overrides": {"stimulus": "0", "reaction": "0", "dt": str(dt)}})
        run(directory, 800, 80, dump=False)
        rows = stats(directory)
        drift = max(abs(r["mass"] - rows[0]["mass"]) for r in rows)
        assert drift < 1e-8 * abs(rows[0]["mass"]), (name, drift)
        # the excitable wave from the same stimulus
        directory = build(args.output / name, "oblique", grid, **common)
        run(directory, steps, every)
        runs[name] = (directory, dt, steps, every)
        report[name] = {"description": label, "metric": metric, "direction": direction,
                        "stimulus": stimulus, "theta_length": length, "theta_boundary": wall,
                        "grid": list(grid), "dt": dt, "mass_drift_without_reaction": drift,
                        "final": stats(directory)[-1]}
    destination = HERE / "results"
    destination.mkdir(exist_ok=True)
    (destination / "surfaces.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({k: {"mass_drift_without_reaction": v["mass_drift_without_reaction"], "active_final": v["final"]["active"]} for k, v in report.items()}, indent=2))
    if args.figure:
        figure(runs, destination / "surfaces.png")


def figure(runs, path):
    """Display only: the unwrapped activator on each surface at four times."""
    import numpy as np
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fractions = [1/12, 1/6, 1/4, 1/3]  # t = 5, 10, 15, 20: the fronts and their curled ends before they reach the walls
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 9, "savefig.facecolor": "#fafafa", "figure.facecolor": "#fafafa"})
    fig, axes = plt.subplots(len(runs), len(fractions), figsize=(14, 2.6 * len(runs)), layout="constrained")
    for row, (name, (directory, dt, steps, every)) in enumerate(runs.items()):
        length = SURFACES[name][4]
        for col, fraction in enumerate(fractions):
            step = min((k * every for k in range(steps // every + 1)), key=lambda s: abs(s - fraction * steps))
            grid = np.array(load(directory, step))
            if SURFACES[name][5] == "periodic":
                grid = np.roll(grid, (grid.shape[0] // 2, grid.shape[1] // 2), axis=(0, 1))
                extent = (-180, 180, -180, 180)
            else:
                grid = np.roll(grid, grid.shape[1] // 2, axis=1)
                extent = (-180, 180, 0, length)
            ax = axes[row, col]
            ax.imshow(grid, origin="lower", extent=extent, aspect="auto", cmap="magma", vmin=-2.1, vmax=2.1, interpolation="bilinear")
            ax.set_title("t = %g" % (step * dt), fontsize=9)
            if col == 0:
                ax.set_ylabel(SURFACES[name][0].split(" (")[0] + "\n" + SURFACES[name][6], fontsize=8)
            if row == len(runs) - 1:
                ax.set_xlabel("phi (degrees)")
    fig.suptitle("One excitable-wave program, four surfaces (only the geometry lines differ)", fontsize=13, fontweight="bold")
    fig.savefig(path, dpi=140)


if __name__ == "__main__":
    main()
