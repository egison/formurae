# Formurae 核意味論の実装手順

Date: 2026-07-08

> **履歴文書:** production cutoverは完了した。現行の責務境界と実装手順は
> [20260711-pre-post-fec-pipeline.md](20260711-pre-post-fec-pipeline.md)を正とする。

Follow-up: このメモの中核方針である「添字付きテンソル演算子を `.fme` の `def` で
定義できるようにする」は、2026-07-09 の再設計で復活した。古い保守的な境界は
`design/20260709-egison-style-indexed-defs.md` に履歴として残す。現行方針は
Egison と同じ `.` / `contractWith` / `withSymbols` を Formurae の AST に持たせる
ものであり、詳細は `design/20260709-dot-contractwith-tensor-operators.md` と
`design/20260709-indexed-expr-ast-implementation.md` を参照する。
さらに v1.30 では標準座標演算子も TensorExpr prelude として成分特殊化し、
生成プリンタを `lib/formurae-runtime.egi` へ共有化した。以下の内部 tensor alias 案は
履歴であり、現行構成は `DSL-DESIGN.md` の v1.30 を参照する。

このメモは、Formurae を Egison の強みを活かした小さな核へ整理するための
実装手順をまとめる。

中心となる方針は次のとおり。

- スカラー関数はテンソルに適用されたとき自動的に成分ごとへ lift/map される
- 点ごとのスカラー演算とテンソル縮約を分ける
- 添字付きテンソル演算子をユーザが `.fme` 側で定義できるようにする
- 可能な数学演算子はコンパイラ組み込みではなく prelude 定義へ移す

目的はコンパイラの特殊規則を増やすことではない。`fec` は薄い変換器に保ち、
Egison の「任意のスカラー関数・テンソル関数に添字記法を使える」性質を
Formurae の表層仕様へ露出する。

## 1. 既存挙動を golden test として固定する

核意味論を変える前に、現在の生成結果を回帰テストとして固定する。

対象:

- `examples/elastic3d`
- `examples/maxwell3d`
- `examples/maxwell3d_yee`
- `metric_sphere`、`metric_torus` などの計量例
- `diffusion3d`、`kleingordon`、`ks3d` などの代表的なスカラー例

成功条件:

- 既存の `.fme -> .egi -> .fmr` 生成結果が、記法を変えていない例では
  できるだけバイト一致する。
- 整形差だけが避けられない場合は、理由を限定して記録する。
- 既存例の `make` が通る。

## 2. 核となる式の分類を AST で明確にする

表層 AST では、式を少なくとも次の4種類に分ける。

```text
scalar intrinsic:
  +, -, *, /, sin, cos, exp, sqrt, ...

tensor contraction:
  . / contractWith

coordinate derivative:
  ∂_x, ∂_y, ∂_z, ∂_theta, ...

indexed derivative:
  ∂_i, ∂~i
```

上添字と下添字は、最初から AST に残す。

```text
X~i   -- 反変成分
X_i   -- 共変成分
```

ユークリッド格子でも上付き/下付き添字を常に保持する。ユークリッド計量は
単位行列なので、計量による上げ下げを特別扱いせず同じ仕組みで扱える。
これにより、将来の計量、上げ下げ、接続係数へ進める。

計量テンソルは標準的には `metric g` のように表層名を宣言する。

> **v2.1で置換済み:** 現行仕様は
> [20260711-pre-post-fec-pipeline.md](20260711-pre-post-fec-pipeline.md) §3.5を正とする。
> `metric g`は`g_i_j` / `g~i~j`だけを定義し、whole tensorは`g_#_#` / `g~#~#`で参照する。
> mixed varianceは暗黙生成せず、同じ`g`をFormurae model bindingへ再利用する旧warning規則は
> hard errorへ変更した。以下は旧loweringの設計履歴である。

`metric g` は表層では添字なし宣言だが、式中では実質的に添字付きテンソルとして
扱う。裸の `g` は metric 参照ではなく、metric は常に `g_i_j`、`g~i~j`、
`g~i_j`、`g_i~j` のように添字付きで参照する。
上下パターンは内部では
compiler-private な base 名へ下ろす。内部 base 名には `_` を使わず、
`FormuraeInternal` prefix を予約する。

```text
g~i~j  -> FormuraeInternalMetricContra_i_j
g~i_j  -> FormuraeInternalMetricMixedUpDown_i_j
g_i~j  -> FormuraeInternalMetricMixedDownUp_i_j
g_i_j  -> FormuraeInternalMetricCov_i_j
```

ここで `_i_j` は Egison の添字アクセスであり、内部 base 名そのものには `_` を含めない。
`metric g` がない場合、`g` は普通の変数名として扱われる。例えば `param g = 1.0` は
重力加速度などに使える。一方で `g_i_j` のように添字付き計量として使うには
`metric g` 宣言が必要である。

`metric g` がある場合でも、同じ表層名の `param g` のような添字なし scalar は
添字の有無で区別できるため許す。ただし読み手が混同しやすいので warning を出す。
同名の field や def についても、同名が現れた時点で warning を出す。
実際の参照解決は添字 arity と variance で行い、同じ arity/variance に複数候補が
出る場合だけエラーにする。

一般の添字付きテンソル変数は、宣言された添字仕様どおりに常に添字付きで使う。
例えば `field v~i` を裸の `v` として参照することはできない。
metric はこの規則の例外的な宣言形であり、`metric g` は内部的には2添字テンソルを
宣言しているものとして扱う。

初期案では一般の添字付きテンソル変数に上下パターンごとの内部束縛を用意した。
v1.30 では field/let を storage 成分へ直接特殊化するため、
`FormuraeInternalTensor...` alias は撤去した。v1.31 では field/let の生成 Egison
束縛自体を bare tensor に統一し、成分参照は Egison の添字補完に任せるため、
`A := A_#` のような whole-tensor alias も生成しない。

## 3. スカラー関数の自動 lift/map を実装する

Formurae は Egison と同様に、スカラー関数がテンソルへ適用された場合、
テンソルの各成分へ自動的に map する。

次の演算子・関数は同じ種類の操作として扱う。

```text
+, -, *, /, sin, cos, exp, sqrt, ...
```

これらはスカラー関数だが、テンソル引数に対しては成分ごとに lift される。

例:

```text
exp u_i       -- 各成分 u_i への exp
sin X_i       -- 各成分 X_i への sin
a * X_i       -- 各成分へのスカラー係数倍
X_i * Y_i     -- 同じ添字構造を持つ成分同士の点ごとの積
X_i + Y_i     -- 同じ添字構造を持つ成分同士の点ごとの和
```

実装メモ:

- Formura が C/Formura へ出力できる scalar intrinsic の allowlist を持つ。
- `+`、`*`、`sin`、`cos`、`exp` を同じ lift 可能なスカラー関数として扱う。
- lift される演算のテンソル shape/添字構造が合うことを検査する。
- `*` はテンソル縮約には使わない。`*` は点ごとのスカラー積であり、
  テンソルへ lift される。

成功条件:

- 既存のスカラー式が同じ Formura コードを生成する。
- `+`、`*`、`sin`、`cos`、`exp` を含むテンソル式が、成分ごとの
  スカラー Formura 式へ落ちる。
- shape/添字構造の不一致は Formura コード生成前にエラーになる。

## 4. `.` / `contractWith` をテンソル積・縮約の演算子にする

テンソル構造を変える積は `.`/`contractWith` だけで表す。
Formurae 表面の `.` は関数合成には使わない。関数合成は `compose f g` と書く。
生成する Formura では必要に応じて Formura 本体の `.` へ落としてよいが、
Formurae の parse 段階では tensor `.` と関数合成を混ぜない。

例:

```text
epsilon~i~j~k . ∂_j X_k
```

この操作はテンソル式を結合し、自由添字と縮約添字を決める。
非ユークリッド座標を見据えると、縮約は原則として上添字と下添字の対で
起こるものとして設計しておくのがよい。

実装メモ:

- 表層記法として `.` を残す。
- 内部では Egison の `contractWith` 形式へ下ろす。
- 生成される成分名が安定するように、自由添字の順序を決定的に保つ。
- 最初は既存のユークリッド互換挙動を許してよいが、後で variance-aware な
  縮約へ差し替えられる構造にする。

成功条件:

- 既存の `epsilon`/`delta` 縮約が同じコードを生成する。
- `*` と `.` が別の AST ノード・別の lowering 経路を持つ。
- 誤って `*` でテンソル縮約を書いた場合、コンパイラが検出できる。

## 5. ユーザ定義の添字付きテンソル演算子を追加する

次の大きな表層機能は、添字情報を持つテンソル引数を受け取る演算子定義である。
Egison と同様に、演算子定義には結果添字を書かない。新しい自由添字を作る場合は
`withSymbols` を使う。

例:

```text
def curl X = withSymbols [i, j, k] epsilon~i~j~k . ∂_j X_k
def div X = contractWith (+) (∂_i X~i)
def grad u = withSymbols [i] ∂_i u
def stress G D = λ * G * trace D + 2 * μ * D
```

最初の実装では、完全な型システムは不要である。`.fme` の定義を Egison の
添字付きテンソル関数定義へ渡す薄い変換でよい。

実装メモ:

- `X~i`、`X_i` のような添字付き実引数と、`u` のようなスカラー実引数を parse する。
- `withSymbols [i] ...` で導入された局所添字を parse する。
- 呼び出し時には、テキスト置換ではなく Egison の添字付き関数の仕組みへ接続する。
- 既存の単純な `def NAME ARG = EXPR` は、新経路で置き換えられるまで一時的に残す。

成功条件:

- `grad`、`div`、`curl` を Formurae/prelude 定義として書ける。
- コンパイラ組み込みを prelude 定義へ置き換えても、既存例の生成コードが
  バイト一致する。
- 添字が破綻したユーザ定義はコード生成前に失敗する。

## 6. 数学演算子を prelude 定義へ移す

ユーザ定義の添字付き演算子が動いたら、`fec` の特殊規則を減らし、
数学演算子を prelude へ移す。

最初の対象:

- `grad`
- `div`
- `curl`

次の対象:

- `Δ`
- `lb`
- `dForm`
- `hodge`
- `codiff`

`epsilon`、`delta`、`g`、`gInv`、Hodge 因子などは、コンパイラプリミティブではなく
テンソル値または係数場として扱う。

成功条件:

- `fec` は定義と式を Egison へ運ぶだけになり、各数学演算子の意味を
  直接エンコードしない。
- 組み込み演算子を prelude 定義へ置き換えても、既存例の Formura 出力が変わらない。
- scalar intrinsic、テンソル縮約、微分で表せる数学演算子は、コンパイラ本体を
  編集せずに追加できる。

## 7. 一般計量・非ユークリッド対応は核が安定してから進める

上添字/下添字の区別は今すぐ保持するが、完全な非ユークリッド意味論は
核が安定してから進める。

後続作業:

- 計量テンソル `g_i_j`、逆計量 `g~i~j`
- 明示的な上げ下げ
- variance-aware な縮約
- 共変微分
- Christoffel 記号
- coordinate patch / overset grid のパッチ間変換

この順序にすると、最初のマイルストーンを小さく保ちつつ、将来の
非ユークリッド座標対応を塞がずに済む。

## 最初のマイルストーン

最初の具体的な目標は次のとおり。

```text
scalar intrinsic の自動 lift とユーザ定義 grad/div/curl を実装し、
elastic3d 系の既存生成 Formura コードを、現在のコンパイラ組み込み実装と
バイト一致させる。
```

このマイルストーンで、Formurae の核を次の形として実証する。

```text
lift 可能なスカラー関数 + テンソル縮約 + 座標/添字付き微分
```

それ以外の数学演算子は、できるだけユーザ定義または prelude 定義へ移していく。
