# 境界条件の言語化(宣言 → SAT 導出)

## 現状(v2.17)

境界の实体は 2 箇所に分かれている:
- yaml `boundary: [fixed g, periodic, …]`(fork のランタイム境界 = ghost 充填)
- .fme 内の SBP 演算子(`sbpd`/`sbpd2`)+手書き SAT(表層 if)

コンパイラは境界条件を**知らない**。SBP 閉包は「どの端も物理境界」と
仮定して両端に guard を出し、SAT の正しさ(符号・係数・エネルギー安定性)は
書き手の責任になっている。

## 欠けているもの

軸ごと・端ごとの境界宣言(例):

```
boundary x : dirichlet 0.0, dirichlet 0.0
boundary y : periodic
```

から (1) sbpd の閉包 emit を端ごとに on/off(periodic 端は interior のまま
wrap を使う)、(2) SAT 項の自動導出(エネルギー安定な符号・係数既定値)、
(3) yaml との整合検査、まで導くこと。

## 設計案と注意

- 宣言は Model → FEIR に新しい宣言種として乗せる必要があり、
  **FEIR スキーマ=ワイヤに触る**(fingerprint 更新・全例題再生成の
  随伴作業つき。v2.17 で経験済みの定番スイープ)。
- SAT 自動導出は「方程式の型」(拡散か波動か)に依存するため、完全自動は
  過剰。現実的なのは「宣言から SAT **項を生成するマクロ**を提供し、
  step 内で明示適用する」中間形(可視性の原則とも整合)。
- periodic 混在軸(y だけ周期)は現状でも yaml + sbpd を y に使わない、で
  実現可能。宣言化の価値は検査(「sbpd を periodic 軸に使った」を静的
  エラーにできる)にある。

## 完了条件

- 宣言つき .fme 1 本(2D、x=Dirichlet/y=periodic)が、手書き SAT 版と
  同一の .fmr を生成すること(バイト比較で定義)。
- sbpd を periodic 宣言軸に適用した場合の静的エラー。
