# 最新 Egison の型検査への対応

## 現状

Formurae の通常の変換経路は、Egison の対応版
`1a0298c67cc487dd4a73d96f526f3042b74d6570` を用いて検証する。
`tools/prepare_elastic_validation.sh` がこの版を `.build/` に展開する。
2026-09-10 に隣接する Egison の `dcffa386` で `make compiler-tests` を実行すると、
Formurae 側の37件の検査後、Egison を使う結合検査が以下の診断で停止した。

```text
In expression: vi..._i
Unsupported feature: recursive definition 'vi' must have a lambda or matcher literal at its root
```

9月8日の `examples/elastic_curvilinear/README.md` にも、最新 Egison との
不一致と対応版の固定が記録されている。専用実行経路の削除とは分けて扱う。

## 欠けているもの

最新 Egison の型検査に対して、ライブラリの定義と生成する Egison コードを
対応させる必要がある。最初の診断だけで全体の不一致を把握したとは扱わず、
テンソルの添字、利用者定義演算子、解析的微分、局所中間値を含む検査を確認する。

## 設計方針

既存の数式の表現力と検査を維持し、型検査を通すための検査省略や機能削除は行わない。
必要な修正をライブラリ・生成コード・Egison 本体に切り分け、原因に対応する箇所を直す。
対応版の固定は再現のための依存指定であり、異なる実行経路を追加する理由にはしない。

## 差し込み口

- `lib/formurae-tensor.egi` などの正規化ライブラリ。
- `src/Formurae/Pre/EmitEgison.hs` の定義・初期化・局所中間値の出力。
- `spec/egison-normalization.list` と `tools/run_formurae_normalization.sh` の読み込み順序。
- `tools/run_egison_machine.sh` の厳密な型検査付き実行。
- `tests/compiler_suite.sh` と `tests/pre_pipeline.sh` の結合検査。

## 完了条件

1. 最新 Egison を指定した `make compiler-tests` が、既存の検査を削らずに通る。
2. `make all` で既存例を通常の Formura 経路からコンパイルし、数値検査が通る。
3. README と再現手順の依存指定を、検証済みの新しい版へ統一する。
4. 完了後、このファイルを削除し、TODO の索引と DSL-DESIGN.md に結果を反映する。
