# TODO — 将来課題の索引

将来課題を 1 テーマ 1 ファイルでまとめる。各ファイルは
「現状 / 欠けているもの / 設計判断(または設計案)/ 差し込み口 /
完了条件」を持ち、この会話文脈なしで着手できることを目標にする。
実装が終わった課題のファイルは削除し、経緯は DSL-DESIGN.md の
バージョン記録に残す。

| ファイル | 課題 | 規模感 |
|---|---|---|
| [sbp-characteristic-generalization.md](sbp-characteristic-generalization.md) | 特性 SAT の一般化(Z・2D 法線・幅整合の外挿) | 中(綴りの決めから) |
| [boundary-yaml-consistency.md](boundary-yaml-consistency.md) | yaml boundary と宣言の整合検査 | 小(独立チェッカ) |
| [component-projection-extensions.md](component-projection-extensions.md) | 混合射影・一般式射影・宣言レベル component | 小〜大(3 段階) |
| [time-staggering-declaration.md](time-staggering-declaration.md) | 時間方向スタガードの宣言化 | 小(調査から) |

済(ここには置かない): 3 階以上の staggered profile 則(v2.16 で全次数化)、
スタガード奇数階の幅指定(v2.15)、境界片側化の Phase 0–3(v2.17)、
成分射影の基本形(v2.18)、境界の言語化=boundary 宣言と sbpd 退役
(v2.20)、k ≥ 2 の SBP 閉包構成器(v2.21)、SAT の定型化=宣言供給定数・
境界外挿 sbpx・satDirichlet/satNeumann マクロ(v2.22)。
