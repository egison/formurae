# 構成則・流束・生成時の検査の比較実験

2026-09-07の比較．結論と一次資料は [RELATED-WORK.md](../RELATED-WORK.md)，
実行結果は [results.json](results.json) にまとめる．
第三者のAPIを実行し，Formuraeの入力にも正しく受理される例と意図的に誤りを
入れた例の両方を用意する．失敗の理由が依存ライブラリや構文の不備でなく，
検査対象の条件であることを診断文まで確認する．

2026-09-08に追加した [Egisonによる演算子定義の比較](expressivity/README.md) では，
添字に応じた関数適用，局所的な添字，次数に依存しない外微分の定義を，
実際のAPIと生成Cによって比較する．

## 実行した範囲

| 対象 | 実行した処理 |
|---|---|
| Formurae | 15入力を前処理→Egison評価→後処理の順に実行．構成則の2入力はFormuraによるC生成・コンパイル・実行まで行う |
| Devito 4.8.23 | 円筒・球座標の計量値を使う構成則，非対称な構成則，流束のCを生成・実行．配置の例はC生成まで行う |
| NRPyLaTeX 1.4.0 | 添字付きの式からSymPy式へ展開し，構成則の値を評価．対称性宣言，不正な縮約，非線形流束も検査 |
| OpenSBLI | `EinsteinEquation.expand` で成分式へ展開し，構成則の値を評価．自由添字の不一致と `Conservative` も検査 |
| NRPy+ | 先に格納した流束 `F` の中心差分Cを生成 |
| Kranc | 公開ソースの二つのテンソル展開経路を読む．Mathematicaでの実行は行っていない |

構成則は，ひずみから応力変化を計算する関係である．ここでの比較はその計算部分と
生成時の検査を対象にする．Formurae以外の波動ソルバー全体の時間発展，OPSによる
OpenSBLIのC生成，性能比較はこの実験には含まない．
Formuraeの円筒・球座標の波動プログラム全体にも構成則の変更を加え，
両座標で正しい変更を受理し，誤った変更を拒否することを確認する．
既存の等方性弾性波の収束・長時間検証は [別の実験](../README.md) である．

## 共通の入力と判定方法

逆計量を $G^{ij}=g^{ij}$，対称なひずみを $e_{ij}$ とする．
次の構成則に，同じ値を与える．繰り返す添字について和を取る．

$$
q^{ij}=2G^{ij}G^{kl}e_{kl}+2G^{ik}G^{jl}e_{kl}
       +\alpha n^i n^j n^k n^l e_{kl}.
$$

- $e=[[1,2,3],[2,4,5],[3,5,6]]$，$\alpha=0.5$，$n=(1,0,0)$．
- 円筒：$G=\operatorname{diag}(1,R^{-2},1)$．
- 球：$G=\operatorname{diag}(1,R^{-2},(R\sin T)^{-2})$．
- 評価点：$R=1.5$，$T=1.25$．Formuraeでは $R=1+r$，$T=1+\theta$ として
  座標を含む計量から生成する．他の3系の構成則には，この点の計量値を代入する．
- 非対称な変更：追加項の $n^j$ 一つだけを $m^j$，$m=(0,1,0)$ に変える．
  正しい式と同じ宣言・生成方法を使う．
- 許容絶対誤差：$10^{-12}$．最大実測誤差は $3.552713678800501\times10^{-15}$．

Devitoでは同じ縮約をPythonのループで書く．NRPyLaTeXとOpenSBLIでは添字付きの
式として与える．ここではユーザー入力の行数を優劣の指標にしていない．

流束には $F(u)=u^2/2$ を使い，$u_{i-1}=1$，$u_i=4$，$u_{i+1}=9$，$h=0.25$
を与える．同じ2次中心差分で $D(F(u))=80$，$uD(u)=64$ となるため，
積の微分則による書き換えを数値で区別できる．Devitoでは `side=centered` を明示する．
NRPyLaTeXには `\partial_i(\frac{u^2}{2})` を入力する．NRPy+の例は
`F` を格子上の変数として登録してから `F_dD0` を生成する．

配置の比較では，格子点と半格子点（隣接する格子点の中間）を区別する．
Formuraeでは半格子点を返す微分を格子点の変数へ代入する入力を拒否する．
Devitoでは `x0={x:x+x.spacing/2}` を明示した微分を `staggered=NODE` の変数へ
代入する入力を受理する．これは配置に関する宣言の扱いの比較であり，
Devitoの通常の自動補間が不正確であると結論する実験ではない．

## 再現する環境

作業ディレクトリはFormuraeリポジトリのルートとする．Cコンパイラ，Formuraeの
Cabal環境，`bin/formura`，`mpistub` が必要である．今回の実行環境はmacOS arm64，
GHC 9.10.1である．CabalやEgisonを呼ぶコマンドは，ほかのHaskell系ビルドと
重ねず，順に完了を待つ．

Python 3.12.14でDevito・NRPyLaTeX・NRPy+を，Python 3.9.6でOpenSBLIを実行した．
依存バージョンは二つの `requirements` ファイルに固定してある．
以下の `python3.12` と `python3.9` は，それぞれ対応するPython実行ファイルに置き換えられる．

```sh
python3.12 -m venv .build/related-work/venv
.build/related-work/venv/bin/python -m pip install -r examples/elastic_curvilinear/comparison/requirements-python.txt
python3.9 -m venv .build/related-work/opensbli-venv
.build/related-work/opensbli-venv/bin/python -m pip install -r examples/elastic_curvilinear/comparison/requirements-opensbli.txt
```

OpenSBLIでは現在のSymPyから削除された `sympy.printing.ccode` を参照するため，
SymPy 1.6.2を用いる．依存バージョンを合わせて実行し，第三者のソースは改変しない．

取得先と検査したリビジョン：

```sh
mkdir -p .build/related-work/sources
git clone https://github.com/opensbli/opensbli .build/related-work/sources/opensbli
git -C .build/related-work/sources/opensbli checkout e37dc377fa9b27d6bfa6e9da2968b96bcd736f1d
git clone https://github.com/zachetienne/nrpytutorial .build/related-work/sources/nrpyplus
git -C .build/related-work/sources/nrpyplus checkout a32e120f5642bee00e32e9e04dd8cb4c58ae661c
git clone https://github.com/ianhinder/Kranc .build/related-work/sources/kranc
git -C .build/related-work/sources/kranc checkout b4b2b40103a706a29f8f6b3910110a30afff75aa
tools/prepare_elastic_validation.sh
```

最後のコマンドは，隣の `egison` リポジトリから `spec/egison-revision` の
検証済みリビジョンを `.build/egison-<リビジョン>` へ取り出す．
取得元は `EGISON_SOURCE` で変更できる．Formurae自体は作業ツリーの版を使い，
生成に関係するソース・入力のSHA-256を結果に保存する．

## 実行

以下を順に実行する．取得・ビルド・ログ・生成Cは `.build/related-work/` に置く．

```sh
.build/related-work/venv/bin/python examples/elastic_curvilinear/comparison/python_probes.py nrpylatex --output .build/related-work/results/nrpylatex.json
.build/related-work/venv/bin/python examples/elastic_curvilinear/comparison/python_probes.py devito --output .build/related-work/results/devito.json
.build/related-work/opensbli-venv/bin/python examples/elastic_curvilinear/comparison/python_probes.py opensbli --output .build/related-work/results/opensbli.json
.build/related-work/venv/bin/python examples/elastic_curvilinear/comparison/python_probes.py nrpyplus --output .build/related-work/results/nrpyplus.json
python3 examples/elastic_curvilinear/comparison/formurae_probes.py --egison-dir "$(tools/prepare_elastic_validation.sh)" --output .build/related-work/results/formurae.json
python3 examples/elastic_curvilinear/comparison/collect_results.py
```

`collect_results.py` は15入力の受理・拒否，診断文，8件の構成則評価，
非線形流束の値，第三者ソースのリビジョンと未改変状態を確認してから
`comparison/results.json` に集約する．

Formuraeの個別入力は `fixtures/`，球座標への変更と波動プログラムへの変更は
`formurae_probes.py` にある．生成された全入力は
`.build/related-work/formurae/*.fme` に残る．4階テンソルを返す関数の再利用は
`rank4_helper.fme` で検査する．これは数学的な関数の中間結果であり，
4階テンソルの格子配列を宣言する実験とは異なる．

Devitoの非対称な更新と配置の生成Cは `devito-asymmetric.c` と
`devito-placement.c`，NRPy+の流束の生成Cは `nrpyplus-flux.c.inc` に残る．
いずれも `.build/related-work/` 配下である．
