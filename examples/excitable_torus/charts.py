#!/usr/bin/env python3
"""Chart independence: the model in the orthogonal chart (theta, phi) and in
the sheared chart (theta, psi) with phi = psi + theta, on commensurate grids.

Both programs go through the normal pipeline; this script only builds, runs,
maps one grid onto the other (phi index = psi index + 2 theta index when the
psi grid is twice as fine as the theta grid) and compares the saved fields.
The smooth diffusion case gives a convergence order; the excitable case is
rendered for the gallery.
"""
import argparse
import json
from pathlib import Path
import re
import struct
import subprocess

from run import HERE, ROOT, NAME, build, run, call

TWISTED = "excitable_torus_twisted"


def build_twisted(directory, grid, overrides=None):
    """Build the sheared-chart program; mirrors run.build for the other source."""
    directory = Path(directory).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    source = (HERE / (TWISTED + ".fme")).read_text()
    for key, value in (overrides or {}).items():
        source, count = re.subn(r"^param " + re.escape(key) + r" = .*$",
                                "param " + key + " = " + str(value), source, flags=re.MULTILINE)
        if count != 1:
            raise ValueError("unknown or repeated parameter: " + key)
    model = directory / (TWISTED + ".fme")
    model.write_text(source)
    (directory / (TWISTED + ".yaml")).write_text("\n".join([
        "length_per_node: [6.283185307179586, 6.283185307179586]",
        "grid_per_node: " + json.dumps(list(grid)),
        "mpi_shape: [1, 1]",
        "boundary: [periodic, periodic]",
        "reduces: [umin = min u, umax = max u, vmin = min v, vmax = max v, mass = sum mass, square = sum square, active = sum active]",
    ]) + "\n")
    import os
    env = dict(os.environ, EGISON_HEAP_LIMIT=os.environ.get("EGISON_HEAP_LIMIT", "1G"))
    egison = Path(os.environ.get("EGISON_DIR", ROOT.parent / "egison")).resolve()
    call(["cabal", "run", "-v0", "formurae-pre", "--", model], directory, "pre", env, directory / (TWISTED + ".egi"))
    call([ROOT / "tools/run_formurae_normalization.sh", egison, directory / (TWISTED + ".egi")],
         directory, "egison", env, directory / (TWISTED + ".feir"))
    call(["cabal", "run", "-v0", "formurae-post", "--", directory / (TWISTED + ".feir")],
         directory, "post", env, directory / (TWISTED + ".fmr"))
    formura = os.environ.get("FORMURA", str(ROOT / "bin/formura"))
    with (directory / "formura.log").open("w") as log:
        subprocess.run([formura, TWISTED + ".fmr"], cwd=directory, stdout=log, stderr=subprocess.STDOUT, check=True)
    # The same driver with the second axis renamed: psi instead of phi.
    driver = (HERE / "driver.c").read_text().replace('"excitable_torus.h"', '"' + TWISTED + '.h"')
    driver = re.sub(r"\b(lower|upper|offset|total_grid)_phi\b", r"\1_psi", driver)
    (directory / "driver.c").write_text(driver)
    call([os.environ.get("CC", "cc"), "-O2", "-std=c11", "-I" + str(directory), "-I" + str(ROOT / "mpistub"),
          directory / "driver.c", directory / (TWISTED + ".c"), "-lm", "-o", directory / "check"], directory, "cc", env)
    (directory / "metadata.json").write_text(json.dumps({"chart": "sheared", "grid": list(grid)}, indent=2) + "\n")
    return directory


def fields(directory, step):
    result = {}
    for path in (directory / "data").glob(f"frame-{step:07d}-rank-*.bin"):
        data = path.read_bytes()
        nx, ny, stamp = struct.unpack_from("=iii", data)
        assert stamp == step
        for i, j, u, v in struct.iter_unpack("=iidd", data[12:]):
            result[i, j] = (u, v)
    assert len(result) == nx * ny
    return nx, ny, result


def compare(orthogonal, sheared, step):
    nx, ny, uo = fields(orthogonal, step)
    nx2, ny2, ut = fields(sheared, step)
    assert (nx, ny) == (nx2, ny2) and ny % nx == 0
    shift = ny // nx  # dtheta = shift * dpsi, so phi index = psi index + shift * theta index
    differences = [abs(ut[i, j][0] - uo[i, (j + shift * i) % ny][0]) for i in range(nx) for j in range(ny)]
    return {"max": max(differences), "rms": (sum(d*d for d in differences) / len(differences)) ** 0.5}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".build/excitable_torus/charts")
    parser.add_argument("--time", type=float, default=6.0)
    parser.add_argument("--figure", action="store_true", help="also draw results/charts.png (needs numpy and matplotlib)")
    args = parser.parse_args()
    report = {}
    # 1. Smooth diffusion (no reaction, smooth initial value): second-order agreement.
    report["diffusion"] = []
    for n, dt, steps in ((128, 0.005, 800), (256, 0.00125, 3200)):
        overrides = {"reaction": "0", "stimulus": "0", "dt": str(dt)}
        orthogonal = build(args.output / f"orthogonal-diffusion-{n}", "oblique", (n, 2*n), blocking=0, overrides=overrides)
        run(orthogonal, steps, steps)
        sheared = build_twisted(args.output / f"sheared-diffusion-{n}", (n, 2*n), overrides=overrides)
        run(sheared, steps, steps)
        result = compare(orthogonal, sheared, steps) | {"grid": [n, 2*n], "time": steps*dt}
        report["diffusion"].append(result)
    coarse, fine = report["diffusion"]
    report["diffusion_convergence_ratio"] = coarse["max"] / fine["max"]
    assert 3.0 < report["diffusion_convergence_ratio"] < 5.0, report
    # 2. The excitable case: sharp fronts, so the two discretizations are
    #    compared at two resolutions (the finer grid needs a tenth of the time step).
    report["excitable"] = []
    runs = {}
    for n, dt in ((128, 0.005), (256, 0.0005)):
        steps = int(round(args.time / dt))
        orthogonal = build(args.output / f"orthogonal-excitable-{n}", "oblique", (n, 2*n), blocking=0, overrides={"dt": str(dt)})
        run(orthogonal, steps, steps)
        sheared = build_twisted(args.output / f"sheared-excitable-{n}", (n, 2*n), overrides={"dt": str(dt)})
        run(sheared, steps, steps)
        runs[n] = (orthogonal, sheared, steps)
        report["excitable"].append(compare(orthogonal, sheared, steps) | {"grid": [n, 2*n], "time": steps*dt})
    destination = HERE / "results"
    destination.mkdir(exist_ok=True)
    (destination / "charts.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    if args.figure:
        figure(runs[128], report, destination / "charts.png")


def figure(triple, report, path):
    """Display only: the field in each chart and the mapped difference."""
    import numpy as np
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    orthogonal, sheared, steps = triple
    nx, ny, uo = fields(orthogonal, steps)
    _, _, ut = fields(sheared, steps)
    shift = ny // nx
    grid_o = np.array([[uo[i, j][0] for j in range(ny)] for i in range(nx)])
    grid_t = np.array([[ut[i, j][0] for j in range(ny)] for i in range(nx)])
    mapped = np.array([[uo[i, (j + shift*i) % ny][0] for j in range(ny)] for i in range(nx)])
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 10, "savefig.facecolor": "#fafafa", "figure.facecolor": "#fafafa"})
    fig, axes = plt.subplots(1, 3, figsize=(15, 4.4), layout="constrained")
    kw = dict(origin="lower", extent=(-180, 180, -180, 180), aspect="auto", cmap="magma", vmin=-2.1, vmax=2.1, interpolation="bilinear")
    axes[0].imshow(np.roll(grid_o, (nx//2, ny//2), axis=(0, 1)), **kw)
    axes[0].set(title="Orthogonal chart (θ, φ)", xlabel="phi (degrees)", ylabel="theta (degrees)")
    axes[1].imshow(np.roll(grid_t, (nx//2, ny//2), axis=(0, 1)), **kw)
    axes[1].set(title="Sheared chart (θ, ψ), φ = ψ + θ", xlabel="psi (degrees)", ylabel="theta (degrees)")
    image = axes[2].imshow(np.roll(np.abs(grid_t - mapped), (nx//2, ny//2), axis=(0, 1)), origin="lower", extent=(-180, 180, -180, 180), aspect="auto", cmap="viridis", interpolation="bilinear")
    axes[2].set(title="|difference| after mapping ψ → φ", xlabel="psi (degrees)", ylabel="theta (degrees)")
    fig.colorbar(image, ax=axes[2], fraction=0.046)
    fig.suptitle("The same excitable-wave program in two charts of the torus, t = %.0f" % report["excitable"][0]["time"], fontsize=14, fontweight="bold")
    fig.savefig(path, dpi=140)


if __name__ == "__main__":
    main()
