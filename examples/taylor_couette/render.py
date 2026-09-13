#!/usr/bin/env python3
"""Render a saved Taylor-Couette run; every NumPy computation here is for display.

Requires numpy and matplotlib.  The records (meridional plane per rank,
reductions per interval) are written by the generated solver through run.py;
this script merges the ranks, subtracts the laminar Couette profile for the
color map, draws the meridional velocity, fits the growth of the perturbation,
and writes the figure and a record of the run.  Nothing here feeds back into
a simulation.
"""
import argparse
import csv
import json
import math
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager
from matplotlib.font_manager import FontProperties

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
R1, R2, W1, W2 = 1.0, 2.0, 1.0, 0.0
RECORD = np.dtype([("i", "=i4"), ("j", "=i4"), ("ut", "=f8"), ("ur", "=f8"),
                   ("uz", "=f8"), ("p", "=f8")])
JAPANESE = Path("/usr/local/texlive/2025/texmf-dist/fonts/opentype/public/haranoaji/HaranoAjiMincho-Regular.otf")
TEXT = {
    "en": {"dev": "azimuthal velocity minus the Couette profile, $u_\\theta - (Ar + B/r)$",
           "speed": "meridional speed $\\sqrt{u_r^2 + u_z^2}$ and streamlines",
           "growth": "growth of the perturbation: $\\max|u_r|$",
           "profile": "radial velocity at mid gap, $u_r(r = 1.5, z)$",
           "time": "time $t$", "z": "$z$", "r": "$r$",
           "fit": "fit $e^{\\sigma t}$, $\\sigma$ = %.4f",
           "title": "Axisymmetric Taylor-Couette flow at Re = %g: Taylor vortices from the Couette flow (t = %g)"},
    "ja": {"dev": "周方向速度とクエット解の差 $u_\\theta - (Ar + B/r)$",
           "speed": "子午面の速さ $\\sqrt{u_r^2 + u_z^2}$ と流線",
           "growth": "擾乱の成長：$\\max|u_r|$",
           "profile": "隙間中央の半径方向速度 $u_r(r = 1.5, z)$",
           "time": "時間 $t$", "z": "$z$", "r": "$r$",
           "fit": "当てはめ $e^{\\sigma t}$，$\\sigma$ = %.4f",
           "title": "軸対称テイラー・クエット流れ，Re = %g：クエット流れから育つテイラー渦（t = %g）"},
}


def metadata(directory):
    return json.loads((directory / "metadata.json").read_text())


def load(directory, step):
    """The meridional plane at one step: arrays indexed by (radial slot, axial cell)."""
    shape = None
    fields = {}
    for path in sorted((directory / "data").glob(f"state-{step:07d}-rank-*.bin")):
        with path.open("rb") as file:
            nr, nz, stamp = np.fromfile(file, dtype="=i4", count=3)
            assert stamp == step
            data = np.fromfile(file, dtype=RECORD)
        if shape is None:
            shape = (nr, nz)
            fields = {name: np.full(shape, np.nan) for name in RECORD.names[2:]}
        for name in fields:
            fields[name][data["i"], data["j"]] = data[name]
    if shape is None or not all(np.isfinite(f).all() for f in fields.values()):
        raise ValueError(f"missing or invalid records: {directory}, step {step}")
    return fields


def stats(directory):
    with (directory / "stats.csv").open() as file:
        rows = list(csv.DictReader(file))
    return {key: np.array([float(row[key]) for row in rows]) for key in rows[0]}


def couette(r):
    a = (W2 * R2 ** 2 - W1 * R1 ** 2) / (R2 ** 2 - R1 ** 2)
    b = (W1 - W2) * R1 ** 2 * R2 ** 2 / (R2 ** 2 - R1 ** 2)
    return a * r + b / r


def growth_rate(t, amplitude):
    """Slope of log amplitude over the part of the record between 3 and 30
    times the initial amplitude (the linear regime)."""
    a0 = amplitude[0]
    mask = (amplitude > 3 * a0) & (amplitude < 30 * a0) & (amplitude > 0)
    if mask.sum() < 3:
        return float("nan"), float("nan"), mask
    slope, intercept = np.polyfit(t[mask], np.log(amplitude[mask]), 1)
    return float(slope), float(intercept), mask


def exponent(t, amplitude):
    """Slope of log amplitude over the middle of a record (20 % to 60 % of
    the time), which covers the linear regime of a growing or decaying
    perturbation after the initial adjustment."""
    mask = (t >= 0.2 * t[-1]) & (t <= 0.6 * t[-1]) & (amplitude > 0)
    if mask.sum() < 3:
        return float("nan")
    slope, _ = np.polyfit(t[mask], np.log(amplitude[mask]), 1)
    return float(slope)


def figure(directory, lang, out):
    meta = metadata(directory)
    dt, lz = meta["dt"], meta["lz"]
    nr, nz = meta["grid"]
    dr, dz = (R2 - R1) / (nr - 1), lz / nz
    final = meta["steps"]
    fields = load(directory, final)
    text = TEXT[lang]
    # every label of the Japanese figure uses the Japanese font (registered
    # once); the English figure uses matplotlib's default
    plt.rcdefaults()
    font = None
    if lang == "ja" and JAPANESE.exists():
        font_manager.fontManager.addfont(str(JAPANESE))
        font = FontProperties(fname=str(JAPANESE))
        plt.rcParams["font.family"] = font.get_name()
    # cell centres (r) x cell centres (z) for the scalars; the faces carry
    # the velocity components, which are averaged to the cell centres for
    # display only
    rc = R1 + (np.arange(nr - 1) + 0.5) * dr
    zc = (np.arange(nz) + 0.5) * dz
    ut = fields["ut"][:-1, :]
    ur_face = fields["ur"]                 # faces 0..nr-1 (wall to wall)
    uz_face = fields["uz"][:-1, :]         # z-faces of the cells inside the gap
    ur = 0.5 * (ur_face[:-1, :] + ur_face[1:, :])
    uz = 0.5 * (uz_face + np.roll(uz_face, -1, axis=1))
    dev = ut - couette(rc)[:, None]
    speed = np.hypot(ur, uz)
    rec = stats(directory)
    t = rec["step"] * dt
    sigma, intercept, window = growth_rate(t, rec["ur"])

    fig, axes = plt.subplots(2, 2, figsize=(13.5, 8.2), gridspec_kw={"width_ratios": [1.9, 1]})
    extent = [0, lz, R1, R2]
    ax = axes[0, 0]
    limit = np.abs(dev).max() or 1.0
    im = ax.imshow(dev, origin="lower", extent=extent, aspect="equal", cmap="RdBu_r",
                   vmin=-limit, vmax=limit, interpolation="nearest")
    fig.colorbar(im, ax=ax, fraction=0.025, pad=0.02)
    ax.set_title(text["dev"], fontproperties=font)
    ax.set_xlabel(text["z"]); ax.set_ylabel(text["r"])
    ax = axes[1, 0]
    im = ax.imshow(speed, origin="lower", extent=extent, aspect="equal", cmap="viridis",
                   interpolation="nearest")
    fig.colorbar(im, ax=ax, fraction=0.025, pad=0.02)
    zz, rr = np.meshgrid(zc, rc)
    ax.streamplot(zz, rr, uz, ur, color="white", density=(1.6, 0.6), linewidth=0.7, arrowsize=0.8)
    ax.set_xlim(0, lz); ax.set_ylim(R1, R2)
    ax.set_title(text["speed"], fontproperties=font)
    ax.set_xlabel(text["z"]); ax.set_ylabel(text["r"])
    ax = axes[0, 1]
    ax.semilogy(t, rec["ur"], "k.-", ms=3, lw=0.8)
    if math.isfinite(sigma):
        # the fitted exponential, drawn over the fitting window and a little beyond
        lo, hi = t[window].min(), t[window].max()
        span = np.linspace(max(0.0, lo - 0.3 * (hi - lo)), hi + 0.3 * (hi - lo), 50)
        ax.semilogy(span, np.exp(intercept + sigma * span), "r--", lw=1, label=text["fit"] % sigma)
        ax.legend(prop=font, loc="lower right")
    ax.set_title(text["growth"], fontproperties=font)
    ax.set_xlabel(text["time"]); ax.grid(alpha=0.3)
    ax = axes[1, 1]
    mid = (nr - 1) // 2
    ax.plot(zc, ur[mid, :], "b-", lw=1.2)
    ax.axhline(0, color="gray", lw=0.6)
    ax.set_title(text["profile"], fontproperties=font)
    ax.set_xlabel(text["z"]); ax.set_xlim(0, lz); ax.grid(alpha=0.3)
    fig.suptitle(text["title"] % (meta["re"], final * dt), fontproperties=font)
    fig.tight_layout()
    fig.savefig(out, dpi=110)
    plt.close(fig)
    return {"growth_rate": sigma, "max_ur": float(rec["ur"][-1]), "max_uz": float(rec["uz"][-1]),
            "max_deviation": float(limit), "final_residual": float(rec["res"][-1]),
            "final_divergence": float(rec["div"][-1])}


def wavelength(directory):
    """Dominant axial wavelength of the radial velocity at mid gap (display only)."""
    meta = metadata(directory)
    fields = load(directory, meta["steps"])
    nr, nz = meta["grid"]
    mid = (nr - 1) // 2
    line = fields["ur"][mid, :]
    spectrum = np.abs(np.fft.rfft(line - line.mean()))
    k = int(np.argmax(spectrum[1:]) + 1)
    return meta["lz"] / k, k


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, default=ROOT / ".build/taylor_couette/demo")
    parser.add_argument("--results", type=Path, default=HERE / "results")
    parser.add_argument("--bracket", type=Path, nargs="*", default=[],
                        help="further runs whose growth or decay rate is recorded (below and above the threshold)")
    args = parser.parse_args()
    args.results.mkdir(parents=True, exist_ok=True)
    record = {"run": str(args.run), "metadata": metadata(args.run)}
    record["bracket"] = []
    for run in args.bracket:
        meta, rec = metadata(run), stats(run)
        t = rec["step"] * meta["dt"]
        record["bracket"].append({"run": str(run), "re": meta["re"], "grid": meta["grid"],
                                  "rate": exponent(t, rec["ur"]),
                                  "initial_max_ur": float(rec["ur"][0]),
                                  "final_max_ur": float(rec["ur"][-1]), "final_time": float(t[-1])})
    for lang in ("en", "ja"):
        record.update(figure(args.run, lang, args.results / f"taylor-couette-{lang}.png"))
    lam, k = wavelength(args.run)
    record.update(axial_wavelength=lam, axial_pairs=k)
    (args.results / "runs.json").write_text(json.dumps(record, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({key: record[key] for key in record if key != "metadata"}, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
