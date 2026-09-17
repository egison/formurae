#!/usr/bin/env python3
"""Draw saved Formurae fields. No simulation or diagnostic reconstruction.

Physical coordinate transforms below are used only to position pixels/arrows.
Dividing stored momentum by stored mass converts two already-computed fields
to a velocity for display. Neither operation is fed back into a simulation.
"""
import argparse
import html
import json
from pathlib import Path
import re

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.animation import FFMpegWriter
from matplotlib.patches import Polygon, Rectangle
import numpy as np

from wave_frames import BUILD, MODELS, ROOT, sha, write_json

MEDIA = ROOT / "gallery/video/waves"
IDS = dict(zip(MODELS, ("shallow-water", "lbm-d3q19", "kinetic-coordinates", "kinetic-fv",
                        "kinetic-viscosity", "kinetic-hydrostatic")))
CAPTIONS = {
    "shallowwater": {
        "ja": "初めに1%だけ盛り上がった水面が，左右に分かれて進みます。上段は水面の高さの変化を縦に拡大し，下段は水底からの水深を表示しています。保存した水深 h の断面です。浅水方程式では，巻き込みや飛沫は表現していません。",
        "en": "An initial 1% surface bump splits into two traveling waves. The upper view enlarges the vertical surface variation; the lower view shows the full depth from the bed. Both draw the recorded depth h. This shallow-water model does not represent overturning or spray.",
    },
    "lbm_d3q19": {
        "ja": "色と矢印は y 方向の流速です。上段は三次元計算の中央 z 断面，下段はその流速の分布で，破線は初期値です。粘性で流れが弱まる様子を，固定した色・矢印の尺度で表示しています。断面の縦方向は拡大表示です。水面を持たない流体の計算です。",
        "en": "Color and arrows show the y velocity on the middle z slice of the 3D calculation. Below is its velocity profile; the dashed curve is the initial state. Fixed color and arrow scales show viscous decay. The slice is enlarged vertically. This flow has no free surface.",
    },
    "kinetic_coordinates": {
        "ja": "九方向のうち右向きに移動する一成分の分布を，その重みで割って色付けしています。左は直交格子，右は曲線格子で，どちらも実際の空間上に描いています。薄い線が計算格子です。同じ模様が右へ移動する様子を比較できます。色は水面の高さではありません。",
        "en": "Color shows the right-moving population, divided by its weight. Cartesian (left) and curved (right) grids are drawn in physical space, with faint computational grid lines. Compare the same pattern traveling to the right. Color does not represent surface height.",
    },
    "kinetic_fv": {
        "ja": "右向きに移動する一成分の分布を色で表示しています。左は一次精度の風上法，右は急な変化を保ちやすい高精度の方法で，同じ曲線格子・時間積分を使います。境目のぼやけ方を比較できます。色の範囲は両側とも0〜1で固定しています。水と空気の境界ではありません。",
        "en": "Color shows the right-moving population divided by its weight. First-order upwinding (left) and higher-order limited reconstruction (right) use the same mapped grid and time integrator. Compare smearing at the edges. Both use a fixed 0–1 scale. These are population boundaries, not a water–air interface.",
    },
    "kinetic_viscosity": {
        "ja": "色は y 方向の流速，矢印は流れの向きと速さです。直交格子と曲線格子の同じ流れを実際の空間に描き，粘性で少しずつ弱まる過程を比較します。色と矢印の尺度は固定しています。水面を持たない流体の計算です。",
        "en": "Color shows y velocity; arrows show the flow direction and speed. The same viscously decaying flow on Cartesian and mapped grids is drawn in physical space. Color and arrow scales remain fixed. This fluid calculation has no free surface.",
    },
    "kinetic_hydrostatic": {
        "ja": "色は静水時の密度からのずれの絶対値，矢印は流速です。左は重力と圧力の釣り合いを保つ計算，中央はその工夫を使わない比較，右は左の方法に小さな密度の乱れを加えた計算です。上下の線は壁で，内部全体を流体が満たしています。3枚で色と矢印の尺度をそろえています。水面の映像ではありません。",
        "en": "Color shows the absolute density deviation from hydrostatic rest; arrows show velocity. Left: the method preserving gravity–pressure balance. Middle: an unbalanced control. Right: the balanced method with a small initial density disturbance. Top and bottom are walls, with fluid filling the interior. All panels share fixed scales. This is not a free-surface image.",
    },
}


def load(name):
    base = BUILD / name
    report = json.loads((base / "capture.json").read_text())
    if report["source_sha256"] != sha(ROOT / "examples" / name / f"{name}.fme"):
        raise ValueError(f"stale frames: {name}")
    frames = {}
    for case, record in report["cases"].items():
        path = base / case / "frames.npz"
        if sha(path) != record["archive_sha256"] or not record["baseline_diagnostics_identical"]:
            raise ValueError(f"unverified frames: {name}/{case}")
        with np.load(path) as values:
            frames[case] = {key: values[key] for key in values.files}
        assert np.isfinite(frames[case]["fields"]).all()
    first = next(iter(frames.values()))
    for values in frames.values():
        np.testing.assert_array_equal(values["time"], first["time"])
    return report, frames, first["time"]


def canvas(title, subtitle, count=1):
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 11,
                         "axes.spines.top": False, "axes.spines.right": False,
                         "axes.labelcolor": "#364c5b", "text.color": "#213b4b",
                         "xtick.color": "#526575", "ytick.color": "#526575"})
    fig = plt.figure(figsize=(12, 6.8), dpi=100, facecolor="#f5f8fa")
    fig.text(0.055, 0.94, title, weight="bold", size=20)
    fig.text(0.055, 0.895, subtitle, size=11)
    clock = fig.text(0.945, 0.94, "", ha="right", size=14, family="monospace")
    fig.text(0.055, 0.035, "FORMURAE  /  Recorded simulation fields", color="#647786", size=10)
    if count > 1:
        axes = fig.subplots(1, count)
        fig.subplots_adjust(left=0.055, right=0.88, top=0.8, bottom=0.19, wspace=0.22)
        return fig, axes, clock
    return fig, None, clock


def save(name, report, times, fig, clock, update, footer):
    MEDIA.mkdir(parents=True, exist_ok=True)
    fig.text(0.945, 0.035, footer, ha="right", size=10, color="#647786")
    fps = 15 if len(times) > 110 else 12
    writer = FFMpegWriter(fps=fps, codec="libx264", extra_args=["-crf", "20", "-pix_fmt", "yuv420p", "-movflags", "+faststart"])
    path = MEDIA / f"{name}.mp4"
    with writer.saving(fig, str(path), dpi=100):
        for index, time in enumerate(times):
            update(index)
            clock.set_text(f"t = {time:7.3f}")
            if index == len(times) // 3:
                fig.savefig(MEDIA / f"{name}.png", dpi=100, facecolor=fig.get_facecolor())
            writer.grab_frame(facecolor=fig.get_facecolor())
    plt.close(fig)
    write_json(MEDIA / f"{name}.json", dict(capture=report, frames=len(times), fps=fps,
               physical_time=[float(times[0]), float(times[-1])],
               renderer_sha256=sha(Path(__file__)), movie_sha256=sha(path),
               poster_sha256=sha(MEDIA / f"{name}.png")))
    print(f"{name}: {len(times)} frames rendered", flush=True)


def surface(name, report, frames, times):
    height = frames["surface"]["fields"][:, 0, 4, :]
    x = np.arange(height.shape[1]) * 0.25
    fig, _, clock = canvas("Shallow-water pulse", "A 1% surface bump splits into two traveling waves")
    axes = [fig.add_axes([0.085, 0.40, 0.86, 0.38]), fig.add_axes([0.085, 0.14, 0.86, 0.14])]
    artists = []
    for ax, floor, top, title in zip(axes, [0.997, 0], [1.012, 1.1],
                                    ["Surface detail  /  vertical scale enlarged", "Full depth view"]):
        ax.set(xlim=(0, 64), ylim=(floor, top), ylabel="Height h")
        ax.set_title(title, loc="left", fontsize=11, pad=10)
        ax.set_facecolor("#edf4f8")
        water = Polygon([[0, floor], [64, floor]], closed=True, color="#53abc8", alpha=0.8)
        ax.add_patch(water)
        line, = ax.plot(x, height[0], color="#08658f", lw=2)
        ax.axhline(1, color="#78909f", lw=1, ls="--")
        artists.append((water, line, floor))
    axes[0].ticklabel_format(axis="y", useOffset=False)
    axes[1].set_xlabel("x")
    def update(index):
        for water, line, floor in artists:
            water.set_xy(np.column_stack((np.r_[x[0], x, x[-1]], np.r_[floor, height[index], floor])))
            line.set_ydata(height[index])
    save(name, report, times, fig, clock, update, "256 cells across x  /  periodic domain")


def mapped_grid(size, chart, kind, edges=False):
    h = 2*np.pi/size
    if kind == "hydro":
        q = np.arange(size+1)*h if edges else (np.arange(size)+0.5)*h
    else:
        q = (np.arange(size+1)-0.5)*h if edges else np.arange(size)*h
    x, y = np.meshgrid(q, q)
    if chart == "cartesian":
        return x, y
    if kind == "coordinates":
        return x + 0.2*np.sin(x) + 0.3*np.sin(y), y
    return x + 0.2*np.sin(x)*np.sin(y), y + 0.15*np.sin(x)*np.sin(y)


def grid_lines(ax, x, y, stride):
    for k in range(0, x.shape[0], stride):
        ax.plot(x[k], y[k], color="#345367", alpha=0.2, lw=0.5)
        ax.plot(x[:, k], y[:, k], color="#345367", alpha=0.2, lw=0.5)


def panels(name, report, frames, times):
    if name == "kinetic_coordinates":
        kind, cases, labels = "coordinates", ["cartesian", "curved"], ["Cartesian grid", "Curved grid"]
        title, subtitle = "The same transport in two coordinate systems", "One of nine populations, moving to the right  /  64 × 64 cells"
        low, high, cmap, color_label = 0.98, 1.02, "viridis", "Population / weight"
    elif name == "kinetic_fv":
        kind, cases, labels = "fv", ["upwind", "muscl"], ["First-order upwind", "Higher-order reconstruction"]
        title, subtitle = "Preserving sharp population boundaries", "Same mapped grid and two-stage time integrator  /  64 × 64 cells"
        low, high, cmap, color_label = 0, 1, "viridis", "Population / weight"
    elif name == "kinetic_viscosity":
        kind, cases, labels = "viscosity", ["cartesian", "mapped"], ["Cartesian grid", "Curved grid"]
        title, subtitle = "A flow slowly weakens through viscosity", "Color: y velocity  /  Arrows: physical velocity  /  64 × 64 cells"
        low, high, cmap, color_label = -0.02, 0.02, "RdBu_r", "y velocity"
    else:
        kind, cases, labels = "hydro", ["balanced", "ordinary", "disturbed"], ["Balanced rest", "Unbalanced control", "Small disturbance"]
        title, subtitle = "Gravity and pressure in balance", "Color: density deviation from rest  /  Arrows: velocity  /  32 × 32 cells"
        low, high, cmap, color_label = 0, 0.001, "YlOrBr", "|density − rest density|"
    fig, axes, clock = canvas(title, subtitle, len(cases))
    size = report["settings"]["grid"][0]
    meshes, arrows, values = [], [], []
    for ax, case, label in zip(axes, cases, labels):
        chart = "cartesian" if case == "cartesian" else "mapped"
        xe, ye = mapped_grid(size, chart, kind, edges=True)
        xc, yc = mapped_grid(size, chart, kind)
        data = frames[case]["fields"]
        velocity = None
        if kind == "hydro":
            data = data[:, :, 1:-1, :]  # omit the two wall guard rows
            color = data[:, 0]
            velocity = data[:, 2:4] / data[:, 1:2]
        elif kind == "viscosity":
            velocity = data[:, 1:3] / data[:, :1]
            color = velocity[:, 1]
        else:
            color = 9*data[:, 0]
        mesh = ax.pcolormesh(xe, ye, color[0], shading="flat", cmap=cmap, vmin=low, vmax=high, rasterized=True)
        grid_lines(ax, xe, ye, max(1, size//8))
        ax.set(title=label, xlabel="Physical x", ylabel="Physical y", aspect="equal")
        ax.set_xticks([0, np.pi, 2*np.pi], ["0", "π", "2π"])
        ax.set_yticks([0, np.pi, 2*np.pi], ["0", "π", "2π"])
        ax.set_xlim(-0.45, 2*np.pi+0.35)
        ax.set_ylim(-0.35, 2*np.pi+0.35)
        if kind == "hydro":
            ax.hlines([0, 2*np.pi], 0, 2*np.pi, color="#344f5e", lw=2)
        quiver = None
        stride = max(1, size//10)
        if velocity is not None:
            scale = 0.0015 if kind == "hydro" else 0.035
            quiver = ax.quiver(xc[::stride, ::stride], yc[::stride, ::stride],
                              velocity[0, 0, ::stride, ::stride], velocity[0, 1, ::stride, ::stride],
                              angles="xy", scale_units="xy", scale=scale, color="#263d4d",
                              width=0.005, minshaft=1, minlength=0)
            if kind == "hydro":
                quiver.set_clip_path(Rectangle((0, 0), 2*np.pi, 2*np.pi, transform=ax.transData))
            key = 0.0005 if kind == "hydro" else 0.01
            position = ax.get_position()
            ax.quiverkey(quiver, position.x0 + position.width/2, 0.103, key,
                         f"speed {key:g}", labelpos="S", coordinates="figure")
        meshes.append(mesh)
        arrows.append((quiver, velocity, stride))
        values.append(color)
    colorbar = fig.colorbar(meshes[0], cax=fig.add_axes([0.905, 0.27, 0.018, 0.40]))
    colorbar.set_label(color_label, size=10)
    def update(index):
        for mesh, color, (quiver, velocity, stride) in zip(meshes, values, arrows):
            mesh.set_array(color[index].ravel())
            if quiver is not None:
                quiver.set_UVC(velocity[index, 0, ::stride, ::stride], velocity[index, 1, ::stride, ::stride])
    save(name, report, times, fig, clock, update, "Fixed scales  /  No free surface in this model")


def lbm(name, report, frames, times):
    velocity = frames["shear"]["fields"][:, 0]
    fig, _, clock = canvas("Viscous decay in a three-dimensional fluid", "Color and arrows: y velocity  /  D3Q19  /  Middle z slice")
    ax = fig.add_axes([0.075, 0.54, 0.80, 0.23])
    mesh = ax.imshow(velocity[0], origin="lower", extent=(-0.5, 63.5, -0.5, 3.5),
                     aspect="auto", cmap="RdBu_r", vmin=-0.05, vmax=0.05, interpolation="nearest")
    x, y = np.meshgrid(np.arange(0, 64, 4), np.arange(4))
    arrows = ax.quiver(x, y, np.zeros_like(x), velocity[0, :, ::4], angles="xy", scale_units="xy",
                       scale=0.06, color="#263d4d", width=0.003, minlength=0)
    ax.set(xlabel="x", ylabel="y")
    ax.set_title("Spatial slice  /  y direction enlarged", loc="left", size=11, pad=10)
    fig.colorbar(mesh, cax=fig.add_axes([0.90, 0.54, 0.018, 0.23])).set_label("y velocity")
    profile = fig.add_axes([0.075, 0.16, 0.80, 0.23])
    profile.plot(np.arange(64), velocity[0, 2], "--", color="#879daa", lw=1.3, label="Initial")
    line, = profile.plot(np.arange(64), velocity[0, 2], color="#076b98", lw=2.5, label="Current")
    profile.set(xlabel="x", ylabel="y velocity", xlim=(0, 64), ylim=(-0.055, 0.055))
    profile.axhline(0, color="#b3c4ce", lw=0.7)
    profile.legend(loc="upper right", frameon=False, ncol=2)
    def update(index):
        mesh.set_data(velocity[index])
        arrows.set_UVC(np.zeros_like(x), velocity[index, :, ::4])
        line.set_ydata(velocity[index, 2])
    save(name, report, times, fig, clock, update, "64 × 4 × 4 cells  /  Fixed scales  /  No free surface")


def render(name):
    report, frames, times = load(name)
    if name == "shallowwater":
        surface(name, report, frames, times)
    elif name == "lbm_d3q19":
        lbm(name, report, frames, times)
    else:
        panels(name, report, frames, times)


def video_html(name, lang):
    metadata = json.loads((MEDIA / f"{name}.json").read_text())
    if metadata["capture"]["source_sha256"] != sha(ROOT / "examples" / name / f"{name}.fme"):
        raise ValueError(f"stale movie: {name}")
    for suffix, key in (("mp4", "movie_sha256"), ("png", "poster_sha256")):
        if sha(MEDIA / f"{name}.{suffix}") != metadata[key]:
            raise ValueError(f"changed media: {name}.{suffix}")
    caption = html.escape(CAPTIONS[name][lang])
    fallback = "動画を開く" if lang == "ja" else "Open video"
    base = f"../../gallery/video/waves/{name}"
    return f'''<!-- wave-movie:{name}:begin -->
<div class="imgs"><video controls loop muted playsinline preload="none" width="1200" height="680" poster="{base}.png" aria-label="{caption}"><source src="{base}.mp4" type="video/mp4"><a href="{base}.mp4">{fallback}</a></video></div>
<p class="cap">{caption}</p>
<!-- wave-movie:{name}:end -->'''


def publish():
    for lang in ("ja", "en"):
        page = ROOT / "html" / lang / "waves.html"
        text = page.read_text()
        for name in MODELS:
            snippet = video_html(name, lang)
            pattern = rf"<!-- wave-movie:{name}:begin -->.*?<!-- wave-movie:{name}:end -->"
            if re.search(pattern, text, re.S):
                text, count = re.subn(pattern, lambda _: snippet, text, flags=re.S)
                assert count == 1
            else:
                card = re.search(rf'<(?:article|div) class="card featured" id="{IDS[name]}">', text)
                if card is None:
                    raise ValueError(f"missing card: {name}")
                # Place each spatial movie before the first graph or source listing.
                position = re.search(r'<div class="imgs">|<details class="codebox"', text[card.end():])
                if position is None:
                    raise ValueError(f"missing insertion point: {name}")
                offset = card.end() + position.start()
                text = text[:offset] + snippet + "\n" + text[offset:]
        page.write_text(text)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--publish-only", action="store_true")
    parser.add_argument("--models", nargs="+", choices=MODELS, default=list(MODELS))
    args = parser.parse_args()
    if not args.publish_only:
        for name in args.models:
            render(name)
    if all((MEDIA / f"{name}.json").exists() for name in MODELS):
        publish()
