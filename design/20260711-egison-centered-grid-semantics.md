# Egison 中心のテンソル・格子意味論

Date: 2026-07-11

Status: Accepted; Phases 1-7 implemented

> Follow-up: `20260711-pre-post-fec-pipeline.md` は、実装済みの本設計を
> `pre-fec -> Egison -> FEIR -> post-fec` へ発展させる次期pipelineを定める。
> そのproduction cutoverまでは本文書が現在の実装状態を記録し、cutover後はfollow-upの
> pipelineと責務境界を正とする。

この文書は、`.fme` の数式を `fec` が標準演算子ごとに成分特殊化していた構成を改め、
テンソル・添字・微分形式・格子配置の意味論を Egison に集約するための設計と
移行手順を定める。標準座標演算子だけでなく、任意の添字 equation、indexed `let`、
indexed CAS initializer も whole tensor のまま共有 Egison kernel へ渡る。
`TensorExpr` は `.fme` の surface AST、ユーザー `def` の展開、source diagnostics、
Egison runtime expression を組み立てる bridge として残るが、Formura 成分を
`fec` で列挙・評価する production fallback ではない。

`20260710-tensor-expr-ir-roadmap.md` のうち、`TensorExpr` をテンソル意味論の
最終的な実行主体とする方針は本設計で置き換える。`TensorExpr` は
surface parser、source diagnostics、定義展開、静的な添字・配置診断、runtime bridge に限って残し、
`.fme` から高水準 Egison 式を生成する frontend とする。

## 1. 責務境界

目標パイプラインは次である。

```text
.fme
  -> fec frontend
       parse / scope / source span / static diagnostics
  -> generated Egison
       context / field descriptor / runtime tensor-valued equations
  -> Egison semantic kernel
       tensor indices / operators / discrete geometry
  -> Formura backend
       component projection / grid lowering / storage planning / printer
  -> .fmr
```

### `fec` に残す責務

- `.fme` の構文解析と source span
- field、parameter、extern、boundary、raw block の宣言検査
- `let` / `local` の逐次 scope と、initializer から step binding・primed field を参照しない検査
- dimension、mode、backend 制約の早期診断
- field の論理宣言を Egison 用 descriptor に変換する処理
- LHS の添字数・上下から得る rank/variance signature と、自由添字・縮約の静的診断
- component basis を列挙する保守的な placement 整合性診断
- `TensorExpr` から hygienic な Egison runtime tensor expression を組み立てる bridge
- Formura の物理 storage layout、prime/time level、補助 field の lifetime
- Egison の実行エラーを `.fme` の位置へ戻す source map

placement 診断は Haskell に残る frontend static oracle である。これは不正な式を
Egison 実行前に `.fme` の位置で報告するため、全 component basis と縮約 dummy の候補を列挙して
配置整合性を保守的に検査する。stencil や component 式を生成する lowering ではなく、
実行時の配置・微分の意味の権威は引き続き Egison の `FE.componentPlacement` /
`FE.gridDerivativeChain` にある。

### Egison に移す責務

- `withSymbols`、添字補完、転置、縮約、tensor lifting
- `grad`、`divg`、`curl`、`d`、`hodge`、`delta`、`lb` の数学的意味
- tensor-valued user `def` の評価と合成
- form degree の推論
- runtime tensor の shape / rank / index variance signature の最終検査
- component index と grid policy からの格子配置推論
- source/target placement に基づく離散微分の lowering

### Formura backend に置く責務

- target tensor と RHS tensor の対応付け
- symmetric / antisymmetric / form の独立成分 projection
- Egison function symbol から Formura storage 名への変換
- grid offset、shift、stencil、metric coefficient の Formura 表現
- 最終 `.fmr` の構成と表示

判断基準は次である。

> Formura の storage 名や配列 offset なしに数式として定義できる処理は Egison、
> 物理成分・保存期間・Formura 構文を選ぶ処理は Formura backend に置く。

## 2. Tensor introspection

Egison の runtime tensor は shape と、現在付いている添字列をすでに保持している。
shape は既存の `tensorShape`、省略軸数は既存の `dfOrder` で取得できるため、
Egison 本体に追加する最小 primitive は `tensorIndices` とする。

概念 API:

```egison
inductive TensorIndex :=
  | SubIndex MathValue
  | SupIndex MathValue
  | DiagIndex MathValue
  | UserIndex MathValue

tensorIndices : Tensor a -> [TensorIndex]

def tensorSignature t :=
  (tensorShape t, tensorIndices t)
```

`tensorSignature` は core primitive にせず、既存 primitive を組み合わせる library
function とする。`DF` は evaluator 内部の anonymous-axis bookkeeping なので公開しない。
multi-index は公開前に通常の index 列へ desugar する。

例:

```egison
def T := generateTensor (\[i, j] -> 10 * i + j) [2, 3]

tensorSignature T
-- ([2, 3], [])

withSymbols [i] (tensorSignature T_i)
-- ([2, 3], [SubIndex i])

withSymbols [i, j] (tensorSignature T_i~j)
-- ([2, 3], [SubIndex i, SupIndex j])
```

`dfOrder T`、`dfOrder T_i`、`dfOrder T_i~j` はそれぞれ `2`、`1`、`0` になる。
これは differential form の degree を

```text
tensor rank - attached index count
```

として得る既存の index completion 則そのものである。

bare binding の省略軸は runtime tensor 上では index なしである。例えば
`def E := generateTensor ... [3]` の signature は `([3], [])` であり、既定の
下添字は leaf function symbol `E_1`、`E_2`、`E_3` に記録される。
field variance や symmetry を `tensorSignature` に詰め込まず、target tensor の
leaf symbol と field descriptor をそれぞれの情報源とする。

## 3. Whole-tensor equation printer

生成 Egison は成分別の `feqE1`、`feqE2`、... を作らず、field descriptor と
policy つき tensor-valued RHS を Formura backend に渡す。

```egison
def rhsE := E + dt * FE.curl (feTensorDerivative Collocated Collocated) feAxisIds B
def rhsB := B - dt * FE.curl (feTensorDerivative Collocated Collocated) feAxisIds E'

def feSteps :=
  FMR.fieldEqs fePrinterContext (nth 1 feFieldDescriptors) (Collocated, rhsE)
  ++ FMR.fieldEqs fePrinterContext (nth 2 feFieldDescriptors) (Collocated, rhsB)
```

現在の実装は次を行う。

1. descriptor 自体の shape / variance / layout / projection / storage mapping を検査する
2. descriptor の policy / shape と RHS tensor の policy / `tensorShape` が等しいことを検査する
3. descriptor の independent-component projection だけを tensor から取り出す
4. 同じ descriptor の component-to-storage mapping で Formura の LHS 名を得る
5. 各 RHS component を既存の `FMR.show` で表示する

これは Formura backend helper であり、Egison core の component enumeration
primitive ではない。通常の tensor 表示は `show` で完結する。

plain tensor は全成分を row-major に射影する。symmetric、antisymmetric、form は物理
storage が full tensor より少ないため、field descriptor が持つ canonical component
projection を backend が適用する。数式本体を storage 成分ごとに生成する必要はない。
`FMR.fieldNameMappings`、`FMR.fieldEqs`、`FMR.fieldInits` はすべて同じ descriptor を使うため、
generated runtime では policy table・出力名リスト・projection を独立の source data として
管理しない。indexed CAS initializer も、LHS の rank/variance を持つ単一の runtime tensor を
`generateTensor` で作り、`FMR.fieldInits` が descriptor の独立成分だけを射影する。
成分ごとの Haskell lowering は残さない。raw initializer は Formura 式をそのまま受け取る
明示的な低水準経路であり、この tensor runtime の対象外である。

## 4. Grid policy

任意の placement vector を field や式へ保存しない。field が持つ配置情報は次の
3値だけとする。

```egison
inductive GridPolicy :=
  | Collocated
  | Primal
  | Dual
```

### 表層構文と既定値

```formurae
field u                         -- Collocated
field E_i                       -- Collocated

field v~i @ primal              -- index-parity staggered
field sigma{~i~j} @ primal

field E : 1-form                -- Primal is the form default
field B : 2-form                -- Primal is the form default
field H : 1-form @ dual         -- explicit dual storage
```

規則:

| declaration | policy |
|---|---|
| scalar / vector / tensor without an attribute | `Collocated` |
| `@ collocated` | `Collocated` |
| `@ primal` | `Primal` |
| `@ dual` | `Dual` |
| `k-form` without an attribute | `Primal` |

現在の `@ staggered` は `@ primal` へ置き換える。後方互換 shim は残さず、parser、
examples、tests、documents を同じ変更で更新する。

`mode collocated` / `mode dec` は利用できる演算子と離散化規約を選ぶ宣言であり、
個々の field policy とは別である。例えば elastic model は collocated tensor
operators と `@ primal` fields を同時に使える。

## 5. Placement inference

補完後の成分添字列を `I = [i_1, ..., i_r]` とする。各空間軸 `a` に対し、

```text
chi_a(I) = count(m where i_m = a) mod 2
```

を計算する。boolean placement bit は次で定める。

```text
Collocated: bit_a = 0
Primal:     bit_a = chi_a(I)
Dual:       bit_a = 1 xor chi_a(I)
```

Formura の座標 offset は `bit_a / 2` である。

例:

```text
Primal v_1       -> [1/2, 0,   0]
Primal sigma_11  -> [0,   0,   0]
Primal sigma_12  -> [1/2, 1/2, 0]
Primal B_12      -> [1/2, 1/2, 0]
Dual A_1         -> [0,   1/2, 1/2]
```

したがって配置は rank や添字数だけではなく、具体的な成分添字の多重集合から
決まる。`sigma_11` と `sigma_12` は同じ rank/index count だが配置が異なる。
一方、`Collocated` / `Primal` / `Dual` 自体は数式だけから一意に決まらないため、
field declaration または operator propagation から得る。

## 6. Operator propagation

operator は任意の placement vector ではなく `GridPolicy` を伝播する。

```text
policy(partial_a X) = policy(X)
policy(d X)         = policy(X)
policy(hodge X)     = flip(policy(X))
policy(delta X)     = policy(X)
policy(flat X)      = policy(X)
policy(sharp X)     = policy(X)

flip(Collocated) = Collocated
flip(Primal)     = Dual
flip(Dual)       = Primal
```

`partial_a` と `d` は component index に軸 `a` を追加するので、placement parity の
軸 `a` が自動的に反転する。source/target の explicit placement 引数は不要になる。

`curl` は定義に従う。collocated vector calculus の `curl` は `Collocated` を保つ。
form として `hodge (d X)` から定義した curl は `hodge` により primal/dual を反転する。
3次元の vector proxy として使う場合も同じで、`Primal` vector の curl は `Dual`、
`Dual` vector の curl は `Primal` になる。

加減算と assignment は、結果成分ごとに inferred placement が一致することを
要求する。不一致は暗黙補間せず error にする。異なる配置間の積や補間は別の
operator として将来設計する。数値、parameter、座標に依存しない symbol は
placement-polymorphic とし、通常の `Collocated` field と同一視しない。
metric coefficient は backend が target placement で sample する。

離散微分は target component basis が決まるまで評価を遅延する。native `FE.*` operator は
各 tensor component を作るとき、target/source policy、target/source basis、微分軸列を
generated `feTensorDerivative` へ渡す。callback 内の `FE.componentPlacement` と
`FE.gridDerivativeChain` が source/target placement と stencil を決める。equation printer は
完成した RHS tensor から descriptor の独立成分だけを射影する。

### Placement-neutral な値と配置済みの値

runtime binding の policy は `Maybe GridPolicy` として扱う。field やその微分を参照して
配置が一意に決まる式は `Just Collocated` / `Just Primal` / `Just Dual`、数値・parameter・
座標に依存しない scalar `let` のようにどの格子でも同じ式は `Nothing` である。
したがって `let c = 2` は Primal field と Dual field のどちらにも掛けられるが、
Primal field と Dual field を同じ項で加えたり縮約したりすることはできない。
indexed `let` は LHS の添字数から rank 1/2、添字の上下から variance signature を得る。
RHS を runtime tensor として評価した後、Egison の `FE.checkedTensorSignature` が
`tensorShape`、`tensorVariances`、`dfOrder` を最終検査する。

CAS initializer は「target の絶対 offset」を常に足さない。RHS が配置済みなら、

```text
relative offset = placement(target policy, component basis)
                - placement(RHS policy, component basis)
```

を `FE.relativePlacement` で計算し、同じ配置なら shift せず、異なる場合だけ相対 shift する。
placement-neutral な解析式は target component の位置で sample する。これにより、すでに
Primal/Dual 格子上にある field を initializer で参照したときの二重 shift を防ぐ。
scalar initializer と indexed whole-tensor initializer は同じ規則を使う。
ただし、explicit coordinate (`x`, `y`, ...) と non-collocated field-valued RHS を同じ
initializer 式に混在させると、単一の `substitute` では「座標だけ target 位置で評価し、field
reference だけ source から target へ移す」ことを表現できない。この場合は誤った式を生成せず
明示的に拒否する。必要なら座標依存部分を別の解析関数または同一配置の field として分離する。

### 座標微分と symbolic reducer

固定軸微分 `∂_x` / `∂^m_x` は宣言された座標軸を直接選ぶ。symbolic 軸微分
`∂_i u` / `∂^m_i u` は、結果 component `i` ごとに同じ軸で微分する rank-1 tensor として
`FE.diagonalCoordinateDerivative` が生成する。radius 1 は placement-aware な
`FE.partialChainTensor` を使い、quoted derivative の wider radius は generated `∂` callback を使う。
wide stencil の奇数階微分で半セル間の移動が必要な場合は、未定義の補間を暗黙に作らず
静的エラーにする。

`contractWith (+)` / `contractWith (*)` は通常の Egison reducer を使う。`max` のような
名前付き reducer は symbolic field expression を Haskell/Egison の大小比較で評価せず、
`FE.symbolicBinary "max"` が backend function call として保持する。runtime printer は
field component の関数適用を grid reference、その他の function symbol を通常の Formura
関数呼び出しとして区別する。

## 7. Differential-form representation

generated Egison の form は次の値で表す。

```text
(GridPolicy, Tensor MathValue)
```

- degree は `dfOrder tensor` から得る
- components は tensor 自身を走査する
- `d` は policy を保ち、index completion で degree を1増やす
- `hodge` は degree を `n-k` にし、policy を反転する
- `delta` は `hodge d hodge` から導出され、元の policy に戻る

`FE.hodgeForm dim coefficient` の coefficient callback は source policy と source basis を
受け取る。Euclidean metric では1、直交計量では source component placement で sample した
`sqrt(g) / product(i in basis, h_i^2)` を返す。

field の永続的な policy は descriptor に置く。生成 field wrapper (`Ef` / `Bf` と
primed 側の `EfN` / `BfN`)および `hodge` などが作る中間 form は、小さな
`(policy, tensor)` 値を持つ。一般の `PlacedExpr` や placement vector は導入しない。

full Tensor は重複 index を 0、permutation を正準な昇順成分への符号付き参照にする。
backend descriptor は `FE.formBasis` と一致する昇順基底だけを projection し、
`FE.formComponents` は同じ順序を取り出す pure helper として残る。旧
`(complex, degree, [components])` とその `formComps` / `formDeg` helper は削除済みである。

## 8. Field descriptor

`fec` の `FieldDecl` は最終的に次の論理情報を一度だけ生成する。

```text
FieldDescriptor =
  base name
  GridPolicy
  tensor shape
  declared variance
  layout (scalar / vector / symmetric / antisymmetric / full / form)
  physical component projection
  component-to-storage mapping
```

生成 `.egi` では、この情報を
`(name, policy, shape, variances, layout, projection, storageMapping)` の data tuple として
`feFieldDescriptors` に一度だけ出す。論理 tensor shape、variance、policy は Egison
evaluator と grid lowering が使い、physical projection、storage name、component order は
Formura backend が使う。generated runtime の `feFieldPolicies` と `feFieldNames` は descriptor
から導出する。
`Vector Bool` / `Tensor2 Bool` や `fdStaggered :: Bool` のように layout と placement を
同じ値へ埋め込まない。

Haskell 側の移行後の型は概念的に次となる。

```haskell
data GridPolicy = Collocated | Primal | Dual

data Kind
  = Scalar
  | Vector
  | Form Int
  | SymM
  | AntiM
  | Tensor2

data FieldDecl = FieldDecl
  { fdName   :: String
  , fdIndex  :: Maybe FieldIndex
  , fdLayout :: FieldLayout
  , fdPolicy :: GridPolicy
  , fdKind   :: Kind
  }
```

## 9. Implementation phases

### Phase 1: Tensor introspection and whole-tensor printing

- [x] Egison core に `tensorIndices` を追加する
- [x] focused test で Sub/Sup/Diag、`withSymbols` の内外、`dfOrder` を検証する
- [x] `FMR.tensorEqs context target rhs` を追加する
- [x] collocated Maxwell の vector equations を whole-tensor RHS で生成する
- [x] `.fmr` と既存の数値 check が変更前と同じであることを確認する

Phase 1 の導入時点では RHS の各 component 式を `fec` が tensor literal へ束ねていたが、
Phase 4 で標準座標演算子の評価も Egison へ移し、Phase 7 で一般の添字式も runtime tensor
bridge へ移した。旧 component 経路は削除済みであり、`TensorExpr` は static oracle と
Egison expression emitter にだけ使う。Phase 2 の完全 descriptor 統合後は、暫定 API
`FMR.tensorEqs` / `FMR.formEqs` 自体も削除し、`FMR.fieldEqs` に一本化した。

### Phase 2: GridPolicy syntax and descriptors

- [x] `GridPolicy` を Haskell/Egison に追加する
- [x] `fdStaggered :: Bool` を `fdPolicy :: GridPolicy` へ置き換える
- [x] `Vector Bool` / `Tensor2 Bool` から placement flag を除く
- [x] `@ collocated` / `@ primal` / `@ dual` を parse する
- [x] `@ staggered` を削除し、全 examples/tests/docs を更新する
- [x] 型付き field-policy table を generated Egison context に出す
- [x] shape / variance / layout / projection / storage mapping を含む完全な field descriptor を生成し、
  policy table と backend projection metadata の重複を統合する
- [x] output が既存 stencil と一致する段階では Haskell placement を oracle として比較する
- [x] 最初の end-to-end policy test は `E_i @ primal` / `B_i @ dual` の vector Yee
  Maxwell とし、collocated Maxwell と同じ rank/index count でも別配置になることを
  固定する

### Phase 3: Index-parity placement lowering

- [x] Egison runtime に component-index parity と policy-to-placement を実装する
- [x] generated Egison が target/RHS の policy と component indices から placement を導出する
- [x] vector、symmetric rank-2、full rank-2 の個別 placement helper を置き換える
- [x] 標準 tensor operator の微分 chain と target/source placement からの stencil 選択を
  `FE.gridDerivativeChain` と generated `feTensorDerivative` callback へ移す
- [x] elastic3d を vertical acceptance test とする
- [x] policy/placement 不一致の assignment・加減算・curl を拒否する
- [x] indexed initializer と一般の添字式から Haskell の component lowering / parity fallback を削除する
- [x] placement-neutral / located binding を区別し、initializer を target/RHS の相対配置で sample する
- [x] Haskell の component-basis 列挙は早期エラー用の frontend static oracle に限定する

### Phase 4: Tensor-valued operators in Egison

- [x] `grad`、`dGrad`、`divg`、`curl`、`lap`、`hessian` の tensor-valued shared Egison
  definitions と strict tests を追加する
- [x] 標準 operator marker を user `def` と同じ展開経路で保持し、generated equations を
  `FE.grad` / `FE.dGrad` / `FE.divg` / `FE.curl` / `FE.lap` / `FE.hessian` へ接続する
- [x] native subset の standard operator RHS から Haskell component specialization を除く
- [x] native subset 外の複合式、任意の user tensor `def`、添字縮約を runtime Egison 評価へ移し、
  production の `ixExpand` fallback を削除する。`expandDefs` は surface の user `def` 解決だけに使う
- [x] `contractWith` の `+` / `*` と、名前付き symbolic reducer を whole tensor のまま評価する
- [x] 固定軸・symbolic 軸、階数・radius を持つ座標微分を runtime tensor bridge へ接続する
- [x] 複合微分 operand の自由添字を source component basis として保持し、staggered tensor
  (`∂_x (A_i * c)` など) も正しい source placement から評価する
- [x] collocated Maxwell、divergence2d、elastic3d を回帰テストにする

`feTensorDerivative targetPolicy sourcePolicy targetBasis derivativeAxes sourceBasis value`
が grid 固有 callback である。`FE.gridDerivativeChain` は微分軸列を一度に受け取り、
同一軸2回なら `dC2`、mixed derivative なら `dC` の合成、配置が異なる場合は中間
placement を推論して `dYee` を選ぶ。このため Hessian/Laplacian の対角成分も
`dC (dC u)` ではなく compact な二階 stencil になる。標準名は marker を通して native
identity を保つため、高階関数へ渡しても native operator に戻り、ユーザーの同名 `def`
は従来どおり標準定義を shadow する。

### Phase 5: Tensor differential forms

- [x] form field を canonical antisymmetric Tensor として生成する
- [x] `(complex, degree, [components])` を `(policy, tensor)` へ置き換える
- [x] `d`、`hodge`、`delta` を shared Egison geometry library へ移す
- [x] `dfOrder` と Tensor projection を degree/component generation の情報源にする
- [x] descriptor-driven `FMR.fieldEqs` で whole-form equation から独立成分だけを
  backend projection する
- [x] maxwell_dec と `assert-dd-zero` を acceptance test にする
- [x] model ごとの d/hodge/codiff 実装と `formComps` / `formDeg` tuple helpers を削除する
- [x] grid/metric 固有部分は generated `feFormDerivative` / `feHodgeCoefficient`
  callback に縮小する

### Phase 6: Metric and `lb`

- [x] induced metric、直交計量とその逆、体積要素、Hodge coefficient の純粋な
  記号式を `lib/formurae-geometry.egi` へ移す
- [x] `lb` の flux と flux-divergence 合成を `FE.lbFlux` / `FE.lbFromFluxes` として
  Egison で評価し、生成コードは格子固有の gradient / divergence / coefficient callback
  だけを渡す
- [x] metric/Hodge/Laplace--Beltrami の純粋な式を strict geometry library test で検証する
- [x] 直交計量の rank-1 musical map `FE.flat` / `FE.sharp` を geometry context へ統合する
- [x] `hodge` の source basis coefficient を policy/placement で sample し、metric-aware form
  Hodge と、それから合成される `codiff` を generated equation path へ接続する
- [x] 複数の distinct `lb` source を request ごとの flux/result bundle として schedule し、
  metric coefficient/volume fields はモデル内で共有する
- [x] `BackendRequest` / `LbPlan` / `AuxFieldPlan` により、backend planner が
  auxiliary coefficient/volume/flux fields を lifetime・role・placement つきで materialize する
- [x] token scan の `lbPass` / `lbTargets` を削除し、span を保持する `TensorExpr` の
  構造変換で `lb` request を結果 binding へ lower する。残る metric 生成分岐は
  token ではなく `LbPlan` から駆動する

現在の境界では、純粋な metric/Hodge/Laplace--Beltrami/musical-map 公式は Egison が評価し、
Haskell の backend planner は shared `ca` / `cb` / `cc` / `sg` と、request ごとの flux bundle の
宣言・初期化・更新・lifetime だけを計画する。保存済み flux は request ごとの
`feLbStoredFlux...` を通して divergence から参照され、全 request の flux 更新を user field 更新より
前に emit する。同じ source の request は共有し、異なる scalar source は独立の result binding を持つ。
各 request の operand は引き続き unindexed collocated scalar field に限定し、compound source、
primed source、initializer 内の `lb` は明示診断で拒否する。

metric-aware Hodge は `FE.orthogonalHodgeCoefficient` を source basis の配置で sample する。
`flat` / `sharp` は直交計量 `g_ii = h_i^2` に対する純粋な rank-1 musical map であり、policy を保ち、
generated `feMusicalScale` が各 component basis の配置で `h_i` を sample する。
補間・積分・de Rham map・reconstruction を暗黙には行わない。非対角計量、一般 rank tensor、
cochain との写像は未実装である。`BackendRequest` は transliteration 前の `.fme` に対応する
path/line/column と、user `def` ごとの definition-site / call-site expansion trace を保持する。
request が nested definition や initializer を通っても、展開後文字列の列番号へ退避しない。

### Phase 7: Shrink `TensorExpr`

- [x] standard coordinate operator の native identity を marker で保持し、対応する
  whole scalar/rank-1/rank-2 RHS を成分 helper なしで emit する
- [x] field projection、policy、shape、variance、layout、storage mapping を descriptor-driven
  `FMR.fieldEqs` に統合する
- [x] offset 付き lexer で重複部分式・nested expression の正確な span を保持し、直接の backend
  request を `.fme` path/line/column へ対応付ける
- [x] strict result rank/variance signature の最終検査を Egison の `tensorShape` / `tensorIndices`
  (`tensorVariances`) / `dfOrder` に移す
- [x] user `def` substitution trace と transliteration 前の column を含む完全な source map を保持する
- [x] indexed equation、implicit vector equation、rank-1/rank-2 indexed `let`、indexed initializer を
  whole runtime tensor として emit する
- [x] runtime binding の逐次 scope、self/forward reference、initializer scope を静的に検査する
- [x] `TensorExpr` を surface AST / user `def` 展開 / diagnostics / runtime bridge emitter に縮退させる
- [x] production 経路から Haskell の `ixExpand` / `ixExpandInitializer` と legacy component operator
  expansion を削除する
- [x] `strictEinstein` は削除せず、自由添字・variance・明示縮約を検査する surface diagnostic として
  責務を限定する
- [x] Haskell placement validator は削除せず、Egison 実行前の frontend static oracle として
  責務を限定する

Phase 7 の完了条件は、Haskell の AST や静的検査をなくすことではなく、Haskell が
数式を storage component ごとに実行・特殊化する経路をなくすことである。現在は native marker に
収まらない複合式も `RuntimeTensorExpr` が hygienic な symbolic index を付けて Egison へ渡し、
indexed `let` と initializer は `generateTensor` で whole tensor を materialize する。
`strictEinstein` は LHS に対する自由添字と上下、未縮約 diagonal を `.fme` の位置で報告するだけで、
結果 tensor の shape/variance の権威は `FE.checkedTensorSignature` にある。basis-aware な Haskell
placement validator も、配置不一致を source-level error にするための保守的な oracle であり、
stencil 選択や出力式生成には使わない。

source span 自体は token offset を保持し、transliteration は生成文字ごとに
元ソースの line/column を持つため、multiline initializer を空白結合しても物理行を失わない。
同じ部分式が複数回現れても後続出現を
先頭へ誤対応させない。definition substitution は本体と実引数それぞれの origin を保ち、
definition/call の組を trace として積む。

## 10. Acceptance tests

各 phase は次を満たしてから旧経路を削除する。

### Source diagnostics

- 同じ部分式の複数出現と nested application がそれぞれ固有の span を持つ
- Unicode 名の transliteration で文字数が変わっても、診断は元 `.fme` の列を示す
- user `def` の request は request 自体の definition-site とすべての call-site を示す
- nested user `def` と initializer の backend request でも provenance trace が欠落しない
- multiline initializer の request は実際の継続行を示し、raw fallback は識別子内の `lb` を誤検出しない

### Egison core

- bare rank-1/rank-2 tensor の `tensorShape` / `tensorIndices` / `dfOrder`
- Sub/Sup/Diag index の構造化出力
- `withSymbols` の内側では index が見え、外側では local index が除去される
- `generateTensor` 内の function symbol 名補完が維持される

### Whole-tensor printer

- descriptor と RHS の policy/shape mismatch は明示 error
- collocated Maxwell の generated `.egi` に component-specific `feqE1` 等がない
- native `grad` / `dGrad` / `divg` / `curl` / `lap` / `hessian` が component-specific helper を作らない
- native subset 外の indexed equation と user `def` の複合式も component-specific helper を作らない
- rank-1/rank-2 indexed `let` は LHS の rank/variance を保つ bare tensor binding になる
- indexed initializer は成分列ではなく1個の `FMR.fieldInits` 呼び出しになる
- result の shape/variance/`dfOrder` mismatch は `FE.checkedTensorSignature` が拒否する
- symbolic dummy index は generated binder や関数名を capture しない
- `contractWith max` のような named reducer は symbolic backend call のまま残る
- generated `.fmr` と C check の結果が変更前と一致する
- prime、variance、field-name mapping、projection が同じ descriptor から得られる

### Grid policy

- default tensor field は Collocated
- default form field は Primal
- `@ primal` / `@ dual` component placement
- `sigma_11` と `sigma_12` の parity 差
- `partial_a` が軸 `a` の placement bit を反転する
- `hodge` が Primal/Dual を反転する
- policy/placement の異なる加算と assignment は error
- placement-neutral な `let` は Primal/Dual のどちらの式でも使える
- located operand 同士の加算・積・縮約は component basis ごとに配置が一致する
- initializer は target/RHS の relative placement で評価され、同一配置の field を二重 shift しない
- fixed-axis と symbolic-axis の微分が同じ runtime derivative bridge を使う

raw `=` initializer は Formura 式をそのまま保持しており、現在は配置推論による
座標 shift を適用できない。完全自動化するときは CAS initializer へ移すか、raw init
を明示的に低水準構文として扱う。移行中に既存 raw init の `i+0.5` を二重 shift
しない。

### Physical layout

- symmetric tensor は対角＋上三角だけを保存する
- antisymmetric tensor/form は上三角 off-diagonal だけを保存する
- full tensor は全成分を保存する
- projection は数式の storage-component specialization を要求しない

## 11. Implementation discipline

- 各 phase の新経路は既存経路を一時的な test oracle として比較してよいが、
  一致確認後は旧経路を削除し、恒久的な compatibility branch を残さない。
- generated `.egi` の文字列差だけでなく、最終 `.fmr` と既存 check driver で検証する。
- Egison core の変更は小さな mini-test から始め、`gtimeout` を付けて実行する。
- 公開挙動を変更した phase では本 design と `DSL-DESIGN.md` の実装状況を更新する。
- `fec` は数式を component ごとに再実装・lowering せず、Egison へ data/metadata と高水準方程式を渡す。
  source-level の早期診断に必要な自由添字検査と placement oracle は frontend に残すが、
  runtime signature、tensor 評価、stencil 選択の意味は Egison kernel を権威とする。
