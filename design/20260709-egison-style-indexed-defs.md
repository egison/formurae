# Egison 方式の添字記法と省略添字補完

Date: 2026-07-09

## 目的

Formurae の数学記法を、Egison / type-tensor-paper と同じ考え方に寄せる。
その際、添字付き expression と、添字を省略した tensor/vector equation を明確に
分ける。

重要な方針は次のとおり。

- 添字付き expression では、自由添字は式の表面に明示されていなければならない
- `E'~i = E~i + dt * curl B` のように、添字付き項の中へ `curl B` を混ぜる形は許さない
- ベクトル解析風に書く場合は、式全体を添字なし tensor equation として書く
- つまり `E' = E + dt * curl B` はサポート対象にできる
- `curl` / `div` / `grad` は、添字付き項を返す特殊構文ではなく、tensor/vector 値を返す普通の関数として扱う
- 添字なし equation は、LHS の field 宣言・shape・添字型に基づいて component equation へ lowering する
- Egison の omitted-index completion と同様に、省略された添字は必要な文脈で補完する
- strict Einstein 検査は、添字付き expression に対しては従来どおり厳密に行う

## 1. 2つの記法層

### 1.1 添字付き expression

添字付き expression では、自由添字が表面に現れている必要がある。

```text
E'~i = E~i + dt * (epsilon~i~j~k . ∂_j B_k)
B'~i = B~i - dt * (epsilon~i~j~k . ∂_j E'_k)
q' = ∂_i V~i
```

この層では、右辺の各項の自由添字が LHS の自由添字と一致するかを検査する。
したがって、次は許さない。

```text
-- NG
E'~i = E~i + dt * curl B
```

`curl B` の表面には自由添字がないため、添字付き項 `~i` として扱えない。

### 1.2 添字なし tensor/vector equation

ベクトル解析風に書きたい場合は、式全体を添字なしにする。

```text
E' = E + dt * curl B
B' = B - dt * curl E'
q' = div V
P' = grad u
```

この層では、`curl B` は「自由添字 `~i` を暗黙に持つ項」ではなく、
rank-1 tensor/vector 値を返す普通の関数適用である。式全体の shape は LHS の
field 宣言から決まり、最後に component equation へ lowering する。

概念的には、compiler が次のような展開を行う。

```text
E' = E + dt * curl B

-- lowering 後
E'~i = E~i + dt * (epsilon~i~j~k . ∂_j B_k)
```

この補完は、添字付き expression の途中で発生するのではなく、添字なし equation を
component equation に下ろす境界で発生する。

## 2. Egison との対応

Egison では、tensor は添字情報を値側に保持できる。また、differential forms は
添字を省略した tensor として表現され、演算に参加するときに omitted indices が
補完される。

Formurae に移すべき要点は次である。

- 添字情報は、macro-local な文字列ではなく tensor 値に付く
- スカラー関数は tensor 引数に対して `tensorMap` 的に lift される
- 添字 reduction と省略添字 completion は別の処理である
- completion は、隠れた自由添字を添字付き項の中に突然作る処理ではない
- completion は、添字なし tensor/form 値を、演算や lowering の文脈で具体的な添字付き表現へ変換する処理である

この理解に基づくと、`curl B` は添字付き項ではなく、vector 値を返す関数適用として
扱うのが自然である。

## 3. `curl` / `div` / `grad` の位置付け

`curl` / `div` / `grad` は、Formurae の indexed core には入れない。
ただし、添字なし tensor/vector equation のための prelude 関数としては提供できる。

```text
use vector-calculus { curl, div, grad }

step:
  E' = E + dt * curl B
  B' = B - dt * curl E'
```

これらの関数は、入力と出力の rank / dimension 制約を持つ。

```text
grad : scalar -> covariant vector
div  : contravariant vector -> scalar
curl : covariant vector -> contravariant vector   -- 3D
```

ただし Formurae では rank を型で管理しないため、これらは静的型ではなく
field 宣言、metric、dimension、実際の lowering 時の shape 検査として実装する。

`curl` は 3D 専用なので、`dimension 2` で `use vector-calculus { curl }` または
`curl B` が現れた場合は早期エラーにする。

## 4. 添字付き式との接続

`curl` / `div` / `grad` を添字付き式の部分項として使うことは、第一段階では禁止する。

```text
-- NG
E'~i = E~i + dt * curl B

-- OK
E' = E + dt * curl B

-- OK
E'~i = E~i + dt * (epsilon~i~j~k . ∂_j B_k)
```

理由は、添字付き expression の検査を単純で予測可能に保つためである。
自由添字が見えている式は strict Einstein 検査へ渡す。
自由添字が見えていない vector calculus 関数は、添字なし equation の lowering で扱う。

## 5. `def` の扱い

`def` は、まず scalar 関数と座標軸 stencil の定義に限定する。

```text
def square u = u * u
def Δ u = ∂2x u + ∂2y u + ∂2z u
def Δ4 u = ∂2,2x u + ∂2,2y u + ∂2,2z u
```

添字付き expression に scalar 関数を適用した場合は map される。

```text
W_i = square V_i
```

一方、body に新しい自由添字を持つ `def` は、通常の scalar `def` としては扱わない。

```text
-- scalar def としては NG
def grad u = ∂_i u
def curl X = epsilon~i~j~k . ∂_j X_k
```

`curl` / `div` / `grad` を提供する場合は、通常の scalar `def` ではなく、
prelude の tensor/vector 関数として扱う。実装上は、unindexed equation lowering が
これらの関数を既知の rank-changing operation として展開する。

将来、ユーザ定義の rank-changing tensor 関数を一般化する場合は、
Egison の omitted-index completion と index-sequence pattern を参考に、別の設計として
導入する。

## 6. `use` との関係

`use vector-calculus { curl, div, grad }` は、添字なし tensor/vector equation のための
prelude として位置付ける。

```text
dimension 3
axes x, y, z
metric δ

use vector-calculus { curl, div, grad }

field E~i @ staggered
field B_i @ staggered

step:
  E' = E + dt * curl B
```

`use` された関数だけを利用可能にする。未 import の関数名は通常の未定義名として
エラーにする。

`extern` との分担は従来方針どおりである。

- `extern`: Formura/C 側で使うスカラー関数
- `use`: Formurae が座標文脈・dimension・metric から展開する数学演算子

## 7. lowering 方針

### 7.1 添字なし equation の shape 推論

LHS が `field E~i` として宣言されている場合、

```text
E' = E + dt * curl B
```

は rank-1 equation として扱う。compiler は LHS の添字 pattern `~i` を component
lowering の target pattern として使う。

`curl B` は直接 `~i` を持つ項ではないが、`curl` の lowering rule が target pattern を
受け取り、次の添字式を生成する。

```text
curl(B) under target ~i
  -> epsilon~i~j~k . ∂_j B_k
```

`div V` は scalar target の中でのみ許す。

```text
div(V) under scalar target
  -> ∂_i V~i
```

`grad u` は rank-1 target の中でのみ許す。

```text
grad(u) under target _i
  -> ∂_i u

grad(u) under target ~i
  -> g~i~j . ∂_j u
```

ここで上げ下げは自動ではなく、`grad` の rule が metric を明示的に展開式へ入れる。
ユーザの添字付き expression 内で勝手に上げ下げするわけではない。

### 7.2 添字付き expression の検査

lowering 後に得られた expression は、通常の strict Einstein 検査に通す。

```text
E'~i = E~i + dt * (epsilon~i~j~k . ∂_j B_k)
```

この段階では自由添字もダミー添字もすべて表面に現れている。

## 8. 実装手順

### Step 1: 設計と documentation を修正する

成功条件:

- `E'~i = E~i + dt * curl B` を NG と明記する
- `E' = E + dt * curl B` をサポート対象として明記する
- `curl` / `div` / `grad` は indexed core ではなく unindexed equation prelude として説明する

### Step 2: unindexed equation lowering に target pattern を渡す

現在の component lowering に、LHS field の添字 pattern を渡せるようにする。

成功条件:

- `field E~i ...` に対して `E' = ...` を rank-1 target として lower できる
- scalar LHS に対して `q' = ...` を scalar target として lower できる

### Step 3: vector-calculus prelude を target-aware にする

`curl` / `div` / `grad` を、target pattern を受け取って添字 expression を返す
lowering rule として実装する。

成功条件:

```text
E' = E + dt * curl B
  -> E'~i = E~i + dt * (epsilon~i~j~k . ∂_j B_k)

q' = div V
  -> q' = ∂_i V~i

P' = grad u
  -> P'_i = ∂_i u
```

### Step 4: 禁止ケースのエラーを入れる

成功条件:

```text
E'~i = E~i + dt * curl B
  -> NG: vector-calculus functions are only allowed in unindexed tensor equations

dimension 2
E' = E + dt * curl B
  -> NG: curl requires dimension 3

q' = curl B
  -> NG: curl returns rank-1 but scalar target was expected
```

### Step 5: examples を更新する

成功条件:

- Maxwell 例で `E' = E + dt * curl B` が通る
- divergence 例で `q' = div V` が通る
- 添字展開版も引き続き通る
- `make all` が通る

## 9. 完了条件

この設計が完了したと言える条件は次である。

- 添字付き expression では、自由添字が表面に現れる規則を維持する
- `E'~i = E~i + dt * curl B` は分かりやすく失敗する
- `E' = E + dt * curl B` は unindexed tensor equation として通る
- `curl` / `div` / `grad` は `use vector-calculus` で明示的に import された場合だけ使える
- lowering 後の式は通常の strict Einstein 検査に通す
- Egison の省略添字補完と同様に、添字省略は equation/lowering の境界で扱う
- `make all` が通る
