# quoted derivative・明示local保存・最小離散演算子surface

Date: 2026-07-13

Status: Implemented (2026-07-13)

本書は、[pre-fec / post-fec pipeline設計](20260711-pre-post-fec-pipeline.md)を前提に、保存形のwhole-expression
微分、step-local storage、保存flux、微分形式、Laplace--Beltramiを、できるだけ数式に近い
Formurae surfaceへ整理する設計を定める。既存pipelineとFEIR v1の説明は
[pre-fec / post-fec pipeline設計](20260711-pre-post-fec-pipeline.md)を正とし、本書はそのsurface
simplificationと次期実装計画を追加する。

本変更では後方互換性を要件としない。cutover時には旧surface名、examples、docs、testsを同時に
更新し、deprecated aliasや互換shimを残さない。

## 1. Decision summary

確定した中心構文は次である。

```formurae
∂_x (u * u)       -- analytic derivative
`(∂_x (u * u))    -- whole-expression grid derivative
```

通常の`∂`はEgisonが積・商・chain ruleを適用する解析微分である。微分適用全体を
backquoteで囲んだ `` `(∂_x e) `` は、`e`を一つの格子式として各stencil offsetで評価し、
解析展開せずに差分する。

保存される中間値は`local`で明示する。

```formurae
let a = u * u          -- pure alias; materializationしない
local b = u * u        -- step-local grid field; materializationする
```

目標surfaceでは次を行う。

- `gridD` / `gridDerivative`を `` `(∂_x e) `` へ統合する。
- indexed/vector/tensor/form `local`と`@ collocated` / `@ primal` / `@ dual`を追加する。
- materialized face fluxへの通常の`∂` / `divg`から保存divergenceを構成し、
  `fluxDiv` / `conservativeDiv`を削除する。
- `materialize(value)`を削除し、storage boundaryを`local`へ一本化する。
- `d`と`hodge`を基本演算として残し、`δ`と`Δ`を数学的合成として表す。
- variable metricの`δ`とscalar Laplace--Beltramiは、surface合成を保ったまま
  discrete-adjoint / conservative backend planへlowerする。

今回採択しない構文も明示しておく。

```formurae
balance mass:
  density ρ
  measure volume
  flux F_i
  source 0
```

この案を読むなら、`mass`はbalanceの名前、`density ρ`はmeasureあたりの保存密度、
`measure volume`は積分測度、`flux F_i`は境界を横切る流束、`source 0`は体積sourceがないことを
表す。意図する連続式は`∂_t(ρ * volume) + boundaryFlux(F) = 0`である。

同じ案を他の保存則へ当てはめると、概念上は次になる。この表は意味の整理であり、採択surface構文では
ない。

| Balance | Density | Measure | Flux | Source |
|---|---|---|---|---|
| mass | `ρ` | volume | `ρ v_i` | mass production `s_ρ` |
| momentum component `i` | `ρ v_i` | volume | stress/momentum flux `Π_i_j` | body force `f_i` |
| energy | `E` | volume | energy flux `H_i` | heating/work `Q` |
| electric charge | `q` | volume | current `J_i` | charge production `s_q` |

この`balance` blockは、保存するstorage、fluxの配置、離散divergenceを単独では決められず、
density/flux/sourceの関係は明示した更新式とも重複する。一方、variable metricにおける`volume`の
ように、measureは更新式だけから自明でない検証情報になり得る。このため初回設計には入れず、保存則は
typed `local`と通常の更新式で直接書く。

将来追加する場合も、`balance`はstencil、storage、placementを選ばず、既存action graphを検証する
assertion / diagnostic metadataに限定する。その場合は少なくとも次を要求する。

- densityを一つのupdate targetへ対応付ける。
- Euclidean unit measure以外ではmeasureを省略しない。
- fluxはすでにmaterializeされたrank-1、dfOrder 0のPrimal face fieldを参照する。
- volume sourceとboundary exchangeを別々に記述する。
- higher-rank fluxはdivergence axis contractが決まるまで対象外とする。

boundary conditionをFormuraeで宣言できることには価値があるが、本変更には含めない。現時点の
Formuraeはinterior operatorを生成し、boundary/ghost処理はFormuraが所有する。将来導入する場合は、
単なるghost-fill指定ではなく、保存則と離散随伴のoperator domainを型付けする構文として設計する。

review gateで次を採択し、実装した。

- quoted derivativeの入れ子を順序付きgrid derivative chainとし、`orderedD`を削除した。
- canonical surface名を`δ`、scalar `Δ`、form `Δ_H`に絞り、`codiff`、`formLaplacian`、`lb`を
  特別な予約名から外す。
- per-occurrence wide derivative `∂'^m_x`は今回のcutoverでは残した。
- localはfield declarationが表せるscalar、vector、rank-2 tensor、form、symmetric、antisymmetricを
  同じtype/layout projectorで扱う。
- boundary conditionのownerは引き続きFormuraとし、Formurae surfaceには今回追加しない。

## 2. Goals and non-goals

### 2.1 Goals

- 数式上同じ`∂`を用いながら、analytic derivativeとwhole-expression grid derivativeを
  source上で判別できるようにする。
- whole-expression指定、保存指定、placement指定を別々の概念として扱う。
- ユーザーが保存する中間fieldを`local`で明示できるようにする。
- rank、shape、variance、differential-form degree、policy、component placementを静的検査する。
- 一つのmaterialized face fluxを隣接cellが共有し、内部face contributionが相殺する
  保存divergenceを通常のtensor式から構成できるようにする。
- `d`、Hodge star、`δ`、`Δ`の連続数学上の定義をsurfaceに保つ。
- variable coefficient、metric、volume、orientation、Primal/Dual、storage lifetimeを
  typed IRからpost-fecへ渡す。
- source path、line、column、definition expansion traceを新しい構文でも保持する。

### 2.2 Non-goals

- 任意のPDEからflux、Riemann solver、limiter、reconstructionを自動推測すること。
- placementの異なる値の間に補間を暗黙挿入すること。
- 任意の解析式から保存形や離散随伴をnormalization後に再発見すること。
- boundary conditionなしに大域保存、自己共役性、正定値性を保証すること。
- 初版で一般非直交metric、unstructured mesh、full Hodge mass matrixを実装すること。
- sampled Yee component表現を、初版からintegrated cochainによる完全なDECと呼ぶこと。
- generic Egison program全体のquote意味を変更すること。
- `balance` blockからupdate equationやflux storageを自動生成すること。
- LHS placementからRHS derivativeのstencilを逆向きに推論すること。

## 3. Terminology

本書では次を区別する。

- **analytic derivative**: Egisonが積・chain ruleを適用し、FieldJet multi-indexへ正規化する微分。
- **whole-expression grid derivative**: operand内部を解析微分せず、operand全体をstencil sampleして
  差分する微分。
- **grid derivative chain**: whole-expression一次微分を指定順に合成したもの。
- **pure alias**: `let`による非保存束縛。参照は値へ展開できる。
- **materialized local**: `local`によるstep-local logical field。参照はFieldIdを通し、
  RHSへ再展開しない。
- **policy**: `Collocated`、`Primal`、`Dual`のlogical grid policy。
- **placement**: policyとcomponent basis parityから得る各軸のinteger/half位置。
- **formal adjoint**: 連続内積と境界項を前提にした`d`の随伴。
- **discrete adjoint**: 選択済みの離散`d`とmass/Hodge matrixに対する行列随伴。

「局所的にconservativeなflux-difference stencil」と「boundaryを含む領域全体の保存則」も
同一視しない。前者はinterior loweringで保証できるが、後者にはboundary operator domainが必要である。

## 4. Quoted whole-expression derivative

### 4.1 Canonical syntax

canonical surface形は次とする。

```formurae
`(∂_x e)
```

compound operandでは作用範囲を明確にするため、次の形を標準表記とする。

```formurae
`(∂_x (u * u / 2))
```

外側の `` `( ... ) `` 全体が一つのFormurae専用構文である。backquoteがoperandだけに付く
`` ∂_x `(e) `` や、axisへprimeを付ける`∂_x' e`はこの意味に使わない。

初版では次に限定する。

- 一階微分。
- modelで宣言された固定coordinate axis。
- scalar operand。
- radius 1。
- current `derivative.grid-whole@1`と同じprofile-bypassing contract。

symbolic indexed axis `∂_i`、direct higher derivative `∂^m_x`、tensor whole operandは、
それぞれresult shapeとaxis expansion contractを別途定めるまでquoted formでは拒否する。
materialized tensor fluxのdivergenceには通常のindexed derivativeを使うため、初版の保存則記述に
quoted `∂_i`は必須ではない。

### 4.2 Semantic rule

`e`がscalar grid expressionであるとき、

```formurae
∂_x e
```

は`e`を解析微分してからFieldJetを離散化する。一方、

```formurae
`(∂_x e)
```

は`e`を各sample offsetで一つの値として評価してから固定一次差分を適用する。

Collocated uniform gridでは、

\[
  G_x[e]_i =
  \frac{e_{i+1}-e_{i-1}}{2\Delta x}.
\]

例えば、

\[
  G_x[u^2]_i =
  \frac{u_{i+1}^{2}-u_{i-1}^{2}}{2\Delta x},
\]

であり、

\[
  2u_i\frac{u_{i+1}-u_{i-1}}{2\Delta x}
\]

ではない。

Primal/Dual fieldでは、source placementとaxisからYee forward/backward pairを選び、target placementを
そのaxisについて反転する。暗黙resampleは行わない。

Located operandの微分結果placementはconsumerから独立に決める。`local ... @ primal`やfield
equationのLHSはexpected placementを与えるが、それによってCollocated derivativeをcell-to-face
derivativeへretargetしてはならない。expected placementは、定数やcoordinateのようにintrinsic
placementを持たないConstant/Sampleable operandを既存のdemand semanticsでanchorし、最終的な
Located値との一致を検査するためだけに使う。このanchorは既にLocatedな値を移動する規則ではない。

したがって、次の`u`がCollocated fieldなら、quoted derivativeもCollocatedに留まる。

```formurae
field u : scalar

step:
  local q_i @ primal = [| `(∂_x u), `(∂_y u) |]_i  -- placement error
```

LHS annotationだけを見てYee gradientへ変えると、同じ式を`let`やhelper functionへ移しただけで
stencilが変わり得るためである。face targetが必要なら、自然にそのplacementへ移るsource policy、
または意味を独立に定めた明示placement変換を使う。

quoted derivativeは次の解析には透明である。

- scope/name resolution
- scalar/tensor/form type checking
- free index、variance、shape、degree checking
- field/effect collection
- source policyとplacement checking
- source provenance

一方、analytic product/chain ruleに対しては不透明である。

### 4.3 Storage semantics

quoted derivativeはmaterializationを意味しない。operandは必要なoffsetで直接評価され、
中間fieldを作らない。

```formurae
`(∂_x (u * u))
```

と、

```formurae
local w = u * u
∂_x w
```

は同じ値になる場合があるが、storage contractは異なる。前者はpure-local inline stencil、
後者は`w`を先に保存するstep-local scheduleである。

### 4.4 Egison quoteとの境界

このspellingはEgisonのprefix backquoteに似ているが、`.fme`のexact
`Quote(CoordinateDerivative(...))`形はpre-fecがEgison評価前に消費する。Egisonの`Quote`値として
出力してから後段で意味を推測してはならない。

したがってfrontendは次を区別する。

- `` `(∂_x e) ``: Formurae whole-expression grid derivative。
- geometry専用経路の `` `e ``: 既存のCAS rule-suppression quote。
- pure `def`のraw-Egison fallbackなど、現在generic quoteを受理するcontext: 現行Egison quote意味を維持。
- structured parseが必須の`init` / `step` / `local` RHS: quoted derivative以外のgeneric quoteを
  新しく許可しない。

この区別は`prepareDefinitions`のraw-Egison fallbackより前に構造parseしなければならない。
`.fme`で「微分式そのものを通常のCAS Quote値にする」旧解釈は、このcutoverでは提供しない。

### 4.5 Nesting and ordered chains

`orderedD`をsurfaceから削除する場合、quoted derivativeの入れ子を次のように定める。

```formurae
`(∂_y (`(∂_x e)))
```

これは`x`を先に、`y`を後に適用する。

\[
  G_y(G_x(e)).
\]

frontendはnested opaque nodeを作らず、次の一つのsemantic nodeへflattenする。

```text
GridDerivativeChain {
  operand = e,
  axes = [x, y],
  per_stage_order = 1,
  per_stage_radius = 1,
  profile = fixed-v1
}
```

規則は次とする。

- innermost derivativeをaxis列の先頭に置く。
- axis列をsortしない。
- 同じaxisの重複を保持する。
- CASのSchwarz multi-indexへ変換しない。
- 各段直前のplacementからYee pairを選び、そのaxisのplacementを反転する。
- 中間fieldをmaterializeしない。
- normal analytic derivativeをgrid chainの外側へ直接掛けることは拒否する。
- `local`を挟んだ場合はflattenせず、明示storage boundaryとして扱う。

通常の`∂^2_x e`と二段chainは同じではない。Collocated accuracy 2では、

\[
  \partial_x^2 e
  \longrightarrow
  \frac{e_{i-1}-2e_i+e_{i+1}}{\Delta x^2},
\]

だが、`G_x(G_x(e))`は、

\[
  \frac{e_{i-2}-2e_i+e_{i+2}}{4\Delta x^2}
\]

になる。

このnesting contractを採択した時点で`orderedD` / `orderedDerivative`を削除する。採択しない場合は
両名を削除してはならない。

### 4.6 Static errors

少なくとも次をsource位置付きhard errorにする。

- undeclared axis
- empty derivative operand
- v1でのsymbolic axis、tensor operand、direct higher derivative
- source placementが一意に定まらないoperand
- 暗黙補間を必要とするmixed placement
- analytic derivativeがgrid derivative resultをoperandに取る形
- effect contractに反するhigher-order function引数
- quoted構文の括弧不整合

## 5. Indexed/vector/tensor local

### 5.1 Surface shape

`local`はfield declarationと同じindex/policy vocabularyを持つstep actionへ拡張する。

```formurae
local s = scalar_expr
local q_i @ primal = vector_expr
local A_i_j @ dual = rank2_expr
local ω : 2-form @ primal = form_expr
```

初版ではplain scalar/vector/rank-2 tensor/formを対象にする。symmetric/antisymmetric shorthandを
同時に実装する場合はfield declarationと同じcanonical component projectionを必ず再利用する。

policy省略時はtensor kindにかかわらず`@ collocated`とする。Primal/Dual localは必ず明示annotationを
持ち、RHSからpolicyを推論しない。これはlocal固有の一貫したdefaultであり、form fieldの既定policyを
localへ流用する規則ではない。

LHSは次を決める。

- logical name / FieldId
- rankとshape
- index variance
- differential-form degree
- layoutとcanonical component projection
- GridPolicy
- StepLocalLifetime

RHSからpolicyやtensor kindを名前ベースで推測しない。RHSのactual result signatureとplacementがLHSに
一致することを検査する。

特にLHS policyはRHSの微分schemeを選択しない。`local q_i @ primal = rhs_i`では各`rhs_i`が、
consumerとは独立に、対応するPrimal faceへLocatedでなければならない。Constant/Sampleableはそのfaceで
評価できるが、既にLocatedなcell値を暗黙補間しない。

例えば次を2次元で読む。

```formurae
local q_i @ primal =
  [| -κ * `(∂_x u),
     -κ * `(∂_y u) |]_i
```

`q_i`は自由index `i`を持つrank-1 tensor localの宣言である。右辺の`[| a, b |]_i`は
「component `i`が`i=x`なら`a`、`i=y`なら`b`」というtensor component式であり、runtimeのarray添字や
逐次loopではない。`@ primal`により`q_x`はx-face、`q_y`はy-faceへ置かれ、両componentを一つのlogical
field bundleとして保存する。

### 5.2 `let` and `local`

`let`はpure bindingであり、storageを作らない。

```formurae
let f = u * u
∂_x f
```

は`f`を展開できるため、analytic product/chain ruleの対象である。

`local`はmaterialized logical fieldである。

```formurae
local f = u * u
∂_x f
```

後続の`∂_x f`は保存済みsampleへの微分であり、`u * u`へ戻ってchain ruleを適用しない。
これは名前に基づく特例ではなく、`f`がStepLocalLifetimeのFieldIdを持つことから導く。

### 5.3 Materialization contract

`local`は次を保証する。

- RHSをconsumerより前にlogical fieldへmaterializeする。
- tensorの全canonical storage componentを一つのbundleとして扱う。
- componentごとのphysical placementをpolicyとbasisから導く。
- 後続参照をRHSへinlineしない。
- `local` actionをsource順に実行する。
- RHSから参照できる`local`を、source上で前にmaterialize済みのものに限る。
- forward referenceとcycleをsource位置付きで拒否する。
- assignment時に暗黙resampleしない。

backendはlifetimeが重ならないbufferの物理再利用を行ってよいが、`local` barrierを越えるinline、
recompute、微分の解析展開、observableなaction順序の変更を行ってはならない。将来topological reorderを
導入する場合は別のeffect-order specificationを先に定める。

## 6. Conservative flux without `fluxDiv`

materialized rank-1 face fieldとplacement-aware derivativeを用いて保存divergenceを表す。

```formurae
local F_i @ primal = face_flux_i

u' =
  u - dt * contractWith (+) (∂_i F_i)
```

またはordinary library operatorを使う。

```formurae
u' = u - dt * divg F
```

保存contractが成立する条件は次である。

- `F`はshape `[dimension]`、dfOrder 0のrank-1 tensor。
- component `i`はaxis `i`の対応faceにLocatedである。
- `F`は一つの`local`として先にmaterializeされる。
- divergenceはface-to-cell Yee differenceを用いる。
- 異なるcomponent placementを暗黙補間しない。
- 隣接cellは同一のstored face sampleを符号反対で参照する。

この条件をtensor/placement checkerが検査することで、`fluxDiv`専用surface constructorの役割を
置換できる。placementだけから任意のinline expressionを自動的にfluxと認定してmaterializeしては
ならない。保存contractを必要とするfluxはnamed `local`にする。

これは、compilerが偏微分方程式中の任意の`divg`を見つけて`fluxDiv`へ文字列置換するという意味では
ない。通常のtensor/form type check後に、operandがmaterialized Primal face fieldであると分かった
`divg`をface-to-cell differenceへlowerするという意味である。例えば`divg (nonlinear_inline_expr)`を
見てcompilerがflux storageを発明することはしない。

同じfaceをperiodic pairとして共有するdownstream boundary contractまで含めれば、face contributionは
telescopeする。ただしFormurae compiler単体は現時点でboundary設定を読まないため、これはFormuraまで
含めたend-to-end条件付き結果であり、Formuraeの静的保証ではない。wall、Dirichlet、no-flux等の
大域保存もboundary contractを含めて初めて保証できる。

### 6.1 Complete target-language example

次は本設計をすべて実装した後の2次元拡散programである。quoted derivative、indexed `local`、
Primal placement、通常の`divg`だけで保存形を表す。

```formurae
-- du/dt + div(q) = 0, q = -kappa grad(u)

mode collocated
dimension 2
axes x, y

param κ = 1.0
param dt = 0.1*dx*dx

extern exp
raw gauss = fun(x,y)
  exp(-((x-(total_grid_x*dx/2))/(5*dx))**2
      -((y-(total_grid_y*dy/2))/(5*dy))**2)

field u : scalar @ primal

init:
  u = gauss(i*dx,j*dy)

step:
  local q_i @ primal =
    [| -κ * `(∂_x u),
       -κ * `(∂_y u) |]_i

  u' = u - dt * divg q
```

`u`はPrimal 0-componentなのでcellにあり、各quoted derivativeは対応axisだけを反転してfaceへ行く。
`q_i @ primal`はそのface値を一度materializeする。`divg q`は保存済みの同じface sampleを両隣のcellで
反対符号に使う。`q`の参照はRHSへinlineされないため、外側の微分が`-κ * ∂u`へ戻ってchain ruleを
適用することもない。

ここで`κ`はparameterなので任意のfaceで評価できる。`κ`自体がcell fieldなら、そのface値をどう作るかは
一意でないため、明示reconstruction / `resample`なしではplacement errorにする。

## 7. Operator surface

surface名、library名、internal primitiveを分けて整理する。

| Current surface | Target surface | Final surface status | Internal status |
|---|---|---|---|
| `gridD_x(e)` / `gridDerivative_x(e)` | `` `(∂_x e) `` | remove | grid-whole loweringは保持 |
| `orderedD(e,x,y)` / alias | nested quoted derivatives | nesting採択後remove | ordered chain nodeは保持 |
| `fluxDiv(F)` / `conservativeDiv(F)` | typed face `local` + `divg` / indexed `∂` | remove | generic local/derivative planへ移す |
| `materialize(e)` | `local name = e` | remove | FEIR Materialize actionは保持 |
| `resample` / `interpolate` | `resample` | canonical名だけkeep | explicit resample primitiveを保持 |
| `∂'^m_x` | same | initial cutoverではkeep | coordinate-wide primitiveを保持 |
| `grad`, `dGrad`, `divg`, `curl`, `hessian`, `lap` | ordinary library definitions | keep as library | compiler special primitive不要 |
| `d`, `hodge`, `flat`, `sharp` | same | keep | typed form/metric semanticsを保持 |
| `codiff` / `delta` / `δ` | `δ` | derived canonical名へ統合 | metric adjoint loweringは保持 |
| `formLaplacian` | `Δ_H` | remove reserved name | form Laplacian graphを保持 |
| `lb` | scalar `Δ u = -δ(d u)` | structural lowering後remove | conservative metric planを保持 |

alias整理では少なくとも次を削除する。

- `gridDerivative`
- `orderedDerivative`
- `conservativeDiv`
- `interpolate`
- `dForm`
- ASCII `delta`

`grad`や`divg`をlibraryから削る必要はない。これらは短い数学的関数であり、特殊な離散primitiveを
増やさない。ユーザーが同名`def`でshadowできる性質も維持する。

## 8. `d`, Hodge star, `δ`, and `Δ`

### 8.1 Continuous convention

向き付けられたRiemannian `n`-manifold上の`k`-form `A`に対し、本設計は現行Formuraeと同じ
codifferential conventionを使う。

\[
  \delta_k A =
  (-1)^{n(k+1)+1}\star d\star A.
\]

Hodge--de Rham Laplacianは、

\[
  \Delta_H A = d(\delta A) + \delta(dA).
\]

0-form `u`では`δu = 0`なので、

\[
  \Delta_H u = \delta(du).
\]

一方、現行FormuraeのPDE用`lap = div grad`と`lb`は、

\[
  \Delta_{\mathrm{PDE}}u = -\delta(du)
\]

に対応する。本設計では`Δ_H`をnonnegative Hodge Laplacian、scalar `Δ`を従来の
`div grad = -δd`として区別する。これにより既存PDE exampleの数値符号を維持する。general formには
`Δ_H`を使い、符号の異なる`Δ`をoverloadしない。

概念surface definitionは次である。degree-dependent signはform typeから得る。

```formurae
def δ A =
  sign(dimension, degree(A)) * hodge (d (hodge A))

def Δ_H A =
  d (δ A) + δ (d A)

def Δ u =
  0 - δ (d u)
```

`degree(A)`と`sign`は説明用であり、実装ではdfOrderとdimensionからlibrary内部で構成する。

### 8.2 Typed signatures

概念型を次とする。

```text
d:
  Form<n,k,policy,geometry,orientation>
  -> Form<n,k+1,policy,geometry,orientation>

hodge:
  Form<n,k,policy,geometry,orientation>
  -> Form<n,n-k,flip(policy),geometry,orientation>

δ:
  Form<n,k,policy,geometry,orientation>
  -> Form<n,k-1,policy,geometry,orientation>

Δ_H:
  Form<n,k,policy,geometry,orientation>
  -> Form<n,k,policy,geometry,orientation>
```

`k=0`の`δ`はzeroとする。canonical sorted basis、permutation sign、complement basis、
Primal/Dual orientationをすべて型・tensor metadataから検査する。

## 9. Why variable-metric `δ` and `lb` remain internal effects

### 9.1 Codifferential

連続式`δ = ±⋆d⋆`は正しい。しかし離散Hodge starは単なるpointwise unary functionではない。
metricとprimal/dual cell measureを含むmass mapである。

離散`d`をincidence matrix `D_k`、degree `k`のHodge/mass matrixを`M_k`とすると、
discrete codifferentialは符号・orientation conventionを除いて、

\[
  \delta_k =
  M_{k-1}^{-1}D_{k-1}^{T}M_k
\]

でなければならない。

したがってvariable metricでは次が必要である。

1. source form componentと内側Hodge coefficientを同じplacementで評価する。
2. coefficient付きsourceをwhole expressionとして差分する。
3. result basisごとのorientation signを保持する。
4. outer Hodge coefficient / volumeをresult placementで適用する。
5. coefficient、weighted flux、resultのlifetimeと依存順を保持する。
6. 最初と最後のstarをPrimal→Dual、Dual→Primalの対応するmapとして扱う。

pure Egison expressionへ完全展開すると、`d(cA)`がanalytic product ruleで
`(dc)A + c(dA)`へ変形され、選択した`D`のmass-adjointであるという離散contractを失う。
よってvariable geometryではcanonical `δ A`を現行`codiff.metric@1`へlowerする。explicit
`hodge (d (hodge A))`は符号とweighted-adjoint identityを安全に回復できるtyped
`AdjointExteriorDerivative` graphが入るまで、variable geometry上で明示診断にする。constant metricでは従来どおり
pureな数学的合成として評価できる。

### 9.2 Laplace--Beltrami

orthogonal metricのscale factorを`h_i`、volume factorを
`V=\prod_i h_i`とすると、

\[
  \operatorname{lb}u =
  \frac{1}{V}
  \sum_i
  \partial_i
  \left(
    \frac{V}{h_i^2}\partial_i u
  \right).
\]

保存的な離散実行順は次である。

```text
cell u
  -> cell-to-face first difference
  -> face coefficient V/h_i^2
  -> materialized face flux
  -> face-to-cell divergence
  -> cell coefficient 1/V
```

現行`lb.orthogonal@1`はこのnearest-neighbor forward/backward Yee pairと補助field scheduleを
固定する。Collocatedのpure `-δ(d u)`を通常のcentered derivativeとして単純展開すると、
内側と外側の中心差分が合成され、`u[i±2]`と`C[i±1]`を参照するstride-2 stencilになる。
連続式は等しくても、halo、boundary closure、profile依存性、face flux共有は同じではない。

したがって`lb`というsurface名を削除しても、`-δ(d u)`を同じconservative metric planへ
構造lowerする処理はcorrectness semanticsとして残す。これは任意のpeephole optimizationではない。

### 9.3 Long-term internal form

長期的には`codiff.metric@1`と`lb.orthogonal@1`を、次の情報を持つtyped operator graphまたは
`weighted-adjoint-d` primitiveへ統合できる。

- GeometryId
- dimension / form degree / result basis
- source policyとcomponent placement
- orientation
- selected incidence/derivative family
- inner/outer Hodge coefficient
- coefficient / flux / result auxiliary roles
- boundary domain

generic graphが同じeffectとscheduleを表せるまでは、既存internal primitiveを削除しない。

## 10. Boundary conditions and guarantees

`δ`が`d`のadjointになるという主張にはoperator domainが含まれる。境界がある場合、
Green formulaにはboundary trace termが残る。

初版で保証できるのは次までとする。

- interiorでのtyped placement consistency
- 同じinterior face sampleを隣接cellが反対符号で使うflux-difference structure
- boundaryを除くstencil上のformal/discrete adjoint structure
- `d^2=0`の構造検査

現在のFormurae/FEIRはFormura側のYAML boundaryを読まない。したがってperiodic domainでの大域的な
telescopingは、YAML boundary、生成stencil、実行backendを合わせたend-to-end testで確認する条件付き
性質であり、Formurae compiler単体のcompile-time guaranteeには含めない。mirror ghost fillも任意の
staggered face fluxに対するno-flux条件と同義ではなく、fixed boundaryは一般に外部とのexchangeを持つ。

Dirichlet、Neumann/no-flux、absolute/relative form boundary等について大域保存、symmetry、
positive semidefinitenessを保証するには、Formurae surfaceまたはversioned backend contractに
boundary conditionを含めなければならない。

boundary syntax自体は本書の実装scope外とする。ただし将来設計では次を満たす。

- field/component/form traceごとにboundary domainを型付けする。
- Formura側のghost-fill設定との二重指定を禁止する。
- no-fluxでface fluxを直接制約できる。
- Primal/Dualのnormal/tangential traceを区別する。
- discrete adjoint testにboundary contributionを含める。

現在のownerはFormura側設定で確定している。§14の`BC-OWNER`は、将来Formuraeへtyped boundary
contractを導入するときのownershipを決める項目であり、初回実装の未確定挙動を意味しない。

## 11. Compiler and IR architecture

### 11.1 Surface AST

`TensorExpr`へgeneric quote nodeを追加せず、意味の確定したnodeを追加する。

```text
TEGridDerivativeChain
  SourceSpan
  [AxisRef]
  TensorExpr
```

parserは `` `(∂_x e) `` を直接このnodeへする。nested formはparse後にaxis列へflattenする。
generic CAS quoteは既存経路のままにする。

`local`は`Step + IndexedTarget`のspecial caseを拡張し続けるより、最終的には次の情報を持つ
declaration nodeへする。

```text
LocalDecl
  target
  tensor kind / degree
  GridPolicy
  RHS
  SourceText
```

微分形式については、normalized scalar式から`⋆d⋆`を探し直さない。実装した
`Pre.FormOperator`はname resolution後、Egisonへ渡す前にcanonical unary `d` / `hodge` / `δ` / `Δ` /
`Δ_H`と、exact scalar identity `0 - δ(d u)`をscope-awareに認識する。modeとgeometryでpure mathematical
compositionまたはtyped internal requestを選ぶ。indexed Kronecker `δ~i_j`、user-shadowed name、
algebraic near missはcanonical operatorとして扱わない。

`Pre.TypeCheck`はEgisonのcomponentwise liftingより先にoperand kindを検査する。quoted derivativeと
scalar `Δ`はstatically known scalarだけを受け取り、`d` / `hodge` / `δ` / `Δ_H`はscalarまたは
宣言済み`k-form`だけを受け取る。ordinary vector/full/symmetric/antisymmetric tensorはformへ暗黙変換
しない。現行surfaceのuser `def` parameterには型annotationがないため、parameterのkindを証明できない
helper内でこれらのtyped operator boundaryを越えることも拒否する。field、typed local、先行するscalar
`let`をoperandにする通常の記述は静的に判定できる。

canonical operatorは単項の直接適用だけを許し、first-class alias、高階引数、誤ったarityからtyped
boundaryを迂回できないようにする。user definitionがcanonical名、scalar intrinsic、`.`をshadowした
場合は組み込みの返値kindを流用せず、通常のuntyped callとして扱う。type checkerは特殊AST nodeの
全childも走査し、`local`、field update、CAS initializerでは宣言kindと静的に判明したRHS kindを照合する。
特に`0-form`をscalarへ暗黙変換してscalar-only operatorへ渡すことはしない。この規則はfrontendの
静的kindに関するものであり、Egisonがgenerated rank-zero tensorの唯一のcomponentをruntime scalarとして
返す表現とは独立である。ただしcollocated modeのexact `0 - δ(d u)`は、他passと同じscope-aware matcherで
canonical scalar `Δ`として扱う。metric scale、
embedding、`assert-dd-zero`も同じ検査境界に含め、geometryで従来許可しているgeneric CAS quoteはraw
fallbackとして維持しつつ、その中のcanonical operator利用は拒否する。

constant metricではcanonical callをpure Egison式へemitする。variable metricの`δ`とscalar `Δ`はidentityを
保ったopaque requestへemitする。general expression全体を表す再帰的`TypedFormExpr`は、variable metric
general `Δ_H`とgeneric weighted-adjoint graphを実装するときの次期IRとし、今回のsurface cutoverには
導入しない。

### 11.2 pre-fec

pre-fecは次を担当する。

- quoted derivativeのexact parse、axis resolution、source span
- nesting flattenとaxis order preservation
- analytic/discrete effect separation
- step `let`のeffectとvariable-metric operator pathのsource-order propagation
- localのscope、rank、variance、degree、policy
- local LogicalFieldDecl / FieldId / StepLocalLifetime
- free-indexとplacement consistency diagnostics
- 廃止surface名にcompiler special caseを残さないname resolution
- scalar/tensor/form operator kindとform degreeの検査
- Egison bridge call生成

### 11.3 Egison normalization

Egisonは通常の`∂`にだけanalytic differentiationを行う。grid chainはopaque bridgeとして
operandとaxis列を保持する。

opaque bridgeの構築能力はgenerated normalization libraryだけが持つ。definition、step、initializer、
metric、embeddingを含むuser sourceは、structured式とraw Egison fallbackのどちらであっても、
`functionSymbol`、`formuraeOpaqueBarrier`、`FormuraeInternal*`、trusted `Formurae` / `FEIR`
namespaceを参照できない。この検査は各grammarの分岐より前にsource全体へ行い、commentと
診断用string内の同名textはidentifierとして扱わない。これによりcomputed stringから任意の
internal FunctionDataを作る経路と、generated bridgeをsurfaceから直接呼び出す経路を切り離す。

raw Egison fallbackはapplication treeを持たないため、variable metric上でcanonical `hodge`と`d`の
両方を直接または先行helper経由で参照するbodyを保守的に拒否する。structured expressionでは
`hodge -> d -> hodge`の順序付きsemantic pathをuser definitionとstep `let`越しにも伝播し、aliasで
weighted-adjoint guardを迂回できないようにする。user-shadowed canonical名はこのtagを持たない。
`contractWith`のreducerとuser-defined `.`も通常のfunction applicationと同様にeffectとmetric semantic
pathを伝播し、高階適用の内側へ離散operationやweighted-adjoint pathを隠せないようにする。

`d` / `hodge` / `δ` / `Δ`については、

- constant metricでpure compositionとして安全な部分はnormalizationしてよい。
- variable metricのAdjointD / Laplacian graph identityは消してはならない。
- storageやoffsetをEgisonのFieldJetへ埋め込まない。

### 11.4 FEIR

初回実装ではwire互換を利用できる。

- axis列長1: `derivative.grid-whole@1`
- axis列長2以上: `derivative.ordered@1`
- materialized local: 既存`Materialize` actionとStepLocalLifetime field
- variable metric`δ`: `codiff.metric@1`
- scalar metric`Δ`: `lb.orthogonal@1`

surface名を削除しても、この内部OpIdを同時に削除する必要はない。後続のFEIR cleanupで、
`grid-whole`と`ordered`を一つの`derivative.grid-chain`へ統合するかを決める。

現行`derivative.grid-whole@1`と新しいchain nodeはいずれも、operandからsource capabilityとnatural
targetを決める。consumerや`local` LHSのplacementをpayloadへ逆流させない。将来、明示target付き
derivativeが必要になった場合は、この規則を曖昧に拡張せず、source/target policyを持つversioned
operationとして別途追加する。

### 11.5 post-fec

post-fecは次を担当する。

- source/target placementからのcentered/Yee stencil選択
- grid chainの順序付きfixed stencil合成
- tensor local component storageとsource-order schedule
- `Materialize`と`UpdateField`を分離せず、FEIR actionと同じ単一のordered assignment streamとして出力
- face fluxからcell divergenceへのplacement-aware lowering
- geometry coefficient/volumeのdedup
- AdjointD / Laplacian auxiliary plan
- boundary contractが導入された後のhalo/closure検査

FEIR validationは`UpdateField`のtargetをwhole-fieldに限定する。component targetはraw initializer専用で、
一部componentだけをNextTimeへ書いて未定義の残りを読むprogramは受理しない。可変計量scalar `Δ`の
backend planは、source-order上ですでに生成済みならCurrentTimeだけでなくNextTime fieldもsourceに
できる。

### 11.6 Implemented architecture and remaining limitation

実装後の構成は次である。

- `TensorExpr`は`TEGridDerivativeChain`を持ち、exact quoted formをraw Egison fallbackより前にparseする。
  入れ子はinnermost-firstのaxis列へflattenし、順序と重複を保持する。
- tensor literalはstructured component ASTとして保持され、`[| e_x, e_y |]_i`をhelper関数なしで
  typed localへ渡せる。
- `LocalDecl`はindex、tensor kind/form degree、policy、source位置を保持する。registryとemitterはfieldと
  同じtype/layout/component projectionを再利用し、FEIR `Materialize` actionへsource順にencodeする。
- symmetric/antisymmetric declarationはstorage projectionだけでなく、normalization済みwhole rank-2
  tensorの全`(i,j)`成分について`A_ij = A_ji` / `A_ij = -A_ji`をmaterialize/update境界で検査する。
- post-fecは`Materialize`と`UpdateField`を単一のstep assignment列で保持する。これにより、先行する
  `NextTime`更新をlocalが読み、そのlocalを後続更新が読む場合もFEIRのsource順どおりになる。
- 保存fluxはmaterialized Primal face localへの通常の`divg`からface-to-cell differenceへlowerする。
  旧opaque flux-divergence requestと旧opaque materialization requestは削除した。
- canonical form resolverはscope、mode、degree、geometryをEgison normalization前に検査する。
  constant metricの`δ`、`Δ`、`Δ_H`は数学的合成へ、variable metricの`δ`とscalar `Δ`はそれぞれ
  internal `codiff.metric@1`、`lb.orthogonal@1`へlowerする。
- variable metricのexplicit `hodge (d (hodge A))`はanalytic product ruleへ流さず、weighted discrete
  adjointを保つcanonical `δ A`を要求するsource位置付き診断にする。このpathはuser helperとstep
  `let`越しにも追跡する。
- `grid-whole`、ordered chain、coordinate-wide、explicit resample、metric codifferential、
  orthogonal Laplace--Beltramiのspecialized internal primitiveは維持する。
- user definitionはstructured/rawの両経路でinternal opaque constructorとgenerated bridgeを参照できず、
  opaque semantic identityを作れるはtrusted generated libraryに限定する。
- indexed Unicode `δ~i_j`はASCII `delta`へ字訳せず、dimensionから構造生成したcompiler-owned
  Kronecker tensorを参照する。従ってordinary user function `def delta ...`と衛生的に共存する。
- boundary/ghost contractは従来どおりFormuraが所有する。

variable metric上のgeneral form `Δ_H = dδ + δd`は、現行FEIRではmaterialized `δ` resultへさらに`d`を
正しく作用させるtyped operator graphを表現できない。この組合せをpure expressionへ誤展開せず、
source位置付きで明示的に拒否する。variable metricのgeneral `Δ_H`はweighted-adjoint graph導入後の
拡張事項であり、variable metric `δ`とscalar `Δ`は今回実装済みである。

## 12. Implementation record

以下のphase順で実装し、最終cutoverではcompatibility aliasやdeprecated pathを残さなかった。
旧surface名をuser-defined ordinary function名として使うことはできるが、compiler special caseや
旧primitiveへのloweringは行わない。

| Phase | Result |
|---|---|
| quoted derivative / ordered chain | implemented |
| indexed/tensor/form local | implemented; fieldと同じ全layoutを共有 |
| symmetric/antisymmetric relation check | implemented at normalization boundary |
| conservative face local + `divg` | implemented |
| old surface/opaque primitive removal | implemented |
| canonical `d` / `hodge` / `δ` / `Δ` / `Δ_H` | implemented |
| scalar/form static operator kind check | implemented; untyped helper boundaryはreject |
| indexed Kronecker `δ` hygiene | implemented independently of ASCII `delta` |
| variable metric `δ` / scalar `Δ` | implemented with existing internal plans |
| variable metric general form `Δ_H` | explicit diagnostic; typed weighted graphまでdeferred |
| boundary syntax | out of scope; Formura ownershipを維持 |

periodic 1D/2D diffusion examplesは`local q_i @ primal`にquoted gradientをmaterializeし、通常の
`divg q`で更新する保存flux形へ移行した。各exampleのC numerical checkは一周期全cellの
mass sumが時間発展前後で保存されることを検証し、face sampleの隣接cell間cancellationを1D/2Dで
end-to-endに固定する。

### Phase 0: Frozen decisions

1. nested quoted derivativeを採択し、`orderedD` surfaceを削除した。
2. `∂'^m_x`を残した。
3. localはformとsymmetric/antisymmetricを含むfield grammar全体を対象にした。
4. surface `lb` / `codiff`を同じcutoverで削除し、必要なinternal loweringだけを残した。

decision example、exact stencil、sign conventionはgolden/focused testで固定した。

### Phase 1: Parse and represent quoted derivative

主要ファイル:

- `fec/src/Formurae/TensorExpr.hs`
- `fec/src/Formurae/Pre/Parse.hs`
- `fec/src/Formurae/Pre/Registry.hs`
- `fec/src/Formurae/Pre/Effect.hs`
- `fec/src/Formurae/Pre/EmitEgison.hs`

作業:

1. `parseModel`のtransliteration後もbackquoteとoriginal-column mapを保持する。
2. token depth handlingへbackquote付きouter groupを追加する。
3. `TEGridDerivativeChain`とpattern/export/render/preprocess supportを追加する。
4. exact derivative-root形だけをparseし、generic`TEQuote`は追加しない。
5. inner coordinate derivativeをpreprocess後の`pd1r1_axis`表現まで追跡し、fixed axisをAxisIdへresolveする。
6. `Pre/Registry.collectDefinitionCalls`等のexhaustive `TensorExpr` traversalへ新nodeを追加する。
7. single chainを`FormuraeInternalGridWholeDerivative`へemitする。
8. source mapをbackquote、outer parentheses、inner derivative、operandへ保持する。
9. raw-Egison fallbackより前に必ず認識する。
10. generic quoteを従来受理するcontextだけのregression testを追加する。
11. expected placementからgrid derivativeをretargetせず、natural targetとの一致だけを検査する。

test:

- analytic `∂_x(u*u)`とquoted formが異なるFEIR/FMRになる。
- quoted formがcurrent `gridD_x`とbyte-equivalentなstencilになる。
- unknown axis、malformed parentheses、tensor operandをsource位置付きで拒否する。
- quoted derivativeがEgison`Quote`としてFEIR境界へ残らない。
- Collocated sourceを`local ... @ primal`へ代入してもYee derivativeへ暗黙変更されない。

### Phase 2: Nested chain and `orderedD` migration

主要ファイル:

- `fec/src/Formurae/TensorExpr.hs`
- `fec/src/Formurae/Pre/Effect.hs`
- `fec/src/Formurae/Pre/EmitEgison.hs`
- `lib/formurae-operators.egi`
- `lib/formurae-feir.egi`
- `fec/src/Formurae/Post/PrimitiveContract.hs`
- `fec/src/Formurae/Post/ExplicitStencil.hs`
- `fec/src/Formurae/Post/Compile.hs`

`derivative.ordered@1`のwire contractをそのまま再利用する限り、`lib` / `Post`側はauditと同値testが
中心であり、production変更は必須ではない。manifestやpost-fecを変更するのはgrid-chainへwire統合する
場合だけとする。

作業:

1. nested quoted derivativeをinnermost-first axis列へflattenする。
2. axis順と重複をsemantic keyへ保持する。
3. analytic derivative of grid-chainを明示errorにする。
4. single chainとmulti chainのplacement transitionを検査する。
5. `orderedD` examples/testsをnested syntaxへ移す。
6. `orderedD` / `orderedDerivative`をreserved names、rewriter、docsから削除する。

test:

- `[x,y]`と`[y,x]`が別semantic keyを持つ。
- `[x,x]`がdirect`∂^2_x`と異なるstencilを生成する。
- Collocated cross stencil、Primal/Dual placement toggle、target mismatch。
- model accuracy 4をbypassするfixed-v1 contract。
- `local`を挟むとchain flattenしない。

### Phase 3: Indexed/tensor local

主要ファイル:

- `fec/src/Formurae/Syntax.hs`
- `fec/src/Formurae/Pre/Parse.hs`
- `fec/src/Formurae/Pre/Registry.hs`
- `fec/src/Formurae/Pre/EmitEgison.hs`

既存tensor/form materialization capabilityのaudit対象:

- `fec/src/Formurae/FEIR/Syntax.hs`
- `fec/src/Formurae/FEIR/Codec.hs`
- `fec/src/Formurae/FEIR/Validate.hs`
- `fec/src/Formurae/Post/BackendPlan.hs`
- `fec/src/Formurae/Post/Compile.hs`

作業:

1. current「local target cannot have indices」制限を削除する。
2. LocalDeclへindex group、kind/degree、policy、SourceTextを保持する。
3. `validateDimensionFeatures`をlocal kind/formにも適用する。
4. fieldと同じtensor type/layout constructionとcanonical projectorをlocalへ共有する。
5. registryの固定`Collocated scalar` / basis `[]` local生成をdescriptor-drivenに置換する。
6. `KLocal`の固定`EncodeScalar`、空index、`ScalarValue`生成をLHS typeに応じた
   `EncodeScalar` / `EncodeTensor`、`ScalarValue` / `TensorValue`へ置換する。
7. generated local declarationへindexed tensor引数とmetadataを渡す。
8. FEIRの既存`Materialize TensorValue`、StepLocalLifetime、independent basis projection、
   `compileMaterialization`を再利用し、不足分だけを変更する。
9. action source順を維持し、未materialize localへのforward referenceとcycleをpre-fec/FEIRで拒否する。
10. placement mismatch、mixed policy、primed/local lifetime違反を診断する。

test:

- scalar/vector/rank-2/form local。
- up/down variance mismatch。
- Primal/Dual component placement。
- symmetric/antisymmetric projectionを対象に含める場合のcanonical storage。
- local参照がRHSへinlineされない。
- materializationがconsumerとhalo useより前に出る。
- source順が保持され、forward local referenceがsource位置付きで拒否される。
- buffer lifetimeと複数consumer reuse。

### Phase 4: Remove `fluxDiv` and `materialize` surface

作業:

1. materialized face tensorへのindexed derivative / `divg` loweringを検証する。
2. old`fluxDiv`とnew local+divergenceのFMRを比較する。
3. rank、dimension、dfOrder、component face placement検査を通常tensor checkerへ移す。
4. `shallowwater` / `euler_sod`のscalar local patternをindexed fluxへ一般化するtestを追加する。
5. `fluxDiv` / `conservativeDiv` / `materialize`をsurface、rewriter、standardNamesから削除する。
6. 不要になった`flux.conservative-divergence@1`と
   `operator.materialized@1` opaque operationをmanifestから削除する。step schedulingに使う
   `FEIR.Materialize` actionは削除しない。
7. manifest変更時は`runghc -ifec/src tools/generate-feir-primitives.hs`でbindingsを再生成し、
   `runghc -ifec/src tools/generate-feir-primitives.hs --check`で確認する。generated fileを手編集しない。

test:

- downstream periodic boundaryを含む1D/2D end-to-end mass balance。
- 同一face sampleの隣接cell cancellation。
- inline nonmaterialized fluxを保存fluxとして自動認定しない。
- wrong face placementとimplicit interpolationを拒否する。
- higher-rank fluxはdivergence axis contractが決まるまで拒否する。

### Phase 5: Migrate `gridD` surface

1. `ks3d`等の`gridD`使用箇所をquoted derivativeへ移す。
2. `gridD` / `gridDerivative`をreserved names、rewriter、README、gallery、testsから削除する。
3. internal`derivative.grid-whole@1`はquoted syntaxのlowering先として残す。
4. removed nameを通常のuser definition名として再利用可能にするか、明示unknown-function errorにする。

### Phase 6: Typed `d` / `hodge` / `δ` / `Δ` graph

実装結果: canonical operatorとexact scalar identityに必要なtyped boundaryを
`Pre.FormOperator`として実装した。以下のfull recursive graph項目のうち、variable metric general
`Δ_H`にだけ必要な部分は次期IRへdeferし、その組合せは明示診断にした。

主要ファイル:

- `fec/src/Formurae/TensorExpr.hs`
- `fec/src/Formurae/Pre/Registry.hs`
- `fec/src/Formurae/Pre/Effect.hs`
- `fec/src/Formurae/Pre/EmitEgison.hs`
- `lib/formurae-operators.egi`
- `lib/formurae-geometry.egi`
- `lib/formurae-feir.egi`
- `fec/src/Formurae/Post/Geometry.hs`
- `fec/src/Formurae/Post/Location.hs`

作業:

1. dimension、degree、policy、geometry、orientation contractを固定する。
2. name resolution後、standard libraryの`d` / `hodge` / `δ` / `Δ`だけをtyped form operatorとして
   elaborateする。user shadowingした同名関数は通常callのままにする。
3. Egison normalizationより前に`ExteriorD`、`Hodge`、`Add`、`Scale`を持つtyped form graphを作る。
4. `d`のbasis signとdegree transition、`d^2=0`を維持する。
5. Hodge complement basis、policy flip、coefficient sampling、star-star identityを検査する。
6. constant metric `δ = ±⋆d⋆`はtyped graphからpure compositionへemitしてよい。
7. scalar`Δ`とform`Δ_H`の符号をtestで固定する。
8. variable metricではAdjointD / Laplacian identityをpure ScalarNFへ消さず、typed graphのままemitする。

### Phase 7: Structural variable-metric lowering

実装結果: variable metric `δ`とscalar `Δ`をnormalization前に認識し、既存の
`codiff.metric@1` / `lb.orthogonal@1`へ直接lowerした。general variable-metric `Δ_H`は
weighted-adjoint graph未導入のため拒否する。

主要ファイル:

- `fec/src/Formurae/Pre/Effect.hs`
- `fec/src/Formurae/Pre/EmitEgison.hs`
- `spec/feir-primitives-v1.sexp`
- `fec/src/Formurae/FEIR/PrimitiveBindings.hs`
- `fec/src/Formurae/Post/BackendPlan.hs`
- `fec/src/Formurae/Post/Compile.hs`

作業:

1. normalization前に保持したtyped `Hodge(D(Hodge(A)))` graphをAdjointD requestへlowerする。
2. typed scalar`-δ(d u)` graphをconservative Laplace--Beltrami requestへlowerする。
3. 初回wireではcurrent`codiff.metric@1` / `lb.orthogonal@1`をemitし、同じcoefficient、flux、result
   scheduleを生成する。normalization後のScalarNFをpattern matchしてidentityを再発見しない。
4. post plannerがcoefficient、weighted flux、resultのhygienic auxiliary field/actionを生成し、
   user definitionから直接step actionを生成させない。
5. multiple requestのcoefficient dedupとsource別flux/result bundleを維持する。
6. orthogonal geometry verificationをgateにする。
7. equivalence確立後に`codiff`、`formLaplacian`、`lb`を予約surface名から削除する。
8. internal primitiveをgeneric weighted-adjoint nodeへ統合する場合だけmanifest/bindings/postを同時更新する。

test:

- current metric 5 examplesの数値schemeとhalo topology。
- metric codiffの全degree/result basis。
- discrete mass-adjoint identity。
- scalar`Δ`とold`lb`のsign/stencil equivalence。
- coefficient/volume persistent lifetime、flux/result step lifetime、dedup。
- nonorthogonal/unverified geometry rejection。

### Phase 8: Documentation and final cutover

1. README、DSL-DESIGN、gallery、全examplesを新surfaceへ更新する。
2. removed aliasesを検索し、source/docs/generated fixturesから除去する。
3. old syntax rejection diagnosticsを追加するが、compatibility loweringは追加しない。
4. full pre-fec→Egison→FEIR→post-fec testと全example buildを実行する。
5. tracked exampleの`.egi` / `.feir` / `.fmr`、gallery生成物、golden fixtureを新仕様へ更新する。
   regeneration前にworktreeを確認し、無関係な既存変更を上書きしない。
6. generated primitive manifest、bindings、fingerprintを更新する。
7. 次を最終gateとして実行する。

   ```sh
   runghc -ifec/src tools/generate-feir-primitives.hs --check
   cabal build
   make compiler-tests
   make formurae-operator-tests
   make all
   ```

8. 本書のStatusをImplementedへ変更し、未決事項の最終決定を記録する。

## 13. Acceptance criteria

実装完了条件は次である。

### Derivative

- ordinary`∂`はanalytic product/chain ruleを維持する。
- quoted derivativeはwhole-expression sampleを行い、`gridD`と同じv1 stencilになる。
- nested quoted derivativeはaxis順・重複を保持し、中間storageを作らない。
- direct higher derivativeとrepeated grid chainが区別される。
- source/target placementとprofile bypassが仕様どおりである。

### Local/storage

- indexed/vector/tensor/form localが一つのlogical field bundleとしてmaterializeされる。
- localのrank、variance、degree、policy、component placementが静的検査される。
- local参照はRHSへ再展開されない。
- user field updateより前に依存localがscheduleされる。
- implicit resampleを行わない。

### Conservation

- materialized face fluxの内部face contributionが隣接cell間で相殺する。
- downstream periodic boundaryを含むend-to-end mass testがroundoff範囲で保存する。
- wrong placement、nonmaterialized inline flux、unsupported higher-rank divergenceを拒否する。
- boundaryなしの結果を大域保存保証と誤記しない。

### Differential forms and geometry

- 全degreeで`d`のsignと`d^2=0`が成立する。
- Hodgeがdegreeとpolicyを反転し、orientation signを保持する。
- constant metric`δ`が`±⋆d⋆`と一致する。
- variable metric`δ`が選択済み`d`のmass-adjointになる。
- scalar`Δ`の符号とold`lb`との関係が固定される。
- metric coefficient、volume、flux、result lifetimeとdedupが維持される。

### Migration

- `gridD`、`fluxDiv`、`materialize`と採択済み削除aliasがsurface standardNamesに残らない。
- examples/docs/testsに旧spellingが残らない。
- no deprecated path / compatibility shim。
- generated FEIR/FMR、diagnostic provenance、manifest fingerprintが一貫する。

## 14. Final decisions and future extensions

今回のcutoverで次を確定した。

1. **QD-NEST**: 採択。nested quoted derivativeをordered chainへflattenし、`orderedD` surfaceを削除。
2. **WIDE**: per-occurrence `∂'^m_x`を維持。
3. **LOCAL-SCOPE**: form、symmetric、antisymmetricを含むfield declaration全体を採択。
4. **FLUX-TYPE**: 初版はtyped lifetime、rank、dfOrder、Primal component placementで認定。
5. **D-DISCRETE**: 現行DEC `d`とsampled derivativeの既存mode境界を維持。
6. **BC-OWNER**: Formura backendが所有。Formuraeはinterior operatorだけを生成。
7. **METRIC-NAMES**: `codiff` / `lb`の予約surface名を削除。canonical `δ` / `Δ`からinternal planへlower。
8. **IR-CONSOLIDATION**: specialized `codiff.metric` / `lb.orthogonal`を今回維持。

将来拡張として残るのは、higher-rank fluxのdivergence-axis refinement、typed boundary domain、
variable metric general `Δ_H`を表すweighted-adjoint graph、specialized metric primitiveの統合である。
これらは今回実装した構文のcompatibility shimではなく、新しい型・IR contractを必要とする独立設計とする。
