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
from matplotlib.collections import LineCollection
from matplotlib.patches import Circle
from matplotlib import patheffects as path_effects
from mpl_toolkits.mplot3d.art3d import Poly3DCollection, Line3DCollection

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
R1, R2, W1, W2 = 1.0, 2.0, 1.0, 0.0
SURFACE_RADIUS = R2 - 0.10 * (R2 - R1)  # actual radius of the displayed fluid section
SECTION_COLOR = "#b45309"
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
           "views": "Rotation and Taylor vortices: a cutaway cylinder, an axial view, and longitudinal slices",
           "cutaway": "Upright cylinders, viewed from above and outside",
           "cutaway_note": "Gray frame: stationary outer wall at r = 2.\nOrange outline: a cylindrical section of the fluid at r = %.2f.\nRed: upward; blue: downward; white arrows: velocity along the section.",
           "fluid_section": "Orange circle: the fluid section in the 3-D view, r = %.2f",
           "surface_speed": "Near-wall axial velocity $u_z$",
           "endview": "View from $+z$ (section at $z$ = %g)",
           "inner": "Inner cylinder\nrotating CCW\n$\\Omega_1 = 1$",
           "outer": "Outer cylinder: stationary",
           "azimuthal": "azimuthal velocity $u_\\theta$",
           "section": "axial-view section",
           "glyphs": "Moving arrows in the gap and axial view indicate rotation at fixed radii and heights: $d\\theta/dt = u_\\theta/r$ (not particle trajectories).",
           "sampling": "%g times simulation speed  |  %d fps  |  saved velocities interpolated for display",
           "video": "Taylor-Couette flow at Re = %g, $t$ = %5.1f"},
    "ja": {"dev": "周方向速度とクエット解の差 $u_\\theta - (Ar + B/r)$",
           "speed": "子午面の速さ $\\sqrt{u_r^2 + u_z^2}$ と流線",
           "growth": "擾乱の成長：$\\max|u_r|$",
           "profile": "隙間中央の半径方向速度 $u_r(r = 1.5, z)$",
           "time": "時間 $t$", "z": "$z$", "r": "$r$",
           "fit": "当てはめ $e^{\\sigma t}$，$\\sigma$ = %.4f",
           "title": "軸対称テイラー・クエット流れ，Re = %g：クエット流れから育つテイラー渦（t = %g）",
           "views": "切り開いた円筒・軸方向からの図・縦断面で，回転とテイラー渦を表示",
           "cutaway": "円筒を立て，外側の斜め上から見る",
           "cutaway_note": "灰色の枠：静止した外壁 r = 2\n橙の縁：流体の円筒断面 r = %.2f\n赤は上昇・青は下降／白矢印は断面に沿う速度",
           "fluid_section": "橙の円：立体図の流体断面 r = %.2f",
           "surface_speed": "壁の内側の軸方向速度 $u_z$",
           "endview": "円筒を $+z$ 側から見る（$z$ = %g）",
           "inner": "内筒\n反時計回り\n$\\Omega_1 = 1$",
           "outer": "外筒：静止",
           "azimuthal": "周方向速度 $u_\\theta$",
           "section": "中央図の断面",
           "glyphs": "隙間・中央図の動く矢印は固定した半径・高さでの回転速度 $d\\theta/dt = u_\\theta/r$ を表示（流体粒子の軌跡ではありません）",
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


class CutawayView:
    """A display-only reconstruction of the axisymmetric field in 3-D.

    The front quarter is omitted to expose two meridional sections. Fluid
    data is displayed at its actual sampling radius, inside a wire outline
    of the stationary wall. Opaque surfaces share one depth-sorted collection.
    The periodic z limits are open, without end caps.
    """

    def __init__(self, ax, rc, zc, lz, top, surface_limit, surface_scale, text, font):
        self.rc, self.zc = rc, zc
        self.top = top
        self.surface_norm = matplotlib.colors.Normalize(-surface_limit, surface_limit)
        self.surface_scale = surface_scale
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
        section = quads(SURFACE_RADIUS*np.cos(theta[:, None]),
                        SURFACE_RADIUS*np.sin(theta[:, None]), heights[None, :])
        self.section_slice = slice(0, len(section))
        self.section_z = np.tile((heights[:-1]+heights[1:])/2, len(theta)-1)
        self.faces.extend(section)
        self.colors.extend(np.ones((len(section), 4)))

        # Full inner cylinder, with animated stripes in its surface colors.
        heights = np.linspace(0, lz, 33)
        nz = len(heights)-1
        theta = np.linspace(0, 2*np.pi, 129)
        inner = quads(R1*np.cos(theta[:, None]), R1*np.sin(theta[:, None]), heights[None, :])
        self.inner_slice = slice(len(self.faces), len(self.faces)+len(inner))
        self.faces.extend(inner)
        self.colors.extend(np.ones((len(inner), 4)))
        self.inner_theta = np.repeat((theta[:-1] + theta[1:])/2, nz)

        # Downsampling only affects the resolution of the displayed surfaces.
        re = np.linspace(R1, R2, 25)
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
        outlines = [np.c_[R1*np.cos(kept), R1*np.sin(kept), np.full_like(kept, lz)]]
        for theta in self.front:
            outlines.append(np.array([[R1*np.cos(theta), R1*np.sin(theta), 0],
                                      [R2*np.cos(theta), R2*np.sin(theta), 0],
                                      [R2*np.cos(theta), R2*np.sin(theta), lz],
                                      [R1*np.cos(theta), R1*np.sin(theta), lz]]))
        ax.add_collection3d(Line3DCollection(outlines, colors='#475569', linewidths=.8, zorder=3), autolim=False)
        # Distinct outlines locate the real wall and the interior fluid section.
        # At lower heights only front-facing wall edges are shown, so hidden
        # edges do not appear through the opaque fluid surface.
        wall = [np.c_[R2*np.cos(kept), R2*np.sin(kept), np.full_like(kept, lz)]]
        section_edges = [np.c_[SURFACE_RADIUS*np.cos(kept), SURFACE_RADIUS*np.sin(kept),
                               np.full_like(kept, lz)]]
        for theta in np.deg2rad([-140, -100, -10, 30]):
            wall.append(np.array([[R2*np.cos(theta), R2*np.sin(theta), 0],
                                  [R2*np.cos(theta), R2*np.sin(theta), lz]]))
        for theta in self.front:
            section_edges.append(np.array([[SURFACE_RADIUS*np.cos(theta), SURFACE_RADIUS*np.sin(theta), 0],
                                           [SURFACE_RADIUS*np.cos(theta), SURFACE_RADIUS*np.sin(theta), lz]]))
        for lo, hi in ((-145, -100), (-10, 35)):
            a = np.deg2rad(np.linspace(lo, hi, 40))
            for z in (0, lz/2):
                wall.append(np.c_[R2*np.cos(a), R2*np.sin(a), np.full_like(a, z)])
        ax.add_collection3d(Line3DCollection(wall, colors='#64748b', linewidths=1.0,
                                              linestyles='dashed', zorder=3), autolim=False)
        ax.add_collection3d(Line3DCollection(section_edges, colors=SECTION_COLOR,
                                              linewidths=1.0, zorder=3), autolim=False)
        self.streams = Line3DCollection([], colors='white', linewidths=.7, zorder=4)
        ax.add_collection3d(self.streams, autolim=False)
        self.rotation_outline = Line3DCollection([], colors='#334155', linewidths=3.2, zorder=5)
        self.rotation = Line3DCollection([], colors='white', linewidths=1.8, zorder=6)
        ax.add_collection3d(self.rotation_outline, autolim=False)
        ax.add_collection3d(self.rotation, autolim=False)
        self.surface_outline = Line3DCollection([], colors='#334155', linewidths=2.8, zorder=7)
        self.surface_arrows = Line3DCollection([], colors='white', linewidths=1.5, zorder=8)
        ax.add_collection3d(self.surface_outline, autolim=False)
        ax.add_collection3d(self.surface_arrows, autolim=False)
        # Only the outward-facing portions of the fluid section are visible.
        # Keeping arrows here avoids drawing hidden back-side vectors through
        # the cylinder; each arrow also stays clear of the cut edges.
        self.surface_theta = np.deg2rad(-55 + np.array([-78, -60, 60, 78]))
        self.surface_z = np.linspace(.2, lz-.2, 11)
        ax.view_init(elev=27, azim=-55)
        ax.set_proj_type('ortho')
        ax.set_box_aspect((4, 4, lz), zoom=1.15)
        ax.set_xlim(-2.1, 2.1); ax.set_ylim(-2.1, 2.1); ax.set_zlim(0, lz)
        ax.set_axis_off()
        ax.text2D(.5, 1.04, text['cutaway'], ha='center', va='top',
                  transform=ax.transAxes, fontsize=17, fontproperties=font)
        ax.text2D(.5, -.035, text['cutaway_note'] % SURFACE_RADIUS, ha='center', va='bottom',
                  transform=ax.transAxes, fontsize=11.5, fontproperties=font, color='#475569')
        color_axis = ax.figure.add_axes([.027, .34, .009, .29])
        cb = ax.figure.colorbar(matplotlib.cm.ScalarMappable(norm=self.surface_norm, cmap='RdBu_r'),
                                 cax=color_axis, ticks=[-surface_limit, 0, surface_limit], format='%.3f')
        cb.set_label(text['surface_speed'], fontproperties=font, fontsize=11)
        cb.ax.yaxis.set_label_position('left')
        cb.ax.tick_params(labelsize=10)
        # Height labels sit just outside the right-hand cut edge.
        theta = self.front[1]
        for z in (0, lz):
            ax.text(2.18*np.cos(theta), 2.18*np.sin(theta), z, '$z=%g$' % z, fontsize=11)

    def draw(self, t, speed, paths, surface_ut, surface_uz):
        # Four stripes rotate at the prescribed inner-cylinder angular speed.
        distance = np.abs(np.angle(np.exp(4j*(self.inner_theta-W1*t))))/4
        stripe = np.exp(-(distance/.055)**4)
        shade = .85 + .08*np.cos(self.inner_theta-np.deg2rad(-55))
        base = np.c_[shade*.95, shade*.98, shade, np.ones_like(shade)]
        base[:, :3] = (1-stripe[:, None])*base[:, :3] + stripe[:, None]*np.array([.25, .32, .41])
        self.colors[self.inner_slice] = base
        # Interpolate the recorded meridional speed onto the display mesh.
        along_z = np.array([np.interp(self.sample_z, self.zc, row) for row in speed])
        sample = np.array([np.interp(self.sample_r, self.rc, column) for column in along_z.T]).T
        rgba = plt.get_cmap('viridis')(np.clip(sample/self.top, 0, 1)).reshape(-1, 4)
        for part in self.cut_slices:
            self.colors[part] = rgba
        self.colors[self.section_slice] = plt.get_cmap('RdBu_r')(
            self.surface_norm(np.interp(self.section_z, self.zc, surface_uz)))
        self.surfaces.set_facecolors(self.colors)
        self.draw_surface_velocity(surface_ut, surface_uz)
        if paths is not None:
            segments = []
            for theta in self.front:
                for path in paths:
                    # streamplot paths contain (z,r) coordinates in flow order.
                    z, r = path[:, 0], path[:, 1]
                    segments.append(np.c_[r*np.cos(theta), r*np.sin(theta), z])
                    if len(path) > 4:
                        mid = len(path)//2
                        tangent = path[mid+1]-path[mid-1]
                        length = np.linalg.norm(tangent)
                        if length > 0:
                            tangent = .055*tangent/length
                            side = .45*np.array([-tangent[1], tangent[0]])
                            head = np.array([path[mid]-tangent+side, path[mid], path[mid]-tangent-side])
                            segments.append(np.c_[head[:, 1]*np.cos(theta), head[:, 1]*np.sin(theta), head[:, 0]])
            self.streams.set_segments(segments)

    def draw_surface_velocity(self, ut, uz):
        """Fixed-position arrows show the (azimuthal, axial) velocity components.

        Arrow lengths use one scale for every frame. Their geometry follows
        the fluid section; these vectors contain no radial velocity component.
        These vectors do not advance any particle or simulation state.
        """
        segments = []
        radius = SURFACE_RADIUS
        for z in self.surface_z:
            v = self.surface_scale*np.array([np.interp(z, self.zc, ut), np.interp(z, self.zc, uz)])
            if np.linalg.norm(v) < 1e-8:
                continue
            # Local coordinates are circumferential arc length and height.
            shaft = np.linspace(-.5, .5, 9)[:, None]*v
            side = .13*np.array([-v[1], v[0]])
            head = np.array([.15*v+side, .5*v, .15*v-side])
            for theta in self.surface_theta:
                for points in (shaft, head):
                    a = theta + points[:, 0]/radius
                    segments.append(np.c_[radius*np.cos(a), radius*np.sin(a), z+points[:, 1]])
        self.surface_outline.set_segments(segments)
        self.surface_arrows.set_segments(segments)

    def draw_rotation(self, phases, angular, radii, heights):
        segments = []
        for phase, omega, radius, z in zip(phases, angular, radii, heights):
            direction = np.sign(omega)
            for offset in (0, 2*np.pi/3, 4*np.pi/3):
                angle = (phase+offset+np.pi) % (2*np.pi)-np.pi
                # Only the front opening exposes these rotation indicators.
                trail = angle - direction*np.linspace(.28, 0, 18)
                visible = (trail > self.front[0]+.05) & (trail < self.front[1]-.05)
                if visible.sum() > 1:
                    a = trail[visible]
                    segments.append(np.c_[radius*np.cos(a), radius*np.sin(a), np.full_like(a, z)])
                if visible[-1]:
                    tip = np.array([radius*np.cos(angle), radius*np.sin(angle), z])
                    tangent = direction*np.array([-np.sin(angle), np.cos(angle), 0])
                    radial = np.array([np.cos(angle), np.sin(angle), 0])
                    segments.append(np.array([tip-.13*tangent+.05*radial, tip,
                                              tip-.13*tangent-.05*radial]))
        self.rotation_outline.set_segments(segments)
        self.rotation.set_segments(segments)


def video(directory, lang, out, poster, fps=30, time_scale=6.0, poster_only=False):
    """Show circumferential motion alongside the meridional fields.

    Moving glyphs in the gap and axial view stay at fixed (r,z); only their
    display angle advances with sampled u_theta/r. Surface arrows instead
    stay at fixed positions and show the local tangential velocity vector.
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
    # Reconstruct the same axisymmetric data at several display heights.
    glyph_r = np.tile([1.28, 1.70], 4)
    glyph_z = np.repeat(lz*np.array([.125, .375, .625, .875]), 2)
    glyph_angular = np.array([
        [np.interp(r, rc, [np.interp(z, zc, row) for row in fields[2]+couette(rc)[:, None]])/r
         for r, z in zip(glyph_r, glyph_z)] for fields in saved
    ])
    glyph_phases = np.zeros_like(glyph_angular)
    glyph_phases[0] = np.linspace(-1.4, -.3, len(glyph_r))
    glyph_phases[1:] = glyph_phases[0] + np.cumsum(
        np.diff(times)[:, None]*(glyph_angular[:-1]+glyph_angular[1:])/2, axis=0)

    max_rotation = max(abs(W1), abs(W2), float(np.abs(angular).max()),
                       float(np.abs(glyph_angular).max()))
    # Four marks on the inner cylinder repeat every pi/2. Stay well below
    # half that interval per frame, so apparent reverse rotation is avoided.
    if max_rotation * (frame_times[1] - frame_times[0]) > np.pi / 8:
        raise ValueError("rotation is undersampled; increase fps or reduce time_scale")

    surface_ut = np.array([[np.interp(SURFACE_RADIUS, rc, col)
                            for col in (fields[2]+couette(rc)[:, None]).T] for fields in saved])
    surface_uz = np.array([[np.interp(SURFACE_RADIUS, rc, col)
                            for col in fields[4].T] for fields in saved])
    surface_limit = float(np.abs(surface_uz).max()) or 1.0
    surface_scale = .32/(float(np.hypot(surface_ut, surface_uz).max()) or 1.0)

    fig = plt.figure(figsize=(19.2, 9.6), dpi=100)
    cutaway = CutawayView(fig.add_axes([0, .16, .40, .70], projection='3d', computed_zorder=False),
                          rc, zc, lz, top, surface_limit, surface_scale, text, font)
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
                          cmap="cividis", vmin=min(0.0, profiles.min()),
                          vmax=max(abs(W1 * R1), float(profiles.max())), interpolation="bilinear")
    for ring in rings:
        end.add_patch(Circle((0, 0), ring, fill=False, edgecolor="white", lw=0.7, alpha=0.25))
    end.add_patch(Circle((0, 0), SURFACE_RADIUS, fill=False, edgecolor=SECTION_COLOR,
                         lw=1.8, zorder=3))
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
    end.text(0, -2.58, text["fluid_section"] % SURFACE_RADIUS, ha="center", va="center",
             fontproperties=font, fontsize=10, color=SECTION_COLOR)
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
    upper.set_title(text["dev"].replace(" $", "\n$", 1), fontproperties=font, fontsize=14)
    lower.set_title(text["speed"].replace(" $", "\n$", 1), fontproperties=font, fontsize=14)
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
        cut_paths = None
        if record != last_record:
            for artist in stream_artists:
                artist.remove()
            stream_artists = []
            cut_paths = []
            if saved[record][5].max() > 1e-3 * top:
                before = set(lower.get_children())
                stream = lower.streamplot(zz, rr, saved[record][4], saved[record][3],
                                 color="white", density=(1.4, 0.6), linewidth=0.65, arrowsize=0.8)
                stream_artists = [artist for artist in lower.get_children() if artist not in before]
                cut_paths = stream.lines.get_segments()
            last_record = record
        cutaway.draw(t, np.hypot(ur, uz), cut_paths,
                     (1-weight)*surface_ut[index]+weight*surface_ut[index+1],
                     (1-weight)*surface_uz[index]+weight*surface_uz[index+1])
        glyph_phase = glyph_phases[index] + glyph_angular[index]*offset + (
            glyph_angular[index+1]-glyph_angular[index])*offset**2/(2*interval)
        glyph_omega = (1-weight)*glyph_angular[index] + weight*glyph_angular[index+1]
        cutaway.draw_rotation(glyph_phase, glyph_omega, glyph_r, glyph_z)
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
                  video_section_z=record["metadata"]["lz"] / 8,
                  video_size=[1920, 960], video_cutaway_degrees=90,
                  video_surface_radius=SURFACE_RADIUS)
    lam, k = wavelength(args.run)
    record.update(axial_wavelength=lam, axial_pairs=k)
    (args.results / "runs.json").write_text(json.dumps(record, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({key: record[key] for key in record if key != "metadata"}, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
