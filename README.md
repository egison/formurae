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
| `examples/maxwell3d/` | Maxwell 方程式(ε 縮約による curl、2段更新) |
| `formura-patch/` | Formura 2.3.2 → GHC 9.6.7 移植パッチ(6ファイル) |
| `mpistub/mpi.h` | 1ランク実行用 MPI スタブ(自己メッセージを FIFO マッチング) |
| `setup.sh` / `Makefile` | ビルドとエンドツーエンド実行の自動化 |

各 example の `*.fmr` は生成物だが、出力例として追跡対象にしている(`make` で再生成される)。

## 仕組みの要点

- **場の表現**: `def u := function (x, y, z)`(抽象関数)。格子参照は
  `substitute [(x, x + hx)] u` が生む未解釈適用 `u (x + hx) y z` として現れる。
- **プリンタ**: 正規化された数式を `mathValue` マッチャ(`poly`/`term`/`func`/`symbol`)で分解し、
  適用引数から `(引数 − 座標)/h` でオフセットを有理数として逆算して `u[i+1,j,k]` に写す。
  半整数オフセット(`1/2`)も扱えるため、**Yee 格子などスタガード配置に拡張可能**。
- **テンソル**: `Vector MathValue` 等の型注釈でテンソルごと受け取り(λ⊗ のスカラー/テンソルパラメタ)、
  `ε`・`generateTensor`・添字縮約は Egison 標準ライブラリをそのまま使う。

## 検証結果(Apple Silicon Mac、1コア)

- **拡散 3D**(100³ 格子 × 100 step、temporal blocking 5): 実行 0.19 秒。
  質量保存の相対誤差 **6.4×10⁻¹³**(機械精度)、ピーク 1.0 → 0.2385(正しい拡散減衰)。
- **Maxwell**(128×16×16、dt = 0.1dx、100 step): エネルギードリフト 0.33%、
  パルスは Poynting 方向(+x)へ伝播。生成式は手計算の curl と符号・係数一致。

## 制約と既知の問題

1. **境界条件**: Formura 2.x は実質周期境界のみ。物理境界は方程式内のマスクかドライバ側で扱う。
2. **大域リダクションなし**: CFL による動的 dt などは書けない(固定 dt)。
3. **Formura 2.3.2 の temporal blocking は袖幅2ステンシルで halo を誤処理する**(確定):
   Maxwell を dt = 0.4dx(中立安定域)で TB4 と組み合わせた場合のみ発散。TB なしでは有界。
   同一の生成 C を MPI スタブと Open MPI 5(シングルトン)の両方で実行して全桁一致で
   発散が再現したため、通信層ではなく TB 実装のバグと切り分け済み(2026-07-07)。
   dt = 0.1dx では誤差が 1e-9 程度に隠れるので注意。付属例は全て袖幅1で無事。
   Yee スキーム(袖幅1)なら構造的に回避できる。上流への最小再現の報告は今後の課題。
4. プリンタの対応範囲は「多項式 + 格子参照 + 記号」。extern 関数適用や if 式は未対応
   (現状 init はテンプレート文字列で記述)。

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

- Yee-FDTD(E/B 半整数配置 + leapfrog)の糖衣を `fmrgen.egi` に追加し、Maxwell の正式ターゲットに
- λ⊗ 型システムによる生成前の添字整合性検査(「連続の数式からの検証つきコード生成」)
- MHD・Navier-Stokes 等、`sample/` にある実戦級 Formura コードの Egison 記述への巻き上げ
- 実 MPI・複数ランクでの動作確認と、上記 3. の切り分け
