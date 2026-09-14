#!/usr/bin/env python3
"""Render a saved Taylor-Couette run; every NumPy computation here is for display.

Requires numpy and matplotlib.  The records (meridional plane per rank,
reductions per interval) are written by the generated solver through run.py;
this script merges the ranks, draws the meridional velocity and animated
circumferential speed indicators, fits the growth of the perturbation, and
writes figures, videos, and a record of the run. Nothing here feeds back into
a simulation.
"""
import argparse
import csv
import json
import math
import os
from pathlib import Path
import shutil
import subprocess

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager
from matplotlib.font_manager import FontProperties
from matplotlib.collections import LineCollection
from matplotlib.patches import Circle
from matplotlib import patheffects as path_effects

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
           "title": "Axisymmetric Taylor-Couette flow at Re = %g: Taylor vortices from the Couette flow (t = %g)",
           "views": "Rotation around the cylinders and circulation in the longitudinal slice",
           "endview": "View from $+z$ (section at $z$ = %g)",
           "inner": "Inner cylinder\nrotating CCW\n$\\Omega_1 = 1$",
           "outer": "Outer cylinder: stationary",
           "azimuthal": "azimuthal velocity $u_\\theta$",
           "section": "section at left",
           "glyphs": "Moving arrows indicate rotation at fixed radii: $d\\theta/dt = u_\\theta/r$ (not particle trajectories).",
           "sampling": "%g times simulation speed  |  %d fps  |  saved velocities interpolated for display",
           "video": "Taylor-Couette flow at Re = %g, $t$ = %5.1f"},
    "ja": {"dev": "周方向速度とクエット解の差 $u_\\theta - (Ar + B/r)$",
           "speed": "子午面の速さ $\\sqrt{u_r^2 + u_z^2}$ と流線",
           "growth": "擾乱の成長：$\\max|u_r|$",
           "profile": "隙間中央の半径方向速度 $u_r(r = 1.5, z)$",
           "time": "時間 $t$", "z": "$z$", "r": "$r$",
           "fit": "当てはめ $e^{\\sigma t}$，$\\sigma$ = %.4f",
           "title": "軸対称テイラー・クエット流れ，Re = %g：クエット流れから育つテイラー渦（t = %g）",
           "views": "円筒を回る周方向の運動と，縦断面内の循環を同時に表示",
           "endview": "円筒を $+z$ 側から見る（$z$ = %g）",
           "inner": "内筒\n反時計回り\n$\\Omega_1 = 1$",
           "outer": "外筒：静止",
           "azimuthal": "周方向速度 $u_\\theta$",
           "section": "左図の断面",
           "glyphs": "動く矢印は固定半径での回転速度 $d\\theta/dt = u_\\theta/r$ を表示（流体粒子の軌跡ではありません）",
           "sampling": "計算時間の %g 倍速  |  %d fps  |  保存した速度を描画用に補間",
           "video": "テイラー・クエット流れ，Re = %g，$t$ = %5.1f"},
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


def fonts(lang):
    """Every label of the Japanese figure uses the Japanese font (registered
    once); the English figure uses matplotlib's default."""
    plt.rcdefaults()
    font = None
    if lang == "ja" and JAPANESE.exists():
        font_manager.fontManager.addfont(str(JAPANESE))
        font = FontProperties(fname=str(JAPANESE))
        plt.rcParams["font.family"] = font.get_name()
    return font


def prepare(meta, fields):
    """Cell-centred arrays for display: the azimuthal velocity minus the
    Couette profile, the two meridional components averaged from the faces to
    the cell centres, and the meridional speed, with the cell coordinates."""
    nr, nz = meta["grid"]
    dr, dz = (R2 - R1) / (nr - 1), meta["lz"] / nz
    rc = R1 + (np.arange(nr - 1) + 0.5) * dr
    zc = (np.arange(nz) + 0.5) * dz
    ut = fields["ut"][:-1, :]
    ur_face = fields["ur"]                 # faces 0..nr-1 (wall to wall)
    uz_face = fields["uz"][:-1, :]         # z-faces of the cells inside the gap
    ur = 0.5 * (ur_face[:-1, :] + ur_face[1:, :])
    uz = 0.5 * (uz_face + np.roll(uz_face, -1, axis=1))
    dev = ut - couette(rc)[:, None]
    return rc, zc, dev, ur, uz, np.hypot(ur, uz)


def figure(directory, lang, out):
    meta = metadata(directory)
    dt, lz = meta["dt"], meta["lz"]
    nr, nz = meta["grid"]
    final = meta["steps"]
    fields = load(directory, final)
    text = TEXT[lang]
    font = fonts(lang)
    rc, zc, dev, ur, uz, speed = prepare(meta, fields)
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


def ffmpeg():
    return os.environ.get("FFMPEG") or shutil.which("ffmpeg")


def video(directory, lang, out, poster, fps=30, time_scale=6.0, poster_only=False):
    """Show circumferential motion alongside the meridional fields.

    Glyphs stay at fixed (r,z); only their display angle advances with the
    sampled u_theta/r. They indicate local rotation, not fluid trajectories.
    Saved velocities are linearly interpolated in time and in the displayed
    cross-section. No tracer, flow state, or solver input is evolved here.
    """
    if fps <= 0 or not math.isfinite(time_scale) or time_scale <= 0:
        raise ValueError("fps and time_scale must be positive")
    if not poster_only and not ffmpeg():
        raise RuntimeError("ffmpeg is required to render the video")
    meta = metadata(directory)
    dt, lz = meta["dt"], meta["lz"]
    steps = np.arange(0, meta["steps"] + 1, meta["output_interval"])
    times = steps * dt
    if len(times) < 2:
        raise ValueError("video requires at least two saved records")
    text = TEXT[lang]
    font = fonts(lang)
    plt.rcParams.update({"font.size": 12, "axes.titlesize": 14,
                         "axes.labelsize": 12, "xtick.labelsize": 11, "ytick.labelsize": 11})
    saved = [prepare(meta, load(directory, int(step))) for step in steps]
    rc, zc = saved[-1][:2]
    limit = np.abs(saved[-1][2]).max() or 1.0
    top = saved[-1][5].max() or 1.0
    z_slice = lz / 8
    # Cell-centre velocities, with the prescribed wall values at the ends.
    radius = np.r_[R1, rc, R2]
    profiles = np.array([
        np.r_[W1 * R1,
              [np.interp(z_slice, zc, row) for row in fields[2] + couette(rc)[:, None]],
              W2 * R2]
        for fields in saved
    ])
    rings = np.linspace(R1 + 0.11, R2 - 0.10, 5)
    angular = np.array([np.interp(rings, radius, row) / rings for row in profiles])
    # Integrate the interpolated angular speed only to animate the glyphs.
    phases = np.zeros_like(angular)
    phases[0] = np.linspace(0.1, 1.2, len(rings))
    phases[1:] = phases[0] + np.cumsum(
        np.diff(times)[:, None] * (angular[:-1] + angular[1:]) / 2, axis=0)
    frame_count = int(math.ceil(times[-1] / time_scale * fps)) + 1
    frame_times = np.linspace(0, times[-1], frame_count)
    max_rotation = max(abs(W1), abs(W2), float(np.abs(angular).max()))
    # Four marks on the inner cylinder repeat every pi/2. Stay well below
    # half that interval per frame, so apparent reverse rotation is avoided.
    if max_rotation * (frame_times[1] - frame_times[0]) > np.pi / 8:
        raise ValueError("rotation is undersampled; increase fps or reduce time_scale")

    fig = plt.figure(figsize=(14.4, 8.0), dpi=100)
    grid = fig.add_gridspec(2, 2, left=0.035, right=0.95, bottom=0.18, top=0.82,
                            width_ratios=[1.05, 1.6], wspace=0.24, hspace=0.50)
    end = fig.add_subplot(grid[:, 0])
    upper = fig.add_subplot(grid[0, 1])
    lower = fig.add_subplot(grid[1, 1])
    title = fig.suptitle("", y=0.97, fontsize=18, fontproperties=font)
    fig.text(0.5, 0.917, text["views"], ha="center", color="#475569", fontsize=13, fontproperties=font)
    fig.text(0.5, 0.055, text["glyphs"], ha="center", fontsize=11, color="#475569", fontproperties=font)
    fig.text(0.5, 0.025, text["sampling"] % (time_scale, fps), ha="center",
             fontsize=11, color="#475569", fontproperties=font)

    end.set_title(text["endview"] % z_slice, fontproperties=font, fontsize=14, pad=19)
    end.set_aspect("equal")
    end.set_xlim(-2.3, 2.3); end.set_ylim(-2.3, 2.3); end.axis("off")
    xy = np.linspace(-R2, R2, 320)
    xx, yy = np.meshgrid(xy, xy)
    radial = np.hypot(xx, yy)
    outside = (radial < R1) | (radial > R2)
    def annulus(profile):
        return np.ma.array(np.interp(radial, radius, profile), mask=outside)
    rotation = end.imshow(annulus(profiles[0]), extent=[-R2, R2, -R2, R2], origin="lower",
                          cmap="cividis", vmin=min(0.0, profiles.min()),
                          vmax=max(abs(W1 * R1), float(profiles.max())), interpolation="bilinear")
    for ring in rings:
        end.add_patch(Circle((0, 0), ring, fill=False, edgecolor="white", lw=0.7, alpha=0.25))
    end.add_patch(Circle((0, 0), R1, facecolor="#e2e8f0", edgecolor="#334155", lw=2, zorder=4))
    end.add_patch(Circle((0, 0), R2, fill=False, edgecolor="#334155", lw=2))
    ticks = np.arange(12) * 2 * np.pi / 12
    end.add_collection(LineCollection([
        np.c_[np.array([R2, R2 + 0.08]) * np.cos(angle),
              np.array([R2, R2 + 0.08]) * np.sin(angle)] for angle in ticks
    ], colors="#334155", linewidths=2))
    rotor, = end.plot([], [], color="#64748b", lw=4, solid_capstyle="round", zorder=5)
    end.text(0, 0, text["inner"], ha="center", va="center", fontproperties=font,
             fontsize=13, color="#1e293b", zorder=6)
    end.text(0, -2.29, text["outer"], ha="center", va="center", fontproperties=font,
             color="#334155", fontsize=12)
    cb = fig.colorbar(rotation, ax=end, orientation="horizontal", fraction=0.046, pad=0.085)
    cb.set_label(text["azimuthal"], fontproperties=font)
    tails = LineCollection([], colors="white", linewidths=1.4, zorder=7)
    end.add_collection(tails)
    arrows = end.quiver(np.zeros(15), np.zeros(15), np.zeros(15), np.zeros(15),
                        color="white", angles="xy", scale_units="xy", scale=1,
                        width=0.007, headwidth=3.6, headlength=4.2, pivot="tip", zorder=8)
    arrows.set_path_effects([path_effects.withStroke(linewidth=1.0, foreground="#334155")])

    extent = [0, lz, R1, R2]
    deviation = upper.imshow(saved[0][2], origin="lower", extent=extent, aspect="equal",
                             cmap="RdBu_r", vmin=-limit, vmax=limit, interpolation="nearest")
    meridional = lower.imshow(saved[0][5], origin="lower", extent=extent, aspect="equal",
                              cmap="viridis", vmin=0, vmax=top, interpolation="nearest")
    fig.colorbar(deviation, ax=upper, fraction=0.028, pad=0.025)
    fig.colorbar(meridional, ax=lower, fraction=0.028, pad=0.025)
    upper.set_title(text["dev"], fontproperties=font, fontsize=14)
    lower.set_title(text["speed"], fontproperties=font, fontsize=14)
    for ax in (upper, lower):
        ax.set_xlim(0, lz); ax.set_ylim(R1, R2)
        ax.set_xlabel(text["z"]); ax.set_ylabel(text["r"])
        line = ax.axvline(z_slice, ls="--", color="#f8fafc", lw=1.2, zorder=10)
        line.set_path_effects([path_effects.withStroke(linewidth=2.5, foreground="#334155")])
    upper.text(z_slice + 0.04 * lz, R2 - 0.035, text["section"], ha="left", va="top",
               fontsize=10, fontproperties=font, color="#475569",
               bbox={"facecolor": "white", "edgecolor": "none", "alpha": 0.85, "pad": 2})
    zz, rr = np.meshgrid(zc, rc)
    stream_artists = []
    last_record = None

    def draw(t):
        nonlocal stream_artists, last_record
        index = min(int(np.searchsorted(times, t, side="right") - 1), len(times) - 2)
        offset = t - times[index]
        interval = times[index + 1] - times[index]
        weight = offset / interval
        first, second = saved[index], saved[index + 1]
        dev = (1 - weight) * first[2] + weight * second[2]
        ur = (1 - weight) * first[3] + weight * second[3]
        uz = (1 - weight) * first[4] + weight * second[4]
        deviation.set_data(dev)
        meridional.set_data(np.hypot(ur, uz))
        # Streamline geometry updates at saved-record intervals; the color
        # maps and circumferential motion are smooth at every video frame.
        record = index if weight < 0.5 else index + 1
        if record != last_record:
            for artist in stream_artists:
                artist.remove()
            stream_artists = []
            if saved[record][5].max() > 1e-3 * top:
                before = set(lower.get_children())
                lower.streamplot(zz, rr, saved[record][4], saved[record][3],
                                 color="white", density=(1.4, 0.6), linewidth=0.65, arrowsize=0.8)
                stream_artists = [artist for artist in lower.get_children() if artist not in before]
            last_record = record
        profile = (1 - weight) * profiles[index] + weight * profiles[index + 1]
        rotation.set_data(annulus(profile))
        phase = phases[index] + angular[index] * offset + (
            angular[index + 1] - angular[index]) * offset ** 2 / (2 * interval)
        omega = (1 - weight) * angular[index] + weight * angular[index + 1]
        angles = (phase[:, None] + np.arange(3)[None, :] * 2 * np.pi / 3).ravel()
        rad = np.repeat(rings, 3)
        direction = np.repeat(np.sign(omega), 3)
        arrows.set_offsets(np.c_[rad * np.cos(angles), rad * np.sin(angles)])
        arrows.set_UVC(-0.22 * np.sin(angles) * direction, 0.22 * np.cos(angles) * direction)
        trail = angles[:, None] - direction[:, None] * np.linspace(0.30, 0, 18)[None, :]
        tails.set_segments(np.stack([rad[:, None] * np.cos(trail), rad[:, None] * np.sin(trail)], axis=-1))
        spokes = W1 * t + np.arange(4) * np.pi / 2
        sx = np.c_[0.73 * np.cos(spokes), 0.95 * np.cos(spokes), np.full(4, np.nan)].ravel()
        sy = np.c_[0.73 * np.sin(spokes), 0.95 * np.sin(spokes), np.full(4, np.nan)].ravel()
        rotor.set_data(sx, sy)
        title.set_text(text["video"] % (meta["re"], t))

    draw(times[-1])
    fig.savefig(poster, dpi=100)
    if not poster_only:
        fig.canvas.draw()
        width, height = fig.canvas.get_width_height()
        command = [ffmpeg(), "-y", "-loglevel", "error", "-f", "rawvideo", "-vcodec", "rawvideo",
                   "-pix_fmt", "rgba", "-s", f"{width}x{height}", "-r", str(fps), "-i", "-",
                   "-an", "-c:v", "libx264", "-crf", "23", "-preset", "medium",
                   "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(out)]
        with subprocess.Popen(command, stdin=subprocess.PIPE) as encoder:
            try:
                for k, t in enumerate(frame_times):
                    draw(t)
                    fig.canvas.draw()
                    encoder.stdin.write(fig.canvas.buffer_rgba())
                    if k % (fps * 5) == 0:
                        print(f"{lang}: video frame {k + 1}/{frame_count}, t={t:.1f}", flush=True)
            finally:
                encoder.stdin.close()
            if encoder.wait() != 0:
                raise RuntimeError("ffmpeg video encoding failed")
    plt.close(fig)
    return frame_count


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
    parser.add_argument("--fps", type=int, default=30, help="video frames per second")
    parser.add_argument("--time-scale", type=float, default=6.0, help="simulation time units per video second")
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
        record["video_frames"] = video(args.run, lang, args.results / f"taylor-couette-{lang}.mp4",
                                       args.results / f"taylor-couette-{lang}-poster.png",
                                       fps=args.fps, time_scale=args.time_scale)
    record.update(video_fps=args.fps, video_time_scale=args.time_scale,
                  video_section_z=record["metadata"]["lz"] / 8)
    lam, k = wavelength(args.run)
    record.update(axial_wavelength=lam, axial_pairs=k)
    (args.results / "runs.json").write_text(json.dumps(record, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({key: record[key] for key in record if key != "metadata"}, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
