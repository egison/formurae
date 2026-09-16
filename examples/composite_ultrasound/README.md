# 複合材の超音波：繊維方向と局所的な剛性低下

均質な材料と，一か所が滑らかに柔らかくなった材料について，繊維方向 0° と 45° の
波の伝わり方と受信波形を比較する．繊維強化された連続体の二次元平面ひずみモデルを用いる．
材料の方向依存性と形状が超音波検査に及ぼす影響は，
[Yu らの複合材の研究](https://doi.org/10.1016/j.ultras.2016.07.016)などで調べられている．
このデモは材料内部を伝わる波のモデル比較を扱う．自由表面，層間の剥離，亀裂の開閉は含めない．

## 自分で定義する演算子

速度の対称勾配 `strain`，ひずみから応力を返す `stressRate`，応力の発散 `stressDiv` を
関数として定義する．`stressRate` は時間微分にも同じ線形関係が使える名前である．

C(E)^{ij} = s(x,y) [λ g^{ij} g^{kl} E_kl + 2μ g^{ik}g^{jl}E_kl
+ α n^i n^j n^k n^l E_kl]．

n = (cos(angle), sin(angle)) が繊維方向．最後の項がその方向の剛性を加える．
s = 1 − damage exp(−[(x−7)²+(y−6)²]/0.16) は，中央で最大 70% 剛性が低下する滑らかな領域．
`damage=0` が健全，`damage=0.7` が局所的な剛性低下で，密度は 1，λ=2，μ=1，α=5．
数値はすべて無次元で，特定の複合材に合わせた定数ではない．

(4,6) を中心とするガウス形の初期ひずみから波を発生させ，(9,6) の周囲で速度の x 成分を
ガウス重みで積分して受信波形を計算する．正の初期ひずみは引張り側の応力パルスを与える．
速度 Verlet 法で進め，ひずみと材料テンソルから弾性エネルギーを計算する．
この積分法が保存する修正エネルギーの計算も `.fme` にある．
修正エネルギーは通常の弾性・運動エネルギーから Δt² ∫|div σ|²/8 を引いた量である．
CSV の `modified` 列には更新後の値を記録し，保存の検査は最初の更新後の出力を基準とする．
初期化直後（`step=0`）の同列は補正前の通常のエネルギーであり，この検査には用いない．

領域は 16×12，256×192 点，Δt=0.0025，観測は t=2.4 まで．周期境界を使うが，
波源から周期境界を経由して受信点へ戻る最短距離は 11，最大波速は 3 なので，
主要な波の回り込みは観測後になる．全体図には境界をまたぐ波も現れる．

## 実行・結果

リポジトリ直下で `python3 examples/application_demos/run.py composite_ultrasound`．
動画生成・検証を含む共通手順は [application_demos](../application_demos/README.md) を参照．

[比較画像](../application_demos/results/composite_ultrasound/comparison.png) ／
[比較動画](../application_demos/results/composite_ultrasound/comparison.mp4) ／
[受信波形](../application_demos/results/composite_ultrasound/measurements.png) ／
[検証結果](../application_demos/results/verification.json)．

検証は修正エネルギーの保存，繊維方向の平面波の厳密解に対する格子細分化，
時間方向のブロッキングと各軸の MPI 分割の一致を対象とする．
