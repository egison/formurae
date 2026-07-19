# k ≥ 2 の SBP 境界閉包の構成器

## 現状(v2.17)

`Formurae.Post.Stencil` の `sbpStaggeredPair` は内部 2 次(k = 1)のみを
閉形式で構成する: D⁺ は閉包不要、D⁻ は両端 1 行の片側行 (q₁ − q₀)/h、
H_p = h·[1/2, 1, …, 1, 1/2]、H_d = h·I、外挿 d₀ = (3/2, −1/2)。
`validateSbpStaggeredPair` は**任意の閉包データ**に対して有限 N で
SBP 恒等式 H_d D⁺ + (H_p D⁻)ᵀ = d_N e_Nᵀ − d₀ e₀ᵀ・境界次数・外挿精度・
ノルム正値・「2 階閉包 = D⁻D⁺ 合成」を厳密検査できる(k に依存しない)。
k ≠ 1 の要求は `UnsupportedSbpInterior` を返す。

## 欠けているもの

内部 4 次(k = 2、stage = ±9/8 ∓1/24)以上の境界閉包。両方向とも閉包が要る
(D⁺ も境界 2〜3 行が領域外を読む)点が k = 1 と違う。

## 設計案

閉包係数・境界 H 重み・外挿ベクトルを未知数とする**連立一次系の厳密解**で
構成する。鍵は Q⁺ = H_d D⁺、Q⁻ = H_p D⁻ を直接未知数に取ると、
精度条件(Σ_j Q_{ij} x̂_j^p − H_i p x_i^{p−1} = 0)と SBP 恒等式
(Q⁺ + (Q⁻)ᵀ = 境界 rank-2)が **(Q, H, d) に対して線形**になること。
既存の exact RREF(`solveUnique`)がそのまま使える。自由パラメータが残る
(SBP 閉包は一意でない)ので、正準化規則(遠い係数から 0 に固定、など)を
決めて `centeredTaylor` の radius 探索と同様の探索ループにする。
有理数で閉じない最適化族(スペクトル最小化系)は採らない。

## 差し込み口(v2.20 の boundary 宣言後)

- `fec/src/Formurae/Post/Stencil.hs`: `sbpStaggeredPair` の k=1 分岐を
  一般構成に置換。検証器・`SbpStaggeredPair` 型・`SbpBoundaryRow` は不変。
- `fec/src/Formurae/Post/Compile.hs` `lowerSbpGuardedDerivative`:
  閉包行リストを既にループで guard 化しているので、行数が増えても変更不要
  のはず(要確認: 2 階の interior [1,−2,1] 固定箇所を pair 由来に置換)。
- 表層は**新しい綴り不要**([boundary-declaration.md](boundary-declaration.md)
  の因数分解どおり): sbp 軸ではプライム幅・profile accuracy が今は
  `SbpClosureUnavailable` / `SbpProfileClosureUnavailable` の明示エラーに
  なっているので、構成器が入り次第そのエラー分岐を k = radius(または
  accuracy/2)の閉包呼び出しへ差し替えるだけで「幅 × 境界」の積が全域で
  定義される。attribute 追加も不要(order/radius の既存 3 つ組で足りる)。

## 完了条件

- 単体: k=2 の対が `validateSbpStaggeredPair` を複数 N で通過。
- E2E: sbp_diffusion1d の accuracy-4 版で大域 3 次以上の実測収束
  (境界 s=2/内部 4 の定石で s+2)+エネルギー単調。
