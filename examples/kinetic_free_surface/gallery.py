#!/usr/bin/env python3
"""Publish the measured development status on both wave pages."""
import html
import json
from pathlib import Path
import re
import run

BASE='../../examples/kinetic_free_surface'
BEGIN,END='<!-- kinetic-free-surface:begin -->','<!-- kinetic-free-surface:end -->'
NB,NE='<!-- kinetic-free-surface:nav:begin -->','<!-- kinetic-free-surface:nav:end -->'


def load():
    path=run.HERE/'results/verification.json'
    report=json.loads(path.read_text())
    assert report['source_sha256']==run.sha(run.HERE/f'{run.NAME}.fme')
    assert report['verifier_sha256']==run.sha(run.HERE/'verify.py')
    assert report['assessor_sha256']==run.sha(run.HERE/'assess.py')
    assert report['foundation_passed']
    candidates=[c for c in report['cases'] if c['check']=='backwash']
    assert len(candidates)==1
    beach=candidates[0]
    parameters=beach['record']['parameters']
    for case in report['cases']:
        for key in ['heightMethod','method']:
            if case['check']=='falling' and key=='method':
                continue  # the falling suite reports its own transport method
            assert case['record']['parameters'][key]==parameters[key], ('different numerical method',case['directory'],key)
    bed_checks=[case for case in report['cases'] if case['check']=='bed_rest']
    assert len(bed_checks)==1 and bed_checks[0]['passed']
    shear_checks=[case for case in report['cases'] if case['check']=='shear' and case.get('role')=='beach-shear']
    assert len(shear_checks)==1 and shear_checks[0]['passed']
    for key in ['tau','timeScale']:
        assert shear_checks[0]['record']['parameters'][key]==parameters[key]
    # Conservation and boundedness must pass even for a visibly labelled
    # experiment that has not met the breaking/retreat acceptance criteria.
    basic=[c for c in report['cases'] if c['directory']==beach['directory'] and c['check']=='basic']
    assert len(basic)==1
    # Conservation, bounds and positivity are required; the only basic check
    # a displayed development run may fail is the retained-speed limit, and
    # that failure is shown on the card.
    if not basic[0]['passed']:
        assert basic[0]['failure'].startswith("('retained speed'"), basic[0]['failure']
    rendering=json.loads((run.HERE/'results/beach.json').read_text())
    assert rendering['source_sha256']==report['source_sha256']
    assert rendering['result_sha256']==beach['record_sha256']
    assert rendering['frames_sha256']==beach['record']['files']['frames.npz']
    assert rendering['renderer_sha256']==run.sha(run.HERE/'render.py')
    for ext,digest in rendering['media'].items():
        assert digest==run.sha(run.HERE/f'results/beach.{ext}')
    review=json.loads((run.HERE/'results/surface-review.json').read_text())
    assert review['source_sha256']==report['source_sha256']
    assert review['frames_sha256']==rendering['frames_sha256']
    strong=None
    if (run.HERE/'results/strong.json').exists():
        strong=json.loads((run.HERE/'results/strong.json').read_text())
        assert strong['source_sha256']==report['source_sha256']
        assert strong['renderer_sha256']==run.sha(run.HERE/'render.py')
        for ext,digest in strong['media'].items():
            assert digest==run.sha(run.HERE/f'results/strong.{ext}')
        assert review['strong_frames_sha256']==strong['frames_sha256']
    return report,beach,basic[0],review,strong


def card(lang,report,beach,basic,review,strong):
    r=beach['record']; m=beach['backwash']['measurements']; p=r['parameters']
    period_cases=[c for c in report['cases'] if c['check']=='wave']
    period_errors=[abs(c['record']['final']['wavePeriod']/c['record']['final']['expectedPeriod']-1) for c in period_cases]
    assert period_cases
    def period_item(c,e):
        f=c['record']['final']; A=c['record']['parameters']['amplitude']
        extra='' if c['passed'] else (f"，流速 {f['peakSpeed']:.2f}，分布最小 {f['populationLowest']:.2f}" if lang=='ja' else f", speed {f['peakSpeed']:.2f}, lowest population {f['populationLowest']:.2f}")
        return f"A={A}: {100*e:.2f}%{extra}"
    period_text=', '.join(period_item(c,e) for c,e in zip(period_cases,period_errors))
    title=('動く水面と斜面：巻き込みと引き波に向けた検証' if lang=='ja' else
           'Moving free surface and sloping beach: testing breaking and backwash')
    accepted=report['numerical_checks_passed'] and beach['passed'] and review['connected_crest_cavity_impact']
    speed=r['final']['peakSpeed']
    mass_drift=r['mass_drift']/r['history'][0]['waterMass']
    speed_note=('' if basic['passed'] else (f'記録した最大流速 {speed:.3f} は基準 0.3 を超えました（保存・有界性・正値性は通過）。' if lang=='ja' else f'The retained speed record {speed:.3f} exceeds the 0.3 limit (conservation, bounds and positivity pass).'))
    periods_passed=all(c['passed'] for c in period_cases)
    falling_cases=[c for c in report['cases'] if c['check']=='falling']
    assert len(falling_cases)==4
    falling_passed=all(c['passed'] for c in falling_cases)
    if lang=='ja':
        description='D2Q9（二次元で九方向の分布を使う流体モデル）の移動を微分方程式で計算し，動く水面に大気圧を与えます。海底に沿って曲げた格子でも，共有面を通る流量と同じ流れの式を使います。初期条件，重力，壁，水面，時間更新，検査値はすべてFormuraeで求めています。'
        status=('連続した巻き込み・空洞・衝突と，薄い水を含む水際の後退を確認しました。' if accepted else
                '開発中です。段階5の連続した巻き込み・空洞・衝突と，段階6の薄い水を含む水際の後退は，以下の検査と動画で区別して確認します。未達の項目を完了扱いにはしていません。')
        caption='色は計算した水の割合，矢印は流速です。実線は割合0.5，破線は0.01。上は水槽全体，下は水面の拡大図です。右のグラフは水際の位置と，初めの水際より岸側にある全水量で，薄い層も含みます。'
        foundation='直交格子・曲線格子の静水と平行移動，衝突による緩和，粘性による減衰の基礎10条件が通過しました。斜面上の静水と，波に用いる格子・時間刻みでの粘性の検査も通過しました。'
        period_status='通過しました' if periods_passed else '未達があります'
        falling_status='通過しました' if falling_passed else '未達があります'
        limitations=f'小さな定在波（水槽内で往復する波）の周期検査は{period_status}。各条件の差は{period_text}で，基準は5%です。水の層の自由落下を調べる四条件は{falling_status}（運動量と重心の落下量の基準は2%）。空気自身の運動，表面張力，気泡の圧縮はまだ含みません。'
        metrics=[('水量の最大相対変化',f'{mass_drift:.3e}'),
                 ('水際0.5の後退距離',f'{m["shoreline_retreat"]:.5f}'),
                 ('薄い水0.01の後退距離',f'{m["thin_front_retreat"]:.5f}'),
                 ('岸側の水量：最大 → 最後',f'{m["maximum_mass_above_shore"]:.6f} → {m["final_mass_above_shore"]:.6f}')]
        notes=review['ja']
        links='方程式・再現手順'
        check_title='引き波の数値検査'
        names={'runup':'水の遡上','shoreline_retreat':'水際0.5の後退','bulk_retreat':'厚みのある水の後退','offshore_flow':'沖向きの流れ','overturning_candidate':'覆いかぶさる形の候補セル','thin_layer_retreat':'薄い水0.01の後退','water_arrived_above_shore':'岸側への水の到達','water_returned_from_shore':'岸側の全水量の減少','waterline_avoids_far_wall':'水際が右端の壁に届かない','thin_layer_avoids_far_wall':'薄い水も右端の壁に届かない'}
        passed,failed='通過','未達'
    else:
        description='The nine velocity populations of D2Q9 are transported by a differential equation and coupled to atmospheric pressure at a moving surface. A mesh fitted to the bed uses the same face-flux and fluid equations. Initialization, gravity, walls, the surface, time integration and physical diagnostics are all computed in Formurae.'
        status=('A connected curling crest, cavity, impact and retreat of the shoreline including thin water have been observed.' if accepted else
                'Under development. A connected curling crest, cavity and impact (stage 5), and retreat including thin water (stage 6), are assessed separately below. Failed criteria remain open.')
        caption='Color shows computed water fraction and arrows show velocity. Solid contours mark 0.5; dashed contours mark 0.01. The overview is above the surface close-up. Right: shoreline positions and all water mass beyond the initial shoreline, including thin layers.'
        foundation='Ten foundation cases passed: Cartesian/curved-grid rest and translation, collision relaxation and viscous decay. Still water on the fitted bed and viscosity at the beach grid and timestep also passed.'
        period_status='passed' if periods_passed else 'have open criteria'
        falling_status='passed' if falling_passed else 'have open criteria'
        limitations=f'Standing-wave period tests {period_status}: discrepancies are {period_text}, with a 5% limit. Four falling-layer tests {falling_status}; the momentum and centroid-displacement limits are 2%. Air inertia, surface tension and bubble compression are not included.'
        metrics=[('Maximum relative water-mass drift',f'{mass_drift:.3e}'),
                 ('Retreat of fraction-0.5 shoreline',f'{m["shoreline_retreat"]:.5f}'),
                 ('Retreat of fraction-0.01 thin front',f'{m["thin_front_retreat"]:.5f}'),
                 ('Mass beyond initial shore: peak → final',f'{m["maximum_mass_above_shore"]:.6f} → {m["final_mass_above_shore"]:.6f}')]
        notes=review['en']; links='Equations and reproduction'; check_title='Numerical backwash checks'
        names={name:name.replace('_',' ') for name in beach['backwash']['criteria']}
        passed,failed='Passed','Open'
    table='<table style="width:100%;font-size:13px;text-align:left">'+''.join(f'<tr><th scope="row">{html.escape(k)}</th><td>{html.escape(v)}</td></tr>' for k,v in metrics)+'</table>'
    strong_block=''
    if strong is not None:
        strong_title=review['strong_title_'+lang]
        strong_block=(f'<h4>{html.escape(strong_title)}</h4>'
                      f'<div class="imgs"><video controls loop muted playsinline preload="none" width="1200" height="800" poster="{BASE}/results/strong.png" aria-label="{html.escape(strong_title)}"><source src="{BASE}/results/strong.mp4" type="video/mp4"><a href="{BASE}/results/strong.mp4">MP4</a></video></div>'
                      f'<p class="description">{html.escape(review["strong_"+lang])}</p>')
    checks='<ul>'+''.join(f'<li>{names[k]}: <b>{passed if v else failed}</b></li>' for k,v in beach['backwash']['criteria'].items())+'</ul>'
    source=html.escape((run.HERE/f'{run.NAME}.fme').read_text().rstrip(),quote=False)
    return f'''{BEGIN}
<article class="card featured" id="kinetic-free-surface">
<h3>{title}</h3>
<p class="description">{description}</p>
<p class="facts"><b>{status}</b> {html.escape(speed_note)}</p>
<div class="imgs"><video controls loop muted playsinline preload="none" width="1200" height="800" poster="{BASE}/results/beach.png" aria-label="{title}"><source src="{BASE}/results/beach.mp4" type="video/mp4"><a href="{BASE}/results/beach.mp4">MP4</a></video></div>
<p class="cap">{caption}</p>
<p class="description">{html.escape(notes)}</p>
{table}
<details><summary>{check_title}</summary>{checks}</details>
{strong_block}
<p class="description">{foundation}</p><p class="facts">{limitations}</p>
<p class="description"><a href="{BASE}/README.md">{links}</a> · <a href="{BASE}/results/verification.json">JSON</a> · <a href="{BASE}/results/surface-review.json">Surface review</a> · <a href="{BASE}/{run.NAME}.fme">Formurae</a><br><code>{r['grid'][0]}×{r['grid'][1]}</code>, H={p['level']}, A={p['amplitude']}, slope={p['bedSlope']}, t={r['final']['elapsed']:.1f}</p>
<details class="codebox" data-fme="{run.NAME}/{run.NAME}.fme"><summary>Formurae ({run.NAME}.fme)</summary><pre>{source}</pre></details>
</article>
{END}''',title


def main():
    report,beach,basic,review,strong=load()
    for lang in ['ja','en']:
        path=run.ROOT/'html'/lang/'waves.html'; text=path.read_text()
        article,title=card(lang,report,beach,basic,review,strong)
        for begin,end,content,anchor in [(BEGIN,END,article,'<article class="card featured" id="breaking-wave">'),
                (NB,NE,f'{NB}<p><a href="#kinetic-free-surface">{title}</a></p>{NE}','  <!-- kinetic-surface:nav:begin -->')]:
            if begin in text:
                text,count=re.subn(re.escape(begin)+'.*?'+re.escape(end),lambda _:content,text,flags=re.S)
                assert count==1
            else:
                assert text.count(anchor)==1, (lang,anchor)
                text=text.replace(anchor,content+'\n'+anchor,1)
        path.write_text(text)
        print(path)


if __name__=='__main__':
    main()
