# 回転速度によるテイラー・クエット流れの変化

二つの同心円筒の間にニュートン流体（せん断応力が変形速度に比例する流体）を置き，
内筒だけを回す三次元シミュレーションである．半径方向，円周方向，軸方向の変化をすべて計算する．
[鳥取大学の流れパターンの紹介](https://www.damp.tottori-u.ac.jp/~lab4/research.html)
にある，円周に沿うクエット流からテイラー渦，さらに円周方向に波打つ渦への変化を調べる．

[Formurae の方程式](taylor_couette3d.fme)を Egison，Formura を経て C に変換する．
[実行スクリプト](../../tools/taylor_couette.py)は境界値，時間積分，圧力計算を担当する．
流体の加速度の式を Python に書き直してはいない．この例は通常の Formura バックエンドを使い，
`formurae run` 用の実行宣言は含まない．
[描画スクリプト](../../tools/taylor_couette_render.py)は保存された速度だけを描く．

## 条件と回転速度

内半径 `Ri = 3d`，外半径 `Ro = 4d`，隙間幅 `d = Ro−Ri` とする．
軸方向の長さは `4d` で，上下を周期的につなぐ．端板はない．
円周方向は一周すべてを計算する．内外の壁で流体の速度を壁の速度に一致させる．

回転速度はレイノルズ数 `Re = Ω Ri d / ν = U d / ν` で表す．
これは慣性と粘性の相対的な強さを表す無次元数で，`Ω` は内筒の角速度，
`U = Ω Ri` は内壁速度，`ν` は動粘度である．形状と `ν` を固定すると，`Re` は回転速度に比例する．
計算は各条件の `U` を速度の単位，`d/U` を時間の単位にしており，
無次元の内壁速度は 1，粘性係数は `1/Re` になる．
この係数の変更は，次元を持つ粘性を固定して回転速度を変える実験を表す．

## 今回の計算結果

`24 × 64 × 48` 点，終了時刻 `tU/d = 300` の結果である．
速度の数値は内壁速度 `U` を単位とする．
RMS（二乗平均平方根）は速度変動の大きさを表す．
「渦の速度」は半径・軸方向の速度，「円周方向の変動」は円周平均からのずれを測る．

| Re | 回転速度の比 | 観察した流れ | 渦の速度の RMS | 円周方向の変動の RMS |
|---:|---:|---|---:|---:|
| 60 | 1 | 初期の渦が減衰し，円周に沿う流れへ戻る | `< 10⁻¹²` | `< 10⁻¹²` |
| 150 | 2.5 | ほぼ輪状のテイラー渦 | 0.07497 | 0.00410 |
| 600 | 10 | 円周方向に二つの波を持ち，回転して移動する渦 | 0.10978 | 0.04781 |

[比較動画](../../gallery/taylor-couette/comparison.mp4)，
[比較図](../../gallery/taylor-couette/comparison.png)，
[円筒面を一周分ひらいた図](../../gallery/taylor-couette/azimuthal-patterns.png)で確認できる．
円周に沿う流れでも円周方向の速度はゼロではない．色と縦断面の矢印は半径・軸方向の運動を示す．

Re = 150 に残る微小な波は減衰中であり，完全な定常状態に到達したという判定ではない．
Re = 600 の波は成長中で，主要な波の角速度は内筒の約 0.234 倍である．
全保存時刻における離散的な速度の発散の最大値は `3.8 × 10⁻¹²` 未満だった．
Re = 60 の円周速度は解析解と最大 `1.1 × 10⁻⁴` の差で一致した．
追加の `32 × 64 × 64` 点の計算でも，円周に二つの波が成長して移動した．
比較用の格子との差は，波の角速度で約 0.55%，`tU/d=225〜300` の渦速度の平均で約 0.0042% だった．
一方，同じ時間区間での円周方向の変動の平均には約 42% の差が残った（細かい格子の値を基準とする）．
波の発生と移動を確認できる一方，成長中の波の振幅には格子による差が残る．
振幅や遷移速度の精密測定，乱流の判定は，この比較の検証結果には含めない．

## 実寸への換算と初期値

実寸への換算例として `Ri = 3 cm, Ro = 4 cm, ν = 10⁻⁶ m²/s` を選ぶと，
`Ω = Re/300 rad/s`，回転数は `Re/(10π) rpm` である．
`Re=60` では約 1.91 rpm，`Re=150` では約 4.77 rpm，`Re=600` では約 19.1 rpm となる．
これは換算用の設定例であり，リンク先の実験装置の寸法を推定したものではない．

初期値は解析的なクエット流 `vθ/U = (48/R−3R)/7` に小さな速度変動を加える．
`R=r/d` である．速度変動は流れ関数（微分によって体積を保つ速度を作る関数）から計算し，
軸方向の二つの波長と円周方向の波数 1〜4 を含む．各円周成分の軸方向位相（波の位置）を変え，
上下反転の対称性によって波打つ変形を排除しない初期値にする．回転速度ごとに同じ初期変動を使う．
波打ちの形やその発生時刻は描画側で与えない．

## 方程式と離散化

流体の運動と体積の保存を表す非圧縮 Navier–Stokes 方程式

```
∂t v + (v·∇)v = −∇p + ν ∇²v
∇·v = 0
```

を円筒座標の物理成分 `u=vr, v=vθ, w=vz` で解く．`p` は密度で割った圧力である．
Formurae の式には遠心力 `v²/r`，円周方向の慣性項 `−uv/r`，
ベクトルの粘性項に現れる `−u/r²−2∂θv/r²` と `−v/r²+2∂θu/r²` を含む．

圧力をセル中央，速度成分をそれぞれの方向のセル面に置くスタガード格子を使う．
`.fme` の `arp` などは隣り合う二点の平均を表す利用者定義の関数であり，
成分間の位置の違いを調整する．一階・二階中心差分の組合せによって平均を記述するため，
コンパイラ固有のセル移動命令を追加していない．

空間微分は二次精度の中心差分，時間積分は各刻みで傾きを二回評価する二次精度の Runge–Kutta 法である．
各段階の加速度から圧力勾配を除き，離散的な速度の発散（各セルの流出量から流入量を引いた値）をゼロにする．
圧力の行列は，この発散と圧力勾配の差分を合成して構成する．
円周・軸方向の高速 Fourier 変換（周期的な場を波数別の成分へ分ける変換）と，
半径方向の三重対角行列（主対角とその両隣だけが非ゼロとなる行列）の求解を組み合わせる．
定数の圧力は任意なので，定数 Fourier 成分の一点を固定する．

壁の外の補助セルでは壁速度について速度を反射する．半径方向速度は両壁でゼロである．
全保存時刻で有限性，速度の発散，Courant 数（時間刻みの間に流体が進む距離と格子幅の比）を検査し，
条件を満たさなければ実行を失敗させる．

## 再実行

リポジトリの Formurae / Egison / Formura のビルド環境と C コンパイラが必要である．
Haskell 系のビルド・コンパイルをほかの実行と重ねず，以下を順番に実行する．

```sh
python3 -m venv .build/taylor-couette-venv
.build/taylor-couette-venv/bin/pip install -r examples/taylor_couette/requirements.txt
.build/taylor-couette-venv/bin/python tools/taylor_couette.py validate
.build/taylor-couette-venv/bin/python tools/taylor_couette.py simulate --reynolds 60 --name re60
.build/taylor-couette-venv/bin/python tools/taylor_couette.py simulate --reynolds 150 --name re150
.build/taylor-couette-venv/bin/python tools/taylor_couette.py simulate --reynolds 600 --name re600
.build/taylor-couette-venv/bin/python tools/taylor_couette_analyze.py
.build/taylor-couette-venv/bin/python tools/taylor_couette_render.py re60 re150 re600
```

格子による差の追加確認には，以下の二条件を実行してから解析を再実行する．

```sh
.build/taylor-couette-venv/bin/python tools/taylor_couette.py simulate --nr 16 --nt 64 --nz 32 --reynolds 600 --name pilot600
.build/taylor-couette-venv/bin/python tools/taylor_couette.py simulate --nr 32 --nt 64 --nz 64 --reynolds 600 --name refined600
.build/taylor-couette-venv/bin/python tools/taylor_couette_analyze.py
```

`--nr, --nt, --nz` は半径・円周・軸方向の分割数，`--time` は終了時刻，`--dt` は時間刻みの上限である．
既定値は `24 × 64 × 48` 点，終了時刻 `300 d/U`，時間刻みの上限 `0.02 d/U` である．
粘性による安定条件から必要な場合は時間刻みを自動的に小さくする．
一括実行には `make taylor-couette TENSOR_PYTHON=.build/taylor-couette-venv/bin/python` を使う．
`--amplitude` で初期変動を変更できる．`--restart .build/taylor-couette/NAME/restart.npz` は
同じ格子の保存状態から再開する．回転速度を段階的に変える場合にも使用できる．
`--name` を変えると出力先を分けて比較できる．

保存した全速度と再開用状態は `.build/taylor-couette/`，
数値とソースの SHA-256 は [results/](results/)，動画と図は
[`gallery/taylor-couette/`](../../gallery/taylor-couette/) に置く．

## 検証と読み方

`validate` は三方向に変化する既知の滑らかな速度場について，生成された加速度を連続方程式の値と比較する．
格子を細かくしたときの二次収束，ランダムな速度場を圧力補正した後の発散，
時間刻みを細かくしたときの二次収束を検査する．
結果は [検証記録](results/taylor-couette-validation.json) に保存する．
初期変動の発散がゼロで，上下反転の対称性が破れていることも検査する．
`taylor_couette_analyze.py` は保存結果から減衰・渦の成長・円周方向の波の移動を測定し，
[比較結果](results/taylor-couette-comparison.json) を作る．
波の移動は，円周方向の Fourier 成分（波数ごとに分けた周期的な成分）の位相の時間変化から測る．

動画の色は半径方向の速度を内壁速度で割った値であり，全条件で同じ色尺度を使う．
赤は外向き，青は内向きである．半径中央の円筒面と，一定の角度で切った縦断面を示す．
縦断面の矢印は半径・軸方向の流れである．円周方向に流れるだけなら両方ともほぼゼロになる．
テイラー渦では赤青の帯が軸方向に並び，波打つ渦ではその帯が円周方向にも変化する．
図の円筒面は模様を読み取るための投影表示である．

「渦の速度」は半径・軸方向の速度の二乗平均平方根（RMS），
「円周方向の変動」は円周平均からの全速度成分のずれの RMS である．
平均には円筒座標の体積を用いる．いずれも内壁速度を単位とする．
非対称性があるだけでは乱流とは判定しない．時間変化と格子依存性も確認する必要がある．

## 参考文献

- [鳥取大学：流れパターンの紹介](https://www.damp.tottori-u.ac.jp/~lab4/research.html)．
- [Jones, The transition to wavy Taylor vortices](https://www.cambridge.org/core/journals/journal-of-fluid-mechanics/article/transition-to-wavy-taylor-vortices/CFD8705D02E27F3E9AD38EE84B3D5866)．波打つ渦の発生と半径比・軸方向波長の関係．
- [Razzak et al., Numerical study on wide gap Taylor Couette flow with flow transition](https://arxiv.org/abs/1901.08931)．半径比 0.5 の三次元数値計算．本例とは形状が異なるため，遷移速度を直接の合否判定には使わない．
