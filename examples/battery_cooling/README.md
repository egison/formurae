# 円筒型電池：熱伝導モデルと冷却面の比較

軸方向に発熱が集中した円筒型電池の巻回部を，半径 r と軸方向 z の二次元で表す．
25 °C の冷却媒体に対して，等方的な熱伝導と方向依存の熱伝導，側面と端面の冷却を比較する．
中央の温度上昇が周囲へ広がる過程を，400 秒間の実際の計算結果から動画にする．

- 巻回部は内半径 2 mm，外半径 9 mm，長さ 65 mm の円筒環．内側は断熱．
- 体積熱容量は 2 MJ/(m³ K)，半径方向の熱伝導率は 0.5 W/(m K)．
- 等方モデルの軸方向の熱伝導率は 0.5，異方モデルでは 10 W/(m K)．
- 発熱は Q(z) = 100000 [1 + 4 exp(−(z−0.0325)²/0.0001)] W/m³．
- 冷却面は熱伝達率 50 W/(m² K)，それ以外は断熱．初期温度は一様に 25 °C．

これらはモデル比較用の値であり，特定の電池の測定データへの適合結果ではない．
電気化学反応は解かず，指定した発熱に対する熱伝導を計算する．
巻かれた電極による熱伝導の方向依存性は，例えば
[COMSOL の円筒型電池の熱解析モデル](https://doc.comsol.com/6.3/doc/com.comsol.help.models.battery.li_battery_thermal_2d_axi/li_battery_thermal_2d_axi.html)
にも取り入れられている．

## 自分で定義する演算子

`conductivity` は軸方向 a の材料テンソル K^{ij} = k_r g^{ij} + (k_z−k_r) a^i a^j．
`heatFlux U` はこのテンソルと温度勾配の縮約 K^{ij} ∂_j U を返す．
物理的な熱流束の符号はその逆である．

```
def axis = [| 0, 1 |]~i
def conductivity = withSymbols [i, j] (radial * g~i~j + (axial - radial) * axis~i * axis~j)
def heatFlux U = withSymbols [i, j] (conductivity~i~j . ∂_j U)
```

温度上昇 T は，ρc ∂t T = r⁻¹∂r(r k_r ∂r T) + ∂z(k_z ∂z T) + Q に従う．
場は整数位置，流束の各成分はその方向に半格子ずれた位置に置く．
`boundary … : sbp` は離散的な部分積分が成り立つ差分を指定する．
`satNeumann` で端の流束を置換し，外向きの熱流束 hT を課す．
円筒座標の体積要素 2πr と端点の重みを含めた熱量，投入熱，除去熱，その収支も `.fme` で計算する．

## 実行・結果

リポジトリ直下で `python3 examples/application_demos/run.py battery_cooling`．
動画生成・検証を含む共通手順は [application_demos](../application_demos/README.md) を参照．

[比較画像](../application_demos/results/battery_cooling/comparison.png) ／
[比較動画](../application_demos/results/battery_cooling/comparison.mp4) ／
[最高温度・温度むら](../application_demos/results/battery_cooling/measurements.png) ／
[検証結果](../application_demos/results/verification.json)．

標準は 33×97 点，Δt = 0.01 s．検証は，一様な断熱加熱の厳密解，熱収支，
65×193 点・Δt = 0.0025 s への細分化，時間方向のブロッキングと各軸の MPI 分割を対象とする．
