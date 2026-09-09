# Egisonによる演算子定義の比較

調査・実行日：2026-09-08．[全体の比較](../../RELATED-WORK.md)のうち，
「どんな数学的な関数を，どのように定義して生成器へ渡せるか」を調べる実験である．
前日の対称性検査の実験も維持する．

## 1．同じスカラー計算を添字に応じて適用する

スカラー計算とは，テンソル全体ではなく，個々の数値について計算することを指す．
ここでは2引数の $F(a,b)=(a^2+ab+b^2)/6$ を使う．
Formuraeで実行した定義は次のとおりである．

```text
def scalarFlux a b = (a*a + a*b + b*b) / 6
def indexed f X Y = tensorMap2 f X Y
def plusValues X Y = X + Y
def reduceWith combine reduce X Y =
  contractWith reduce (indexed combine X Y)
```

`tensorMap2` は，二つのテンソルに付いた添字に応じて成分を対応させ，
関数を適用するEgisonの機能である．`contractWith` は，同じ文字の上下添字に
対応する成分を，指定された関数でまとめる．ここでは加算する．

同じ `indexed` と `scalarFlux` を，次の三通りで呼び出せた．

| 呼出し | 計算するもの | 生成Cの結果 |
|---|---|---|
| `indexed scalarFlux a_i b_i` | 対応する成分の $F(a_i,b_i)$ | $[3.5,6.5,10.5]$ |
| `indexed scalarFlux a_i b_j` | すべての組合せの $F(a_i,b_j)$ | 3行3列の配列．各成分を独立計算と照合 |
| `reduceWith scalarFlux plusValues v~i b_i` | $\sum_i F(v^i,b_i)$ | $20.5$ |

入力は $a=v=[1,2,3]$，$b=[4,5,6]$．
`scalarFlux` は添字，配列の階数，成分数を扱うコードを持たない．
**成分の対応は呼出し側の添字，計算内容は通常の関数，縮約は別の関数で指定できる．**
非線形な成分写像が座標変換に対してテンソルとして変換することを保証する実験ではなく，
添字を使う配列計算の表現力を調べる実験である．

Formuraeの型注釈を省略した `def` について，複合スカラー関数がすべて自動で
この動作をするとは扱わない．今回の実行例では，一度定義した `indexed` を通じて
スカラー計算をテンソルへ適用することを明示している．Egison本体のスカラー引数と
テンソル引数の仕組みは，この添字に応じた適用を基盤とする．

### 同じ計算を既存系で書いた結果

| 対象 | 動作を確認した書き方 | 添字・形状の扱い |
|---|---|---|
| UFL 2026.1.0 | 対応成分には `elem_op(flux,a,b)`，全組合せには `as_matrix([[flux(a[p],b[q]) ...] ...])` | 対応成分用の演算と，成分配列を組み立てる記述を使い分ける |
| Devito 4.8.23 | スカラー成分へ `flux` を適用し，`ImmutableDenseMatrix` で結果を構築 | Python関数による成分の組立てを行い，生成Cも実行できる |
| SymPy 1.14.0 | 数値・記号の成分配列へ展開して `flux` を適用 | 抽象テンソルの上下添字とは別に，成分の組立てを行う |
| NumPy 2.4.3 | `flux(a,b)` と `flux(a[:,None],b[None,:])` | 全組合せには軸の追加位置を明示する |

UFLの `flux(a[i],b[j])` やSymPyの `flux(a(i),b(j))` をそのまま使う書き方は
この例では受理されなかった．UFLでは項ごとの自由添字（和を取らずに残る添字）が
一致せず，SymPyでは同じ上添字が積で繰り返されるためである．
Devitoのベクトル全体への呼出しも，内部の積が行列積として扱われて失敗する．
**上表の適切な書き方なら各系とも計算できる．差は計算可能性より，
添字による成分の対応を汎用の関数適用と組み合わせる方法にある．**

## 2．定義内の添字を局所化して再利用する

```text
def inner X~a Y_b = withSymbols [i] (X~i . Y_i)

q'~i = c~i * inner v b
r'~j = c~j * inner v b
```

`withSymbols` は，その定義の内部だけで使う新しい添字を導入する．
呼出し側にも `i` があっても混同しない．上の二つの生成Cの結果は，
$c=[7,8,9]$ に対してともに $[224,256,288]$ となった．

NRPyLaTeXでは，次の置換によって同じ内積の略記を定義できた．

```text
% replace "\mathrm{dot}(\1,\2)" -> "\1^i \2_i"
```

`s=\mathrm{dot}(a,b)` は成功するが，`q^i=c^i \mathrm{dot}(a,b)` では，
展開後に呼出し側の `i` と衝突して拒否された．置換内の `i` を `j` に変えると
成功した．OpenSBLIでも，`Eq(s,a_i*b_i)` を `Eq(q_i,c_i*s)` へ置換する入力は
拒否され，補助式内を `a_j*b_j` に変えると成功した．
これらは今回使った置換の定義方法の結果である．
NRPyLaTeXの組み込み共変微分やLie微分には，別途添字を生成する処理がある．

UFLでは，関数内で `indices` によって新しい添字を作ると同じ衝突を避けられた．
したがって，局所的な添字の機能自体をEgisonだけのものとは扱わない．
Egisonでは，この局所化と，添字付きの値を返して別の関数へ渡す処理が，
同じ関数評価の規則に従う．

対称部分を取る関数も実行した．

```text
def symmetricPart T_a_b = withSymbols [i,j] ((T_i_j + T_j_i) / 2)
S' = symmetricPart M
```

関数の結果は，代入先に宣言した対称テンソルとして検査される．
この定義は生成Cまで通り，$M$ の9成分から6個の独立な対称成分を計算した．
UFLでも `indices` と `as_tensor` により同じユーザー関数を定義できた．
SymPyも宣言された対称性によって $S(i,j)-S(j,i)$ を0へ整理できた．

## 3．省略添字を使って，次数に依存しない微分演算子を定義する

微分形式は，曲線・曲面などに沿って積分する量であり，積分する対象の次元を
次数と呼ぶ．外微分は，$k$ 形式を $k+1$ 形式へ写す微分演算子である．
次の定義を，2次元と3次元の両方で変更せずに使った．

```text
def exterior A =
  let degree := dfOrder A + 1
   in degree * dfNormalize (!(flip ∂/∂) coordinates A)
```

`dfOrder` は次数を返し，`dfNormalize` は添字の入替えに応じた符号を持つ
反対称な部分を取り出す．`flip` は二つの引数の順序を入れ替える．
`!` は，二つの引数の省略された添字を別の添字として補い，微分のための軸を増やす．
これらを組み合わせると，次数ごとに成分式を記述せずに外微分を定義できる．

| 同じ定義への入力 | 生成した成分計算 | 検証 |
|---|---|---|
| 0形式 | 各方向への微分 | 2次元・3次元の生成Cを実行 |
| 1形式 | $\partial_i A_j-\partial_j A_i$ | 2次元・3次元の生成Cを実行 |
| 2形式 | $\partial_i B_{jk}-\partial_j B_{ik}+\partial_k B_{ij}$ | 3次元の生成Cを実行 |
| `exterior (exterior f)` | 全成分が0へ正規化される | 2次元・3次元で0を出力する生成Cを実行 |

入力には座標の多項式を使い，成分ごとの格子位置を考慮した解析値と比較した．
独立に実装した成分式はC検証側だけにあり，`exterior` の定義にはない．

また，次の回転演算子を通常の関数として定義してCを生成した．
`epsilon` は，添字の順序に応じて $0,1,-1$ を取るLevi-Civita記号である．

```text
def rotation X = withSymbols [i,j,k] (epsilon_i~j~k . ∂/∂ X_k coordinates~j)
def apply op X = op X
```

`rotation A` と `apply rotation A` の両方を実行した．関数名と内部の添字名を
変更しても，生成されたFormuraプログラムは完全一致した．
数学的な関数の名前がコンパイラの特別な演算子名である必要はない．
Devitoにも同じ回転の関数を定義し，3成分について生成Cの値を照合した．
その定義には，二つの成分添字を列挙するPythonのループと結果行列の構築を使う．
入力 $A=(xy,yz,zx)$ の回転は $(-y,-z,-x)$ である．成分の取り違えも検出できるよう，
両系で $(x,y,z)=(0.5,0.75,1.0)$ を評価し，$(-0.75,-1.0,-0.5)$ と照合する．

### 既存の外微分との比較

SymPyの `Differential` に同じ3次元の多項式を0・1・2形式として与え，
各成分と $d(df)=0$ を実行確認した．既存の外微分を呼び出すだけなら，
`Differential(A)` と短く書ける．UFLの `exterior_derivative` も，
入力が属する有限要素空間に応じて `grad`・`curl`・`div` などを選択する．
この選択は，今回インストールした2026.1.0の公開ソースでも確認した．
Mathematica上のxTeriorにも，テンソル値の微分形式，外微分，共変外微分，
座標表示の機能がある．xTeriorは公式資料を調べ，Mathematicaでの実行はしていない．

| 比較する内容 | 確認できたこと |
|---|---|
| 外微分を短く呼び出す | 既存系も提供する．Formuraeだけの能力ではない |
| 複数の次数を同じ演算子で処理する | SymPyの0・1・2形式で実行確認．この能力自体にも先行例がある |
| 外微分の計算内容を利用者が定義する | Formuraeでは，偏微分・反対称化・省略添字の補完を組み合わせた3行の定義を実行した |
| その定義を数値生成に使う | 同じ定義から2次元・3次元の成分と格子位置を処理し，生成Cの実行値を照合した |

したがって，Egisonの差を測る対象は，完成済みの外微分APIの呼出し行数ではなく，
**数学的な演算子を利用者が定義する記述と，その定義を数値生成へ渡す方法**である．
他系でもPythonやMathematicaで独自の処理を実装できる．今回のFormuraeの定義では，
次数ごとに添字の列や成分を組み立てる処理を，利用者が追加する必要がなかった．

## 実験中に修正した実装

`∂/∂` を高階関数（関数を引数に取る関数）へ渡す場合と，複数行の関数本体で
参照する場合に，前処理が変換した内部名の定義が生成されない不備を修正した．
通常の解析的な微分を，そのまま関数値として渡せるようにする修正である．

さらに $d(df)=0$ で更新式が定数0になった場合にも配列として生成できるよう，
Formuraの更新関数で出力の配列型を明示した．前処理・後処理の回帰テストと，
上記のC実行で検証した．
数学演算子の意味や，演算子ごとの変換規則を新しくコンパイラへ追加したわけではない．

## 再現

環境と第三者ソースの取得は [親ディレクトリの手順](../README.md) に従う．
UFLだけ追加する．各コマンドの完了を待って次を実行する．

```sh
.build/related-work/venv/bin/python -m pip install -r examples/elastic_curvilinear/comparison/expressivity/requirements.txt
python3 examples/elastic_curvilinear/comparison/expressivity/run_formurae.py --egison-dir "$(tools/prepare_elastic_validation.sh)"
.build/related-work/venv/bin/python examples/elastic_curvilinear/comparison/expressivity/run_python.py modern
.build/related-work/opensbli-venv/bin/python examples/elastic_curvilinear/comparison/expressivity/run_python.py opensbli
```

結果：

- [Formuraeの生成・C実行・ソースのハッシュ](results-formurae.json)
- [UFL・SymPy・NumPy・NRPyLaTeX・Devito](results-python.json)
- [OpenSBLI](results-opensbli.json)

生成された入力・Formura・C・実行ファイルは
`.build/related-work/expressivity-final/` に残る．
UFLとSymPyは数式の構築・評価，NRPyLaTeXとOpenSBLIは添字展開を実行している．
全システムで波動ソルバー全体を実行した比較や，実行性能の比較ではない．

## 一次資料

- [Egison：添字の簡約と補完の設計](https://arxiv.org/html/1804.03140)．特に2.3節の関数適用，2.5節の局所添字，2.6節の微分形式．これらはEgisonの先行成果である．
- [UFL：利用者定義演算子](https://docs.fenicsproject.org/ufl/main/manual/form_language.html#user-defined-operators)と[成分ごとの関数適用の実装](https://docs.fenicsproject.org/ufl/main/_modules/ufl/operators.html#elem_op)．
- [SymPy：上下添字と対称性](https://docs.sympy.org/latest/modules/tensor/tensor.html)と[テンソル式の微分](https://docs.sympy.org/latest/modules/tensor/toperators.html)．SymPyにも微分によって添字の上下を反転する機能がある．
- [SymPy：微分形式と外微分](https://docs.sympy.org/latest/modules/diffgeom.html#sympy.diffgeom.Differential)．外微分の複数次数への適用と二重適用の簡約は，既存のライブラリにもある．
- [UFL：外微分の実装](https://docs.fenicsproject.org/ufl/main/_modules/ufl/operators.html#exterior_derivative)．有限要素空間に応じた微分演算子の選択．
- [xTerior公式](https://www.xact.es/xTerior/index.html)．テンソル値の微分形式と外微分，座標表示の先行例．
- [NRPyLaTeXの設計](https://arxiv.org/html/2111.05861)．独自演算子の置換による定義と，組み込み演算子の添字生成を区別する．実行時の置換構文は1.4.0の `% replace` である．
- [OpenSBLIの式の展開](https://github.com/opensbli/opensbli/blob/e37dc377fa9b27d6bfa6e9da2968b96bcd736f1d/opensbli/core/parsing.py#L380)．今回比較した補助式の置換の実装．
- [Decapodesの独自演算子](https://algebraicjulia.github.io/Decapodes.jl/dev/concepts/generate/)．公式資料では，独自演算子をJuliaの実装関数へ対応させる方法を提供する．この資料比較と，今回の実行比較は分けている．
