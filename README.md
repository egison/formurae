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
`(gamma 0)~i_k_l . Q~l~j`のように`.`による縮約とも組み合わせられます
(defの結果は`(christoffel 0)~i_1_l`のように数値添字で成分を取り出せます)。

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

`.fme`が編集対象です。27個のFME例では`.egi`、`.feir`、`.fmr`をreview可能な生成artifactとして
追跡し、Makefileから再生成します。galleryは4段すべてを表示します。`mhd_ot`は19本の保存流束を
typed `local`として物質化し、`lbm_d3q19`は中心1階・2階差分の恒等式で整数1セルpullを構成して、
どちらも通常の`.fme -> .egi -> .feir -> .fmr`経路で検査します。LBMの19成分宣言と式を速度集合から
自動展開する`field f : family 19`構文は、記述量をさらに減らす将来の表層機能です。

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
