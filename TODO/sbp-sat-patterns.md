# Neumann・特性 SAT の定型化

> **実装済み(2026-07-19、v2.22)。** 宣言が名前つき定数
> `sbpLoA`/`sbpHiA`/`sbpHinvA`(+使用幅ぶんの `sbpHinv<2k>A`)を供給し、
> 境界外挿は新 opaque `boundary.sbp-trace`(表層 `sbpx_a e`、壁行で
> d₀ᵀ/d_Nᵀ・内部 0)。定型は prelude マクロ `satDirichlet_a(u,g,coef)`・
> `satNeumann_a(flux,glo,ghi)`。例題 = sbp_neumann(断熱壁、熱量ドリフト
> 3.4e-15 の厳密保存+実測 2.04 次)と sbp_wave_open(特性 SAT の透過境界、
> エネルギー無成長+mid-flight 実測 1.98 次+反射残差減衰)。既存 sbp
> 例題 4 本も定数+マクロのイディオムへ書き換え済み(driver 値同一)。
> 特性 SAT は方程式内容なのでマクロ化せず例題で明示(向き・インピーダンス
> 依存)。

## 現状(v2.17)

SAT は新機構なしの表層記述: Dirichlet は
`if x < xlo then 0.0 - satx*u else 0.0`(係数は param、H⁻¹ の 2/h 込み)で
書き、sbp_diffusion1d / sbp_wave1d(pressure-release)/ sbp_diffusion2d が
この形で実測済み。係数・しきい値を param に置くのは dx が CAS 側で
非束縛のため(v2.17 の設計記録参照)。

## 欠けているもの

1. **Neumann**(流束指定): 熱方程式なら境界流束 g を D⁻ の閉包行が読む
   「仮想フラックス」として注入する形が自然だが、現在の閉包降下
   (v2.20 の `lowerSbpGuardedDerivative`)は閉包行を固定で emit するので、
   境界行だけ g で置換/加算する綴りがない。
2. **特性 SAT**(波動系の透過境界): p ± Z v の特性変数への penalty。
   v の境界値が外挿 d₀ᵀv を要するため、**外挿演算子が表層にない**
   (v2.17 で pressure-release を選んだ理由)。
3. 毎回手書きの if 連鎖は誤りやすい(4 辺 × 係数 × 符号)。

## 設計案

- 最小: 境界外挿の opaque 演算子 `sbpx_x e`(SBP 対の d₀/d_N で境界値を
  外挿する index-guarded 式; 内部は 0 か identity かは要設計)を足すと
  特性 SAT が表層で閉じる。
- 中間: SAT を prelude マクロ化(`satDirichlet_x(u, g, τ)` →
  if 連鎖へ展開)。v2.10 の surface macro(let-insertion)機構が使える。
- Neumann は境界フラックスを **boundary 宣言の側**で受けるのが v2.20 の
  因数分解に整合する(per-call 演算子引数は sbpd と同じ取り違えに戻る):
  宣言が名前つき定数(H⁻¹ 端重み・g)を式へ供給し、閉包行への注入は
  `lowerSbpGuardedDerivative` の境界行だけを変える。

## 完了条件

Neumann 拡散(厳密解: 断熱壁のモード)と透過境界の波動 1 例ずつが
エネルギー安定+収束実測つきで examples に入ること。
