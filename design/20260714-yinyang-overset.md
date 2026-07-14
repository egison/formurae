# Yin-Yang overset格子(球面全域simulation)への道筋

Date: 2026-07-14

Status: V0 implemented (examples/yinyang_diffusion, driver-level PoC); Phase 1--4 planned

本書は、Kageyama--Sato の Yin-Yang 格子(球面全域を覆う overset 格子)を Formurae に
載せるための段階計画を定める。V0(ドライバ層 PoC)は本書と同時に実装・検証済みで、
`examples/yinyang_diffusion` が球面**全域**の熱方程式を現行 compiler・fork **無改造**で解く。
以降の Phase は「何をどの層に足すか」を pipeline の責務分担
([pre-fec / post-fec pipeline設計](20260711-pre-post-fec-pipeline.md))に沿って固定する。

## 1. 背景: なぜ Yin-Yang が Formurae に向くか

球面の lat-lon 単一格子は極で特異(計量退化・セル縮退・dt 制約悪化)。Yin-Yang 格子
[Kageyama & Sato 2004] は球面を**合同な低緯度 lon-lat パネル 2 枚**で覆う:

```
panel = { (θ,φ) : θ ∈ [π/4, 3π/4], φ ∈ [-3π/4, 3π/4] }   (+ 補間マージン)
Yang 座標 = T(Yin 座標),  T(x,y,z) = (-x, z, y)
```

T は対合(T² = id)なので、Yin→Yang と Yang→Yin の座標変換・補間が**同一の式**になる。
2 枚のパネルは境界の 1 周だけで結合し、そこは相手パネル内部からの補間(overset boundary)。

この構造は Formurae の設計と次の 3 点で噛み合う。

1. **パネル上の物理は既存機能そのもの**: パネルは極を含まない直交曲線座標の矩形であり、
   `embedding` 宣言(metric_sphere で実証済)から Egison が計量・保存 Laplace--Beltrami
   flux form を導く。数式は `u' = u + dt * Δ u` の 1 行のまま。
2. **合同性 = 1 kernel 2 instance**: Yin と Yang は自分の座標では同一格子・同一計量なので、
   1 つの `.fme` から生成した 1 つの Formura program を 2 インスタンス走らせるだけでよい。
   Kageyama が「同一 subroutine を 2 回呼ぶ」と述べた性質が、生成 C の水準でそのまま成立する。
3. **overset は境界 primitive であって数学ではない**: 必要な拡張は全て境界・トポロジー側
   (pre/post-fec、Formura fork、ドライバ)に落ち、Egison の数学演算子には一切触れない。
   reduce・境界条件([UPSTREAM.md](../UPSTREAM.md))と同じ「宣言は FEIR に保持し、
   post-fec が下ろす」進め方が overset にもそのまま使える。

## 2. V0(実装済): ドライバ層 PoC — examples/yinyang_diffusion

### 2.1 構成

- `.fme` はパネル 1 枚の熱方程式(metric_sphere と同型)。h = π/48 として

  ```
  θ_phys = 5π/24 + θ ∈ [π/4 - 2h, 3π/4 + 2h]   (29 点)
  φ      ∈ [-3π/4 - 2h, 3π/4 + 2h]              (77 点)
  ```

  古典的最小パネルを**2 セルずつ拡張**している(§2.2)。yaml は
  `boundary: [mirror, mirror, periodic]`(z はダミー軸)。mirror は placeholder で、
  その影響を受けるのは縁 1 セルの自己更新だけであり、そこは毎ステップ上書きされる。
- check driver(`yy_check.c`)が overset 合成を担う:
  1. `Formura_Init` 後、`formura_data`(計量場込み)を `panel[2]` へ複製し、
     u だけを大域座標の初期値で置き直す(Yin 系 = 大域系、Yang は T 経由)。
  2. 毎ステップ、各パネルを `formura_data` へ struct 代入で swap-in して
     `Formura_Forward`、swap-out。
  3. 交換: 各パネルの**縁 1 セル(208 点)**を、相手パネルからの双一次補間で上書きする。
     対合性+合同性により、補間 stencil 表(donor index と重み)は**両方向で同一の 1 本**。

  swap の安全性は生成 C の構造による: 永続状態は `formura_data` に閉じ、ghost 付き作業
  配列 `buff` は毎 Forward 先頭で `formura_data` から再構成される(anchor 方式、drift なし)。

### 2.2 幾何の要点(実測)

- マージン 2 セルの拡張だけで、縁の全 donor 点が相手パネル境界から
  **4.00 セル以上内側**に入る(driver が構築時に全数検査)。よって
  (a) donor は相手の縁データに触れず、相互交換は**順序非依存**、
  (b) donor 値は常に「正しく更新された内部点」であり、交換は毎ステップ 1 回で足りる。
- パネル φ 範囲は margin 込みで ±(3π/4 + 2h) ≈ ±2.487 < π なので、`atan2` の分枝
  不連続は donor 探索に現れない。margin を増やす場合は 3π/4 + m·h < π、
  すなわち h = π/48 なら m < 12 が上限。
- h = π/48・margin 2 セルの構成では両極がちょうど Yang の格子点に乗る
  (θ' = π/2, φ' = ±π/2)。検証(振幅追跡)にはこれを利用した。一般解像度では
  極は格子点に乗らないが、どのみちパネル内部の通常点である。

### 2.3 検証(2026-07-14 実測、`make yinyang_diffusion`)

Y₁⁰ = cos θ_global は Laplace--Beltrami の厳密固有関数で、u(t) = e^{-2t} u₀。

| 検査 | 実測 |
|---|---|
| max\|u − e^{-2t}Y₁⁰\|(T=0.3, 29×77×2) | 7.32e-4(h² = 4.28e-3 の見積りと整合) |
| 減衰率 fit / 厳密値 2 | 2.0007 |
| 重なり領域の Yin/Yang 整合(1460 点) | 4.57e-4 |
| 離散最大値原理の違反 | 0(厳密に 0) |
| 長時間(T=0.9) | 3.62e-4 / rate 2.0013 / 違反 0(誤差は解とともに減衰) |

最大値原理が**厳密に**保たれるのは、dt = 3e-4 が単調性限界
1/(2(1/h² + 1/(h·sin θ_min)²)) ≈ 5.79e-4 の下にあり、かつ双一次補間の重みが凸だから。
overset 交換が新しい極値を作らないことの直接検証になっている。

### 2.4 V0 の既知の制約

- NoBlocking・1 rank・スカラー場のみ。交換は縁 O(N) で直列(この規模では無視できる)。
- struct swap は格子 2 倍分の memcpy を伴う(小規模では無視できるが Phase 1 で撤去)。
- 大域保存(∫u dA)は検査しない: overset 補間は流束整合でなく厳密保存しない(§6)。
  さらに全球積分は重なりの二重計上を除く所属重みが要る。固有関数減衰+重なり整合は
  この弱点を避けた検証である。
- `.fme` の罠: CAS 文脈の小数リテラルは Float になり `sin (0.654… + θ)` が正規化で落ちる。
  整数分数 `6544984694978736 / 10000000000000000` なら exact rational として通り、
  生成 C には既約分数 `4.09061543436171e14/6.25e14`(双方 2⁵³ 未満、丸め一致)で残る。

## 3. Phase 1: fork 拡張 — overset を境界 primitive にする

**目的**: 「mirror を置いて縁を上書き」という間接表現をやめ、正しさの条件を機構化する。

- boundary 種別に `driver`(仮)を追加: その軸の ghost 充填コードを**生成しない**。
  ghost 領域へドライバが直接書く API(`Formura_Ghost(navi, axis, side)` 相当)を生成
  ヘッダに出す。V0 の「上書き幅 ≥ ステンシル半径」依存(s ≥ 2 の 4 次精度で破綻)が消える。
- 格子の多重インスタンス化: `formura_data` のグローバル一意性を外す
  (grid struct へのポインタを Navi に持たせる、または全 API に instance 引数を足す)。
  UPSTREAM.md の PR 系列と同じく fork ブランチに積む。
- 受け入れ: yinyang_diffusion を memcpy なし+ghost API で書き直して数値**ビット同等**、
  既存例の回帰ゼロ。

## 4. Phase 2: post-fec による overset 合成の自動生成

**目的**: ドライバ手書きの donor 表・交換ループを compiler の出力にする。

- 表層宣言(案)。計量宣言と同格の「トポロジー宣言」であり、`step:` は不変:

  ```formurae
  grid yinyang margin 2                 -- 定型: 合同 2 パネル + 対合 T + 双一次
  ```

  一般 overset へ開く場合の脱糖形:

  ```formurae
  panels yin, yang
  transform yang = involution [ -x, z, y ]
  overset boundary bilinear
  ```

- pre-fec: 宣言を versioned FEIR declaration(provenance つき)として保持。
  **Egison 層は素通し**(数学演算子に混ぜない — reduce と同じ設計判断)。
- post-fec: パネル格子は静的なので donor 探索・重み計算は**コンパイル時に完結**する。
  縁セルごとの (donor index, 重み) を定数表として `<name>_exchange.c` に生成し、
  交換関数と χ 所属重み場(§6 の大域診断用)も出す。V0 driver の実行時構築と違い、
  Formura の「全 offset は静的」という流儀に揃う。
- 検査: 補間次数と内部差分次数の整合(全体次数)、margin ≥ ステンシル半径+補間福、
  atan2 分枝条件(§2.2)を post-fec の validation に置く。
- 受け入れ: 生成表 = V0 手書き表(全 208 点で index・重み一致)、数値ビット同等。

## 5. Phase 3: MPI 並列と temporal blocking

- rank 配置は Kageyama 流: communicator を Yin 半分/Yang 半分に split
  (生成 API に既にある `Formura_Custom_Init(navi, comm)` が入口)。
  donor 表は静的なので rank 間の通信相手・量もコンパイル時確定し、交換は P2P の
  定型 pack/send/recv/unpack を post-fec が生成する。
- TB との整合は reduce([UPSTREAM.md](../UPSTREAM.md) PR5)と同型の設計問題:
  overset 交換は毎ステップの大域同期そのもの。方針は
  (a) **margin 拡張方式**: パネル margin を 2 + s·nt セルへ広げ、TB interval 内は
      自前データで進めて interval 境界でのみ交換(§2.2 の m < 12 制約に注意)、
  (b) V1 は NoBlocking 限定で意味論を固める(BC・reduce と同じ段階導入)。
- 受け入れ: (a) で TB4 ≡ NoBlocking のビット一致、weak scaling 計測。

## 6. Phase 4: ベクトル場と応用、大域診断

- **ベクトル/テンソル場の交換には成分回転が要る**: (u_θ', u_φ') = R(位置)·(u_θ, u_φ)。
  R は T と embedding から閉形式で出る。ここだけは Egison の出番であり、
  R を**記号導出**して post-fec が縁セル定数として donor 表に焼き込む
  (解析は Egison、格子化は post-fec という分業のまま)。
- 応用の順(それぞれ APPLICATIONS.md の検証流儀で):
  1. 球面浅水方程式 — Williamson TC2(定常帯状流の維持誤差)、TC5(山越え流)。
     成分回転の最初の実戦。
  2. 3D 球殻(r 軸追加、パネルは (r,θ,φ) 直方体)— mantle 対流(Boussinesq)。
  3. Yin-Yang-Zhong [Hayashi & Kageyama 2016] — 中心を含む全球(第 3 の格子 Zhong を
     同じ overset 機構で追加)。
  4. 球殻 MHD ダイナモ(examples/mhd_ot の球殻版)。
- **大域診断**: 全球積分は重なり二重計上を除く所属重み χ(Kageyama の weight function)
  が要る。fork の reduce は単純和なので、`sum (χ * u)` の形で χ 場を掛けるか、
  reduce 宣言に weight 指定を足す。保存が本質の応用(浅水の質量)では、overset の
  非保存(補間は流束整合でない)を flux-correction で締めるか保存誤差を監視項目にする。

## 7. 意味論上の注意(先に踏む罠)

1. **overset は厳密保存しない**。V0 で保存検査を外し固有関数減衰に切り替えたのは意図的。
   保存が要る応用は §6 の対処を先に決める。
2. **双一次の凸性が最大値原理を守る**(V0 で違反厳密 0 を実測)。bicubic へ上げると
   overshoot が入りこの性質は壊れる — 次数と単調性はトレードオフとして宣言で選ばせる。
3. **CAS 文脈の小数リテラル**は Float 扱いで正規化が落ちる(§2.4)。pre-fec で
   小数→exact rational の lowering を入れるまでは整数分数で書く。
4. margin・解像度を変えるときは §2.2 の 2 条件(donor 内側マージン、atan2 分枝)を
   必ず再検査する(V0 driver は構築時に全数 assert している。post-fec 化後は
   compile-time validation に移す)。

## 8. 参考文献

- A. Kageyama, T. Sato: *The "Yin-Yang grid": An overset grid in spherical geometry*,
  Geochem. Geophys. Geosyst. 5, Q09005 (2004).
- H. Hayashi, A. Kageyama: *Yin-Yang-Zhong grid: An overset grid system for a sphere
  including the center*, J. Comput. Phys. 305 (2016).
- A. Qaddouri, V. Lee: *The Canadian Global Environmental Multiscale model on the
  Yin-Yang grid system*, Q. J. R. Meteorol. Soc. 137 (2011).
