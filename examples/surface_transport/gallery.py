#!/usr/bin/env python3
"""Publish the verified interface-transport experiment on both wave pages."""
import hashlib
import html
import json
from pathlib import Path
import re

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
BASE='../../examples/surface_transport'
NAME='surface_transport'
BEGIN,END='<!-- surface-transport:begin -->','<!-- surface-transport:end -->'
NB,NE='<!-- surface-transport:nav:begin -->','<!-- surface-transport:nav:end -->'


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def load():
    r=json.loads((HERE/'results/verification.json').read_text())
    assert r['passed'] and len(r['runs'])==28
    for key,file in [('source_sha256',NAME+'.fme'),('driver_sha256','driver.c'),('config_sha256','config.h'),('orchestration_sha256','run.py')]:
        assert r[key]==sha(HERE/file),f'stale verification: {file}'
    for ext,value in r['generated'].items():
        assert value==sha(HERE/f'{NAME}.{ext}')
    media=json.loads((HERE/'results/rendering.json').read_text())
    assert media['verification_sha256']==sha(HERE/'results/verification.json')
    assert media['source_sha256']==r['source_sha256'] and media['renderer_sha256']==sha(HERE/'render.py')
    for case,values in media['movies'].items():
        for ext,value in values['media'].items():
            assert value==sha(HERE/f'results/{case}.{ext}')
    return r


def sources(lang):
    labels=['Formurae ソース全文','生成された Egison','正規化結果 FEIR','生成された Formura'] if lang=='ja' else ['Full Formurae source','Generated Egison','Normalized FEIR','Generated Formura']
    blocks=[]
    for ext,label in zip(['fme','egi','feir','fmr'],labels):
        source=(HERE/f'{NAME}.{ext}').read_text().rstrip('\n')
        blocks.append(f'<details class="codebox" data-{ext}="{NAME}/{NAME}.{ext}"><summary>{label} ({NAME}.{ext})</summary><pre>{html.escape(source,quote=False)}</pre></details>')
    return '\n'.join(blocks)


def card(lang,r):
    drift=max(run['volume_drift'] for run in r['runs'])
    low=min(run['final']['lowest'] for run in r['runs'])
    high=max(run['final']['highest'] for run in r['runs'])
    excess=r['range_check']['maximum_excess']
    tolerance=r['range_check']['maximum_tolerance']
    ratio=max(r['checks'][chart+'-high-to-upwind-ratios']['returnedL1'] for chart in ['cartesian','mapped'])
    if lang=='ja':
        title='水面をセルの間で運ぶ：水量と0〜1の範囲を保つ'
        description='各セルを水が占める割合を運び，水面がセルをまたいで移動・変形する過程を検証します。流れをあらかじめ指定した輸送試験です。D2Q9で流速を求める処理や，重力・水面の圧力条件との結合は次の段階です。'
        captions={'wave':'320²セルで，波形の境界を一定の流れで横へ一周させます。直交格子と曲線格子で同じ初期形状・流れを使っています。この波形は流れに運ばれるもので，自由に伝わる重力波ではありません。',
                  'vortex':'128²セルで，円形の水領域を渦で伸ばし，流れを反転して戻します。左と中央は傾きを制限した直線でセル内を近似するMUSCL法，右はセル内を一定値とする一次風上法です。後者は輪郭がよりぼけます。'}
        legend='青は保存した占有率，実線は0.5の等値線，破線は初期の境界です。下段は中間の占有率の広がりを示す指標で，物理的な混合ではありません。描画で水の形や動きを付け加えていません。'
        facts=f'<b>28条件の検証が通過。</b> 水量の相対変化は最大{drift:.2e}。全中間段階を含む占有率の範囲は{low:.3g}〜{high:.16g}でした。範囲からの超過は最大{excess:.2e}で，各出力時刻の更新回数kに応じた許容値 max(2×10⁻¹², k×2.22×10⁻¹⁶) 以内でした（許容値の最大は{tolerance:.2e}）。128²セルで元の形へ戻った際の誤差は，MUSCL法では一次風上法の最大{ratio:.2f}倍でした。'
        note='面を通る流量を隣接セルで共有し，流量の出入りもつり合わせます。時間刻みの十分条件を検査し，占有率を0〜1へ切り詰める補正や全体の水量の補正は行いません。初期境界には幅0.025の遷移を設けています。'
        headings=['セル数','波形・直交','波形・曲線','渦・直交','渦・曲線']
        table_note='表は一周・反転後のずれ ΣA|α(T)−α(0)| です。Aは物理的なセル面積，αは占有率です。領域の面積は1です。水面の圧力や水際の処理との結合はまだ行っていません。'
        read,results='モデル・範囲と水量を保つ条件・再現手順','28条件の検証記録'
    else:
        title='Transporting an interface across cells while preserving volume and bounds'
        description='A cell-averaged water volume fraction is transported across cells through translation and deformation. Flow is prescribed in this test. Computing velocity with D2Q9 and coupling gravity and surface pressure remain subsequent steps.'
        captions={'wave':'A wave-shaped interface travels once around the domain in a uniform flow on 320² cells. Cartesian and mapped grids share the initial shape and physical flow. This is an advected shape, not a freely propagating gravity wave.',
                  'vortex':'A circular water region stretches in a vortex and returns as flow reverses on 128² cells. Left and middle: MUSCL, a slope-limited linear approximation within each cell. Right: first-order upwind with constant cell values, which smears the interface more.'}
        legend='Blue shows the saved fraction; solid lines mark 0.5 and dashed lines the initial interface. The lower plot measures intermediate fractions, not physical mixing. Rendering does not prescribe interface motion.'
        facts=f'<b>All 28 cases passed.</b> Maximum relative volume drift was {drift:.2e}. Fractions, including both Euler candidates, ranged from {low:.3g} to {high:.16g}. The maximum excess was {excess:.2e}. Each output was checked against max(2×10⁻¹², k×2.22×10⁻¹⁶), with k the update count; the largest tolerance was {tolerance:.2e}. On 128² cells, MUSCL return error was at most {ratio:.2f} times first-order upwind error.'
        note='Adjacent cells share face flow, with balanced inflow and outflow. A sufficient timestep condition is checked. No clipping to [0,1] or global volume correction changes the state. The initial interface has a finite transition width of 0.025.'
        headings=['Cells','Wave / Cartesian','Wave / mapped','Vortex / Cartesian','Vortex / mapped']
        table_note='The table lists return differences ΣA|α(T)−α(0)|, where A is physical cell area and α is volume fraction. Domain area is 1. Surface-pressure and wetting/drying coupling have not yet been implemented.'
        read,results='Model, bounds, conservation and reproduction','All 28 verification cases'
    videos=[]
    for case in ['wave','vortex']:
        videos.append(f'<div class="imgs"><video controls loop muted playsinline preload="none" width="1200" height="720" poster="{BASE}/results/{case}.png" aria-label="{html.escape(captions[case])}"><source src="{BASE}/results/{case}.mp4" type="video/mp4"><a href="{BASE}/results/{case}.mp4">MP4</a></video></div><p class="cap">{captions[case]}</p>')
    rows=[]
    for n in sorted({x['grid'] for x in r['runs']}):
        values=[next(x['final']['returnedL1'] for x in r['runs'] if (x['grid'],x['case'],x['chart'],x['method'],x['time_scale'])==(n,case,chart,1,n/128 if n>=256 else 1)) for case in ['wave','vortex'] for chart in ['cartesian','mapped']]
        rows.append(f'<tr><td>{n}²</td>'+''.join(f'<td>{v:.4e}</td>' for v in values)+'</tr>')
    table='<div style="overflow-x:auto;margin:12px 0"><table style="width:100%;min-width:590px;border-collapse:collapse;text-align:right;font-size:13px"><thead><tr>'+''.join(f'<th scope="col">{x}</th>' for x in headings)+'</tr></thead><tbody>'+''.join(rows)+'</tbody></table></div>'
    return f'''{BEGIN}
<article class="card featured" id="surface-transport">
<h3>{title}</h3><p class="description">{description}</p>
<div class="math">∂t α + div(u α) = 0， div u = 0， 0 ≤ α ≤ 1</div>
<p class="description">{note}</p>
{''.join(videos)}
<p class="cap">{legend}</p><p class="facts">{facts}</p>
{table}<p class="cap">{table_note}</p>
<p class="facts"><a href="{BASE}/README.md">{read}</a> · <a href="{BASE}/results/verification.json">{results}</a><br><code>make surface-transport-verify</code> · <code>make surface-transport-gallery</code></p>
{sources(lang)}
</article>
{END}''',title


def main():
    report=load()
    for lang in ['ja','en']:
        path=ROOT/'html'/lang/'waves.html'
        text=path.read_text()
        article,title=card(lang,report)
        if BEGIN in text:
            text,count=re.subn(re.escape(BEGIN)+'.*?'+re.escape(END),lambda _:article,text,flags=re.S)
            assert count==1
        else:
            marker='<!-- kinetic-hydrostatic:begin -->'
            assert text.count(marker)==1
            text=text.replace(marker,article+'\n'+marker,1)
        nav=f'{NB}<p><a href="#surface-transport">{title}</a></p>{NE}'
        if NB in text:
            text,count=re.subn(re.escape(NB)+'.*?'+re.escape(NE),lambda _:nav,text,flags=re.S)
            assert count==1
        else:
            marker='<!-- kinetic-hydrostatic:nav:begin -->'
            assert text.count(marker)==1
            text=text.replace(marker,nav+'\n'+marker,1)
        path.write_text(text)
        print(path)


if __name__=='__main__':
    main()
