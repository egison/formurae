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
    expected |= {(n, chart, scenario, "muscl") for n in (16, 32, 64)
                 for chart in ("cartesian", "mapped") for scenario in ("uniform", "smooth", "sharp")}
    expected |= {(n, chart, "smooth", "upwind-rk2") for n in (16, 32, 64) for chart in ("cartesian", "mapped")}
    expected |= {(n, chart, "sharp", "centered") for n in (16, 32, 64) for chart in ("cartesian", "mapped")}
    keys = [(r["grid"], r["chart"], r["scenario"], r["method"]) for r in runs]
    if len(keys) != len(expected) or set(keys) != expected:
        raise ValueError("publish only the complete 48-run comparison")
    for run in runs:
        final = run["final"]
        if not all(math.isfinite(v) for v in final.values()):
            raise ValueError("nonfinite diagnostic")
        if not (run["population_mass_relative_drift"] < 1e-10 and run["max_closure"] < 1e-10
                and 0 < run["max_cfl"] < 1 and final["minArea"] > 0):
            raise ValueError("failed conservation, geometry or time-step check")
        if run["method"] != "centered" and final["lowest"] < -1e-12:
            raise ValueError("positivity check failed")
        if run["method"] == "muscl" and run["max_cfl"] >= 0.5:
            raise ValueError("MUSCL positivity time-step bound exceeded")
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
    stable = [r for r in runs if r["method"] != "centered"]
    mass = scientific(max(r["population_mass_relative_drift"] for r in runs))
    uniform = scientific(max(r["final"]["error"] for r in stable if r["scenario"] == "uniform"))
    cfl = max(r["max_cfl"] for r in stable)
    factors = report["improvements"]
    improvement = math.floor(10*min(v["upwind-rk2"] for v in factors.values()))/10
    sharp = {(r["chart"],r["method"]): r["final"]["mixing"] for r in runs
             if r["grid"]==grids[-1] and r["scenario"]=="sharp" and r["method"]!="centered"}
    less_mixing = math.floor(min(100*(1-sharp[(chart,"muscl")]/sharp[(chart,"upwind")]) for chart in ("cartesian","mapped")))
    if lang == "ja":
        title = "波頭を保つための輸送の高精度化：D2Q9"
        description = "D2Q9（二次元の九方向の分布）の移動を，セル内の量と共有面の流量から求める有限体積法で検証します。一次風上法に加え，セル内を直線で近似し，急な変化の近くで傾きを抑えるMUSCL法を実装しました。時間積分には，途中のEuler更新と平均を使う二段のSSPRK2法を組み合わせます。同じ更新式を直交格子と曲がった格子で使います。"
        equation_note = "Fは共有面の流量，Bは移動速度と面の向き・長さから求める係数です。高精度法では，両側のセル平均と制限した傾きから面の値を求めます。隣接セルには同じ面の流量を逆符号で加えます。"
        caption = "左：滑らかな移動問題の最大誤差。実線は高精度法，点線は一次風上法，破線は二次精度の傾きです。右：64×64セルの急な分布が，中間の値へどれだけ広がったかを示す指標。小さいほど分布のぼけが少なく，初期値は0です。水面の厚さを測った図ではありません。"
        facts = f"<b>48条件の検証が通過。</b> 高精度法は平均前の候補も含め，全更新で負値を作りませんでした。64×64セルでは，時間積分を同じ二段法にそろえた一次風上法に対し，最大誤差が両格子で{improvement:.1f}分の1以下に減りました。急な分布のぼけの指標は，従来の一次風上法より両格子で{less_mixing:.0f}%以上減少しました。"
        table_caption = "滑らかな移動問題：重みで割った分布の最大誤差と実測次数"
        chart_label, order_label = "格子・方法", "最大誤差の次数 / 平均誤差の次数"
        chart_names = ("直交", "曲がった格子")
        method_names = ("一次風上", "高精度法")
        order_note = "次数は32→64セルで評価しています。セル平均の参照値には四次精度の四点Gauss積分（重み付きの四点評価）を使います。急な変化や極値で傾きを抑えるため，最大誤差の次数は2を下回ることがあります。二段法にそろえた対照実験も検証JSONに含めています。"
        code_label = "両方の格子に共通の輸送処理（実際のソースから抜粋）"
        sample_note = "<code>sampleLower</code>／<code>sampleUpper</code> で面の両側の値と，セルの両側の差を直接選び，傾きを計算します。座標の定義・面の幾何係数は輸送処理と分けています。新しい構文や処理系の拡張は使っていません。"
        scope = f"各方向の総量の相対変化は全48条件で最大{mass}，一様分布の最大誤差は{uniform}でした。時間刻みと面の流量係数から計算した値Cは最大{cfl:.3f}で，非負性を保つ十分条件C ≤ 0.5を満たしました。初期条件・幾何・時間積分・診断値はすべてFormuraeに記述しています。今回は周期境界での輸送を検証し，衝突項・重力・壁・水面との結合は次の段階です。"
        previous = "<a href=\"#breaking-wave\">巻き込む波と引き波</a>に向け，分布を必要以上になだらかにしない輸送を検証する段階です。この波の動画への組込みは今後行います。<a href=\"#kinetic-coordinates\">前の中心差分による実験</a>と，比較用の中心的な流量＋前進Euler法は異なる計算法です。"
        more, checks, vector, reproduce = "設計と再現手順", "48条件の検証結果", "拡大できるグラフ（SVG）", "計算と検証の再現"
    else:
        title = "More accurate D2Q9 transport toward sharper wave crests"
        description = "We test transport of D2Q9 populations—nine velocity populations in two dimensions—with finite volumes: cell contents change through shared-face fluxes. Alongside first-order upwinding, MUSCL reconstructs a linear profile in each cell and limits its slope near abrupt changes. Two-stage SSPRK2 combines Euler updates and averaging for time integration. Both Cartesian and mapped grids use the same update."
        equation_note = "F is the shared-face flux. B combines velocity with face orientation and length. The higher-order method reconstructs face values from cell averages and limited slopes. Adjacent cells receive the same face flux with opposite signs."
        caption = "Left: maximum smooth-transport error. Solid lines show the higher-order method, dotted lines first-order upwinding, and the dashed guide a second-order slope. Right: spreading of a sharp profile into intermediate values on a 64×64 grid. Lower values indicate less smearing; initially the measure is zero. This is not a measurement of water-surface thickness."
        facts = f"<b>All 48 verification cases passed.</b> The higher-order method remained nonnegative at every update, including Euler candidates before averaging. On 64×64 grids, maximum error fell by at least a factor of {improvement:.1f} in both geometries relative to first-order upwinding with the same two-stage time integrator. Sharp-profile smearing fell by at least {less_mixing:.0f}% relative to the previous upwind method."
        table_caption = "Smooth transport: maximum error in population / weight, and measured convergence orders"
        chart_label, order_label = "Geometry / method", "Maximum / mean error orders"
        chart_names = ("Cartesian", "Mapped")
        method_names = ("First-order upwind", "Higher-order")
        order_note = "Orders are measured from 32 to 64 cells per coordinate. Reference cell averages use fourth-order, four-point Gaussian quadrature. Limiting slopes near sharp changes and extrema can lower the maximum-error order below two. The verification JSON also includes a control using first-order upwinding with the same two-stage integrator."
        code_label = "Transport shared by both grids (excerpt from the actual source)"
        sample_note = "The existing sampleLower/sampleUpper operations select values on either side of a face and differences on either side of a cell to calculate slopes. Coordinate maps and face geometry are defined separately. No new syntax or compiler extension is used."
        scope = f"Across all 48 cases, maximum relative drift of each population’s total was {mass}; maximum uniform-state error was {uniform}. The coefficient C, computed from the time step and face flux coefficients, reached at most {cfl:.3f}, satisfying the sufficient positivity condition C ≤ 0.5. Initial conditions, geometry, time integration and diagnostics are all written in Formurae. This verifies periodic transport; collisions, gravity, walls and a free surface are the next stage."
        previous = "This is a transport test toward the <a href=\"#breaking-wave\">breaking-wave and backwash example</a>; integration into that simulation is still ahead. The <a href=\"#kinetic-coordinates\">earlier centered-difference experiment</a> uses a different method from the centered-flux + forward-Euler control here."
        more, checks, vector, reproduce = "Design and reproduction", "All 48 verification cases", "Scalable graph (SVG)", "Reproduce the simulations and checks"
    rows = []
    for chart, label in zip(("cartesian", "mapped"), chart_names):
        for method, method_label in zip(("upwind", "muscl"), method_names):
            smooth = sorted((r for r in runs if r["chart"] == chart and r["scenario"] == "smooth" and r["method"]==method), key=lambda r:r["grid"])
            cells = "".join(f'<td style="padding:6px;white-space:nowrap">{scientific(r["final"]["error"])}</td>' for r in smooth)
            orders = report["orders"][method][chart]
            rows.append(f'<tr><th scope="row" style="text-align:left;padding:6px">{label} / {method_label}</th>{cells}'
                        f'<td style="padding:6px">{orders["error"][-1]:.3f} / {orders["errorL1"][-1]:.3f}</td></tr>')
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
        label = "波頭を保つための輸送の高精度化：D2Q9" if lang == "ja" else "More accurate D2Q9 transport toward sharper wave crests"
        nav = f'{NAV_BEGIN}<p><a href="#{SLUG}">{label}</a></p>{NAV_END}'
        page = replace_or_insert(page, NAV_BEGIN, NAV_END, nav, "<!-- kinetic-coordinates:nav:begin -->")
        path.write_text(page)
        print(path)


if __name__ == "__main__":
    main()
