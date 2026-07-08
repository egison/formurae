# Formurae 設計メモ — Egison 流の添字記法・微分形式をもつステンシル DSL

**命名(2026-07-10 確定)**: 表層言語(.fe)の名前は **Formurae**(フォーミュレ)。
Formura のラテン語風複数形で *formulae*(数式)への掛詞 — 「数式のまま書く」という
本言語の主題が名前になっている。Formura 設計者・村主崇行氏への敬意を込めた継承でもある
(「Formura 2」は本体の現行バージョン 2.3.2 と紛れるため回避)。

**v1.13(2026-07-09): 座標文脈つき `use` 宣言の導入** —
`extern` は Formura/C 側のスカラー関数、`use` は Formurae が座標文脈から
生成する数学演算子、という役割に分け始めた。第一段階として
`use exterior-calculus { Δ }` を実装し、`Δ` は暗黙 prelude ではなく
この宣言で追加される `def Δ u = 0 - δ (d u)` になった。
`Δ` を使っているのに `use` がない場合は `.fmr` 生成前にエラーにする。
既存の `Δ` 使用例には `use` を明示し、生成 .egi はバイト一致。
今後 `use vector-calculus { curl, divg }` や
`use exterior-calculus { d, δ }` へ広げ、`lib/fmrgen.egi` の座標固定定義を
モデルごとの座標文脈つき生成へ移す。

**v1.14(2026-07-09): `use vector-calculus` の第一段階** —
`curl`・`divg`・`dGrad` を `use vector-calculus` 側の演算子として扱い始めた。
`curl` は `use vector-calculus { curl }`、`divg` は
`use vector-calculus { divg }` なしでは `.fmr` 生成前にエラーにする。
`maxwell3d.fe` には `use vector-calculus { curl }` を明示し、生成 .egi は
バイト一致。現時点では定義本体はまだ `lib/fmrgen.egi` の `curl`/`divg` を使う。
次は `d`/`δ` の use 化、または `lib/fmrgen.egi` の座標文脈つき定義生成へ進む。

**v1.15(2026-07-09): `use exterior-calculus { d, δ }` の第一段階** —
ユーザが直接書いた `d`・`δ`・`codiff`・`dForm` を `use exterior-calculus`
必須にした。`maxwell_dec.fe` と `hyperbolic.fe` に `use exterior-calculus { d, δ }`
を明示し、生成 .egi はバイト一致。`Δ` の内部定義 `δ (d u)` は
`use exterior-calculus { Δ }` の依存として扱い、`Δ` 単独 use は引き続き動く。
定義本体はまだ `lib/fmrgen.egi` の `dForm`/`codiff` を使う。

**v1.16(2026-07-09): 生成 `.egi` への座標文脈定義** —
`use` または計量宣言を持つモデルの生成 `.egi` に
`feDim`・`feAxes`・`feCoords`・`feHsteps` を出すようにした。
`embedding` から計量を導出する `feGd`/`feGo` は `[x, y, z]` の直書きではなく
`feCoords_a` を参照し、計量係数場の半セル評価も `feCoords_a`/`feHsteps_a`
を使う。これはまだ `lib/fmrgen.egi` の `coords`/`hsteps` 本体置換ではないが、
座標文脈つきライブラリ生成へ進むための足場になる。生成 `.fmr` は全 `.fe` 例で
バイト一致。

**v1.8(2026-07-08): Unicode と基本演算子** — ギリシャ文字識別子(θ, φ, …
→ fec が ASCII へ字訳)・∂=d・δ=codiff・−=-・Δ=幾何のラプラシアン
(平坦 lap/計量 lb)。`∂x (∂x u)` は compact 2階差分に融合、スカラーへの
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

**v1.12c(2026-07-08): 本体定義の調査と整合** — Egison 本体の定義を調査:
`div` = trace(Jacobian)(lib/math/algebra/vector.egi: `trace (!∂/∂ A xs)`)・
`rot` = `crossProductWithFun ∂/∂ A xs`(∇× をクロス積として)・`∇` = 勾配の
**関数**(derivative.egi)。**本体 rot は符号が慣例と逆(A×∇=−∇×A)と実測で
確認 → チップ発行(task_4109e663)**。formurae 側: `divg` を本体 div と同じ
**trace (dGrad X)** に再定義(バイト同値)、curl は ε 縮約のまま(これも
Egison 流; crossProductWithFun 形は将来の選択肢)。表層の主綴りは
**関数形 curl/divg/Δ/Δ4**(∇×・∇·・∇²・lap・lap4 は sub 別名として受理)—
∇ × は関数に見えないという指摘によりギャラリー・例は主綴りで統一
(maxwell=curl・burgers=Δ)。lap4 の禁止は撤回し Δ4 への別名に。

**v1.12b(2026-07-08): lap4 全廃** — fmrgen の関数名ごと `Δ4` に改名
(Egison は Unicode 識別子可)。fec の特別規則も消え Δ4 は素通しで
ライブラリ関数に直結、表層 `lap4` は「lap4 is spelled Δ4」エラー。

**v1.12(2026-07-08): ユーザ定義演算子+Δ のプレリュード化** —
`def NAME ARG = EXPR`(ファイルスコープ・使用箇所でテキスト β 展開・
本文は先行定義のみ参照可=前方参照/再帰はエラー・引数は先に展開)。
**Δ はコンパイラ魔法から `def Δ u = 0 - δ (d u)` のプレリュード定義に格下げ**
(δ∘d 降下が平坦/計量を吸収するので分岐ごと言語内へ; 再定義可能)。
**Δ4 を主名に**(lap4 は別名)し、本体を fec 内のインラインλから
lib/fmrgen.egi の正規の関数 `lap4` に移設。局所場への Δ(CH の Δ μ)は
compound fallback(lap (…))で通る。fec に残る「魔法」= fuseDD・
lowerDeltaD(中核の降下)・nablaPass(グリフ別名)・計量の係数場機構
(エミッタ固有; lbExpansion の言語内化は将来課題)。全対象例 .fmr バイト一致。

**v1.11(2026-07-08): 記法の掃除** — 融合形 `delta_ij` と演算子 `d2_a` を
**言語から削除**(パース時に明確なエラー; d2 は fuseDD の内部表現としてのみ
存続)。Kronecker は 1添字1マーク(`δ~i_j`)のみ。usage の演算子表は
別名を演算子欄に併記する形へ再構成(「〜とも書ける」廃止)。
lap4 の基本演算子分解 = Richardson 外挿 (4·Δ_h − Δ_{2h})/3 と等価
(±1: 4/3・±2: −1/12・0: −5/2 で厳密一致)であり、不足しているのは
幅 2h の差分を表す表層演算子(stride つき ∂/Δ)— 導入すれば lap4 は
廃止可能、と記録。

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
5. ✅ v1.7(2026-07-10): **数式演算子と Einstein 添字記法** — レビュー指摘
   「dC2 のような関数でなく数式どおりに」を受け、.fe の座標軸微分は
   `∂x` 形式だけを許す(dC/dC2/dTaylor は .fe から撤去、lap4 追加)。
   `field v : vector @ staggered`・`field s : symmetric @ staggered` を宣言すると
   **テンソル添字方程式**が書ける:
   `v'~i = v~i + (dt/rho0) * ∂_j s~i_j` /
   `s'~i_j = s~i_j + dt * (la * δ~i_j * ∂_k v'~k + mu * (∂_i v'~j + ∂_j v'~i))`。
   繰り返し添字は「それを含む最小の項」で総和(Einstein;括弧は独立領域)、
   δ~i_j は Kronecker、∂_a は対象成分の配置にアンカーされた半セル差分
   (dYee)に落ち、対称成分は正準化(s_2_1 = s_1_2)。elastic3d.fe の生成
   .fmr は v0 テンソル版と**バイト一致**。
6. v2: 2D/1D、変数別境界条件、多段時間積分スキーム、Christoffel 一般計量
   (Egison 側の sqrt(完全平方多項式) 簡約が前提; チップ発行済)。

## 6. 次の開発目標: Egison の強みを表層仕様へ開放する

現仕様は、Egison のテンソル添字記法・微分形式・CAS を **実装内部の意味論**
として活用している。一方で、Formurae ユーザが任意のスカラー関数や
テンソル関数に対して添字付き演算子を自由に定義する力は、まだ表層仕様としては
限定的にしか露出していない。次の目標は、固定演算子(`curl`・`divg`・`dForm`・
`codiff`・`lb`)を増やす方向ではなく、Egison ならではの「添字を扱う演算子を
ユーザが簡潔に定義できる」性質を `.fe` へ持ち上げること。

1. **ユーザ定義テンソル演算子の表層化**
   - `def curl X~i = epsilon~i~j~k . ∂_j X_k`
   - `def div X = ∂_i X~i`
   - `def grad u_i = ∂_i u`
   - `def stress_i_j v = ...`

   のように、添字を持つ引数・返り値・演算子本体を `.fe` 側で定義できるようにする。
   ここでは `~i` を上添字、`_i` を下添字として区別する。現行 v1.7 はユークリッド格子を
   前提に上付き/下付き添字を等価に正規化しているが、非ユークリッド座標・一般計量へ
   進む開発目標では、反変/共変成分、計量による上げ下げ、接続係数の扱いを表層仕様に
   残す必要がある。
   現行の `def NAME ARG = EXPR` は一引数のテキスト的β展開に近いので、これを
   Egison の添字付き関数定義へ接続する。

2. **スカラー関数のテンソルへの自動 lift とテンソル関数の区別**
   Egison の型は Scalar/Tensor の区別を中心にし、テンソルの階数までは型で
   管理しない。この方針に合わせ、Formurae でも演算子定義の基礎は
   「スカラー関数か、添字を受け取るテンソル関数か」の区別に置く。
   さらに Egison と同じく、スカラー関数がテンソルに適用された場合は
   成分ごとに自動 lift/map する。したがって `+`・`*`・`sin`・`cos`・`exp`
   などは同じ種類のスカラー関数として扱い、テンソル引数を受け取ったときは
   各成分へ作用する。例えば `exp u_i` は各 `u_i` への `exp`、`a * X_i` は
   各成分へのスカラー係数倍、`X_i * Y_i` は同じ添字構造を持つ成分同士の
   点ごとの積として読む。

   一方、テンソル積・添字縮約を伴う積は `.`/`contractWith` で書く。
   例えば `epsilon~i~j~k . ∂_j X_k` のように、異なる添字構造を結合して
   自由添字と縮約添字を決める操作はテンソル演算として扱う。
   `vector`・`symmetric`・`k-form` などは Egison の型そのものではなく、
   Formurae 側で成分展開・格子配置・出力名を決めるための場の kind として扱う。
   長期的には λ⊗ 型システムに接続し、階数を型で固定するのではなく、
   スカラー/テンソル関数の使い分けと添字整合性を生成前に検査する。

3. **`fec` の特殊規則を減らし、演算子を通常定義へ寄せる**
   現在 `curl`・`delta`・`lb`・`d_i` などは `fec` と Egison ライブラリにまたがる
   特別扱いを持つ。`Δ` を `use exterior-calculus { Δ }` で追加される通常定義へ
   移した方針を進め、`curl`・`divg`・`grad`・高階差分なども、可能な限り
   座標文脈つき `use` 定義または `.fe`/Egison 側の通常の演算子定義として表現する。
   `fec` は「定義を解釈する」のではなく「表層定義を Egison 埋め込み形へ運ぶ」
   薄い層に保つ。

   目標となる意味論の核は、かなり小さくできるはず:
   - scalar intrinsics: `+`、`-`、`*`、`/`、`sin`、`cos`、`exp` など、
     Formura が出力でき、テンソル引数には成分ごとに lift されるスカラー関数
   - `contractWith`: テンソル同士の積と添字縮約(Egison の `.` に対応)
   - `∂symbol`: 座標軸 `symbol` に沿う偏微分/差分生成子(`∂x`, `∂theta` など)

   `d_symbol` のような綴りは `_` が下添字と衝突し、`∂_i`(添字付き微分演算子)と
   `∂x`(座標軸 x の微分)の区別も読みにくい。非ユークリッド座標・一般計量へ進むなら、
   軸名に対する微分は `∂x` のように演算子名として書き、添字を持つ微分は別途
   `∂_i`/`∂~i` などとして扱う方が安全。表層仕様では、座標軸微分については
   `∂x` 形式だけを許す。

   その上で、`grad`・`div`・`curl`・`dForm`・`hodge`・`codiff`・`Δ`・`lb` は
   組み込みではなく `use` で座標文脈から生成される定義へ落とす。
   `epsilon`・`delta`・`g`・`gInv`・Hodge 因子などは、
   演算子プリミティブではなくテンソル値/係数場として扱う。
   これにより、Formurae の言語核は「lift 可能なスカラー関数・テンソル縮約・
   座標微分」だけになり、数学演算子の多様性は Egison 側のユーザ定義で表せる。

4. **微分形式演算子をユーザ拡張可能にする**
   現在の `dForm`・`hodge`・`codiff` は固定ライブラリとして強力だが、複体・次数・
   配置規則をユーザが拡張する道はない。将来的には、格子配置・Hodge 因子・符号規約・
   pullback/pushforward などを組み合わせて、幾何や離散化に応じた微分形式演算子を
   ユーザが定義できるようにする。陰陽格子/overset grid のようなマルチパッチ幾何では、
   この拡張性が基底変換やパッチ間写像の記述にも効く。

この方向では、Formurae の新規性は「固定された便利演算子を持つステンシル表層言語」
から、「Egison の任意スカラー関数・テンソル関数への添字記法を、分散ステンシル
コード生成へ接続する言語」へ進む。
