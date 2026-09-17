#!/usr/bin/env python3
"""Publish the recorded coordinate comparison in the Japanese/English gallery."""
import hashlib
import html
import json
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
NAME = "kinetic_coordinates"
BEGIN = "<!-- kinetic-coordinates:begin -->"
END = "<!-- kinetic-coordinates:end -->"
NAV_BEGIN = "<!-- kinetic-coordinates:nav:begin -->"
NAV_END = "<!-- kinetic-coordinates:nav:end -->"
BASE = "../../examples/kinetic_coordinates"


def scientific(value):
    mantissa, exponent = f"{value:.2e}".split("e")
    return f'<span style="white-space:nowrap">{mantissa}×10<sup>{int(exponent)}</sup></span>'


def source_blocks(lang):
    labels = {
        "ja": ("Formurae ソース全文", "生成された Egison", "正規化結果 FEIR", "生成された Formura"),
        "en": ("Full Formurae source", "Generated Egison", "Normalized FEIR", "Generated Formura"),
    }
    blocks = []
    for suffix, label in zip(("fme", "egi", "feir", "fmr"), labels[lang]):
        source = (HERE / f"{NAME}.{suffix}").read_text().rstrip("\n")
        body = html.escape(source, quote=False)
        comment = r"(?m)^(--.*)$" if suffix in ("fme", "egi") else r"(?m)^([;#].*)$"
        body = re.sub(comment, r'<span class="c">\1</span>', body)
        opened = " open" if suffix == "fme" else ""
        unit = "行" if lang == "ja" else "lines"
        blocks.append(f'<details class="codebox" data-{suffix}="{NAME}/{NAME}.{suffix}"{opened}>'
                      f'<summary>{label} ({NAME}.{suffix}, {len(source.splitlines())} {unit})</summary>'
                      f'<pre>{body}</pre></details>')
    return "\n".join(blocks)


def generate(lang, report, source):
    grids = report["transport"]["cartesian"]["grids"]
    count = len(report["runs"])
    mass = scientific(report["max_mass_relative_drift"])
    momentum = scientific(report["max_momentum_absolute_drift"])
    uniform = scientific(report["max_uniform_error"])
    mode = scientific(report["shear"]["curved"]["mode_difference_from_cartesian"][-1])
    if lang == "ja":
        title = "座標を変えても同じ流れ：D2Q9の検証"
        description = "D2Q9は，二次元の九方向に移動する分布から流れを求める方法です。分布の移動を微分方程式で解き，直交座標・間隔が変わる直交座標・非直交の曲線座標で，同じ更新式を実行しました。物理的な九方向を固定して座標だけを変え，一様流，分布の移動，粘性で減衰する流れを比較します。"
        equation_note = "Jは面積を換算する係数，cは九方向の速度，fは各方向の分布，fᵉᑫは平衡分布，τは緩和時間です。速度の内積には計量（長さと角度を表す係数）を使います。"
        caption = "左：移動の厳密解との最大誤差。右：粘性で減衰する流れの，直交座標との振幅の差。格子間隔を半分にすると，どちらもおよそ4分の1になります。破線は二次精度の傾きです。"
        facts = f"<b>{count}通りの検証が通過。</b> 一様流の誤差は最大{uniform}，質量の相対変化は{mass}，物理的な運動量の絶対変化は{momentum}でした。{grids[-1]}×{grids[-1]}点で，曲線座標と直交座標との流れの振幅の差は{mode}でした。"
        table_caption = "移動の厳密解との最大誤差（各点で求めた9成分の誤差の長さを比較）"
        chart_label, order_label = "座標", "収束次数"
        chart_names = ("直交", "間隔が変わる直交", "非直交の曲線")
        order_note = f"収束次数は{grids[-2]}点から{grids[-1]}点への変化で評価しています。領域の大きさ，物理的な初期条件，終了時刻をそろえて比較しました。"
        code_label = "座標を変えても共通の更新式（実際のソースから抜粋）"
        scope = "初期条件・幾何・時間積分・検証用の物理量もすべてFormuraeに記述しています。この基礎実験は平面上の座標変換を扱います。一般の座標写像での一様流保存，壁・重力・水面を加えた計算は次の検証課題です。"
        more, checks, vector, reproduce = "モデルと再現手順", "全実行の条件・検証結果", "拡大できるグラフ（SVG）", "計算と検証の再現"
    else:
        title = "The same flow in different coordinates: a D2Q9 comparison"
        description = "D2Q9 represents two-dimensional flow with populations moving in nine directions. We solve their transport as a differential equation and use the same update equations in Cartesian, stretched Cartesian and nonorthogonal curved coordinates. The nine physical directions stay fixed as their coordinate components change. We compare uniform flow, population transport and viscously decaying flow."
        equation_note = "J converts coordinate area to physical area; c denotes the nine velocities, f their populations, fᵉᑫ the equilibrium populations, and τ the relaxation time. Velocity inner products use the metric, which specifies lengths and angles."
        caption = "Left: maximum error against the exact transport solution. Right: the decaying flow’s amplitude difference from Cartesian coordinates. Halving the grid spacing reduces both errors by roughly a factor of four. Dashed lines indicate second-order convergence."
        facts = f"<b>All {count} runs passed verification.</b> Maximum uniform-flow error: {uniform}; relative mass drift: {mass}; absolute physical-momentum drift: {momentum}. On the {grids[-1]}×{grids[-1]} grid, the flow amplitude difference between curved and Cartesian coordinates was {mode}."
        table_caption = "Maximum transport error against the exact solution (norm of the nine population errors at each point)"
        chart_label, order_label = "Coordinates", "Order"
        chart_names = ("Cartesian", "Stretched Cartesian", "Curved, nonorthogonal")
        order_note = f"Orders are measured from {grids[-2]} to {grids[-1]} points per coordinate. Physical domain size, initial conditions and final time are held fixed."
        code_label = "The same update equations in every chart (excerpt from the actual source)"
        scope = "Initial conditions, geometry, time integration and physical diagnostics are also written entirely in Formurae. This experiment changes coordinates on a plane. Uniform-flow preservation under more general maps, and simulations with walls, gravity and a free surface, are the next validation tasks."
        more, checks, vector, reproduce = "Model and reproduction", "All run settings and verification results", "Scalable graph (SVG)", "Reproduce the simulations and checks"
    rows = []
    for chart, label in zip(("cartesian", "stretched", "curved"), chart_names):
        values = report["transport"][chart]
        if values["grids"] != grids:
            raise ValueError("inconsistent comparison grids")
        errors = "".join(f'<td style="padding:6px;white-space:nowrap">{scientific(value)}</td>'
                         for value in values["final_max_population_error"])
        rows.append(f'<tr><th scope="row" style="padding:6px;text-align:left;white-space:nowrap">{label}</th>'
                    f'{errors}<td style="padding:6px">{values["observed_orders"][-1]:.3f}</td></tr>')
    headings = "".join(f'<th scope="col" style="padding:6px">{n}×{n}</th>' for n in grids)
    excerpt = "macro rhs Q =\n" + source.split("macro rhs Q =\n", 1)[1].split("\n\n", 1)[0]
    return f'''{BEGIN}
<article class="card featured" id="kinetic-coordinates">
<h3>{title}</h3>
<p class="description">{description}</p>
<div class="math">∂<sub>t</sub>f<sub>a</sub> = −J<sup>−1</sup>∂<sub>i</sub>(J c<sub>a</sub><sup>i</sup> f<sub>a</sub>) + (f<sub>a</sub><sup>eq</sup> − f<sub>a</sub>)/τ</div>
<p class="description">{equation_note}</p>
<div class="imgs"><a href="{BASE}/results/convergence.svg"><img src="{BASE}/results/convergence.png" alt="{html.escape(caption)}" width="1800" height="756" loading="lazy"></a></div>
<p class="cap">{caption}</p>
<p class="facts">{facts}</p>
<div style="overflow-x:auto;margin:12px 0">
<table style="width:100%;min-width:520px;border-collapse:collapse;font-size:12.5px;text-align:right">
<caption style="text-align:left;padding-bottom:8px">{table_caption}</caption>
<thead><tr><th scope="col" style="text-align:left;padding:6px">{chart_label}</th>{headings}<th scope="col" style="padding:6px">{order_label}</th></tr></thead>
<tbody>{''.join(rows)}</tbody></table></div>
<p class="description">{order_note}</p>
<div class="codebox"><div class="head">{code_label}</div><pre style="white-space:pre-wrap;overflow-wrap:anywhere">{html.escape(excerpt)}</pre></div>
<p class="description">{scope}</p>
<p class="facts"><a href="{BASE}/README.md">{more}</a> · <a href="{BASE}/results/verification.json">{checks}</a> · <a href="{BASE}/results/convergence.svg">{vector}</a><br>{reproduce}: <code>make kinetic-coordinates-verify</code></p>
{source_blocks(lang)}
</article>
{END}'''


def replace_or_insert(page, begin, end, content, anchor):
    if begin in page:
        before, rest = page.split(begin, 1)
        _, after = rest.split(end, 1)
        return before + content + after
    if page.count(anchor) != 1:
        raise ValueError(f"expected one insertion point: {anchor}")
    return page.replace(anchor, content + "\n" + anchor, 1)


def main():
    source = (HERE / f"{NAME}.fme").read_text()
    report = json.loads((HERE / "results/verification.json").read_text())
    if not report["passed"] or report["source_sha256"] != hashlib.sha256(source.encode()).hexdigest():
        raise ValueError("verification must match the current model")
    for filename in ("convergence.png", "convergence.svg"):
        if not (HERE / "results" / filename).is_file():
            raise FileNotFoundError(filename)
    for lang in ("ja", "en"):
        path = ROOT / "html" / lang / "gallery.html"
        page = path.read_text()
        card = generate(lang, report, source)
        page = replace_or_insert(page, BEGIN, END, card, '<article class="card featured" id="breaking-wave3d">')
        label = "座標を変えても同じ流れ：D2Q9の検証" if lang == "ja" else "The same flow in different coordinates: D2Q9"
        nav = f'{NAV_BEGIN}<p><a href="#kinetic-coordinates">{label}</a></p>{NAV_END}'
        page = replace_or_insert(page, NAV_BEGIN, NAV_END, nav, '  <p><a href="#breaking-wave3d">')
        path.write_text(page)
        print(path)


if __name__ == "__main__":
    main()
