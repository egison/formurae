#!/usr/bin/env python3
"""Add the verified finite-volume transport experiment to both galleries."""
import hashlib
import html
import json
import math
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
NAME = "kinetic_fv"
SLUG = "kinetic-fv"
BASE = "../../examples/kinetic_fv"
BEGIN = "<!-- kinetic-fv:begin -->"
END = "<!-- kinetic-fv:end -->"
NAV_BEGIN = "<!-- kinetic-fv:nav:begin -->"
NAV_END = "<!-- kinetic-fv:nav:end -->"


def load_report():
    report = json.loads((HERE / "results/verification.json").read_text())
    if report["source_sha256"] != hashlib.sha256((HERE / f"{NAME}.fme").read_bytes()).hexdigest():
        raise ValueError("recorded verification does not match the current model")
    runs = report["runs"]
    expected = {(n, chart, scenario, "upwind") for n in (16, 32, 64)
                for chart in ("cartesian", "mapped") for scenario in ("uniform", "smooth", "sharp")}
    expected |= {(n, chart, "sharp", "centered") for n in (16, 32, 64) for chart in ("cartesian", "mapped")}
    keys = [(r["grid"], r["chart"], r["scenario"], r["method"]) for r in runs]
    if len(keys) != len(expected) or set(keys) != expected:
        raise ValueError("publish only the complete 24-run comparison")
    for run in runs:
        final = run["final"]
        if not all(math.isfinite(v) for v in final.values()):
            raise ValueError("nonfinite diagnostic")
        if not (run["population_mass_relative_drift"] < 1e-10 and run["max_closure"] < 1e-10
                and 0 < run["max_cfl"] < 1 and final["minArea"] > 0):
            raise ValueError("failed conservation, geometry or time-step check")
        if run["method"] == "upwind" and final["lowest"] < -1e-12:
            raise ValueError("upwind positivity check failed")
        if run["scenario"] == "uniform" and final["error"] >= 1e-12:
            raise ValueError("uniform-state check failed")
    return report


def scientific(value):
    mantissa, exponent = f"{value:.2e}".split("e")
    return f'<span style="white-space:nowrap">{mantissa}×10<sup>{int(exponent)}</sup></span>'


def source_blocks(lang):
    labels = {"ja": ("Formurae ソース全文", "生成された Egison", "正規化結果 FEIR", "生成された Formura"),
              "en": ("Full Formurae source", "Generated Egison", "Normalized FEIR", "Generated Formura")}
    blocks = []
    for extension, label in zip(("fme", "egi", "feir", "fmr"), labels[lang]):
        source = (HERE / f"{NAME}.{extension}").read_text().rstrip("\n")
        body = html.escape(source, quote=False)
        comment = r"(?m)^(--.*)$" if extension in ("fme", "egi") else r"(?m)^([;#].*)$"
        body = re.sub(comment, r'<span class="c">\1</span>', body)
        opened = " open" if extension == "fme" else ""
        unit = "行" if lang == "ja" else "lines"
        blocks.append(f'<details class="codebox" data-{extension}="{NAME}/{NAME}.{extension}"{opened}>'
                      f'<summary>{label} ({NAME}.{extension}, {len(source.splitlines())} {unit})</summary>'
                      f'<pre>{body}</pre></details>')
    return "\n".join(blocks)


def generate(lang, report, source):
    runs = report["runs"]
    grids = sorted({r["grid"] for r in runs})
    upwind = [r for r in runs if r["method"] == "upwind"]
    mass = scientific(max(r["population_mass_relative_drift"] for r in runs))
    uniform = scientific(max(r["final"]["error"] for r in upwind if r["scenario"] == "uniform"))
    cfl = max(r["max_cfl"] for r in upwind)
    if lang == "ja":
        title = "面の両側を明示する：D2Q9の有限体積輸送"
        description = "D2Q9（二次元の九方向の分布）の移動を，セル内の量と共有面の流量から求める有限体積法で検証します。風上法は，流れが来る側のセル平均を面の流量に使う方法です。直交格子と曲がった格子に同じ更新式を使い，一様な分布，滑らかな分布，ゼロを含む急な分布を比較しました。"
        equation_note = "Fは共有面の流量，Bは物理的な移動速度と面の向き・長さから求める係数です。fの小さい／大きい計算座標側の値を別々に選び，隣接セルには同じ面の流量を逆符号で加えます。"
        caption = "左：滑らかな移動問題の誤差。破線は一次精度の傾きです。右：64×64セルの急な分布で，全ステップ・全方向を通した最小値。風上法は0以上を保ち，比較用の中心的な流量では負値が発生しました。右の比較は両方とも前進Euler法による時間積分です。"
        facts = f"<b>24条件の検証が通過。</b> 風上法の18条件では途中の全ステップを含めて負値がなく，全24条件で各方向の総量の相対変化は最大{mass}でした。一様分布の最大誤差は{uniform}。非負性に必要な時間刻みの条件（1以下）の左辺は最大{cfl:.3f}でした。"
        table_caption = "滑らかな移動問題：重みで割った各分布の最大誤差"
        chart_label, order_label = "格子", "実測次数"
        chart_names = ("直交", "曲がった格子")
        order_note = "実測次数は32→64セルで評価しています。参照するセル平均には二次精度の中点近似を使い，厳密なセル積分とは区別しています。一次風上法は分布をなだらかにする傾向が強く，高精度化が次の課題です。"
        code_label = "両方の格子に共通の輸送処理（実際のソースから抜粋）"
        sample_note = "<code>sampleLower(Q,1,0)</code>／<code>sampleUpper(Q,1,0)</code> は，x方向の面に接する小さい／大きい計算座標側のセル値を直接選びます。補間や微分は行いません。座標の定義・面の幾何係数と，この輸送処理を分けています。"
        scope = "初期条件・幾何・時間積分・診断値はすべてFormuraeに記述し，通常の生成経路で実行しています。今回は周期境界での輸送を検証しました。分布を平衡へ近づける衝突項，壁・重力・水面との結合は次の段階です。"
        previous = "<a href=\"#kinetic-coordinates\">前の中心差分による実験</a>は，滑らかな分布と粘性で減衰する流れの検証です。今回の右図にある「中心的な流量＋前進Euler法」は，前の三段の時間積分と同じ計算法ではありません。"
        more, checks, vector, reproduce = "設計と再現手順", "24条件の検証結果", "拡大できるグラフ（SVG）", "計算と検証の再現"
    else:
        title = "Explicit values on both sides of a face: finite-volume D2Q9 transport"
        description = "We test transport of D2Q9 populations—nine velocity populations in two dimensions—with a finite-volume method: cell contents change through shared-face fluxes. Upwinding uses the cell average on the side the flow comes from. The same update runs on Cartesian and mapped grids, with uniform, smooth and sharp profiles, including zero populations."
        equation_note = "F is the shared-face flux. B combines the physical velocity with the face orientation and length. Values from the lower and upper computational-coordinate sides are selected separately, and the same face flux enters adjacent cells with opposite signs."
        caption = "Left: smooth-transport error; the dashed line shows a first-order slope. Right: the minimum across all steps and populations for a sharp profile on a 64×64 grid. Upwinding stays nonnegative, while the centered-flux comparison produces negative values. Both methods in the right panel use forward Euler time integration."
        facts = f"<b>All 24 verification cases passed.</b> The 18 upwind runs stayed nonnegative at every step. Across all 24 runs, the maximum relative drift of each population’s total was {mass}; maximum uniform-state error was {uniform}. The largest time-step bound for positivity was {cfl:.3f}, below the required limit of 1."
        table_caption = "Smooth transport: maximum error in each population divided by its weight"
        chart_label, order_label = "Grid geometry", "Measured order"
        chart_names = ("Cartesian", "Mapped")
        order_note = "Orders are measured from 32 to 64 cells per coordinate. Reference cell averages use a second-order midpoint approximation, rather than exact cell integrals. First-order upwinding noticeably smooths the profile; higher-order transport is the next step."
        code_label = "Transport shared by both grids (excerpt from the actual source)"
        sample_note = "<code>sampleLower(Q,1,0)</code> and <code>sampleUpper(Q,1,0)</code> directly select the source-cell values on the lower and upper computational-coordinate sides of an x face. They perform neither interpolation nor differentiation. The coordinate map and face geometry are defined separately from this transport procedure."
        scope = "Initial conditions, geometry, time integration and diagnostics are all written in Formurae and run through the normal generation pipeline. This experiment verifies transport with periodic boundaries. Collisions that relax populations toward equilibrium, walls, gravity and a free surface are the next stage."
        previous = "The <a href=\"#kinetic-coordinates\">earlier centered-difference experiment</a> checks smooth profiles and viscously decaying flow. The centered-flux + forward-Euler comparison in the right panel uses a different time integrator from that experiment’s three-stage method."
        more, checks, vector, reproduce = "Design and reproduction", "All 24 verification cases", "Scalable graph (SVG)", "Reproduce the simulations and checks"
    rows = []
    for chart, label in zip(("cartesian", "mapped"), chart_names):
        smooth = sorted((r for r in upwind if r["chart"] == chart and r["scenario"] == "smooth"), key=lambda r:r["grid"])
        cells = "".join(f'<td style="padding:6px;white-space:nowrap">{scientific(r["final"]["error"])}</td>' for r in smooth)
        rows.append(f'<tr><th scope="row" style="text-align:left;padding:6px">{label}</th>{cells}'
                    f'<td style="padding:6px">{report["orders"][chart][-1]:.3f}</td></tr>')
    headings = "".join(f'<th scope="col" style="padding:6px">{n}×{n}</th>' for n in grids)
    excerpt = "macro transport Q =\n" + source.split("macro transport Q =\n", 1)[1].split("\n\n", 1)[0]
    return f'''{BEGIN}
<article class="card featured" id="{SLUG}">
<h3>{title}</h3>
<p class="description">{description}</p>
<div class="math">F = max(B, 0) f<sub>lower</sub> + min(B, 0) f<sub>upper</sub></div>
<p class="description">{equation_note}</p>
<div class="imgs"><a href="{BASE}/results/comparison.svg"><img src="{BASE}/results/comparison.png" alt="{html.escape(caption)}" width="1800" height="756" loading="lazy"></a></div>
<p class="cap">{caption}</p>
<p class="facts">{facts}</p>
<div style="overflow-x:auto;margin:12px 0">
<table style="width:100%;min-width:520px;border-collapse:collapse;font-size:12.5px;text-align:right">
<caption style="text-align:left;padding-bottom:8px">{table_caption}</caption>
<thead><tr><th scope="col" style="text-align:left;padding:6px">{chart_label}</th>{headings}<th scope="col" style="padding:6px">{order_label}</th></tr></thead>
<tbody>{''.join(rows)}</tbody></table></div>
<p class="description">{order_note}</p>
<div class="codebox"><div class="head">{code_label}</div><pre style="white-space:pre-wrap;overflow-wrap:anywhere">{html.escape(excerpt)}</pre></div>
<p class="description">{sample_note}</p>
<p class="description">{previous}</p>
<p class="description">{scope}</p>
<p class="facts"><a href="{BASE}/README.md">{more}</a> · <a href="{BASE}/results/verification.json">{checks}</a> · <a href="{BASE}/results/comparison.svg">{vector}</a><br>{reproduce}: <code>make kinetic-fv-verify</code></p>
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
    return page.replace(anchor, content+"\n"+anchor, 1)


def main():
    report = load_report()
    source = (HERE / f"{NAME}.fme").read_text()
    for filename in ("comparison.png", "comparison.svg"):
        if not (HERE / "results" / filename).is_file():
            raise FileNotFoundError(filename)
    for lang in ("ja", "en"):
        path = ROOT / "html" / lang / "gallery.html"
        page = replace_or_insert(path.read_text(), BEGIN, END, generate(lang, report, source),
                                 "<!-- kinetic-coordinates:begin -->")
        label = "面の両側を明示する：D2Q9の有限体積輸送" if lang == "ja" else "Explicit face-side values: finite-volume D2Q9 transport"
        nav = f'{NAV_BEGIN}<p><a href="#{SLUG}">{label}</a></p>{NAV_END}'
        page = replace_or_insert(page, NAV_BEGIN, NAV_END, nav, "<!-- kinetic-coordinates:nav:begin -->")
        path.write_text(page)
        print(path)


if __name__ == "__main__":
    main()
