#!/usr/bin/env python3
"""Publish verified hydrostatic experiments on the Japanese/English wave pages."""
import hashlib
import html
import json
import math
from pathlib import Path
import re
import sys
from run import CHARTS, cases, verify_refinement

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
sys.path.insert(0, str(ROOT / "gallery/tools"))
from wave_movies import video_html
NAME='kinetic_hydrostatic'
BASE='../../examples/kinetic_hydrostatic'
SLUG='kinetic-hydrostatic'
BEGIN='<!-- kinetic-hydrostatic:begin -->'
END='<!-- kinetic-hydrostatic:end -->'
NAV_BEGIN='<!-- kinetic-hydrostatic:nav:begin -->'
NAV_END='<!-- kinetic-hydrostatic:nav:end -->'


def load_report():
    report=json.loads((HERE/'results/verification.json').read_text())
    for key,file in (('source_sha256',NAME+'.fme'),('driver_sha256','driver.c'),
                     ('config_sha256','config.h'),('orchestration_sha256','run.py')):
        assert report[key]==hashlib.sha256((HERE/file).read_bytes()).hexdigest(),file
    expected={(n,chart,*case) for n in (16,32,64) for chart in CHARTS for case in cases(n)}
    keys=[tuple(r[k] for k in ('grid','chart','scenario','balanced','time_scale','duration')) for r in report['runs']]
    if len(keys)!=24 or set(keys)!=expected:
        raise ValueError('publish only the complete 24-case verification')
    for r in report['runs']:
        f=r['final']
        assert all(math.isfinite(v) for v in f.values())
        assert r['mass_drift']<2e-11 and f['lowest']>=-1e-12 and f['equilibriumLowest']>=0 and f['minArea']>0
        assert all(f[key]<1e-12 for key in ('collisionResidual','forceResidual','wallMassFlux','wallTangentialFlux'))
        if r['scenario']=='rest' and r['balanced']:
            assert r['max_speed']<2e-12 and r['max_density_error']<2e-12
        if r['scenario']=='perturbation':
            assert r['max_speed']>1e-5
        if r['scenario']=='acceleration':
            assert max(abs(h['accelerationError']) for h in r['history'])<2e-12
    assert verify_refinement(report['runs'],[16,32,64])==report['checks']
    return report


def scientific(value):
    if value==0:
        return '0'
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
    mass=scientific(max(r['mass_drift'] for r in runs))
    wall=scientific(max(r['final']['wallMassFlux'] for r in runs))
    rest_speed=scientific(max(r['max_speed'] for r in runs if r['scenario']=='rest' and r['balanced']))
    if lang=='ja':
        title='重力と壁を加える：静水を保ち，小さな乱れを動かす'
        description='粘性のあるD2Q9（二次元の九方向の分布）に，重力と上下の反射壁を加えました。静水状態からの差を計算し，重力と圧力が計算上もつり合うようにします。密度の小さな乱れを与えた場合は，流れが生じて伝わります。直交格子と曲がった格子で物理モデルは共通です。'
        equation_note='ρHは高さYでの静水密度，hは静水の分布fHからの差です。この差を輸送することで静水を保つwell-balanced法（定常状態を保つ計算法）を使います。'
        caption='左：静水から勝手に生じる流速の最大値。通常の重力の加え方と，静水からの差を使う方法を比較します。右：密度に0.1%の乱れを与えたときの，初期の空間的な波形に沿った密度変化の大きさ（投影振幅）。曲線は実際の計算値で，解析解ではありません。'
        facts=f'<b>24条件の検証が通過。</b> 静水での最大流速は{rest_speed}。32×32セルでは時刻8πまで静水を保ちました。乱れを与えた試験では流れが生じ，水平に外力を加えた試験では総運動量が力×時間に一致しました。'
        table_caption='静水試験での最大流速（時刻0〜2π）'
        labels=('格子','セル数','通常の重力項','静水からの差')
        names=('直交','曲がった格子')
        scope=f'全条件で質量の相対変化は最大{mass}，壁を通る質量流量は最大{wall}。物理的な分布，時間微分から一回進めた中間値，平衡分布の非負性を検査しました。一般の外力下で非負性を保証する条件は，引き続き検討します。'
        wall_note='壁では上下方向の分布を入れ替えて反射させます。水が壁を通り抜けず，壁に沿っては滑る条件です。内部ではセル内の傾きから面の値を求め，壁に接したセルでは上下方向の傾きをゼロにします。'
        limits='これは領域全体を流体で満たした，密度が高さで変わる静水の試験です。水面・傾斜した海底・水際の後退は次の段階です。初期条件，境界処理，時間積分，診断値を含むすべての計算をFormuraeに記述し，構文と処理系は変更していません。'
        previous='<a href="#kinetic-viscosity">衝突と粘性の検証</a>に続く実験です。<a href="#breaking-wave">巻き込む波と引き波</a>への組込みに向け，重力と壁の扱いを検証しています。'
        more,checks,vector='式・壁の扱い・再現手順','24条件の検証結果','拡大できるグラフ（SVG）'
    else:
        title='Adding gravity and walls: preserving rest and evolving small disturbances'
        description='We add gravity and reflecting horizontal walls to the viscous D2Q9 model (nine velocity populations in two dimensions). Evolving the difference from hydrostatic equilibrium balances gravity and pressure numerically. A small density disturbance generates motion. Cartesian and mapped grids share the physical model.'
        equation_note='ρH is the hydrostatic density at height Y; h is the departure from the resting populations fH. Evolving this departure gives a well-balanced method, which preserves the stationary state.'
        caption='Left: maximum spurious speed starting from rest, comparing ordinary gravity forcing with evolution of the hydrostatic departure. Right: density change projected onto the initial spatial pattern after a 0.1% disturbance. These curves are simulation results, not analytical references.'
        facts=f'<b>All 24 verification cases passed.</b> Maximum hydrostatic speed was {rest_speed}. The 32×32 runs preserved rest through t=8π. Density disturbances generated motion, and horizontal acceleration produced the expected total momentum: force × time.'
        table_caption='Maximum speed from hydrostatic initial data (t=0 to 2π)'
        labels=('Geometry','Cells','Ordinary forcing','Hydrostatic departure')
        names=('Cartesian','Mapped')
        scope=f'Across all cases, maximum relative mass drift was {mass} and wall mass flux was {wall}. Physical populations, Euler candidates before averaging, and equilibrium populations were checked for nonnegativity. A general positivity condition including forcing remains to be established.'
        wall_note='Reflection reverses the vertical velocity label. Fluid cannot cross the walls but may slip tangentially. Interior face values use limited cell slopes; vertical slopes are zero in cells adjacent to the walls.'
        limits='This is a fully filled domain with a height-dependent density. A free surface, a sloping bed and shoreline retreat are the next steps. All calculations, including initial conditions, boundary treatment, time integration and diagnostics, are written in Formurae, with no syntax or compiler changes.'
        previous='This follows the <a href="#kinetic-viscosity">collision and viscosity experiment</a> and tests gravity and wall treatment toward integration into the <a href="#breaking-wave">breaking-wave and backwash simulation</a>.'
        more,checks,vector='Equations, walls and reproduction','All 24 verification cases','Scalable graph (SVG)'
    rows=[]
    for chart,name in zip(CHARTS,names):
        for size in (16,32,64):
            pair=[next(r for r in runs if r['chart']==chart and r['grid']==size and r['scenario']=='rest' and r['duration']==1 and r['balanced']==b) for b in (0,1)]
            rows.append(f'<tr><th scope="row">{name}</th><td>{size}×{size}</td>'+''.join(f'<td>{scientific(r["max_speed"])}</td>' for r in pair)+'</tr>')
    headings=''.join(f'<th scope="col">{label}</th>' for label in labels)
    card=f'''{BEGIN}
<article class="card featured" id="{SLUG}">
<h3>{title}</h3><p class="description">{description}</p>
<div class="math">ρH(Y) = exp(−3gY)，h = f − fH<br>∂t h + div(c h) = (f_eq − f)/τ + S(f) − S(fH)</div>
<p class="description">{equation_note}</p>
{video_html(NAME, lang)}
<div class="imgs"><a href="{BASE}/results/hydrostatic.svg"><img src="{BASE}/results/hydrostatic.png" alt="{html.escape(caption)}" width="1800" height="756" loading="lazy"></a></div>
<p class="cap">{caption}</p><p class="facts">{facts}</p>
<div style="overflow-x:auto;margin:12px 0"><table style="width:100%;min-width:460px;border-collapse:collapse;font-size:12.5px;text-align:right"><caption style="text-align:left;padding-bottom:8px">{table_caption}</caption><thead><tr>{headings}</tr></thead><tbody>{''.join(rows)}</tbody></table></div>
<p class="description">{scope}</p><p class="description">{wall_note}</p>
<p class="description">{limits}</p><p class="description">{previous}</p>
<p class="facts"><a href="{BASE}/README.md">{more}</a> · <a href="{BASE}/results/verification.json">{checks}</a> · <a href="{BASE}/results/hydrostatic.svg">{vector}</a><br><code>make kinetic-hydrostatic-verify</code></p>
{source_blocks(lang)}
</article>
{END}'''
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
        path=ROOT/'html'/lang/'waves.html'
        page=replace_or_insert(path.read_text(),BEGIN,END,card,'<!-- kinetic-viscosity:begin -->')
        nav=f'{NAV_BEGIN}<p><a href="#{SLUG}">{title}</a></p>{NAV_END}'
        page=replace_or_insert(page,NAV_BEGIN,NAV_END,nav,'<!-- kinetic-viscosity:nav:begin -->')
        path.write_text(page)
        print(path)


if __name__=='__main__':
    main()
