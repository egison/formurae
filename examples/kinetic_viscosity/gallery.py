#!/usr/bin/env python3
"""Publish the saved collision/viscosity verification in both galleries."""
import hashlib
import html
import json
import math
from pathlib import Path
import re

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
NAME='kinetic_viscosity'
BASE='../../examples/kinetic_viscosity'
SLUG='kinetic-viscosity'
BEGIN='<!-- kinetic-viscosity:begin -->'
END='<!-- kinetic-viscosity:end -->'
NAV_BEGIN='<!-- kinetic-viscosity:nav:begin -->'
NAV_END='<!-- kinetic-viscosity:nav:end -->'


def load_report():
    report=json.loads((HERE/'results/verification.json').read_text())
    assert report['source_sha256']==hashlib.sha256((HERE/f'{NAME}.fme').read_bytes()).hexdigest()
    expected=set()
    for n in (16,32,64,128):
        for chart in ('cartesian','mapped'):
            for scenario in ('uniform','relaxation'):
                expected.add((n,chart,scenario,'muscl',0.008,1))
            for zeta in (0.002,0.008,0.02):
                expected.add((n,chart,'shear','muscl',zeta,1))
            expected.add((n,chart,'shear','upwind',0.008,1))
            if n==64:
                expected.add((n,chart,'shear','muscl',0.008,0.5))
    keys=[tuple(r[k] for k in ('grid','chart','scenario','method','zeta','time_scale')) for r in report['runs']]
    if len(keys)!=50 or set(keys)!=expected:
        raise ValueError('publish only the complete 50-case verification')
    for r in report['runs']:
        f=r['final']
        assert all(math.isfinite(v) for v in f.values())
        assert r['mass_drift']<2e-11 and r['momentum_drift']<2e-11
        assert r['max_positivity_bound']<1 and f['equilibriumLowest']>=0 and f['lowest']>=-1e-12
        assert f['collisionResidual']<1e-12 and f['minArea']>0
    return report


def scientific(value):
    mantissa,exponent=f'{value:.2e}'.split('e')
    return f'<span style="white-space:nowrap">{mantissa}×10<sup>{int(exponent)}</sup></span>'


def source_blocks(lang):
    labels=('Formurae ソース全文','生成された Egison','正規化結果 FEIR','生成された Formura') if lang=='ja' else ('Full Formurae source','Generated Egison','Normalized FEIR','Generated Formura')
    blocks=[]
    for extension,label in zip(('fme','egi','feir','fmr'),labels):
        source=(HERE/f'{NAME}.{extension}').read_text().rstrip('\n')
        body=html.escape(source,quote=False)
        comment=r'(?m)^(--.*)$' if extension in ('fme','egi') else r'(?m)^([;#].*)$'
        body=re.sub(comment,r'<span class="c">\1</span>',body)
        opened=' open' if extension=='fme' else ''
        unit='行' if lang=='ja' else 'lines'
        blocks.append(f'<details class="codebox" data-{extension}="{NAME}/{NAME}.{extension}"{opened}><summary>{label} ({NAME}.{extension}, {len(source.splitlines())} {unit})</summary><pre>{body}</pre></details>')
    return '\n'.join(blocks)


def generate(lang,report):
    runs=report['runs']
    source=(HERE/f'{NAME}.fme').read_text()
    excerpt='macro equilibrium Q =\n'+source.split('macro equilibrium Q =\n',1)[1].split('\n\n',1)[0]
    mass=scientific(max(r['mass_drift'] for r in runs))
    momentum=scientific(max(r['momentum_drift'] for r in runs))
    finest=[r for r in runs if r['grid']==64 and r['scenario']=='shear' and r['method']=='muscl' and r['time_scale']==1]
    mode=max(abs(r['final']['modeError']) for r in finest)
    if lang=='ja':
        title='輸送に衝突を加える：粘性による流れの減衰'
        description='D2Q9（二次元の九方向の分布）の輸送に，分布を同じ密度・運動量の平衡状態へ近づけるBGK衝突項を加えました。横方向の位置によって縦方向の速さが変わる「せん断流」が，粘性で減衰する様子を計算します。直交格子と曲がった格子で，同じ輸送・衝突の式を使います。'
        equation_note='τは平衡へ近づく時間の尺度です。密度と運動量から平衡分布 f_eq を作り，輸送と衝突を同じ二段の時間積分で進めます。'
        caption='左：三つの緩和時間での流れの減衰。実線は直交格子，丸印は曲がった格子，破線は方程式から導いた参照値です。右：同じ時間積分を使う一次風上法とMUSCL法の平均速度誤差。MUSCL法はセル内の傾きから面の値を求め，急な変化では傾きを抑えます。'
        facts=f'<b>50条件の検証が通過。</b> 64×64セルの高精度法では，参照値との振幅の差は初期振幅の{100*mode:.2f}%以内でした。各格子で三つの緩和時間を検証し，格子を細かくしたときの速度誤差の減少を確認しています。'
        table_caption='高精度法の平均速度誤差：同じ物理条件で格子を細分化（次数は64→128セル）'
        labels=('格子','緩和時間 τ','16×16','32×32','64×64','128×128','平均誤差の次数')
        names=('直交','曲がった格子')
        code_title='座標の定義と分離した衝突モデル（実際のソースから抜粋）'
        code_note='aは九方向の番号，pは物理空間の正規直交基底（互いに直角な単位ベクトル）の二成分です。frameは格子の座標と独立に固定した九方向を表します。曲がった格子でもこの内積と平衡分布の式を変えません。'
        scope=f'全条件で質量の相対変化は最大{mass}，運動量の絶対変化は最大{momentum}。輸送と衝突の両方を含めた，非負性を保つ時間刻みの十分条件を満たしました。平均前のEuler候補と平衡分布も非負であり，値の切り詰めは行っていません。'
        limits='この参照値は九方向の方程式の有限波長での減衰率です。長波長での動粘性係数 ν=τ/3 とは区別して比較します。初期条件・時間積分・診断値もすべてFormuraeで計算しています。重力・壁・水面を加えた波の計算は次の段階です。'
        previous='<a href="#kinetic-fv">輸送の高精度化</a>を粘性のある流れへ進めた実験です。<a href="#breaking-wave">巻き込む波と引き波</a>の動画への組込みは今後行います。'
        more,checks,vector='式の導出と再現手順','50条件の検証結果','拡大できるグラフ（SVG）'
    else:
        title='Adding collisions: viscous decay of a shear flow'
        description='We add BGK collisions to the D2Q9 transport solver (nine velocity populations in two dimensions): populations relax toward an equilibrium with the same density and momentum. A shear flow, whose transverse speed varies across the domain, decays through viscosity. Cartesian and mapped grids use the same transport and collision equations.'
        equation_note='τ is the relaxation time. Density and momentum determine f_eq. Transport and collisions are evaluated together in the same two-stage time integrator.'
        caption='Left: flow decay for three relaxation times. Solid lines are Cartesian results, circles are mapped-grid results, and dashed lines are references derived from the equations. Right: mean velocity error for first-order upwinding and MUSCL with the same time integrator. MUSCL reconstructs face values from limited cell slopes.'
        facts=f'<b>All 50 verification cases passed.</b> On 64×64 grids, the higher-order method’s projected amplitude differed from the reference by at most {100*mode:.2f}% of the initial amplitude. Three relaxation times were checked in each geometry, with decreasing velocity errors under grid refinement.'
        table_caption='Higher-order mean velocity error at fixed physical conditions (orders: 64→128 cells)'
        labels=('Geometry','Relaxation time τ','16×16','32×32','64×64','128×128','Mean-error order')
        names=('Cartesian','Mapped')
        code_title='Collision model separated from grid geometry (actual source excerpt)'
        code_note='a labels the nine populations; p labels the two components in a fixed physical orthonormal basis. frame contains the physical velocity directions independently of grid coordinates. These inner products and equilibrium expressions are unchanged on mapped grids.'
        scope=f'Across all cases, maximum relative mass drift was {mass} and absolute momentum drift was {momentum}. The sufficient time-step condition for positivity, including both transport and collisions, was satisfied. Euler candidates before averaging and equilibrium populations remained nonnegative, without clipping.'
        limits='The reference uses the finite-wavelength decay rate of the nine-velocity equations, distinguished from the long-wavelength kinematic viscosity ν=τ/3. Initial conditions, time integration and diagnostics are all calculated in Formurae. Gravity, walls and a free surface remain the next stage.'
        previous='This extends the <a href="#kinetic-fv">higher-order transport test</a> to viscous flow. Integration into the <a href="#breaking-wave">breaking-wave and backwash simulation</a> is still ahead.'
        more,checks,vector='Derivation and reproduction','All 50 verification cases','Scalable graph (SVG)'
    rows=[]
    for chart,name in zip(('cartesian','mapped'),names):
        for zeta in (0.002,0.008,0.02):
            selected=sorted((r for r in runs if r['chart']==chart and r['scenario']=='shear' and r['zeta']==zeta
                             and r['method']=='muscl' and r['time_scale']==1),key=lambda r:r['grid'])
            cells=''.join(f'<td>{scientific(r["final"]["velocityErrorL1"])}</td>' for r in selected)
            order=report['orders'][f'{chart}-z{zeta}-velocityErrorL1'][-1]
            rows.append(f'<tr><th scope="row">{name}</th><td>{selected[0]["final"]["relaxationTime"]:.4f}</td>{cells}<td>{order:.3f}</td></tr>')
    headings=''.join(f'<th scope="col">{v}</th>' for v in labels)
    card=f'''{BEGIN}
<article class="card featured" id="{SLUG}">
<h3>{title}</h3><p class="description">{description}</p>
<div class="math">∂t f + div(c f) = (f_eq − f) / τ</div>
<p class="description">{equation_note}</p>
<div class="imgs"><a href="{BASE}/results/viscosity.svg"><img src="{BASE}/results/viscosity.png" alt="{html.escape(caption)}" width="1800" height="756" loading="lazy"></a></div>
<p class="cap">{caption}</p><p class="facts">{facts}</p>
<div style="overflow-x:auto;margin:12px 0"><table style="width:100%;min-width:600px;border-collapse:collapse;font-size:12.5px;text-align:right"><caption style="text-align:left;padding-bottom:8px">{table_caption}</caption><thead><tr>{headings}</tr></thead><tbody>{''.join(rows)}</tbody></table></div>
<div class="codebox"><div class="head">{code_title}</div><pre>{html.escape(excerpt)}</pre></div>
<p class="description">{code_note}</p><p class="description">{scope}</p>
<p class="description">{limits}</p><p class="description">{previous}</p>
<p class="facts"><a href="{BASE}/README.md">{more}</a> · <a href="{BASE}/results/verification.json">{checks}</a> · <a href="{BASE}/results/viscosity.svg">{vector}</a><br><code>make kinetic-viscosity-verify</code></p>
{source_blocks(lang)}
</article>
{END}'''
    # Keep table padding local to this generated card.
    card=card.replace('<td>','<td style="padding:6px">').replace('<th scope="row">','<th scope="row" style="text-align:left;padding:6px">').replace('<th scope="col">','<th scope="col" style="padding:6px">')
    return title,card


def replace_or_insert(page,begin,end,content,anchor):
    if begin in page:
        before,rest=page.split(begin,1)
        _,after=rest.split(end,1)
        return before+content+after
    if page.count(anchor)!=1:
        raise ValueError(f'expected one insertion point: {anchor}')
    return page.replace(anchor,content+'\n'+anchor,1)


def main():
    report=load_report()
    for lang in ('ja','en'):
        title,card=generate(lang,report)
        path=ROOT/'html'/lang/'gallery.html'
        page=replace_or_insert(path.read_text(),BEGIN,END,card,'<!-- kinetic-fv:begin -->')
        nav=f'{NAV_BEGIN}<p><a href="#{SLUG}">{title}</a></p>{NAV_END}'
        page=replace_or_insert(page,NAV_BEGIN,NAV_END,nav,'<!-- kinetic-fv:nav:begin -->')
        path.write_text(page)
        print(path)


if __name__=='__main__':
    main()
