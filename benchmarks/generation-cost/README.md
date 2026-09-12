# 生成コストの測定

`measure.py` は，代表的な 6 例（`diffusion3d`，`maxwell_dec`，`elastic3d`，`mhd_ot`，
`transformation_optics`，`elastic_pulse`）について，生成の各段階
（`formurae-pre`，Egison の正規化，`formurae-post`，Formura，C コンパイル）を
それぞれ 1 つのツールプロセスとして 3 回ずつ起動し，`/usr/bin/time -l` の実時間と
最大常駐メモリ，生成した Formura ソースと C の行数を記録する．
Haskell のプロセスは重ねて起動しない（すべて直列）．

```sh
python3 benchmarks/generation-cost/measure.py        # EGISON_DIR で Egison の場所を指定できる
cp .build/generation-cost/generation-cost.json benchmarks/generation-cost/results.json
```

各ツールは `cabal list-bin` で得たバイナリを直接起動する（`formurae_datadir`，
`egison_datadir` を設定して `cabal run` と同じデータファイルを参照させる）．
`diffusion3d` については `tools/run_formurae_normalization.sh`（`cabal run` 経路）の
出力とバイト一致することも記録する（`direct_binary_matches_cabal_run`）．

`results.json` は 2026-09-12 の測定（Apple M5，Apple clang 17）で，
論文 formurae-paper の表 5 の元データである．
