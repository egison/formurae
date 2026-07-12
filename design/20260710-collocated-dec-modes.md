# `mode collocated` / `mode dec` の設計と実装手順

Date: 2026-07-10

> **履歴文書:** 以下はcutover前の実装記録である。現行のmode、placement、form演算子の
> 責務境界は[20260711-pre-post-fec-pipeline.md](20260711-pre-post-fec-pipeline.md)を正とする。

Implementation status at the time (2026-07-11):

- `mode collocated` / `mode dec`、mode の必須化、重複検査を実装済み。
- `collocated` の `grad` / `dGrad` / `divg` / `curl` / `lap` / `hessian` は標準 marker を
  経由して共有 native `FE.*` tensor operator へ lower する。ユーザーの同名 `def` は shadow できる。
- `mode dec` は既存の structured Yee/form context (`dForm`, `hodge`, `codiff`) を
  `use` なしで自動ロードし、`codiff (d a)` のような unary form operator 合成を扱う。
- 現在の form storage は積分 cochain ではなく staggered 格子上の sampled component
  であり、`dForm` は `dYee` により格子幅で割る。この段階を厳密な incidence-only
  cochain DEC と同一視しない。
- `flat` / `sharp` は直交計量の rank-1 musical map として実装済みで、GridPolicy を保ち、
  補間・積分を行わない。metric だけでは決まらない de Rham map / reconstruction と
  DEC vector aliases は引き続き設計対象である。

このメモは、Formurae の数学演算子を `use vector-calculus` /
`use exterior-calculus` で個別に有効化する方針から、ファイル全体の離散化方針を
`mode` で明示する方針へ整理するための設計と実装手順をまとめる。

中心方針:

- Formurae には `collocated` と `dec` の2つの基本モードを置く。
- `mode` が基本演算子集合を決めるため、標準の `use vector-calculus` /
  `use exterior-calculus` は不要にする。
- `metric` は常に内部的に存在する。明示宣言がない場合は Euclidean identity metric とする。
- `collocated` は Euclidean/cartesian な簡潔表記のためのモードとする。
- `dec` は metric、配置、保存則を明示する幾何的なモードとする。
- `mode` は必須の top-level 宣言とする。

## 1. なぜ `use` ではなく `mode` か

`use vector-calculus { curl }` と `use exterior-calculus { d, δ }` は、
当初は「必要な数学演算子だけを座標文脈つきで生成する」ための宣言だった。
しかし `curl` / `divg` / `grad` の意味は、単にどの関数を import したかではなく、
ファイル全体がどの離散化を採用しているかに依存する。

例えば `curl` は2つの意味を持ちうる。

```text
collocated:
  curl X = coordinate finite-difference curl

dec:
  curl X = sharp (hodge (d (flat X)))
```

この2つは同じ連続極限を意図していても、格子配置、Hodge star、補間、保存性が
異なる。したがって `curl` を `use` で個別に有効化するより、`mode` で
離散化の哲学を先に固定し、そのモードの基本演算子を自動ロードする方が明確である。

## 2. 表層構文

新しい top-level 宣言を追加する。

```formurae
mode collocated
```

または:

```formurae
mode dec
```

制約:

- `mode` は top-level で1回だけ指定できる。
- `dimension` / `axes` と同じく、式の意味を決める文脈宣言として扱う。

例:

```formurae
mode collocated
dimension 3
axes x, y, z

field E_i
field B_i

step:
  E'_i = E_i + dt * curl B_i
```

```formurae
mode dec
dimension 3
axes x, y, z

field E : 1-form
field B : 2-form

step:
  E' = E + dt * δ B
  B' = B - dt * d E'
```

## 3. `collocated` モードの意味

`collocated` は既存の Euclidean/cartesian な簡潔表記を保つ。

現在自動ロードする基本演算子:

```text
coordinate derivative:
  ∂_x, ∂_y, ∂_z, ∂^m_x, ∂'^m_x, ...

indexed derivative:
  ∂_i, ∂~i

vector calculus:
  grad
  dGrad
  divg
  curl

scalar Laplacian aliases:
  lap とその alias Δ
```

意味:

- `field u : scalar` は格子点に置く。
- `field X_i` は各成分を同じ格子点に置く。
- `field X_i @ primal` / `@ dual` は component-index parity による配置規則に従う。
- `∂_x` は collocated field では中心差分へ下りる。
- `@ primal` / `@ dual` field に対する微分は target/source placement を見て `dYee` へ下りる。
- pointwise product は現在どおり同じ評価点での積とする。
- metric は内部的には存在するが、collocated vector calculus は当面
  Euclidean/cartesian を基本意味とする。

標準 `curl` の数学的意味は、概念的には次の添字式である。

```formurae
def curl X =
  withSymbols [i, j, k]
    (epsilon_i~j~k . ∂_j X_k)
```

実装はこれを Haskell で成分化せず、`FE.curl feTensorDerivative feAxisIds X` として
whole tensor のまま評価する。`FE.grad` / `FE.dGrad` / `FE.divg` / `FE.lap` /
`FE.hessian` も同じである。`feTensorDerivative` が target/source policy、component basis、
微分軸列を `FE.gridDerivativeChain` に渡し、`dC` / `dC2` / `dYee` を選ぶ。

`collocated` の標準 `divg` / `lap` は Euclidean/cartesian 演算子なので、別途宣言された
`metric scale` / `embedding` と混同しない。

```formurae
def divg X =
  withSymbols [i, j]
    (cartesianMetric~i~j . ∂_i X_j)
```

次の式は表層で同名 operator を上書きするときにも使える概念定義である。

```formurae
def grad u = withSymbols [i] ∂_i u
def dGrad X = withSymbols [i, j] ∂_i X_j
def lap u = withSymbols [i, j] (cartesianMetric~i~j . ∂_i ∂_j u)
def Δ u = lap u
```

ここで `cartesianMetric` は説明用の名前である。native 標準演算子自体は
`FormuraeInternalCartesianMetric` AST を生成しない。

## 4. `dec` モードの意味

`dec` は Discrete Exterior Calculus の演算構造を基本にする。現実装は structured
Yee 格子上の form component 表現であり、積分 cochain を使う厳密な DEC は次段階とする。

自動ロードする基本演算子:

```text
exterior calculus:
  d
  δ
  codiff
  hodge

metric bridge:
  flat
  sharp

将来の derived vector aliases:
  grad
  curl
  divg
```

field 配置:

```text
0-form: vertex / point
1-form: edge
2-form: face
3-form: cell
```

基本方針:

- 真の cochain DEC へ進む段階では、`d` は格子幅を含まない incidence ベースの
  離散外微分とし、metric / cell-volume factor は Hodge star に集約する。
- 現実装の `dForm` は sampled component に対する `dYee` であり `/ h` を含む。
- `hodge` は metric を使って primal/dual complex を移す。
- `δ` / `codiff` は Hodge star と `d` から定義する。
- `flat` / `sharp` は metric による vector/form 変換とする。
- 将来の `grad` / `curl` / `divg` は `d` / `hodge` / `flat` / `sharp` から派生させる。

3D での概念定義:

```text
grad f = reconstruct (d (deRham f))
curl X = reconstruct (hodge (d (deRham (flat X))))
divg X = -codiff (deRham (flat X))
```

最後の符号は現在の
`δ = (-1)^(n(k+1)+1) ⋆ d ⋆` convention による。3D の 1-form では
`δ(X♭) = -div X` になる。`deRham` / `reconstruct` は metric だけでは決まらず、
離散化・補間規約を表すため、これらを省略した vector aliases はまだ導入しない。

`dec` モードでは、`field E : 1-form` / `field B : 2-form` のような form field が
第一級の field kind になる。`field X_i` のような vector field も許す場合は、
`flat X` / `sharp α` を通して form field と橋渡しする。

## 5. metric は常に存在する

> **v2.1で置換済み:** metricが常に存在する方針は維持するが、公開ambient familyは
> `metric_i_j` / `inverseMetric~i~j`である。`metric g`は`g_i_j` / `g~i~j`を追加し、
> whole tensorを`g_#_#` / `g~#~#`で参照する。mixed metricは暗黙生成しない。詳細は
> [20260711-pre-post-fec-pipeline.md](20260711-pre-post-fec-pipeline.md) §3.5を参照する。

モードに関係なく、内部 metric は常に存在する。

```text
no metric declaration:
  g_i_j  and g~i~j have identity-matrix component values
  g~i_j  = δ~i_j
  g_i~j  = δ_i~j

metric scale [h1, ...]:
  orthogonal metric from Lame scale factors

embedding [...]:
  metric derived by CAS from the coordinate embedding
```

実装上は、surface name `g` が宣言されていなくても内部 metric tensor を持つ。
ユーザーが `metric g` を書いた場合は、従来どおり `g_i_j` / `g~i~j` などの
surface access を許す。

`flat` / `sharp` は内部 metric を直接参照する。

```formurae
flat X:
  α_i = g_i_j . X~j

sharp α:
  X~i = g~i~j . α_j
```

Euclidean identity metric では、成分値としては恒等変換になる。ただし DEC mode では
vector/covector の musical map と、form field/cochain 間の離散写像を分ける。
`flat` / `sharp` 自体に placement の補間・積分・再構成を暗黙に含めない。

## 6. 標準演算子の選択

標準演算子は `mode` により自動的に選択する。標準演算子のための `use` 宣言は
存在せず、`use` は構文として受理しない。

## 7. 実装手順

### Phase 1 (implemented): syntax と Model に mode を追加する

- `Syntax.hs` に `Mode = CollocatedMode | DecMode` を追加する。
- `Model` に `mMode :: Maybe Mode` を追加し、parse 完了時に必須性を検査する。
- parser に `mode collocated` / `mode dec` を追加する。
- `mode` が複数回出たらエラーにする。
- `mode` がなければエラーにする。
- `README.md` と `DSL-DESIGN.md` に mode 必須の方針を書く。

### Phase 2 (implemented): standard operator registry を mode keyed にする

現在の `standardDefs` を mode ごとに分ける。

```haskell
standardDefs :: Model -> [Def]
standardDefs m =
  dotDef : modeStandardDefs (mMode m) m
```

`collocated`:

- `grad`
- `dGrad`
- `divg`
- `curl`
- 必要なら `lap` / `Δ`

`dec`:

- `d`
- `δ`
- `codiff`
- `hodge`

`flat` / `sharp` は補間を含まない pure musical map として `dec` に登録する。
reconstruction policy 導入後に vector aliases を追加する。

`mode` が演算子の意味を決めるため、`missingUse` は廃止または mode 検査へ置き換える。

### Phase 3 (implemented): collocated operator を native Egison path へ固定する

- 現在の `∂_x` / `∂_i` lowering を `collocated` mode の実装として固定する。
- `@ primal` / `@ dual` field への微分は、target/source placement つき `dYee` lowering を使う。
- 標準 operator marker を mode ごとに登録し、whole-tensor `FE.*` 呼び出しへ lower する。
- `FE.gridDerivativeChain` が complete derivative axes から `dC` / `dC2` / `dYee` を選ぶ。
- regression:
  - `field B_i` に対する `curl B_i` が中心差分になる。
  - `field X_i @ primal` に対する `curl X_i` が `dYee` になる。
  - vector/rank-2 field の `E' = curl B` / `H' = hessian u` が native Tensor のまま残る。

### Phase 4 (implemented): dec mode の基本 context を自動ロードする

- `mode dec` では form context を無条件に生成する。
- shared `FE.dForm` / `FE.codiffForm` / `FE.hodgeForm` / `FE.formBasis` を `use` なしで使えるようにする。
- 旧 `sigmaC` と model 固有 form operator を削除し、`FE.componentPlacement` と generated
  `feFormDerivative` / `feHodgeCoefficient` callback へ置き換える。
- `field E : 1-form` / `field B : 2-form` の既存 `maxwell_dec` を
  `mode dec` に移行する。
- `assert-dd-zero` は `mode dec` 専用機能として扱う。

### Phase 5 (partially implemented): musical map と離散写像を分離する

pure musical map は 1D/2D/3D の Euclidean identity と直交 `metric scale` / `embedding`
について実装済みである。離散 cochain 写像は未実装のまま明示的に分離する。

実装単位:

- `flat`:
  - vector expression -> covector/form field expression
  - `FE.flat feH` が `X^i -> h_i^2 X^i` を評価する
- `sharp`:
  - covector/form field expression -> vector expression
  - `FE.sharp feH` が `alpha_i -> alpha_i / h_i^2` を評価する
- `deRham`: form field -> integral cochain
- `reconstruct`: cochain -> form field/vector

前2項は実装済み、後2項は pending である。form は旧 tuple ではなく
`(GridPolicy, Tensor MathValue)` を使う。

初期制限:

- `flat` / `sharp` は vector/covector の間だけ対応し、配置を暗黙変更しない。
- cochain との変換は必ず `deRham` / `reconstruct` を通す。
- 現実装は明示的 contravariant rank-1 vector と 1-form の間だけを扱う。
- 一般の tensor field への flat/sharp は後回し。

### Phase 6 (pending): dec mode の grad / curl / divg を定義する

3D の初期定義:

```text
grad f = reconstruct (d (deRham f))
curl X = reconstruct (hodge (d (deRham (flat X))))
divg X = -codiff (deRham (flat X))
```

実装上は、表層 def としてそのまま解決するのではなく、form tuple を返す
中間演算子として lowering する必要がある。

検証:

- `mode dec` Maxwell:

```formurae
field E : 1-form
field B : 2-form

step:
  E' = E + dt * δ B
  B' = B - dt * d E'
```

- `curl` 派生版:

```formurae
field X_i
field C_i

step:
  C'_i = curl X_i
```

この2つの配置と符号が想定どおりかを小さな manufactured solution で検査する。

### Phase 7 (implemented): mode の適用範囲を固定する

`mode collocated` では form field と `assert-dd-zero` を禁止し、`mode dec` では
form context を有効にする。`mode` のないファイルや標準演算子用の `use` はエラーにする。

## 8. テスト計画

compiler regression:

- `mode collocated` 明示時にも既存 examples が通る。
- `mode collocated` で `curl` / `divg` が使える。
- `mode dec` では `d` / `δ` / `hodge` が使える。
- `mode dec` で `maxwell_dec` が通る。
- `mode collocated` と `mode dec` の混在エラーを検査する。

end-to-end:

- `make maxwell3d`
- `make maxwell_dec`
- `make divergence2d`
- `make elastic3d`
- `make metric_torus metric_sphere`

生成 `.egi` のバイト一致は要件とせず、standard operator の native `FE.*` lowering、
descriptor-driven projection、新しい mode 必須仕様を基準に検証する。

## 9. 注意点

`collocated` と `dec` は単なる実装切り替えではない。

- `collocated` は pointwise product を自然に持つ。
- `dec` は degree / placement を自然に持つ。
- 非線形項や異なる degree の積は、DEC では補間・wedge・Hodge などの規約が必要になる。

したがって、`mode dec` は「collocated で書いた式をすべて自動的に同じ数値スキームへ
変換する」機能ではない。幾何的に意味のある field kind と演算子を明示するモードである。
