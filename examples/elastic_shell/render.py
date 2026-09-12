#!/usr/bin/env python3
"""Render saved solver output; all NumPy computations here are for display.

Requires numpy and matplotlib.  The slices, the shell moments, and the
energies are recorded by the generated solver (run.py); this script maps grid
points of the equatorial plane to physical positions, colors the two wave
indicators, and writes the figure, the plot data, and a record of the runs.
Nothing here feeds back into a simulation.
"""
import argparse
import csv
import hashlib
import json
import math
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.colors import LinearSegmentedColormap, PowerNorm
from matplotlib.font_manager import FontProperties
from matplotlib.patches import Circle, PathPatch
from matplotlib.path import Path as MplPath

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
INNER, OUTER = 1.0, 2.0
SLICE = np.dtype([("i", "=i4"), ("j", "=i4"), ("k", "=i4"), ("compression", "=f8"),
                  ("shearing", "=f8"), ("v1", "=f8"), ("v2", "=f8"), ("v3", "=f8")])
JAPANESE = Path("/usr/local/texlive/2025/texmf-dist/fonts/opentype/public/haranoaji/HaranoAjiMincho-Regular.otf")
TEXT = {
    "en": {"rows": ["Spherical coordinates", "Non-orthogonal coordinates"],
           "columns": ["$t = 0.4$", "$t = 0.8$", "$t = 0.8$, anisotropic material"],
           "p": "P wave: $a\\,|\\nabla\\cdot v|/V_0$", "s": "S wave: $a\\,|\\nabla\\times v|/V_0$",
           "legend": "black circles: the walls $R = 1$ and $R = 2$; dashed circles: radii $c_P t$ and $c_S t$; black dot: source; thin lines: every 16th grid line"},
    "ja": {"rows": ["球座標", "非直交座標"],
           "columns": ["$t = 0.4$", "$t = 0.8$", "$t = 0.8$，異方性材料"],
           "p": "P 波：$a\\,|\\nabla\\cdot v|/V_0$", "s": "S 波：$a\\,|\\nabla\\times v|/V_0$",
           "legend": "黒い円：壁 $R = 1$ と $R = 2$；破線円：半径 $c_P t$ と $c_S t$；黒点：波源；細線：16 本ごとの格子線"},
}
RED = LinearSegmentedColormap.from_list("p", [(1, 1, 1), (0.85, 0.1, 0.1)])
BLUE = LinearSegmentedColormap.from_list("s", [(1, 1, 1), (0.1, 0.3, 0.85)])
# colors follow the square root of each indicator up to its limit, so that the
# weaker, spreading shells at the later time stay visible on one fixed scale
LIMITS = {"p": 0.2, "s": 0.5}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load_slice(directory, step):
    """The equatorial plane: arrays indexed by (radial node, longitude cell)."""
    n = None
    fields = {}
    for path in sorted((directory / "data").glob(f"slice-{step:07d}-rank-*.bin")):
        with path.open("rb") as file:
            nr, nt, np_, stamp, full = np.fromfile(file, dtype="=i4", count=5)
            assert stamp == step and full == 0
            data = np.fromfile(file, dtype=SLICE)
        if n is None:
            n = (nr, np_)
            fields = {name: np.full(n, np.nan) for name in SLICE.names[3:]}
        assert (data["j"] == nt // 2).all()
        for name in fields:
            fields[name][data["i"], data["k"]] = data[name]
    if n is None or not all(np.isfinite(f).all() for f in fields.values()):
        raise ValueError(f"missing or invalid slice: {directory}, step {step}")
    return fields


def metadata(directory):
    return json.loads((directory / "metadata.json").read_text())


def time_step(meta):
    # dt = c * dr with dr = 1 / (nr - 1)
    return float(meta["parameters"]["dt"].split("*")[0]) / (meta["grid"][0] - 1)


def source(meta):
    p = meta["parameters"]
    return float(p["x0"]), float(p["y0"])


def positions(meta, nr, np_):
    """Physical positions of the nodes (i, k) of the equatorial plane and of
    the cell corners around them: radius 1 + i dr, longitude k dphi + twist i dr."""
    twist = float(meta["parameters"]["twist"])
    dr, dphi = 1.0 / (nr - 1), 2 * math.pi / np_
    i, k = np.meshgrid(np.arange(nr), np.arange(np_), indexing="ij")
    r, phi = i * dr, k * dphi + twist * i * dr
    ic, kc = np.meshgrid(np.arange(nr + 1) - 0.5, np.arange(np_ + 1) - 0.5, indexing="ij")
    rc = np.clip(ic * dr, 0.0, 1.0)          # the wall nodes own half cells
    phic = kc * dphi + twist * rc
    return (INNER + r, phi), (INNER + rc, phic)


def rgb(p, s):
    # white background; P in red, S in blue; square-root scale up to the limits
    p = np.sqrt(np.clip(p / LIMITS["p"], 0, 1))
    s = np.sqrt(np.clip(s / LIMITS["s"], 0, 1))
    colors = np.ones(p.shape + (3,))
    colors *= RED(p)[..., :3]
    colors *= BLUE(s)[..., :3]
    return colors


def annulus_path():
    outer = MplPath.circle((0, 0), OUTER)
    inner = MplPath.circle((0, 0), INNER)
    return MplPath(np.concatenate([outer.vertices, inner.vertices[::-1]]),
                   np.concatenate([outer.codes, inner.codes]))


def panel(ax, directory, step, radius, circles, grid_every=16):
    meta = metadata(directory)
    fields = load_slice(directory, step)
    nr, np_ = fields["compression"].shape
    (r, phi), (rc, phic) = positions(meta, nr, np_)
    p = radius * np.abs(fields["compression"])
    s = radius * fields["shearing"]
    colors = rgb(p, s)
    mesh = ax.pcolormesh(rc * np.cos(phic), rc * np.sin(phic), np.zeros((nr, np_)), shading="flat",
                         edgecolors="none", rasterized=True)
    mesh.set_array(None)
    mesh.set_facecolor(colors.reshape(-1, 3))
    # grid lines: circles of constant radius and the longitude lines, which
    # wind with the radius in the twisted chart; the walls in black
    for start in list(range(0, nr, grid_every)):
        ax.plot(r[start, :].tolist() * 0 + r[start, 0] * np.cos(np.append(phi[start, :], phi[start, 0] + 2 * math.pi)),
                r[start, 0] * np.sin(np.append(phi[start, :], phi[start, 0] + 2 * math.pi)), color="0.55", lw=0.35)
    for start in range(0, np_, grid_every):
        ax.plot(r[:, start] * np.cos(phi[:, start]), r[:, start] * np.sin(phi[:, start]), color="0.55", lw=0.35)
    for wall in (INNER, OUTER):
        ax.add_patch(Circle((0, 0), wall, fill=False, color="black", lw=0.7))
    x0, y0 = source(meta)
    clip = PathPatch(annulus_path(), transform=ax.transData, visible=False)
    ax.add_patch(clip)
    for c in circles:
        arc = Circle((x0, y0), c, fill=False, color="black", lw=0.7, ls=(0, (4, 3)))
        ax.add_patch(arc)
        arc.set_clip_path(clip)
    ax.plot([x0], [y0], "k.", ms=4)
    ax.set(xlim=(-OUTER - 0.02, OUTER + 0.02), ylim=(-OUTER - 0.02, OUTER + 0.02), aspect="equal",
           xticks=[], yticks=[])
    ax.axis("off")
    return p.max(), s.max()


def figure(runs, lang, output):
    text = TEXT[lang]
    font = FontProperties(fname=str(JAPANESE)) if lang == "ja" and JAPANESE.exists() else None
    meta = metadata(runs["spherical"])
    # dt = 0.05 dr: the snapshots t = 0.4 and 0.8 are steps 8 (nr - 1) and 16 (nr - 1)
    steps = (8 * (meta["grid"][0] - 1), 16 * (meta["grid"][0] - 1))
    radius = float(meta["parameters"]["radius"])
    dt = time_step(meta)
    speeds = (2.0, 1.0)      # lambda = 2, mu = rho0 = 1
    fig, axes = plt.subplots(2, 3, figsize=(7.0, 5.15))
    maxima = {}
    for row, case in enumerate(("spherical", "twisted")):
        for column, (key, step) in enumerate([(case, steps[0]), (case, steps[1]),
                                              (case + "-anisotropic", steps[1])]):
            t = step * dt
            circles = [c * t for c in speeds] if column < 2 else []
            maxima[key, step] = panel(axes[row, column], runs[key], step, radius, circles)
            if row == 0:
                axes[row, column].set_title(text["columns"][column], fontsize=9, fontproperties=font)
        axes[row, 0].text(-OUTER - 0.15, 0, text["rows"][row], fontsize=9, fontproperties=font,
                          rotation=90, ha="center", va="center")
    fig.subplots_adjust(left=0.05, right=0.99, top=0.945, bottom=0.175, wspace=0.05, hspace=0.06)
    for k, (cmap, label, limit) in enumerate(((RED, text["p"], LIMITS["p"]), (BLUE, text["s"], LIMITS["s"]))):
        cax = fig.add_axes([0.10 + 0.47 * k, 0.105, 0.33, 0.018])
        bar = matplotlib.colorbar.ColorbarBase(cax, cmap=cmap, orientation="horizontal",
                                               norm=PowerNorm(0.5, 0, limit))
        bar.set_label(label, fontsize=8, fontproperties=font, labelpad=2)
        bar.ax.tick_params(labelsize=7)
    fig.text(0.5, 0.012, text["legend"], ha="center", fontsize=7.5, fontproperties=font)
    fig.savefig(output, dpi=220)
    plt.close(fig)
    return {f"{key}-{step}": {"p_max": float(p), "s_max": float(s)} for (key, step), (p, s) in maxima.items()}


def stats(directory):
    with (directory / "stats.csv").open() as file:
        return [{k: float(v) for k, v in row.items()} for row in csv.DictReader(file)]


def radii(directory):
    dt = time_step(metadata(directory))
    rows = []
    for r in stats(directory)[1:]:
        # diagnostics are evaluated on the state entering each step
        rows.append(((r["step"] - 1) * dt, r["pfront"], r["sfront"], r["pr"] / r["pw"], r["sr"] / r["sw"],
                     r["energy"], r["modified"]))
    return rows


def slope(points):
    t = np.array([p[0] for p in points])
    r = np.array([p[1] for p in points])
    return float(np.polyfit(t, r, 1)[0])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=Path, default=ROOT / ".build/elastic_shell/demo")
    parser.add_argument("--output", type=Path, default=HERE / "results")
    args = parser.parse_args()
    runs = {name: args.runs / name for name in ("spherical", "twisted", "spherical-anisotropic", "twisted-anisotropic")}
    args.output.mkdir(exist_ok=True)
    record = {"runs": {}, "figures": {}}
    for name, directory in runs.items():
        meta = metadata(directory)
        entry = {"metadata": meta, "stats_sha256": sha(directory / "stats.csv")}
        if "anisotropic" not in name:
            table = radii(directory)
            # speeds: slopes of the outer shell radii (farthest points where the
            # dimensionless indicators exceed 0.01) over 0.3 <= t <= 0.7
            entry["p_speed"] = slope([(t, pf) for t, pf, _, _, _, _, _ in table if 0.3 <= t <= 0.7])
            entry["s_speed"] = slope([(t, sf) for t, _, sf, _, _, _, _ in table if 0.3 <= t <= 0.7])
            energies = [e for _, _, _, _, _, e, _ in table]
            modified = [m for _, _, _, _, _, _, m in table]
            entry["energy_band"] = [min(energies) / energies[0], max(energies) / energies[0]]
            entry["modified_energy_relative_drift"] = max(abs(m - modified[0]) for m in modified) / modified[0]
            with (args.output / f"radii-{name}.dat").open("w") as file:
                file.write("t pf sf rp rs energy modified\n")
                for row in table:
                    file.write(" ".join(repr(v) for v in row) + "\n")
            if name == "spherical":
                # guide lines of slopes 2 and 1 through the first sample at t >= 0.3
                t0, pf0, sf0 = next((t, pf, sf) for t, pf, sf, _, _, _, _ in table if t >= 0.3)
                with (args.output / "guides.dat").open("w") as file:
                    file.write("t p s\n")
                    for t in (t0, 0.8):
                        file.write(f"{t!r} {pf0 + 2 * (t - t0)!r} {sf0 + (t - t0)!r}\n")
        record["runs"][name] = entry
    # agreement of the two coordinate systems on the same physical shell
    tables = {name: radii(runs[name]) for name in ("spherical", "twisted")}
    record["chart_agreement"] = {
        key: max(abs(a[column] - b[column]) for a, b in zip(tables["spherical"], tables["twisted"]) if 0.3 <= a[0] <= 0.7)
        for key, column in (("p_front_max_difference", 1), ("s_front_max_difference", 2),
                            ("p_mean_radius_max_difference", 3), ("s_mean_radius_max_difference", 4))}
    record["chart_agreement"]["energy_relative"] = max(
        abs(a[5] - b[5]) / a[5] for a, b in zip(tables["spherical"], tables["twisted"]))
    grid = metadata(runs["spherical"])["grid"]
    record["grid_spacing"] = {"radial": 1.0 / (grid[0] - 1), "colatitude_at_outer_wall": OUTER * (math.pi - 2 * math.atan(2)) / (grid[1] - 1),
                              "longitude_at_outer_wall": OUTER * 2 * math.pi / grid[2]}
    for lang in ("en", "ja"):
        output = args.output / f"elastic-shell-{lang}.png"
        record["figures"][lang] = {"maxima": figure(runs, lang, output), "sha256": sha(output)}
    (args.output / "runs.json").write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps({k: {kk: vv for kk, vv in v.items() if kk != "metadata"} for k, v in record["runs"].items()}, indent=2))


if __name__ == "__main__":
    main()
