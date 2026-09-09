# coding: utf-8
from pathlib import Path
import html,json
root=Path(__file__).resolve().parents[1]
assets='../../gallery/tensor/'
source='../../examples/tensor_demos/'
labels={'ja': {'title': '円筒・球面のテンソル方程式',
        'intro': 'まず，押す・ねじる・かき混ぜるという三つの操作と，手を離した後の動きをご覧ください．その後に方程式と検証の詳細を示します．各動画は生成 C '
                 'コードによる計算値から描画しています．球面は極を含む全球を計算し，座標間でベクトル・テンソルを変換しています．',
        'repro': '検証・計算・描画を',
        'repro2': 'で再実行できます．',
        'details': '方程式・設定・数値手法・再実行手順',
        'recoil': 'かき混ぜるのをやめると，液体が少し戻る',
        'recoil_body': '中央の円筒を回して液体を動かし，その円筒を止めます．青い点は液体と一緒に動く目印です．橙の点に注目すると，いったん進んでから少し逆回転するのがわかります．',
        'recoil_note': 'この液体は，変形から戻ろうとする弾性も持ちます．円筒が停止した後，蓄えられた弾性の力で液体が少し戻ります．目印の動きは計算した流速から求め，移動量は拡大していません．動画全体を同じ約 1/2 倍速で再生します．',
        'recoil_details': 'この流れの方程式・応力・検証結果を見る',
        'press-ball': '中空のボールを押して離す',
        'press-ball_body': '橙色の場所を内側へ押し，手を離します．へこみが戻り，振動が反対側にも伝わります．表面の線は材料と一緒に動きます．',
        'press-ball_note': '変形を全区間で 8 倍に拡大しています．球全体を計算し，中空が見えるように一部を切り除いて表示します．押している間だけ小さな領域の動きを指定し，離した後は全表面が自由に動きます．',
        'twist-tube': '管をねじって離す',
        'twist-tube_body': '下端を固定し，橙色の上端を回してから離します．縦の線がねじれ，手を離すと戻りながら振動します．',
        'twist-tube_note': '変形を全区間で 6 倍に拡大しています．下端は固定したままで，上端は t = 4 以降自由に動きます．側面・内面にも力を加えません．',
        'sources': 'Formurae ソース全文',
        'generated': '生成されたコード',
        'elastic': '異方性弾性体：円筒と球殻',
        'elastic_body': '左右は同じ初期速度を与えた材料です．左は等方的，右は半径方向を補強しています．色は速度の大きさ，変形は変位を 8 '
                        '倍で表示します．手前の半分を切り除き，外面・内面・切断面を不透明に描画しています．',
        'elastic_note': '円筒の軸方向は周期境界です．球殻は全球を計算しています．切断は表示のためだけで，計算領域や境界条件は変えません．',
        'couette': '粘弾性流体：回転する円筒間の流れ',
        'couette_body': 'Oldroyd-B モデルで，高分子の変形を表す対称テンソルと非圧縮流れを結合します．色は高分子応力の大きさ，白い矢印は流速です．内筒は t = '
                        '12 から減速し，t = 14 で停止します．右側で速度分布とエネルギーの緩和を追います．',
        'couette_note': '二次元の環状領域を計算します．風上輸送と正定値性を保つ分割時間積分を使い，速度を求める Poisson 方程式は Python/SciPy '
                        'で解きます．',
        'nematic': '球面の液晶：配向と欠陥の移動',
        'nematic_body': '分子の向きと配向の強さを，対称かつトレースゼロのテンソル Q '
                        'で表します．色は配向の強さ，短い線は向き，水色の点は向きが定まらない欠陥です．球の表裏を同時に示します．',
        'nematic_note': '球面上の受動的な配向緩和を計算しています．周囲の流体は結合していません．欠陥は計算した Q の向きの回転から検出し，その位置の変化を表示します．',
        'checks': '検証結果',
        'raw': '数値記録',
        'cylinder': '円筒',
        'sphere': '球殻'},
 'en': {'title': 'Tensor equations on cylinders and spheres',
        'intro': 'Start with three familiar actions: press, twist, and stir, then watch what happens after release. Equations and verification follow below. Every frame is rendered from a '
                 'generated C simulation. Spherical models cover the entire sphere, including the '
                 'poles, with vector and tensor transformations between overlapping coordinate '
                 'panels.',
        'repro': 'Run verification, simulation, and rendering with',
        'repro2': '.',
        'details': 'Equations, settings, numerical methods, and reproduction',
        'recoil': 'Stop stirring. The liquid briefly turns back.',
        'recoil_body': 'The central cylinder turns to set the liquid in motion, then stops. Blue dots are markers carried by the liquid. Follow the orange dot: it continues forward, then briefly turns back.',
        'recoil_note': 'This liquid also has elasticity: it tends to recover from deformation. After the cylinder stops, stored elastic stress pulls the liquid back. Marker paths are integrated from the computed velocity without magnifying displacement. The entire clip runs at approximately half speed.',
        'recoil_details': 'See the equations, stress, and verification for this flow',
        'press-ball': 'Press a hollow ball, then let go',
        'press-ball_body': 'Push the orange patch inward, then release it. The dent recovers and vibrations reach the opposite side. Surface lines move with the material.',
        'press-ball_note': 'Displacement is magnified eight times throughout. The whole ball is simulated; a cutaway reveals the hollow interior. Motion is prescribed on a small patch only while pressing; after release, every surface is free.',
        'twist-tube': 'Twist a tube, then let go',
        'twist-tube_body': 'Fix the bottom, turn the orange upper end, then release it. The vertical lines twist and swing back as the tube vibrates.',
        'twist-tube_note': 'Displacement is magnified six times throughout. The bottom stays fixed; the top moves freely after t = 4. Inner and outer sidewalls are also free of applied traction.',
        'sources': 'Complete Formurae source',
        'generated': 'Generated code',
        'elastic': 'Anisotropic elasticity: cylinder and hollow sphere',
        'elastic_body': 'Both materials start with the same velocity. The left material is '
                        'isotropic; the right has extra radial stiffness. Colour shows speed and '
                        'displacement is magnified eight times. The front half is cut away; outer, '
                        'inner, and cut surfaces are opaque.',
        'elastic_note': 'The cylinder is periodic along its axis. The spherical simulation covers '
                        'the whole shell. Cutting changes the rendering only, not the '
                        'computational domain or boundary conditions.',
        'couette': 'Viscoelastic flow between rotating cylinders',
        'couette_body': 'The Oldroyd-B model couples a symmetric polymer-conformation tensor to '
                        'incompressible flow. Colour shows polymer stress magnitude; white arrows '
                        'show velocity. The inner cylinder slows at t = 12 and stops at t = 14. '
                        'The plots track velocity and energy relaxation.',
        'couette_note': 'This is a two-dimensional annulus. The driver uses upwind transport and a '
                        'positivity-preserving split time step; Python/SciPy solves the Poisson '
                        'equation for velocity.',
        'nematic': 'Liquid crystal on a sphere: orientation and moving defects',
        'nematic_body': 'The symmetric, trace-free tensor Q describes molecular orientation and '
                        'alignment strength. Colour shows alignment, short lines show orientation, '
                        'and cyan points mark defects where orientation is undefined. Front and '
                        'back views are shown together.',
        'nematic_note': 'This is passive orientational relaxation on the sphere, without a coupled '
                        'surrounding fluid. Defects are detected from the winding of the computed '
                        'Q field; their motion is a simulation result.',
        'checks': 'Verification',
        'raw': 'Numerical records',
        'cylinder': 'Cylinder',
        'sphere': 'Hollow sphere'}}

def movie(name):
 records=json.loads((root/'gallery/tensor/render.json').read_text())
 paths={ext:f'{assets}{name}.{ext}?v={records[name][ext][:12]}' for ext in ['png','mp4','gif']}
 return f'<video controls autoplay loop muted playsinline preload="metadata" aria-label="{name}" poster="{paths["png"]}" style="display:block;width:100%;max-width:1100px;max-height:75vh;object-fit:contain;margin:auto"><source src="{paths["mp4"]}" type="video/mp4"><a href="{paths["gif"]}">GIF</a></video>'
def code(name,L):
 f=name+'.fme';body=html.escape((root/'examples/tensor_demos'/f).read_text())
 links=' · '.join(f'<a href="{source}{name}.{ext}">.{ext}</a>' for ext in ['fme','egi','feir','fmr'])
 return f'<details class="codebox" data-fme="tensor_demos/{f}"><summary>{L["sources"]}: {f}</summary><pre>{body}</pre></details><p style="font-size:12px">{L["generated"]}: {links}</p>'
def main():
    for lang,L in labels.items():
     page=root/f'html/{lang}/gallery.html';s=page.read_text()
     # Keep this region separate from the legacy full-source embed generator.
     begin='<!-- BEGIN TENSOR DEMOS -->';end='<!-- END TENSOR DEMOS -->'
     manual='README.md' if lang=='ja' else 'README.en.md'
     section=f'{begin}\n<section id="tensor-demos">\n<h2>{L["title"]}</h2>\n<p>{L["intro"]}</p>\n'
     section+='<div id="tensor-intro"><nav>'+' · '.join(f'<a href="#{case}-intro">{L[case]}</a>' for case in ['press-ball','twist-tube','recoil'])+'</nav>'
     for case in ['press-ball','twist-tube','recoil']:
      movie_name=('couette-recoil' if case=='recoil' else case)+'-'+lang
      section+=f'<article class="card" style="margin:20px 0" id="{case}-intro"><h3>{L[case]}</h3><p>{L[case+"_body"]}</p>{movie(movie_name)}<p class="cap">{L[case+"_note"]}</p>'
      if case=='recoil':section+=f'<p><a href="#tensor-couette">{L["recoil_details"]}</a></p>'
      else:
       section+=code(case.replace('-','_'),L)
       section+=f'<p><a href="{source}{manual}">{L["details"]}</a> · <a href="{source}results/{case}.json">{L["raw"]}</a> · <a href="{source}results/manipulation-validation.json">{L["checks"]}</a> · <a href="{source}results/manipulation-time-validation.json">'+('時間精度' if lang=='ja' else 'Time accuracy')+'</a></p>'
      section+='</article>\n'
     section+='</div>\n'
     section+=f'<p>{L["repro"]} <code>make tensor-demos</code>{L["repro2"]} <a href="{source}{manual}">{L["details"]}</a></p>\n'
     section+='<nav>'+' · '.join(f'<a href="#tensor-{n}">{L[n]}</a>' for n in ['elastic','couette','nematic'])+'</nav>'
     section+='<p>'+('式の g は座標の長さ・角度を表す計量，∇ は基底の変化も含む微分です．' if lang=='ja' else 'In the equations, g is the metric describing lengths and angles; ∇ includes spatial changes of the coordinate basis.')+'</p>'
     for name,sources,movies,equation in [
     ('elastic',['anisotropic_cylinder','anisotropic_sphere'],['elastic-cylinder','elastic-sphere'],'ρ ∂ₜvⁱ = ∇ⱼσⁱʲ<br>∂ₜσⁱʲ = λ gⁱʲ tr(e) + 2μ eⁱʲ + α nⁱnʲnᵏnˡeₖₗ'),
     ('couette',['oldroyd_couette'],['couette'],'∇ᵢvⁱ = 0 &nbsp; · &nbsp; ρ Dₜvⁱ = −∇ⁱp + ∇ⱼ(2ηₛeⁱʲ + τⁱʲ)<br>DₜCⁱʲ − Cᵏʲ∇ₖvⁱ − Cⁱᵏ∇ₖvʲ = −(Cⁱʲ − gⁱʲ)/λᵣ'),
     ('nematic',['nematic_sphere'],['nematic'],'∂ₜQⁱʲ = P₀[L ∇ᵏ∇ₖQⁱʲ + (A − B QₖₗQᵏˡ)Qⁱʲ]')]:
      section+=f'<article class="card" style="margin:20px 0" id="tensor-{name}"><h3>{L[name]}</h3><div class="math">{equation}</div><p>{L[name+"_body"]}</p>'
      for m in movies:
       if name=='elastic':section+=f'<h4>{L["cylinder" if m.endswith("cylinder") else "sphere"]}</h4>'
       section+=movie(m)
      section+=f'<p class="cap">{L[name+"_note"]}</p>'
      for src in sources:section+=code(src,L)
      section+=f'<div class="facts" data-tensor-check="{name}"><b>{L["checks"]}</b>: '
      if name=='elastic':
       section+=('独立な成分実装との差 ≤ 3.6×10⁻¹⁵．格子細分化で約 2 次収束．動画のエネルギー変動は円筒 0.0005% 以内，球殻 0.17% 以内．' if lang=='ja' else 'Independent component residual ≤ 3.6×10⁻¹⁵; approximately second-order spatial convergence. Energy variation is below 0.0005% for the cylinder and 0.17% for the sphere in these runs.')
      elif name=='nematic':
       section+=('テンソル固有モードに対して約 2 次収束．全保存時刻でトレース誤差 < 10⁻⁹，欠陥の指数の総和 +2．' if lang=='ja' else 'Approximately second-order convergence on an analytic tensor eigenmode. Trace residual < 10⁻⁹ and total defect charge +2 at every saved frame.')
      else:
       r=json.loads((root/'examples/tensor_demos/results/couette.json').read_text())
       minimum=min(f['min_conformation_eigenvalue'] for f in r['frames'])
       divergence=max(f['divergence_max'] for f in r['frames'])
       section+=(f'定常解析解で約 2 次の空間収束，分割積分は 1 次の時間収束．全保存時刻で正定値性を維持（最小固有値の最小値は約 {minimum:.3f}）．速度の発散の最大値は約 {divergence:.2e}．' if lang=='ja' else f'Approximately second-order spatial convergence for exact steady flow; first-order time convergence for the split integrator. Positive definiteness at every saved frame; smallest eigenvalue ≈ {minimum:.3f}, maximum velocity divergence ≈ {divergence:.2e}.')
      records=['elastic-validation','elastic-cylinder','elastic-sphere'] if name=='elastic' else [name+'-validation',name]
      section+=f' {L["raw"]}: '+', '.join(f'<a href="{source}results/{r}.json">{r}</a>' for r in records)+'</div></article>\n'
     section+='</section>\n'+end
     if begin in s:s=s[:s.index(begin)]+section+s[s.index(end)+len(end):]
     else:s=s.replace('<main>','<main>\n'+section,1)
     if lang=='ja':
      s=s.replace('検証済み応用26例','検証済み応用29例').replace('検証済み応用 26 例','検証済み応用 29 例')
      s=s.replace('すべて<code>make all</code>で再現でき','従来の例は<code>make all</code>，下記のテンソルデモは<code>make tensor-demos</code>で再現でき')
     else:
      s=s.replace('26 Verified Applications','29 Verified Applications').replace('26 verified applications','29 verified applications')
      s=s.replace('Everything is reproducible with <code>make all</code>','The existing examples use <code>make all</code>; the tensor demos below use <code>make tensor-demos</code>')
     s=s.replace("document.querySelectorAll('.imgs video')","document.querySelectorAll('.imgs video, #tensor-demos video')")
     s=s.replace('すべての数値は <code>make all</code> の検証ドライバが exit code で保証。','数値は <code>make all</code> または <code>make tensor-demos</code> の検証ドライバーで確認。')
     s=s.replace('Every number is guaranteed by the <code>make all</code> verification drivers via exit codes.','Numerical checks use the <code>make all</code> or <code>make tensor-demos</code> verification drivers.')
     page.write_text(s)

if __name__=='__main__':main()
