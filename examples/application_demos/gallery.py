#!/usr/bin/env python3
"""Regenerate only the three application cards in the existing JA/EN gallery."""
import html
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
RESULT=ROOT/'examples/application_demos/results'
BEGIN='<!-- application-demos:begin -->'
END='<!-- application-demos:end -->'

def source_block(name, suffix, lang):
    rel=f'{name}/{name}.{suffix}'
    text=(ROOT/'examples'/rel).read_text()
    label=('ソース全文' if suffix=='fme' else '生成されたソース') if lang=='ja' else ('Full model source' if suffix=='fme' else 'Generated source')
    return f'<details class="codebox" data-{suffix}="{rel}"><summary>{label}: {name}.{suffix}</summary><pre>{html.escape(text)}</pre></details>'

def excerpt(name, definitions):
    lines=(ROOT/'examples'/name/(name+'.fme')).read_text().splitlines()
    return '\n'.join(line for line in lines if any(line.startswith('def '+word+' ') for word in definitions))

def card(key,title,description,equation,code,caption,facts,lang,model=None):
    base='../../examples/application_demos/results/'+key
    for ext in ['comparison.png','comparison.mp4','measurements.png','runs.json']:
        if not (RESULT/key/ext).is_file(): raise FileNotFoundError(RESULT/key/ext)
    source='\n'.join(source_block(model,suffix,lang) for suffix in ['fme','egi','feir','fmr']) if model else ''
    readme=f'../../examples/{model}/README.md' if model else '../../examples/application_demos/README.md'
    more='モデルと再現手順' if lang=='ja' else 'Model and reproduction'
    checks='検証結果' if lang=='ja' else 'Verification results'
    code_label='変更する演算子（実際のソースから抜粋）' if lang=='ja' else 'Operators being changed (excerpt from the actual source)'
    video_fallback='動画を再生できません．' if lang=='ja' else 'Video playback is unavailable.'
    return f'''<article class="card featured" id="{key.replace('_','-')}">
<h3>{title}</h3>
<p class="description">{description}</p>
<div class="math">{equation}</div>
<div class="codebox"><div class="head">{code_label}</div><pre style="white-space:pre-wrap;overflow-wrap:anywhere">{html.escape(code)}</pre></div>
<div class="imgs"><video controls loop muted playsinline preload="none" poster="{base}/comparison.png"><source src="{base}/comparison.mp4" type="video/mp4">{video_fallback}</video></div>
<p class="cap">{caption}</p>
<div class="imgs"><img src="{base}/measurements.png" alt="{html.escape(title)}: {'測定値の比較' if lang=='ja' else 'measured comparison'}" loading="lazy"></div>
<p class="facts">{facts}<br><a href="{readme}">{more}</a> · <a href="../../examples/application_demos/results/verification.json">{checks}</a> · <a href="{base}/runs.json">{'実行条件' if lang=='ja' else 'Run settings'}</a></p>
{source}
</article>'''

def generate(lang,report):
    heat=report['battery_cooling']; waves=report['composite_ultrasound']; light=report['optics_design']
    hv=heat['comparisons']; wv=waves['comparisons']; ov=light['comparisons']
    if lang=='ja':
        title='材料則と座標変換を変更する応用デモ'
        intro='利用者が関数として定義した演算子を，材料や装置の比較に使う三つの例です．初期条件・境界処理・時間発展・物理量の測定を Formurae に記述し，同じコード生成経路で実行しています．'
        a=card('composite_ultrasound','複合材の超音波：繊維方向と柔らかい領域',
            '向きによって硬さが違う材料を考えます．繊維方向を 0° と 45° に変え，健全な材料と，一か所の剛性が低下した材料を比較します．ひずみから応力を返す <code>stressRate</code> の定義を共通の更新式に組み込み，波面と受信波形への影響を調べます．',
            'C(E)<sup>ij</sup> = s(x,y)[λg<sup>ij</sup>g<sup>kl</sup>E<sub>kl</sub> + 2μg<sup>ik</sup>g<sup>jl</sup>E<sub>kl</sub> + αn<sup>i</sup>n<sup>j</sup>n<sup>k</sup>n<sup>l</sup>E<sub>kl</sub>]',
            excerpt('composite_ultrasound',['direction','stiffness','strain','stressRate']),
            '上段は繊維方向 0°，下段は 45°．左は健全，右は破線の円の付近が柔らかい材料．＋は波源，三角は受信点．無次元の材料内部の波動で，亀裂や自由表面は含みません．',
            f'256×192 点，t=2.4 まで．修正エネルギーの相対変動は最大 {max(v["relative_modified_energy_drift"] for v in wv.values()):.1e}．平面波の最大誤差は格子の細分化で {waves["plane_wave_max_errors"][0]:.3g} から {waves["plane_wave_max_errors"][1]:.3g} へ減少．',lang,'composite_ultrasound')
        b=card('optics_design','電磁波を回転させる材料：角度と層の厚さ',
            '座標変換の式を解析的に微分し，その積から材料テンソルを求めます．波面を回す角度と材料層の厚さを変え，装置内の波面と装置外の散乱を比較します．理想化した連続体の設計比較です．',
            'φ′ = φ + θ(R₂−r)/(R₂−R₁)， J<sup>k</sup><sub>i</sub> = ∂F<sup>k</sup>/∂x<sup>i</sup>， g<sub>ij</sub> = J<sup>k</sup><sub>i</sub>J<sup>k</sup><sub>j</sub>',
            excerpt('transformation_optics',['angle','rotated','rotatedJacobian','rotatedMetric']),
            '左上から 0°，22.5°，45°，厚い層の 45°．厚い層では外半径 2 を保ち，内半径を 1 から 0.5 に縮めます．全条件の散乱は同じ外側領域 r&gt;2.5 で測定します．',
            '240×180 点，t=10 の散乱指標：'+ '，'.join(f'{label} {ov[c]["scattering_ratio"]:.3g}' for c,label in [('zero','0°'),('turn22','22.5°'),('turn45','45°'),('turn45-wide','厚い層')])+ '．<a href="#transformation-optics">元のモデルと生成ソース全文</a>も参照できます．',lang)
        c=card('battery_cooling','円筒型電池：熱伝導の方向依存性と冷却面',
            '中央ほど強く発熱する円筒型電池の巻回部を考えます．軸方向に熱が伝わりやすい材料テンソルを <code>heatFlux</code> に組み込み，等方モデルとの差と，側面・端面の冷却の効果を比較します．値はモデル比較用で，特定製品への適合結果ではありません．',
            'K<sup>ij</sup> = k<sub>r</sub>g<sup>ij</sup> + (k<sub>z</sub>−k<sub>r</sub>)a<sup>i</sup>a<sup>j</sup>， ρc ∂<sub>t</sub>T = r⁻¹∂<sub>r</sub>(r k<sub>r</sub>∂<sub>r</sub>T) + ∂<sub>z</sub>(k<sub>z</sub>∂<sub>z</sub>T) + Q',
            excerpt('battery_cooling',['axis','conductivity','heatFlux']),
            '水色の辺が冷却面．上段：等方／側面冷却，異方／側面冷却．下段：異方／端面冷却，異方／両方冷却．初期温度と冷却媒体は 25 °C．内半径 2 mm，外半径 9 mm，長さ 65 mm．',
            '400 秒後の最高温度は順に '+ '，'.join(f'{hv[k]["maximum_temperature_C"]:.2f} °C' for k in ['side-isotropic','side-anisotropic','ends-anisotropic','both-anisotropic'])+f'．熱収支の相対誤差は最大 {max(v["relative_heat_balance_error"] for v in hv.values()):.1e}．65×193 点に細分化したときの両面冷却の最高温度差は {heat["refinement_difference_K"]:.3g} K．',lang,'battery_cooling')
    else:
        title='Applications with user-defined material laws and coordinate maps'
        intro='Three comparisons put user-defined operators to work. Initial conditions, boundary treatment, time evolution and physical diagnostics are all written in Formurae and run through the same code-generation pipeline.'
        a=card('composite_ultrasound','Composite ultrasound: fiber direction and a soft inclusion',
            'Compare a healthy medium and a locally softer region at fiber angles of 0 and 45 degrees. The material tensor in <code>stressRate</code>, a function mapping strain to stress, changes while the time-stepping equations stay the same. Observe both wavefronts and the receiver signal.',
            'C(E)<sup>ij</sup> = s(x,y)[λg<sup>ij</sup>g<sup>kl</sup>E<sub>kl</sub> + 2μg<sup>ik</sup>g<sup>jl</sup>E<sub>kl</sub> + αn<sup>i</sup>n<sup>j</sup>n<sup>k</sup>n<sup>l</sup>E<sub>kl</sub>]',
            excerpt('composite_ultrasound',['direction','stiffness','strain','stressRate']),
            'Top: fibers at 0 degrees. Bottom: 45 degrees. Left: healthy. Right: a soft region near the dashed circle. + marks the source and the triangle the receiver. Dimensionless bulk-wave model; no cracks or traction-free surfaces.',
            f'256×192 points, through t=2.4. Maximum relative drift of the modified energy: {max(v["relative_modified_energy_drift"] for v in wv.values()):.1e}. Plane-wave maximum errors decrease from {waves["plane_wave_max_errors"][0]:.3g} to {waves["plane_wave_max_errors"][1]:.3g} under refinement.',lang,'composite_ultrasound')
        b=card('optics_design','Electromagnetic field rotator: angle and layer thickness',
            'Analytically differentiate a coordinate map and contract its derivatives to obtain a material tensor. Compare the internal wavefront and external scattering while changing rotation angle and layer thickness. This is a design study of idealized continuous media.',
            'φ′ = φ + θ(R₂−r)/(R₂−R₁), J<sup>k</sup><sub>i</sub> = ∂F<sup>k</sup>/∂x<sup>i</sup>, g<sub>ij</sub> = J<sup>k</sup><sub>i</sub>J<sup>k</sup><sub>j</sub>',
            excerpt('transformation_optics',['angle','rotated','rotatedJacobian','rotatedMetric']),
            'Reading order: 0, 22.5, 45 degrees, then 45 degrees with a thicker layer. The thicker layer keeps the outer radius at 2 and reduces the inner radius from 1 to 0.5. Scattering is measured in the same region r&gt;2.5 in every case.',
            '240×180 points. Scattering indicator at t=10: '+ ', '.join(f'{label}: {ov[k]["scattering_ratio"]:.3g}' for k,label in [('zero','0°'),('turn22','22.5°'),('turn45','45°'),('turn45-wide','thicker layer')])+ '. See the <a href="#transformation-optics">original model and full generated sources</a>.',lang)
        c=card('battery_cooling','Cylindrical cell: directional conduction and cooling surfaces',
            'A cylindrical wound annulus has stronger heating near its axial center. Define the conductivity tensor and contract it with the temperature gradient in <code>heatFlux</code>. Compare isotropic and directional conduction, then side and end cooling. Parameters illustrate a model comparison and are not fitted to a particular product.',
            'K<sup>ij</sup> = k<sub>r</sub>g<sup>ij</sup> + (k<sub>z</sub>−k<sub>r</sub>)a<sup>i</sup>a<sup>j</sup>, ρc ∂<sub>t</sub>T = r⁻¹∂<sub>r</sub>(r k<sub>r</sub>∂<sub>r</sub>T) + ∂<sub>z</sub>(k<sub>z</sub>∂<sub>z</sub>T) + Q',
            excerpt('battery_cooling',['axis','conductivity','heatFlux']),
            'Cyan edges are cooled. Top: isotropic/side cooling, anisotropic/side cooling. Bottom: anisotropic/end cooling, anisotropic/both. Initial and coolant temperatures: 25 °C. Inner radius 2 mm, outer radius 9 mm, length 65 mm.',
            'Maximum temperatures at 400 s, in panel order: '+ ', '.join(f'{hv[k]["maximum_temperature_C"]:.2f} °C' for k in ['side-isotropic','side-anisotropic','ends-anisotropic','both-anisotropic'])+f'. Maximum relative heat-balance error: {max(v["relative_heat_balance_error"] for v in hv.values()):.1e}. Refining to 65×193 points changes the maximum temperature with both cooling surfaces by {heat["refinement_difference_K"]:.3g} K.',lang,'battery_cooling')
    return f'{BEGIN}\n<section id="application-demos"><h2>{title}</h2><p>{intro}</p><div class="grid">\n'+a+'\n'+b+'\n'+c+'\n</div></section>\n'+END

if __name__=='__main__':
    report=json.loads((RESULT/'verification.json').read_text())
    for lang in ['ja','en']:
        path=ROOT/'html'/lang/'gallery.html'; page=path.read_text(); section=generate(lang,report)
        if BEGIN in page:
            before,rest=page.split(BEGIN,1); _,after=rest.split(END,1); page=before+section+after
        else: page=page.replace('<main>','<main>\n\n'+section,1)
        path.write_text(page)
        print(path)
