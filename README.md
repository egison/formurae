# Formurae

Egison のテンソル添字記法で書いた偏微分方程式から、
[Formura](https://github.com/formura/formura)(村主崇行氏らによるステンシル計算 DSL)のソースを生成し、
MPI + temporal blocking つきの高速な C コードに落とすための実験リポジトリ。

表層言語は **Formurae**(フォーミュレ、拡張子 `.fe`)と名づけた。Formura のラテン語風複数形で、
*formulae*(数式)への掛詞 — 数式(formulae)をそのまま書けば Formura が走る。
Formura を設計した村主崇行氏への敬意を込め、氏の言語の名前を継いでいる。

```
.fe      : Formurae — 表層言語(field 宣言+添字記法・微分形式・計量の方程式) ← 22例
   ↓        fec(薄い変換層、Haskell; cabal build)
Egison   : 生成 .egi(座標文脈・差分化コンビネータ・DEC・.fmr プリンタを含む)
   ↓        Egison CAS + mathValue マッチャ
Formura  : .fmr → C ライブラリ(MPI 通信・temporal blocking を自動生成)
   ↓
C コンパイラ + ドライバ → 実行
```

Formurae の Maxwell(全28行のうち物理部分)— 方程式は**添字も成分もないベクトル方程式**:

```
dimension 3
axes x, y, z
use vector-calculus { curl }

field E : vector
field B : vector

init:
  E = [| 0, gauss1(i*dx), 0 |]
  B = [| 0, 0, gauss1(i*dx) |]

step:
  E' = E + dt * curl B
  B' = B - dt * curl E'    -- E' は更新済み配列への参照(symplectic・袖幅1)
```

微分形式版(maxwell_dec.fe)なら:

```
use exterior-calculus { d, δ }

field E : 1-form
field B : 2-form

step:
  E' = E + dt * delta B    -- δ = ⋆d⋆(余微分)
  B' = B - dt * d E'

assert-dd-zero E'      -- d∘d=0 を CAS が確認しない限り生成しない
```

Unicode でもそのまま書ける(fec が Formura 向けに ASCII へ字訳する)。
トーラス上の熱方程式の幾何・使う演算子・物理は4行:

```
axes θ, φ, z
embedding [ `(2 + cos θ) * cos φ, `(2 + cos θ) * sin φ, sin θ, z ]
def Δ u = lb u

u' = u + dt * Δ u
```

`Δ` は組み込みではなく、この例では `def Δ u = lb u` として定義している。
生成 `.fmr` でも `axes :: theta,phi,z` となり、格子幅や C ドライバの名前も
`dtheta`、`dphi`、`space_interval_theta` のように宣言した軸名に追随する。
基本演算子だけでも書ける: `∂x u` は1階中心差分、`∂ 2 1 x u` は2階中心差分、
`∂ 2 2 x u` は半径2の5点 stencil で導出される2階差分になる。
平坦格子の Laplacian は、例えば `def Δ u = ∂ 2 1 x u + ∂ 2 1 y u + ∂ 2 1 z u` と書く。

`dimension` は 1、2、3 を指定できる。スカラー、ベクトル、添字付き rank-1、
対称/反対称/full rank-2 field、微分形式 `k-form` は宣言次元に応じた成分数で
Formura storage へ展開される。形式の storage 名は昇順の軸組で
`B_1_2`、`B_1_3`、`B_2_3` のように決まる。`curl` と `epsilon~i~j~k` は
3D 専用として検査する。

Maxwell 方程式の場合、Egison 側の物理記述はこれだけ:

```egison
def E_i := generateTensor (\[i] -> function (x, y, z)) [3]   -- E はベクトル場(1行)
def B_i := generateTensor (\[i] -> function (x, y, z)) [3]

def En_i := withSymbols [i] E_i + dt * (curl B_#)_i          -- E' = E + dt curl B
def Bn_i := withSymbols [i] B_i - dt * (curl En_#)_i         -- B' = B - dt curl E'
```

`curl` は `use vector-calculus { curl }` で有効化する。生成 `.egi` の先頭には、
現在の `dimension`/`axes` から作った座標文脈つき定義が出る
(Levi-Civita テンソルとの Einstein 縮約):

```egison
def curl (X: Vector MathValue) : Vector MathValue :=
  withSymbols [i, j, k] (ε 3)~i~j~k . (dGrad X)_j_k
```

ここから6本の更新式が全自動で展開される(生成物の1本):

```
E_2' = E_2[i,j,k] + B_3[i-1,j,k]*dt/(2*dx) + (-1)*B_3[i+1,j,k]*dt/(2*dx)
     + (-1)*B_1[i,j,k-1]*dt/(2*dz) + B_1[i,j,k+1]*dt/(2*dz)
```

## クイックスタート

前提: GHC 9.6 系 + stack(Formura 用)、`../egison` に Egison 開発ツリー
(インストール済みの egison バイナリは同梱数学ライブラリが古いため不可)。
MPI は不要(1ランク用スタブ `mpistub/mpi.h` を同梱。実 MPI があればそちらでも可)。

```sh
make setup        # Formura 2.3.2 を clone + GHC 9.6 パッチ適用 + ビルド → bin/formura
cabal build       # Formurae コンパイラ fec をビルド(base のみ; make が cabal run 経由で使う)
make diffusion3d  # .fe → fec → Egison → Formura → cc → 実行(質量保存を検査)
make maxwell3d    # 同上(エネルギー保存・伝播を検査)
```

## リポジトリ構成

| パス | 内容 |
|---|---|
| `fec/` + `fec.cabal` | **Formurae コンパイラ**: 表層言語 Formurae(.fe;`field E : vector`・`E' = E + dt * curl B`・`B' = B - dt * d E'`)を埋め込み形 .egi に変換。Haskell(base のみ)、リポジトリ直下で `cabal build` / `cabal run -v0 fec -- model.fe`。意味論は Egison 側に一本化した薄い変換層 |
| `lib/fmrgen.egi` | 生成コア: Taylor 条件から係数を導出する **`taylorStencil`**、quote cleanup、形式補助などの座標非依存基盤 |
| `lib/fmrlegacy3d.egi` | まだ `.fe` 化していない手書き `.egi` 例のための 3D 互換文脈。`.fe` 由来の生成物では使わない |
| `examples/diffusion1d/` | 1D 拡散方程式。`def Δ u = ∂ 2 1 x u` と書き、check driver が質量保存とピーク減衰を検査 |
| `examples/diffusion2d/` | 2D 拡散方程式。`dimension 2` と `axes x, y` に応じて Formura/C の配列・Navi・Laplacian が2次元化される |
| `examples/divergence2d/` | 2D 発散演算子の smoke test。`use vector-calculus { divg }` で生成される `dGrad`/`divg` が `dimension 2` 文脈で動くことを、中心差分の離散記号と比較して検査 |
| `examples/diffusion3d/` | 3D 拡散方程式(`def Δ u = ∂ 2 1 x u + ∂ 2 1 y u + ∂ 2 1 z u` で Laplacian を定義し、物理は `u' = u + dt * κ * Δ u` の1行) |
| `examples/maxwell3d/` | Maxwell 方程式(**E・B がベクトル場**。`use vector-calculus { curl }` で回転を有効化し、全ベクトル更新2本から ε 縮約 curl の collocated 格子コードを生成) |
| `examples/maxwell3d_yee/` | **Yee-FDTD**(E=辺・B=面のスタガード格子+leapfrog。場ごとの配置オフセット宣言から教科書どおりの FDTD を生成) |
| `examples/maxwell_dec/` | **Maxwell(微分形式/DEC)**(`use exterior-calculus { d, δ }` で外微分・余微分を有効化。E=1-form・B=2-form の**次数宣言だけ**で Yee 配置を導出。B の storage は `B_1_2,B_1_3,B_2_3` の幾何基底名。d∘d=0 を CAS が生成時に検査し、check driver がエネルギー・伝播・divB を検証) |
| `examples/pearson3d/` | **Formura 論文の看板シミュレーション再現**(菌根菌 mycorrhiza の Pearson 反応拡散系。FHPC'16 と同じ方程式・パラメタ。自己複製スポットパターンが創発) |
| `examples/burgers3d/` | **Burgers 方程式**(Cole–Hopf 厳密解と直接比較 — 非線形項生成の機械検証) |
| `examples/cahnhilliard3d/` | **Cahn–Hilliard**(4階微分を中間場 μ の2段構成で。質量は `reduces` 経由で監視) |
| `examples/tdgl3d/` | **TDGL 超伝導**(\|ψ\|⁴ 理論。量子化渦の自発形成) |
| `examples/mhd_ot/` | **理想 MHD: Orszag–Tang 渦**(保存形+Rusanov 流束を中間流束場19本で生成。8保存量を `reduces` で監視) |
| `examples/elastic3d/` | **弾性波(Virieux)**(.fe の **Einstein 添字記法2行**: `field v~i @ staggered`、`field σ{~i~j} @ staggered` と宣言し、`v'~i = v~i + (dt/ρ0) * ∂_j σ~i~j`、`σ'~i~j = … λ * δ~i~j … δ~i~k * ∂_k v'~j …` と書く。繰り返し添字は上1・下1だけを総和し、上げ下げは metric を明示する。`@ staggered` 宣言で ∂_a が対象配置アンカーの半セル差分に = Virieux 格子を導出。P/S 両波速を1回で実測) |
| `examples/metric_torus/` | **計量つき拡散(トーラス上の Laplace–Beltrami)**(.fe の `embedding [...]`(座標系の埋め込み)だけから CAS が計量 g_ab=∂X·∂X を導出・**直交性を記号検査**・h_a=√g_aa → hodge 因子の係数場・半セル評価・保存流束まで自動。`def Δ u = lb u` と定義し、物理は `u' = u + dt * Δ u` の1行。`metric scale` 直接指定も可) |
| `examples/kleingordon/` | **非線形 Klein–Gordon(φ⁴ キンク)**(leapfrog 2場。ブーストした kink–antikink 対で速度と相対論的エネルギーを実測) |
| `examples/shallowwater/` | **浅水方程式**(保存形+人工粘性。重力波速 √(gh) を実測、質量は流束形式で厳密保存) |
| `examples/lbm_d3q19/` | **格子ボルツマン D3Q19**(19方向の衝突・ストリーミング・平衡分布 init を全部 Egison の map で生成。BGK 粘性を解析値と照合) |
| `examples/acoustic3d/` | **線形音響(p–v スタガード)**(Virieux のスカラー縮約。インピーダンス整合パルスで音速を実測) |
| `examples/euler_sod/` | **圧縮性 Euler: Sod 衝撃管**(保存形+LF 粘性。周期格子用の二重ダイアフラム構成で厳密 Riemann 解と L1 比較) |
| `examples/ks3d/` | **Kuramoto–Sivashinsky(時空カオス)**(4階微分は中間場 w=∂²u の2段構成。参照実装との一致とアトラクタ統計で検証) |
| `examples/highorder4/` | **4次精度スキーム自動導出**(係数はソースに書かず `taylorStencil` が導出。離散シンボルと機械精度一致+h⁴ 残差則を検証) |
| `examples/dirichlet_diffusion/` | **Dirichlet 壁の拡散**(fork の `boundary: [fixed 0.0, …]` を使う最初の例。壁つき離散固有モードの厳密減衰 (1+λdt)ⁿ を機械精度で再現) |
| `examples/polar2d/` | **極座標の円環(平坦)**(embedding から教科書の極座標 Laplacian を導出 — 曲率 0 でも座標は曲がっている対照例。参照 5.6e-16・保存 1.1e-15) |
| `examples/spherical3d/` | **球座標の球殻(3D)**(全3軸非自明: g=diag(1,(1+r)²,(1+r)²sin²θ) を embedding から導出、r・θ の2軸 mirror 壁。3D 参照実装と 4.4e-16・保存 4.2e-15) |
| `examples/metric_sphere/` | **球面の帯(正曲率)**(.fe の `embedding` から g=diag(1, sin²θ) を CAS 導出、θ 壁は mirror。参照実装と 5.6e-16・Σ√g·u 保存 3.6e-15) |
| `examples/hyperbolic/` | **双曲平面 Poincaré 半平面(負曲率 −1)**(ℝ³ 埋め込み不可なので `metric scale [1/(1+y), 1/(1+y), 1]` 直接指定。参照実装と 6.7e-16・保存 9.8e-16) |
| `formura-patch/` | Formura 2.3.2 → GHC 9.6.7 移植パッチ(6ファイル) |
| `mpistub/mpi.h` | 1ランク実行用 MPI スタブ(自己メッセージを FIFO マッチング) |
| `setup.sh` / `Makefile` | ビルドとエンドツーエンド実行の自動化 |
| `figures/` | 論文図版のデータ生成(`gen.sh` → `out/*.dat`: Yee パルス断面・エネルギー時系列4種) |
| `gallery/` | **全応用例の可視化ギャラリー**(`gen.sh` → `tools/render.py` → `index.html`。外部ライブラリ不要 — PNG/SVG を標準ライブラリだけで生成。ブラウザで `gallery/index.html` を開く。各カードの Egison/Formura 全文は `tools/embed_src.py` が再埋め込み) |
| `gallery/usage.html` | **使い方ガイド**(セットアップ → チュートリアル → .fe/yaml リファレンス → 検証ドライバの書き方 → 3層構造の考え方。ブラウザで開く) |
| `gallery/dsl/` | **Formurae ギャラリー**(**.fe 22例**。各カードは .fe → 中間 .egi → 生成 .fmr の3段表示。移行は .fmr 比較(バイト一致 or 整形差のみ)+全チェックで検証) |
| [`DSL-DESIGN.md`](DSL-DESIGN.md) | **Formurae 設計メモ**(痛点 → v0 埋め込み層 → v1 表層構文のロードマップと実装記録、命名の経緯) |
| [`APPLICATIONS.md`](APPLICATIONS.md) | 応用カタログ(16 テーマ: MHD・弾性波・LBM・Cahn–Hilliard 等、検証方法つき) |
| [`UPSTREAM.md`](UPSTREAM.md) | Formura 本体への拡張計画(GHC 移植 PR・TB バグ修正・境界条件・大域リダクション) |
| [`DEVELOPMENT.md`](DEVELOPMENT.md) | 開発ノート(修正済みバグの事後解説) |

各 example の `*.fmr` は生成物だが、出力例として追跡対象にしている(`make` で再生成される)。

## 仕組みの要点

- **場の表現**: `def u := function (x, y, z)`(抽象関数)。格子参照は
  `substitute [(x, x + hx)] u` が生む未解釈適用 `u (x + hx) y z` として現れる。
- **プリンタ**: `fec` が各 `.egi` に生成する。正規化された数式を `mathValue` マッチャ(`poly`/`term`/`func`/`symbol`)で分解し、
  適用引数から `(引数 − 座標)/h` でオフセットを有理数として逆算して `u[i+1,j,k]` に写す。
  半整数オフセット(`1/2`)も扱える。
- **スタガード格子**: 場を「(抽象関数, 配置オフセット σ∈{0,½}³)」の組で表し、参照時に
  「変位 + 対象の σ − 参照場の σ」で配列オフセットを解決する(`yeeRef`/`dYee`/`curlYee`)。
  Yee 配置なら curl の全項が整数オフセット(袖幅1)に落ちる。
- **座標文脈つき `use`**: `use` または計量宣言を持つモデルでは、生成 `.egi` に
  `feDim`・`feAxes`・`feAxisIds`・`feCoords`・`feHsteps` と、その文脈を参照する
  `shift`/`dC`/`dC2`/`dTaylor` と表向きの `∂ order radius axis expr`、
  必要に応じて `curl`/`divg` や `dForm`/`codiff`、さらに `.fmr` プリンタを出す。
  `extern` は Formura/C 側のスカラー関数、`use` は Formurae が生成する数学演算子として分けている。
- **離散微分形式(DEC)**: 形式は「(複体, 次数, 成分)」の3つ組で、**格子配置は複体と次数だけ
  から決まる**。`dimension n` の `k-form` は昇順の k 個の軸組
  (2D なら `B_1_2`、3D なら `B_1_2,B_1_3,B_2_3`)を成分に持ち、primal k-cell と
  dual (n-k)-cell の補複体を `hodge` が対応させる。演算は Egison 本体の連続版サンプル
  (`sample/math/geometry/yang-mills-…`: d・hodge・δ)と**同じ構造・同じ名前**:
  `dForm`(離散外微分 = k-form → (k+1)-form)、`hodge`(補基底への符号つき複体スワップ)、
  そして余微分 `codiff`(別名 `δ`)は教科書どおりの合成
  **δ = (−1)^{n(k+1)+1} ⋆d⋆** で定義する。
  **d∘d=0 は CAS が文字どおり 0 に簡約**することで成立が確認でき、これが生成された
  Yee スキームの div B 厳密保存の構造的理由になる。
- **テンソル**: `Vector MathValue` 等の型注釈でテンソルごと受け取り(λ⊗ のスカラー/テンソルパラメタ)、
  `ε`・`generateTensor`・添字縮約は Egison 標準ライブラリをそのまま使う。
  添字つき field は `field v~i @ staggered` や `field σ{~i~j} @ staggered` のように宣言し、
  rank・上下・対称性・Formura 出力 layout は添字仕様から推論する。
  初期値も `v~i = [| ... |]~i` や `σ~i~j = [| ... |]~i~j` のように同じ添字を明示する。
  記号式で初期化したい場合は `σ~i~j := δ~i~j * exp(x)` のような indexed CAS initializer も使える。
  反対称 rank-2 field は `field A[_i_j] @ staggered` と宣言し、storage は独立な
  上三角 off-diagonal 成分だけを持つ(2D なら1成分、3D なら3成分)。参照時には
  `A_j_i = -A_i_j`、`A_i_i = 0` に正準化する。
  上付き `~i` と下付き `_i` は strict に区別し、`metric g` で宣言した計量名は
  `g~i~j`/`g~i_j`/`g_i~j`/`g_i_j` の上下パターンごとに生成 `.egi` の
  内部計量テンソルへ下ろす(Euclidean では単位行列)。`metric δ` と宣言すれば
  `δ_i_j` も計量として使える。添字の上げ下げは自動化せず、必要なら
  `g_i_j * v~j` のように metric を明示する。metric 名と同じ `param`/`field` 名はエラー。

## 検証結果(Apple Silicon Mac、1コア)

- **拡散 3D**(100³ 格子 × 100 step、temporal blocking 5): 実行 0.19 秒。
  質量保存の相対誤差 **6.4×10⁻¹³**(機械精度)、ピーク 1.0 → 0.2385(正しい拡散減衰)。
- **拡散 1D / 2D**: `dimension 1` / `dimension 2` の正式例として追加。
  1D は 100 格子 × 120 step で質量保存 **1.0e-15**、ピーク 1.0 → 0.5857。
  2D は 100² 格子 × 100 step で質量保存 **6.5e-15**、ピーク 1.0 → 0.3850。
- **2D 発散演算子**: `use vector-calculus { divg }` が `dimension 2` の座標文脈で
  `trace (dGrad V)` へ下りることを検査。正弦ベクトル場の中心差分離散記号と
  相対誤差 **2.8e-15** で一致。
- **Maxwell**(128×16×16、dt = 0.1dx、100 step、修正版コンパイラ): エネルギードリフト
  **4.8e-5**・パルス伝播 **+9.9 セル(理想 +10)**。2ランク実 MPI ではパルスがランク境界を
  完全に通過(送り側ランクは 1e-23 まで排出)し大域エネルギー保存 4.8e-5。
  生成式は手計算の curl と符号・係数一致。
- **Yee-FDTD**(128×16×16、dt = 0.5dx、100 step、TB4): 実行 0.13 秒。
  エネルギードリフト 0.10%、パルス伝播 +49.9 セル(理想 +50)、
  **div B ≡ 0(機械精度で恒等)**。20行の 1D リファレンス実装とパルス位置が
  全桁一致(113.68)。temporal blocking あり/なしがビット一致。
- **Pearson 反応拡散(Formura 論文 Listing 1 の再現)**(64³、dt = 200s、40,000 step、TB4):
  実行 78 秒。FHPC'16 と同一の方程式・パラメタ(Fu=1/86400 等)。値は範囲内・NaN なし・
  V コロニーが自己複製し、論文 Figure 7 と同じ Gray-Scott スポットパターンが創発。
  物理の記述は2行で、Laplacian は `.fe` 側の `def Δ u = ∂ 2 1 x u + ∂ 2 1 y u + ∂ 2 1 z u` と同じ形。
- **Burgers**(128×8×8、ν=0.05、5000 step、TB4): **Cole–Hopf 厳密解と max 誤差 3.5e-5**
  (離散化誤差オーダー)。非線形積項 u·∂u の生成を解析解で機械検証。0.4 秒。
- **Cahn–Hilliard**(64×64×32、25,000 step): 質量(reduces 経由)**12桁保存**、
  自由エネルギー単調減少、スピノーダル分解で c ∈ [−0.95, 0.96] まで相分離。128 秒。
- **TDGL**(128×128×4、4,000 step): バルク \|ψ\|² = 0.978 に飽和、渦芯 48 セル
  (min \|ψ\|² = 0.004)= 量子化渦の自発形成。3.6 秒。
- **MHD Orszag–Tang**(128×128×4、t=0.5、1250 step): 8 保存量の総和ドリフト
  ~1e-12(望遠鏡和により厳密)、**divB = 1.2e-14**(中心差分 induction が厳密保存)、
  正値性維持(ρ_min=0.15、p_min=0.11)。物理記述 = 流束19行+更新8行。6 秒。
- **弾性波 Virieux**(256×8×8、600 step、TB4): P/S パルスを同時発射し
  **測定 vp=1.990(厳密 2)・vs=0.995(厳密 1)**、弾性エネルギードリフト 3.4e-4。
  副産物: gpb < 2·s·nt の TB 構成が無警告で全零化する検証穴を発見 → 本体に検証追加。1.5 秒。
- **計量つき拡散(トーラス)**(128×128、3,000 step): 計量 g = diag((2+cos θ)², …) から
  √g・g^{ij} を **CAS が記号導出**し、係数場 ca/cb/sg の init 式(`cos((i*dx)+dx/(2))+2` 等)
  まで自動生成。独立に手書きした C リファレンスと **max 差 3.3e-16(全桁一致)**、
  計量重みつき熱量 Σ√g·u のドリフト 2.5e-15(流束形式により厳密)、
  最大値原理(reduces の umax↓・umin↑)成立。1.2 秒。
- **Klein–Gordon φ⁴ キンク**(256×8×8、800 step、TB4): v=±0.2 にブーストした
  kink–antikink 対を伝播。**実測速度 ±0.1993(規定 ±0.2)**、全エネルギーは相対論値
  2γE_kink=1.92450 に対し 1.92242(**偏差 0.11%**)、leapfrog(kick–drift、更新済み w' を
  drift が参照するシンプレクティック形)によりエネルギードリフト **3.3e-7**。0.7 秒。
- **浅水方程式**(256×8×8、400 step): 静水面上の 1% バンプが左右の重力波に分裂。
  **実測波速 0.9989(厳密 √(gh₀)=1)**、質量ドリフト 3.7e-14(流束形式)、
  y 運動量は対称性によりビット厳密に 0 のまま。0.1 秒。
- **格子ボルツマン D3Q19**(64×4×4、1,000 step): 19 方向の平衡分布・BGK 衝突・
  ストリーミングの計 57 本の式を **速度集合リストへの map だけで生成**(方向表と重み表が
  モデル定義の全て)。剪断波減衰から **実測 ν=0.10010(BGK 厳密値 (τ−½)/3=0.1、偏差 0.1%)**、
  質量ドリフト 4.8e-14、横方向速度 ≤4.5e-16。19 出力が全て異なるステンシルオフセットを持つため、
  fork で修正した混在オフセット誤コンパイルの回帰テストにもなっている。0.2 秒。
- **線形音響**(256×8×8、600 step、TB4): インピーダンス整合(p = Z·vx)の右進パルス。
  **実測音速 0.9957(厳密 √(K/ρ)=1)**、音響エネルギードリフト 1.6e-4、
  横速度 vy,vz はビット厳密に 0。0.1 秒。
- **Euler: Sod 衝撃管**(512×4×4、t=1.2): 保存形 3 変数+LF 粘性(全て流束形式)。
  **厳密 Riemann 解(p*=0.30313, 衝撃波速 1.75215)と L1(ρ)=0.0255** で
  衝撃波・接触不連続・膨張扇の3波構造を再現、質量/運動量/エネルギーの
  ドリフト ~1e-14、正値性維持。0.1 秒。
- **極座標の円環**(64×128、2,000 step): 平坦な幾何を曲がった座標で。教科書の極座標
  Laplacian が embedding から導出され、参照実装と **5.6e-16**・Σr·u 保存 **1.1e-15**。
- **球座標の球殻(3D)**(32×32×64、1,000 step): 全3軸が非自明な球座標。
  r・θ の**2軸に mirror 壁**+φ 周期。独立 3D 参照実装と **4.4e-16**・
  Σr²sinθ·u 保存 **4.2e-15**・最大値原理成立。
- **球面の帯**(64×128、2,000 step): 埋め込みだけから CAS が導出した Laplace–Beltrami、
  mirror 壁(Neumann)+周期 φ。独立参照実装と **5.6e-16**・Σ√g·u 保存 **3.6e-15**・
  最大値原理成立 — 計量と境界条件の合わせ技の最初の例。
- **双曲平面(Poincaré 半平面)**(128×64、5,000 step): 曲率 −1 の真の非ユークリッド幾何。
  Δ_H² = y²(∂xx+∂yy) を `metric scale` から導出。参照実装と **6.7e-16**・保存 **9.8e-16**。
- **Kuramoto–Sivashinsky**(L=22、64 格子、600,000 step = t=90): Lyapunov 時間内
  (t=5)は独立参照実装と **max 差 3.6e-14**、その後は時空カオスへ —
  アトラクタ統計(rms=0.916 ∈ [0.8,2.2]、|u|max=1.81 有界)で検証。
  保存形の非線形項+望遠鏡和により **Σu ドリフト 5.4e-12**(60万 step 後)。7 秒。
- **4次精度スキーム自動導出**(64×8×8、100 step): 5点係数 (−1/12, 4/3, −5/2, 4/3, −1/12)
  は**ソースのどこにも書かれておらず**、`.fe` の `def Δ4 u = ∂ 2 2 x u + ∂ 2 2 y u + ∂ 2 2 z u`
  から生成される Egison 式 `∂ 2 2 x u` が `taylorStencil 2 [-2..2]` を呼び、Taylor 条件の連立を
  厳密有理数のガウス消去で解いて導出(.fmr ヘッダに導出値をコメント出力)。単一 Fourier
  モードの振幅比が導出ステンシルの厳密離散シンボル (1+λ₄dt)ⁿ と **4.4e-16 で一致**、
  残差 \|λ₄+k²\| = 4.17e-3 は4次理論値 k⁶h⁴/90 = 4.23e-3 の 98.6%(2次の 1/49)。0.1 秒。
- **Maxwell 微分形式版(DEC)**: E を 1-form、B を 2-form として d と ⋆d⋆ で記述。
  配置情報は一切書かず、形式の次数から Yee 格子が出る。B は幾何基底名
  `B_1_2,B_1_3,B_2_3` で出力され、生成は d(dE')=0 の CAS 検査に合格した場合のみ実行される。
  check driver でエネルギードリフト 0.10%、パルス +49.9 セル、divB≡0 を検証。
- **Dirichlet 壁の拡散**(64×8×8、5,000 step): yaml の `boundary: [fixed 0.0, periodic,
  periodic]` だけで冷壁つき拡散に(物理は周期版と同じ1行)。ゴースト壁つき離散固有モード
  sin(π(i+1)/65) の厳密減衰 (1+λdt)ⁿ を **6.8e-14 で再現**、モード純度 1.2e-15
  (アンカー経路はドリフトなし=生添字がそのまま物理座標)。0.1 秒。

## 制約と既知の問題

1. **境界条件**: Formura 2.x は実質周期境界のみ。物理境界は方程式内のマスクかドライバ側で扱う。
2. **大域リダクションなし**: CFL による動的 dt などは書けない(固定 dt)。
3. プリンタの対応範囲は「多項式 + 格子参照 + 記号」。extern 関数適用や if 式は未対応
   (現状 init はテンプレート文字列で記述)。
4. **一般次元の残課題**: `.fe` 生成経路の scalar/vector/rank-2/k-form は
   1D/2D/3D 対応済み。2D curl の扱い、1D の反対称 rank-2 ゼロ storage、
   4D 以上の Formura backend は未実装。
5. **ドライバの注意**: Formura は `Formura_Forward` のたびに配列内でデータを平行移動させる
   ことがある(仕様。特に非対称ステンシルで毎ステップずれる)。座標が要る計測・出力は
   必ず `to_pos_x/y/z` を使うこと。生の配列添字で位置を測ると伝播速度を誤る
   (maxwell_yee_check.c で実際に踏んだ罠)。

## 実 MPI での実行(macOS)

`brew install open-mpi` で mpicc/mpirun が入る。生成 C は
`mpicc -O2 -std=c11 -o check main_check.c diffusion3d.c -lm` でそのままコンパイルでき、
1ランクなら `./check` の直接起動(シングルトンモード、mpirun 不要)で動く。
複数ランクは Homebrew の Open MPI 5.0.9 + 新しめの macOS だと mpirun(PRRTE)が
hwloc のトポロジ検出で segfault するため、合成トポロジで回避する:

```sh
HWLOC_SYNTHETIC="core:8 pu:1" mpirun --map-by slot --oversubscribe -n 2 ./check
```

(2ランクにするときは yaml の `mpi_shape` を `[2,1,1]` 等にして formura から再生成する。)

## Formura の GHC 9.6 移植メモ

2019 年の v2.3.2(GHC 8.4.3 / lts-12.13)からの変更は3点だけ:

1. lattices-2: `MeetSemiLattice` 廃止 → `Lattice` インスタンス化(3箇所、`\/` はスタブ)
2. GHC 9.x の TH スプライス可視性規則: `mmInstTails` を `makeLenses ''Node` の後方へ移動
3. `CompilerMonad` に `MonadFail` を deriving 追加

ほかに resolver を lts-22.44 へ、未使用の `sbv` 依存を削除。Formura は MIT ライセンス。

## 今後の方向

- Formura 本体への境界条件(mirror/fixed)と大域リダクションの実装([UPSTREAM.md](UPSTREAM.md) ④⑤)
- その後 [APPLICATIONS.md](APPLICATIONS.md) の推奨順で応用拡充(まず MHD Orszag–Tang)
- λ⊗ 型システムによる生成前の添字整合性検査(「連続の数式からの検証つきコード生成」)
- HPC 環境での複数ノード計測
- 上流への PR(GHC 9.6 移植・誤コンパイル修正)は全タスク完了後に一括提出予定

## ライセンス

MIT ライセンス([LICENSE](LICENSE))。土台とする Egison も Formura も MIT。
`vendor/` 以下の Formura(© 2015 Takayuki Muranushi)は各自のライセンスに従う。
