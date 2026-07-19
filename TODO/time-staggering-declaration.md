# 時間方向スタガードの宣言化

## 現状

leapfrog / Yee の時間半歩ずれは**更新順序で運用的に**表現している
(例: sbp_wave1d は `v' = v − dt ∂_x p` を先に置き、`p' = p − dt(… v' …)` が
更新後の v' を読むことで時間スタガードを実現)。placement 語彙
(collocated/primal/dual)は空間のみで、時間軸の半歩は宣言に現れない。

## 課題

- 意味が「式の並び順」という暗黙情報に載っており、並べ替えると
  静かに別のスキーム(前進 Euler 連立)になる。透明性の原則に照らすと
  宣言で固定したい。
- 例: `field v : scalar @ dual, time half` のような時間占位の宣言と、
  「half-time の場は同 step 内で更新済みの値を読む」規則の明文化+検査
  (v' を読み忘れて v を読んだら警告、など)。

## 進め方

まず調査から: 既存例(maxwell3d_yee・acoustic3d・sbp_wave1d)の時間
インターリーブをパターンとして分類し、宣言 1 個で表せる範囲を確定する。
実装は Model の field 宣言拡張+emit の参照検査のみで、FEIR/placement
機構には触れない見込み(時間 slot は CurrentTime/NextTime が既にある)。
