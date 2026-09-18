#!/usr/bin/env python3
"""Publish verified D2Q9/label transport on the Japanese and English wave pages."""
import hashlib
import html
import json
from pathlib import Path
import re

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
NAME='kinetic_transport'
BASE='../../examples/kinetic_transport'
BEGIN,END='<!-- kinetic-transport:begin -->','<!-- kinetic-transport:end -->'
NB,NE='<!-- kinetic-transport:nav:begin -->','<!-- kinetic-transport:nav:end -->'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load():
    report=json.loads((HERE/'results/verification.json').read_text())
    assert report['passed'] and len(report['runs'])==20
    for key,file in [('source_sha256',NAME+'.fme'),('driver_sha256','driver.c'),('config_sha256','config.h'),('orchestration_sha256','run.py')]:
        assert report[key]==sha(HERE/file),f'stale verification: {file}'
    for ext,value in report['generated'].items():
        assert value==sha(HERE/f'{NAME}.{ext}')
    media=json.loads((HERE/'results/rendering.json').read_text())
    assert media['verification_sha256']==sha(HERE/'results/verification.json')
    assert media['source_sha256']==report['source_sha256'] and media['renderer_sha256']==sha(HERE/'render.py')
    for ext,value in media['media'].items():
        assert value==sha(HERE/f'results/coupled.{ext}')
    return report


def sources(lang):
    labels=['Formurae ソース全文','生成された Egison','正規化結果 FEIR','生成された Formura'] if lang=='ja' else ['Full Formurae source','Generated Egison','Normalized FEIR','Generated Formura']
    return '\n'.join(f'<details class="codebox" data-{ext}="{NAME}/{NAME}.{ext}"><summary>{label} ({NAME}.{ext})</summary><pre>{html.escape((HERE/f"{NAME}.{ext}").read_text().rstrip(),quote=False)}</pre></details>' for ext,label in zip(['fme','egi','feir','fmr'],labels))


def card(lang,report):
    mass=max(r['drifts']['waterMass']/r['history'][0]['waterMass'] for r in report['runs'])
    constant=max(r['final']['stationaryError'] for r in report['runs'] if r['case']=='constant')
    low=min(r['final']['lowest'] for r in report['runs'])
    high=max(r['final']['highest'] for r in report['runs'])
    ratio=max(report['checks'][c+'-high-to-upwind-error'] for c in ['cartesian','mapped'])
    if lang=='ja':
        title='D2Q9の流れで水の領域を運ぶ：密度が変わっても質量を保つ'
        description='流速をあらかじめ指定する段階から，D2Q9（二次元で九方向の分布を使うモデル）で計算した流れへ進めました。セルの面を通る質量を流体と水の領域で共有し，密度の増減と整合する移動を検証します。'
        scope='現在は全セルが同じ流体で満たされ，その一部に水という印を付けています。印の外側も流体を計算します。印の境界への大気圧条件，重力，新しく水になるセルの初期化との結合は次の課題です。'
        explanation='ρは密度，αは水を表す割合，m=ραはその単位面積当たりの質量です。D2Q9の九つの分布の面流束を足したFρを，密度とmの両方の更新に使います。保存量mと分布を同じ時間積分で更新した後，α=m/ρを求めます。'
        caption='64²セル。左と中央は水を表す割合と計算された流速，右は曲線格子の密度です。実線は割合0.5，破線は初期の境界です。流れには初期値だけを与え，以後はD2Q9で変化を計算しています。色と矢印の尺度は全時刻で固定しています。'
        mixing='下段は中間の割合の広がりを示す比較用の指標で，物理的な混合ではありません。白い領域を空気とみなした自由表面の動画ではありません。'
        facts=f'<b>20条件の検証が通過。</b> 水を表す質量の相対変化は最大{mass:.2e}。密度が変わる流れに入れた一定割合0.37の誤差は最大{constant:.2e}でした。全中間段階を含む割合は{low:.3g}〜{high:.16g}で，検査の許容範囲は−2×10⁻¹²〜1+2×10⁻¹²です。'
        accuracy=f'表は平行移動の解析解に対する面積積分誤差 ΣA|α−α_exact| です。Aはセル面積です。64²で，傾きを制限した直線を使うMUSCL法の誤差は，セル内を一定とする一次風上法の最大{ratio:.3f}倍でした。上の変形試験は別に，保存性，範囲，座標間の指標の差，時間刻みの半減を検査しています。'
        note='両方の輸送に必要な時間刻みの条件を毎段検査し，0〜1への切り詰めや全体の質量補正は行いません。初期条件，幾何，時間更新，参照解，診断値までFormuraeに記述し，処理系や構文を拡張せずに実行しています。'
        headers=['セル数','直交格子','曲線格子']
        read,results='方程式・範囲を保つ条件・再現手順','20条件の検証記録'
    else:
        title='Transport driven by D2Q9: preserving labelled mass as density changes'
        description='Velocity now comes from D2Q9, a fluid model with nine velocity populations in two dimensions. The fluid and the labelled region share the numerical mass flux through each cell face, making transport consistent with changing density.'
        scope='All cells currently contain the same fluid, with part of it labelled as water. Fluid is also computed outside the label. An atmospheric-pressure boundary, gravity, and initialization of newly wetted cells remain subsequent steps.'
        explanation='ρ is density, α is the labelled fraction, and m=ρα is labelled mass per unit area. Fρ is the sum of the nine numerical population fluxes. The same Fρ updates both density and m. Populations and m use the same time integration; α=m/ρ is recovered afterwards.'
        caption='64² cells. Left and middle show the labelled fraction and computed velocity; right shows density on the curved grid. Solid lines mark fraction 0.5; dashed lines show the initial interface. Only the initial flow is prescribed; D2Q9 computes its subsequent evolution. Color and arrow scales remain fixed.'
        mixing='The lower plot compares intermediate fractions, not physical mixing. The white region is also fluid; this is not yet a water–air free-surface movie.'
        facts=f'<b>All 20 cases passed.</b> Maximum relative labelled-mass drift was {mass:.2e}. A uniform fraction of 0.37 changed by at most {constant:.2e} in the variable-density flow. Fractions, including both Euler candidates, ranged from {low:.3g} to {high:.16g}; the acceptance interval is −2×10⁻¹² to 1+2×10⁻¹².'
        accuracy=f'The table lists integrated errors ΣA|α−α_exact| against analytic uniform translation, where A is cell area. On 64² cells, MUSCL (a slope-limited linear reconstruction) had at most {ratio:.3f} times the error of first-order upwind (constant cell values). The deformation shown above is checked separately for conservation, bounds, chart differences in a scalar diagnostic, and timestep sensitivity.'
        note='Sufficient timestep conditions for both transports are checked at every stage. No clipping or global mass correction is applied. Initialization, geometry, updates, analytic references and diagnostics are written in Formurae and use the existing syntax and normal compilation pipeline.'
        headers=['Cells','Cartesian grid','Curved grid']
        read,results='Equations, bounds and reproduction','All 20 verification cases'
    rows=[]
    for i,n in enumerate([16,32,64]):
        values=[report['checks'][c+'-translation-L1'][i] for c in ['cartesian','mapped']]
        rows.append(f'<tr><td>{n}²</td>'+''.join(f'<td>{v:.4e}</td>' for v in values)+'</tr>')
    table='<div style="overflow-x:auto;margin:12px 0"><table style="width:100%;min-width:280px;text-align:right;font-size:13px"><thead><tr>'+''.join(f'<th scope="col">{h}</th>' for h in headers)+'</tr></thead><tbody>'+''.join(rows)+'</tbody></table></div>'
    return f'''{BEGIN}
<article class="card featured" id="kinetic-transport">
<h3>{title}</h3><p class="description">{description}</p>
<div class="math">∂t fₐ + div(cₐ fₐ) = (fₐᵉᵠ − fₐ)/τ<br>ρ = Σₐ fₐ， m = ρα， ∂t m + div(ρuα) = 0</div>
<p class="description">{explanation}</p><p class="facts">{scope}</p>
<div class="imgs"><video controls loop muted playsinline preload="none" width="1200" height="760" poster="{BASE}/results/coupled.png" aria-label="{html.escape(title)}"><source src="{BASE}/results/coupled.mp4" type="video/mp4"><a href="{BASE}/results/coupled.mp4">MP4</a></video></div>
<p class="cap">{caption}</p><p class="cap">{mixing}</p><p class="facts">{facts}</p>
{table}<p class="cap">{accuracy}</p><p class="description">{note}</p>
<p class="facts"><a href="{BASE}/README.md">{read}</a> · <a href="{BASE}/results/verification.json">{results}</a><br><code>make kinetic-transport-verify</code> · <code>make kinetic-transport-gallery</code></p>
{sources(lang)}
</article>
{END}''',title


def main():
    report=load()
    for lang in ['ja','en']:
        path=ROOT/'html'/lang/'waves.html'
        text=path.read_text()
        article,title=card(lang,report)
        for begin,end,content,anchor in [(BEGIN,END,article,'<!-- kinetic-hydrostatic:begin -->'),(NB,NE,f'{NB}<p><a href="#kinetic-transport">{title}</a></p>{NE}','<!-- kinetic-hydrostatic:nav:begin -->')]:
            if begin in text:
                text,count=re.subn(re.escape(begin)+'.*?'+re.escape(end),lambda _:content,text,flags=re.S)
                assert count==1
            else:
                assert text.count(anchor)==1
                text=text.replace(anchor,content+'\n'+anchor,1)
        path.write_text(text)
        print(path)


if __name__=='__main__':
    main()
