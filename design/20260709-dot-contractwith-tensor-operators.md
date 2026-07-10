# Egison 風 `.` / `contractWith` によるテンソル演算子定義

Date: 2026-07-09

## 目的

Egison の利点は、任意のテンソル演算子を添字記法で簡潔に定義できることにある。
Formurae でもこの利点を表面言語として活かすため、テンソル同士の掛け算は
Egison と同様に `.` で書けるようにする。

中心方針:

- `.` は任意のテンソルに使えるテンソル積・縮約演算子にする
- `.` の意味は `contractWith (+) (A * B)` と考える
- `contractWith reducer expr` は Formurae の組み込みプリミティブとして扱う
- `contractWith` は Formura の縮約命令へ対応させるのではなく、
  Egison/Formurae 側で有限個の scalar 式へ展開してから Formura へ渡す
- Formura backend へ落とす範囲では、reducer は Formura の scalar 式として
  lowering できる二項演算または二項関数に限る
- `*` はスカラー積または成分ごとの lift 済み積であり、テンソル縮約には使わない
- Formurae の `.` は関数合成には使わない。関数合成は `compose` と書く
- 数学演算子は Haskell 側の個別組み込みではなく、添字つき `def` / prelude 定義へ寄せる
- 自由添字を新しく作る演算子は `withSymbols` で局所添字を導入して書く
- 通常の添字付加は添字の付け替えであり、添字を追加したい場合は Egison と同様に
  `...` 付きの append-index 構文を使う

参考にする意味論:

- Egison 本体の `lib/math/algebra/tensor.egi` では `.` は `contract (t1 * t2)` を
  `+` で畳み込む演算として定義されている
- type-tensor-paper では `A~i_i` は scalar ではなく supersubscript 対角を作り、
  `contractWith (+) A~i_i` がそれを scalar へ畳み込む
- したがって、Formurae でも同じ上下添字が現れただけで暗黙に総和しない
- これは内部意味論だけでなく表面構文でも守る。表面で `A~i_i` を暗黙総和に
  してしまうと、対角テンソルそのものをユーザが表せなくなり、
  明示的な縮約としての `contractWith` の意味を失うためである

このメモは `design/20260709-egison-style-indexed-defs.md` の保守的な方針を
一段進めるものである。Formurae は Egison の添字記法を重複実装するのではなく、
Egison と同じ核概念、特に `.` と `contractWith`、を Formurae の AST に持つ。

実装手順の詳細は
`design/20260709-indexed-expr-ast-implementation.md` に分けてまとめる。

Formura 本体にはテンソル添字に対する縮約プリミティブはない。しかしこれは
`contractWith` を `+` に限定する理由ではない。Formura では内積も
`sum(A*B)` のような通常の tuple 演算と scalar 式へ展開されるため、
Formurae/Egison 側で `contractWith (*)` や `contractWith max` も同じように
有限展開すればよい。

Formura 本体の `.` は関数合成だが、Formurae 表面の `.` はテンソル積・縮約に
予約する。Formurae で関数合成が必要な場合は `compose f g` と書く。
`compose` は Formura 出力時に `f . g` へ落としても、`f(g(x))` へ展開してもよい。
重要なのは、Formurae 表面の `.` を Formura の関数合成として解釈しないことである。

## 1. 目標構文

平坦な Laplacian:

```formurae
metric g

def Δ u = g~i~j . ∂_i ∂_j u

step:
  u' = u + dt * κ * Δ u
```

勾配・発散:

```formurae
def grad u = withSymbols [i] ∂_i u
def div X = contractWith (+) (∂_i X~i)
def Δ u = g~i~j . ∂_i ∂_j u

添字列操作と成分 lift も TensorExpr の基本演算子である。

```formurae
def mapExp X... = tensorMap exp X
def transpose2 A_i_j = transpose [j, i] A
def sym A = withSymbols [i, j]
  ((subrefs A [_i, _j] + transpose [j, i] (subrefs A [_i, _j])) / 2)
def wedge A B = A !. B
```

`tensorMap` はスカラー関数を全成分へ適用し、`subrefs` は添字列を付加する。
`transpose` は指定した順序へ添字を並べ替え、`!.` は添字を縮約しない
disjoint tensor product である。`X...` は呼び出し側の添字列を受け取る
rank-polymorphic parameter marker、`A_i_j` は固定長の indexed parameter である。
```

弾性波で使う演算子:

```formurae
def div X = contractWith (+) (∂_i X~i)
def trace A = contractWith (+) A~i_i
def strain D = (D + transpose D) / 2
def stress G D = λ * G * trace D + 2 * μ * strain D

step:
  v'~i = v~i + (dt / ρ0) * ∂_j σ~i~j
  σ'~i~j = σ~i~j + dt * stress g~i~j D'~i~j
```

ここで `D'` は `∂ v'` などから得られる rank-2 の微分テンソルを表す仮名である。
重要なのは、`stress` 自身には結果添字を書かず、呼び出し側の `g~i~j` と
`D'~i~j` が添字情報を持つことである。

一般のテンソル積・縮約:

```formurae
X~i . Y_i
G~i~j . v_j
G_i_j . v~j
A~i_j . B~j_k
def scalarCurvature Ric = g~i~j . Ric_i_j
```

これらは `dot` や `matmul` のような個別名を定義せず、すべて同じ `.` の意味から
成分展開されるべきである。

### `def` は結果添字を書かない

Egison では、演算子定義に結果添字を書かない。テンソルデータは添字情報も
保持しており、引数に渡されたテンソルは関数本体にその添字情報を持ったまま
入ってくる。Formurae もこのモデルへ寄せる。

したがって、行列積のような個別関数を作るのではなく、標準 prelude / 核で
`.` 自身を定義する。

```formurae
def (.) A B = contractWith (+) (A * B)
```

呼び出し側がテンソルに添字を付けて `.` へ渡す。

```formurae
C'~i_k = A~i_j . B~j_k
```

このとき `A` は `~i_j`、`B` は `~j_k` の添字情報を持ったまま
`.` の本体に入り、`contractWith (+) (A * B)` が `j` を縮約して `~i_k` を返す。

関数定義内に明示的な添字が現れる場合、それは基本的にその関数内で縮約されて
消える局所添字である。ただし、消す操作は repeated upper/lower index
だけでは起こらず、`contractWith` または `.` が明示的に行う。

```formurae
def div X = contractWith (+) (∂_i X~i)
def Δ u = g~i~j . ∂_i ∂_j u
```

ここで `div` の `i` は `contractWith (+)` で畳み込まれる。`Δ` の `i`、`j` は
`.` の定義 `contractWith (+) (A * B)` により畳み込まれる。
`grad` のように新しい自由添字を持つテンソルを返す演算子は、結果添字つき `def`
ではなく、`withSymbols` で局所添字を導入して書く。

```formurae
def grad u = withSymbols [i] ∂_i u
```

`withSymbols` 内で付加された添字は、`withSymbols` の外に出るときに結果テンソルの
最後尾へ転置され、添字名・上下の symbol 情報は消える。

また、通常の添字付加は、引数が持っていた添字の付け替えとして扱う。
既存の添字に追加したい場合は、Egison と同様に `...` 付きの添字追加構文を使う。

```formurae
A_i       -- A の添字 view を _i に付け替える
A..._i    -- A が持つ添字の後ろに _i を追加する
```

### 添字付きテンソルは常に添字付きで使う

添字付きで宣言されたテンソルは、式中でも常に添字付きで参照する。

```formurae
field v~i
field A~i_j

v~i      -- OK
v        -- error
A~i_j    -- OK
A        -- error
```

これにより、関数へ渡されたテンソルが添字情報を保持するという Egison 風の
モデルと、Formurae の strict Einstein 検査を一致させる。

metric は表層では `metric g` と宣言されるが、式中では実質的に添字付きテンソル
として扱う。

```formurae
metric g

g_i_j    -- covariant metric
g~i~j    -- contravariant metric
g~i_j    -- mixed metric
g        -- metric 参照ではない
```

裸の `g` は metric ではない。`param g` などの scalar 名として使うことはできるが、
同じ表層名が scalar と metric の両方に現れた場合は warning を出す。
添字の有無で解決は一意にできるが、読み手が混同しやすいためである。

## 2. `.` の意味

`A . B` は、Egison と同じく概念的には次の形である。

```formurae
contractWith (+) (A * B)
```

ここで `A * B` は添字を保った成分ごとの積・テンソル積であり、
`contractWith (+)` が上添字と下添字で同じ名前を持つ supersubscript 軸を畳み込む。
同じ上下添字が現れるだけでは総和しない。例えば `A~i_i` は対角テンソルを作り、
`contractWith (+) A~i_i` がそれを scalar へ畳み込む。
これは Formurae の外部構文でも同じで、`A~i_i` を直接 scalar へ縮約する
省略記法は入れない。簡潔さは `.` と prelude 演算子で確保する。

例:

```formurae
X~i . Y_i
```

は inner product になり、スカラーを返す。

```formurae
X_i . Y_j
```

は縮約すべき上/下の対がないので outer product のまま残り、共変 rank-2
テンソルを返す。`contractWith` は縮約軸がない場合に恒等写像として振る舞う。

```formurae
A~i_j . B~j_k
```

は `j` で縮約し、自由添字 `~i, _k` を持つ混合 rank-2 テンソルを返す。

重要なのは、`dotProduct`、`matrixProduct`、`raise`、`lower`、`trace` のような
個別演算子を Haskell 側に増やさないこと。すべて `.` と添字の組み合わせで表す。

## 3. `contractWith` を組み込みにする理由

Formurae で `contractWith` を組み込みにする理由は4つある。

1. `.` の定義を Egison と同じ形に保てる
2. `A~i_i` のような対角テンソル生成と、縮約を明確に分けられる
3. `+` 以外の reducer でも、有限個の scalar 式へ展開できる
4. AST 上で「テンソル縮約」を明示的に保持でき、最後の Formura lowering まで遅延できる

標準の `.` は次の prelude 定義として扱う。

```formurae
def (.) A B = contractWith (+) (A * B)
```

ユーザが明示的に `contractWith` を使うことも許す。

```formurae
contractWith (+) T~_i
contractWith (*) T~_i
contractWith max T~_i
```

Formura 本体の式言語には、テンソル添字に対する任意 reducer の縮約
プリミティブはない。現在ある `reduces: [tot = sum q]` などの YAML 機能は、
格子全体に対する大域リダクションであり、添字縮約とは別物である。

むしろ Formura に縮約プリミティブがないため、`contractWith` は Formura の
特殊機能に合わせる必要がない。Formurae/Egison 側で縮約添字の範囲を展開し、
reducer を普通の scalar 式として畳み込んだ結果を Formura へ渡せばよい。

3 次元の例:

```formurae
contractWith (+) A~i_i
=> A~1_1 + A~2_2 + A~3_3

contractWith (*) A~i_i
=> A~1_1 * A~2_2 * A~3_3

contractWith max A~i_i
=> max(max(A~1_1, A~2_2), A~3_3)
```

したがって、制約は reducer が Formura へ lowering 可能な scalar 二項演算または
scalar 二項関数であることだけでよい。Formura に未定義の reducer、非結合的で
評価順を明示すべき reducer、または tensor を返す reducer は型検査または
lowering でエラーにする。

## 4. `*` と `.` の役割分担

`*` は scalar operator である。テンソルに対しては Egison 的に lift される。

```formurae
a * X_i        -- スカラー倍
X_i * Y_i      -- 同じ添字構造を持つ成分ごとの積
sin X_i        -- 成分ごとの sin
X_i + Y_i      -- 成分ごとの和
```

一方、テンソル構造を変える積は `.` で書く。

```formurae
X~i . Y_i      -- 縮約して scalar
X_i . Y_j      -- outer product
A~i_j . B~j_k  -- matrix-like contraction
```

この分離により、`*` を見たときに Formurae は tensorMap 的 lift だけを考えればよい。
Einstein 縮約は `.` / `contractWith` の経路だけに集約する。

## 5. 内部表現

文字列置換のまま `.` を扱うと、添字の alpha-renaming、dummy index の衝突回避、
関数展開時の rank 推論が難しくなる。したがって indexed expression AST を導入する。

概念的には次のノードを持つ。

```text
Expr
  = ScalarLit ...
  | Var Name
  | Indexed Expr [IxPart]
  | AppendIndexed Expr [IxPart]
  | Apply Name [Expr]
  | Pointwise Op [Expr]
  | Dot Expr Expr
  | ContractWith Reducer Expr
  | WithSymbols [IndexName] Expr
  | Deriv IxPart Expr
```

`Dot a b` は lowering の早い段階で `ContractWith Plus (Pointwise Mul [a,b])`
へ正規化してよい。ただし、ユーザ向けエラーや pretty print のために、
表層が `.` だった事実は保持できるとよい。

`Reducer` は最初から一般にしておく。Formura backend では reducer が
lowering 可能かを検査し、縮約対象の成分列をその reducer で fold した
scalar 式を生成する。

## 6. `def` と添字情報

`def` は、単なるテキスト置換ではなく AST レベルの関数定義として扱う。
ただし、Egison と同様に演算子定義には結果添字を書かない。
関数に渡されたテンソル引数は、呼び出し側で付けられた添字情報を保持したまま
関数本体に入る。

```formurae
def (.) A B = contractWith (+) (A * B)
```

呼び出し側:

```formurae
A~i_j . B~j_k
```

では、`A` は `~i_j`、`B` は `~j_k` の添字情報を持って本体へ入り、
`contractWith (+) (A * B)` が `j` を縮約して `~i_k` を持つテンソルを返す。
定義本体の dummy index は、呼び出し側や周囲の式と衝突しないように
alpha-renaming する必要がある。

定義内に明示的な添字を書く場合、それは関数内部で縮約される局所添字か、
`withSymbols` で導入された局所添字である。縮約は `contractWith` または `.`
によって明示する。新しい自由添字を作る場合は `withSymbols` を使う。

```formurae
def grad u = withSymbols [i] ∂_i u
def div X = contractWith (+) (∂_i X~i)
def Δ u = g~i~j . ∂_i ∂_j u
```

`grad` の `i` は `withSymbols` によって局所的に導入される。`withSymbols` の
外へ出るとき、結果に自由に残った `i` は結果テンソルの最後尾へ転置され、
添字名・上下の symbol 情報は消える。`div` の `i` は `contractWith (+)` で、
`Δ` の `i`、`j` は `.` の内側の `contractWith (+)` で縮約されて消える。

通常の添字付加は、仮引数が持っていた添字の付け替えである。添字を追加したい
場合だけ `...` 付きの append-index 構文を使う。

## 7. lowering の責務

Formurae の lowering は次の順に行う。

1. 表層式を indexed expression AST に parse する
2. `def` を hygienic に展開する
3. `withSymbols` の局所添字 scope を処理する
4. `.` を `contractWith (+)` へ正規化する
5. index reduction を行い、同じ上下添字を supersubscript 対角として残す
6. `withSymbols` から出る自由な局所添字を最後尾へ転置し、symbol 情報を消す
7. 対象 field の自由添字ごとに成分式を生成する
8. `contractWith reducer` が supersubscript 軸を指定された reducer で畳み込む
9. 最後に `∂_i`、metric、staggered 配置を Formura stencil へ落とす

ポイントは、`∂^2_x` などの低水準 stencil へ落とすのを最後まで遅らせること。
これにより、`grad`、`div`、`Δ`、`stress` のような演算子を Formurae/prelude 側で
普通に定義できる。

## 8. 実装ステップ

### Step 1: `.` と `contractWith` の parser/AST 追加

- `.` を infix operator として parse する
- 当面は `.` の前後に空白を要求してよい
- `contractWith reducer expr` を parse する
- `withSymbols [i, j] expr` を parse する
- 通常の添字付加と `...` 付き添字追加を別ノードとして parse する
- reducer が Formura の scalar 式へ lowering 可能か検査する
- `*` と `.` を別ノードにする
- 関数合成は `compose f g` として parse し、Formurae 表面の `.` とは分ける

### Step 2: 現在の `ixExpand` と同じ結果を出す lowering

- `g~i~j . ∂_i ∂_j u` を従来 `g~i~j * ∂_i ∂_j u` で得ていた stencil と同じ形へ落とす
- `X~i . Y_i`、`A~i_j . B~j_k` の小さな smoke test を作る
- Euclidean `metric g` は従来通り恒等行列として簡約する

### Step 3: `.` の prelude 定義と縮約つき `def`

- `def (.) A B = contractWith (+) (A * B)`
- `def Δ u = g~i~j . ∂_i ∂_j u`
- `def grad u = withSymbols [i] ∂_i u`
- dummy index の alpha-renaming を実装する

### Step 4: prelude 化

Formurae の標準 prelude として、次のような定義を持てるようにする。

```formurae
def (.) A B = contractWith (+) (A * B)
def grad u = withSymbols [i] ∂_i u
def div X = contractWith (+) (∂_i X~i)
def Δ u = g~i~j . ∂_i ∂_j u
def trace A = contractWith (+) A~i_i
```

この段階で、数学演算子を Haskell の特殊規則として増やす方針から離れる。

## 9. 検証例

最低限の受け入れ例:

```formurae
metric g
field u : scalar

def Δ u = g~i~j . ∂_i ∂_j u

step:
  u' = u + dt * κ * Δ u
```

期待 lowering:

```formurae
∂^2_x u + ∂^2_y u + ∂^2_z u
```

rank-2 例:

```formurae
field A~i_j
field B~i_j
field C~i_j

step:
  C'~i_j = A~i_k . B~k_j
```

一般 reducer の例:

```formurae
field A~i_j

step:
  p = contractWith (*) A~i_i
  m = contractWith max A~i_i
```

3 次元なら、期待 lowering はそれぞれ次のような scalar 式である。

```formurae
p = A~1_1 * A~2_2 * A~3_3
m = max(max(A~1_1, A~2_2), A~3_3)
```

弾性例:

```formurae
def div X = contractWith (+) (∂_i X~i)
def trace A = contractWith (+) A~i_i
def strain D = (D + transpose D) / 2
def stress G D = λ * G * trace D + 2 * μ * strain D
```

既存の `elastic3d` と同じ Formura コード、または意味的に同じコードへ落ちることを
確認する。

## 10. 完了条件

- `.` が任意の rank のテンソル式に使える
- `.` と `contractWith (+)` が同じ意味を持つ
- `.` をユーザ定義できる
- `contractWith` が AST 上の明示的なプリミティブになっている
- `contractWith` が lowering 可能な scalar reducer を受け取り、有限個の成分式へ展開できる
- `*` は縮約を行わない
- 通常の添字付加は付け替え、`...` 付き添字付加は追加として扱われる
- `withSymbols` で局所添字を導入できる
- 添字つき `def` が `.` を含む式を hygienic に展開できる
- 複数引数 `def` は結果添字を書かず、呼び出し側から渡された添字情報を保持する
- `def Δ u = g~i~j . ∂_i ∂_j u` が既存の Laplacian stencil へ落ちる
- `def grad u = withSymbols [i] ∂_i u` が rank-1 tensor を返す
- `def stress ...` のような物理演算子を Formurae/prelude 定義として書ける
