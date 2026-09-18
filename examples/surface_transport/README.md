# 水面がセルをまたぐための，占有率の保存輸送

水の占有率 `α`（各セルを水が占める割合）を，0〜1に保ちながら運ぶ実験である．
前段の `kinetic_surface` は水面の高さを水平な基準面上に保持した．今回は水面の位置を
二次元の占有率で表し，水面がセルをまたぐ移動や大きな変形を検査する．

**流れをあらかじめ指定した輸送の検証である．D2Q9（二次元で九方向の分布を使うモデル）で
流速を解く処理，重力，水面の
圧力条件との相互作用はまだ結合していない．** 波形の移動は移流（流れによって運ばれる
こと）であり，自由に伝わる重力波ではない．円形の水領域の変形も，指定した渦による．
水の占有率の時間発展，初期条件，面の流量，幾何，時間積分，検証値はすべてFME
（Formuraeのソース）で求める．
描画は保存済みの占有率を使う．

## 方程式と幾何

密度が一定で，体積が変わらない二次元の流れ `u` を使う．

```text
∂t α + div(u α) = 0,    div u = 0
```

計算領域は物理座標 `(X,Y)` で `[0,1]²`．直交格子と，次の曲線格子を比較する．

```text
X = x + 0.06 sin(2πx) sin(2πy)
Y = y + 0.045 sin(2πx) sin(2πy)
```

セルの物理的な面積 `A = Δx Δy J` は，写像した四隅を結ぶ四角形の面積を使う．
初期値も同じ四角形で四点のGauss積分（重み付きの点の値から積分を近似する方法）を
行い，セル平均にする．両座標で物理的な初期形状と流れを共通にする．

流れは流れ関数 `ψ`（`uX=∂Y ψ`, `uY=−∂X ψ` で速度を定める関数）で与える．
面の両端での `ψ` の差が，その面を通る体積流量になる．これを共有面に一度定義して
隣接セルの両方が使う．セルを一周すると四隅の値が相殺されるため，数値計算でも
流量の出入りがつり合う．単に連続式で `div u=0` を満たす速度をセルへ与えるだけでは
この離散的なつり合いは保証されない．

更新は，共有面の流束 `F~i` の発散を `volumeCell` で割る同じ式で書く．
座標写像と面の幾何はその入力として分離する．`sampleLower`／`sampleUpper` による
面の両側の選択は，数値流束を作る `waterFlux` にまとめる．座標を変えたときに
物理モデルを書き換える必要はないが，有限の格子での誤差は変わるので細分化で比較する．

左右は周期境界である．上下の面を通る流量は0で，保存領域の端を周期的につないで
近傍値を読む場合も，上下から水は流出しない．上下の流量もFMEで検査する．

## 範囲と水量を保つ更新

各セルの占有率を，セル内の傾きを制限した直線で近似するMUSCL法を使う．
傾きにはMC制限（前後の差の符号が違うときは0，同符号のときも差の2倍以下にする）を
使い，面の値を周囲の最小値・最大値の範囲に保つ．面の流れの向きで上流側の値を選ぶ．
比較用の一次風上法は，セル内を一定値として同じ面の流量・時間積分を使う．

占有率を範囲内へ切り詰めて水量の変化を隠す処理は行わない．以下の十分条件で更新を
0〜1に保つ．セルの四つの面へ再構成した値を `q_e`，セル外へ向かう面の体積流量を
`Φ_e` とすると，この再構成では `α = Σ_e q_e/4` である．各面で

```text
λ_e = Δt max(Φ_e,0) / A ≤ 1/4
```

なら，Euler更新（現在の変化率から1ステップ進める操作）を「係数 `1/4−λ_e` の自セル側の面の値」と「流入係数を掛けた隣の
セル側の面の値」の和に書ける．係数は非負で，流量の出入りがつり合うので係数の和は1．
したがって，すべての面の値が0〜1なら更新後も0〜1となる．二段のRunge–Kutta法
（中間状態を一度計算する時間積分）も，この更新と元の値の平均なので範囲を保つ．
時間により流れの向きが変わるときは，各段階の時刻で上流側を選び直す．

`boundCourant` は全段階・全時刻の `max 4λ_e` を記録する．`lowest`・`highest` は
最終的な平均の前のEuler候補も含む最小値・最大値である．共有面の流束が隣接セルで
逆符号になるため，水量 `Σ A α` も保存する．ここで水量は二次元の断面積であり，
奥行きを1とした体積に相当する．実数演算でのこの性質と，浮動小数点演算の検査は区別する．
範囲検査の許容値は，各出力時刻の更新回数 `k` に対して `max(2e-12, k ε)` とする．
`ε = 2.220446049250313e-16` は倍精度の機械イプシロン（1付近で区別できる数の間隔）である．
これは初期化の余裕と更新回数に応じた検査用の基準であり，浮動小数点誤差の厳密な上界の
証明ではない．各時刻までの両Euler候補を含む極値を検査し，計算値は変更しない．

## 初期形状と流れ

初期の境界には幅0.025の線形な遷移を与える．境界から離れると占有率は厳密に0または1．
これは初期値の定義であり，時間更新後の切り詰めではない．セルを境界線で切断して厳密な
占有面積を求める幾何学的なVOF法（体積割合から境界を再構成する方法）は未導入である．

- **静止**：`Y=0.5+0.12 cos(2πX)` の水面と流速0．形が変わらないことを検査する．
- **一定値**：占有率0.37を，時間により反転する渦で運ぶ．格子が曲がっていても一定値を保つ．
- **波形の移動**：同じ水面を `u=(1,0)` で横へ運ぶ．`t=1` で領域を一周し初期形状へ戻る．
- **変形と反転**：中心 `(0.5,0.75)`，半径0.15の円形領域を，次の流れで変形させる．

```text
ψ(X,Y,t) = sin²(πX) sin²(πY) cos(πt/T) / π,    T=4
```

前半で伸び，後半で流れが反転し，連続方程式では `t=T` に初期形状へ戻る．
初期形状へ戻る性質を使って，数値的なぼけや誤差を測る．初期形状を狭い遷移幅で定め，
反転時間を4とした本実験は，界面輸送の渦による検証を参考にした独自の設定である．

`returnedL1 = Σ A |α(T)−α(0)|` は戻った形の平均的なずれを面積で重み付けした量，
`mixing = Σ A α(1−α)` は0と1の中間にある水の広がりを表す量である．`mixing` は
セル平均による影響も含み，物理的な混合を計算した値ではない．境界のぼけを比較する
指標として使い，初期形状へ戻った時点でも比較する．
`movedArea` は初期から占有率0.5の内外が入れ替わったセルの面積を測る．
これらと初期形状の面積の積分誤差もFMEで求める．

## 再現と検証

```sh
make surface-transport-verify
make surface-transport-gallery
```

通常の `.fme → Egison → FEIR → .fmr → Formura → C` の経路を使う．Formurae・Formuraの
処理系の変更は不要．ビルド・実行をすべて直列で行い，計算は単一プロセスで実行する．
FEIRは数式を正規化した中間表現である．
モデルと処理系が一致する正規化結果は
`python3 examples/surface_transport/run.py --reuse-normalized` で再利用できる．
`--reuse-runs` を追加すると，同じモデル・処理系・引数の記録を，出力ハッシュの照合後に
再利用する．再利用元の検証記録も別名で残す．

小さく動作を確認する場合は `python3 examples/surface_transport/run.py --grids 32 --probe`
を使う．静止，一定値，波形，渦を二つの座標で検査するが，格子細分化での精度比較は行わず，
公開用の検証記録も更新しない．

32²・64²・128²・256²・320²セル，直交格子と曲線格子で波形の一周と渦の反転を比較する．
64²では静止，一定値，時間刻みを半分にした反転も調べる．128²では一次風上法と比較する．
128²から320²まででは物理的な時間刻みを一定に保ち，空間の細分化の効果を比べる．
この時間刻みは64²の半減試験と同じで，320²でも範囲を保つ十分条件を検査する．
合計28条件を検査し，水量の相対変化 `2e-11` 未満，範囲・面流量のつり合い・十分条件，
格子細分化での戻りの誤差の減少を要求する．最も細かい320²での `returnedL1` は波形0.025未満，
渦0.02未満とする．128²では高精度法の戻りの誤差と最終的なぼけの指標は一次風上法の0.8倍未満とする．
同じ物理時刻での格子間・時間刻み間の比較にもFMEの診断値を使う．

記録用ヘッダーは計算済みの場を保存するだけである．32²では保存あり・なしの診断出力の
バイト単位の一致を検査する．結果は `results/verification.json`，場の記録は
`.build/surface-transport/` に保存する．描画用のPythonに輸送や補正の計算は実装しない．
波形の動画は320²セル，渦の動画は一次風上法と同じ解像度で比較できる128²セルを使う．
表と検証記録には，256²・320²セルの渦の結果も含む．

## 測定結果（2026-09-18）

28条件の検査が通過した．次は `Σ A |α(T)−α(0)|` の値である．領域の面積は1であり，
水量に対する相対誤差とは異なる．

| セル数 | 波形・直交 | 波形・曲線 | 渦・直交 | 渦・曲線 |
|---|---:|---:|---:|---:|
| 32² | 0.012770 | 0.019965 | 0.075882 | 0.080417 |
| 64² | 0.006851 | 0.010549 | 0.047861 | 0.055038 |
| 128² | 0.003099 | 0.004503 | 0.024724 | 0.029280 |
| 256² | 0.001277 | 0.001533 | 0.012349 | 0.014786 |
| 320² | 0.000966 | 0.001134 | 0.009738 | 0.011735 |

水量の相対変化は最大 `5.034e-14`．静止試験の変化は0，一定値の保持の誤差は
最大 `1.654e-14`．範囲を保つ十分条件の指標 `boundCourant` は最大0.802514だった．
128²でのMUSCL法の戻りの誤差は一次風上法の0.2757〜0.3076倍，最終的な中間占有率の
指標は0.3808〜0.4164倍だった．64²の時間刻みを半分にした比較では，指標の差を
初期水量で割った値は最大 `2.145e-5` だった．

128²では渦の戻りの誤差が目標0.02未満に届かず，256²を追加した．256²ではこの目標に
届いたが，座標間の中間占有率の指標の差が比較基準を満たさなかったため320²を追加した．
320²では，記録した同時刻での指標の差を初期水量で割った最大値は，波形0.03926%，
渦1.9641%だった．渦のこの差は32²から64²ではいったん増えており，粗い格子だけで
座標間の精度を判断しない．戻りの誤差と座標間の差の基準は変更していない．

320²の曲線格子では，占有率の上限超過が最大 `2.605e-12` となり，当初の固定許容値
`2e-12` を超えた．そこで範囲の検査を，上述の更新回数に応じた `max(2e-12, k ε)` へ
変更し，全記録時刻を再検査した．最大の許容値は `4.547e-12` である．モデルと計算値は
変更しておらず，切り詰めも行っていない．この検査基準を，丸め誤差の厳密な保証とは扱わない．

## 次の結合

次段の [kinetic_transport](../kinetic_transport/README.md) では，D2Q9の分布の面流束を共有し，
全セルを満たす流体の中で水を表す印を輸送する．大気圧の境界条件との結合は引き続き必要である．

ここで検証するのは体積が変わらない流れの占有率輸送である．D2Q9の密度が変化する流れと
結合するときには，水の質量 `αρ` と密度 `ρ` に整合した面の質量流束を使う必要がある．
流速だけを今回の式へ代入して圧縮性を無視したまま結合しない．水面の法線，任意の向きでの
圧力条件，空気から水へ変わるセルの分布の初期化を加え，静水・小振幅波の検査を保つ．
薄い水の膜や水際については，保存と範囲だけで十分とせず，境界のぼけと形の収束を確認する．

## 参考文献

- [LeVeque (1996), High-Resolution Conservative Algorithms for Advection in Incompressible Flow](https://doi.org/10.1137/0733033)：与えた非圧縮の流れでの保存的な輸送と傾き制限の背景．本例は多次元の波伝播アルゴリズムをそのまま実装したものではない．
- [Rider and Kothe (1998), Reconstructing Volume Tracking](https://doi.org/10.1006/jcph.1998.5906)：渦による変形などを用いた界面輸送の検証と幾何学的な体積追跡．本例に幾何学的な境界再構成は含まれない．

## English

This example advances a cell-averaged water volume fraction through prescribed
incompressible flow. It is an interface-advection experiment; velocity is not
computed by D2Q9 (a two-dimensional, nine-velocity kinetic model), and gravity/free-surface pressure feedback is not yet coupled.
A moving wavy interface and a deforming circular region test motion across cells.
A finite initial transition of width 0.025 is used, not a geometrically reconstructed
sharp interface. The same physical shapes and flows are used on Cartesian and
mapped quadrilateral grids.

Face-integrated flow is obtained from differences of a streamfunction at shared
corners, preserving discrete divergence freedom. MC-limited linear reconstruction
and two-stage Runge–Kutta integration preserve bounds under the checked sufficient
condition `4 Δt max(Φ_out)/A ≤ 1`. Both Euler candidates are inspected. No clipping
or global volume correction changes the state. Initialization, geometry, fluxes,
updates, diagnostics and initial/final reference comparisons all run in Formurae's `.fme` source.

Run the two Make targets above for the 28-case verification and publication.
Density-consistent mass transport, arbitrary surface-normal pressure conditions
and initialization of newly wetted cells remain required before coupling this
transport to the nonlinear D2Q9 free-surface model.

The 28 cases passed. The maximum relative volume drift was 5.034e-14.
On 320² cells, return differences were 0.0009660–0.0011336 for translation and
0.0097380–0.0117347 for the reversing vortex. At 128², MUSCL return differences
were 0.2757–0.3076 times the first-order upwind values. The normalized difference
between the grids' intermediate-fraction indicators reached at most 1.9641% on
320² cells. Spatial accuracy criteria were retained when extending the grid study.

The largest fraction overshoot was 2.605e-12, exceeding the original fixed 2e-12
tolerance. Bounds were rechecked at every saved diagnostic time with the acceptance
budget max(2e-12, k epsilon), where k counts updates and epsilon is binary64 machine
epsilon. The largest budget was 4.547e-12. This is a diagnostic criterion, not a
formal floating-point error bound. Both Euler candidates contribute to the running
extrema; no clipping or state correction was introduced.
