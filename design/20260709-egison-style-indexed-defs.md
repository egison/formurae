# Egison 側に任せる添字補完と Formurae の役割

Date: 2026-07-09

Superseded: このメモは「Formurae に一般的な添字補完器を実装しない」という
保守的な境界を記録した履歴文書である。現行方針では、Egison と同じ
`.` / `contractWith` / `withSymbols` を Formurae の AST に持たせ、添字つき `def` を
prelude 的な数式定義へ広げる。詳細は
`design/20260709-dot-contractwith-tensor-operators.md` と
`design/20260709-indexed-expr-ast-implementation.md` を参照する。

## 目的

Formurae は、Formura へ落とすための物理 DSL / 座標文脈 DSL として薄く保つ。
テンソル記法、スカラー関数の tensorMap 的 lift、微分形式の省略添字補完、縮約などの
数式展開は Egison 側に任せる。

中心方針は次のとおり。

- Formurae には Egison と重複する一般的な添字補完器を実装しない
- `curl` / `divg` は Formurae の添字付き項を返す特殊構文ではなく、生成 Egison 側の通常関数として扱う
- `E' = E + dt * curl B` のような添字なし vector equation は許す
- `E'~i = E~i + dt * curl B` のように、添字付き式へ添字なし vector 関数を混ぜる形は許さない
- 添字付き equation は、右辺に自由添字が表面上すべて現れる strict Einstein 記法として扱う
- Formurae の lowering は、field 宣言に基づく成分名への射影と Formura 出力に集中する

## 1. Formurae と Egison の分担

### 1.1 Formurae が担当すること

Formurae は次を担当する。

- `dimension` / `axes` / `metric` / `embedding` などの座標文脈を読む
- `field` 宣言から Formura storage layout を決める
- `use vector-calculus { curl }` のような宣言に応じて、必要な Egison 定義だけを生成 `.egi` に出す
- 添字なし vector/form equation を成分更新式へ下ろす
- 明示的な添字 equation は strict Einstein 検査と成分展開を行う
- 最終的に Formura `.fmr` を出す Egison プログラムを生成する

### 1.2 Egison が担当すること

Egison は次を担当する。

- tensor 値に添字情報を保持する
- スカラー関数を tensor 引数へ lift する
- `withSymbols` による局所添字管理を行う
- `epsilon`、metric、縮約、tensorMap 的 lift を含む数式展開を行う
- differential forms の omitted-index completion を行う
- `curl` / `divg` などの生成定義の内部で添字記法を評価する

したがって、Formurae 側で Egison の omitted-index completion を再実装しない。

## 2. 添字なし vector equation

ベクトル解析風に書きたい場合は、式全体を添字なしにする。

```text
use vector-calculus { curl }

field E : vector
field B : vector

step:
  E' = E + dt * curl B
  B' = B - dt * curl E'
```

Formurae はこれを、生成 Egison 側で次のような成分定義へ下ろす。

```egison
def feqE_i := withSymbols [i] E_i + dt * (curl B_#)_i
def feqB_i := withSymbols [i] B_i - dt * (curl E'_#)_i
```

ここで Formurae がしていることは、`E_i` や `(curl B_#)_i` のように成分を取り出す
ことである。`curl` の数式展開そのものは、生成 `.egi` に出した Egison 定義が担当する。

```egison
def dGrad (X: Vector MathValue) : Matrix MathValue :=
  generateTensor (\[a, b] -> dC a X_b) [feDim, feDim]

def curl (X: Vector MathValue) : Vector MathValue :=
  withSymbols [i, j, k] (epsilon 3)~i~j~k . (dGrad X)_j_k
```

このため、Formurae に「`curl B` から `epsilon~i~j~k . ∂_j B_k` を作る」
target-aware な添字補完ルールは不要である。

## 3. 添字付き equation

添字付き equation では、自由添字を右辺の表面に明示する。

```text
field v~i @ staggered
field σ{~i~j} @ staggered

step:
  v'~i = v~i + (dt / ρ0) * ∂_j σ~i~j
```

この層では strict Einstein 検査を行う。

- 自由添字は LHS と同じ名前・上下で各項に現れる
- ダミー添字は上1・下1だけを許す
- `∂_i` は下添字だけを許す
- metric による上げ下げは明示的に書く

したがって次は許さない。

```text
-- NG
E'~i = E~i + dt * curl B
```

`curl B` は添字付き項ではなく vector 値を返す Egison 関数呼び出しなので、添字付き
Formurae equation の項としては自由添字 `~i` が見えない。

同じ物理を添字付き equation で書くなら、展開形を明示する。

```text
E'~i = E~i + dt * (epsilon~i~j~k . ∂_j B_k)
```

## 4. `use vector-calculus`

`use vector-calculus` は、Formurae が現在の座標文脈から生成 Egison 定義を出すための
宣言である。

現在の対象:

```text
use vector-calculus { curl }
use vector-calculus { divg }
use vector-calculus { dGrad }
```

`curl` は `dimension 3` 専用として、`use` 宣言時点で検査する。
`divg` / `dGrad` は `dimension 1` / `2` / `3` で生成できる。

`divg` の例:

```text
use vector-calculus { divg }

field V : vector
field q : scalar

step:
  q' = divg V
```

生成 Egison 側では、`q'` の RHS は概念的に次のようになる。

```egison
divg V_#
```

`divg` の中身は Egison 定義である。

```egison
def divg (X: Vector MathValue) : MathValue := trace (dGrad X)
```

## 5. `def` の扱い

`.fme` の `def` は、第一段階では scalar 関数と座標軸 stencil の定義に寄せる。

```text
def square u = u * u
def Δ u = ∂^2_x u + ∂^2_y u + ∂^2_z u
def Δ4 u = ∂'^2_x u + ∂'^2_y u + ∂'^2_z u
```

body に新しい自由添字を持つ定義は、Formurae の通常 `def` としては扱わない。

```text
-- 採用しない
def grad u = ∂_i u
def curl X = epsilon~i~j~k . ∂_j X_k
```

現行仕様でも、`withSymbols` なしで新しい自由添字を導入するこの形は採用しない。
現行仕様では次のように `withSymbols` で局所添字を導入する。

```text
def grad u = withSymbols [i] ∂_i u
```

この履歴メモを書いた時点では、この種類の数式抽象は Egison 側で定義し、
Formurae は必要な定義を `use` に応じて生成 `.egi` に出す方針だった。

## 6. 実装状態

現状の Formurae 実装は、この方針に近い。

- `E' = E + dt * curl B` は unindexed vector equation として通る
- `curl B` は `curl B_#` という Egison の vector 呼び出しになり、component lowering で `(curl B_#)_i` として取り出す
- `curl` / `divg` は `use vector-calculus` で明示した場合だけ利用できる
- `curl` / `divg` の数式本体は、生成 `.egi` の Egison 定義として出る
- 一般的な omitted-index completion は Formurae には実装しない

重要なのは、Formurae の component lowering は「成分を取り出す」だけであり、
`curl` の数式を Haskell 側で `epsilon` 展開しないことである。

## 7. 実装手順

### Step 1: documentation を新方針へ揃える

- `def curl X~i = ...` や `def grad u_i = ...` を Formurae の目標構文として紹介しない
- `curl` / `divg` は `use` で生成される Egison 定義として説明する
- この履歴文書では、Formurae には一般的な添字補完器を実装しないことを明記する

### Step 2: 既存実装の境界を明確にする

- `opPass` は vector/form 関数呼び出しを Egison 呼び出しへつなぐだけに保つ
- `rewrite` は成分射影だけを行う
- `curl` の `epsilon` 展開を Haskell 側へ移さない

### Step 3: 禁止ケースを確認する

次の形が分かりやすく失敗することを確認する。

```text
E'~i = E~i + dt * curl B
```

一方、次は通る。

```text
E' = E + dt * curl B
```

### Step 4: 回帰確認

- `cabal build`
- `make maxwell3d`
- `make divergence2d`
- 必要に応じて `make all`

## 8. 完了条件

- Formurae 側に一般的な添字補完器を追加しない設計になっている
- `E' = E + dt * curl B` は、生成 Egison の `curl` 定義に任せて動く
- `E'~i = E~i + dt * curl B` は strict Einstein 検査で失敗する
- documentation が「数式展開は Egison、Formurae は座標文脈と Formura 出力」という分担を説明している
- 既存例の生成結果とテストが壊れていない
