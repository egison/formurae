# 添字型つき field 宣言と strict Einstein 検査の実装手順

Date: 2026-07-09

## 目的

Formurae の添字記法を、ユークリッド格子上の成分展開としてだけでなく、
座標変換に対して意味のあるテンソル記法として扱えるようにする。

中心となる変更は次の3つである。

- `field` 宣言の時点で、その場が持つ添字の上下と対称性を宣言する
- field の rank、対称性、Formura 出力 layout は添字仕様から推論する
- 添字方程式を展開する前に、各項の自由添字と縮約添字を strict に検査する

これにより、次のような式を Formurae の正しい表層構文として書けるようにする。

```text
metric δ
field v~i @ staggered
field s{~i~j} @ staggered

step:
  v'~i = v~i + (dt / ρ0) * ∂_j s~i~j
  s'~i~j = s~i~j + dt * (λ * δ~i~j * ∂_k v'~k
                       + μ * (δ~i~k * ∂_k v'~j + δ~j~k * ∂_k v'~i))
```

ここで `δ` は `metric δ` で宣言されたユークリッド計量であり、
`δ~i~j` は反変計量として扱う。Kronecker delta の mixed identity は
別概念として残すが、`metric δ` 宣言下では2添字の `δ...` は計量名として
優先解決する。

## 1. 添字型つき field 宣言

新しい標準構文では、`vector`、`tensor`、`symmetric` のような kind は
表層で明示しない。field が scalar か tensor か、tensor なら rank、添字の上下、
対称性をどう持つかは、field 名に付いた添字仕様から決まる。

```text
field u
field v~i @ staggered
field w_i @ staggered
field s{~i~j} @ staggered
field T~i_j @ staggered
field F[_i_j] @ staggered
```

意味:

```text
u          scalar field
v~i       反変ベクトル
w_i       共変ベクトル
s{~i~j}   対称な反変2階テンソル
T~i_j     混合2階テンソル
F[_i_j]   反対称な共変2階テンソル
```

`@ staggered` は storage/layout の注釈であり、tensor の rank や kind ではない。
Formura 出力に必要な layout は、添字仕様から推論した内部情報として持つ。

```text
field u
  -> ScalarLayout

field v~i @ staggered
  -> Rank1Layout, variance = [Up], staggered = true

field s{~i~j} @ staggered
  -> SymRank2Layout, variance = [Up, Up], staggered = true

field T~i_j @ staggered
  -> FullRank2Layout, variance = [Up, Down], staggered = true

field F[_i_j] @ staggered
  -> AntiRank2Layout, variance = [Down, Down], staggered = true
```

### `[]` と `{}` の意味

`type-tensor-paper` の記法に合わせる。

```text
[...]  反対称
{...}  対称
```

根拠:

- `/Users/egisatoshi/PL/type-tensor-paper/main.tex:1338`
- `/Users/egisatoshi/PL/type-tensor-paper/main.tex:1342`
- `/Users/egisatoshi/PL/type-tensor-paper/main.tex:1345`

従って、対称応力テンソルは次のように書く。

```text
field s{~i~j} @ staggered
```

`field s[_i_j] @ staggered` は反対称テンソルを意味するため、
対称応力テンソルには使わない。

## 2. 内部表現

表層構文から `Kind` を直接受け取るのではなく、field が持つ添字仕様を保存し、
そこから Formura 出力 layout を推論する。

```text
data FieldIndex =
  FieldIndex
    { fiGroups :: [IndexGroup]
    }

data IndexGroup =
    Plain [IxPart]
  | Symmetric [IxPart]
  | Antisymmetric [IxPart]

data IxPart = IxPart Variance String
data Variance = VUp | VDown

data FieldLayout =
    ScalarLayout
  | Rank1Layout
  | SymRank2Layout
  | FullRank2Layout
  | AntiRank2Layout
```

例:

```text
v~i
  -> Plain [IxPart VUp "i"]

s{~i~j}
  -> Symmetric [IxPart VUp "i", IxPart VUp "j"]

F[_i_j]
  -> Antisymmetric [IxPart VDown "i", IxPart VDown "j"]
```

`Model` には、field 名から `FieldIndex` と推論済み `FieldLayout` を引ける情報を持たせる。
既存の `mFlds :: [(String, Kind)]` は、実装途中の wrapper としては残してよいが、
表層の真の情報源は次の `FieldDecl` に寄せる。

```text
data FieldDecl =
  FieldDecl
    { fdName      :: String
    , fdIndex     :: Maybe FieldIndex
    , fdLayout    :: FieldLayout
    , fdStaggered :: Bool
    }
```

`Kind` は Formurae 表層の型ではなく、既存 backend へ渡すための一時的な
互換表現としてだけ扱う。

## 3. 既存構文の扱い

既存の `field v : vector @ staggered` や `field s : symmetric @ staggered` は、
新しい標準構文ではない。実装上、非添字方程式や既存例を一時的に読むために
parser が受けてもよいが、添字方程式に参加する field は明示的な添字仕様を
持たなければならない。

移行期間は設けない。strict Einstein 検査は、legacy field で書かれた式にも
即時に適用する。legacy 宣言の field を添字つきで参照した場合、宣言から
上下添字が一意に決まらないならエラーにする。

実装時には、`elastic3d` など添字方程式を使う例を同じ変更で新構文へ移行する。

## 4. field 参照の検査

field 宣言が添字型を持つ場合、参照時の添字の上下は宣言と一致しなければならない。

```text
field v~i @ staggered

v~i  OK
v_i  error
```

下げた成分を使いたい場合は、計量を明示する。

```text
metric g
g_i_j * v~j
```

対称 field は、宣言された添字型を保ったまま添字順序だけを交換できる。

```text
field s{~i~j} @ staggered

s~i~j  OK
s~j~i  OK, 同じ成分へ正準化
s~i_j  error
```

反対称 field は、添字順序の交換で符号を反転する。

```text
field F[_i_j] @ staggered

F_i_j  OK
F_j_i  OK, 符号反転
F_i_i  0
F~i_j  error
```

最初の実装では、対称 rank-2 field を既存の `SymM` lowering へ対応させた。
その後、反対称 rank-2 field も上三角 off-diagonal の3成分 storage として
backend 対応した。一般 rank-2 tensor は full 3x3 storage として扱う。

添字の上げ下げは自動では行わない。`v~i` と宣言された field を `v_i` と
参照することは許さず、必要なら常に `g_i_j * v~j` のように metric を明示する。

## 5. strict Einstein 検査

添字方程式では、右辺の各加減算項ごとに添字を検査する。

### 自由添字

各項の自由添字は、LHS の自由添字と同じ名前・同じ上下でなければならない。

```text
s'~i~j = ...
```

なら、右辺の各項は自由添字 `~i, ~j` を持つ必要がある。

OK:

```text
s~i~j
δ~i~j * ∂_k v'~k
δ~i~k * ∂_k v'~j
δ~j~k * ∂_k v'~i
```

NG:

```text
∂_i v'~j
```

これは自由添字が `_i, ~j` になり、LHS の `~i, ~j` と一致しない。

### ダミー添字

LHS に出ない添字は、各項の中でちょうど2回出現し、
片方が上添字、片方が下添字でなければならない。

OK:

```text
∂_j s~i~j
```

`j` は `∂_j` の下添字と `s~i~j` の上添字で1回ずつ出る。

NG:

```text
∂_j s~i_j
```

`j` が下添字として2回出るため、strict Einstein 検査ではエラーにする。

NG:

```text
A~i~j B~j
```

`j` が上添字として2回出るため、計量または添字を下げた量を明示する必要がある。

### 微分演算子

`∂_i` は covariant な添字 `_i` を導入する。

```text
∂_j s~i~j
```

は、`∂_j` が `_j`、`s~i~j` が `~i, ~j` を持つので、
`j` が上下で縮約され、結果の自由添字は `~i` になる。

## 6. `metric δ` と Kronecker delta

`metric δ` がある場合、2添字の `δ` は metric tensor として解決する。

```text
metric δ

δ_i_j   共変計量
δ~i~j   反変計量
δ~i_j   mixed metric
δ_i~j   mixed metric
```

Kronecker delta は mixed identity として残すが、`metric δ` がある場合は
2添字 metric 参照が優先される。

このため、strict な数式では Euclidean 計量が必要な箇所に
`δ~i~j` や `δ_i_j` を書ける。

## 7. 実装手順

### Step 1: field 宣言 parser を拡張する

- `field FIELD_SPEC [@ staggered]` を新しい標準構文として parse する
- `v~i`、`v_i`、`s{~i~j}`、`F[_i_j]` を受け付ける
- `[]` は反対称、`{}` は対称として保存する
- `: vector`、`: tensor`、`: symmetric` は新構文では使わない
- legacy 構文を受ける場合も、添字方程式では strict 検査を通す

### Step 2: Model に field index metadata を追加する

- `FieldDecl` を導入する
- 添字仕様から `FieldLayout` を推論する
- 既存 backend 用に `kindOf` 相当の helper を残す
- `fieldIndexOf` を追加する
- `mFlds` をすぐ全面置換せず、最初は `FieldDecl` から作る互換 wrapper でもよい

### Step 3: LHS 添字を `IxPart` のまま保持する

現状の `primeEqForm` は `~i` と `_i` をどちらも `"i"` に落としている。
これを変更して、LHS の添字を `IxPart` のリストとして保持する。

```text
v'~i
  -> [IxPart VUp "i"]

s'~i~j
  -> [IxPart VUp "i", IxPart VUp "j"]
```

`Step` の `sIdx :: [String]` は、最終的に `[IxPart]` へ変更する。

### Step 4: 添字出現を収集する

`ixExpand` の前段で、各 top-level term ごとに添字出現を収集する。

対象:

- field 参照
- metric 参照
- Kronecker delta
- epsilon
- `∂_i`
- let tensor 参照

スカラー関数名や coordinate derivative `∂x` は添字出現に含めない。

### Step 5: strict Einstein 検査を入れる

各 term について:

- LHS にある添字は、term 内でちょうど1回、同じ上下で自由添字として現れる
- LHS にない添字は、term 内でちょうど2回、上1回・下1回で現れる
- 同じ添字が3回以上出たらエラー
- 同じ variance で2回出たらエラー
- term の自由添字集合が LHS と一致しなければエラー

この検査が通ったあとに、従来の成分展開へ進む。

### Step 6: fieldRef で宣言添字型を検査する

`fieldRef` は、参照された添字の上下が field 宣言と合うかを確認する。

```text
field v~i @ staggered

v~i  OK
v_i  error
```

対称 rank-2 は `s~j~i` を `s~i~j` と同じ成分へ正準化する。

### Step 7: elastic3d を strict 記法へ移行する

`examples/elastic3d/elastic3d.fe` を次の形へ移行する。

```text
metric δ
field v~i @ staggered
field s{~i~j} @ staggered

step:
  v'~i = v~i + (dt / ρ0) * ∂_j s~i~j
  s'~i~j = s~i~j + dt * (λ * δ~i~j * ∂_k v'~k
                       + μ * (δ~i~k * ∂_k v'~j + δ~j~k * ∂_k v'~i))
```

既存の Virieux 配置と `.fmr` が一致することを確認する。

### Step 8: docs と gallery を更新する

- `DSL-DESIGN.md`
- `README.md`
- `gallery/usage.html`
- `gallery/index.html`
- `gallery/dsl/index.html`

特に、`[]` が反対称、`{}` が対称であることを明記する。

### Step 9: テストを追加する

最低限のテストケース:

OK:

```text
field v~i @ staggered
field s{~i~j} @ staggered
metric δ

v'~i = v~i + ∂_j s~i~j
s'~i~j = s~i~j + δ~i~j * ∂_k v'~k
```

NG:

```text
∂_j s~i_j        -- down/down contraction
∂_i v'~j         -- free indices do not match s'~i~j
v_i              -- field v~i declared contravariant
s~i_j            -- field s{~i~j} declared contravariant/contravariant
```

OK:

```text
field A[_i_j] @ staggered
A'_i_j = A_i_j + dt * A_j_i  -- A_j_i は -A_i_j に正準化
```

代表例:

```text
cabal build
make elastic3d metric_torus hyperbolic maxwell_dec shallowwater diffusion3d
```

## 8. 未決事項

- 一般 rank-2 `field T~i~j @ staggered` を Formura の field 出力としてどう表すか
- 反対称 tensor を `2-form` backend へさらに接続できるか
- `metric δ` がある場合の `δ~i_j` を metric mixed tensor として優先する現仕様を
  Kronecker delta とどう説明するか

## 9. 確定した方針

- 新構文では `: vector`、`: tensor`、`: symmetric` を書かない
- rank、添字の上下、対称性、Formura 出力 layout は添字仕様から推論する
- strict Einstein 検査に移行期間は設けず、添字方程式には即時適用する
- 添字の上げ下げは自動化しない。常に metric を明示する
