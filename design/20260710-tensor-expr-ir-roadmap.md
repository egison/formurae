# TensorExpr IR で Egison の利点を Formurae の中核にする

Date: 2026-07-10

## 目的

Egison の大きな利点は、添字記法を使ってテンソル演算子を簡潔に定義できる
ことである。

Formurae でも次のような定義をそのまま物理モデルの語彙として使える状態を
目指す。

```formurae
def grad u = withSymbols [i] ∂_i u
def div X = contractWith (+) (∂_i X~i)
def trace A = contractWith (+) A~i_i
def (.) A B = contractWith (+) (A * B)
def lap u = div (grad u)
```

現在の Formurae は、`withSymbols`、`contractWith`、`.`、複数引数 `def` を
受け取り、代表的な例を stencil へ落とせる段階に入っている。
しかし内部処理にはまだ文字列走査・文字列置換が残っている。

このままだと、次のような Egison らしい性質を一般に扱いにくい。

- テンソル値が添字情報を保持したまま関数に渡される
- 関数本体で添字を付けると、引数が持つ添字が付け替えられる
- `...~i_i` のように、必要な場合だけ添字を追加できる
- `withSymbols` で導入した局所添字が外へ出るときに、結果テンソルの自由添字になる
- `contractWith` または `.` だけが縮約を行う
- `div (grad u)` のような tensor-valued operator の合成が自然に動く

したがって、もう一歩を埋めるための中心方針は、Formurae の式を
文字列ではなく **TensorExpr IR** として扱うことである。

## 1. 目標パイプライン

現在の `fec` は、表面構文から比較的早い段階で成分式や Formura/Egison 文字列へ
近づく。目標は、添字式の意味論を十分に正規化してから、最後にだけ成分式へ
特殊化することである。

```text
Formurae source
  -> surface parser
  -> TensorExpr IR
  -> def expansion / prelude expansion
  -> withSymbols hygiene / index elaboration
  -> dot desugaring / contractWith normalization
  -> free-index, diagonal-index, variance checks
  -> component specialization
  -> coordinate derivative / metric / staggered placement lowering
  -> Formura scalar expression
```

この順序の重要点は、`∂_i`、metric、`contractWith`、`.` をすぐに
`∂ 2 1 x` や `dYee` へ落とさないことである。
添字構造を保ったまま関数合成・縮約・自由添字推論を済ませ、最後の段階でだけ
Formura の配列・stencil 計算へ変換する。

## 2. TensorExpr IR

IR は完全な Egison 実装ではなく、Formurae が stencil へ下ろすための
有限次元テンソル式を表せればよい。

概念的には次のノードを持つ。

```haskell
data TensorExpr
  = EVar Name
  | ENumber String
  | EUnary Op TensorExpr
  | ECall TensorExpr [TensorExpr]
  | EApply TensorExpr [TensorExpr]
  | EIf TensorExpr TensorExpr TensorExpr
  | EBinary Op TensorExpr TensorExpr
  | EIndexed TensorExpr [IxPart]
  | EAppendIndexed TensorExpr [IxPart]
  | EWithSymbols [IndexName] TensorExpr
  | EContractWith Reducer TensorExpr
  | EDot TensorExpr TensorExpr
  | EDerivative IxPart TensorExpr
  | ECoordDerivative Order Radius AxisName TensorExpr
  | EMetric Name [IxPart]
  | EDelta [IxPart]
  | EEpsilon [IxPart]
```

scalar 式も raw leaf にはせず、数値、単項演算、関数呼び出し、空白適用、条件式、
二項演算を AST として保持する。これにより `exp(0 - X_i^2) + sin(X_i)` のような
式でも、添字つき引数 `X_i` の付け替えや出現検査を文字列走査に戻らず扱える。
parser error は `Either` として返し、式全体、失敗近傍、column を表示する。
source span つき診断は、この AST に位置情報を付ける形で追加する。

各ノードには elaboration 後に次の情報を注釈する。

```haskell
data TensorInfo = TensorInfo
  { tiFreeIx :: [IxPart]
  , tiDiagIx :: [DiagIx]
  , tiRank   :: Int
  }

data DiagIx = DiagIx
  { diagName :: IndexName
  , diagUp   :: IxPart
  , diagDown :: IxPart
  }
```

ここで `tiDiagIx` は「同じ名前の上添字・下添字が現れているが、まだ縮約されて
いない diagonal axis」である。`A~i_i` は scalar ではなく、diagonal axis を持つ
テンソル式として表す。`contractWith (+) A~i_i` が初めて scalar へ畳み込む。

## 3. 添字付加と関数適用

Egison と同様に、関数定義の head には結果添字を書かない。

```formurae
def grad u = withSymbols [i] ∂_i u
def div X = contractWith (+) (∂_i X~i)
```

関数呼び出しでは、引数は添字情報を持った値として本体へ入る。

```formurae
def trace A = contractWith (+) A~i_i

p' = trace A~p_q
```

このとき、`trace` の本体内の `A~i_i` は呼び出し側の `A~p_q` の添字を
保持するのではなく、`~i_i` へ付け替える。したがって成分展開は
`A_1_1 + A_2_2 + ...` になる。

既存の添字に追加したい場合だけ append-index を使う。

```formurae
A...~i_i
```

これは引数が持っている添字構造を保ったまま、末尾に `~i_i` を追加する。

## 4. `withSymbols`

新しい自由添字を作る演算子は、必ず `withSymbols` で局所添字を導入して書く。

```formurae
def grad u = withSymbols [i] ∂_i u
```

`withSymbols [i] body` の中で導入された `i` は hygienic な局所 symbol である。
外へ出るとき、自由に残った局所添字は結果テンソルの最後尾へ転置され、名前としての
添字情報は消える。

したがって次は同じ意味を持つ。

```formurae
q'_i = grad u
q'_j = grad u
```

`grad` の内部名 `i` は、外側の代入先の `i` または `j` と直接一致する必要がない。

## 5. `*`, `.`, `contractWith`

Formurae の `*` は縮約を行わない。Egison と同様に、同じ添字構造なら pointwise、
異なる自由添字なら tensor product として扱う。

```formurae
A~i * B~i      -- same free-index structure: pointwise
A~i * B~j      -- different free indices: tensor product
A~i_i          -- diagonal axis, not scalar
```

縮約は `contractWith` だけが行う。`.` は core primitive に固定せず、
ユーザー定義可能な operator として扱う。標準 prelude では次の定義を持ち、
内部に `contractWith` を使うため縮約を行う。

```formurae
def (.) A B = contractWith (+) (A * B)
```

例:

```formurae
A~i_k . B~k_j
```

これは

```formurae
contractWith (+) (A~i_k * B~k_j)
```

へ正規化され、`k` が縮約され、自由添字 `~i_j` を持つ式になる。

同じ上下添字が現れただけで暗黙総和してはいけない。
これは Formurae 内部だけでなく表面言語の仕様でも守る。

## 6. Lowering

TensorExpr IR の lowering は、成分を固定してから行う。

例えば

```formurae
def lap u = div (grad u)

u' = u + dt * κ * lap u
```

は、概念的には次のように進む。

1. `lap u`
2. `div (grad u)`
3. `contractWith (+) (∂_i (withSymbols [j] ∂_j u)~i)`
4. `contractWith (+) (∂_i ∂~i u)` 相当の添字式
5. Euclidean metric または mixed identity により各軸成分へ特殊化
6. `∂ 2 1 x u + ∂ 2 1 y u + ∂ 2 1 z u`

実装上は、`grad u` の結果添字と `div` が要求する `X~i` の添字付加を
IR 上で解決する必要がある。

staggered field に対する `∂_i` は、成分特殊化後に target component の placement を
使って `dYee` へ落とす。metric も、成分特殊化後に Euclidean identity または
生成済み metric component へ落とす。

## 7. 受け入れテスト

この設計が実装できたと判断するための最小テストは次である。

```formurae
def grad u = withSymbols [i] ∂_i u
def div X = contractWith (+) (∂_i X~i)
def lap u = div (grad u)
```

`lap u` が 2D/3D で既存の低水準 Laplacian と同じ stencil へ落ちることを確認する。

追加で必要な golden tests:

- `trace A = contractWith (+) A~i_i`
- `A~i_k . B~k_j`
- `g~i~j . ∂_i ∂_j u`
- `withSymbols [i] ∂_i u` を `q'_i` と `q'_j` の両方へ代入する
- `A~i_i` 単独は scalar へ縮約されず、`contractWith` がない場合は error になる
- `contractWith (*) A~i_i`
- `contractWith max A~i_i`
- metric `g` と Kronecker delta `δ` の区別
- 添字付きで宣言された field を裸で参照した場合の error

## 8. 実装ステップ

1. 表面式 parser を作り、添字式を `TensorExpr` へ変換する
2. 既存の文字列ベース `applyDefs` を AST ベースの beta reduction へ置き換える
3. `withSymbols` の hygienic scope と、外へ出る自由添字の扱いを実装する
4. `.` を `contractWith (+) (A * B)` へ正規化する
5. `*` の pointwise/tensor-product 判定を TensorInfo 上で実装する
6. `contractWith` が diagonal axes を reducer で finite fold へ落とす
7. 成分特殊化器を作り、自由添字に具体的な軸番号を割り当てる
8. `∂_i`、metric、field component、staggered placement を既存の Formura scalar
   lowering へ接続する
9. 既存の `ixExpand` 経路を、TensorExpr lowering の薄い wrapper へ縮小する
10. 代表例と golden tests を追加する

## 設計判断が必要な要素

大きな方向性は Egison と同じ仕様でよい。実装前に明確にしておくべき判断は
次の通りである。

### 1. IR 化の範囲

Formurae の scalar 式をどこまで parse するか。

決定: scalar 部分も raw leaf として残さず、演算子優先順位つきの AST として保持する。
これにより、ユーザ定義テンソル演算子の beta reduction、添字付け替え、出現検査を
同じ `TensorExpr` 経路で扱う。source span つき診断はこの AST に位置情報を足して
拡張する。

### 2. 中間テンソルの rank

最終的な field storage は現在の scalar/rank-1/rank-2/form に制限されるが、
中間式は arbitrary rank を許すか。

推奨: 中間 TensorExpr は arbitrary rank を許す。`epsilon~i~j~k` や
テンソル積を自然に扱うためである。最終代入時だけ、代入先 field の rank/layout と
一致することを検査する。

### 3. `.` はユーザー定義可能な operator にする

方針: `.` は core primitive ではなく、ユーザー定義可能な operator にする。
標準 prelude では

```formurae
def (.) A B = contractWith (+) (A * B)
```

として定義する。`contractWith` と `withSymbols` は縮約と局所添字 binding を
担う core primitive として残す。つまり、`.` はそれらの primitive を使って
定義される通常の operator である。

ユーザが同名定義した場合は、その定義で標準 prelude の `.` を shadow できるように
する。ただし backend が lowering できない定義なら明確な error を出す。

### 4. `contractWith` reducer の範囲

`+` 以外の reducer をどこまで許すか。

推奨: `+`、`*`、および Formura scalar 式として lowering できる二項関数名を許す。
Formura 本体にテンソル縮約 primitive がないため、Formurae 側で有限 fold へ展開する。

### 5. `*` の一般化

同じ添字構造なら pointwise、異なる自由添字なら tensor product という Egison 仕様を
採用するか。

推奨: 採用する。これにより `.` は単に `contractWith (+) (A * B)` と定義できる。
ただし、同じ名前の自由添字が同じ variance で重複するなど、意味が曖昧な式は
error にする。

### 6. metric と scalar 名の衝突

`metric g` と `param g` または `field g` が同居したとき、表層の `g` と
添字付き `g~i~j` を区別するか。

推奨: 現在方針を維持する。裸の `g` は scalar/field 名、添字付き `g~i~j` などは
metric tensor とし、名前衝突時は warning を出す。

### 7. 現在の lowering から TensorExpr lowering への移行

現在の `fec` には、添字式を文字列として走査しながら成分式へ展開する経路がある。
代表的には `ixExpand` 周辺の処理である。この経路は既存例を動かすためには
まだ必要だが、`div (grad u)` のような tensor-valued operator composition を
一般に扱うには向いていない。

ここでの判断は、既存経路を一気に削って全てを TensorExpr lowering に置き換えるか、
それとも新しい TensorExpr lowering を横に追加し、段階的に対象を移すかである。

推奨: 最初は段階的に移行するが、最終的には全ての添字式 lowering を
TensorExpr 経路へ一本化する。既存例は当面既存経路でも動かしつつ、
新しい operator composition、特に `def lap u = div (grad u)` は
TensorExpr 経路だけで通す。TensorExpr 経路が `grad`、`div`、`trace`、`.`、
metric、staggered derivative を十分に覆った段階で、既存の文字列走査経路を
削除する。

### 8. エラー表示

IR 化すると、エラー位置や元の表面式との対応を持てるようになる。
最初から source span を持つか。

現状: parser error は `Either` 経路で式全体、失敗近傍、column を返す。
次は `TensorExpr` に簡単な source span を持たせる。
添字エラーはユーザが直す必要があるため、`A~i_i` のどこで縮約が足りないかを
表示できることが重要である。
