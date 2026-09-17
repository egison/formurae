# Formurae

Formurae は、Egison のテンソル添字記法で書いた偏微分方程式を
[Formura](https://github.com/formura/formura) の stencil programへ変換し、
MPI・temporal blocking付きC codeを生成するための実験的な言語処理系です。

例題・デモ・ベンチマークは、Formura 本体を拡張せず、既存の機能と通常のコード生成経路で
実装できるシミュレーションを対象にします（例外として、境界のある領域での時間方向の
ブロッキングと MPI 分割は 2026-09-12 にユーザー指示で fork に実装しました）。近傍格子点を参照する局所更新を中心に、
初期条件・境界処理・補助計算も含めて実装可能性を確認します。
開発時の詳細は [AGENTS.md](AGENTS.md) に従います。

表層言語の拡張子は `.fme` です。数式の意味と離散化を分離し、次の4段で処理します。

```text
model.fme
  └─ formurae-pre ──> model.egi
                    └─ Egison ──> model.feir
                                      └─ formurae-post ──> model.fmr
                                                         └─ Formura ──> C
```

- `formurae-pre` は構文、scope、宣言、source mapを検査し、Egison normalization unitを生成します。
- Egison はuser definition、tensor/index algebra、analytic differentiationを評価し、canonical FEIRを出力します。
- `formurae-post` はplacement、stencil、補助field、storageを決め、Formura programを生成します。
- Formura は配列、loop、MPI通信、temporal blockingを含むC codeを生成します。

純粋な数学演算子はEgisonにだけ定義されます。`grad`、`divg`、`curl`、`hessian`、`lap`、
`d`、`hodge`、`δ`、`Δ_H`の解析的な部分は、callbackやcomponent loopを含まない短いEgison関数です。
具体的な差分係数や格子offsetをEgisonの演算子定義へ混ぜません。

user tensor operatorも同じ経路です。例えば次の`withSymbols`を出た自由な下添字は、Egisonでは
添字を省略したtensor軸になります。省略軸には既存の明示添字とは異なるfreshな下添字が補われ、
formurae-preは関数名や本体からresult varianceのsignatureを推論・付与しません。EgisonがRHSを評価した後、
宣言済みのequation targetまたはindexed `local`へ値を格納する時点で、targetが要求するshape、logical
variance、`dfOrder`と実際の値を照合します。degree-zero covariant tensor targetへ代入する場合に限り、
構造的index completionがcompatibleなanonymous down軸をtargetの下添字へ対応付けます。anonymous down軸を
up targetとして読み替えることはできず、form targetでは`dfOrder`を保持します。

```formurae
def gradLike u = withSymbols [i] (∂_i u)
field q_i
step:
  q' = gradLike u
```

したがって、`E_i + gradLike u`のanonymous軸が既存の`i`へ暗黙に統合されることはありません。
この式では両者は別の軸です。同じ軸で合成する意図は、
`withSymbols [i] (E_i + (gradLike u)..._i)`のようにcall siteで下添字を明示できます。
Egisonと同じ`(gradLike u)_i`という綴りも同じ意味で使えます。括弧でくくった式の直後に
添字をつける書き方はinit・step・defのどこでも構造化された式として解析され、
`(gradLike u)_i . Q~i~j`のように`.`による縮約とも組み合わせられます。
引数なしで定義したテンソル値にも，`christoffel~i_1_l`のように数値添字を使って
成分を取り出せます。

`def` は引数を省略すると値を定義します。先に定義した値を名前だけで参照でき，
使わない仮引数や呼び出し時の `0` は不要です。例えば，座標 `x, y` とパラメータ `cx, cy` に対して，
次のように書けます。

```formurae
def u = `(x - cx)
def v = `(y - cy)
def rr = sqrt (u^2 + v^2)
```

スカラーだけでなくテンソルや関数も値として定義できます。引数を持つ定義と同様に，
自分自身や後に現れる定義への参照はエラーになります。バッククォートは，くくった式を
記号計算中に展開せずひとまとまりとして扱う指示です。

pure user operatorの本体は1行に限定されません。`=`の次をindentすると、Egisonの`let`、lambda、
`match`、`withSymbols`、`generateTensor`を含む式blockをそのままnormalizationへ渡せます。
1行の本体とこのようなrich bodyは、どちらもEgisonが通常の式として評価します。Formuraeはuser
definitionの式構造や計算履歴を検査してresult signatureを付けません。評価結果がfield equation
またはindexed `local`へ格納されるときだけ、上記のtarget metadata照合を行います。

```formurae
def chooseByDimension X =
  let apply := \f x -> f x
      choose := match dimension = 3 as bool with
        | #True -> \Y -> 2 * Y
        | #False -> \Y -> Y
   in apply choose X
```

`generateTensor` は `def` の本体で使えます。例えば、9成分の平衡分布を
1つの式から作り、初期化で利用できます（`weights`・`cx`・`cy` は重みと移動方向の表です）。

```formurae
def equilibriumPopulations r u v =
  generateTensor (\[q] -> equilibrium weights_q cx_q cy_q r u v) [9]

init:
  f_a := (equilibriumPopulations initialDensity initialU 0)_a
```

`q` は1〜9の整数で、`_a` は生成した9成分に付ける添字記号です。
生成はEgisonでの正規化時に行われ、実行時のテンソル生成処理は増えません。
完全な使用例は [二次元の波](examples/breaking_wave/breaking_wave.fme) にあります。

`dimension`、`coordinates`、`volume`、`epsilon`、`metric`、`inverseMetric`はmodelのambient
Egison環境にあり、ユーザ定義と`Formurae.*`標準演算子はこれらを直接参照します。
そのためユーザがcontext引数を渡す必要はありません。`metric g`を宣言すると、同じ実計量を
共変な`g_i_j`（whole viewは`g_#_#`）と反変な`g~i~j`から参照できます。宣言名を使わない
canonical viewは`metric_i_j` / `metric_#_#`と`inverseMetric~i~j`です。反変なviewは、次のように
varianceが見えるindexed equation/localで直接使います。

```formurae
metric scale [1, 1 + x]
metric g

field A_i
field X~i

step:
  X'~i = withSymbols [j] (g~i~j . A_j)
  A'_i = withSymbols [j] (g_i_j . X~j)
```

この明示的な計量縮約を正準な書き方とし、`flat` / `sharp`はFormuraeのpublic operatorとして
提供しません。関数headへ結果添字を書く構文もありません。

ambient名と`metric g`の宣言名はfield、parameter、user definition、definition parameter、
step-level `let` / `local`では予約されます。Egison expression block内の局所`let`やlambdaだけは
通常のlexical scopeに従います。

## 空間次元と独立した成分数

`index a, b : 9` は，添字記号 `a` と `b` の範囲をそれぞれ **1〜9** と宣言します。
`dimension` と `axes` は引き続き計算領域の空間次元と座標を指定します。
`index` は場と関数の宣言より前に書きます。

```formurae
dimension 2
axes x, y
index a, b : 9

field f_a             -- 9成分
field u~i             -- 空間方向の2成分
field c_a~i           -- 9×2成分
field M_a_b           -- 9×9成分
```

場の各軸のサイズは宣言時の添字で決まります。宣言していない `i`，`j` などは，
従来どおり `dimension` 個の空間方向を表します。同じサイズを宣言した記号への
付け替え（`f_a` → `f_b`）は可能ですが，`f_i` として2成分に読み替えることはできません。
数値添字 `f_9` は第9成分を取り出します。

`static field`，添字を明示した `local` / `let`，関数の添字付き引数でも同じ指定を使えます。
例えば，9成分の場を各成分で拡散させる更新は次のように書けます。

```formurae
def diffuse X_b = X_b + dt * (∂^2_x X_b + ∂^2_y X_b)
step:
  local next_a = diffuse f
  f'_b = next_b
```

上付きと下付きの同じ添字を `.` で縮約する，つまりその成分について和を取ると，
`weights~a . f_a` は9項の和になります。`∂_i f_a` では `i` が空間方向，`a` が成分番号です。
[実行検査用の例](tests/fixtures/pre_index_sizes.fme)は，拡散，縮約，空間微分，
9×2の場，対称・反対称な3×3の場を含みます。

明示した `index` は空間方向ではありません。`index a : 2` と空間次元が同じ場合でも，
`∂_a` や空間の計量 `g_a_b` には使えません。`@ primal` / `@ dual` による格子配置も
空間方向の添字だけで決めます。例えば `c_a_i @ primal` は，すべての `a` について
`i` の方向に半格子だけずらします。

サイズには正の整数を指定します。対称・反対称な場の2軸には同じサイズと種類
（両方とも空間方向，または両方とも成分番号）が必要です。微分形式の軸は空間方向のままです。
`index` 宣言があるモデルの局所場には `local q_a` や `local q_a_i` のように添字を
明示します。`local q : tensor` の推論は，空間方向だけを使うモデルで利用できます。
場の対応範囲は従来と同じで，通常の添字付きの場は2軸までです。

## 弾性波の例と適用条件

[壁のある球殻の弾性波の例](examples/elastic_shell/README.md)は，同じプログラムを球座標と，
同じ球殻の非直交座標（経度の線が半径とともに巻く座標系，`metric tensor` で計量を宣言）で
実行し，剛体の壁（速度を 0 に保つ球面と円錐）で反射しながら P 波と S 波が速さ 2 対 1 で
分離して広がることを示します．`origin` 宣言で座標を半径と余緯度そのものにし，
`boundary … : sbp` の壁でも時間方向のブロッキングと MPI 分割（壁のある軸の分割を含む）が
通常版とビット単位で一致します．ねじれ振動の厳密なモード（3 次の球 Bessel 関数と
$P_3^1$）に対する 2 次収束，エネルギー，波速，二つの座標系の一致を `verify.py` が確かめ，
`run.py`・`render.py` が論文の図の実行と描画を行います．

[周期領域の弾性波の例](examples/elastic_pulse/README.md)は，同じプログラムを直交座標と，
同じ周期立方体の非直交座標（格子線が横に波打つ座標系，`metric tensor` で計量を宣言）で
実行し，P 波と S 波が速さ 2 対 1 で分離して広がることを示します．演算子は計量・逆計量・
計量の解析微分をその場で使い，Egison がコンパイル時に展開・簡約した係数を生成された
時間ステップがセルの座標から評価します．時間方向のブロッキングと MPI 分割はそのまま
使えます（Formura のコード生成器がブロッキングされたステップの座標を誤っていた点は
fork で修正済み）．
初期パルス，波の指標，エネルギー，波速を測るモーメント，平面波厳密解との誤差まで
すべて `.fme` の場として計算し，C ドライバは起動と記録だけを行います．

[直交座標の例](examples/elastic3d/elastic3d.fme)は周期境界で，4ステップをまとめる
時間方向のブロッキングを設定しています．初期条件と更新式は `.fme` にありますが，
検証用のエネルギー・波速の計算は C 側に残っています．

[球座標の例](examples/elastic_spherical/elastic_spherical.fme)は壁のある非周期境界を持ちます．
2026-09-12 の Formura の拡張（fork の `tb-boundaries`，`setup.sh` が固定する版）により，
壁のある軸でも時間方向のブロッキングと MPI による領域分割が使えるようになり，
この例も間隔 2 のブロッキングで生成します．実験の初期値は C 側で設定しています．
同じ制約のあった円筒座標の弾性波は，2026-09-10に例題から削除しました．
壁のある全例題でブロッキング版と分割版（`mpicc`・`mpirun` がある場合）が通常版と
ビット単位で一致することは `make tb-wall-tests`（`tests/tb_wall_examples.py`）が確かめます．
各例の初期化・境界・高速化機能の確認結果は [弾性波の例題調査](examples/ELASTICITY-REVIEW.md) にまとめています．

球座標の[再現手順と過去の数値結果](examples/elastic_curvilinear/README.md)，
[関連研究との比較](examples/elastic_curvilinear/RELATED-WORK.md)を参照してください．

## 巻き込む波と引き波

[巻き込む波と引き波](examples/breaking_wave/README.md)は，横から見た二次元の水槽で
水と空気の境界を追跡します．水面が前へせり出す形を，格子ボルツマン法
（格子点間を移動する分布から流れを求める方法）で計算します．初期条件，海底，
水面の更新，水量保存の測定をすべて `.fme` に記述し，Formura 本体を変更せずに
通常の生成経路で実行します．1つの波が崩れ，岸へ乗り上げた水が沖へ戻る引き波まで計算し，
流れが岸向きから沖向きに変わり，持続することを検査します．`make breaking-wave-demo` で動画まで生成し，
`make breaking-wave-verify` で静水との比較も検査できます．

[三次元版](examples/breaking_wave3d/README.md)は，3次元空間で19種類の移動速度を使う
D3Q19へ拡張し，奥行きによって波高と波の位置が変わる水槽を計算します．
`index a : 19` で宣言した分布 `f_a` と，3成分の流速 `u_i` を使います．
立体の水面と2か所の断面を動画にし，水量保存・静水・奥行き方向の対称性を検査します．
実行と描画は `make breaking-wave3d-demo`，数値検証は `make breaking-wave3d-verify` です．
描画用ライブラリの準備は三次元版のREADMEを参照してください．
大きな巻き込みから水と空気の相互作用・飛沫へ進める計画は
[三次元の波の開発計画](TODO/breaking-waves.md)にまとめています．

## 材料則と座標変換を変更する応用デモ

[三つの比較デモ](examples/application_demos/README.md)では，利用者が定義した演算子を
材料モデルや装置の比較に使います．[複合材の超音波](examples/composite_ultrasound/README.md)は
繊維方向と局所的な剛性低下による受信波形の違い，場の回転子は座標変換の回転角と材料層の厚さ，
[円筒型電池の冷却](examples/battery_cooling/README.md)は熱伝導の方向依存性と冷却面を比較します．
初期条件・境界処理・更新式・物理量の測定を `.fme` に記述し，通常の生成経路で実行します．
日英の gallery には比較動画，測定値，ソースと検証結果を掲載しています．
`make application-demos` で計算・検証・動画・gallery を再生成できます（描画用 Python と ffmpeg が必要）．

## 最小例

```formurae
dimension 3
axes x, y, z

param κ = 1.0
param dt = 0.1*dx*dx

field u : scalar

init:
  u = gauss(i*dx,j*dy,k*dz)

step:
  u' = u + dt * κ * Δ u
```

`Δ`はcanonical scalar Laplacianです。精度に依存しないため、
4次精度へ変更するときも別の数学演算子を定義せず、model-level profileを追加します。

```formurae
discretization collocated derivative 2 centered accuracy 4
```

Egisonはgeometryのない`Δ u`を二階のFieldJetへ正規化し、formurae-postが4次精度を満たす最小半径2の
compact 5点stencilをexact rational coefficientで導出します。一階wide stencilを二重適用しません。

## 時間変化しない場

位置ごとに異なっても時間では変化しない係数は、`static field` で宣言します。

```formurae
static field G1{_j_k} @ collocated := gammaTheta
static field J : scalar @ collocated := volume
static field twiceJ : scalar @ collocated := 2 * J
```

右辺は初期化時に宣言された格子配置で一度だけ評価され、以後は値が保持されます。
`init` への代入や `G1' = G1` のような更新式は不要です。
型・添字・格子配置の指定は通常の `field` と共通です。
右辺には座標、パラメータ、計量、および先に宣言した `static field` を使えます。
通常の `field`、後に宣言した固定場、自分自身、次の時刻の値には依存できません。
これらの依存は `def` の評価後にも検査します。`init` での再初期化と `step` での更新もエラーです。
`def` は式の値を定義し、`static field` はその値を格子上に保存する点が異なります。

## 微分の意味

添字つきの `∂` は，式全体を格子上で評価してから差分する微分です．

```formurae
∂_x (u * u)          -- u*u 全体を参照先の点で評価して差分
```

計量などを解析的に微分する場合は `∂/∂` を使います．
未知の解析微分則を0とみなすことはなく，Egisonがエラーにします．

通常の1階差分に対する次のbackquoteは同じ意味を持ちます．

```formurae
`(∂_x (u * u / 2))  -- product ruleを開かないwhole-expression差分
```

入れ子のbackquoteは、内側からの軸順と重複を保ちます。

```formurae
`(∂_y (`(∂_x (`(∂_x q))))  -- x, x, yの順に適用
```

解析的な式の中のbackquoteはEgisonへの指示で、くくった部分式を展開せずに一つの原子として扱います。
生成されるプログラムには中身の式がそのまま入ります。座標変換の写像を`∂/∂`で微分するときに
`` `(x - cx) ``のように中心をずらした座標を原子にしておくと、正規化が数分から1分程度になります
（`examples/transformation_optics`）。

配置変換を意図的に行う場合の明示surfaceは`resample`です。

```formurae
resample(q, 0, 1)   -- 2Dの絶対placement (integer, half) へ線形補間
```

中間storageは型付き`local`で指定します。face fluxを明示する保存形は、
次のように通常の`divg`と合成できます。

```formurae
field u : scalar @ primal

step:
  local q_i @ primal = [| -κ * `(∂_x u), -κ * `(∂_y u) |]_i
  u' = u - dt * divg q
```

`q_i @ primal`は成分ごとに対応軸のfaceへ保存され、`divg q`はcellへ戻る差分を作ります。
このtelescopingによる保存保証は周期境界、または同じfluxと整合するghost/boundary処理の下でのものです。
`.fme` の `boundary x : sbp` は差分の境界行を選びます．
物理的な壁条件は例題の更新式や境界項で与え，FormuraのYAML設定で
実行時の境界処理を指定します．

`origin r = 1.0` は軸 `r` の最初の格子点の座標値を指定します（省略時は 0）．
座標 `r` はそのまま物理的な半径や余緯度として使え，`1 + r` のような
ずれた多項式を Egison が展開せずに済むので，計量を成分で宣言する曲線座標の
生成物が小さくなります．`sbpLoR` などの sbp 境界の定数もこの原点を含みます．

## Tensor、form、格子配置

fieldはscalar、vector、rank-1/rank-2 tensor、`k-form`を宣言できます。

```formurae
field E_i @ primal
field B_i @ dual
field σ{~i~j} @ primal
field A : 1-form
field F : 2-form

step:
  local q_i @ primal = [| 0, 0, 0 |]_i
  local ω : 2-form @ primal = d A
```

配置は`Collocated`、`Primal`、`Dual`のいずれかです。Primal/Dualの具体的な半セル位置は
field policyとcomponent basisのparityからformurae-postが推論します。異なるplacement間の補間は
暗黙に行わず、必要なら`resample(value, bit...)`を使います。

Maxwellはcollocated vector、Yee vector、DEC formの各形式で記述できます。

```formurae
dimension 3
axes x, y, z

field E : 1-form
field B : 2-form

step:
  E' = E + dt * δ B
  B' = B - dt * d E'
```

canonical form演算子は`d`、`hodge`、`δ`、`Δ_H`です。
`δ`は余微分、`Δ_H A = d (δ A) + δ (d A)`はHodge--de Rham Laplacianです。
宣言幾何の`δ`はpreludeマクロとして`dFluxWeights`/`dFluxScale`/`dFluxDiv`へ展開され、幾何のみの係数localはformurae-postがinit凍結のstate配列にします。
`Δ_H`はconstant geometryでのpureな合成をサポートし、general variable-metric formは現IRで表せないためcompile-time errorにします。
これらのform演算子は宣言済みscalar/`k-form`だけを受け取り、ordinary tensorを暗黙にformへ変換しません。
quoted derivativeとcollocated scalar `Δ`もscalar-onlyです。型annotationを持たないuser `def` parameterの
kindは証明できないため、typed operatorはfield、typed `local`、またはkindが確定したstep式へ直接適用します。
indexed `δ~i_j`は余微分とは別のKronecker tensorで、ASCII名`delta`のuser定義にも捕捉されません。
`d(d A) = 0`は演算子ライブラリの定理としてcompiler suiteが検査し、離散的な
`div B = 0`の保存は各exampleのcheck driverが実測します。

## GeometryとLaplace--Beltrami

直交計量はscale factorまたはembeddingで宣言します。

```formurae
axes θ, φ, z
embedding [ `(2 + cos θ) * cos φ, `(2 + cos θ) * sin φ, sin θ, z ]

step:
  u' = u + dt * Δ u
```

座標線が直交しない座標系では、計量を成分で宣言します。

```formurae
axes θ, ψ                                    -- トーラスのねじった座標 φ = ψ + θ
metric g
metric tensor [[36 + (12 + 6 * cos θ)^2, (12 + 6 * cos θ)^2], [(12 + 6 * cos θ)^2, (12 + 6 * cos θ)^2]]
metric volume 6 * (12 + 6 * cos θ)         -- 省略すると sqrt(det g) をEgisonが作る
```

`metric tensor`ではEgisonが対称性を検査し、逆計量と体積要素を導きます。このとき使えるのは
`g~i~j`・`g_i_j`・`volume`と`∂/∂`による計量の解析微分で、直交性を前提とするcanonicalな
`Δ`・`δ`・`hodge`はコンパイル時エラーになります(流束形を明示的に書きます)。
`examples/excitable_torus/excitable_torus_twisted.fme`は同じ興奮波のモデルをこの座標で書き、
直交座標の結果と2次精度で一致することを`charts.py`で確認します。

Egisonはmetric、inverse metric、scale factor、volumeを記号的に作り、embeddingでは直交性を
検査します。geometryを宣言したモデルの`Δ u`はpreludeマクロとして、実体化した重み・flux
localと符号付きadjoint divergenceへ展開されます。FEIRに残るのはordinaryなMaterialize
actionとwhole-operandな`derivative.grid-whole` requestだけで、幾何のみの係数local
はformurae-postが凍結してinit一回+恒等carryのpersistent stateにします(mirror/fixed壁の
境界処理もstate配列として宣言どおりに受けます)。

## FEIR

FEIR (Formurae Egison IR) はEgisonとformurae-postのcanonical protocolです。その同一性は
手で振る版番号ではなくfingerprint(内容ハッシュ)が固定します。

`.fme` のgeometry、`:=` analytic initializer、step、parse可能な`def`に書いた
小数・指数リテラルは、formurae-preが綴りどおりのexact rationalへ変換します。
raw Egison `def`本体と`=` raw initializerはEgisonのFloat/生文字列の意味論を保ちます。
有限なdouble backendへ安全に下ろせない指数、または約分後の分子・分母をbinary64へ
正確に渡せない非整数リテラルは、丸めて続行せずcompile-time errorにします。
Unicode `π` はEgison CASでシンボリックに簡約され、残った値はFEIRの
`(named-constant pi)`としてformurae-postまで保持されます。FMRをrenderするときだけ、binary64のπと
同値で両operandが2^53未満の`(884279719003555 / 281474976710656)`へ変換します。
ASCII `pi`はEgisonのFloatと衝突するためaliasではありません。parameter値と`=` raw initializerは
symbolic FEIRを通らないので、そこでは`π`を使わずbackend数値を明示します。

- exact rationalを保持するcanonical S-expression
- closedなnamed mathematical constant
- stable `AxisId`、`FieldId`、`FunctionId`、`OriginId`（軸のrecordは
  `origin` 宣言があるときだけ省略可能な `start` fieldを持つ）
- scalar/tensor normal formとderivative multi-index付き`FieldJet`
- `GeometryNF`、discretization profile、opaque discrete request
- 場の各軸のサイズと，空間方向を表す軸の位置 `spatial-slots`（1から数える）
- registry/primitive-manifest/profile fingerprint
- `.fme`のpath・line・columnとdefinition expansion trace

list nodeの順序はcanonical S-expressionをrenderしたbyte列で決まり、Egison encoderとHaskell
validatorが同じ規則を使います。decoderはwire順を保持するため、非canonicalな入力順をparse時の
sortで隠さずhard errorにします。

成功したEgison stageのstdoutはFEIR 1個だけです。diagnosticはstderrへ分離され、warning、type error、
evaluation error、余分なstdoutはmachine runnerが拒否します。

## クイックスタート

### インストール

Formurae、Egison、検証済みFormuraはすべてCabalでインストールできます。
`cabal install`の実行ファイルディレクトリ(通常は`~/.local/bin`)を`PATH`に加えてください。

```sh
cabal install egison-5.1.0

git clone https://github.com/egison/formura.git
cd formura
git checkout 3bc74b5c6f1a24dfffe869839d75fd44b8aa2eb0
cabal install exe:formura --overwrite-policy=always
cd ..

git clone https://github.com/egison/formurae.git
cd formurae
cabal install exe:formurae exe:formurae-pre exe:formurae-post \
  --overwrite-policy=always
```

一括CLIは`.egi`、`.feir`、`.fmr`を入力ファイルと同じディレクトリへ書き、
`compile`では続けてFormuraを呼び出します。

```sh
formurae compile examples/diffusion3d/diffusion3d.fme
formurae lower examples/diffusion3d/diffusion3d.fme
```

`compile`には入力と同じbasenameの`.yaml`が必要です。`lower`は`.fmr`生成で停止します。
`EGISON`、`FORMURA`、`FORMURAE_PRE`、`FORMURAE_POST`環境変数で各実行ファイルを明示できます。

### 開発と検証

リポジトリ全体の試験はGHC 9.6系、隣接する`../egison`開発tree、および検証済みFormuraを使います。
`make setup`はFormuraを固定commitからCabalで`bin/formura`へインストールします。
1-rank用MPI stubを同梱しています。

```sh
make setup
cabal build
make diffusion3d
make maxwell3d_yee
make metric_torus
```

`make NAME`は`.fme -> .egi -> .feir -> .fmr -> C -> check`を通します。全例は次で検証できます。

```sh
make all
```

各stageを直接確認する場合:

```sh
cabal run -v0 formurae-pre -- examples/diffusion3d/diffusion3d.fme > /tmp/model.egi

tools/run_formurae_normalization.sh ../egison \
  /tmp/model.egi > /tmp/model.feir

cabal run -v0 formurae-post -- /tmp/model.feir > /tmp/model.fmr
```

## 生成物

`.fme`が編集対象です。42個のFME例では`.egi`、`.feir`、`.fmr`をreview可能な生成artifactとして
追跡し、Makefileから再生成します。galleryは4段すべてを表示します。`mhd_ot`は19本の保存流束を
typed `local`として物質化し、`lbm_d3q19`は中心1階・2階差分の恒等式で整数1セルpullを構成して、
どちらも通常の`.fme -> .egi -> .feir -> .fmr`経路で検査します。LBMの19成分を
まとめて宣言する場合は `index a : 19` と `field f_a` を使えます。
`lbm_d3q19` では，この添字宣言で分布と衝突・移動の各段階をまとめています。

## リポジトリ構成

| パス | 役割 |
|---|---|
| `app/formurae/` | インストール済みtoolchainを駆動する一括CLI |
| `app/formurae-pre/` | Formurae frontend CLI |
| `app/formurae-post/` | FEIR validation・discretization・Formura backend CLI |
| `src/Formurae/FEIR/` | FEIR syntax、codec、validation、fingerprint |
| `src/Formurae/Pre/` | parse、registry、effect analysis、Egison emitter |
| `src/Formurae/Post/` | placement、stencil、geometry/backend plan、FMR AST/printer |
| `lib/formurae-operators.egi` | pure continuum operatorとopaque request constructor |
| `lib/formurae-primitives.egi` | primitive manifestから自動生成するfull-signature binding |
| `lib/formurae-feir.egi` | MathValue/Tensorからcanonical FEIRへのencoder |
| `spec/feir-primitives.sexp` | 5 primitiveのfull signatureを規定する唯一のmanifest source |
| `spec/egison-normalization.list` | Egison normalization libraryの規範load順 |
| `examples/` | model、生成artifact、C numerical check |
| `gallery/` | galleryのasset(画像・動画・データ)と生成スクリプト |
| `html/ja/`・`html/en/` | gallery・usage guideのHTML(日本語/英語) |

galleryの時間場は、初期・最終画像の補間ではなく、数値計算中に等間隔で保存した実データから
H.264動画を生成します。`ffmpeg`を用意し、全exampleのC生成後に次を実行します。

```sh
make all
make gallery-assets
```

`gallery/gen.sh`が静止画用snapshotと動画frame dataを同じrunで生成し、
`render.py`が静止画、`render_video.py`が全フレーム共通の色スケールで動画を描画・encodeします。
誤差曲線、厳密解比較、時空図は検証情報を同時に読める静止図のまま保持します。

## 検証

変更は次の層で検査します。

```sh
EGISON_DIR=$(tools/prepare_elastic_validation.sh)
EGISON_HEAP_LIMIT=4G make compiler-tests EGISON_DIR="$EGISON_DIR"
EGISON_HEAP_LIMIT=4G make all EGISON_DIR="$EGISON_DIR"
```

検証済みの Egison は `87cbb478c845e9760ecfc1d0518b464df10a72cf` です。
依存版は [`spec/egison-revision`](spec/egison-revision) で管理し、準備スクリプトは
`.build/egison-<リビジョン>` に展開します。隣接する Egison の作業ツリーは変更しません。
`EGISON_DIR` を省略すると `../egison` を使うため、開発中の最新版でも同じ検査を実行できます。
`EGISON_HEAP_LIMIT` は Egison が管理するメモリの上限を指定します。標準の上限は `4G` です。
大きなモデルの出力情報は型付きの小さな定義へ分割し、1G の上限でも正規化できることを検査します。

- FEIR round-trip、malformed input、fingerprint、source diagnostic
- formurae-pre scope/effect/ambient-binding tests
- Egison analytic differentiation、FieldJet、tensor/form operator tests
- formurae-post profile、exact Taylor stencil、placement、quoted derivative、geometry-aware `Δ` / `δ` tests
- collocated/Yee/DEC/variable-metric exampleのFormura parseとC numerical checks
- Egison math representative samples、mini-test全件、`cabal test`

現在の受入れ基準は `tests/compiler_suite.sh`、個別の `tests/*.sh`、および `Makefile` の
検証targetに実行可能な形で保持します。

設計上、旧`fec` CLI、旧generated `.egi` schema、callback/marker based loweringとの後方互換性は
提供しません。仕様変更時はexample、document、testを新しい意味へ同時に更新します。

## 関連資料

- [`DSL-DESIGN.md`](DSL-DESIGN.md): 表層構文と設計履歴
- [`html/ja/usage.html`](html/ja/usage.html)/[`html/en/usage.html`](html/en/usage.html): tutorialとusage guide
- [`html/ja/gallery.html`](html/ja/gallery.html)/[`html/en/gallery.html`](html/en/gallery.html): 検証済み応用のgallery
- [`APPLICATIONS.md`](APPLICATIONS.md): 応用例一覧
- [`UPSTREAM.md`](UPSTREAM.md): Formura側の過去の拡張案と実装記録

## ライセンス

MIT。Formura本体とvendor sourceはそれぞれのlicenseに従います。
