# DSL 設計メモ — Egison 流の添字記法・微分形式をもつステンシル DSL

2026-07-10 起草。動機はレビュー指摘:
「現在の .egi は書きにくい。Maxwell の Ex, Ey, Ez は E というベクトルにすべき。
Egison 流の添字記法と微分形式の記法をもつ、Formura のような DSL を新しく作るべき」。

## 1. 現状の痛点(19 例を書いて判明したもの)

1. **成分ごとの場宣言**: `def Ex := function (x, y, z)` × 6〜9 本(LBM は 38 本)。
   `function` が定義変数名を捕捉する仕様のため、名前をプログラムで作れなかった。
2. **ベクトル場が第一級でない**: スカラー成分を定義してから `[| Ex, Ey, Ez |]` に詰め直す。
3. **.fmr の雛形を文字列で手書き**: `dimension ::`・`double ::`・`begin function (…) = step(…)`
   の出力タプルと fmrEq 行の同期を人間が保つ(実際に名前不一致バグを何度か踏んだ)。
4. **init が生の Formura 文字列**(metric の fmrInit 経由を除く)。
5. **演算子の空白必須**(`mx*mx/rho` は1識別子)という Egison 表層文法の罠。

## 2. 発見: 部品は Egison に既にあった

`sample/math/geometry/`(リーマン幾何ノート)が示すとおり、

- **添字つき関数族**: `def E_i := generateTensor (\[i] -> function (x, y, z)) [3]`
  で E_1, E_2, E_3 が独立な抽象関数シンボルになる(LHS 添字が定義文脈に入り、
  generateTensor が添字を埋める設計。`g[_i_j]` 形式も可)。
- 計量 → `M.inverse`・`∂/∂`・Christoffel 記号 Γ の記号計算は全部サンプル済み
  (しかも T2 の例はまさに本リポジトリのトーラス)。
- 微分形式は本リポジトリの DEC 層(σ0..σ3, dF0/dF1/dF2, codF2)が既にあり、
  d∘d=0 を CAS が 0 に簡約することも確認済み。

## 3. v0(実装済み): 埋め込み DSL

- `lib/fmrgen.egi` — `fmrFieldName`: 成分シンボル E_1 → Ex、s_1_2 → sxy を
  プリンタで変換(添字なし名は素通し)。
- `lib/fmrdsl.egi` — `emitModel params helpers fields inits steps`:
  preamble・`double ::` 宣言・init()/step() の雛形・**出力タプルを場宣言から自動生成**。
  `vecEqs`/`scalarEq` が fmrEq 行を組む。
- 実証: `examples/maxwell3d` を全面書換 — 場宣言 2 行+添字方程式 2 行:

```egison
def E_i := generateTensor (\[i] -> function (x, y, z)) [3]
def B_i := generateTensor (\[i] -> function (x, y, z)) [3]
def En_i := withSymbols [i] E_i + dt * (curl B_#)_i
def Bn_i := withSymbols [i] B_i - dt * (curl En_#)_i
```

  生成 .fmr は旧成分手書き版と**バイト一致**(意味保存の証明)。

## 4. v1(次): スタンドアロン表層構文

ファイル例(仮拡張子 .fe;名称候補は要相談):

```
dim 3
param dt = 0.5 * dx

field E : 1-form
field B : 2-form

init:
  E = [ 0, gauss1(x), 0 ]
  B = [ 0, 0, gauss1(x + dx/2) ]

step:
  E' = E + dt * (*d*) B
  B' = B - dt * d E'
```

添字記法の例(弾性波):

```
field v     : vector
field sigma : symmetric matrix    -- 配置は添字から導出(Virieux)

step:
  v'_i      = v_i + (dt/rho) * d_j sigma_i_j
  sigma'_ij = sigma_ij + dt * (la * delta_ij * d_k v'_k
                               + mu * (d_i v'_j + d_j v'_i))
```

曲面(直交計量)の例:

```
metric scale [1, 2 + cos x, 1]     -- Lamé 因子; sqrt(g), g^ii は導出
field u : scalar
step:
  u' = u + dt * laplace_beltrami u
```

### アーキテクチャ

```
.fe(表層構文)
  → パーサ(薄い変換層)
  → v0 の埋め込み形(Egison 式)      ← 意味論はここに一本化
  → Egison CAS が添字・微分形式・計量を展開
  → .fmr プリンタ
  → Formura(fork)→ MPI + temporal blocking つき C
```

- **意味論は Egison ライブラリ(fmrgen/fmrdsl)に置いたまま**、パーサは
  「表層 → 埋め込み形」の機械的変換のみを行う。バイト一致テストを意味の
  アンカーとして維持する。
- パーサ実装は2案: (a) Egison の文字列パターンマッチ(ドッグフーディング、
  ただし式文法+優先順位は重い)、(b) Haskell(megaparsec; Formura fork と
  同じスタックで CI も共通化)。**推奨は (b)**。生成物は中間 .egi でよい
  (デバッグ可視性が高い)。

### v1 スコープの決め事(提案)

- 次元は 3 固定(Formura の現行対応に合わせる)、場の種類 = scalar / vector /
  k-form / symmetric matrix / indexed family(LBM 用 `field f : family 19`)。
- 微分演算子: `d`, `(*d*)`, `grad/div/curl`(collocated), `d_i`(添字)、
  `laplace_beltrami`(metric scale 宣言があるとき)。
- init は式(CAS 経由で .fmr へ; 現行 fmrInit の一般化)。`where` でヘルパ。
- yaml(格子・分割・boundary・reduces)は Formura のまま。

## 5. ロードマップ

1. ✅ v0: fmrdsl + 添字つき関数族 + 成分名変換(maxwell3d で実証、バイト一致)
2. ✅ v0.5: elastic(対称テンソルビュー+添字導出スタガー)・maxwell_dec・
   metric_torus・kleingordon・diffusion3d を v0 様式へ移行(3例バイト一致)。
3. ✅ v1: **.fe 表層構文+コンパイラ tools/fec.py 実装済(2026-07-10)**。
   パーサは Haskell でなく**依存ゼロの Python** に決定(意味論は Egison 側に
   一本化した薄い変換層なので十分)。移行済 = maxwell3d・maxwell_dec・
   diffusion3d・kleingordon・ks3d の5例、**うち4例は .fe → .egi → .fmr が
   バイト一致**(ks は整形差のみ)、全例 make green。.egi は生成中間物になった
   (ヘッダに GENERATED 印、ギャラリーは .fe → .egi → .fmr の3段表示)。
   文法は fec.py 冒頭のコメント参照(dimension/axes/field/param/extern/raw/
   init:/step:/let/local/assert-dd-zero、`:=` = CAS init、`=` = raw init)。
   **ベクトル方程式は添字なしで書ける**: `E' = E + dt * curl B` /
   `B' = B - dt * curl E'`(X' は更新済み配列への参照 = symplectic かつ袖幅1;
   fec が成分化して withSymbols [i] 形に変換)。dimension/axes は宣言可能
   (既定 3 / x,y,z; v1 は 3 次元のみ、CAS init は x,y,z 前提)。
4. v1.5: staggered 宣言(`field v : vector @ edge` 等)と計量宣言
   (`metric scale [...]`)の表層化 → elastic/metric/acoustic/yee も .fe に。
   indexed family(`field f : family 19`)で LBM の 38 宣言を1行に。
5. v2: 2D/1D、変数別境界条件、多段時間積分スキーム、Christoffel 一般計量
   (Egison 側の sqrt(完全平方多項式) 簡約が前提; チップ発行済)。
