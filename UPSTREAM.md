# Formura 本体への拡張計画(upstream ロードマップ)

Egi は GitHub の formura organization メンバーであり、formura/formura に直接
PR/push できる。本ファイルは「issue を立てて待つ」のではなく**自分たちで本体を
更新する**前提の作業計画。小さい PR に分割して出す。

## PR 分割案(依存順)

| PR | 内容 | 規模感 | 状態 |
|---|---|---|---|
| 1 | GHC 9.6 移植(formura-patch/formura-ghc96.patch そのまま) | 小(6 ファイル) | パッチ済・出すだけ |
| 2 | temporal blocking の袖幅≥2 halo バグ修正 | 中 | 最小再現から着手 |
| 3 | per-variable cursor の API 整合(offset の変数別公開) | 小〜中 | 設計済(下記) |
| 4 | 境界条件(mirror / fixed) | 中 | 設計済(下記) |
| 5 | 大域リダクション(まず NoBlocking 限定 → TB 対応) | 中〜大 | 設計済(下記) |

前提知識: コンパイルパイプラインは
`.fmr + .yaml → Parser/Desugar → OMProgram(データフローグラフ、非局所命令は
Shift のみ)→ MMProgram(manifest ノード+cursor)→ C 生成(halo 交換・
ブロックループ・カーネル)`。1.x の設計論文は FHPC'16 §2.3。

## PR 2: TB 袖幅≥2 バグ

- 再現: 袖幅 2 のステンシル(collocated Maxwell の dt² 項、または人工的な
  `a[i+2]` 参照)+ `temporal_blocking_interval ≥ 2` で、非ブロック実行と比較。
  dt を中立安定限界近くに置くと指数発散として顕在化する(examples/maxwell3d、
  README 既知問題③)。安定領域では 1e-9 級の差として潜伏するため、
  **ビット比較**を判定に使う(TB on/off で一致すべき)。
- 当たり: 袖の消費計算(Annotation/Boundary.hs の Boundary 合成)か、
  TB の wall/floor バッファ充填(Generator/Templates.hs)での
  「ステップあたり袖消費 = 1」を仮定した箇所。radius-1 の同梱例では露見しない。
- テスト: radius-1/2 × TB on/off の 4 通りをビット比較する回帰テストを test/ に追加。

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

### これで開くもの

Euler/MHD の実用運転(適応 dt)、Poisson 系(反復+収束判定)経由の非圧縮流体、
オンライン診断。formura-egison 側は `reduce` を fmrgen に透過させるだけで済む。

## formura-egison 側の追随

- fmrgen: 境界宣言・reduce をテンプレート/プリンタに透過
- examples: Euler(Sod)を「固定 λmax 版 → reduce 版」の before/after で並べ、
  論文の動機づけ(なぜ本体拡張が要るか)を実測で示す
