# 演算子を変更する三つの応用デモ

数式で定義した演算子が，材料モデルや装置の比較にどう役立つかを示す．
共通の [日本語 gallery](../../html/ja/gallery.html#application-demos) と
[English gallery](../../html/en/gallery.html#application-demos) に掲載する．

| デモ | 変更する定義・条件 | 観察する量 |
|---|---|---|
| [複合材の超音波](../composite_ultrasound/README.md) | 材料テンソルの繊維方向と局所的な剛性低下 | 波面，受信波形 |
| 場の回転子 | 座標変換の回転角と材料層の厚さ | 内部の波面，外部の散乱 |
| [円筒型電池の冷却](../battery_cooling/README.md) | 熱伝導テンソルと冷却面 | 最高温度，温度むら，熱収支 |

## 実行

Egison・Formura・Formurae が既存の例題を実行できる環境で，リポジトリ直下から実行する．
Python の描画には numpy・matplotlib，動画には ffmpeg を使う．

```
make application-demos PLOT_PYTHON=/path/to/python-with-numpy-and-matplotlib
```

`run.py` は三つの処理系を直列に起動する．初期条件，境界処理，更新式と物理量の計算は
すべて `.fme` にあり，生成した Formura ソースを既存の Formura へ渡して C を生成する．
C ドライバは生成された初期化・更新関数の呼び出しと出力だけを行う．
Python はパラメータ・格子設定，起動，出力の比較，描画を担当する．
パラメータが記号のまま通る正規化結果は同じソースで共有し，Formura への入力時に値を設定する．
`--fresh` は新しい二つの例について正規化も再実行する．

各工程を個別に再実行できる．

```
python3 examples/application_demos/run.py battery_cooling
python3 examples/application_demos/run.py composite_ultrasound
python3 examples/application_demos/run.py optics_design
make application-demos-verify
make application-demos-render PLOT_PYTHON=/path/to/python
make application-demos-gallery
```

MPI 検証には `mpicc` と `mpirun` を使う．環境に応じて `MPIRUN_ARGS` を設定する．
生の計算出力は `.build/application_demos/`，画像・動画・CSV・実行条件と検証結果は `results/` に保存する．
動画は途中時刻に保存した場から作る．最初と最後の画像の補間ではない．
`gallery.py` は検証結果と生成済みの画像・動画・ソースを読み，日英の同じ三つのカードを更新する．

## 場の回転子の比較

[既存の変換光学モデル](../transformation_optics/README.md)を同じ生成経路で実行する．
外側の半径 R2=2 を固定し，回転角を 0°，22.5°，45° と変える．4 番目は内側の半径 R1 を
1 から 0.5 に減らし，材料層を厚くした 45° の回転子．外側の散乱は全条件で r>2.5 の
同じ領域から求める．回転させる内側領域の大きさも変わるため，厚さだけを独立に変えた比較ではない．

`rotated` は φ'=φ+twist(R2−r)/(R2−R1) に対応する座標変換．
`rotatedJacobian` はその解析的微分，`rotatedMetric` は微分の積を縮約した計量．
この材料テンソルを使った Maxwell 方程式を直交格子上で解く．
標準の 240×180 点，Δt=0.1Δx，t=10 までを比較する．
材料は理想化した連続体で，製造用の微細構造を設計する計算ではない．
座標変換による回転子の背景は [Chen・Chan (2007)](https://arxiv.org/abs/physics/0702050) を参照．

[比較画像](results/optics_design/comparison.png) ／ [比較動画](results/optics_design/comparison.mp4) ／
[散乱とエネルギー](results/optics_design/measurements.png) ／ [検証結果](results/verification.json)．

## 出力の読み方

`results/<demo>/<case>.csv` は生成された計算プログラムの集計値をそのまま保存する．
同名の `.fme` と `.yaml` はその条件の実際の入力で，`runs.json` に格子・実行条件・ソースのハッシュを記録する．
電池の `uniformError` は断熱・一様発熱の検査，超音波の `modeError` は `mode=1` の平面波検査に用いる補助場で，
通常の比較デモで出力される `error` 列は精度の指標としては使わない．
画像・動画の各パネルは共通の色尺度を使い，測定値は保存された集計値から描く．
