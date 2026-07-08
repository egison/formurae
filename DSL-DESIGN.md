# Formurae 設計メモ — Egison 流の添字記法・微分形式をもつステンシル DSL

**命名(2026-07-10 確定)**: 表層言語(.fe)の名前は **Formurae**(フォーミュレ)。
Formura のラテン語風複数形で *formulae*(数式)への掛詞 — 「数式のまま書く」という
本言語の主題が名前になっている。Formura 設計者・村主崇行氏への敬意を込めた継承でもある
(「Formura 2」は本体の現行バージョン 2.3.2 と紛れるため回避)。

**v1.8(2026-07-08): Unicode と基本演算子** — ギリシャ文字識別子(θ, φ, …
→ fec が ASCII へ字訳)・∂=d・δ=codiff・−=-・Δ=幾何のラプラシアン
(平坦 lap/計量 lb)。`∂_x (∂_x u)` は compact 2階差分に融合、スカラーへの
`δ (d u)` は −Δ へ降下 — いずれも生成 .fmr バイト一致で検証
(metric_torus=θφΔ・maxwell_dec=δ・ks3d=∂2回・hyperbolic=−δd)。
Egison 側の function symbol 改良(functionSymbol 構築子・quote 透過
substitute・mathFunctionName・ディスパッチ修正 = egison/design/
function-symbol-formurae.md)により **LBM の 38 defs が map 2行の族に**、
feq の let も復活(いずれも .fmr バイト一致)。`field f : family N` の
表層化が次の一手として解禁。

**v1.9(2026-07-08): ∇・λ・上添字** — `∇×`=curl・`∇·`(∇.)=divg・
`∇^2`/`∇²`=Δ(nablaPass; ∇ 後の空白許容)。λ→lambda の字訳に合わせ
生成側の係数名を la/lam → lambda に変更(3例の .fmr が改名分だけ変化、
全チェック green)。添字方程式で **上付き ~i と下付き _i を等価に**
(step 行で ~→_ 正規化; ユークリッド格子ゆえ変位は記法上の区別)、
Kronecker は `delta_ij`/`delta_i_j`(= `δ~i~j`・`delta~i_j`)の両形対応。
弾性波は `v'~i = v~i + (dt/ρ0) * ∂_j s~i~j`・`s'~i~j = … λ δ~i~j …` の
教科書形に。Maxwell は `∇ × B`、Burgers は `∇^2 u`(いずれもバイト一致)。

**v1.10(2026-07-08): 宣言必須化+テンソル初期化** — dimension/axes を必須に
(∂_j の意味=座標系を各ファイルで確定; 欠落・軸数不一致はエラー)。
ベクトル場 init `v = [| … |]` は staggered にも既対応、**対称テンソルは
`s = [| [| xx,xy,xz |], [| yy,yz |], [| zz |] |]`(上三角; 3×3 全成分なら
対称性検査)を新設**、init 行は括弧が閉じるまで複数行可。弾性波の添字は
混合変位 `s~i_j`/`δ~i_j` に(いずれも .fmr バイト一致)。

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
- 微分形式は本リポジトリの DEC 層が担う。当初は dF0/dF1/dF2/codF2 という独自名
  だったが、**Egison 本体の Yang–Mills サンプル(d・hodge・δ)と同じ構造・標準名に
  再構成済み**: 形式=(複体, 次数, 成分)の3つ組、`hodge` は単位立方格子で成分不変の
  複体スワップ、`dForm` が離散外微分、余微分は `codiff = (−1)^(n(k+1)+1) ⋆d⋆`
  (別名 `δ`; codF2 は撤去)。d∘d=0 を CAS が 0 に簡約することも確認済み。

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
3. ✅ v1: **.fe 表層構文+コンパイラ実装済(2026-07-10)**。まず Python
   (fec.py)でプロトタイプし、同日 **Haskell 版に置換**(レビュー指摘)。
   現在は cabal パッケージ `fec`(ルート fec.cabal、ソース fec/src/Main.hs、
   base のみ)で、`cabal build` / `cabal run -v0 fec --` で使う。
   置換時に全5例で両実装の .egi 出力バイト一致を確認してから fec.py を撤去。移行済 = maxwell3d・maxwell_dec・
   diffusion3d・kleingordon・ks3d の5例、**うち4例は .fe → .egi → .fmr が
   バイト一致**(ks は整形差のみ)、全例 make green。.egi は生成中間物になった
   (ヘッダに GENERATED 印、ギャラリーは .fe → .egi → .fmr の3段表示)。
   文法は fec.py 冒頭のコメント参照(dimension/axes/field/param/extern/raw/
   init:/step:/let/local/assert-dd-zero、`:=` = CAS init、`=` = raw init)。
   **init もベクトルで書ける**: `E = [| 0, gauss1(i*dx), 0 |]`(成分展開は fec)。
   **ベクトル方程式は添字なしで書ける**: `E' = E + dt * curl B` /
   `B' = B - dt * curl E'`(X' は更新済み配列への参照 = symplectic かつ袖幅1;
   fec が成分化して withSymbols [i] 形に変換)。dimension/axes は宣言可能
   (既定 3 / x,y,z; v1 は 3 次元のみ、CAS init は x,y,z 前提)。
4. ✅ v1.5/v1.6(2026-07-10): **計量サポート実装済** —
   `metric scale [h1, h2, h3]`(直接指定)と **`embedding [X1..Xm]`
   (座標系からの計量自動導出)**。軸名(`axes r, theta, phi` 等)は内部
   x,y,z に写像(生成物・yaml・ドライバは x,y,z のまま)。embedding では
   CAS が g_ab = ∂X/∂xₐ·∂X/∂x_b を計算(sin²+cos²=1 は自動簡約)、
   **直交性 g_ab=0 (a≠b) を記号検査してゲート**、h_a = √g_aa。quote
   (`` `(2+cos θ) ``)で因子を原子に保つと √ が閉じ、`expandAll` で
   quote を外してから半セル substitute(substitute は quote 非対応と判明;
   printer には quote ケースを追加)。宣言から hodge 因子 √g/hᵢ² の係数場
   (ca/cb/cc/sg)生成・半セル CAS 評価・保存流束・`lb`(Laplace–Beltrami)
   まで自動。トーラスを R⁴ 埋め込みから生成すると **hand-written スケール
   因子版と .fmr が extern sqrt 1行差で一致**。√ が閉じない埋め込みでも
   extern sqrt 経由で init が数値評価するので動く。球座標 hs=[1,r,r sinθ] は
   r=0・θ=0,π の座標特異点があるため、次例は円筒環状領域
   (embedding [r cos phi, r sin phi, zz]、r 壁は fork の boundary)推奨。
   残り = indexed family(`field f : family 19`)で LBM、ε_ijk とスカラー対象の
   添字和で yee/acoustic、ユーザ定義ヘルパ(def)で MHD。
6. ✅ v1.7(2026-07-10): **数式演算子と Einstein 添字記法** — レビュー指摘
   「dC2 のような関数でなく数式どおりに」を受け、.fe の微分は
   `d_x`/`d2_x`(軸名で書く;dC/dC2/dTaylor は .fe から撤去、lap4 追加)。
   `field v : vector @ staggered`・`field s : symmetric @ staggered` を宣言すると
   **テンソル添字方程式**が書ける:
   `v'_i = v_i + (dt/rho0) * d_j s_i_j` /
   `s'_i_j = s_i_j + dt * (la * delta_ij * d_k v'_k + mu * (d_i v'_j + d_j v'_i))`。
   繰り返し添字は「それを含む最小の項」で総和(Einstein;括弧は独立領域)、
   delta_ij は Kronecker、d_a は対象成分の配置にアンカーされた半セル差分
   (dYee)に落ち、対称成分は正準化(s_2_1 = s_1_2)。elastic3d.fe の生成
   .fmr は v0 テンソル版と**バイト一致**。
5. v2: 2D/1D、変数別境界条件、多段時間積分スキーム、Christoffel 一般計量
   (Egison 側の sqrt(完全平方多項式) 簡約が前提; チップ発行済)。
