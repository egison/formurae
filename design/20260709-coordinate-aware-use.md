# 座標文脈つき `use` 宣言の実装手順

Date: 2026-07-09

> 履歴メモ。`use` を中心とする以下の手順は当時の設計記録であり、現行仕様は
> `mode` と `DSL-DESIGN.md` の v1.29/v1.30 を参照する。

## 実装状況

- 2026-07-10: collocated の `grad`/`dGrad`/`divg`/`curl`/`lap`/`Δ` と、
  mode 共通の `hessian` は生成 `.egi` の関数群ではなく、
  ユーザー `def` と同じ TensorExpr prelude として
  `fec` 内で成分特殊化する方式へ移行した。ユーザー定義による shadowing は維持する。
- 2026-07-10: `.fmr` 出力層は各 `.egi` への複製をやめ、
  `lib/formurae-runtime.egi` の共有実装へ移した。生成物は座標・格子幅・名前変換表を
  明示 data context として渡す。collocated 微分、Yee helper、metric context は
  最終残余式が参照するものだけ、DEC form context は `mode dec` で生成する。
  以下の 2026-07-09 項目は移行履歴であり、
  「生成 `.egi` 側へ移した」という記述はこの共有 runtime 化より前の状態を指す。
- 2026-07-09: `use exterior-calculus { Δ }` はその後撤去し、
  `Δ`/`Δ4` は `.fme` 側の通常の `def` で書く方針へ移行済み。
  平坦格子用の生成 `.egi` 文脈からも `lap` は外し、
  `∂^2_x`/`∂'^m_x` と `dTaylor` を低水準プリミティブとして使う。
  `use vector-calculus { divg }` については 2D 例 `examples/divergence2d` で検証済み。
- 2026-07-09: `use exterior-calculus { Δ }` を実装済み。
  `Δ` は暗黙 prelude ではなく `use` で有効化される。
- 2026-07-09: `use vector-calculus { curl, divg }` の第一段階を実装済み。
  `curl`、`divg`、`dGrad` は `use vector-calculus` なしではエラーになる。
  現在は生成 `.egi` 側に座標文脈つき定義を出す。
- 2026-07-09: `use exterior-calculus { d, δ }` の第一段階を実装済み。
  ユーザが直接書いた `d`、`δ`、`codiff`、`dForm`、`hodge` は
  `use exterior-calculus` なしではエラーになる。`Δ` の内部依存としての
  `δ (d u)` は `Δ` use だけで動く。
- 2026-07-09: 生成 `.egi` に `feDim`、`feAxes`、`feCoords`、`feHsteps` を
  出す足場を実装済み。`embedding` の計量導出は `nth a [x, y, z]` ではなく
  `feCoords_a` を参照し、計量係数場の半セル評価も `feCoords_a`/`feHsteps_a`
  を参照する。
- 2026-07-09: 生成 `.egi` に座標文脈つき数学プリミティブを出す段階まで実装。
  `shift`、`dC`、`dC2`、`dTaylor` は `feCoords`/`feHsteps` を参照する。
  `use vector-calculus` で `dGrad`、`curl`、`divg` を生成し、
  `use exterior-calculus { d, δ }` や `assert-dd-zero` では
  `dYee`、`curlYee`、`sigmaC`、`hodge`、`dForm`、`codiff` を生成する。
  計量つき `Δ` は保存流束に必要な Yee プリミティブを生成する。
  生成 `.fmr` は全 `.fme` 例でバイト一致。
- 2026-07-09: `showFmr`、`fmrEq`、`fmrInit`、`emitModelOn` などの出力層も
  生成 `.egi` 側へ移した。`lib/fmrgen.egi` は `taylorStencil`、quote cleanup、
  形式補助だけの座標非依存 core になった。手書き `.egi` 例は移行まで
  `lib/fmrlegacy3d.egi` の 3D 互換文脈を読む。

このメモは、Formurae の数学演算子ライブラリを
`dimension`、`axes`、`metric scale`、`embedding` で指定された座標文脈に
合わせて生成するための実装手順をまとめる。

中心となる方針は次のとおり。

- `extern` は Formura/C 側へ渡すスカラー関数の宣言に限定する
- `use` は Formurae が座標文脈から生成する数学演算子の宣言にする
- `use MODULE { names }` のように、使いたい関数名まで明示する
- 座標系・次元に制限がある演算子は、できるだけ `.fmr` 生成前にエラーにする
- `lib/fmrgen.egi` の座標固定部分を、モデルごとに生成される定義へ移していく

## 1. `extern` と `use` の役割を分ける

`extern` は現在どおり、Formura/C 側に存在するスカラー関数を宣言する。

```text
extern exp
extern sin
extern sqrt
```

これは Formura の `extern function :: exp` へ下りるものであり、
座標系やテンソル構造とは独立である。

一方、`use` は Formurae の数学演算子を現在の座標文脈で具象化する宣言にする。

```text
use vector-calculus { curl, divg }
use exterior-calculus { d, δ, Δ }
```

`use` は単なるファイル読み込みではない。`dimension`、`axes`、`embedding` などから
作られる座標文脈を受け取り、その文脈に合う演算子定義と検査を生成する。

## 2. 表層構文を追加する

最初に parser へ次の構文を追加する。

```text
use MODULE { name1, name2, ... }
```

例:

```text
dimension 3
axes x, y, z

extern exp

use vector-calculus { curl }
use exterior-calculus { Δ }

field u : scalar
field E : vector
field B : vector
```

実装メモ:

- `Model` に `mUses :: [(String, [String])]` を追加する
- `use` 行は top-level 宣言としてのみ許す
- `MODULE` は当面 `vector-calculus` と `exterior-calculus` だけでよい
- `name` は Unicode 字訳後の名前で保持する
- 同じ `use` の重複は `nub` で正規化する
- 未知の module/name は parse 後の検査でエラーにする

## 3. 名前解決を `use` と接続する

最終仕様では、数学演算子は明示的に `use` されたときだけ使えるようにする。

```text
use exterior-calculus { Δ }

u' = u + dt * Δ u       -- OK
```

```text
u' = u + dt * Δ u       -- Error: Δ is not in use
```

ただし移行のため、最初は互換モードを置いてもよい。

段階:

1. `use` を parse し、まだ既存の暗黙利用も許す
2. `use` された演算子について早期検査を行う
3. examples を `use` 明示に移行する
4. 暗黙の `Δ` prelude、暗黙の `curl`/`divg` 利用をエラーにする

この順序なら、既存例の生成結果を保ちながら仕様を締められる。

## 4. 演算子レジストリを作る

`fec` 内に、演算子ごとの所属 module、必要条件、生成する Egison 定義を表す
小さなレジストリを作る。

初期案:

```text
exterior-calculus:
  d
  δ
  Δ
  hodge
  codiff

vector-calculus:
  dGrad
  curl
  divg
```

検査例:

- `curl` は `dimension 3` でのみ許す
- `dGrad`、`divg` は `field X : vector` の次元と座標次元が合う場合だけ許す
- `d`、`δ` は form field に対する演算として使う場合、form degree が必要
- `δ`、`Δ` は Hodge star を使うため、計量が必要であることを明示的に扱う
- 平坦直交格子では標準計量を暗黙に使う、という方針を仕様に書く
- `embedding` がある場合は、直交性検査と hodge 係数場生成を `use` された演算子に応じて行う

エラー例:

```text
dimension 2
axes x, y
use vector-calculus { curl }
```

```text
fec: error: curl requires dimension 3
```

## 5. `lib/fmrgen.egi` を分割する

当初の課題は、`lib/fmrgen.egi` に座標非依存の処理と `x,y,z` 固定の
座標依存処理が混在していたことだった。現在は次のように分けている。

```text
1. 座標非依存の基盤
   lib/fmrgen.egi:
   taylorStencil, gaussSolve, unquoteAll, formComps, scaleForm など

2. モデルごとに生成する残余文脈と式
   生成 .egi:
   feDim, feAxes, feCoords, feHsteps, field, step、
   残余依存の shift/dC/dC2/dTaylor・Yee・metric、mode dec の form context

3. 共有 Formura 出力 runtime
   lib/formurae-runtime.egi:
   FMR.show, FMR.eq, FMR.init, FMR.componentEqs, FMR.scalarEq, FMR.emitModelOn
```

`.fme` から生成される `.egi` は `lib/formurae-tensor.egi`、`lib/fmrgen.egi`、
`lib/formurae-runtime.egi` を読む。まだ `.fme` 化していない
手書き `.egi` 例は互換用に `lib/fmrlegacy3d.egi` も読む。

`lib/fmrgen.egi` からは

```egison
def coords : Vector MathValue := [| x, y, z |]
def hsteps : Vector MathValue := [| hx, hy, hz |]
```

のような固定定義を取り除いた。対応する定義はモデルごとの生成 `.egi` に出る。

## 6. 座標文脈つき定義を生成する

`dimension 2`、`axes θ, φ` なら、生成 `.egi` 側には例えば次のような情報を出す。

```egison
def feDim := 2
def feAxes := ["theta", "phi"]
def feCoords : Vector MathValue := [| x, y |]
def feHsteps : Vector MathValue := [| hx, hy |]
```

`dimension 3`、`axes r, θ, φ` なら:

```egison
def feDim := 3
def feAxes := ["r", "theta", "phi"]
def feCoords : Vector MathValue := [| x, y, z |]
def feHsteps : Vector MathValue := [| hx, hy, hz |]
```

重要なのは、内部の Formura 座標は当面 `x,y,z` のままでもよいが、
数学演算子は `feDim` と `axes` から生成される、という構造にすることである。

## 7. `Δ` を最初の移行対象にする

最初の小さなマイルストーンは、現在暗黙 prelude に入っている `Δ` を
`use exterior-calculus { Δ }` へ移すことである。

現状:

```text
def Δ u = 0 - δ (d u)
```

を `fec` の暗黙 prelude に持っている。

移行後:

```text
use exterior-calculus { Δ }
```

がある場合だけ、次の定義を有効化する。

```text
def Δ u = 0 - δ (d u)
```

成功条件:

- `use exterior-calculus { Δ }` を足した既存例の `.fmr` がバイト一致する
- `Δ` を使っているのに `use` がない場合、わかりやすいエラーになる
- 平坦例では `lap`、計量例では `lb` へ下りる既存挙動が保たれる

## 8. `curl` / `divg` を次に移す

次の対象は collocated vector calculus である。

```text
use vector-calculus { curl, divg }
```

現在の Egison 側定義は概ね次の形である。

```egison
def dGrad (X: Vector MathValue) : Matrix MathValue :=
  generateTensor (\[a, b] -> dC a X_b) [3, 3]

def curl (X: Vector MathValue) : Vector MathValue :=
  withSymbols [i, j, k] (ε 3)~i~j~k . (dGrad X)_j_k

def divg (X: Vector MathValue) : MathValue :=
  trace (dGrad X)
```

`curl` は 3次元専用なので、`dimension 2` で `use vector-calculus { curl }` した時点で
エラーにできる。

`divg` は任意次元へ一般化しやすい。`dGrad` の shape を `[feDim, feDim]` にすればよい。

成功条件:

- `maxwell3d` が `use vector-calculus { curl }` 明示で同じ `.fmr` を生成する
- `dimension 2` + `curl` が早期エラーになる
- `divg` の定義が 2D/3D の両方で自然に生成できる

## 9. `d` / `δ` / `dForm` / `codiff` を移す

外微分と余微分は form degree と計量に依存するため、`use` の意味が特に重要である。

```text
use exterior-calculus { d, δ }
```

既存の定義:

```egison
def dForm (f: (Integer, Integer, [MathValue])) : (Integer, Integer, [MathValue]) := ...

def codiff (f: (Integer, Integer, [MathValue])) : (Integer, Integer, [MathValue]) :=
  scaleForm ((-1) ^ (3 * (formDeg f + 1) + 1)) (hodge (dForm (hodge f)))

def δ := codiff
```

ここには `3` 固定が残っている。`feDim` に置き換える必要がある。

成功条件:

- `maxwell_dec` が `use exterior-calculus { d, δ }` 明示で同じ `.fmr` を生成する
- `assert-dd-zero` の検査が `d` の use と整合する
- `codiff` の符号が `feDim` と form degree から決まる

## 10. examples の移行

各 `.fme` の冒頭に、使う数学演算子を明示する。

例:

```text
dimension 3
axes x, y, z

extern exp
use exterior-calculus { Δ }
```

```text
dimension 3
axes x, y, z

extern exp
use vector-calculus { curl }
```

```text
dimension 3
axes x, y, z

extern exp
use exterior-calculus { d, δ }
```

移行時の検証は、既存の方針どおり `.fmr` のバイト一致を使う。

対象:

- `diffusion3d`, `highorder4`, `burgers3d`, `metric_*`, `spherical3d`, `polar2d`
- `maxwell3d`
- `maxwell_dec`
- `elastic3d`

## 11. 最終的な仕様イメージ

最終的には、`.fme` の top-level は次の責務分担になる。

```text
dimension 3
axes x, y, z
embedding [...]

param dt = ...

extern exp
extern sin

use exterior-calculus { d, δ, Δ }
use vector-calculus { curl, divg }

field ...
```

名前解決の責務:

- `extern`: Formura/C 側のスカラー関数
- `use`: 座標文脈つき数学演算子
- `∂_x`: Formurae 組み込みの座標軸微分構文
- `∂_i`: Formurae 組み込みの添字微分構文
- `def`: ユーザ定義演算子

この形にすると、Formurae の「座標系に依存しない数式記述」を、
実装構造としても `use` と座標文脈つきライブラリ生成に反映できる。

## 最初のマイルストーン

最初の実装目標は次のとおり。

```text
use exterior-calculus { Δ } を実装し、
Δ を使う既存例に use を追加しても生成 .fmr がバイト一致することを確認する。
```

このマイルストーンは完了した。`use` の構文、名前解決、早期エラーを導入し、
さらに当時は `lib/fmrgen.egi` の座標依存部分と出力層を生成 `.egi` 側へ移した。
出力層は v1.30 で `lib/formurae-runtime.egi` に再抽出済みである。
