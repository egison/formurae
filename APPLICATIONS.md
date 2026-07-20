# Formurae 応用カタログ

Egison のテンソル添字記法で連続系の PDE を 2〜3 行書き、Formura で分散並列+
temporal blocking つきの C に落とす——このパイプラインで狙える応用を、
**実装可能性と検証方法つき**で整理する。生物系(反応拡散の生態解釈)は
`examples/pearson3d` で実証済みなので、ここでは**物理・工学系を中心**に挙げる。

## 適用可能性の判定基準

Formura 2.x + 現行の `formurae-pre -> Egison -> FEIR -> formurae-post` に乗るのは
次を満たす問題:

1. **陽的時間発展**(explicit): u^{n+1} が u^n の局所ステンシルで書ける
2. **局所相互作用**: 近接格子点のみ参照(長距離力・大域結合なし)
3. **周期境界で意味がある**(または物理境界をマスク係数場で表現できる)
4. **固定 dt で安定**(最悪波速を事前に見積もれる)

Egison が数式とテンソル演算を導関数つき `FieldJet` へ正規化し、
`formurae-post` が格子配置、差分係数、補助場を決定する。したがって
**多項式的な非線形項(u·v², |ψ|²ψ など)はそのまま書ける**し、
`extern` 宣言した exp/cos などの関数呼出しも FEIR から Formura へ保持される。
長距離相互作用や全格子同期は引き続き Formura 側の機構を必要とする。

凡例 — ◎: 現行機能で今すぐ / ○: FEIR、`formurae-post`、または Formura の小拡張で可 /
△: Formura 本体拡張(境界条件 or 大域リダクション、[UPSTREAM.md](UPSTREAM.md))後に実用化

「済」の例はすべて `.fme` から上記の FEIR pipeline で生成する。

## 一覧

| # | テーマ | 方程式系 | 必要機構 | 検証(不変量・解析解) | 判定 |
|---|---|---|---|---|---|
| 1 | 理想 MHD(Orszag–Tang 渦) | 保存形 8 変数 | 中間流束場+Rusanov | 保存 ~1e-12・divB 1.2e-14・正値性 | **済** (examples/mhd_ot) |
| 2 | 弾性波・地震波(Virieux) | v–σ 定式化、σ は対称テンソル | Primal policy+テンソル成分から配置推論 | vp=1.990/2・vs=0.995/1・E ドリフト 3.4e-4 | **済** (examples/elastic3d) |
| 3 | 線形音響(p–v) | ∂t p = −K∇·v、∂t v = −∇p/ρ | Yee の scalar 版 | 音速 0.9957/1・E ドリフト 1.6e-4・横速度 =0 | **済** (examples/acoustic3d) |
| 4 | 浅水方程式(津波・回転流体) | h, hu の保存形(+コリオリ f) | 中心差分+人工粘性 | 波速 0.9989/1・質量 3.7e-14・対称性 max\|my\|=0 | **済** (examples/shallowwater) |
| 5 | Burgers 方程式(1D/3D) | ∂t u + u∂x u = ν∇²u | 済 | Cole–Hopf 厳密解と 3.5e-5 一致 | **済** (examples/burgers3d) |
| 6 | 圧縮性 Euler(Sod 衝撃管) | 保存形 3 変数(1D 流)、LF 粘性 | λmax は固定パラメタ | 厳密 Riemann 解と L1(ρ)=0.0255・保存 ~1e-14 | **済** (examples/euler_sod) |
| 7 | 格子ボルツマン(D3Q19) | streaming(=shift)+局所衝突 | 中心差分から整数1セルpullを厳密構成 | 実測 ν=0.10010(BGK 厳密 0.1)・質量 2.3e-14 | **済** (examples/lbm_d3q19) |
| 8 | Cahn–Hilliard(スピノーダル分解) | μ = c³−c−κ∇²c、∂t c = M∇²μ | 中間場 μ | Σc 12桁保存・F 単調減・相分離 ±0.95 | **済** (examples/cahnhilliard3d) |
| 9 | 時間依存 Ginzburg–Landau(超伝導渦) | ∂t ψ = ψ − \|ψ\|²ψ + ∇²ψ(実 2 場) | 多項式のみ | バルク飽和 0.978・渦芯形成 | **済** (examples/tdgl3d) |
| 10 | 非線形 Klein–Gordon(φ⁴ キンク) | ∂tt φ = ∇²φ − m²φ − λφ³ | leapfrog 2 場 | 速度 ±0.1993/0.2・E=2γE_kink 偏差 0.11%・ドリフト 3e-7 | **済** (examples/kleingordon) |
| 11 | 曲線座標・曲面上の拡散(計量つき) | ∂t u = (1/√g)∂i(√g g^{ij}∂j u) | Egison が `GeometryNF` を構成し、`formurae-post` が保存流束へlowering | 参照実装と 3.3e-16・Σ√g·u 保存 2.5e-15・最大値原理 | **済** (examples/metric_torus) |
| 12 | Kuramoto–Sivashinsky(時空カオス) | ∂t u = −∂x(u²/2) − ∇²u − ∇⁴u | 保存項はbackquoteしたwhole-expression微分、4 階項は中間場への2階差分×2段 | Lyapunov 内で参照と 3.6e-14・アトラクタ統計・Σu 5e-12 | **済** (examples/ks3d) |
| 13 | 樹枝状凝固 phase-field(Kobayashi) | 異方性 ε(θ)、θ = atan2(∂yφ, ∂xφ) | atan2/cos の出力対応 | 界面幅、異方性次数と枝の本数 | ○ |
| 14 | 非線形シュレディンガー(光ソリトン) | i∂t ψ = −½∇²ψ − \|ψ\|²ψ | 実 2 場;陽解法の弱不安定に注意 | ノルム・ソリトン形状(sech 解析解) | ○ |
| 15 | FDTD 実用化(誘電体・PML) | Yee + ε(x), σ(x) 係数場 | 係数場(PML は減衰係数場だけで書ける) | 反射率、導波路モード | ◎〜△ |
| 16 | 高次スキーム自動導出(横断機能) | 通常の∆にmodel profileで 4 次精度を指定 | `formurae-post` のexact Taylor solverが最小半径の係数を導出 | 導出=既知公式・離散シンボル 4.4e-16・h⁴ 残差則 98.6% | **済** (examples/highorder4) |
| 17 | 球面**全域**の拡散(Yin-Yang overset 格子) | ∂t u = Δ_{S²} u、合同 2 パネル+相互補間境界 | embedding 計量(済)+ドライバ層 overset 交換(1 kernel 2 instance) | 大域 x/y/z 固有モード減衰 e^{−2t}(最悪 7.3e-4)・重なり整合(最悪 5.4e-4)・最大値原理(1e-13 許容差内) | **済** (examples/yinyang_diffusion、V0) |

**不向きなもの(正直リスト)**: 非圧縮 Navier–Stokes(圧力 Poisson = 大域結合;
ただし人工圧縮性法なら陽的化可能、また大域リダクション追加後は Jacobi 反復+収束判定で
原理的には可)/重力・クーロンなど長距離力/AMR・非構造格子/陰解法。

## 各テーマの要点

### 1. 理想 MHD — 「次の一手」最有力

Formura 同梱の手書き 283 行 HLLD(`vendor/formura/sample/mhd_3d_hlld`)の簡易版
(Lax–Friedrichs flux)を Formurae へ移すときは、保存流束と誘導方程式の
連続系だけを表層に書き、配置と stencil を `formurae-post` に決めさせる:

```egison
def flux a U = ...                         -- 保存形 F_a(U)
def induction W = curl W                  -- W = v×B, ∂B/∂t = ∇×W
```

誘導方程式を **constrained transport(B を Dual、E を Primal に配置)**で書けば
∇·B ≡ 0 が機械精度で保存される(maxwell3d_yee で実証済みの機構をそのまま流用)。
検証は Orszag–Tang 渦 — FHPC'16 論文 Fig.3 と同じ絵が出るはず。
論文の「notation が boilerplate を消す」主張の決定打になる。

### 2. 弾性波(Virieux スタガード格子)— Yee の直系

速度 v_i と応力 σ_ij(対称 6 成分)を半セルずらして配置する標準法。
Formurae では成分ごとの offset tableや微分 callback を書かず、field policyと
テンソル添字から `formurae-post` が配置を推論する:

```formurae
field v~i @ primal
field σ{~i~j} @ primal

step:
  v'~i = v~i + (dt / ρ) * ∂_j σ~i~j
  σ'~i~j = σ~i~j + dt * (λ * g~i~j * ∂_k v'~k
                    + μ * (g~i~k . ∂_k v'~j + g~j~k . ∂_k v'~i))
```

検証: 弾性エネルギー ∫(ρv²/2 + σ:ε/2) の保存、P 波速 √((λ+2μ)/ρ)・S 波速 √(μ/ρ) の実測。
地表自由境界・吸収底面をつけると実務的地震波計算になる(→ UPSTREAM.md の境界条件)。

### 5. Burgers — 解析解つき非線形のベンチマーク

Cole–Hopf 変換で 1D 厳密解が書けるため、**非線形項の生成が正しいことを
解析解との L∞ 誤差で機械検証できる**唯一級の題材。回帰テストに最適。

### 7. 格子ボルツマン(D3Q19)— コード生成の強みが最大化する例

19 本の分布関数 f_k の平衡分布は `.fme` の純粋関数 `feq` で共有する。
streaming は、c=±1 に対する中心差分の恒等式
`q(x-c h) = q - c h Dq + h² D²q/2`を `pullx`/`pully`/`pullz` として書き、
各軸の materialized local を連結する。これにより新しいbackend専用shiftを追加せず、
FEIRの既存derivative requestからD3Q19の整数・対角offsetを厳密に生成する。
将来 `field f : family 19` と式familyを表層化すれば、速度集合と重みをデータとして
19 本の宣言・衝突・streamingを自動展開できる。

### 8. Cahn–Hilliard — 4 階微分と 2 段参照

μ を `local` として書くと、`formurae-post` が .fmr の中間格子場として保存し、
各段の式を半径 1 に保つ。Σc の厳密保存(丸め誤差のみ)が
強い検証になる。スピノーダル模様は見栄えもよい。

### 9. TDGL 超伝導渦 — 「今すぐ動いて派手」枠

複素場を実 2 場 (a,b) にすると全項が多項式。ランダム初期値から渦(位相欠陥)が
自発形成され、巻き数が量子化される。実装コストは pearson3d 並みに低い。

### 11. 計量つき拡散 — Egison ならではの看板候補

ユーザは計量 g_ij を与えるだけ。√g, g^{ij}, Laplace–Beltrami の展開は
**Egison の CAS が記号的に実行**し、計量、逆計量、scale factor、volumeを
`GeometryNF` として FEIR へ出す。canonical `Δ u` は内部で保存流束の離散 request として残し、
`formurae-post` が half-cell の係数場、flux、volume除算、更新順を決めて .fmr を出す。
トーラス(周期境界そのもの!)上の拡散が最初の題材として綺麗。
Devito/GT4Py にはない芸当で、論文の差別化ポイントを増やす。

**実装済**(`examples/metric_torus/`): トーラス R=2, r=1 の embedding から
√g = 2+cos θ、A=√g·g^{θθ}、B=√g·g^{φφ} を Egison が記号導出する。
`formurae-post` は ca/cb/sg 等の係数場を必要な配置で初期化し、f1/f2 を半セル位置に置く
保存流束形を生成する。これにより計量重みつき熱量が厳密保存される。
独立 C 参照実装と 3.3e-16 一致、最大値原理は `reduces` の umax/umin で監視。

### 16. 高次スキーム自動導出 — 応用ではなく「武器の増設」【実装済】

**実装済**(`examples/highorder4/`): 数学的な Laplacian はcanonical `Δ`を直接使い、
離散化だけをmodel profileで指定する。

```formurae
discretization collocated derivative 2 centered accuracy 4
```

Egison がgeometryのない`Δ u`を二階の `FieldJet` へまとめた後、`formurae-post` の
exact-rational Taylor solverが要求精度を満たす最小半径を選ぶ。その結果、5点4次の
第2微分係数(−1/12, 4/3, −5/2, 4/3, −1/12)が得られる。
精度別の数学演算子は定義せず、wideな一階差分を二重適用しない。
検証は単一 Fourier モードで、生成コードの振幅比 = 導出ステンシルの
離散シンボル (1+λ₄dt)ⁿ を 4.4e-16 で再現+残差の h⁴ 則 98.6%。

### 17. Yin-Yang overset(球面全域)— 「1 kernel 2 instance」の実証【V0 実装済】

**実装済**(`examples/yinyang_diffusion/`): 球面全域を Kageyama–Sato の合同 2 パネル
(Yin/Yang、対合 T(x,y,z) = (−x,z,y) で写り合う)で覆い、熱方程式を解く。
パネルの物理は `embedding` 宣言+`Δ u` の 1 行(metric_sphere と同型)で、
compiler・fork に**overset 固有の改造を加えず**、overset 合成(パネル 2 インスタンス+縁 1 セルの
相互双一次補間)は check driver が担い、対合性により補間表は両方向で同一の 1 本。
標準検証は固有値 2 の大域 Cartesian 固有関数 X_g/Y_g/Z_g を 1 回の起動で
それぞれ 1000 step 回し、減衰 e^{−2t}、重なり領域の Yin/Yang 整合、離散最大値原理を見る。
最大値原理の「違反 0」は 1e-13 を超える極値増加がないという判定であり、
浮動小数点での厳密な 0 は主張しない。`make yinyang_diffusion-long` は各モードの
3000 step 回帰も実行する。
表層宣言化(`grid yinyang margin 2`)・MPI 分割・ベクトル場成分回転・浅水/mantle
対流への展開は未実装の将来課題である。

## 推奨実装順(1–5 は完了済)

1. ~~**MHD(Orszag–Tang)**~~ — 済(283 行 → 流束19行+更新8行)
2. ~~**弾性波(Virieux)**~~ — 済(テンソル添字からの staggered placement 推論を実証)
3. ~~**Burgers**~~ — 済(Cole–Hopf 解析解による機械検証、`make all` が CI 相当)
4. ~~**Cahn–Hilliard / TDGL**~~ — 済
5. ~~**LBM D3Q19**~~ — 済(中心差分恒等式による整数pullを`.fme`化)
6. 境界条件・大域リダクション入り後の発展: Euler の CFL 適応 dt(reduce V2 =
   カーネル内参照が必要)、地震波の自由地表(変数別 BC が必要)、PML。
   最初の BC 実例 = `examples/dirichlet_diffusion/`(fixed 0.0 壁の離散固有減衰)。

新しい `.fme` exampleは `.egi`、`.feir`、`.fmr` の各生成artifactと検証ドライバを持ち、
Makefile ターゲットが `formurae-pre -> Egison -> formurae-post -> Formura -> C check` を通す。
不変量チェックが exit code を返すため、`make <name>` で全段を再現できる。
