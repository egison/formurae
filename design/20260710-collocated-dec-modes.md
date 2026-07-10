# `mode collocated` / `mode dec` の設計と実装手順

Date: 2026-07-10

Implementation status (2026-07-10):

- `mode collocated` / `mode dec`、重複検査、旧 `use` からの推論と warning、
  mode/use 競合検査を実装済み。
- `collocated` prelude の `grad` / `dGrad` / `divg` / `curl` / `lap` / `Δ` は
  通常の TensorExpr `Def` として自動ロードする。
- `mode dec` は既存の structured Yee/form context (`dForm`, `hodge`, `codiff`) を
  `use` なしで自動ロードし、`codiff (d a)` のような unary form operator 合成を扱う。
- 現在の form storage は積分 cochain ではなく staggered 格子上の sampled component
  であり、`dForm` は `dYee` により格子幅で割る。この段階を厳密な incidence-only
  cochain DEC と同一視しない。
- `flat` / `sharp` と DEC vector aliases は未実装。metric だけでは決まらない
  de Rham map / reconstruction / interpolation policy を先に設計する。

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
- 既存 `.fme` との互換のため、当面は `mode` 省略時を `collocated` とみなす。

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
- 省略時は移行期間のため `mode collocated` とみなす。
- 将来的に `mode` 省略を warning にするかは、examples 移行後に判断する。

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

自動ロードする基本演算子:

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
  Δ / lap は必要なら prelude def として提供するか、従来どおり user def に残す。
```

意味:

- `field u : scalar` は格子点に置く。
- `field X_i` は各成分を同じ格子点に置く。
- `field X_i @ staggered` は既存の配置規則に従う。
- `∂_x` は collocated field では中心差分へ下りる。
- `@ staggered` field に対する `∂_x` は target/source placement を見て `dYee` へ下りる。
- pointwise product は現在どおり同じ評価点での積とする。
- metric は内部的には存在するが、collocated vector calculus は当面
  Euclidean/cartesian を基本意味とする。

標準 `curl` は、軸や成分を列挙せず、prelude def として次のように定義する。

```formurae
def curl X =
  withSymbols [i, j, k]
    (epsilon_i~j~k . ∂_j X_k)
```

標準 `divg` は、名前捕獲できない内部 Cartesian identity metric を使って定義する。
`collocated` prelude は Euclidean/cartesian 演算子なので、別途宣言された
`metric scale` / `embedding` をこの metric と混同しない。

```formurae
def divg X =
  withSymbols [i, j]
    (cartesianMetric~i~j . ∂_i X_j)
```

`grad` / `dGrad` も同じ prelude def として扱う。

```formurae
def grad u = withSymbols [i] ∂_i u
def dGrad X = withSymbols [i, j] ∂_i X_j
def lap u = withSymbols [i, j] (cartesianMetric~i~j . ∂_i ∂_j u)
def Δ u = lap u
```

ここで `cartesianMetric` は説明用の名前であり、実装ではユーザーが参照・捕獲できない
`FormuraeInternalCartesianMetric` AST name を使う。

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

derived vector calculus:
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
- `grad` / `curl` / `divg` は `d` / `hodge` / `flat` / `sharp` から派生させる。

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

## 6. `use` の扱い

標準演算子に対する `use vector-calculus` / `use exterior-calculus` は deprecated にする。

移行期間の扱い:

- 既存 `.fme` を壊さないため、当面 `use` は parse し続ける。
- `use vector-calculus { ... }` があって `mode` がない場合は `mode collocated` と同じ扱いにする。
- `use exterior-calculus { ... }` があって `mode` がない場合は、当面は既存挙動維持のため
  DEC 文脈を有効化する。ただし warning を出す段階を設ける。
- `mode collocated` と `use exterior-calculus` の併用、または `mode dec` と
  `use vector-calculus` の併用は、移行後はエラーにする。

将来:

- 標準演算子の `use` は削除する。
- `use` を残すなら、外部/実験的ライブラリの読み込みだけに限定する。

## 7. 実装手順

### Phase 1 (implemented): syntax と Model に mode を追加する

- `Syntax.hs` に `Mode = CollocatedMode | DecMode` を追加する。
- `Model` に `mMode :: Maybe Mode` または `mMode :: Mode` を追加する。
- parser に `mode collocated` / `mode dec` を追加する。
- `mode` が複数回出たらエラーにする。
- 省略時は `CollocatedMode` にする。
- `README.md` と `DSL-DESIGN.md` の `use` 説明に deprecated 方針を書く。

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

将来の reconstruction policy 導入後に `flat` / `sharp` / vector aliases を追加する。

`mode` が演算子の意味を決めるため、`missingUse` は廃止または mode 検査へ置き換える。

### Phase 3 (implemented): collocated mode を現行挙動として固定する

- 現在の `∂_x` / `∂_i` lowering を `collocated` mode の実装として固定する。
- `@ staggered` field への座標微分は、既存の target/source placement つき `dYee` lowering を使う。
- `use vector-calculus` で生成 `.egi` に `def curl` / `def dGrad` を出す経路は撤去する。
- `curl` / `divg` / `dGrad` は prelude def 展開に一本化する。
- regression:
  - `field B_i` に対する `curl B_i` が中心差分になる。
  - `field X_i @ staggered` に対する `curl X_i` が `dYee` になる。
  - legacy `field B : vector` / `E' = curl B` も component 展開される。

### Phase 4 (implemented): dec mode の基本 context を自動ロードする

- `mode dec` では form context を無条件に生成する。
- `dForm` / `codiff` / `hodge` / `sigmaC` / `formBasis` を `use` なしで使えるようにする。
- `field E : 1-form` / `field B : 2-form` の既存 `maxwell_dec` を
  `mode dec` に移行する。
- `assert-dd-zero` は `mode dec` 専用機能として扱う。

### Phase 5 (pending): musical map と離散写像を分離する

最初は 3D Euclidean identity metric で型と配置を固定し、次に metric scale /
embedding へ広げる。

実装単位:

- `flat`:
  - vector expression -> covector/form field expression
  - component lowering は `g_i_j . X~j`
- `sharp`:
  - covector/form field expression -> vector expression
  - component lowering は `g~i~j . α_j`
- `deRham`: form field -> integral cochain
- `reconstruct`: cochain -> form field/vector
- form tuple `(complex, degree, representation, components)` と vector/tensor expression の
  橋渡しを AST または lowering helper で表す。

初期制限:

- `flat` / `sharp` は vector/covector の間だけ対応し、配置を暗黙変更しない。
- cochain との変換は必ず `deRham` / `reconstruct` を通す。
- 2-form と pseudovector の同一視は `curl` 実装に必要な範囲で扱う。
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

### Phase 7 (implemented for core conflicts): mode の混在を制限する

移行が済んだら、次をエラーにする。

```formurae
mode collocated
field E : 1-form
```

または:

```formurae
mode dec
use vector-calculus { curl }
```

ただし、`mode dec` でも vector field 自体は許す。禁止するのは
collocated semantics の vector-calculus を持ち込むことである。

## 8. テスト計画

compiler regression:

- `mode collocated` 省略時に既存 examples が通る。
- `mode collocated` 明示時にも既存 examples が通る。
- `use vector-calculus` なしで `curl` / `divg` が使える。
- `mode dec` では `d` / `δ` / `hodge` が `use` なしで使える。
- `mode dec` で `maxwell_dec` が通る。
- `mode collocated` と `mode dec` の混在エラーを検査する。

end-to-end:

- `make maxwell3d`
- `make maxwell_dec`
- `make divergence2d`
- `make elastic3d`
- `make metric_torus metric_sphere`

互換性:

- `mode` 省略の既存 `.fme` は当面 `collocated` として扱う。
- 既存 `use` は warning を出す段階までは受理する。
- 生成 `.egi` のバイト一致は可能な範囲で維持するが、standard operator の
  prelude def 展開化に伴う整形差は許容する。

## 9. 注意点

`collocated` と `dec` は単なる実装切り替えではない。

- `collocated` は pointwise product を自然に持つ。
- `dec` は degree / placement を自然に持つ。
- 非線形項や異なる degree の積は、DEC では補間・wedge・Hodge などの規約が必要になる。

したがって、`mode dec` は「collocated で書いた式をすべて自動的に同じ数値スキームへ
変換する」機能ではない。幾何的に意味のある field kind と演算子を明示するモードである。
