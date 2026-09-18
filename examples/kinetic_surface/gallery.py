#!/usr/bin/env python3
"""Publish verified linearized free-surface waves on both wave pages."""
import hashlib
import html
import json
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
NAME = "kinetic_surface"
BASE = "../../examples/kinetic_surface"
BEGIN, END = "<!-- kinetic-surface:begin -->", "<!-- kinetic-surface:end -->"
NAV_BEGIN, NAV_END = "<!-- kinetic-surface:nav:begin -->", "<!-- kinetic-surface:nav:end -->"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load():
    report = json.loads((HERE / "results/verification.json").read_text())
    if not report["passed"] or len(report["runs"]) != 16:
        raise ValueError("publish the complete 16-case verification")
    for key, path in (("source_sha256", HERE / f"{NAME}.fme"), ("driver_sha256", HERE / "driver.c"),
                      ("config_sha256", HERE / "config.h"), ("orchestration_sha256", HERE / "run.py")):
        if report[key] != sha(path):
            raise ValueError(f"verification is stale: {path.name}")
    for extension, value in report["generated"].items():
        if value != sha(HERE / f"{NAME}.{extension}"):
            raise ValueError("generated source differs from verified source")
    rendering = json.loads((HERE / "results/rendering.json").read_text())
    if rendering["verification_sha256"] != sha(HERE / "results/verification.json"):
        raise ValueError("movie does not match verification")
    if rendering["source_sha256"] != report["source_sha256"] or rendering["renderer_sha256"] != sha(HERE / "render.py"):
        raise ValueError("movie must be regenerated from the current model and renderer")
    for suffix, value in rendering["media"].items():
        if value != sha(HERE / f"results/surface.{suffix}"):
            raise ValueError("media changed after rendering")
    return report


def sources(lang):
    labels = ("Formurae ソース全文", "生成された Egison", "正規化結果 FEIR", "生成された Formura") if lang == "ja" else (
        "Full Formurae source", "Generated Egison", "Normalized FEIR", "Generated Formura")
    blocks = []
    for extension, label in zip(("fme", "egi", "feir", "fmr"), labels):
        text = (HERE / f"{NAME}.{extension}").read_text().rstrip("\n")
        blocks.append(f'<details class="codebox" data-{extension}="{NAME}/{NAME}.{extension}">'
                      f'<summary>{label} ({NAME}.{extension})</summary><pre>{html.escape(text, quote=False)}</pre></details>')
    return "\n".join(blocks)


def generate(lang, report):
    waves = [r for r in report["runs"] if r["scenario"] == "wave" and r["gravity"] == 0.02
             and r["time_scale"] == 1 and r["boundary_slope"] == 1]
    rest = [r for r in report["runs"] if r["scenario"] == "rest"]
    drift = max(r["mass_drift"] for r in report["runs"])
    period_error = max(r["final"]["periodError"] for r in waves if r["grid"][0] == report["period_check_grid"])
    coordinate_gap = report["checks"]["chart_amplitude_gaps"][-1]
    if lang == "ja":
        title = "小さな水面の波：D2Q9の微分方程式と結合"
        description = "D2Q9（二次元・九速度）の分布を微分方程式で運び，水面の圧力条件と高さの更新を結合しました。初めに与えた小さな凹凸が，山と谷を入れ替えながら振動します。直交格子と曲線格子で同じ物理モデルを計算しています。"
        caption = "上段は計算した水面の高さを縦方向に拡大した断面です。破線は静水面です。下段は水面変位に初期のcos形状を掛けて和を取り，その形の波の振幅を測った量です。2種類の格子を重ねています。水面は流体の計算から更新しており，描画で波の形や運動を与えていません。"
        facts = f"<b>16条件の検証が通過。</b> 静水の流速は0，線形化した総質量の相対変化は最大{drift:.2e}でした。96×48セルでは，参照理論との周期の差は最大{100*period_error:.2f}%，座標間の振幅指標の差は初期振幅の{100*coordinate_gap:.3f}%でした。"
        scope = "静水からの変化の一次の項までを残す，線形化した小振幅のモデルです。水平な基準面で水面の条件を評価します。巻き込み・水の分裂・水際の移動は次の段階であり，既存の「巻き込む波と引き波」への非線形な水面処理の統合はまだ行っていません。"
        note = "hは静水の分布との差，Cは衝突，Sは重力の項，ζは水面の変位，jY(H)は基準水面を通る質量流束です（基準水面の密度は1）。内部と水面の更新に同じ流束を使います。"
        headings = ("格子", "座標", "計測周期", "参照理論との最大相対差")
        names = {"cartesian": "直交", "mapped": "曲線"}
        table_note = "周期は水面の点ごとに零交差から求めた値の最大です。参照値44.511875は，粘性と圧縮性を無視した小振幅の重力波の周期で，本モデルの厳密解ではありません。"
        more, check, play = "方程式と再現手順", "16条件の検証結果", "動画を開く"
    else:
        title = "Small surface waves coupled to the D2Q9 differential equations"
        description = "Transport in D2Q9, a two-dimensional model with nine velocity directions, is solved as a differential equation and coupled to the surface pressure condition and evolving height. A small initial displacement oscillates, exchanging crests and troughs. Cartesian and mapped grids use the same physical model."
        caption = "The upper panels show the computed surface with an enlarged vertical scale; dashed lines mark the undisturbed level. Below, the amplitude of the initial cosine component is compared between grids by summing surface displacement weighted by that shape. Surface motion comes from the fluid calculation; no wave shape or motion is prescribed by rendering."
        facts = f"<b>All 16 cases passed.</b> Hydrostatic speed remained zero; maximum relative drift in linearized total mass was {drift:.2e}. On 96×48 cells, the maximum period difference from reference theory was {100*period_error:.2f}%, and the cosine-amplitude difference between coordinate systems was {100*coordinate_gap:.3f}% of initial amplitude."
        scope = "This small-amplitude model retains terms linear in deviations from hydrostatic rest and evaluates surface conditions on a horizontal reference plane. Overturning, splitting and wetting/drying are subsequent steps. Nonlinear surface handling has not yet been integrated into the existing breaking-wave simulation."
        note = "h is the population deviation from rest, C is collision, S is forcing, ζ is surface displacement, and jY(H) is the boundary mass flux (reference surface density is 1). Bulk and surface updates use the same flux."
        headings = ("Grid", "Coordinates", "Measured period", "Maximum relative difference")
        names = {"cartesian": "Cartesian", "mapped": "Mapped"}
        table_note = "Periods are measured from zero crossings at surface points; the maximum is listed. The reference 44.511875 assumes inviscid incompressible small-amplitude gravity waves and is not an exact solution of this kinetic model."
        more, check, play = "Equations and reproduction", "All 16 verification cases", "Open video"
    assert max(r["final"]["speed"] for r in rest) == 0
    rows = "".join(f'<tr><td>{r["grid"][0]}×{r["grid"][1]}</td><td>{names[r["chart"]]}</td>'
                   f'<td>{r["final"]["period"]:.4f}</td><td>{100*r["final"]["periodError"]:.3f}%</td></tr>' for r in waves)
    header = "".join(f'<th scope="col">{heading}</th>' for heading in headings)
    return f'''{BEGIN}
<article class="card featured" id="kinetic-surface">
<h3>{title}</h3><p class="description">{description}</p>
<div class="math">∂t h<sub>a</sub> + div(c<sub>a</sub> h<sub>a</sub>) = C<sub>a</sub> + S<sub>a</sub>， ∂t ζ = j<sub>Y</sub>(H)</div>
<p class="description">{note}</p>
<div class="imgs"><video controls loop muted playsinline preload="none" width="1200" height="720" poster="{BASE}/results/surface.png" aria-label="{html.escape(caption)}"><source src="{BASE}/results/surface.mp4" type="video/mp4"><a href="{BASE}/results/surface.mp4">{play}</a></video></div>
<p class="cap">{caption}</p><p class="facts">{facts}</p>
<div style="overflow-x:auto;margin:12px 0"><table style="width:100%;min-width:480px;border-collapse:collapse;text-align:right;font-size:13px"><thead><tr>{header}</tr></thead><tbody>{rows}</tbody></table></div>
<p class="cap">{table_note}</p><p class="description">{scope}</p>
<p class="facts"><a href="{BASE}/README.md">{more}</a> · <a href="{BASE}/results/verification.json">{check}</a><br><code>make kinetic-surface-verify</code> · <code>make kinetic-surface-gallery</code></p>
{sources(lang)}
</article>
{END}''', title


def main():
    report = load()
    for lang in ("ja", "en"):
        path = ROOT / "html" / lang / "waves.html"
        text = path.read_text()
        card, title = generate(lang, report)
        if BEGIN in text:
            text, count = re.subn(re.escape(BEGIN)+r".*?"+re.escape(END), lambda _: card, text, flags=re.S)
            assert count == 1
        else:
            anchor = '</div>\n</section>\n<section aria-labelledby="fluid-foundations">'
            assert text.count(anchor) == 1
            text = text.replace(anchor, card+"\n"+anchor, 1)
        nav = f'{NAV_BEGIN}<p><a href="#kinetic-surface">{title}</a></p>{NAV_END}'
        if NAV_BEGIN in text:
            text, count = re.subn(re.escape(NAV_BEGIN)+r".*?"+re.escape(NAV_END), lambda _: nav, text, flags=re.S)
            assert count == 1
        else:
            text = text.replace('  <details class="wave-index">', "  "+nav+'\n  <details class="wave-index">', 1)
        path.write_text(text)
        print(path)


if __name__ == "__main__":
    main()
