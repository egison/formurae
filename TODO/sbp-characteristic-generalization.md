# 特性 SAT の一般化 — インピーダンス Z・2D 法線・幅整合の外挿

## 現状(v2.22)

- 透過境界は sbp_wave_open が **Z = 1・1D** の特性 SAT を表層で明示:
  左壁 `sbpHinvX*(p + sbpx_x v')`・右壁 `sbpHinvX*(p - sbpx_x v')`。
  エネルギー法で dE/dt = −2p₀² − 2p_N² が厳密に閉じ、実測で E は初期値を
  一度も超えない。特性 SAT は方程式内容(向き・インピーダンス依存)なので
  意図的にマクロ化していない。
- 境界外挿 `sbpx_a e`(opaque `boundary.sbp-trace`)は**最小対(k = 1)固定**。
  ワイヤには radius 属性を確保済みで、radius ≥ 2 は
  `SbpTraceUnsupportedRadius` の明示エラー。構成器
  (`sbpStaggeredPair k`)は全 k の外挿ベクトル d₀ を既に持っている。
- `satNeumann_a`/`satDirichlet_a` マクロと注入定数 `sbpHinvA` は最小対を参照
  (幅つき定数 `sbpHinv<2k>A` は注入済みだがマクロは使わない)。

## 欠けているもの

1. Z ≠ 1(音響なら Z = ρc)の特性 SAT と、その 1 例題。
2. 2D の面ごとの特性 SAT(法線速度 v_n)と角の実測確認。
3. k ≥ 2 スキームでの SAT: エネルギー恒等式は**使っている対の d₀**で
   閉じるので、k = 2 の flux モデルの Neumann/特性 SAT には k = 2 の外挿
   (d₀ = (15/8, −5/4, 3/8))と `sbpHinv4A` の**組**が要る。今は組めない
   (sbpx が k = 1 固定)。

## 設計判断(着手前に決める)

1. **sbpx の幅の綴り**: プライム(`sbpx'_x`)は不可 — 表層トークナイザが
   末尾 `'` を next-step マーカとして識別子を切る(∂' が動くのは ∂ が
   トークン化前に transliterate されるためで、ASCII 名には効かない)。
   **数字サフィックス `sbpx4_x` を推奨**(注入定数 `sbpHinv4X` と同じ
   命名系)。ワイヤは既存 radius 属性のままで良い。
2. **マクロと幅の結合**: マクロは flux 式がどの幅で作られたか知り得ない
   (幅は式の中の演算子綴り)。定数と同じ方針で、**検出した幅ぶんの
   `satNeumann4_a` 系(幅サフィックス族)を生成するのを推奨**。代替の
   「trace と hinv を引数で渡す」は定型性が薄れる。
3. **Z 付き特性のマクロ化はまだしない**: 例題 2〜3 本で形が安定するまで
   表層明示のまま。エネルギーノルムの重み(1/K・ρ)と係数への c/Z の
   入り方を、まず Z ≠ 1 の 1 例題で実測込みで確定する。
4. **2D は新機構ほぼ不要の見込み**: v_n は成分射影(v2.18)+ sbpx で
   `sbpHinvX*(p + sbpx_x v_x)` と書け、角は sbp_diffusion2d と同じ
   「両面ペナルティの加法」で成立するはず。判断は「第一階系の角の
   エネルギー減衰の実測確認」のみ。格子非整合の曲がった境界は
   この因数分解(境界=軸の属性)の対象外と明記する。

## 差し込み口

- `Formurae.Post.Compile.lowerSbpTrace`: radius ゲートのエラー分岐を
  `sbpStaggeredPair radius` の `sbpExtrapolate` 参照に差し替えるだけ
  (構成器側は変更不要)。
- `Formurae.Pre.Parse`: `sbpxOpParts` の数字サフィックス対応
  (Index.hs)と、`boundaryPreludeMacros`/`pairCounts` 検出の幅つき
  マクロ生成。
- 例題: sbp_wave_open の変種(Z ≠ 1)と 2D 版(角つき)。

## 完了条件

- Z ≠ 1 の 1D 透過例題と 2D 透過例題(角つき)がエネルギー減衰+収束
  実測つきで examples に入る。
- k = 2 の Neumann(または特性)例題が幅整合の外挿・定数で書け、
  熱量保存(または無成長)が最小対の例題と同水準で成立する。
