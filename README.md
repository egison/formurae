# formura-egison

Egison のテンソル添字記法で書いた偏微分方程式から、
[Formura](https://github.com/formura/formura)(村主崇行氏らによるステンシル計算 DSL)のソースを生成し、
MPI + temporal blocking つきの高速な C コードに落とすための実験リポジトリ。

**結論(2026-07-06 調査): 実装可能。両処理系を無改造のまま、Egison スクリプト約130行で接続できることを実証済み。**

```
Egison   : 連続系の方程式(テンソル添字記法、物理は2〜3行)
   ↓        差分化コンビネータ(substitute による座標シフト)
   ↓        mathValue マッチャによる .fmr プリンタ
Formura  : .fmr → C ライブラリ(MPI 通信・temporal blocking を自動生成)
   ↓
C コンパイラ + ドライバ → 実行
```

Maxwell 方程式の場合、Egison 側の物理記述はこれだけ:

```egison
def En := E + dt * curl B      -- E' = E + dt ∇×B
def Bn := B - dt * curl En     -- B' = B − dt ∇×E'
```

curl はライブラリ内の1行定義(Levi-Civita テンソルとの Einstein 縮約):

```egison
def curl (X: Vector MathValue) : Vector MathValue :=
  withSymbols [i, j, k] (ε 3)~i~j~k . (dGrad X)_j_k
```

ここから6本の更新式が全自動で展開される(生成物の1本):

```
Ey' = Ey[i,j,k] + Bz[i-1,j,k]*dt/(2*dx) + (-1)*Bz[i+1,j,k]*dt/(2*dx)
    + (-1)*Bx[i,j,k-1]*dt/(2*dz) + Bx[i,j,k+1]*dt/(2*dz)
```

## クイックスタート

前提: GHC 9.6 系 + stack(Formura 用)、`../egison` に Egison 開発ツリー
(インストール済みの egison バイナリは同梱数学ライブラリが古いため不可)。
MPI は不要(1ランク用スタブ `mpistub/mpi.h` を同梱。実 MPI があればそちらでも可)。

```sh
make setup        # Formura 2.3.2 を clone + GHC 9.6 パッチ適用 + ビルド → bin/formura
make diffusion3d  # 生成 → Formura → cc → 実行(質量保存を検査)
make maxwell3d    # 生成 → Formura → cc → 実行(エネルギー保存・伝播を検査)
```

## リポジトリ構成

| パス | 内容 |
|---|---|
| `lib/fmrgen.egi` | 生成ライブラリ: `shift`/`dC`/`dC2`/`lap`/`dGrad`/`curl`/`divg` + .fmr プリンタ |
| `examples/diffusion3d/` | 3D 拡散方程式(物理は `u + dt*kappa*lap u` の1行) |
| `examples/maxwell3d/` | Maxwell 方程式(ε 縮約による curl、2段更新、collocated 格子) |
| `examples/maxwell3d_yee/` | **Yee-FDTD**(E=辺・B=面のスタガード格子+leapfrog。場ごとの配置オフセット宣言から教科書どおりの FDTD を生成) |
| `examples/pearson3d/` | **Formura 論文の看板シミュレーション再現**(菌根菌 mycorrhiza の Pearson 反応拡散系。FHPC'16 と同じ方程式・パラメタ。自己複製スポットパターンが創発) |
| `examples/burgers3d/` | **Burgers 方程式**(Cole–Hopf 厳密解と直接比較 — 非線形項生成の機械検証) |
| `examples/cahnhilliard3d/` | **Cahn–Hilliard**(4階微分を中間場 μ の2段構成で。質量は `reduces` 経由で監視) |
| `examples/tdgl3d/` | **TDGL 超伝導**(\|ψ\|⁴ 理論。量子化渦の自発形成) |
| `examples/mhd_ot/` | **理想 MHD: Orszag–Tang 渦**(保存形+Rusanov 流束を中間流束場19本で生成。8保存量を `reduces` で監視) |
| `examples/elastic3d/` | **弾性波(Virieux スタガード格子)**(速度3+応力6のテンソル場。yeeRef 機構で P/S 両波速を1回で実測) |
| `formura-patch/` | Formura 2.3.2 → GHC 9.6.7 移植パッチ(6ファイル) |
| `mpistub/mpi.h` | 1ランク実行用 MPI スタブ(自己メッセージを FIFO マッチング) |
| `setup.sh` / `Makefile` | ビルドとエンドツーエンド実行の自動化 |
| `figures/` | 論文図版のデータ生成(`gen.sh` → `out/*.dat`: Yee パルス断面・エネルギー時系列4種) |
| [`APPLICATIONS.md`](APPLICATIONS.md) | 応用カタログ(16 テーマ: MHD・弾性波・LBM・Cahn–Hilliard 等、検証方法つき) |
| [`UPSTREAM.md`](UPSTREAM.md) | Formura 本体への拡張計画(GHC 移植 PR・TB バグ修正・境界条件・大域リダクション) |

各 example の `*.fmr` は生成物だが、出力例として追跡対象にしている(`make` で再生成される)。

## 仕組みの要点

- **場の表現**: `def u := function (x, y, z)`(抽象関数)。格子参照は
  `substitute [(x, x + hx)] u` が生む未解釈適用 `u (x + hx) y z` として現れる。
- **プリンタ**: 正規化された数式を `mathValue` マッチャ(`poly`/`term`/`func`/`symbol`)で分解し、
  適用引数から `(引数 − 座標)/h` でオフセットを有理数として逆算して `u[i+1,j,k]` に写す。
  半整数オフセット(`1/2`)も扱える。
- **スタガード格子**: 場を「(抽象関数, 配置オフセット σ∈{0,½}³)」の組で表し、参照時に
  「変位 + 対象の σ − 参照場の σ」で配列オフセットを解決する(`yeeRef`/`dYee`/`curlYee`)。
  Yee 配置なら curl の全項が整数オフセット(袖幅1)に落ちる。
- **テンソル**: `Vector MathValue` 等の型注釈でテンソルごと受け取り(λ⊗ のスカラー/テンソルパラメタ)、
  `ε`・`generateTensor`・添字縮約は Egison 標準ライブラリをそのまま使う。

## 検証結果(Apple Silicon Mac、1コア)

- **拡散 3D**(100³ 格子 × 100 step、temporal blocking 5): 実行 0.19 秒。
  質量保存の相対誤差 **6.4×10⁻¹³**(機械精度)、ピーク 1.0 → 0.2385(正しい拡散減衰)。
- **Maxwell**(128×16×16、dt = 0.1dx、100 step、修正版コンパイラ): エネルギードリフト
  **4.8e-5**・パルス伝播 **+9.9 セル(理想 +10)**。2ランク実 MPI ではパルスがランク境界を
  完全に通過(送り側ランクは 1e-23 まで排出)し大域エネルギー保存 4.8e-5。
  生成式は手計算の curl と符号・係数一致。(旧値 0.33% は既知問題③の破損込みの数値)
- **Yee-FDTD**(128×16×16、dt = 0.5dx、100 step、TB4): 実行 0.13 秒。
  エネルギードリフト 0.10%、パルス伝播 +49.9 セル(理想 +50)、
  **div B ≡ 0(機械精度で恒等)**。20行の 1D リファレンス実装とパルス位置が
  全桁一致(113.68)。temporal blocking あり/なしがビット一致。
- **Pearson 反応拡散(Formura 論文 Listing 1 の再現)**(64³、dt = 200s、40,000 step、TB4):
  実行 78 秒。FHPC'16 と同一の方程式・パラメタ(Fu=1/86400 等)。値は範囲内・NaN なし・
  V コロニーが自己複製し、論文 Figure 7 と同じ Gray-Scott スポットパターンが創発。
  物理の記述は2行で、`lap` は拡散例と同一コンビネータ。
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

## 制約と既知の問題

1. **境界条件**: Formura 2.x は実質周期境界のみ。物理境界は方程式内のマスクかドライバ側で扱う。
2. **大域リダクションなし**: CFL による動的 dt などは書けない(固定 dt)。
3. **[根治済 2026-07-08] 混在ステンシル半径の誤コンパイル**(当初「TB の袖幅2バグ」と
   誤診していたもの): 真因は mkKernel の per-node range。出力は生添字に書かれ、入力中心は
   ノードごとの range オフセットで再センタリングされるため、更新式の半径が変数間で異なると
   変数ごとに毎ステップの配列内シフト量が食い違い、**temporal blocking なしでも 2 ステップ目
   から相互参照がずれる**(TB は増幅するだけ)。最小再現は 2 変数各 1 行
   (upstream/tb-repro/reproG.fmr)。fork の fix-mixed-radius-drift(de9b623)で修正済み:
   出力ノードの range をグローバル (−s,+s) に統一。検証 = 閉形式解と 2.7e-15 一致・
   15 変種で TB≡NB ビット一致・collocated Maxwell のパルスが 1D リファレンスと一致
   (エネルギードリフト 0.33%→4.8e-5)。
4. プリンタの対応範囲は「多項式 + 格子参照 + 記号」。extern 関数適用や if 式は未対応
   (現状 init はテンプレート文字列で記述)。
5. **ドライバの注意**: Formura は `Formura_Forward` のたびに配列内でデータを平行移動させる
   ことがある(仕様。特に非対称ステンシルで毎ステップずれる)。座標が要る計測・出力は
   必ず `to_pos_x/y/z` を使うこと。生の配列添字で位置を測ると伝播速度を誤る
   (maxwell_yee_check.c で実際に踏んだ罠)。
6. **[解消済 2026-07-08] per-variable cursor の不整合は上記③の症状だった**: 修正後は
   全変数が一様に(sleeve/step だけ)ドリフトするため、`to_pos_*` が全変数に対して正しい。
   デルタ応答テスト(1点インパルス→1ステップ→応答位置)は、生成コードのレイアウトを
   実測する診断手法として引き続き有用(このバグを最初に暴いたのもこれ)。

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
