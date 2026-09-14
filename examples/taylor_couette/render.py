#!/usr/bin/env python3
"""Render a saved Taylor-Couette run; every NumPy computation here is for display.

Requires numpy and matplotlib.  The records (meridional plane per rank,
reductions per interval) are written by the generated solver through run.py;
this script merges the ranks, draws cutaway cylinders, meridional velocity,
and animated circumferential speed indicators, fits the perturbation growth, and
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
from matplotlib.artist import Artist
from matplotlib.collections import LineCollection
from matplotlib.patches import Circle
from matplotlib.transforms import IdentityTransform
from matplotlib import patheffects as path_effects
from mpl_toolkits.mplot3d import proj3d
from mpl_toolkits.mplot3d.art3d import Poly3DCollection, Line3DCollection

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
R1, R2, W1, W2 = 1.0, 2.0, 1.0, 0.0
# Both colored cylinders sit at the actual radii sampled from the fluid.
INNER_SURFACE_RADIUS = R1 + 0.10 * (R2 - R1)
OUTER_SURFACE_RADIUS = R2 - 0.10 * (R2 - R1)
SURFACE_RADII = (INNER_SURFACE_RADIUS, OUTER_SURFACE_RADIUS)
SECTION_COLOR = "#b45309"
OUTPUT_WIDTH = 1920
# Output pixels, shared by every panel and the separate diagnostic figures.
ARROW_LENGTH = 16.0
ARROW_HEAD_LENGTH = 5.0
ARROW_HEAD_WIDTH = 6.0
ARROW_LINE_WIDTH = 1.4
ARROW_OUTLINE_WIDTH = 2.8
RECORD = np.dtype([("i", "=i4"), ("j", "=i4"), ("ut", "=f8"), ("ur", "=f8"),
                   ("uz", "=f8"), ("p", "=f8")])
JAPANESE = Path("/usr/local/texlive/2025/texmf-dist/fonts/opentype/public/haranoaji/HaranoAjiMincho-Regular.otf")
TEXT = {
    "en": {"dev": "azimuthal velocity change from the reference $u_\\theta - (Ar + B/r)$",
           "dev_colors": "Red: faster / white: unchanged / blue: slower than reference\nReference: Couette flow without vortices.\nBlue means a decrease, not reverse rotation.",
           "speed": "speed in the longitudinal slice $\\sqrt{u_r^2 + u_z^2}$ and streamlines",
           "speed_colors": "Purple: slow (near zero) → green → yellow: fast\nColor shows radial and axial speed; rotation is excluded.",
           "growth": "growth of the perturbation: $\\max|u_r|$",
           "profile": "radial velocity at mid gap, $u_r(r = 1.5, z)$",
           "time": "time $t$", "z": "$z$", "r": "$r$",
           "fit": "fit $e^{\\sigma t}$, $\\sigma$ = %.4f",
           "title": "Axisymmetric Taylor-Couette flow at Re = %g: Taylor vortices from the Couette flow (t = %g)",
           "views": "Flow inside the cylinders: a 3-D view, an axial view, and longitudinal slices",
           "cutaway": "Flow inside the outer wall, seen from above at an angle",
           "cutaway_note": "White arrows: flow direction; the same display size in every panel.\nCylinders: $(u_\\theta,u_z)$ / vertical cuts: $(u_r,u_z)$ / top: $(u_r,u_\\theta)$.\nTop fan: fluid section at z = %(height)g; color scale shared with the center panel.\nVertical-cut colors: lower right scale / cylindrical-section colors: left scale.\nGray dashes: wall r = 2 / orange: fluid sections r = %(inner).2f, %(outer).2f.",
           "fluid_section": "Orange: fluid sections at r = %.2f and %.2f",
           "surface_speed": "Fluid axial velocity $u_z$ ($r = %.2f, %.2f$)",
           "up": "Upward", "down": "Downward",
           "arrow_size": "Arrows show direction at the same display size in every figure; their size does not encode speed.",
           "endview": "View from $+z$ (section at $z$ = %g)",
           "inner": "Inner cylinder\ncounterclockwise\n$\\Omega_1 = 1$",
           "inner_top": "Inner cylinder $r=1$",
           "outer": "Outer wall $r=2$: stationary",
           "azimuthal": "azimuthal velocity $u_\\theta$",
           "section": "axial-view section",
           "glyphs": "Moving arrows in the center panel show rotation at fixed radius and height: $d\\theta/dt = u_\\theta/r$ (not particle trajectories).",
           "sampling": "%g times simulation speed  |  %d fps  |  saved velocities interpolated for display",
           "video": "Taylor-Couette flow at Re = %g, $t$ = %5.1f"},
    "ja": {"dev": "基準からの周方向速度の増減 $u_\\theta - (Ar + B/r)$",
           "dev_colors": "赤：基準より速い ／ 白：同じ ／ 青：基準より遅い\n基準：渦のないクエット流れ\n青は逆回転を意味しない．",
           "speed": "縦断面内の速さ $\\sqrt{u_r^2 + u_z^2}$ と流線",
           "speed_colors": "紫：遅い（0 に近い）→ 緑 → 黄：速い\n色は半径方向・軸方向の速さ（周方向は含まない）",
           "growth": "擾乱の成長：$\\max|u_r|$",
           "profile": "隙間中央の半径方向速度 $u_r(r = 1.5, z)$",
           "time": "時間 $t$", "z": "$z$", "r": "$r$",
           "fit": "当てはめ $e^{\\sigma t}$，$\\sigma$ = %.4f",
           "title": "軸対称テイラー・クエット流れ，Re = %g：クエット流れから育つテイラー渦（t = %g）",
           "views": "円筒内の流れを，立体図・軸方向からの図・縦断面で表示",
           "cutaway": "外壁の内側の流れ（斜め上から）",
           "cutaway_note": "白矢印：面に沿う流れの向き（大きさは全図で共通）\n円筒面 $(u_\\theta,u_z)$ ／ 縦の切り口 $(u_r,u_z)$ ／ 上面 $(u_r,u_\\theta)$\n上の扇形：z = %(height)g の流体断面（色尺度は中央図と共通）\n縦の切り口の色：右下の目盛り／円筒面の色：左の目盛り\n灰破線：外壁 r = 2 ／ 橙：流体断面 r = %(inner).2f，%(outer).2f",
           "fluid_section": "橙の円：左図の流体断面 r = %.2f，%.2f",
           "surface_speed": "流体の軸方向速度 $u_z$（$r = %.2f, %.2f$）",
           "up": "上昇", "down": "下降",
           "arrow_size": "矢印は全図で同じ大きさで向きを示し，速さを表さない．",
           "endview": "円筒を $+z$ 側から見る（$z$ = %g）",
           "inner": "内筒\n反時計回り\n$\\Omega_1 = 1$",
           "inner_top": "内筒 $r=1$",
           "outer": "外壁 $r=2$：静止",
           "azimuthal": "周方向速度 $u_\\theta$",
           "section": "中央図の断面",
           "glyphs": "中央図の動く矢印：固定した半径と高さでの回転 $d\\theta/dt = u_\\theta/r$ を表示（流体粒子の軌跡ではない）",
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


class DirectionArrows(Artist):
    """Project positions/directions first, then draw identical pixel-sized arrows.

    This also runs at savefig's output DPI, after layout has set the axes size.
    The optional surface check omits arrows that would leave their visible
    face; it never clips or shrinks an arrow to make it fit.
    """

    def __init__(self, ax, project=None, contains=None, spacing=0, zorder=5):
        super().__init__()
        self.ax = ax
        self.project = project or ax.transData.transform
        self.contains = contains
        self.spacing = spacing
        self.positions, self.vectors = [], []
        self.set_zorder(zorder)
        self.set_in_layout(False)
        ax.add_artist(self)
        self.outline = LineCollection([], colors='#334155', transform=IdentityTransform(),
                                      capstyle='round', joinstyle='round')
        self.lines = LineCollection([], colors='white', transform=IdentityTransform(),
                                    capstyle='round', joinstyle='round')
        for collection in (self.outline, self.lines):
            collection.set_figure(ax.figure)

    def set_data(self, positions, vectors):
        self.positions = np.asarray(positions, dtype=float)
        self.vectors = np.asarray(vectors, dtype=float)
        self.stale = True

    def draw(self, renderer):
        if not self.get_visible() or len(self.positions) == 0:
            return
        centers = self.project(self.positions)
        directions = self.project(self.positions+self.vectors)-centers
        lengths = np.linalg.norm(directions, axis=1)
        unit = directions/np.maximum(lengths[:, None], 1e-12)
        side = np.c_[-unit[:, 1], unit[:, 0]]
        tail = centers-ARROW_LENGTH/2*unit
        tip = centers+ARROW_LENGTH/2*unit
        left = tip-ARROW_HEAD_LENGTH*unit+ARROW_HEAD_WIDTH/2*side
        right = tip-ARROW_HEAD_LENGTH*unit-ARROW_HEAD_WIDTH/2*side
        vertices = np.concatenate([
            tail[:, None, :]+np.linspace(0, 1, 9)[None, :, None]*(tip-tail)[:, None, :],
            left[:, None, :]+np.linspace(0, 1, 5)[None, :, None]*(tip-left)[:, None, :],
            right[:, None, :]+np.linspace(0, 1, 5)[None, :, None]*(tip-right)[:, None, :],
        ], axis=1)
        # Include the stroke when checking whether the complete arrow fits.
        angles = np.arange(8)*np.pi/4
        offsets = (ARROW_OUTLINE_WIDTH/2+.5)*np.c_[np.cos(angles), np.sin(angles)]
        footprint = (vertices[:, :, None, :]+offsets).reshape(len(centers), -1, 2)
        keep = lengths > 1e-8
        if self.contains is not None:
            keep &= self.contains(footprint)
        else:
            x0, y0, x1, y1 = self.ax.bbox.extents
            keep &= ((footprint[..., 0] >= x0) & (footprint[..., 0] <= x1)
                     & (footprint[..., 1] >= y0) & (footprint[..., 1] <= y1)).all(axis=1)
        segments, placed = [], []
        for i in np.flatnonzero(keep):
            if self.spacing and any(np.linalg.norm(centers[i]-p) < self.spacing for p in placed):
                continue
            segments.extend([np.array([tail[i], tip[i]]), np.array([left[i], tip[i], right[i]])])
            placed.append(centers[i])
        pixels_per_point = renderer.points_to_pixels(1)
        for collection, width in ((self.outline, ARROW_OUTLINE_WIDTH), (self.lines, ARROW_LINE_WIDTH)):
            collection.set_segments(segments)
            collection.set_linewidth(width/pixels_per_point)
            collection.draw(renderer)
        self.stale = False


def streamlines(ax, zz, rr, uz, ur, density):
    """Streamlines with the same direction arrows as the 3-D and axial views."""
    before = set(ax.patches)
    stream = ax.streamplot(zz, rr, uz, ur, color='white', density=density, linewidth=.65)
    # Replace streamplot's independently sized arrowheads, retaining its paths.
    for patch in set(ax.patches)-before:
        patch.remove()
    positions, directions = [], []
    for path in stream.lines.get_segments():
        if len(path) > 2:
            mid = len(path)//2
            positions.append(path[mid])
            directions.append(path[mid+1]-path[mid-1])
    arrows = DirectionArrows(ax, spacing=ARROW_LENGTH+4)
    arrows.set_data(positions, directions)
    return stream.lines, arrows


def color_note(ax, label, font):
    """Keep the color meaning beside its panel, below the axis labels."""
    return ax.annotate(label, xy=(.5, 0), xycoords='axes fraction',
                       xytext=(0, -46), textcoords='offset points',
                       ha='center', va='top', fontsize=10, linespacing=1.5,
                       fontproperties=font, color='#334155', annotation_clip=False)


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
    color_note(ax, text["dev_colors"], font)
    ax = axes[1, 0]
    im = ax.imshow(speed, origin="lower", extent=extent, aspect="equal", cmap="viridis",
                   interpolation="nearest")
    fig.colorbar(im, ax=ax, fraction=0.025, pad=0.02)
    zz, rr = np.meshgrid(zc, rc)
    streamlines(ax, zz, rr, uz, ur, density=(1.6, 0.6))
    ax.set_xlim(0, lz); ax.set_ylim(R1, R2)
    ax.set_title(text["speed"], fontproperties=font)
    ax.set_xlabel(text["z"]); ax.set_ylabel(text["r"])
    color_note(ax, text["speed_colors"], font)
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
    fig.text(.5, .018, text['arrow_size'], ha='center', fontsize=10, fontproperties=font, color='#475569')
    fig.tight_layout(rect=[0, .04, 1, 1])
    fig.savefig(out, dpi=OUTPUT_WIDTH/fig.get_figwidth())
    plt.close(fig)
    return {"growth_rate": sigma, "max_ur": float(rec["ur"][-1]), "max_uz": float(rec["uz"][-1]),
            "max_deviation": float(limit), "final_residual": float(rec["res"][-1]),
            "final_divergence": float(rec["div"][-1])}


def ffmpeg():
    return os.environ.get("FFMPEG") or shutil.which("ffmpeg")


def sample_velocity(rc, zc, lz, ut, ur, uz, r, z):
    """Bilinear display interpolation, including no-slip walls and periodic z.

    The returned components are (azimuthal, radial, axial). In particular,
    the top display section at z=lz samples across the periodic seam. The
    prescribed wall velocities bound the interpolation inside the fluid.
    """
    r, z = np.broadcast_arrays(r, np.mod(z, lz))
    radial = np.r_[R1, rc, R2]
    axial = np.r_[zc[-1]-lz, zc, zc[0]+lz]
    i = np.clip(np.searchsorted(radial, r)-1, 0, len(radial)-2)
    j = np.clip(np.searchsorted(axial, z)-1, 0, len(axial)-2)
    a = (r-radial[i])/(radial[i+1]-radial[i])
    b = (z-axial[j])/(axial[j+1]-axial[j])
    sampled = []
    for field, inner, outer in ((ut, W1*R1, W2*R2), (ur, 0, 0), (uz, 0, 0)):
        data = np.vstack([np.full(len(zc), inner), field, np.full(len(zc), outer)])
        data = np.c_[data[:, -1], data, data[:, 0]]
        sampled.append((1-a)*((1-b)*data[i, j]+b*data[i, j+1])
                       + a*((1-b)*data[i+1, j]+b*data[i+1, j+1]))
    return np.stack(sampled, axis=-1)


class CutawayView:
    """A display-only reconstruction of the axisymmetric field in 3-D.

    The front quarter is omitted to expose two meridional sections. Fluid
    data is displayed at its actual sampling radius, inside a wire outline
    of the stationary wall. Arrow anchors lie only on faces visible from the
    fixed camera, with margins keeping the complete arrows on those faces.
    The top annular section cuts fluid at the periodic display limit, not a lid.
    """

    def __init__(self, ax, rc, zc, lz, top, surface_limit, rotation_norm, text, font):
        self.rc, self.zc, self.lz = rc, zc, lz
        self.top = top
        self.surface_norm = matplotlib.colors.Normalize(-surface_limit, surface_limit)
        self.rotation_norm = rotation_norm
        self.front = np.deg2rad([-100, -10])
        self.faces, self.colors = [], []
        self.cut_slices = []
        # Each face is ordered counterclockwise in its own parameter plane.
        def quads(x, y, z):
            xyz = np.stack(np.broadcast_arrays(x, y, z), axis=-1)
            return np.stack([xyz[:-1, :-1], xyz[1:, :-1],
                             xyz[1:, 1:], xyz[:-1, 1:]], axis=2).reshape(-1, 4, 3)

        # The colored surface is a cylindrical section of the fluid, at
        # the same radius used to sample velocities. The wall is only a frame.
        theta = np.linspace(self.front[1], self.front[0] + 2*np.pi, 73)
        heights = np.linspace(0, lz, 97)
        section = quads(OUTER_SURFACE_RADIUS*np.cos(theta[:, None]),
                        OUTER_SURFACE_RADIUS*np.sin(theta[:, None]), heights[None, :])
        self.section_slice = slice(0, len(section))
        self.section_z = np.tile((heights[:-1]+heights[1:])/2, len(theta)-1)
        self.faces.extend(section)
        self.colors.extend(np.ones((len(section), 4)))

        # The front face is fluid at r=1.10, not color painted onto the wall.
        heights = np.linspace(0, lz, 97)
        theta = np.linspace(self.front[0], self.front[1], 33)
        inner = quads(INNER_SURFACE_RADIUS*np.cos(theta[:, None]),
                      INNER_SURFACE_RADIUS*np.sin(theta[:, None]), heights[None, :])
        self.inner_slice = slice(len(self.faces), len(self.faces)+len(inner))
        self.faces.extend(inner)
        self.colors.extend(np.ones((len(inner), 4)))
        self.inner_z = np.tile((heights[:-1]+heights[1:])/2, len(theta)-1)

        # The inner solid is capped; the surrounding fan is a fluid section.
        theta = np.linspace(0, 2*np.pi, 129)
        disk = np.array([[[0, 0, lz], [R1*np.cos(a), R1*np.sin(a), lz],
                          [R1*np.cos(b), R1*np.sin(b), lz]]
                         for a, b in zip(theta[:-1], theta[1:])])
        self.faces.extend(disk)
        self.colors.extend(np.tile(matplotlib.colors.to_rgba('#cbd5e1'), (len(disk), 1)))
        re = np.linspace(R1, OUTER_SURFACE_RADIUS, 25)
        theta = np.linspace(self.front[1], self.front[0]+2*np.pi, 97)
        fan = quads(re[:, None]*np.cos(theta), re[:, None]*np.sin(theta), lz)
        self.fan_sections = [(slice(len(self.faces), len(self.faces)+len(fan)),
                              np.repeat((re[:-1]+re[1:])/2, len(theta)-1))]
        self.faces.extend(fan)
        self.colors.extend(np.ones((len(fan), 4)))

        # The narrow fluid band between the solid r=1 and the r=1.10 section
        # remains in the opening, including its horizontal top face.
        re = np.linspace(R1, INNER_SURFACE_RADIUS, 5)
        theta = np.linspace(self.front[0], self.front[1], 33)
        collar = quads(re[:, None]*np.cos(theta), re[:, None]*np.sin(theta), lz)
        self.fan_sections.append((slice(len(self.faces), len(self.faces)+len(collar)),
                                  np.repeat((re[:-1]+re[1:])/2, len(theta)-1)))
        self.faces.extend(collar)
        self.colors.extend(np.ones((len(collar), 4)))

        # Downsampling only affects the resolution of the displayed surfaces.
        re = np.linspace(INNER_SURFACE_RADIUS, OUTER_SURFACE_RADIUS, 25)
        ze = np.linspace(0, lz, 97)
        self.sample_r = (re[:-1] + re[1:])/2
        self.sample_z = (ze[:-1] + ze[1:])/2
        for theta in self.front:
            face = quads(re[:, None]*np.cos(theta), re[:, None]*np.sin(theta), ze[None, :])
            self.cut_slices.append(slice(len(self.faces), len(self.faces)+len(face)))
            self.faces.extend(face)
            self.colors.extend(np.ones((len(face), 4)))
        self.colors = np.array(self.colors)
        self.surfaces = Poly3DCollection(self.faces, facecolors=self.colors, edgecolors='none',
                                         antialiaseds=False, zsort='average', zorder=2)
        ax.add_collection3d(self.surfaces, autolim=False)

        # Top rims and exposed sections; hidden back edges at the bottom
        # are omitted rather than drawn through the opaque cylinder surfaces.
        kept = np.linspace(self.front[1], self.front[0]+2*np.pi, 150)
        full = np.linspace(0, 2*np.pi, 160)
        outlines = [np.c_[R1*np.cos(full), R1*np.sin(full), np.full_like(full, lz)]]
        for theta in self.front:
            outlines.append(np.array([[INNER_SURFACE_RADIUS*np.cos(theta), INNER_SURFACE_RADIUS*np.sin(theta), 0],
                                      [OUTER_SURFACE_RADIUS*np.cos(theta), OUTER_SURFACE_RADIUS*np.sin(theta), 0],
                                      [OUTER_SURFACE_RADIUS*np.cos(theta), OUTER_SURFACE_RADIUS*np.sin(theta), lz],
                                      [INNER_SURFACE_RADIUS*np.cos(theta), INNER_SURFACE_RADIUS*np.sin(theta), lz]]))
        ax.add_collection3d(Line3DCollection(outlines, colors='#475569', linewidths=.8, zorder=3), autolim=False)
        # Distinct outlines locate the real wall and the interior fluid section.
        # At lower heights only front-facing wall edges are shown, so hidden
        # edges do not appear through the opaque fluid surface.
        wall = [np.c_[R2*np.cos(kept), R2*np.sin(kept), np.full_like(kept, lz)]]
        section_edges = [np.c_[OUTER_SURFACE_RADIUS*np.cos(kept), OUTER_SURFACE_RADIUS*np.sin(kept),
                               np.full_like(kept, lz)],
                         np.c_[INNER_SURFACE_RADIUS*np.cos(full), INNER_SURFACE_RADIUS*np.sin(full),
                               np.full_like(full, lz)]]
        opening = np.linspace(self.front[0], self.front[1], 50)
        section_edges.append(np.c_[INNER_SURFACE_RADIUS*np.cos(opening),
                                    INNER_SURFACE_RADIUS*np.sin(opening), np.zeros_like(opening)])
        for theta in np.deg2rad([-140, -100, -10, 30]):
            wall.append(np.array([[R2*np.cos(theta), R2*np.sin(theta), 0],
                                  [R2*np.cos(theta), R2*np.sin(theta), lz]]))
        for theta in self.front:
            section_edges.append(np.array([[OUTER_SURFACE_RADIUS*np.cos(theta), OUTER_SURFACE_RADIUS*np.sin(theta), 0],
                                           [OUTER_SURFACE_RADIUS*np.cos(theta), OUTER_SURFACE_RADIUS*np.sin(theta), lz]]))
        for lo, hi in ((-145, -100), (-10, 35)):
            a = np.deg2rad(np.linspace(lo, hi, 40))
            for z in (0, lz/2):
                wall.append(np.c_[R2*np.cos(a), R2*np.sin(a), np.full_like(a, z)])
        ax.add_collection3d(Line3DCollection(wall, colors='#64748b', linewidths=1.0,
                                              linestyles='dashed', zorder=3), autolim=False)
        ax.add_collection3d(Line3DCollection(section_edges, colors=SECTION_COLOR,
                                              linewidths=1.0, zorder=3), autolim=False)
        self.arrows = DirectionArrows(ax, project=self.project, contains=self.contains_arrows,
                                      spacing=ARROW_LENGTH+1)
        self.ax = ax
        # Each arrow is sampled and drawn on the same face. Values normal to
        # that face are omitted. Arrow length expresses direction only.
        self.arrow_groups = []
        def add_arrows(kind, radius, theta, height):
            r, a, z = np.broadcast_arrays(radius, theta, height)
            self.arrow_groups.append((kind, r.ravel(), a.ravel(), z.ravel()))
        # From azimuth -55 degrees, all rays from these inner/cut faces
        # pass through the opening. Outer-face arrows stay within the front
        # hemisphere. The top faces point upward. Thus none of these arrows
        # can be hidden behind another face or drawn over a different one.
        heights = np.linspace(.22, lz-.22, 9)[None, :]
        add_arrows('cylinder', INNER_SURFACE_RADIUS, np.deg2rad([-82, -55, -28])[:, None], heights)
        add_arrows('cylinder', OUTER_SURFACE_RADIUS,
                   np.deg2rad([-133, -115, 5, 23])[:, None], heights)
        for theta in self.front:
            add_arrows('cut', np.linspace(INNER_SURFACE_RADIUS+.12, OUTER_SURFACE_RADIUS-.12, 3)[:, None],
                       theta, np.linspace(.18, lz-.18, 15)[None, :])
        add_arrows('top', np.linspace(INNER_SURFACE_RADIUS+.14, OUTER_SURFACE_RADIUS-.14, 3)[:, None],
                   np.linspace(self.front[1]+.13, self.front[0]+2*np.pi-.13, 14)[None, :],
                   lz)
        add_arrows('top', (R1+INNER_SURFACE_RADIUS)/2,
                   np.linspace(0, 2*np.pi, 16, endpoint=False), lz)
        # The solid's motion is marked on its gray top section, not on fluid.
        self.rotor = Line3DCollection([], colors='#64748b', linewidths=2.4, zorder=4)
        ax.add_collection3d(self.rotor, autolim=False)
        ax.text(0, 0, lz, text['inner_top'], ha='center', va='center',
                fontsize=10, fontproperties=font, color='#334155', zorder=6)
        ax.view_init(elev=27, azim=-55)
        ax.set_proj_type('ortho')
        ax.set_box_aspect((4, 4, lz), zoom=1.15)
        ax.set_xlim(-2.1, 2.1); ax.set_ylim(-2.1, 2.1); ax.set_zlim(0, lz)
        ax.set_axis_off()
        ax.text2D(.5, 1.04, text['cutaway'], ha='center', va='top',
                  transform=ax.transAxes, fontsize=17, fontproperties=font)
        note = text['cutaway_note'] % {'height': lz, 'inner': INNER_SURFACE_RADIUS,
                                      'outer': OUTER_SURFACE_RADIUS}
        ax.text2D(.5, -.07, note, ha='center', va='bottom',
                  transform=ax.transAxes, fontsize=10.5, fontproperties=font, color='#475569')
        color_axis = ax.figure.add_axes([.027, .34, .009, .29])
        cb = ax.figure.colorbar(matplotlib.cm.ScalarMappable(norm=self.surface_norm, cmap='RdBu_r'),
                                 cax=color_axis, ticks=[-surface_limit, 0, surface_limit], format='%.3f')
        cb.set_label(text['surface_speed'] % SURFACE_RADII, fontproperties=font, fontsize=11)
        cb.ax.text(.5, 1.045, text['up'], transform=cb.ax.transAxes, ha='center', va='bottom',
                   fontsize=10, fontproperties=font, color='#b91c1c')
        cb.ax.text(.5, -.045, text['down'], transform=cb.ax.transAxes, ha='center', va='top',
                   fontsize=10, fontproperties=font, color='#1d4ed8')
        cb.ax.yaxis.set_label_position('left')
        cb.ax.tick_params(labelsize=10)
        # Height labels sit just outside the right-hand cut edge.
        theta = self.front[1]
        for z in (0, lz):
            ax.text(2.18*np.cos(theta), 2.18*np.sin(theta), z, '$z=%g$' % z, fontsize=11)

    def draw(self, t, ut, ur, uz):
        angles = W1*t+np.arange(4)*np.pi/2
        self.rotor.set_segments([np.c_[np.array([.73, .94])*np.cos(a),
                                        np.array([.73, .94])*np.sin(a), [self.lz, self.lz]]
                                 for a in angles])
        def sample(r, z):
            return sample_velocity(self.rc, self.zc, self.lz, ut, ur, uz, r, z)
        velocity = sample(self.sample_r[:, None], self.sample_z[None, :])
        speed = np.hypot(velocity[..., 1], velocity[..., 2])
        rgba = plt.get_cmap('viridis')(np.clip(speed/self.top, 0, 1)).reshape(-1, 4)
        for part in self.cut_slices:
            self.colors[part] = rgba
        self.colors[self.section_slice] = plt.get_cmap('RdBu_r')(
            self.surface_norm(sample(OUTER_SURFACE_RADIUS, self.section_z)[:, 2]))
        self.colors[self.inner_slice] = plt.get_cmap('RdBu_r')(
            self.surface_norm(sample(INNER_SURFACE_RADIUS, self.inner_z)[:, 2]))
        for part, radii in self.fan_sections:
            self.colors[part] = plt.get_cmap('cividis')(
                self.rotation_norm(sample(radii, self.lz)[:, 0]))

        positions, vectors, faces, sampled_radii, sampled_angles = [], [], [], [], []
        for kind, radii, angles, heights in self.arrow_groups:
            velocity = sample(radii, heights)
            components = {'cylinder': (0, 2), 'cut': (1, 2), 'top': (1, 0)}[kind]
            tangent = velocity[:, components]
            magnitude = np.linalg.norm(tangent, axis=1)
            threshold = 1e-3*self.top if kind == 'cut' else 1e-6
            for r, a, z, v, norm in zip(radii, angles, heights, tangent, magnitude):
                if norm <= threshold:
                    continue
                if kind == 'cylinder':
                    vector = [-v[0]*np.sin(a), v[0]*np.cos(a), v[1]]
                elif kind == 'cut':
                    vector = [v[0]*np.cos(a), v[0]*np.sin(a), v[1]]
                else:
                    vector = [v[0]*np.cos(a)-v[1]*np.sin(a),
                              v[0]*np.sin(a)+v[1]*np.cos(a), 0]
                positions.append([r*np.cos(a), r*np.sin(a), z])
                vectors.append(vector)
                faces.append(kind)
                sampled_radii.append(r)
                sampled_angles.append(a)
        self.arrow_faces = np.array(faces)
        self.arrow_radii = np.array(sampled_radii)
        self.arrow_angles = np.array(sampled_angles)
        self.surfaces.set_facecolors(self.colors)
        self.arrows.set_data(positions, vectors)

    def project(self, points):
        """World positions to output pixels, using the current 3-D axes layout."""
        x, y, _ = proj3d.proj_transform(*np.asarray(points).T, self.ax.get_proj())
        return self.ax.transData.transform(np.c_[x, y])

    def contains_arrows(self, pixels):
        """Keep complete arrows on their sampled visible faces.

        Cast parallel viewing rays through each screen-space arrow's outline.
        Intersections with its cylinder or plane must stay inside that face.
        Arrows near silhouettes, cut edges, or the narrow top band are omitted
        if they cannot fit at the common size.
        """
        origin = self.project(np.zeros((1, 3)))[0]
        matrix = (self.project(np.eye(3))-origin).T
        starts = (pixels-origin) @ np.linalg.pinv(matrix).T
        ray = np.cross(matrix[0], matrix[1])
        ray /= np.linalg.norm(ray)
        if ray[2] < 0:  # the fixed camera is above the cylinder
            ray = -ray
        keep = np.zeros(len(pixels), dtype=bool)
        for kind in ('cylinder', 'cut', 'top'):
            indices = np.flatnonzero(self.arrow_faces == kind)
            o = starts[indices]
            if not len(indices):
                continue
            if kind == 'cylinder':
                radii = self.arrow_radii[indices, None]
                aa = ray[0]**2+ray[1]**2
                bb = o[..., 0]*ray[0]+o[..., 1]*ray[1]
                cc = o[..., 0]**2+o[..., 1]**2-radii**2
                discriminant = bb**2-aa*cc
                # The nearer intersection is the outward-facing surface.
                distance = (-bb+np.sqrt(np.maximum(discriminant, 0)))/aa
                p = o+distance[..., None]*ray
                theta = np.arctan2(p[..., 1], p[..., 0])
                opening = (theta >= self.front[0]) & (theta <= self.front[1])
                visible = np.where(radii == INNER_SURFACE_RADIUS, opening, ~opening)
                valid = (discriminant >= 0) & visible & (p[..., 2] >= 0) & (p[..., 2] <= self.lz)
            elif kind == 'cut':
                theta = self.arrow_angles[indices]
                normal = np.c_[-np.sin(theta), np.cos(theta), np.zeros(len(theta))]
                distance = -np.einsum('nki,ni->nk', o, normal)/(normal @ ray)[:, None]
                p = o+distance[..., None]*ray
                r = p[..., 0]*np.cos(theta[:, None])+p[..., 1]*np.sin(theta[:, None])
                valid = ((r >= INNER_SURFACE_RADIUS) & (r <= OUTER_SURFACE_RADIUS)
                         & (p[..., 2] >= 0) & (p[..., 2] <= self.lz))
            else:
                p = o+((self.lz-o[..., 2])/ray[2])[..., None]*ray
                r = np.hypot(p[..., 0], p[..., 1])
                theta = np.arctan2(p[..., 1], p[..., 0])
                opening = (theta >= self.front[0]) & (theta <= self.front[1])
                valid = (r >= R1) & (r <= OUTER_SURFACE_RADIUS) & ((r <= INNER_SURFACE_RADIUS) | ~opening)
            keep[indices] = valid.all(axis=1)
        return keep


def video(directory, lang, out, poster, fps=30, time_scale=6.0, poster_only=False):
    """Show circumferential motion alongside the meridional fields.

    Moving glyphs in the axial view stay at fixed (r,z); only their display
    angle advances with sampled u_theta/r. Arrows on every cutaway face stay
    at fixed positions and show the local velocity direction along that face.
    Neither display depicts fluid trajectories.
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

    # One fixed color scale for both fluid cylinders over the whole video.
    surface_uz = np.array([[[np.interp(r, rc, col) for col in fields[4].T]
                            for r in SURFACE_RADII] for fields in saved])
    surface_limit = float(np.abs(surface_uz).max()) or 1.0
    rotation_norm = matplotlib.colors.Normalize(
        min(0.0, float(profiles.min())), max(abs(W1*R1), float(profiles.max())))

    fig = plt.figure(figsize=(OUTPUT_WIDTH/100, 9.6), dpi=100)
    cutaway = CutawayView(fig.add_axes([0, .16, .40, .70], projection='3d', computed_zorder=False),
                          rc, zc, lz, top, surface_limit, rotation_norm, text, font)
    end = fig.add_axes([.41, .22, .225, .58])
    upper = fig.add_axes([.69, .61, .285, .22])
    lower = fig.add_axes([.69, .24, .285, .22])
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
                          cmap="cividis", norm=rotation_norm, interpolation="bilinear")
    for ring in rings:
        end.add_patch(Circle((0, 0), ring, fill=False, edgecolor="white", lw=0.7, alpha=0.25))
    for r in SURFACE_RADII:
        end.add_patch(Circle((0, 0), r, fill=False, edgecolor=SECTION_COLOR, lw=1.8, zorder=3))
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
    end.text(0, -2.58, text["fluid_section"] % SURFACE_RADII, ha="center", va="center",
             fontproperties=font, fontsize=10, color=SECTION_COLOR)
    cb = fig.colorbar(rotation, ax=end, orientation="horizontal", fraction=0.046, pad=0.085)
    cb.set_label(text["azimuthal"], fontproperties=font)
    arrows = DirectionArrows(end, zorder=8)

    extent = [0, lz, R1, R2]
    deviation = upper.imshow(saved[0][2], origin="lower", extent=extent, aspect="equal",
                             cmap="RdBu_r", vmin=-limit, vmax=limit, interpolation="nearest")
    meridional = lower.imshow(saved[0][5], origin="lower", extent=extent, aspect="equal",
                              cmap="viridis", vmin=0, vmax=top, interpolation="nearest")
    fig.colorbar(deviation, ax=upper, fraction=0.028, pad=0.025)
    fig.colorbar(meridional, ax=lower, fraction=0.028, pad=0.025)
    upper.set_title(text["dev"].replace(" $", "\n$", 1), fontproperties=font, fontsize=14)
    lower.set_title(text["speed"].replace(" $", "\n$", 1), fontproperties=font, fontsize=14)
    color_note(upper, text["dev_colors"], font)
    color_note(lower, text["speed_colors"], font)
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
                stream_artists = streamlines(lower, zz, rr, saved[record][4], saved[record][3],
                                             density=(1.4, 0.6))
            last_record = record
        cutaway.draw(t, dev+couette(rc)[:, None], ur, uz)
        profile = (1 - weight) * profiles[index] + weight * profiles[index + 1]
        rotation.set_data(annulus(profile))
        phase = phases[index] + angular[index] * offset + (
            angular[index + 1] - angular[index]) * offset ** 2 / (2 * interval)
        omega = (1 - weight) * angular[index] + weight * angular[index + 1]
        angles = (phase[:, None] + np.arange(3)[None, :] * 2 * np.pi / 3).ravel()
        rad = np.repeat(rings, 3)
        direction = np.repeat(np.sign(omega), 3)
        arrows.set_data(np.c_[rad*np.cos(angles), rad*np.sin(angles)],
                        np.c_[-np.sin(angles)*direction, np.cos(angles)*direction])
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
                  video_section_z=record["metadata"]["lz"] / 8,
                  video_size=[OUTPUT_WIDTH, 960], video_cutaway_degrees=90,
                  video_surface_radii=list(SURFACE_RADII))
    lam, k = wavelength(args.run)
    record.update(axial_wavelength=lam, axial_pairs=k)
    (args.results / "runs.json").write_text(json.dumps(record, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({key: record[key] for key in record if key != "metadata"}, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
