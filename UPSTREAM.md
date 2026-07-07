# Formura 本体への拡張計画(upstream ロードマップ)

Egi は GitHub の formura organization メンバーであり、formura/formura に直接
PR/push できる。本ファイルは「issue を立てて待つ」のではなく**自分たちで本体を
更新する**前提の作業計画。小さい PR に分割して出す。

## PR 分割案(依存順)

方針(2026-07-08): **PR の提出は全タスク完了後に一括**。それまで fork のブランチに積む。

| PR | 内容 | 規模感 | 状態 |
|---|---|---|---|
| 1 | GHC 9.6 移植 | 小(6 ファイル) | **fork にコミット済**(ghc96-port fbf1e24) |
| 2 | 混在ステンシル半径の誤コンパイル修正(旧称: TB 袖幅≥2 バグ) | 小(真因判明後) | **fork にコミット済**(fix-mixed-radius-drift de9b623)・下記に解決記録 |
| 3 | per-variable cursor の API 整合 | — | **不要になった**: PR2 の症状だった。修正後は全変数一様ドリフトで to_pos_* が正しい |
| 4 | 境界条件(mirror / fixed) | 中 | **fork にコミット済**(boundary-conditions 58e9a12)・下記に実装記録 |
| 5 | 大域リダクション | 中 | **fork にコミット済**(global-reductions 851a37e)・下記に実装記録 |

前提知識: コンパイルパイプラインは
`.fmr + .yaml → Parser/Desugar → OMProgram(データフローグラフ、非局所命令は
Shift のみ)→ MMProgram(manifest ノード+cursor)→ C 生成(halo 交換・
ブロックループ・カーネル)`。1.x の設計論文は FHPC'16 §2.3。

## PR 2: TB バグ — 調査結果(2026-07-07、upstream/tb-repro/)

`upstream/tb-repro/repro.sh` が TB4 vs 非ブロックの**値多重集合のビット比較**
(配列内平行移動に不変)で全変種を判定する。8 ステップで判定でき、
dt を安定域に置いたままでも検出できる(発散を待つ必要がない)。

**最小再現(reproG/H/J)**: 2 変数・各 1 行で発火する。

```
q' = q + c*(r[i,j+1,k] - r[i,j-1,k])   # 半径 1(方向は x でも y でも発火)
r' = r[i,j,k]                           # 半径 0(パススルー)
```

**判定マトリクス(実測)**:

| ケース | 構成 | 結果 |
|---|---|---|
| repro1/2/2d/dg/3d | 単一変数、半径 1〜2、対角込み、1D/2D/3D | 一致 |
| reproI | 2 変数とも半径 1 | 一致 |
| reproE | 2 変数(半径 1 + 半径 2 自己) | 一致 |
| **reproG/H/J** | **半径 1 + 半径 0(パススルー/0.999 倍)** | **不一致** |
| mxB/mxB1/mxB2 | Maxwell の E 側 1 本+恒等 5 本 | 不一致 |
| mxA/mxC/mxD | E 恒等+B 半径 2 側(E は時間定数) | 一致 |
| maxwell3d | フル(半径 1 の E + 半径 2 の B) | 不一致(8 step で 98% の値) |

**特性**: 更新式の半径が変数間で不均一(特に半径 0 のパススルー変数と
半径 ≥1 の変数の混在)のとき TB が壊れる。reproH(r′=0.999r)では
**位置に依存しない値集合そのものが崩れる** = 一部セルでステップ適用回数を
誤っている(時間位相の誤り)示唆。mxA 系が通るのは、半径 0 側(E)が
時間定数のため位相誤りが値に現れないからと整合。

**次の作業**: reproG の生成 C(小さい)を読んで wall/floor 充填の
変数別カーソル/位相の扱いを特定し修正。修正後は上記マトリクス全通過+
maxwell3d ビット一致が受け入れ条件。回帰テストとして repro.sh を
test/ に移植する。

**解決(2026-07-08)**: 真因は TB ではなく **mkKernel の per-node range**(Generator/Templates.hs)。
出力ノードは結果を生ループ添字に書く一方、入力はノード自身の range オフセットで再センタリング
されるため、「変数の毎ステップ配列内シフト量 = そのノードの range オフセット」になる。
halo コピーと offset_* 更新は全変数一律 sleeve シフトを仮定しているので、半径が混在すると
NoBlocking でも 2 ステップ目から相互参照がずれる(reproG の閉形式解でステップ 2 に増分
1 個分の誤差を確認)。TB は増幅要因にすぎない。修正 = 出力(void)ノードの range を
(−sleeve,+sleeve) に統一(fix-mixed-radius-drift de9b623)。検証 = reproG 閉形式一致
2.7e-15(NB/TB)・15 変種 TB≡NB ビット一致・collocated Maxwell が 1D リファレンス一致
(パルス 0.994@113、エネルギー 0.33%→4.8e-5)・単一変数プログラムはビット不変。

- 当たりの見当(当初のメモ、参考): 変数ごとの sleeve 消費(Annotation/Boundary.hs の合成)と
  TB の wall/floor 充填(Generator/Templates.hs)における、変数別
  MMLocation カーソル/時間位相の不整合。半径が揃った同梱例では露見しない。

## PR 3: per-variable cursor API

- 問題: 変数ごとにステンシル形状が違うと、Forward 後の配列内シフト量が
  **変数ごとに異なる**(実測: collocated Maxwell で E 族 +3/step、B 族 +2/step)。
  しかし `Formura_Navi` の offset_x/y/z は 1 軸 1 個で、`to_pos_*` が全変数に
  同時に正しくなり得ない(README 既知問題⑥)。
- 案 A(後方互換): 生成ヘッダに `to_pos_x_<var>(ix, navi)` を変数ごとに生成。
  内部の MMLocation cursor は既に変数別に追跡されているので、コード生成時に
  変数→累積カーソルの表を Navi に持たせるだけ。
- 案 B(根治): Forward の最後に全変数を共通位相へ揃えるコピーを入れる
  (性能を数%犠牲にして API を単純化)。yaml でどちらかを選択制に。
- どちらでも、ドライバ作成者向けにデルタ応答テストの手順を README に明記する。

## PR 4: 境界条件(mirror / fixed)

### 現状と回避策

2.x は全軸トーラス(周期)固定。物理境界の回避策は
(a) マスク係数場(壁を χ(x) で塗る、PML は減衰係数場 σ(x))
(b) ドライバで Forward 後に上書き — ただし TB 中の中間ステップに介入できず、
TB と非互換。つまり**言語としては周期しか書けない**。

### 設計

- 構文(yaml 案): `boundary: [mirror, periodic, fixed 0.0]`(軸ごと)。
  .fmr 側に置く案(`boundary :: x -> mirror`)もあるが、数値設定は yaml に
  寄せるのが 2.x の流儀。
- 意味論: 端ノードの halo を、周期の「対岸から受信」の代わりに
  - mirror: 自領域の鏡像コピー(Neumann、∂u/∂n = 0)
  - fixed v: 定数 v で充填(Dirichlet)
- 実装箇所: **通信生成部の局所変更で済む筋が良い**。現在、rank_p1_0_0 等の
  隣接ランクへ send/recv しているところで、「隣が存在しない端」(mpi_shape の端、
  周期でない軸)の場合に MPI をスキップし、halo を局所充填するコードを生成する。
  カーネル・TB 構造は無変更(TB の wall/floor 充填も同じフックを通る)。
- 注意: TB との整合は PR 2 の修正が前提(halo 充填の正しさに乗るため)。
- テスト: 1D 熱伝導 mirror で総熱量保存、fixed で定常線形分布(解析解)。

### 実装記録(2026-07-08、boundary-conditions 58e9a12)

設計を一部変更して実装した。当初案の「端 rank の halo 充填差し替え」ではなく、
**アンカー方式の専用 NoBlocking パス**とした。理由: 既存の周期パスは
「片側 2s halo+毎ステップ +s ドリフト」方式で、物理境界の継ぎ目が配列内を
移動するため、巻いた配列では同一セルが実データとゴーストを兼ねてしまい
非周期境界を表現できない(デルタ試験と生成 C 精読で確認)。

- yaml: `boundary: [mirror, periodic, fixed 0.0]`(軸ごと。既定は periodic)
- 非周期軸があると: 対称 halo(interior を全軸 +s に配置)・ゴーストは軸順に
  ローカル充填(periodic=wrap コピー/mirror=面対称/fixed=定数)・コーナーは
  後段の軸パスが正しく上書き・カーネル無変更・offset 恒等(ドリフトなし)
- 制約(検証で明示拒否): NoBlocking かつ mpi_shape [1,...] のみ(段階導入)
- 受け入れテスト(upstream/bc-test/run_bc.sh): 1D 熱伝導 200 step で
  mirror/fixed/periodic ともゴースト意味論リファレンスと 4.4e-16 一致、
  mirror の総熱量保存 3e-16、**3D 混在境界 [mirror, periodic, fixed 0.0] が
  コーナー込みで 4.4e-16 一致**。既存パスは回帰ゼロ(15 変種+4例 green)

残: TB 対応(interval 境界での再充填)、多ランク対応(端 rank 判定+両方向交換)。

### これで開くもの

地震波(地表自由境界+吸収底面)、室内音響(剛壁)、導波路(金属壁)、
津波(海岸線)、有限試料の材料計算。APPLICATIONS.md の△が◎になる。

## PR 5: 大域リダクション

### 現状

全格子の max/sum を取って次ステップの係数に使う仕組みがない。
- CFL 適応 dt(dt = C·dx/max|u±c|)が書けず、最悪ケースの固定 dt で
  性能を捨てるか発散リスクを負う(衝撃波系では本質的)
- 反復法の収束判定が書けない(→ Poisson、非圧縮流体への扉が閉じている)
- 大域診断(全エネルギー等)はドライバで手書き

### 設計

- 構文: `umax = reduce max u` / `total = reduce (+) u`(step 関数内で
  「格子→スカラー」の束縛)。スカラーは次ステップの係数として使える。
- IR: OM 命令に Reduce を追加(現在は Load | Shift | Operator | Imm)。
  データフローグラフ上は「格子ノード → スカラーノード」の縮約辺。
- 生成: ブロック内部分和 → ノード内 OpenMP reduction → MPI_Allreduce。
- **TB との相互作用が本丸**: TB はステップ間同期を消す仕組み、リダクションは
  全域同期そのもの。方針は「リダクション値の更新は TB interval 境界のみ」
  = interval 内は前回値を使う遅延適応。dt 適応なら「前 interval の max 波速
  ×安全係数で今 interval の dt を固定」— 実務の適応 dt と同じ妥協で、
  意味論も『reduce は nt ステップごとに更新される』と単純に言える。
  2.x には filter_interval(nt の倍数制約)という同型の先例があり、同じ枠に載る。
- 段階導入: まず NoBlocking 限定で入れて意味論を固め、TB 対応を第 2 段に。
- テスト: 移流方程式で CFL 適応 dt(初期速度を段階的に上げても安定)、
  Jacobi 反復 Poisson の残差収束。

### 実装記録(2026-07-08、global-reductions 851a37e)

設計を V1 スコープに絞って実装した。**yaml 宣言 + Navi 格納**方式:

- yaml: `reduces: [res = absmax d, tot = sum q]`(op = sum | max | min | absmax)
- Formura_Init 後と毎 Formura_Forward 後(**NoBlocking / TB 両モード**)に全域を
  集計し、MPI_Allreduce(MPI_IN_PLACE)して `n->reduce_<name>` に格納
- ドライバから `while (n.reduce_res > tol) Formura_Forward(&n);` と書ける
- TB でも意味論は一様: 「Forward 完了時点の状態のリダクション」(interval 境界での
  更新という当初案そのもの)
- 受け入れテスト(upstream/reduce-test/): ①**[fixed 0.0] 境界 × Jacobi Poisson を
  生成された residual で収束駆動** → 19,321 掃引で res<1e-13、厳密離散解
  (h2f/2)(i+1)(N−i) と 8.5e-11 一致(PR④ との合わせ技で「Poisson が解ける」を実証)
  ②TB4 での sum 保存 4.6e-16 ③回帰ゼロ(15 変種+4例)

残(V2): カーネル内からの参照(真の CFL 適応 dt)。カーネル IR に実行時スカラー
命令(LoadScalar)を足し、`double :: dt = ...` を navi 由来の実行時値にできるように
する必要がある。

### これで開くもの

Poisson 系(反復+収束判定)経由の非圧縮流体(V1 で可)、オンライン診断(V1 で可)、
Euler/MHD の適応 dt(V2 で解禁)。formura-egison 側は `boundary`/`reduces` を
fmrgen のテンプレートに透過させるだけで済む。

## formura-egison 側の追随

- fmrgen: 境界宣言・reduce をテンプレート/プリンタに透過
- examples: Euler(Sod)を「固定 λmax 版 → reduce 版」の before/after で並べ、
  論文の動機づけ(なぜ本体拡張が要るか)を実測で示す
