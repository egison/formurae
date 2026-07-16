# Formurae

Formurae は、Egison のテンソル添字記法で書いた偏微分方程式を
[Formura](https://github.com/formura/formura) の stencil programへ変換し、
MPI・temporal blocking付きC codeを生成するための実験的な言語処理系です。

表層言語の拡張子は `.fme` です。数式の意味と離散化を分離し、次の4段で処理します。

```text
model.fme
  └─ pre-fec ──> model.egi
                    └─ Egison ──> model.feir
                                      └─ post-fec ──> model.fmr
                                                         └─ Formura ──> C
```

- `pre-fec` は構文、scope、宣言、source mapを検査し、Egison normalization unitを生成します。
- Egison はuser definition、tensor/index algebra、analytic differentiationを評価し、canonical FEIRを出力します。
- `post-fec` はplacement、stencil、補助field、storageを決め、Formura programを生成します。
- Formura は配列、loop、MPI通信、temporal blockingを含むC codeを生成します。

純粋な数学演算子はEgisonにだけ定義されます。`grad`、`divg`、`curl`、`hessian`、`lap`、
`d`、`hodge`、`δ`、`Δ_H`の解析的な部分は、callbackやcomponent loopを含まない短いEgison関数です。
具体的な差分係数や格子offsetをEgisonの演算子定義へ混ぜません。

user tensor operatorも同じ経路です。例えば次の`withSymbols`を出た自由な下添字は、Egisonでは
添字を省略したtensor軸になります。省略軸には既存の明示添字とは異なるfreshな下添字が補われ、
pre-fecは関数名や本体からresult varianceのcontractを推論・付与しません。EgisonがRHSを評価した後、
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

pure user operatorの本体は1行に限定されません。`=`の次をindentすると、Egisonの`let`、lambda、
`match`、`withSymbols`、`generateTensor`を含む式blockをそのままnormalizationへ渡せます。
1行の本体とこのようなrich bodyは、どちらもEgisonが通常の式として評価します。Formuraeはuser
definitionの式構造や計算履歴を検査してresult contractを付けません。評価結果がfield equation
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

## 最小例

```formurae
mode collocated
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

`Δ`は`mode collocated`のcanonical scalar Laplacianです。精度に依存しないため、
4次精度へ変更するときも別の数学演算子を定義せず、model-level profileを追加します。

```formurae
discretization collocated derivative 2 centered accuracy 4
```

Egisonはgeometryのない`Δ u`を二階のFieldJetへ正規化し、post-fecが4次精度を満たす最小半径2の
compact 5点stencilをexact rational coefficientで導出します。一階wide stencilを二重適用しません。

## 微分の意味

通常の`∂`は解析微分です。

```formurae
∂_x (u * u)          -- Egison: 2 * u * FieldJet(u,{x:1})
```

未知の解析微分則を0とみなすことはなく、Egisonの`∂/∂`がerrorにします。
混合偏微分はcanonicalなmulti-indexへまとめられます。

式全体を先に格子上で評価してから差分したい保存形では、微分式をbackquoteします。

```formurae
`(∂_x (u * u / 2))  -- product ruleを開かないwhole-expression差分
```

入れ子のbackquoteは、内側からの軸順と重複を保ちます。

```formurae
`(∂_y (`(∂_x (`(∂_x q))))  -- x, x, yの順に適用
```

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
現在の`.fme`は物理境界条件自体を宣言せず、Formura側のYAML・boundary設定が権威です。

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
field policyとcomponent basisのparityからpost-fecが推論します。異なるplacement間の補間は
暗黙に行わず、必要なら`resample(value, bit...)`を使います。

Maxwellはcollocated vector、Yee vector、DEC formの各形式で記述できます。

```formurae
mode dec
dimension 3
axes x, y, z

field E : 1-form
field B : 2-form

step:
  E' = E + dt * δ B
  B' = B - dt * d E'

assert-dd-zero E'
```

`mode dec`のcanonical form演算子は`d`、`hodge`、`δ`、`Δ_H`です。
`δ`は余微分、`Δ_H A = d (δ A) + δ (d A)`はHodge--de Rham Laplacianです。
可変計量の`δ`は、post-fecがweighted discrete adjointのHodge係数・補助field・配置とlifetimeを計画します。
`Δ_H`はconstant geometryでのpureな合成をサポートし、general variable-metric formは現IRで表せないためcompile-time errorにします。
これらのform演算子は宣言済みscalar/`k-form`だけを受け取り、ordinary tensorを暗黙にformへ変換しません。
quoted derivativeとcollocated scalar `Δ`もscalar-onlyです。型annotationを持たないuser `def` parameterの
kindは証明できないため、typed operatorはfield、typed `local`、またはkindが確定したstep式へ直接適用します。
indexed `δ~i_j`は余微分とは別のKronecker tensorで、ASCII名`delta`のuser定義にも捕捉されません。
`assert-dd-zero`は`d(d E') = 0`を
normalization時に確認し、成立しなければFEIRを出力しません。

## GeometryとLaplace--Beltrami

直交計量はscale factorまたはembeddingで宣言します。

```formurae
axes θ, φ, z
embedding [ `(2 + cos θ) * cos φ, `(2 + cos θ) * sin φ, sin θ, z ]

step:
  u' = u + dt * Δ u
```

Egisonはmetric、inverse metric、scale factor、volumeを記号的に作り、embeddingでは直交性を
検査します。geometryを宣言した`mode collocated`の`Δ u`は、保存流束、half-cell coefficient、
volume除算、補助fieldのlifetimeを伴うversioned requestとしてFEIRへ残ります。post-fecがそのrequestから係数field、flux、
divergence、更新順序を計画します。同じsourceのrequestは共有され、異なるsourceは分離されます。

## FEIR

FEIR (Formurae Egison IR) はEgisonとpost-fecのversioned protocolです。

`.fme` のgeometry、`:=` analytic initializer、step、parse可能な`def`に書いた
小数・指数リテラルは、pre-fecが綴りどおりのexact rationalへ変換します。
raw Egison `def`本体と`=` raw initializerはEgisonのFloat/生文字列の意味論を保ちます。
有限なdouble backendへ安全に下ろせない指数、または約分後の分子・分母をbinary64へ
正確に渡せない非整数リテラルは、丸めて続行せずcompile-time errorにします。
Unicode `π` はEgison CASでシンボリックに簡約され、残った値はFEIRの
`(named-constant pi)`としてpost-fecまで保持されます。FMRをrenderするときだけ、binary64のπと
同値で両operandが2^53未満の`(884279719003555 / 281474976710656)`へ変換します。
ASCII `pi`はEgisonのFloatと衝突するためaliasではありません。parameter値と`=` raw initializerは
symbolic FEIRを通らないので、そこでは`π`を使わずbackend数値を明示します。

- exact rationalを保持するcanonical S-expression
- closedなnamed mathematical constant
- stable `AxisId`、`FieldId`、`FunctionId`、`OriginId`
- scalar/tensor normal formとderivative multi-index付き`FieldJet`
- `GeometryNF`、discretization profile、versioned opaque request
- registry/primitive-manifest/profile fingerprint
- `.fme`のpath・line・columnとdefinition expansion trace

list nodeの順序はcanonical S-expressionをrenderしたbyte列で決まり、Egison encoderとHaskell
validatorが同じ規則を使います。decoderはwire順を保持するため、非canonicalな入力順をparse時の
sortで隠さずhard errorにします。

成功したEgison stageのstdoutはFEIR 1個だけです。diagnosticはstderrへ分離され、warning、type error、
evaluation error、余分なstdoutはmachine runnerが拒否します。

## クイックスタート

前提はGHC 9.6系と、隣接する`../egison`の開発treeです。Formuraのbuildには`stack`を使いますが、
FormuraeとEgison自身は`cabal`でbuildします。1-rank用MPI stubを同梱しています。

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
cabal run -v0 pre-fec -- examples/diffusion3d/diffusion3d.fme > /tmp/model.egi

tools/run_formurae_normalization.sh ../egison \
  /tmp/model.egi > /tmp/model.feir

cabal run -v0 post-fec -- /tmp/model.feir > /tmp/model.fmr
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
| `fec/app/pre-fec/` | Formurae frontend CLI |
| `fec/app/post-fec/` | FEIR validation・discretization・Formura backend CLI |
| `fec/src/Formurae/FEIR/` | FEIR syntax、codec、validation、fingerprint |
| `fec/src/Formurae/Pre/` | parse、registry、effect analysis、Egison emitter |
| `fec/src/Formurae/Post/` | placement、stencil、geometry/backend plan、FMR AST/printer |
| `lib/formurae-operators.egi` | pure continuum operatorとopaque request constructor |
| `lib/formurae-primitives.egi` | primitive manifestから自動生成するversioned full-signature binding |
| `lib/formurae-feir.egi` | MathValue/Tensorからcanonical FEIRへのencoder |
| `spec/feir-primitives-v1.sexp` | 6 primitiveのfull signatureを規定する唯一のmanifest source |
| `spec/egison-normalization-v1.list` | Egison normalization libraryのversioned load順 |
| `examples/` | model、生成artifact、C numerical check |
| `gallery/` | sourceと数値結果のgallery |

## 検証

変更は次の層で検査します。

```sh
make compiler-tests
make all
```

- FEIR round-trip、malformed input、fingerprint、source diagnostic
- pre-fec scope/effect/ambient-binding tests
- Egison analytic differentiation、FieldJet、tensor/form operator tests
- post-fec profile、exact Taylor stencil、placement、quoted derivative、geometry-aware `Δ` / `δ` tests
- collocated/Yee/DEC/variable-metric exampleのFormura parseとC numerical checks
- Egison math representative samples、mini-test全件、`cabal test`

現在の受入れ基準は `tests/compiler_suite.sh`、個別の `tests/*.sh`、および `Makefile` の
検証targetに実行可能な形で保持します。

設計上、旧`fec` CLI、旧generated `.egi` schema、callback/marker based loweringとの後方互換性は
提供しません。仕様変更時はexample、document、testを新しい意味へ同時に更新します。

## 関連資料

- [`DSL-DESIGN.md`](DSL-DESIGN.md): 表層構文と設計履歴
- [`gallery/usage.html`](gallery/usage.html): tutorialとusage guide
- [`APPLICATIONS.md`](APPLICATIONS.md): 応用例一覧
- [`UPSTREAM.md`](UPSTREAM.md): Formura側の拡張計画

## ライセンス

MIT。Formura本体とvendor sourceはそれぞれのlicenseに従います。
