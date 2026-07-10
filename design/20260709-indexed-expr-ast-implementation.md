# IndexedExpr AST による Egison 風テンソル演算子実装計画

Date: 2026-07-09

2026-07-10 時点の上位ロードマップは
`design/20260710-tensor-expr-ir-roadmap.md` にまとめる。
この文書は、そのうち `IndexedExpr`/`TensorExpr` を実装へ落とすための
詳細計画として読む。

## 目的

Formurae で目指す状態は、Egison の利点である

```formurae
def div X = contractWith (+) (∂_i X~i)
def trace A = contractWith (+) A~i_i
def Δ u = g~i~j . ∂_i ∂_j u
```

のような簡潔な添字記法のテンソル演算子定義を、そのまま Formura の
stencil 計算へ落とせる状態である。

現在の実装は `.` / `contractWith` の表面構文を一部受け取れるが、まだ
文字列処理と直接の成分展開が中心である。これでは、

- `def` の引数に添字情報を保持させる
- dummy index を hygienic に alpha-renaming する
- `*` と `.` の意味を型・添字レベルで分ける
- 数学演算子を Haskell 側の個別特殊規則ではなく prelude 定義へ寄せる

ことが難しい。

したがって、Formurae 内部に indexed expression AST を導入し、
添字付き式を文字列ではなく構文木として扱う。

この文書は `design/20260709-dot-contractwith-tensor-operators.md` の意味論を
実装へ落とすための計画である。

## 1. 現状と目標

### 現状

- `.` は空白付き中置演算子として一部 `contractWith (+)` 相当へ落ちる
- `contractWith reducer expr` は一部の scalar lowering で動く
- しかし lowering は `ixExpand` 周辺の文字列走査に強く依存している
- `def` は単純な文字列置換であり、複数引数や添字情報付き引数を自然に扱えない
- repeated upper/lower index はまだ既存の strict Einstein 経路に残っている
- 結果添字付き `def` の名残があり、Egison 的な operator definition とはずれている

### 目標

- 表面式をまず `IndexedExpr` AST へ parse する
- `def` は AST レベルの関数定義として展開する
- 関数に渡されたテンソル引数は、field/metric/一時式の rank と variance 情報を保持する
- 通常の添字付加は、引数が持っていた添字を付け替える
- 既存の添字に追加したい場合は、Egison と同様に `...~i_i` のような append-index
  構文を使う
- `withSymbols` で局所添字を導入できる
- `.` は最終的にユーザ定義可能な演算子として扱い、標準 prelude では
  `contractWith (+) (A * B)` と定義する
- `contractWith` は AST 上の明示的な縮約ノードとして扱う
- 同じ上下添字が現れただけでは暗黙総和しない
- 最後の段階でだけ、metric、field component、staggered placement、`∂_i` を
  Formura の scalar stencil 式へ落とす

## 2. AST の形

最初の実装では、Formurae の stencil 生成に必要な範囲に絞った小さな AST を作る。
完全な Egison 再実装ではなく、有限次元テンソル式を Formura scalar 式へ下ろす
ための AST でよい。

概念的には次の型を持つ。

```haskell
data IndexedExpr
  = EScalarLit String
  | EScalarName Name
  | ETensorName TensorRef
  | EIndexed IndexedExpr [IxPart]
  | EAppendIndexed IndexedExpr [IxPart]
  | EApply Name [IndexedExpr]
  | EPointwise Op [IndexedExpr]
  | EDot IndexedExpr IndexedExpr
  | EContractWith Reducer IndexedExpr
  | EWithSymbols [IndexName] IndexedExpr
  | EDeriv IxPart IndexedExpr
  | ECoordDeriv Order Radius AxisName IndexedExpr
  | EParen IndexedExpr

data Reducer
  = RPlus
  | RTimes
  | RFunction Name

data TensorRef
  = FieldRef Name
  | MetricRef Name
  | ParamRef Name
  | LocalRef Name
```

`EPointwise` は `+`、`-`、`*`、`/`、scalar function application などを表す。
ここでの `*` は tensor contraction ではなく、Egison 的な tensorMap / tensor product
に相当する pointwise/lifted scalar operator である。

`EDot a b` は parse 直後には残してよいが、elaboration の早い段階で

```formurae
contractWith (+) (a * b)
```

つまり

```haskell
EContractWith RPlus (EPointwise Mul [a, b])
```

へ正規化する。

ただし `.` は最終的には組み込み専用ではなく、ユーザ定義可能な演算子にする。
実装初期段階では hardwired core として扱ってよいが、意味論上は標準 prelude の

```formurae
def (.) A B = contractWith (+) (A * B)
```

と同じである。

## 3. 添字情報

AST の各式には、elaboration 後に添字情報を注釈する。

```haskell
data TensorInfo = TensorInfo
  { tiRank       :: Int
  , tiVariance   :: [Variance]
  , tiFreeIx     :: [IxPart]
  , tiDiagIx     :: [DiagIx]
  }

data DiagIx = DiagIx
  { diagName :: String
  , diagUp   :: IxPart
  , diagDown :: IxPart
  }
```

`tiFreeIx` は最終的に成分として残る添字である。
`tiDiagIx` は `A~i_i` のように同じ名前の上添字・下添字から作られる
supersubscript 対角軸であり、まだ scalar へ縮約されていない。

重要な規則:

- `A~i_i` は scalar ではない
- `A~i_i` は diagonal tensor value を表す
- `contractWith (+) A~i_i` が scalar を返す
- `A~i_i` を scalar が必要な場所に置いた場合はエラーにする

これにより、Egison/type-tensor-paper と同じく「添字の重複」と「縮約」を
分離できる。

## 4. field と metric の参照規則

添字付きで宣言された field は、式中では常に添字付きで使う。

```formurae
field v~i
field A~i_j

v~i      -- OK
v        -- error
A~i_j    -- OK
A        -- error
```

ただし `def` の仮引数は field ではないので、仮引数を裸で書くことはできる。

```formurae
def scale a X = a * X
```

この `X` は「呼び出し側から渡された tensor expression」を指す。

仮引数に添字を付けた場合は、その引数の tensor value に対する新しい indexed view
を作る。

```formurae
def trace A = contractWith (+) A~i_i
```

呼び出し側では、field は添字付きで渡す。

```formurae
trace A~p_q
```

このとき `A~i_i` は、引数 `A~p_q` の rank と variance が `~_` に適合することを
検査したうえで、関数本体の局所添字 `i` を使った view として扱う。
呼び出し側の添字名 `p,q` は本体へそのまま漏れない。

Egison と同様に、内側で通常の添字が付加された場合は、引数が持っていた添字は
付け替えられる。

```formurae
def swapView A = A_i~j

swapView T~p_q
```

では、本体内の `A_i~j` が `T` の添字 view を `_i~j` に付け替える。
`~p_q` に `_i~j` を追加する意味ではない。

既存の添字構造を保ったままさらに添字を追加したい場合は、Egison の `...`
添字追加構文を使う。

```formurae
A..._i
A..._(j_1)..._(j_k)
```

この `...` 付きの添字付加は `EAppendIndexed` として parse し、通常の
`EIndexed` とは分けて扱う。

metric は表層では

```formurae
metric g
```

と宣言するが、式中では添字付き tensor としてだけ metric 参照になる。

```formurae
g_i_j
g~i~j
g~i_j
```

裸の `g` は metric ではない。`param g` や scalar helper と名前が重なる場合は
warning を出し、添字付き `g` だけを metric として解決する。

## 5. `def` の AST 展開

`def` は文字列置換ではなく、AST として保持する。

```haskell
data Def = Def
  { defName   :: Name
  , defParams :: [Name]
  , defBody   :: IndexedExpr
  }
```

複数引数を最初から許す。

```formurae
def stress G D = λ * G * trace D + 2 * μ * strain D
```

演算子定義には結果添字を書かない。結果添字は本体の添字構造から推論する。

関数適用では、実引数を AST のまま束縛する。

```formurae
def div X = contractWith (+) (∂_i X~i)

step:
  p' = div v~j
```

展開時には `X` が `v~j` という tensor expression に束縛される。
本体の `X~i` は、`v` の rank/variance に対して `~i` view を作る。
添字名 `j` と `i` は同一視しない。`i` は `div` 本体の局所添字であり、
`contractWith` によって消える。

自由添字を新しく作る演算子は、Egison と同様に `withSymbols` を使って書く。

```formurae
def grad u = withSymbols [i] ∂_i u
```

`withSymbols [i] body` の内側で付加された `i` は局所的な symbol である。
`withSymbols` の外へ出るとき、`withSymbols` が導入した添字のうち結果に自由に
残っているものは、結果テンソルの最後尾へ転置され、表面上の添字名・上下の
symbol 情報は消える。

この規則により、`grad u` は「局所添字 `i` を持つ式」ではなく、添字名を外へ
漏らさない rank-1 tensor を返す。呼び出し側が必要に応じて

```formurae
(grad u)_j
```

のようにあらためて添字 view を付ける。

`withSymbols` を使わずに

```formurae
def grad u = ∂_i u
```

と書いた場合、`i` は未束縛の添字としてエラーにする。

### alpha-renaming

`def` 本体で導入された添字名は、呼び出し側や外側の式と衝突しないように
展開時に fresh name へ alpha-renaming する。

例:

```formurae
def trace A = contractWith (+) A~i_i

step:
  B'~i_j = trace C~k_l * D~i_j
```

`trace` 内部の `i` は、外側の自由添字 `i` と別物として扱う。
内部的には `i#trace1` のような fresh index に置き換えてから elaboration する。

## 6. `contractWith` の意味

`contractWith reducer expr` は、`expr` が持つ diagonal axes を reducer で畳み込む。

```formurae
contractWith (+) A~i_i
```

3 次元では次の finite fold へ落ちる。

```formurae
A~1_1 + A~2_2 + A~3_3
```

`reducer` は Formura scalar 式として lowering できる二項演算または二項関数に限る。

```formurae
contractWith (+) A~i_i
contractWith (*) A~i_i
contractWith max A~i_i
```

はそれぞれ

```formurae
A~1_1 + A~2_2 + A~3_3
A~1_1 * A~2_2 * A~3_3
max(max(A~1_1, A~2_2), A~3_3)
```

へ展開する。

縮約対象の diagonal axis がない場合、`contractWith` は恒等写像として扱う。
ただし reducer が tensor を返す関数である場合や、Formura へ lowering できない場合は
型検査または lowering でエラーにする。

## 7. `.` と `*` の扱い

`*` は縮約しない。

```formurae
X_i * Y_i
```

は同じ index structure を持つ成分ごとの積である。ここでは総和しない。

Egison と同様に、`*`、`+`、`sin` などの scalar operator は tensor expression
に lift される。

```formurae
X_i * Y_i      -- 同じ添字構造なので pointwise product
X_i * Y_j      -- 異なる自由添字なので tensor product
sin X_i        -- 成分ごとの sin
X_i + Y_i      -- 同じ添字構造なので成分ごとの和
```

`+` / `-` のように shape を合わせる必要がある operator では、自由添字構造が
合わなければ型エラーにする。`*` は異なる自由添字を結合して tensor product を
作れる。

`A . B` は常に

```formurae
contractWith (+) (A * B)
```

として扱う。

```formurae
X~i . Y_i
```

は `i` が diagonal axis になり、`contractWith (+)` で scalar へ縮約される。

```formurae
X_i . Y_j
```

は縮約対象がないので outer product として rank-2 tensor を返す。

```formurae
A~i_j . B~j_k
```

は `j` を縮約し、自由添字 `~i, _k` を持つ tensor を返す。

関数合成には `.` を使わず、Formurae 表面では `compose f g` と書く。

### `.` のユーザ定義

最終仕様では、`.` はユーザ定義できる。

```formurae
def (.) A B = contractWith (+) (A * B)
```

これを難しくする要因は意味論ではなく実装上の bootstrapping である。

- parser が `.` を中置演算子として読むには、少なくとも `.` の優先順位と結合規則を
  組み込みで知っている必要がある
- その一方で、elaboration 後の意味はユーザ定義または prelude 定義として
  展開したい
- `def (.)` の本体に `.` が出ると再帰展開になるため、標準定義では
  `contractWith (+) (A * B)` の core primitive へ落とす必要がある
- ユーザが `.` を再定義した場合、既存 prelude と衝突するので、再定義を許す範囲と
  warning/error 方針を決める必要がある

したがって実装順としては、まず `.` を parser/operator table では組み込みにする。
その lowering は標準 prelude の `def (.) A B = contractWith (+) (A * B)` と
同じ AST へ desugar する。AST-level `def` が安定した後、`def (.)` を通常の
ユーザ定義として受け取り、標準 prelude 定義を同じ機構で読み込む。

## 8. 関数適用構文

関数適用は、Egison 的な空白適用を基本にする。

```formurae
stress G~i~j D_i_j
trace A~i_j
```

ただし、parser とエラーメッセージを明確にするため、括弧付き適用も許せるようにする。

```formurae
stress(G~i~j, D_i_j)
trace(A~i_j)
```

両者は同じ AST に parse する。空白適用と中置演算子が混ざる場合は、Egison に近い
優先順位を採用するが、曖昧な式は括弧を要求してよい。

## 9. 暗黙縮約を廃止する

新 AST 経路では、同じ上下添字が現れるだけでは縮約しない。
縮約は `contractWith` だけが行う。`.` は内部で `contractWith` を使うので、
表面上の便利な縮約記法として残る。

```formurae
A~i_i              -- diagonal tensor
contractWith (+) A~i_i
A~i . B_i          -- desugar 後に contractWith (+) (A~i * B_i)
```

既存の implicit Einstein 経路は移行期間を設けず、AST lowerer への置き換え時に
削除する。未リリース言語なので、互換性より仕様の単純さを優先する。

## 10. エラー方針

エラーはできるだけ Formura コード生成前に出す。

- parse error: `contractWith` の reducer 形、`withSymbols` の bracket、
  空白適用と中置演算子の曖昧さ
- name error: 未定義 field/param/def、裸の添字付き field 参照、metric と scalar 名の混同
- rank error: field 宣言 rank と添字数の不一致
- variance error: 宣言と異なる上下添字、Kronecker delta の同 variance
- free-index error: LHS と RHS の自由添字構造の不一致
- diagonal error: scalar が必要な場所に未縮約 diagonal tensor が残っている
- reducer error: `contractWith` reducer が Formura scalar expression へ lowering できない
- lowering error: `∂_i` の対象が field/component として stencil 化できない、
  staggered placement が決められない

エラー文には、可能な限り表面式の断片と、期待される書き方を含める。

## 11. lowering pipeline

最終的な pipeline は次の順にする。

1. Unicode 正規化と tokenization
2. 表面式を `IndexedExpr` AST へ parse
3. `withSymbols` の局所 symbol scope を構築
4. `def` / prelude を AST レベルで展開し、必要に応じて alpha-renaming する
5. `.` を `contractWith (+)` へ正規化する
6. field、metric、param、local の名前解決
7. rank / variance / free index / diagonal index を elaboration
8. `withSymbols` 外へ出る自由な局所添字を最後尾へ転置し、添字 symbol 情報を消す
9. `contractWith` の diagonal axes を finite fold へ展開
10. LHS の自由添字ごとに成分式を生成
11. `∂_i`、metric、staggered placement を Formura scalar stencil へ lowering
12. Formura `.fmr` 用の Egison code を出力

ポイントは、`∂_i` をすぐ `∂^2_x` へ落とさないことである。
先に tensor operator を展開し、最後に成分が決まった段階で axis と placement を決める。

## 12. 実装ステップ

### Step 1: AST module を追加する

`fec/src/Formurae/IndexedExpr.hs` を追加し、次を実装する。

- `IndexedExpr`
- `Reducer`
- `TensorInfo`
- `EWithSymbols`
- `EAppendIndexed`
- parser skeleton
- pretty printer for debugging

この段階では既存の `ixExpand` と結果が一致する subset だけでよい。

### Step 2: scalar / indexed equation の AST parse

次を AST に parse できるようにする。

```formurae
g~i~j . ∂_i ∂_j u
contractWith (+) A~i_i
contractWith max A~i_i
X~i . Y_i
A~i_j . B~j_k
withSymbols [i] ∂_i u
A..._i
A..._(j_1)..._(j_k)
```

この時点では `def` 展開はまだ既存のままでもよい。

### Step 3: AST lowerer を既存 `ixExpand` と置き換える

`rewriteScalar` / `indexDefs` の添字付き経路を AST lowerer へ切り替える。

受け入れ条件:

- `g~i~j . ∂_i ∂_j u` が既存の Laplacian stencil と一致する
- `X~i . Y_i` が内積へ落ちる
- `A~i_j . B~j_k` が成分和へ落ちる
- `contractWith (*)` と `contractWith max` が finite fold へ落ちる
- 既存 examples の `.fmr` または check 結果が変わらない

### Step 4: AST-level `def` を導入する

`def` を `Def` AST として保存し、関数適用を AST substitution に変更する。

受け入れ条件:

```formurae
def trace A = contractWith (+) A~i_i
def Δ u = g~i~j . ∂_i ∂_j u
def grad u = withSymbols [i] ∂_i u

step:
  p' = trace A~i_j
  u' = Δ u
  q_i = (grad u)_i
```

が通る。

ここで `trace A~i_j` の実引数 `A~i_j` は field 参照として添字付きであり、
本体の `A~i_i` は本体局所の indexed view として扱う。
`grad` の内部添字 `i` は `withSymbols` の外へ漏れず、`grad u` は rank-1 tensor
として返る。

### Step 5: prelude 化する

Haskell 側に個別実装している数学演算子を、可能なものから prelude 定義へ移す。

```formurae
def (.) A B = contractWith (+) (A * B)
def trace A = contractWith (+) A~i_i
def div X = contractWith (+) (∂_i X~i)
def Δ u = g~i~j . ∂_i ∂_j u
def grad u = withSymbols [i] ∂_i u
```

`.` は初期実装では hardwired desugar でもよいが、最終的にはこの prelude 定義を
通常の `def` と同じ機構で読む。

### Step 6: 旧経路を削る

AST lowerer が十分に置き換わったら、次を削る。

- 文字列ベースの implicit Einstein 展開
- 結果添字付き `def`
- `.` を `*` に置換する古い処理
- Haskell 側の不要な数学演算子特殊規則

## 13. 検証項目

最低限、次のテストを用意する。

```formurae
metric g
field u : scalar

def Δ u = g~i~j . ∂_i ∂_j u

step:
  u' = Δ u
```

ユークリッド 3 次元なら、期待値は

```formurae
∂^2_x u + ∂^2_y u + ∂^2_z u
```

である。

```formurae
field X~i
field Y_i
field p : scalar

step:
  p' = X~i . Y_i
```

は

```formurae
X_1 * Y_1 + X_2 * Y_2 + X_3 * Y_3
```

へ落ちる。

```formurae
field A~i_j
field p : scalar

step:
  p' = contractWith max A~i_i
```

は

```formurae
max(max(A~1_1, A~2_2), A~3_3)
```

へ落ちる。

alpha-renaming の検証:

```formurae
def trace A = contractWith (+) A~i_i

step:
  B'~i_j = trace C~p_q * B~i_j
```

`trace` 内部の `i` が LHS の `i` と衝突しないことを確認する。

field 参照規則の検証:

```formurae
field v~i
field u : scalar

step:
  u' = v
```

はエラーになる。

`withSymbols` の検証:

```formurae
field u : scalar
field q_i

def grad u = withSymbols [i] ∂_i u

step:
  q'_i = (grad u)_i
```

`grad` の局所添字 `i` は外へ漏れず、呼び出し側の `_i` であらためて view を
取れることを確認する。

append-index の検証:

```formurae
def appendOne A = A..._i
```

通常の `A_i` が添字付け替えであり、`A..._i` が添字追加であることを確認する。

暗黙縮約廃止の検証:

```formurae
field A~i_j
field p : scalar

step:
  p' = A~i_i
```

は未縮約 diagonal tensor を scalar に入れているためエラーになる。

## 14. 完了条件

- `IndexedExpr` AST が添字付き式の中心表現になっている
- `def` は AST レベルで展開される
- 複数引数 `def` が使える
- 演算子定義に結果添字を書かない
- `withSymbols` で局所添字を導入できる
- 通常の添字付加は付け替え、`...` 付き添字付加は追加として扱われる
- field は添字付き宣言なら式中でも添字付きで使う
- `.` は任意 rank の tensor に対して働く
- `.` をユーザ定義できる
- `contractWith` は `+` 以外の reducer も finite fold へ落とせる
- repeated upper/lower index だけでは暗黙総和しない
- `def Δ u = g~i~j . ∂_i ∂_j u` が既存 Laplacian stencil へ落ちる
- `def grad u = withSymbols [i] ∂_i u` が rank-1 tensor を返す
- `def div`、`def trace`、弾性の `stress` のような物理演算子を prelude/Formurae 側で書ける
