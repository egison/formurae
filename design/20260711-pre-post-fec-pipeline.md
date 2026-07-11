# pre-fec / post-fec 二段コンパイラ設計

Date: 2026-07-11

Status: Architecture accepted; FEIR v1 semantic subcontracts pending Phase 0

この文書は、Formurae コンパイラを数式処理の前後で `pre-fec` と `post-fec` に分割し、
Egison の評価結果を versioned な中間表現 FEIR (Formurae Egison IR) として受け渡す設計を
定める。

本設計は `20260711-egison-centered-grid-semantics.md` の follow-up である。同文書の
Phases 1--7 は現在の実装状態を記述している。本設計の cutover が完了するまでは同文書を
実装の記録として残し、cutover 後は本設計の pipeline と責務境界を正とする。

## 1. 結論

最終 pipeline は次の4段とする。

```text
model.fme
  -> pre-fec
       Formurae の parse / scope / declaration / source map
       Egison normalization unit の生成
  -> model.egi
  -> Egison
       tensor/index algebra / analytic differentiation / CAS normalization
       FEIR serialization
  -> model.feir
  -> post-fec
       placement analysis / stencil lowering / auxiliary-field planning
       Formura program emission
  -> model.fmr
  -> Formura
```

最終的な公開コンパイラ executable は `pre-fec` と `post-fec` の2つとする。旧 `fec`
executable や旧 schema readerを互換用に残さない。通常のbuildは Makefile が3コマンドを
順に実行する。

```sh
FORMURAE_DIR=/absolute/path/to/formurae
pre-fec model.fme > model.egi
tests/run_egison_strict.sh "$EGISON_DIR" \
  -l "$FORMURAE_DIR/lib/formurae-grid.egi" \
  -l "$FORMURAE_DIR/lib/formurae-tensor.egi" \
  -l "$FORMURAE_DIR/lib/formurae-geometry.egi" \
  -l "$FORMURAE_DIR/lib/formurae-operators.egi" \
  -l "$FORMURAE_DIR/lib/formurae-feir.egi" \
  model.egi > model.feir
post-fec model.feir > model.fmr
```

ordered load listはversioned normalization manifestとしてMakefileとtest runnerで共有する。
Egison passは成功時stdoutへ単一のcanonical FEIRだけを出し、diagnosticをstderrへ出す。
type/evaluation warningまたはerrorはnonzero exitにし、post-fecはFEIR外の余分なstdoutをhard errorにする。
現`run_egison_strict.sh`はstdout/stderrをまとめるため、Phase 2でmachine-output用にstreamを分離する。

この分割により、純粋な座標・tensor・form 演算子は Egison 本来の1行または数行の定義へ
戻せる。複雑さが残るのは stencil family、grid placement、補間、保存流束、補助fieldの
lifetimeなど、離散化・storageに本質的な処理だけである。

微分演算子の数学的定義と離散化精度も分離する。例えば4次精度Laplacianを別の数学演算子
`Δ4`として定義せず、同じ`lap`または`divg (grad u)`へmodel-level discretization profileを
適用する。

```formurae
mode collocated
discretization collocated derivative 2 centered accuracy 4

def Δ u = divg (grad u)
```

上の`accuracy 4`はsurfaceの`∂`を`∂'`へ置換しない。Egisonが合成を二階FieldJetへ正規化した後、
post-fecが要求精度を満たす最小radiusとexact rational coefficientを選ぶ。この順序により、
`divg (grad u)`をwideな一階差分の二重適用ではなくcompactな4次精度二階stencilへ落とせる。

## 2. 目標と非目標

### 2.1 目標

- Formurae の pure operator definitionを通常の Egison function definitionとして持つ。
- Egison が tensor index、縮約、反対称化、積・chain ruleを評価する。
- analytic derivativeを導関数添字付き function symbolへ完全に押し込む。
- post-fec が FieldJet と field descriptorだけから具体的 stencilを選ぶ。
- `lap = divg (grad u)` のような合成を stencil lowering 前に評価し、二階微分を
  compact stencilへ直接落とす。
- 数学的operator definitionをformal accuracy/radiusから独立させ、model-level profileだけで
  同じFieldJet normal formの離散化精度を変更できるようにする。
- continuum operatorとdiscretization-sensitive operatorを表面・IRの両方で区別する。
- field identity、tensor component、derivative multi-index、time slotを文字列解析せず扱う。
- `.fme` の path / line / column と user definition expansion traceを全段で保持する。
- exact rational coefficientを維持する。
- pre-fec、Egison、post-fecのどこが意味論の権威かを一意にする。

### 2.2 非目標

- 旧 `fec` CLI、旧 generated `.egi` API、旧 FEIR schemaとの後方互換性。
- 任意の解析的恒等式から保存形・mimetic stencilを自動発見すること。
- 異なる grid placement間の暗黙補間。
- Egison の FunctionDataへstorage名やphysical offsetを埋め込むこと。
- `expandAll` による数式全体の無条件な展開。
- 一般非直交計量、任意境界scheme、任意の非可換微分をFEIR v1ですべて扱うこと。
- 同一scalar expression内で複数のdiscretization profileを暗黙に混在させること。v1の通常経路は
  model-level profileとし、個別の`∂'`は明示的opaque requestとして扱う。

## 3. 責務境界

### 3.1 pre-fec

pre-fec は Formurae language frontendである。

- `.fme` のlex/parse
- Unicode transliterationとsource position map
- mode、dimension、axes、metric、embeddingの宣言検査
- model-level discretization declarationのparse、重複・適用可能性検査
- field、parameter、extern、raw helperの宣言検査
- `init` / `step` / `let` / `local` のscopeとtime-level検査
- free index、variance、明示縮約のsurface-level診断
- stable `AxisId` / `FieldId` / `ParamId` / `FunctionId` / `OriginId` の割当て
- logical field registryとsource-origin tableの生成
- surface expressionをhigh-level Egison expressionへ翻訳
- user `def` を通常のEgison functionとしてemit
- effectful discrete primitiveの呼出しにorigin/effect metadataを付与

pre-fec は次を行わない。

- tensor componentごとの式生成
- standard operator名ごとのrank/policy lowering
- `dC` / `dC2` / `dYee` の選択
- stencil offsetやTaylor coefficientの生成
- Formura storage名の決定
- `lb` coefficient/volume/flux fieldの割当て
- FMR文字列化

`TensorExpr` 相当のsurface ASTはpre-fecに残す。ただし値をHaskellで実行するためではなく、
parse、source diagnostics、effect analysis、Egison syntax generationに限定する。

### 3.2 Egison

Egison はcontinuum mathematical semanticsの実行主体である。

- function symbolとtensor-valued function symbolの構築
- index completion、transpose、tensor product、contraction
- Levi-Civita / Kronecker tensorとmetric contraction
- user `def` とstandard operator definitionの評価
- analytic derivativeのsum/product/quotient/power/chain rule
- FunctionDataのderivative user-indexへの変換
- mixed partialのSchwarz canonicalization
- differential formのdegree、反対称化、constant-metric geometry
- equation RHSのwhole-tensor評価とshape/variance/degree検査
- `assert-dd-zero`などcontinuum identity checkの評価とFEIR serializationのgate
- FEIR normal formへの変換とserialization

Egison はconcrete stencil、array offset、storage lifetimeを決めない。

### 3.3 post-fec

post-fec はdiscretization compiler兼Formura backendである。

- FEIR version、registry identity、全ID参照の検証
- tensor/form targetとRHS signatureの最終照合
- field policyとcomponent basisからのsource placement計算
- derivative multi-indexからのnatural target placement計算
- expression subtreeのplacement整合性検査
- centered / Yee / wide / mixed stencilの選択
- model-level derivative ruleの解決とformal accuracyからの最小radius選択
- exact rational Taylor stencilの導出
- coordinate/metric coefficientの必要placementでのsampling
- explicit interpolation/resampling primitiveのlowering
- opaque discrete requestのrank/degree/policy/effect検査
- auxiliary fieldの宣言、lifetime、更新順序の計画
- independent component projectionとFormura storage mapping
- initializer / step / helperのFMR生成

### 3.4 Formura

Formura はpost-fecが生成した `.fmr` を受け取り、配列・loop・C codeを生成する。tensor algebra、
analytic differentiation、placement inferenceをFormuraへ持ち込まない。

FEIR v1が生成するのはtranslation-invariantなinterior stencilである。boundary conditionは現在どおり
Formura側の設定に属し、新しいFormurae boundary構文は本設計のscopeに含めない。

### 3.5 OperatorContext

surfaceでは`grad u`、`curl X`のようにmodel contextを省略するが、shared Egison definitionは
coordinate vector、dimension、geometry registryを必要とする。pre-fecは全Formurae user functionへ
同じhidden `OperatorContext` dictionaryを一律にthreadする。

```text
OperatorContext {
  coordinates
  dimension
  geometry
  primitiveManifestId
}
```

概念的には次の変換である。

```text
def lap2 u = divg (grad u)

->

def lap2 ctx u = FE.divg ctx (FE.grad ctx u)
```

call siteでは`lap2 feOperatorContext u`、higher-order valueでは`lap2 feOperatorContext`という
部分適用済みclosureを渡す。これは全user functionに対するuniform dictionary passingであり、
operator名ごとのrank/policy/stencil分岐ではない。intrinsic、extern、local variableはsymbol table上の
分類に従ってcontextを受け取らない。user shadowingは通常のlexical resolutionでstandard preludeより
優先する。

## 4. 演算子の二層化

### 4.1 Pure continuum operators

解析微分とtensor algebraだけから定義できる演算子は、shared Egison operator libraryの通常の
関数として定義する。以下は`xs = coordinates(ctx)`と展開したmathematical coreのtarget sketchである。
public bindingは同じ式をOperatorContextから座標を取り出す1行wrapperにする。型とindex orientationは
focused testで固定する。

```egison
def FE.grad xs u := ∂/∂ u xs

def FE.dGrad xs X := !∂/∂ X xs

def FE.divg xs X := trace (!∂/∂ X xs)

def FE.curl xs X := rot X xs

def FE.hessian xs u := !∂/∂ (∂/∂ u xs) xs

def FE.lap xs u := FE.divg xs (FE.grad xs u)
```

`grad = ∂/∂` はEgisonのderivative library、`div`と`rot`はvector libraryにすでに存在する。
Formurae固有のcallback、axis loop、`generateTensor`はこれらの定義に含めない。

簡潔化できる範囲は次のとおりである。

| 演算子 | target definition | 判定 |
|---|---|---|
| `grad` | `∂/∂ u xs` | Egison nativeの1行 |
| `dGrad` | `!∂/∂ X xs` | Egison nativeの1行 |
| `divg` | `trace (!∂/∂ X xs)` | Egison nativeの1行 |
| `curl` | `rot X xs` | Egison nativeの1行 |
| `hessian` | `!∂/∂ (∂/∂ u xs) xs` | Egison nativeの1行 |
| Cartesian `lap` | `divg xs (grad xs u)` | pure compositionの1行 |
| `d` | index completion + `dfNormalize` | normalization係数を含む数行 |
| `hodge` | complement basis + metric coefficient | pure Egison + post-fec sampling |
| constant-metric `codiff` | `sign * hodge (d (hodge A))` | pure compositionの数行 |
| variable-metric `codiff` | weighted discrete adjoint | initially opaque |
| variable-metric `lb` | conservative flux request | opaque + post-fec plan |

したがって「数学的な合成演算子を短くする」という目標は達成できる。一方、離散化そのものを
表す演算子まで無理に1行のanalytic definitionへ変換しない。

同じ理由で、4次精度Cartesian Laplacianの定義も通常のLaplacianと同一にする。

```formurae
def Δ u = divg (grad u)
```

2次精度か4次精度かは`Δ`のbodyではなく`DiscretizationProfile`が決める。`Δ4`という名前を
双Laplacianなどの別の数学的演算子と混同しないためにも、formal accuracyをoperator名や
operator definitionへ符号化しない。

外微分もEgisonのindex completionを利用する。Formuraeのnormative component conventionは次である。

```text
(d A)_ij    = ∂_i A_j - ∂_j A_i
(d B)_123   = ∂_1 B_23 - ∂_2 B_13 + ∂_3 B_12
```

Egisonの`dfNormalize`はdegreeに応じたfactorialで割るため、shared implementationは次の係数補正を
行う。

```egison
def FE.d xs A :=
  let q := dfOrder A + 1
   in q * dfNormalize (!(flip ∂/∂) xs A)
```

Phase 0で上の2式、全basis permutation、`d(d A) = 0`をfocused testにし、型とindex orientationを
固定する。式のcomponent convention自体は本設計で確定する。

constant-metric codifferentialは合成定義のまま短く保つ。

```egison
def FE.codiff n d hodge A :=
  let k := dfOrder A
   in (-1) ^ (n * (k + 1) + 1) * hodge (d (hodge A))
```

Hodge starのnormative component conventionは、target basisを`J`、そのcomplementを`I`として

```text
(* A)_J = sign(I ++ J) * c_I * A_I
c_I     = sqrt(g) / product(a in I, h_a^2)
```

とする。Euclidean metricでは`c_I = 1`である。`c_I`がcoordinate/parameterだけからなる場合は
SampleableとしてFEIRへ残し、post-fecが`A_I`のsource placementでsampleする。この範囲の
variable-metric Hodge自体はpure Egisonにできる。

一方、`d(hodge A)`をanalytic product ruleで展開すると、現在のweighted whole-expression Yee
derivativeやdiscrete adjointと異なる場合がある。FEIR v1ではconstant-metric codifferentialだけを
上のpure compositionで定義し、variable-metric codifferential全体をversioned opaque requestとする。
本符号規約ではpositive Cartesian scalar Laplacianは`-codiff (d u)`である。

### 4.2 Opaque discrete primitives

operator applicationの境界自体がdiscretization semanticsを持つものは、Egisonが内部へ
analytic derivativeを分配しないatomic requestとしてFEIRへ残す。

FEIR v1で最低限必要なprimitiveは次である。

- expression occurrenceで明示されたnondefault radius / wide coordinate derivative
- orderedまたはnoncommuting derivative chain
- whole-expression grid derivative
- explicit interpolation / resampling
- conservative flux divergence
- orthogonal variable-metric Laplace--Beltrami (`lb`)
- materializationを必要とするflux/operator
- discrete-adjoint variable-metric codifferential

opaque primitiveはversioned semantic `OpId`、operand、result type、policy/placement rule、effectを
持ち、origin集合はsemantic identity外のprovenance sidecarに置く。表示用の関数名をprotocolにしない。

```text
PrimitiveSig {
  inputs
  output
  policyTransform
  placementRule
  effects          = PureLocal | NeedsMaterialization [AuxRole]
  commutation      = Ordered | DeclaredCommutative
}
```

primitive signatureは3実装へ手書きで複製しない。`spec/feir-primitives-v1.sexp`を唯一のmanifestとし、
build時にpre-fec/Egison/post-fec用のbindingを生成する。FEIR headerは`primitiveManifestId`を持ち、
post-fecは自分が実装するmanifestとの完全一致を要求する。

### 4.3 OpaqueRefのCAS表現

FEIR v1ではEgison coreに新しいCAS atomを追加せず、reserved scalar `OpaqueRef`とmodel-local
request side tableを使う。

- semantic keyは`(OpId, normalized operands, attributes, result basis)`から作る。
- request occurrence IDとOriginIdはsemantic keyに含めない。
- side tableはsemantic keyからpayloadとprovenance集合を引く。
- tensor-valued opaque resultはbasisごとのscalar OpaqueRefへ展開し、同じrequest group keyを共有する。
- Egison encoderはCAS normalization後に生き残ったsemantic keyへRequestIdを割り当てる。
- post-fecのdeduplicationもsemantic keyで行う。

FunctionDataは通常ならchain ruleでargument内部を微分するため、opaqueであるだけではanalytic
derivative barrierにならない。pre-fecはuser definition call graphに`Pure`またはversioned
`Discrete EffectSet`のsummaryを推論し、opaqueを含む値へanalytic `∂`を適用する式をtransitively
拒否する。generated normalization unitも同じassertionを実行する。

FEIR v1ではpure functionのhigher-order受け渡しを許す。effectful function/operatorをhigher-order
argumentとして渡すことは、effect-polymorphic signatureを将来導入するまで拒否する。named user
definitionを通したopaque callはeffect summaryで追跡できる。

`lb` は次のように分ける。

- Cartesian/default metric: `lap` としてpure Egisonで定義可能
- variable metric: coefficient x gradientをface fieldとしてmaterializeし、そのdivergenceを取る
  opaque conservative request

## 5. Analytic derivativeの意味

unannotatedな数学的 `∂_a` はcontinuum differentiate-then-discretize semanticsを持つ。

```text
∂_a c          = 0
∂_a x_b        = delta_ab
∂_a Jet(f,alpha) = Jet(f,alpha + e_a)
∂_a (u + v)    = ∂_a u + ∂_a v
∂_a (u * v)    = (∂_a u) * v + u * (∂_a v)
∂_a F(u_1,..)  = sum_r (partial_r F)(u_1,..) * ∂_a u_r
```

例えばEgisonは次を生成する。

```text
∂_x (exp u)
  -> exp(u) * Jet(u, {x:1})

∂_x (a * ∂_x u)                  -- a is a grid field
  -> Jet(a, {x:1}) * Jet(u, {x:1})
     + a * Jet(u, {x:2})
```

後者はface fluxを保存してからdivergenceを取る保存形stencilと同一ではない。保存形が必要なら
`FluxDiv` / `lb` / whole-expression `GridDerivative`を明示する。

```text
gridD_x (u^2)
  != discretize (2 * u * Jet(u, {x:1}))
```

post-fecはこの差を埋めるための積の再構成や暗黙補間を行わない。

FunctionDataのderivative user-indexは構築時にsortされる。したがってFEIRのanalytic
multi-indexもaxis-count mapとしてcanonicalizeし、mixed partialの可換性をv1の言語規則とする。
順序が意味を持つ離散微分、covariant derivative、境界schemeはopaque ordered primitiveを使う。

model-level profileによるaccuracy/family指定は通常のFieldJet metadataに混ぜず、FEIR headerの
`DiscretizationProfile`としてpost-fecまで運ぶ。したがってpure expressionのCAS normalizationは
scheme非依存である。

一方、`∂'`などexpression occurrenceごとのradius指定は、product/chain ruleとSchwarz
canonicalizationに混ぜると指定範囲が不明になるため、versioned coordinate-derivative requestとして
保持する。このrequestはorder、ordered axis sequence、radius、placement transformを完全に指定し、
model profileを参照しない。通常のFieldJetだけが「model profileのorder-specific rule >
model profileのclass-default rule > `standard-v1`」の順でruleを解決する。
FEIR v1の全`OpaqueDiscrete`（個別`∂'`、`gridD`、interpolation、`lb`を含む）はprofile resolutionを
bypassし、primitive manifestとrequest attributesだけでlowerする。将来profileの一部を継承する
primitiveを追加する場合は、継承する属性をmanifest contractに明記してversionを上げる。

## 6. FEIR v1

### 6.1 Protocol

FEIRはpretty-printed Egison/MathValueを再parseする形式にしない。version付きcanonical
S-expressionをnormative encodingとする。

```text
(feir 1 ...)
```

post-fecは自分が実装するversionだけを受理する。schema変更時はpre-fec、Egison encoder、
post-fecを同時更新し、旧version readerを残さない。

FEIRはlogical registryのdeterministic fingerprintを持つ。post-fecはFEIR内の全IDが同じ
registryに属することを検証し、別modelのmetadataとの取り違えを拒否する。headerの
`registryId`はbodyに埋め込まれたcanonical logical registryからpost-fecが再計算して照合する。
canonical encodingではprovenanceを付けうる各value nodeへNodeIdを割り当てる。以下の概念ADTでは
読みやすさのためnode envelopeを省略する。

### 6.2 Model structure

概念的な型は次である。

```haskell
data FEProgram = FEProgram
  { version      :: Int
  , registryId   :: RegistryId
  , primitiveManifestId :: PrimitiveManifestId
  , discretization :: DiscretizationProfile
  , mode         :: Mode
  , dimension    :: Int
  , axes         :: [AxisDecl]
  , geometry     :: GeometryDecl
  , parameters   :: [ParameterDecl]
  , functions    :: [FunctionDecl]
  , fields       :: [LogicalFieldDecl]
  , initializers :: [FEInitializer]
  , stepActions  :: [FEAction]
  , rawHelpers   :: [RawHelper]
  , origins      :: Map OriginId SourceOrigin
  , provenance   :: Map NodeId [OriginId]
  }

data GeometryDecl
  = EuclideanGeometry
  | OrthogonalScaleGeometry [(AxisId, ScalarNF)] GeometryNF
  | EmbeddedOrthogonalGeometry [ScalarNF] GeometryNF

data GeometryNF = GeometryNF
  { metricComponents :: TensorNF
  , inverseMetric    :: TensorNF
  , scaleFactors     :: [(AxisId, ScalarNF)]
  , volumeElement    :: ScalarNF
  , orthogonalityVerified :: Bool
  }

data DiscretizationProfile = DiscretizationProfile
  { profileVersion     :: VersionedProfileId
  , profileFingerprint :: Fingerprint
  , derivativeRules    :: [DerivativeRule]
  , mixedRule          :: MixedStencilRule
  }

data DerivativeRule = DerivativeRule
  { latticeClass    :: LatticeClass       -- Collocated | Staggered
  , derivativeOrder :: Maybe Positive     -- Nothing is the class default
  , stencilFamily   :: StencilFamily      -- CenteredTaylor | Yee
  , formalAccuracy  :: PositiveEven
  , ruleOrigin      :: OriginId
  }

data FEEquation = FEEquation
  { equationId :: EquationId
  , target     :: FieldTarget
  , rhs        :: TensorNF
  , origin     :: OriginId
  }

data FEAction
  = BindValue NodeId FEValue OriginId
  | Materialize FieldId FEValue OriginId
  | UpdateField FEEquation

data FEInitializer
  = AnalyticInitializer FEEquation
  | RawInitializer FieldTarget String OriginId

data TensorNF = TensorNF
  { shape      :: [Int]
  , variances  :: [Variance]
  , dfOrder    :: Int
  , components :: [(Basis, ScalarNF)]
  }
```

surface declarationは次をnormative syntaxとする。

```formurae
-- all collocated single-axis derivatives
discretization collocated centered accuracy 2

-- all axis factors of multiplicity 2; overrides the preceding class default
discretization collocated derivative 2 centered accuracy 4

-- staggered derivatives are configured independently
discretization staggered yee accuracy 2
```

同じ`latticeClass`と`derivativeOrder`に対する重複ruleはpre-fec errorにする。ruleを省略したclassは
`standard-v1`を使う。derivative order 0は拒否する。`formalAccuracy`はinterior truncation errorが
少なくともその次数になることを要求する値であり、derivative orderやradiusではない。偶発的な
superconvergenceは許す。CenteredTaylor v1ではpositive evenだけを受理する。

`derivativeOrder = Just m`はsingle-axis multi-index `{a:m}`だけでなく、mixed multi-indexの各axis
factorにも適用する。例えば`{x:2,y:1}`はorder 2 ruleをxへ、order 1/default ruleをyへ適用し、
`mixedRule`のfixed axis orderで合成する。pure second derivative `{x:2}`とmixed derivative
`{x:1,y:1}`を同じ「total order 2」という理由で同一ruleにしてはならない。

FEIR v1で有効な組合せは`Collocated + CenteredTaylor`と`Staggered + Yee`だけとし、
`Collocated + Yee`、`Staggered + CenteredTaylor`をpre-fecで拒否する。Staggered order 1ではaxisの
placement bitをtoggleする。integer sourceからhalf targetへは`(u[i+1]-u[i])/h`、half sourceから
integer targetへは`(u[i+1/2]-u[i-1/2])/h`という正方向規約を使う。post-fecは実際のsource placement
bitからoffset orientationを決めるため、rule keyはlattice classとper-axis derivative orderで十分である。
order 2はsourceと同じplacementのcompact second derivativeである。
surface token `centered`はFEIRの`centered-taylor`へ、`yee`は`yee`へnormatively mapする。

mixed profileのaccuracyはtotal orderに対する単一値ではなくaxisごとの保証vectorである。
`{x:2,y:1}`でxがaccuracy 4、yがaccuracy 2なら`{x:4,y:2}`を保証し、haloもaxisごとの最大radius
`{x:2,y:1}`として計算する。translation-invariant interior stencilでは異なるaxisのexact convolutionと
placement-bit toggleが可換であることをpost-fecが検証する。選択familyで可換性または最終placementを
保証できなければ明示エラーにする。

canonical FEIR encodingはruleを`(latticeClass, derivativeOrder)`順にsortする。全順序は
`collocated < staggered`、各class内で`default < 1 < 2 < ...`とする。

```scheme
(discretization
  (schema formurae-discretization 1)
  (fingerprint "sha256:<canonical-profile-digest>")
  (rule collocated default centered-taylor (accuracy 2))
  (rule collocated 2 centered-taylor (accuracy 4))
  (rule staggered default yee (accuracy 2))
  (mixed fixed-axis-order))
```

`profileVersion`と`profileFingerprint`は表示名ではない。fingerprintはschema version、canonical
rule列、mixed ruleから計算する。Egisonはprofileを参照・変更せずcanonical FEIRへ転記し、post-fecが
version、fingerprint、全ruleを検証する。`ruleOrigin`とprovenanceはfingerprintに含めず、invalidまたは
unsupported ruleを元の`discretization` declarationへ対応付ける。
fingerprintは`fingerprint` field、OriginId、provenanceを除いたcanonical UTF-8 S-expression bytesの
SHA-256 lowercase hexとする。

`LogicalFieldDecl` はfield ID、source name、policy、tensor type、layout、declared variance、
user-state/step-local lifetime、source originを持つ。Formura storage名とpost-fecが追加する
auxiliary fieldは含めない。`stepActions` はpure binding、user-declared local materialization、
field updateのsource orderを保持し、post-fecがeffect dependencyを追加してscheduleする。

`GeometryNF` はEgisonがembedding/metric expressionから導出したexact symbolic geometryである。
非直交性が検出されたmodelはFEIRを出力しない。post-fecはscale factorとvolume expressionを
必要placementでsampleし、opaque geometry requestのattribute IDをこのregistryへ解決する。
GeometryNFのexpressionはConstant/Sampleableだけからなり、FieldJet/OpaqueDiscreteを含めない。

`RawInitializer`と`rawHelpers`は明示的なlow-level Formura escapeである。RHS textはpost-fecが
CAS変換せず保持し、そこに現れる名前はbackend名として予約する。raw内からlogical fieldを参照する
場合はpost-fecのdeterministic storage nameを使う必要があり、名前衝突をpre-fecが拒否する。

### 6.3 Scalar normal form

FEIRはEgison内部CAS constructorをそのまま公開せず、安定したsemantic ASTへ変換する。

```haskell
data ScalarNF
  = Exact Integer Integer
  | Parameter ParamId
  | Coordinate AxisId
  | Add [ScalarNF]
  | Mul [ScalarNF]
  | Div ScalarNF ScalarNF
  | Pow ScalarNF ScalarNF
  | Intrinsic FunctionId [ScalarNF]
  | AnalyticCall FunctionId [ScalarNF]
  | Select PredicateNF ScalarNF ScalarNF
  | FieldJet FieldJet
  | OpaqueDiscrete DiscreteCall
  | Ref NodeId

data PredicateNF
  = BoolExact Bool
  | Compare CompareOp ScalarNF ScalarNF
  | Not PredicateNF
  | And [PredicateNF]
  | Or [PredicateNF]

data FieldJet = FieldJet
  { fieldId    :: FieldId
  , timeSlot   :: TimeSlot
  , basis      :: Basis
  , arguments  :: [ScalarNF]
  , multiIndex :: [(AxisId, Natural)]
  }

data DiscreteCall = DiscreteCall
  { opId        :: VersionedOpId
  , semanticKey :: SemanticKey
  , requestGroup :: RequestGroupId
  , resultBasis :: Basis
  , operands    :: [FEValue]
  , attributes  :: [(AttributeId, AttributeValue)]
  }

data FEValue
  = ScalarValue ScalarNF
  | TensorValue TensorNF
```

`FieldJet` のempty multi-indexは通常のfield referenceである。grid field、analytic function、
extern functionはregistry上で分類し、登録grid fieldだけをFieldJetへ変換する。pre-fecが生成する
normalization unitは`FieldId`とbase FunctionData値のstructural registryをencoderへ渡す。encoderは
FunctionData nameのUser indexだけを外し、表示文字列でなくCAS equalityでfieldを同定する。
FunctionDataのpositional User index `n` は、そのfieldのcanonical argument vectorの第`n`要素に
対応するAxisIdへ変換する。argumentがcanonical coordinate vectorでないgrid field derivativeは拒否する。

FEIR v1の`OpaqueDiscrete`はscalar componentだけを表す。tensor/form resultはfull TensorNFのbasisごとに
OpaqueDiscreteを置き、同じ`requestGroup`を共有する。RequestIdはCAS normalization後に生き残った
semantic keyへencoderが割り当て、provenanceはsemantic identityと独立したsidecarに置く。

### 6.4 Example

curlの第1成分

```text
∂_y E_3 - ∂_z E_2
```

は概念的に次のFEIRになる。

```scheme
(component (basis 1)
  (add
    (jet E current (basis 3) (multi-index (y 1)))
    (mul (exact -1 1)
         (jet E current (basis 2) (multi-index (z 1))))))
```

`divg (grad u)` は次の3つのatomの和になる。

```scheme
(add
  (jet u current (basis) (multi-index (x 2)))
  (jet u current (basis) (multi-index (y 2)))
  (jet u current (basis) (multi-index (z 2))))
```

post-fecは各second-order jetを一階stencilの二重適用ではなくcompact `dC2`へ直接落とす。

同じFEIR bodyへ`centered accuracy 4` profileを指定した場合もatomは変わらない。post-fecだけが
各`{axis:2}`についてradius 2を選び、次の5点係数を生成する。

```text
[-1, 16, -30, 16, -1] / (12 h_axis^2)
```

opaque `lb` requestは例えば次の形を持つ。

```scheme
(discrete
  (op lb.orthogonal 1)
  (semantic-key lb-key-17)
  (request-group lb17)
  (result-basis (basis))
  (attributes (metric g1) (source-policy collocated))
  (operands
    (scalar (jet u current (basis) (multi-index)))))
```

### 6.5 Normal-form invariants

Egison encoderは次を満たすFEIRだけを出力する。

1. tensor index algebraは完了している。free/local symbolic index、`withSymbols`、contraction、
   epsilon、transpose、index-completion placeholderは残らない。
2. shape、variance、`dfOrder`、canonical component orderが明示される。`components`はlayoutに
   かかわらずfull row-major tensorであり、scalarはempty basisを1つ持つ。formのzero/sign/permutation
   componentも含み、independent storage projectionはpost-fecだけが行う。
3. grid field occurrenceはstable ID、time slot、basisを持つFieldJetだけで表す。
4. analytic derivative operatorは残らず、derivativeはFieldJet multi-indexにのみ現れる。
5. FieldJetのsemantic identityは`(FieldId,timeSlot,basis,arguments,multiIndex)`であり、originを含まない。
   multi-indexはaxis順、positive count、duplicate/zeroなしのaxis-count mapである。
6. mixed analytic partialはcanonical axis-count mapであり、Schwarz可換性を持つ。
7. `Add`/`Mul`はflatten済み、operandはcanonical order、nested/singleton/empty nodeなし、zero/one
   identity除去済み、同一termの係数は結合済みである。`Div`/`Pow`もunit denominator/exponent等の
   trivial formを残さない。
8. unknown function derivativeを0として扱わない。registered grid FunctionData以外のuser-index付き
   FunctionDataは、登録analytic derivative ruleが通常のIntrinsic/AnalyticCallへ完全展開しない限り
   normalization errorにする。
9. opaque discrete nodeの内部へanalytic derivativeを分配しない。
10. lowered/implicit interpolation、grid offset、array reference、concrete stencil coefficient、storage名、
    per-FieldJet stencil family/accuracyは存在しない。明示interpolationまたはper-occurrence wide
    derivative requestはOpaqueDiscreteとして存在できる。
11. step equationのFieldJet argumentsはmodelのcanonical coordinate vectorである。
12. `Ref`は同じinitializer/action stream内で先行するunique `BindValue`だけを参照し、graphはacyclicである。
13. provenanceはsemantic node identityから独立したsidecarであり、normalization/cancellationへ影響しない。
14. unknown tag、unknown ID、duplicate ID、不正なshape/versionはhard errorである。

`Exact p q` は`q > 0`、`gcd(abs p,q) = 1`の正規形とする。

現Egisonのunmatched apply微分は0へ落ちるため、そのままではinvariant 8を満たさない。Phase 4で
Formurae normalization用のstrict differentiation entry pointを追加し、FunctionData、constant symbol、
登録derivative rule以外を微分前に拒否する。encoderで事後検出するだけでは、0との区別が失われて遅い。

`expandAll` はこのcontractに含めない。必要なのはanalytic derivativeの消去であり、因数分解された
式や共通部分式は可能な限り保持する。式が大きくなる場合は`BindValue`/`Ref`によるDAGを使う。

## 7. post-fecのplacement semantics

post-fecは各scalar subtreeを次のlocation capabilityへ解析する。

```text
Constant       number / parameter; every placementで利用可能
Sampleable     coordinate/parameterだけからなるpure analytic expression; demanded pointでsample可能
Located p      field / jet / discrete result; physical placement pに存在
```

location joinを次で定義する。

```text
join(Constant, x)          = x
join(Sampleable, Constant) = Sampleable
join(Sampleable, Sampleable) = Sampleable
join(Sampleable, Located p)  = Located p
join(Located p, Located p)   = Located p
join(Located p, Located q)   = error, if p != q
```

FieldJetのsource placementはfield policyとcomponent basisから計算する。

- Collocated fieldのanalytic derivativeはCollocatedに留まりcentered stencilを使う。
- Primal/Dual fieldはmulti-index内で奇数回現れるaxisのplacement bitを反転する。
- 偶数階微分はそのaxisのplacementを元へ戻す。

`Add`、`Mul`、`Div`、`Pow`、`Intrinsic`、`AnalyticCall`、predicate、`Select`は全operandを上のjoinで
畳み込む。`Ref`はbindingのlocation、OpaqueDiscreteはprimitive manifestのplacement ruleに従う。
Constantは任意placementで利用でき、Sampleableは確定したplacementで評価する。`exp(u)`は`u`が
fieldならLocatedであり、Sampleableではない。post-fecは暗黙のaverage/interpolationを生成しない。

最後にRHSのlocationをtarget descriptorの各component placementと比較する。neutral/sampleableだけの
RHSはtarget placementでsampleする。

TensorNF自身はlogical GridPolicyを持たない。field/local/updateのmaterialized targetだけがpolicyを持ち、
pure intermediateは各basisのphysical locationとして解析する。zero/constant RHSはplacement-neutralで
任意targetに代入できる。targetのない`BindValue`は使用箇所までlocationを伝播し、ambiguousなまま
opaque primitiveへ渡すことを拒否する。この規則によりoperator名ごとのpolicy表を復活させない。

default FieldJetはcomplete multi-indexを一度にlowerする。

```text
{x:1}       -> centeredまたはYee first derivative
{x:2}       -> compact second derivative
{x:1,y:1}   -> canonical mixed derivative
```

FEIR v1のmixed partialは可換なので、post-fecは選択されたinterior discretization profileで可換な
mixed stencilを提供するか、明示エラーにする。ordered caseを推測しない。

post-fecは各axis orderについて、通常FieldJet用の上記優先順位で`DerivativeRule`を1つ選ぶ。CenteredTaylorのorder `m`、
formal accuracy `p`に対して、offset `s = -r..r`とexact rational weight `c_s`が次のmoment条件を満たす
最小radius `r`をexact solverで求める。

```text
sum_s c_s * s^q = m!   (q = m)
sum_s c_s * s^q = 0    (0 <= q <= m + p - 1, q != m)
```

探索は`m >= 1`、`r >= ceil(m/2)`から始め、CenteredTaylorの対称性
`c_(-s) = (-1)^m c_s`も検証する。対称gridでparityにより従属する条件はexact row reductionが検出する。
例えば`m = 2, p = 4`はradius 2と
`[-1,16,-30,16,-1]/12`を与える。解が一意でない、要求familyでplacementを保てない、または
要求accuracyを実装できない場合は、低いaccuracyへ黙ってfallbackせずsource diagnosticを返す。
実装はparityを前提に未知数を減らさず、exact rational row reductionで過剰決定系のrankと一意性を
判定する。得た解は全moment条件、端係数、必要halo radiusに対して再検証する。

`standard-v1` discretization profileは次を既定とする。

- Collocatedの全single-axis orderはCenteredTaylor accuracy 2を使う。これはorder `m`について
  radius `max(1, ceil(m/2))`となる。
- Primal/Dualのaxis order 1はsourceと相補的なhalf-step placementへのYee accuracy 2、order 2は
  sourceと同じplacementへのcompact 3点second derivativeを使う。
- Primal/Dualのper-axis order 3以上はv1 defaultで拒否し、explicit opaque requestを要求する。
- Yee accuracy 4以上はFEIR v1で拒否し、accuracy 2へfallbackしない。
- mixed multi-indexはaxisごとのprofile-selected stencilをfixed axis orderで合成する。
- mixed Yeeは各axis stencilが生成したplacementを次のaxisのsource placementとして渡し、
  canonical axis orderの最終placementをtargetと照合する。
- boundary modificationはFormura側の責務であり、post-fecはinterior stencilと必要halo radiusだけを
  検証・生成する。

profile resolutionはanalytic initializerとstep actionの全通常FieldJetに同じように適用する。
OpaqueDiscreteはinitializer/stepのどちらでもprofileをbypassし、各primitive固有のcontext制約
（例えばinitializer内`lb`の拒否）をmanifestとpost-fecが検査する。

curlではnonzero `epsilon_ijk` termについて、Primal `X_k`のplacementをaxis `j`でtoggleした位置が
Dual result basis `[i]`と一致することをpositive/negative testにする。`d`ではsource basisへaxisを
追加した位置が同policyのtarget basisと一致し、Hodgeではcomplement basisへの写像がtarget physical
locationと一致することを検査する。

analytic initializerも同じjoinを使い、neutral/sampleable RHSはinitializer targetでsampleする。
located RHSはtargetとのrelative placementが0でなければ、明示resamplingなしには拒否する。

`divg (grad u)`からdirect compact second derivativeを選ぶ保証は、translation-invariant Cartesian
CenteredTaylor、およびuniform staggered Yeeで同じFieldJet multi-indexへ正規化できる場合に限る。
variable-metric、DEC discrete adjoint、保存流束などoperator境界が離散意味を持つ場合はanalytic
FieldJetから同値性を推測せず、versioned opaque conservative primitiveを使う。
RawInitializerはこの解析を通らないlow-level escapeである。

## 8. Source mapとeffect trace

pre-fecは各declaration、definition、call、initializer、equationへOriginIdを付け、次を保持する。

```text
SourceOrigin {
  path
  line
  column
  sourceText
  definitionSite
  callSites
  parentOrigin
}
```

OriginIdをFunctionData/FieldJetのsemantic identityへ含めてはならない。異なるcall site由来の同じ
jetがCASで結合・相殺できなくなり、`d^2=0`も壊れるためである。

FEIR v1はprovenanceをsemantic ASTと独立した`NodeId -> set OriginId` sidecarとして持つ。pure CAS
normalizationではequationとpre-fecが静的に得たdefinition/call stackをprovenance集合にする。
product/chain ruleで生成された個々のtermについて、元のcall siteを一意に復元できない場合は
equation-level traceを使う。atom単位の完全な動的traceをv1の要件にはしない。

`lb`のようなopaque effectは、constructorがmodel-local request side tableへsemantic payloadと
OriginId集合を別々に登録する。origin/effectをFunctionData argumentへ入れない。pre-fecのeffect
summaryは許可contextとdefinition/call traceを調べるために使い、auxiliary planはnormalization後の
FEIRに実際に残ったrequestだけから作る。

Egison normalization errorはequation OriginIdとgenerated `.egi` locationを、post-fec errorは
FEIR provenance sidecarを使って元の`.fme`位置へ戻す。

## 9. 現行実装の移行先

| 現在の処理 | 移行先 |
|---|---|
| `Main.hs:620-844` のparse/model validation | `Formurae.Pre.Parse` / `Pre.Validate` |
| `Main.hs:668-740` のdefinition/effect resolution | `Pre.Effect` / `Pre.EmitEgison` |
| `Main.hs:1252-2229` のnative/runtime lowering | static diagnostics以外をcutover時に削除 |
| `Main.hs:2310-2474` のform interpreter | Egison operator + FEIR encoderへ移して削除 |
| `Main.hs:2723-2906,3137-3174` のregistry/runtime emit | `Pre.EmitEgison` |
| `Main.hs:2833-2885` のstencil emit | `Formurae.Post.Stencil` |
| `Main.hs:2943-3124` のmetric/lb emit | `Formurae.Post.BackendPlan` |
| `Syntax.hs` | surface ModelはPre、wire typeは`FEIR.Syntax` |
| `Index.hs` | free-index診断はPre、placementはPost.Location、storage projectionはPost.FMR |
| `Common.hs` | stable ID/escapingをshared compiler libraryへ移す |
| `TensorExpr.hs` | pre-fec surface AST / index diagnostics / effect analysis |
| `RuntimeTensor.hs` | `Pre.EmitEgison`へ縮小。stencil call生成は削除 |
| native operator marker/名前別rank-policy表 | `formurae-operators.egi` の通常関数へ置換 |
| `formurae-tensor.egi` のtensor introspection/algebra | 中段Egisonに残す |
| `formurae-tensor.egi` のcallback付きcoordinate operators | 短いEgison定義へ置換 |
| `formurae-grid.egi` のGridPolicy/component placement | logical dataはFEIR、計算の権威はpost-fecへ移す |
| `FE.gridDerivativeChain`, generated `dC/dC2/dYee` | `Formurae.Post.Stencil` |
| `fmrgen.egi` の`taylorStencil` | `Post.Stencil`のexact `Rational` solver |
| `formurae-geometry.egi` のpure form/metric algebra | 中段Egisonに残す |
| variable Hodge coefficient sampling | Sampleable geometry expression + `Post.Location` |
| variable-metric codiff/lb callback | opaque request + `Post.BackendPlan` |
| `BackendPlan.hs` | FEIR requestを入力とする`Formurae.Post.BackendPlan` |
| `formurae-runtime.egi` のfield projection | `formurae-feir.egi` encoderとpost validatorへ分割 |
| `formurae-runtime.egi` のFMR printer | `Formurae.Post.FMR` |
| current `fec` executable | `pre-fec` / `post-fec`へ分割し削除 |
| `fec.cabal` | shared library + `pre-fec` / `post-fec` executable |
| `Makefile:86-91` | `.fme -> .egi -> .feir -> .fmr` pipeline |
| compiler/runtime bridge tests | pre/FEIR/post focused testへ分割 |
| gallery generator | `.feir`を含む4-stage displayへ更新 |

新しいHaskell moduleのtarget構成は次とする。

```text
Formurae.FEIR.Syntax
Formurae.FEIR.SExpr
Formurae.FEIR.Validate

Formurae.Pre.Parse
Formurae.Pre.Validate
Formurae.Pre.Effect
Formurae.Pre.EmitEgison

Formurae.Post.Location
Formurae.Post.Normalize
Formurae.Post.Stencil
Formurae.Post.BackendPlan
Formurae.Post.FMR
```

新しいEgison libraryは少なくとも次の2つとする。

```text
lib/formurae-operators.egi
lib/formurae-feir.egi
```

post-fecでstencilを展開した後にはEgison CASの再評価がない。`Post.Normalize`は完全なCASではなく、
exact rational fold、Add/Mul flatten、zero/one除去、structurally identical termの係数結合、
deterministic orderingだけを実装する。

## 10. 実装手順

Phase 0--7の新pipelineは明示コマンドで動かすdevelopment pathであり、現production pathは比較oracle
として変更しない。Phase 0--3では可能な範囲でFMR byte comparisonを使う。analytic semanticsと
stencil ownershipが変わるPhase 4以降は、FEIR/stencil structure assertion、Formura parse、C numerical
checkを受入れ基準にする。Phase 8でproduction callerの切替と旧semantic pathの削除をatomicに行い、
Phase 9は文書・gallery・artifact整理だけを行う。

### Phase 0: BaselineとFEIR contractの固定

- 現在の全unit/strict/end-to-end/C check結果をbaselineとして記録する。
- 本文書のFEIR v1 node、invariant、analytic/discrete derivative contractを確定する。
- operatorごとにpure/opaque分類表をtest dataとして固定する。
- semantic changeになるcompound derivative testを洗い出す。
- OperatorContext dictionary passing、OpaqueRef side table、primitive manifest、provenance sidecarを
  focused prototypeで検証する。
- GeometryNF、raw initializer、default discretization profile、strict differentiationをfixtureで固定する。
- model-level discretization syntax、rule precedence、accuracy-to-radius moment contractをfixtureで固定する。
- `d`のcomponent convention、Hodge coefficient、codiff/Laplacian符号をnormative testで固定する。

完了条件:

- `make fec-tensor-tests`
- `make formurae-grid-tests`
- `make formurae-geometry-tests`
- `make formurae-tensor-tests`
- `make all`

が変更前にgreenである。

### Phase 1: FEIR parser/encoder infrastructure

- `Formurae.FEIR.Syntax/SExpr/Validate`を追加する。
- `lib/formurae-feir.egi`にMathValue/TensorからFEIRへのencoderを追加する。
- exact rational、ID、origin、TensorNF、FieldJet、OpaqueDiscreteをround-tripする。
- canonical serializerとmalformed input diagnosticsを追加する。

focused tests:

- 全nodeのencode/parse
- UTF-8名とescape
- exact rational
- PredicateNF/Select、GeometryNF、per-basis opaque tensor result
- deterministic component/term order
- provenance sidecarがsemantic equality/cancellationへ影響しないこと
- DiscretizationProfile ruleのcanonical order、fingerprint、round-trip
- declaration source orderが異なっても同じcanonical profile/fingerprintになること
- unknown version/tag/ID、duplicate ID、invalid shapeの拒否
- profile fingerprint改ざんの拒否
- duplicate derivative rule、derivative order 0、odd/nonpositive accuracy、unknown stencil family、
  invalid lattice/family pairの拒否
- registry/primitive-manifest mismatchの拒否

このPhaseではproduction pipelineを切り替えない。

### Phase 2: pre-fec executableとnormalization unit

- current parser/validationを`Formurae.Pre.*`へ分離する。
- executable `pre-fec`を追加する。
- stable registry IDとOriginIdを生成する。
- fieldをbare tensor of function symbolsとしてemitする。
- equationをwhole-tensor Egison expressionとしてemitする。
- generated mainはFMRでなくFEIRをprintする。
- `discretization` declarationをparseし、profileをscheme非依存なequation bodyと分離してemitする。
- derivativeを含まないscalar/tensor modelで `.fme -> .egi -> .feir` を通す。

focused tests:

- scalar/vector/rank-2/form field registry
- current/next time slot
- whole-tensor equation shape/variance/degree
- parameter/coordinate/intrinsic/analytic function
- conditional、analytic/raw initializer、step-local action order
- source position map
- class-default/order-specific discretization ruleとduplicate/invalid rule diagnostics
- structurally unsupported ruleは未使用でもdeclaration source locationを示して拒否し、
  structurally validだが現在のequationで未使用のruleはcanonical profileへ保持すること
- generated `.egi` にFMR/stencil/storage helperがないこと

### Phase 3: post-fec skeletonとalgebraic FMR

- executable `post-fec`を追加する。
- FEIR model validation、field projection、storage mapping、FMR AST/printerを実装する。
- derivative/opaque requestを含まないmodelを`.fmr`へ変換する。
- `Post.Normalize`の最小canonicalizationを実装する。

focused tests:

- scalar/vector/symmetric/antisymmetric/full/form projection
- initializerとstepの順序
- raw helper/parameter/extern function
- Bool/comparison/Selectとraw initializer
- malformed FEIR diagnosticsがOriginIdから`.fme`位置を示すこと
- simple algebraic modelのFormura/C check

### Phase 4: OperatorContextとanalytic/opaque derivative仕様

- uniform OperatorContext dictionary passingを実装し、ordinary/higher-order callのcontext captureを
  focused testする。
- unannotated `∂` をanalytic derivativeとして固定する。
- whole-expression derivative、wide/radius、ordered derivativeをopaque syntaxへlowerする。
- model-level profileはFieldJet metadataやopaque nodeへ変換せずFEIR headerに保持し、個別`∂'`だけを
  opaque coordinate derivativeへlowerする。
- explicit interpolation/resampling primitiveを追加する。
- primitive manifestとPure/Discrete effect summaryをpre/Egison/postへ接続する。
- Formurae用strict differentiation entry pointをEgisonに追加する。
- new pipeline用のcompound derivative fixturesを新しい意味に更新する。

acceptance tests:

```text
∂_x (u^2)       -> 2 * u * Jet(u,{x:1})
gridD_x (u^2)   -> whole-expression centered/Yee stencil request
```

- 両者が異なるFEIR（FieldJet式とOpaqueDiscrete request）になることを明示的にtestする。
- staggered productのplacement mismatchをtestする。
- unknown analytic derivative ruleを0にせずerrorにする。
- ordered requestのaxis orderとradiusがFEIRで失われない。
- model profileがaccuracy 4でも個別`∂'` requestはprofileを参照せずexplicit radiusを保つ。
- initializer/stepの通常FieldJetには同じprofileが適用され、全OpaqueDiscreteはprofileをbypassする。
- pure higher-order operatorは通り、effectful higher-order argumentは明示診断になる。

### Phase 5: FieldJetとstandard coordinate stencil

- `formurae-operators.egi`に`grad/dGrad/divg/curl/hessian/lap`のpure target definitionを追加する。
- Egison encoderでFunctionData nameのSub/Sup/User indexを構造的に分離する。
- registered field functionをFieldJetへ変換する。
- analytic derivative operatorがFEIRに残らないことを検証する。
- post-fecにlocation analysisとcentered/Yee loweringを実装する。
- complete multi-indexからfirst/second/mixed stencilを選ぶ。
- exact rational Taylor solverをpost-fecへ移す。
- profile rule resolutionとformal accuracy moment条件からの最小radius探索を実装する。
- profileからaxis別halo footprintを導出しFormura backendへ渡す。

acceptance tests:

- `grad u` がrank-1 FieldJet tensorになる。
- `curl X` がepsilon/component loopなしに3成分のFieldJet式になる。
- `lap u` と`divg (grad u)`が同じcompact second-order stencilになる。
- `accuracy 2`と`accuracy 4`でFEIR expression bodyが同一で、post-fec stencilだけが3点/5点に変わる。
- order 2 overrideにより`divg (grad u)`の各pure second jetだけを4次精度へlowerできる。
- 4次精度の一階stencilを二重適用せず、4次精度のcompact二階stencilを直接生成する。
- order 2 overrideを持たない一階FieldJetはclass default/`standard-v1`を使う。
- `(m,p) = (1,2),(2,2),(1,4),(2,4),(3,2),(4,2)`のradius、exact coefficient、
  全moment、最初の非zero error momentを検証する。
- 採用radiusより1小さいradiusに解がないことを検証する。
- default accuracy 2 + order 2 accuracy 4で`{x:2,y:1}`がhalo `{x:2,y:1}`、
  `{x:1,y:1}`が`{x:1,y:1}`になる。
- repeated Hessian axisは`dC2`、mixed axisはcanonical mixed stencilになる。
- Collocated curlはCollocatedを保つ。
- Primal/Dual curlは正しいdual placementへ落ちる。
- placement mismatchを暗黙補間せず拒否する。
- high-order requestがexact Taylor coefficientを生成する。
- unsupported Yee accuracyを低次へfallbackせずsource errorにする。
- Yee order 1の両orientation、order 2のsame-placement、mixed axis orderの可換性と最終placementを検証する。
- required halo radius 2が最終FMRのoffset footprintと一致する。
- analytic `∂_x(u^2)`とopaque `gridD_x(u^2)`が意図どおり異なるFMRになる。
- post-fec出力にFieldJet/derivative markerが残らない。

### Phase 6: Differential formsとgeometry

- `d`をEgison index completion + normalizationで定義する。
- `d(d A) = 0`をderivative multi-index canonicalizationとantisymmetryで検証する。
- constant/orthogonal-metric Hodgeをpure Egison + Sampleable coefficientへ移す。
- constant-metric codiffをpure Egisonへ移す。
- variable-metric codiffをdiscrete-adjoint opaque requestへ接続する。
- form degree/policyの名前別Haskell interpreterを削除する準備を完了する。

acceptance tests:

- 0/1/2-formの`d`
- `d^2 = 0`
- whole-form Maxwell
- Hodge degree `k -> n-k`
- Primal/Dual flip
- constant/variable metric coefficient sampling
- codiffの符号規約

### Phase 7: Backend effectsと`lb`

- Egisonが`lb`をversioned opaque requestとしてFEIRへ出す。
- `BackendPlan`の入力をModel/TensorExprからFEIR requestへ変更する。
- coefficient、volume、flux、result fieldのplacement/lifetimeをpost-fecで計画する。
- auxiliary flux updateをuser updateより前にscheduleする。
- request deduplicationとdistinct-source bundleを実装する。

acceptance tests:

- metric/embedding必須診断
- initializer内request拒否
- unprimed/unindexed/Collocated scalar制約
- nested user definitionのdefinition/call origin trace
- same-source deduplication
- distinct-source independent bundle
- metric torus/sphere/hyperbolic end-to-end checks
- auxiliary fieldやrequest markerが最終FMRに残らないこと

### Phase 8: Pure user functionsとatomic production cutover

- `formurae-operators.egi`をstandard operatorの唯一の定義元にする。
- standard operatorとpure user `def`をpre-fec macroで展開せず通常のEgison関数としてemitする。
- Makefileと全production test callerを`.fme -> .egi -> .feir -> .fmr`へ切り替える。
- 同じ変更でcurrent `fec`、`nativeOperatorDefs`、`runtimeOperatorExpansionDefs`、native marker map、
  callback付きcoordinate operator、名前別rank/policy/form degree interpreterを削除する。
- generated FMR printer、old runtime stencil callback、old native lowering、`fmrgen.egi`のproduction
  loadを削除する。

acceptance tests:

- higher-order apply/passでstandard operator identityが保たれる。
- user definition shadowing/scopingがEgison上で正しく動く。
- generated `.egi` にstandard operatorの複製がない。
- `.feir` にpure `grad/curl/divg/lap/d/codiff` headやanalytic derivative nodeが残らない。
  `codiff.metric@v1`のようなversioned opaque OpIdは残り得る。
- pure operator definitionにderivative callback、axis loop、component `generateTensor`がない。
- 新pipelineがscope内の全syntaxとnegative diagnosticsを覆う。
- `highorder4`が通常の`lap`/`divg (grad u)`と
  `discretization collocated derivative 2 centered accuracy 4`を使い、既存のdiscrete-symbol C checkを保つ。
- 全Egison strict/library test、compiler test、example C numerical checkがgreenである。
- old marker/callback/printer pathがproduction codeに存在しない。
- feature flag、dual emitter、旧schema reader、compatibility shimが残っていない。

### Phase 9: Documentation、gallery、artifact cleanup

- README、DSL documentation、galleryを新しい中間表現へ更新する。
- galleryを`.fme / .egi / .feir / .fmr`の4段表示へ更新する。
- high-order documentationでderivative order、formal accuracy、radiusを区別し、`∂'`を
  per-occurrence low-level overrideとして記載する。
- tracked `.egi/.feir/.fmr` artifact policyを明記する。
- design docsの「current implementation」記述をcutover後の状態へ更新する。
- 最終`rg`とclean checkout相当のfull buildを行う。

Phase 8 cutoverとPhase 9 cleanupの最終完了条件:

1. 新pipelineがscope内の全syntaxとnegative diagnosticsを覆う。
2. 全Egison strict/library testがgreenである。
3. 全Formurae compiler testがgreenである。
4. 全exampleのFormura/C numerical checkがgreenである。
5. semantic changeを意図しないexampleは旧実装と同じ離散式または数値的同値を持つ。
6. analytic-vs-discrete contractを変更したexample/testは新仕様へ更新済みである。
7. `rg`でold marker/callback/printer pathがproduction codeに存在しない。
8. feature flag、dual emitter、旧schema reader、compatibility shimが残っていない。

## 11. 検証matrix

### Egison normalization

- scalar/vector/tensor function symbolのcomponent naming
- Sub/Sup tensor indexとUser derivative indexの分離
- product/chain/quotient/general-power rule
- mixed partial canonicalization
- curl/lap/hessian/d/codiffのnormal form
- unknown derivative ruleのerror
- no residual analytic derivative/operator head

### FEIR protocol

- canonical round-trip
- exact rational
- stable IDs/registry mismatch
- provenance sidecar/equation-level expansion trace
- PredicateNF/Select、GeometryNF、opaque request group
- DiscretizationProfile rule、precedence、canonical fingerprint
- malformed/unknown node rejection
- deterministic output

### post-fec

- collocated first/second/mixed stencil
- formal accuracy 2/4からのminimal radiusとexact Taylor coefficient
- order-specific profile ruleとmodel default rule
- Primal/Dual Yee stencil
- placement-neutral/sampleable/located merge
- explicit interpolation
- wide/ordered derivative
- tensor/form projection
- auxiliary field lifetime/schedule
- FMR syntax and storage mapping

### End-to-end

- diffusion 1D/2D/3D
- collocated Maxwell
- Yee Maxwell
- DEC Maxwell and `d^2=0`
- elastic rank-2 tensor
- high-order derivative
- profile-selected 4次精度Laplacianとcompact 5点stencil
- nonlinear compound derivativeのanalytic/gridD差
- metric Laplace--Beltrami examples
- all generated C checks

## 12. 成功条件

本改良は次をすべて満たしたとき完了とする。

- pure Formurae operatorの数学的定義がshared Egison libraryにのみ存在する。
- `grad`、`dGrad`、`divg`、`curl`、`hessian`、Cartesian `lap`が1行または数行である。
- `d`、orthogonal-metric Hodge、constant-metric codiffがEgison tensor/form algebraで定義される。
- variable-metric `lb`等の複雑さはopaque requestとpost-fec plannerに隔離される。
- pre-fecにoperator名ごとのstencil/rank/policy branchがない。
- Egison outputはanalytic derivative operatorを含まず、導関数はFieldJet multi-indexだけに現れる。
- 2次/4次精度Laplacianが同じ数学的operator definitionとFEIR expression bodyを共有する。
- model-level accuracy設定だけでpost-fecの3点/5点stencilを選択できる。
- post-fecだけがconcrete stencil、placement、storage、lifetimeを決める。
- 最終FMRにFEIR node、FunctionData derivative mark、opaque requestが残らない。
- source diagnosticsと全numerical acceptance testを維持する。

したがって、「基本的な離散primitiveは複雑でも、それらを組み合わせる数学的関数はEgison本来の
短い定義にする」という要求は、この二段コンパイラ境界によって実現できる。
