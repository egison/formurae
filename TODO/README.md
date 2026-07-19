# TODO — 将来課題の索引

v2.15–v2.18(スタガード半整数半径・profile 全次数化・SBP 境界閉包・成分射影)
の実装時に確定した将来課題を 1 テーマ 1 ファイルでまとめる。各ファイルは
「現状 / 欠けているもの / 設計案 / 差し込み口 / 完了条件」を持ち、この
会話文脈なしで着手できることを目標にする。

| ファイル | 課題 | 規模感 |
|---|---|---|
| [sbp-high-order-closures.md](sbp-high-order-closures.md) | k ≥ 2 の SBP 境界閉包の構成器 | 中(作用素層に閉じる) |
| [sbp-sat-patterns.md](sbp-sat-patterns.md) | Neumann・特性 SAT の定型化 | 小〜中 |
| [boundary-declaration.md](boundary-declaration.md) | 境界条件の言語化(宣言 → SAT 導出) | 大(FEIR スキーマ) |
| [component-projection-extensions.md](component-projection-extensions.md) | 混合射影・一般式射影・宣言レベル component | 小〜大(3 段階) |
| [time-staggering-declaration.md](time-staggering-declaration.md) | 時間方向スタガードの宣言化 | 小(調査から) |

済(ここには置かない): 3 階以上の staggered profile 則(v2.16 で全次数化)、
スタガード奇数階の幅指定(v2.15)、境界片側化の Phase 0–3(v2.17)、
成分射影の基本形(v2.18)。
