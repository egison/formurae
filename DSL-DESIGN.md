# Formurae 設計メモ — Egison 流の添字記法・微分形式をもつステンシル DSL

**命名(2026-07-10 確定)**: 表層言語(.fme)の名前は **Formurae**(フォーミュレ)。
Formura のラテン語風複数形で *formulae*(数式)への掛詞 — 「数式のまま書く」という
本言語の主題が名前になっている。Formura 設計者・村主崇行氏への敬意を込めた継承でもある
(「Formura 2」は本体の現行バージョン 2.3.2 と紛れるため回避)。

**v1.30(2026-07-10): 中間 Egison の特殊化と共有 runtime** —
`grad`、`dGrad`、`divg`、`curl`、`lap`、`Δ`、`hessian` は、モデルごとに
Egison 関数定義を出す方式をやめ、`fec` 内の通常の TensorExpr prelude `Def` として
ユーザー `def` と同じ経路で成分特殊化する。ユーザー定義は prelude を shadow できる。
この統合時に `hessian u` を `∂_i ∂_j u` として修正した。
Formura プリンタは `lib/formurae-runtime.egi` に一度だけ定義し、生成 `.egi` は
名前変換表・座標ベクトル・格子幅を明示的な data context として渡す。
さらに残余式の依存から collocated 微分、Yee helper、参照された metric variance、
Egison Tensor 値のための field alias を必要時に限って生成し、DEC form context は
`mode dec` で選択する。これにより
`dF`/`dB`、生成側 `curlYee`、`FormuraeInternalTensor...` alias、重複プリンタ、
旧 `TensorDef` 展開経路を撤去し、中間 Egison を「モデル固有の残余計算」に縮小した。

**v1.29(2026-07-10): `mode collocated` / `mode dec` と通常 prelude** —
ファイル全体の空間離散化を `mode` で明示する。`mode` は必須であり、複数の mode 宣言、
collocated mode の form field / `assert-dd-zero` はエラーにする。
collocated mode は `grad`、`dGrad`、`divg`、`curl`、`lap`、`Δ` を自動ロードする。
これらは個別の Haskell 特殊展開ではなく、`withSymbols`、`contractWith`、`.`、
内部 Cartesian metric、`epsilon`、`∂_i` だけからなる通常の TensorExpr `Def` である。
例えば `curl` は
`withSymbols [i,j,k] (epsilon_i~j~k . ∂_j X_k)` と定義される。
同一点配置の添字微分は中心差分、source/target placement が異なるときだけ
`dYee` へ下りる。DEC mode は `dForm` / `hodge` / `codiff` context を自動生成し、
`def lapForm a = codiff (d a)` のような form operator の合成も lowering する。
現在の form 値は積分 cochain ではなく structured Yee 格子上の sampled component
であるため、真の incidence-only cochain DEC と区別する。vector/form 間の
`flat` / `sharp` は再構成・補間規約が決まるまで未実装として明示診断する。
`hessian` は添字微分 `∂` だけからなるため、collocated/dec 共通 prelude とする。

**v1.24(2026-07-09): 微分プリミティブの明示化と `Δ`/`Δ4` の通常定義化** —
`∂^2_x e` を2階中心差分、`∂'^m_x e` を m 階微分・半径2の中心 stencil
として追加した。一般に `∂` 直後のクォート数 + 1 を stencil radius と読む。
例えば `∂'^2_x e` は `[-2,-1,0,1,2]` の5点 stencil で、
係数は `taylorStencil` が Taylor 条件から導出する。これにより `Δ` と `Δ4`
は組み込みではなく `.fme` 側で
`def Δ u = ∂^2_x u + ∂^2_y u + ∂^2_z u`、
`def Δ4 u = ∂'^2_x u + ∂'^2_y u + ∂'^2_z u` のように書く方針へ移した。
計量つきモデルでは `def Δ u = lb u` と書く。暗黙の `use exterior-calculus { Δ }`、
`∂_x (∂_x u)` の融合、`δ (d u)` のスカラー Laplacian 降下、
`∇×`/`∇·`/`∇²` の alias は撤去した。

**v1.25(2026-07-09): 生成文脈の `lap` 削除と 2D `divg` 検証** —
平坦格子の Laplacian は `def Δ u = ∂^2_x u + ...` と `.fme` 側で定義する方針に
合わせ、生成 `.egi` の座標文脈から未使用の `lap` 定義を外した。
`dGrad`/`divg` はすでに `feDim` を使って任意の 1D/2D/3D 文脈で生成されるため、
`examples/divergence2d` を追加し、`use vector-calculus { divg }` が 2D で
中心差分の離散記号と一致することを check driver で検証した。

**v1.26(2026-07-09): Egison 型のユーザ定義テンソル演算子と明示縮約** —
`.fme` の `def` は Egison と同様に結果添字を書かない。
例えば `def grad u = withSymbols [i] ∂_i u`、
`def div X = contractWith (+) (∂_i X~i)`、
`def (.) A B = contractWith (+) (A * B)`、
`def Δ u = g~i~j . ∂_i ∂_j u` のように書く。
`withSymbols` の外へ出る自由添字は呼び出し側の添字へ付け替えられ、
同じ上下添字が現れただけでは総和しない。縮約は `contractWith` と、
その上にユーザ定義された `.` だけが行う。
平坦 Laplacian は `metric g` のもとで `g~i~j . ∂_i ∂_j u` から
`∂^2_x u + ∂^2_y u + ∂^2_z u`、さらに通常の3点二階差分へ下りる。

**v1.27(2026-07-09): `δ` と metric 名の分離** —
`δ` は Kronecker delta の mixed identity `δ~i_j` に限定し、
same-variance の計量成分はユークリッド座標でも `metric g` を宣言して
`g~i~j` / `g_i_j` と書く方針にした。`metric δ` は禁止する。
一方、`metric g` と `param g` / `field g` のような名前衝突はエラーにせず
warning にする。添字なし `g` はスカラー名、添字つき `g_i_j` / `g~i~j`
は metric として解釈できるためである。

**v1.28(2026-07-10): TensorExpr lowering への移行完了** —
旧来の文字列置換ベースの添字 lowering ではなく、添字式は TensorExpr AST として扱う。
`withSymbols`、`contractWith`、ユーザ定義可能な `.`、metric `g`、
Kronecker delta `δ~i_j`、`epsilon~i~j~k`、添字微分 `∂_i` を同じ lowering 経路へ通し、
全 `.fme` 例の変換と `diffusion3d`/`elastic3d` の実行検証を green にした。
scalar 式全体も `TENumber`、`TEUnary`、`TECall`、`TEApply`、`TEIf`、`TEBinary`
などの AST へ構文木化するようにした。parser error は式全体、失敗近傍、column を表示する
`Either` 経路へ移し、source span つき診断は次の整理対象である。

**v1.13(2026-07-09): 座標文脈つき `use` 宣言の導入** —
`extern` は Formura/C 側のスカラー関数、`use` は Formurae が座標文脈から
生成する数学演算子、という役割に分け始めた。第一段階として
`use exterior-calculus { Δ }` を実装し、`Δ` は暗黙 prelude ではなく
この宣言で追加される `def Δ u = 0 - δ (d u)` になった。
`Δ` を使っているのに `use` がない場合は `.fmr` 生成前にエラーにする。
既存の `Δ` 使用例には `use` を明示し、生成 .egi はバイト一致。
今後 `use vector-calculus { curl, divg }` や
`use exterior-calculus { d, δ }` へ広げ、`lib/fmrgen.egi` の座標固定定義を
モデルごとの座標文脈つき生成へ移す。

**v1.14(2026-07-09): `use vector-calculus` の第一段階** —
`curl`・`divg`・`dGrad` を `use vector-calculus` 側の演算子として扱い始めた。
`curl` は `use vector-calculus { curl }`、`divg` は
`use vector-calculus { divg }` なしでは `.fmr` 生成前にエラーにする。
`maxwell3d.fme` には `use vector-calculus { curl }` を明示し、生成 .egi は
バイト一致。当初は定義本体に `lib/fmrgen.egi` の `curl`/`divg` を使ったが、
v1.17 で生成 `.egi` 側の座標文脈つき定義へ移した。
次は `d`/`δ` の use 化、または `lib/fmrgen.egi` の座標文脈つき定義生成へ進む。

**v1.15(2026-07-09): `use exterior-calculus { d, δ }` の第一段階** —
ユーザが直接書いた `d`・`δ`・`codiff`・`dForm` を `use exterior-calculus`
必須にした。`maxwell_dec.fme` と `hyperbolic.fme` に `use exterior-calculus { d, δ }`
を明示し、生成 .egi はバイト一致。`Δ` の内部定義 `δ (d u)` は
`use exterior-calculus { Δ }` の依存として扱い、`Δ` 単独 use は引き続き動く。
当初は定義本体に `lib/fmrgen.egi` の `dForm`/`codiff` を使ったが、
v1.17 で生成 `.egi` 側の座標文脈つき定義へ移した。

**v1.16(2026-07-09): 生成 `.egi` への座標文脈定義** —
`use` または計量宣言を持つモデルの生成 `.egi` に
`feDim`・`feAxes`・`feCoords`・`feHsteps` を出すようにした。
`embedding` から計量を導出する `feGd`/`feGo` は `[x, y, z]` の直書きではなく
`feCoords_a` を参照し、計量係数場の半セル評価も `feCoords_a`/`feHsteps_a`
を使う。これはまだ `lib/fmrgen.egi` の `coords`/`hsteps` 本体置換ではないが、
座標文脈つきライブラリ生成へ進むための足場になる。生成 `.fmr` は全 `.fme` 例で
バイト一致。

**v1.17(2026-07-09): 座標文脈つき数学プリミティブ生成** —
`use` または計量宣言を持つモデルでは、生成 `.egi` の先頭に
`feAxisIds` と、`feCoords`/`feHsteps` を参照する `shift`・`dC`・`dC2`・`lap`
を出す。`use vector-calculus` では `dGrad`・`curl`・`divg` を同じ文脈で生成し、
`use exterior-calculus { d, δ }` や `assert-dd-zero` では `dYee`・`curlYee`・
`sigmaC`・`hodge`・`dForm`・`codiff` も生成する。計量つき `Δ` では保存流束に
必要な Yee プリミティブだけを生成する。`hodge` も `use exterior-calculus { hodge }`
なしではエラーにした。全 `.fme` 例の `.fmr` はバイト一致。

**v1.18(2026-07-09): `.egi` への出力層生成と `fmrgen` core 化** —
固定の `lib/fmrgen.egi` から座標依存の数学演算子と `.fmr` プリンタを外し、
`.fme` から生成される `.egi` が毎回 `feDim`/`feAxes`/`feCoords`/`feHsteps`、
ステンシル・Yee/DEC 演算子、`showFmr`/`fmrEq`/`emitModelOn` まで含むようにした。
`lib/fmrgen.egi` は `taylorStencil`・quote cleanup・形式補助などの座標非依存 core に縮小。
まだ `.fme` 化していない手書き `.egi` 例だけは `lib/fmrlegacy3d.egi` の 3D 互換文脈を読む。
全 `.fme` 例と手書き `.egi` 例で生成 `.fmr` はバイト一致。

**v1.19(2026-07-09): 上下添字を保持し、`metric NAME` で計量名を宣言** —
step 式で `~i` を `_i` に正規化する処理をやめ、添字展開器が `Up`/`Down` を
保持するようにした。既存の staggered vector/symmetric field は互換性のため
同じ格子成分へ下ろすが、`metric g` のように宣言された計量名は上下パターンで
別の内部テンソルへ解決する:
`g~i~j` → `FormuraeInternalMetricContra`、`g~i_j` →
`FormuraeInternalMetricMixedUpDown`、`g_i~j` →
`FormuraeInternalMetricMixedDownUp`、`g_i_j` →
`FormuraeInternalMetricCov`。内部 base 名には `_` を使わず、
`FormuraeInternal` prefix を予約した。Euclidean でも計量は単位行列として生成し、
`metric scale`/`embedding` では直交計量から cov/contra を生成する。
`metric NAME` は `NAME_i_j` のような2添字参照だけを計量として奪う。
Euclidean 計量も `metric g` として `g_i_j` / `g~i~j` と書く。
`param NAME` や `field NAME` と同名の場合は warning を出すが、
添字なし `NAME` は param/field、添字つき `NAME_i_j` は metric として解決する。
`δ` は Kronecker identity の mixed form `δ~i_j` に限定する
(融合形 `delta_ij` は不可)。さらに
vector/form/symmetric など添字付き場と `let NAME_i` の一時テンソルについても、
	上下パターンごとの `FormuraeInternalTensor...Up/Down...` 束縛を生成する。
	既存例の `.fmr` はバイト一致。

**v1.20(2026-07-09): 添字仕様から field layout を推論し、strict 添字検査へ** —
添字方程式に参加する field は `field v~i @ staggered`、
`field σ{~i~j} @ staggered` のように宣言する。新構文では
`: vector`、`: tensor`、`: symmetric` を書かず、rank・上下・対称性・
Formura 出力 layout を添字仕様から推論する。`{...}` は対称、`[...]` は
反対称(Egison/type-tensor-paper と同じ)。添字方程式の各項は生成前に
strict 検査され、自由添字は LHS と上下まで一致する。同じ上下添字が残る式は
diagonal tensor であり、scalar にするには `contractWith` または `.` が必要である。
添字の上げ下げは自動化せず、常に `g_i_j . v~j` のように
metric と縮約を明示する。`elastic3d.fme` は `metric g` と対称反変応力
`σ{~i~j}` を使う記法へ移行し、初期値も `v~i = [| ... |]~i` /
`σ~i~j = [| ... |]~i~j` のように同じ添字 suffix を要求する。
P/S 波速検証は green。

**v1.21(2026-07-09): Formura 軸名の透過と軸非依存な成分 storage 名** —
`.fme` の `axes` 宣言を Formura 出力にもそのまま渡すようにし、
`axes θ, φ, z` は `axes :: theta,phi,z`、`axes r, θ, φ` は
`axes :: r,theta,phi` を生成する。格子幅・ドライバ側のナビゲーション名も
`dtheta`、`dphi`、`space_interval_theta`、`lower_phi` のように軸名へ追随する。
CAS 内部では引き続き正規座標 `x,y,z` と `hx,hy,hz` を使い、`.fmr` プリンタの
`symName` で宣言軸へ戻す。

同時に Formura/C の field storage 名から `x,y,z` 文字を取り除いた。
legacy vector/form は `E_1,E_2,E_3`、添字付き rank-1 は
`v_up1,v_up2,v_up3`、対称 rank-2 は
`sigma_up1_up1,sigma_up1_up2,...` のように、成分番号と上下情報で命名する。
`fmrFieldName` は固定ライブラリではなく生成 `.egi` ごとに出し、
Egison 側の抽象関数 `sigma_1_2` / `sigma'_1_2` を
`sigma_up1_up2` / `sigma_up1_up2'` へ写像する。これにより表層の軸名と
storage 名の偶然の衝突を避け、`x,y,z` 以外の座標系を Formura 生成物まで
自然に通せる。生成 `.fmr` は旧版と storage 名が変わるためバイト一致ではなく、
各 check driver を新名へ追随させて物理検証で意味同等性を確認する。

**v1.22(2026-07-09): indexed CAS initializer と反対称 rank-2 backend** —
`σ~i~j := EXPR` のような添字付き CAS 初期化を実装した。LHS の自由添字で
strict 添字検査を行い、field layout から独立成分を列挙して成分ごとに
`ixExpand` する。`@ staggered` field では `v~i` や `σ~i~j` の配置に合わせ、
生成 `.egi` 側で `x -> x + offset*hx` の半セル substitute をかけてから
`fmrInit` に渡す。

反対称 rank-2 field `field A[_i_j] @ staggered` も backend 対応した。
storage は上三角 off-diagonal の3成分
`A_down1_down2,A_down1_down3,A_down2_down3`。参照時には
`A_i_j` を正準成分、`A_j_i` をその負、`A_i_i` を 0 に下ろす。
raw initializer は上三角 off-diagonal rows
`A_i_j = [| [| a12,a13 |], [| a23 |] |]_i_j` と、
対角 0・下三角が上三角の負である 3x3 行列の両方を受ける。
旧 `fmrdsl` の手書き DSL 用 `antiEqs` は後続の整理で削除し、現在は
生成 `.egi` 側の `componentEqs names values` に統合している。

**v1.23(2026-07-09): Formurae 生成経路の 1D/2D/3D 対応** —
`.fme` の `dimension` は 1、2、3 を受け付けるようになった。CAS 内部の
正規座標は宣言次元ぶんだけ `x,y,z` から取り、Formura 出力の `axes ::`、
格子参照、raw init の `[i]`/`[i,j]`/`[i,j,k]` も宣言次元へ追随する。
スカラー、vector、staggered rank-1、対称/反対称/full rank-2 field は
`mDim` から成分を列挙する。対称 tensor の独立成分は対角成分の後に
上三角 off-diagonal、反対称 tensor は上三角 off-diagonal だけを storage に持つ。
raw initializer も full matrix または上三角/上側非対角 rows を次元に応じて受ける。

旧生成 `.egi` 側の `vecEqs`/`symEqs`/`antiEqs`/`tensor2Eqs` は
`componentEqs names values` に統合済みで、field storage 名リストと式リストを zip して
Formura の step 行を出す形にした。`metric scale`/`embedding` 由来の
Laplace-Beltrami 係数場も次元数ぶんだけ生成する(1D なら `ca,sg`、
2D なら `ca,cb,sg`、3D なら従来どおり `ca,cb,cc,sg`)。
既存 3D 例の `.fmr` はバイト一致し、1D/2D の smoke test で `.fmr` 生成を確認。
この時点では `curl`、`epsilon~i~j~k`、DEC の `1-form`/`2-form` と
`d`/`delta`/`codiff`/`dForm`/`hodge` は 3D 専用として早期エラーにしていた。

**v1.24(2026-07-09): DEC/微分形式の一般次元化と diffusion1d/2d** —
`field A : k-form` を表層で受け付け、`0 <= k <= dimension` を検査するようにした。
形式成分は昇順の軸組で列挙する(`dimension 2` の 2-form は `B_1_2`、
`dimension 3` の 2-form は `B_1_2,B_1_3,B_2_3`)。
生成 `.egi` の DEC 文脈は、3D 固定の `sigma0/sigma1/sigma2/sigma3` と
`curlYee` 分岐をやめ、`formBasis k`、`basisSign`、`complementBasis`、
`hodge`、`dForm` を `dimension` から生成する形にした。これにより
`dForm : k-form -> (k+1)-form`、`codiff = (-1)^(n(k+1)+1) * hodge d hodge`
が 1D/2D/3D で同じ構造になる。`assert-dd-zero` も全成分の二乗和を検査する。

正式例として `examples/diffusion1d` と `examples/diffusion2d` を追加し、
`Δ` が宣言次元の Laplacian へ下りることを check driver で確認した。
`maxwell_dec` は B の storage を幾何基底名 `B_1_2,B_1_3,B_2_3` に変更し、
エネルギー・伝播・divB 検査を更新した。
`curl` と `epsilon~i~j~k` は引き続き 3D 専用である。

**v1.8(2026-07-08): Unicode と基本演算子** — ギリシャ文字識別子(θ, φ, …
→ fec が ASCII へ字訳)・∂=d・δ=codiff・−=-・Δ=幾何のラプラシアン
(平坦 lap/計量 lb)。`∂_x (∂_x u)` は compact 2階差分に融合、スカラーへの
`δ (d u)` は −Δ へ降下 — いずれも生成 .fmr バイト一致で検証
(metric_torus=θφΔ・maxwell_dec=δ・ks3d=二階微分2回・hyperbolic=−δd)。
Egison 側の function symbol 改良(functionSymbol 構築子・quote 透過
substitute・mathFunctionName・ディスパッチ修正 = egison/design/
function-symbol-formurae.md)により **LBM の 38 defs が map 2行の族に**、
feq の let も復活(いずれも .fmr バイト一致)。`field f : family N` の
表層化が次の一手として解禁。

**v1.9(2026-07-08): ∇・λ・上添字** — `∇×`=curl・`∇·`(∇.)=divg・
`∇^2`/`∇²`=Δ(nablaPass; ∇ 後の空白許容)。λ→lambda の字訳に合わせ
生成側の係数名を la/lam → lambda に変更(3例の .fmr が改名分だけ変化、
全チェック green)。この時点では添字方程式で上付きと下付きを実装上同一視し、
Kronecker/metric の記法もまだ未整理だった。現在は上付き・下付きは strict に区別し、
Kronecker は `δ~i_j`、same-variance の計量成分は `metric g` の `g~i~j` /
`g_i_j` と書く方針に整理している。Maxwell は `∇ × B`、Burgers は
`∇^2 u`(いずれもバイト一致)。

**v1.12c(2026-07-08): 本体定義の調査と整合** — Egison 本体の定義を調査:
`div` = trace(Jacobian)(lib/math/algebra/vector.egi: `trace (!∂/∂ A xs)`)・
`rot` = `crossProductWithFun ∂/∂ A xs`(∇× をクロス積として)・`∇` = 勾配の
**関数**(derivative.egi)。**本体 rot は符号が慣例と逆(A×∇=−∇×A)と実測で
確認 → チップ発行(task_4109e663)**。formurae 側: `divg` を本体 div と同じ
**trace (dGrad X)** に再定義(バイト同値)、curl は ε 縮約のまま(これも
Egison 流; crossProductWithFun 形は将来の選択肢)。表層の主綴りは
**関数形 curl/divg/Δ/Δ4**(∇×・∇·・∇²・lap・lap4 は sub 別名として受理)—
∇ × は関数に見えないという指摘によりギャラリー・例は主綴りで統一
(maxwell=curl・burgers=Δ)。lap4 の禁止は撤回し Δ4 への別名に。

**v1.12b(2026-07-08): lap4 全廃** — fmrgen の関数名ごと `Δ4` に改名
(Egison は Unicode 識別子可)。fec の特別規則も消え Δ4 は素通しで
ライブラリ関数に直結、表層 `lap4` は「lap4 is spelled Δ4」エラー。

**v1.12(2026-07-08): ユーザ定義演算子+Δ のプレリュード化** —
`def NAME ARG = EXPR`(ファイルスコープ・使用箇所でテキスト β 展開・
本文は先行定義のみ参照可=前方参照/再帰はエラー・引数は先に展開)。
**Δ はコンパイラ魔法から `def Δ u = 0 - δ (d u)` のプレリュード定義に格下げ**
(δ∘d 降下が平坦/計量を吸収するので分岐ごと言語内へ; 再定義可能)。
**Δ4 を主名に**(lap4 は別名)し、本体を fec 内のインラインλから
lib/fmrgen.egi の正規の関数 `lap4` に移設。局所場への Δ(CH の Δ μ)は
compound fallback(lap (…))で通る。fec に残る「魔法」= fuseDD・
lowerDeltaD(中核の降下)・nablaPass(グリフ別名)・計量の係数場機構
(エミッタ固有; lbExpansion の言語内化は将来課題)。全対象例 .fmr バイト一致。

**v1.11(2026-07-08): 記法の掃除** — 融合形 `delta_ij` と演算子 `d2_a` を
**言語から削除**(パース時に明確なエラー; d2 は fuseDD の内部表現としてのみ
存続)。Kronecker は 1添字1マーク(`δ~i_j`)のみ。usage の演算子表は
別名を演算子欄に併記する形へ再構成(「〜とも書ける」廃止)。
lap4 の基本演算子分解 = Richardson 外挿 (4·Δ_h − Δ_{2h})/3 と等価
(±1: 4/3・±2: −1/12・0: −5/2 で厳密一致)であり、不足しているのは
幅 2h の差分を表す表層演算子(stride つき ∂/Δ)— 導入すれば lap4 は
廃止可能、と記録。

**v1.10(2026-07-08): 宣言必須化+テンソル初期化** — dimension/axes を必須に
(∂_j の意味=座標系を各ファイルで確定; 欠落・軸数不一致はエラー)。
ベクトル場 init `v = [| … |]` は legacy field で staggered にも既対応、
indexed field では `v~i = [| … |]~i` のように添字 suffix を要求する。
**対称テンソルは
`σ~i~j = [| [| xx,xy,xz |], [| yy,yz |], [| zz |] |]~i~j`(上三角; 3×3 全成分なら
対称性検査)を新設**、init 行は括弧が閉じるまで複数行可。弾性波の添字は
混合変位 `s~i_j`/`δ~i_j` に(いずれも .fmr バイト一致)。

2026-07-10 起草。動機はレビュー指摘:
「現在の .egi は書きにくい。Maxwell の Ex, Ey, Ez は E というベクトルにすべき。
Egison 流の添字記法と微分形式の記法をもつ、Formura のような DSL を新しく作るべき」。

## 1. 現状の痛点(19 例を書いて判明したもの)

1. **成分ごとの場宣言**: `def Ex := function (x, y, z)` × 6〜9 本(LBM は 38 本)。
   `function` が定義変数名を捕捉する仕様のため、名前をプログラムで作れなかった。
2. **ベクトル場が第一級でない**: スカラー成分を定義してから `[| Ex, Ey, Ez |]` に詰め直す。
3. **.fmr の雛形を文字列で手書き**: `dimension ::`・`double ::`・`begin function (…) = step(…)`
   の出力タプルと fmrEq 行の同期を人間が保つ(実際に名前不一致バグを何度か踏んだ)。
4. **init が生の Formura 文字列**(metric の fmrInit 経由を除く)。
5. **演算子の空白必須**(`mx*mx/rho` は1識別子)という Egison 表層文法の罠。

## 2. 発見: 部品は Egison に既にあった

`sample/math/geometry/`(リーマン幾何ノート)が示すとおり、

- **添字つき関数族**: `def E_i := generateTensor (\[i] -> function (x, y, z)) [3]`
  で E_1, E_2, E_3 が独立な抽象関数シンボルになる(LHS 添字が定義文脈に入り、
  generateTensor が添字を埋める設計。`g[_i_j]` 形式も可)。
- 計量 → `M.inverse`・`∂/∂`・Christoffel 記号 Γ の記号計算は全部サンプル済み
  (しかも T2 の例はまさに本リポジトリのトーラス)。
- 微分形式は本リポジトリの DEC 層が担う。当初は dF0/dF1/dF2/codF2 という独自名
  だったが、**Egison 本体の Yang–Mills サンプル(d・hodge・δ)と同じ構造・標準名に
  再構成済み**: 形式=(複体, 次数, 成分)の3つ組、`hodge` は単位立方格子で成分不変の
  複体スワップ、`dForm` が離散外微分、余微分は `codiff = (−1)^(n(k+1)+1) ⋆d⋆`
  (別名 `δ`; codF2 は撤去)。d∘d=0 を CAS が 0 に簡約することも確認済み。

## 3. v0(実装済み): 埋め込み DSL

- 生成 `.egi` の `fmrFieldName`: 成分シンボル `E'_1` → `E_1'`、
  `sigma_1_2` → `sigma_up1_up2` のように、Egison 側の抽象関数名を
  Formura/C の storage 名へ変換(添字なし名は素通し)。初期の v0 では
  `Ex` や `sigmaxy` へ写していたが、現在は軸名に依存しない数字+上下タグを使う。
- 生成 `.egi` の出力層 — `emitModelOn dim axes params helpers comps inits steps`:
  preamble・`double ::` 宣言・init()/step() の雛形・**出力タプルを場宣言から自動生成**。
  `componentEqs`/`scalarEq` が fmrEq 行を組む。旧 `lib/fmrdsl.egi` は削除済み。
- 実証: `examples/maxwell3d` を全面書換 — 場宣言 2 行+添字方程式 2 行:

```egison
def E_i := generateTensor (\[i] -> function (x, y, z)) [3]
def B_i := generateTensor (\[i] -> function (x, y, z)) [3]
def En_i := withSymbols [i] E_i + dt * (curl B_#)_i
def Bn_i := withSymbols [i] B_i - dt * (curl En_#)_i
```

  当初の生成 .fmr は旧成分手書き版と**バイト一致**していた。現在は
  v1.21 の storage 名変更により `E_2`/`B_3` のような名前へ変わるため
  バイト一致ではないが、同じ物理量を更新する式として check driver で検証する。

## 4. v1(次): スタンドアロン表層構文

ファイル例(仮拡張子 .fme;名称候補は要相談):

```
dim 3
param dt = 0.5 * dx

field E : 1-form
field B : 2-form

init:
  E = [ 0, gauss1(x), 0 ]
  B = [ 0, 0, gauss1(x + dx/2) ]

step:
  E' = E + dt * (*d*) B
  B' = B - dt * d E'
```

添字記法の例(弾性波):

```
metric g
field v~i @ staggered
field σ{~i~j} @ staggered    -- 配置は添字から導出(Virieux)

step:
  v'~i     = v~i + (dt/rho) * contractWith (+) (∂_j σ~i~j)
  σ'~i~j  = σ~i~j + dt * (la * g~i~j * contractWith (+) (∂_k v'~k)
                          + mu * (g~i~k . ∂_k v'~j
                                + g~j~k . ∂_k v'~i))
```

曲面(直交計量)の例:

```
metric g
metric scale [1, 2 + cos x, 1]     -- Lamé 因子; sqrt(g), g^ii は導出
field u : scalar
step:
  u' = u + dt * laplace_beltrami u
```

### アーキテクチャ

```
.fme(表層構文)
  → fec(TensorExpr 構文木・def/prelude 展開・添字/配置の成分特殊化)
  → モデル固有の残余 .egi
  → Egison CAS + tensor/fmrgen/runtime ライブラリ
  → 共有プリンタ runtime が .fmr を出力
  → Formura(fork)→ MPI + temporal blocking つき C
```

- **意味論は TensorExpr と Egison の二段階に分ける**。`fec` はユーザー `def` と
  標準座標演算子を同じ TensorExpr lowering に通し、自由添字・縮約・配置を
  storage 成分へ特殊化する。`lib/formurae-tensor.egi` は、特殊化後にも残る
  `sym`/`wedge` などへ Egison Tensor primitive の bridge を提供する。
  `lib/fmrgen.egi` は `taylorStencil` や quote cleanup などの座標非依存 core、
  `lib/formurae-runtime.egi` は明示 context を受け取る共有 `.fmr` プリンタである。
  生成 `.egi` にはモデル固有の場・残余式と、実際に参照される座標文脈だけを出す。
  生成 `.fmr` のバイト一致テストを意味のアンカーとして維持する。
- パーサと TensorExpr lowering は Haskell(base のみ)で実装済みである。
  生成物はデバッグ可能な中間 `.egi` として追跡し、parser error は式全体・失敗近傍・
  column を返す。正確な source span は今後の診断改善対象である。

### 初期 v1 スコープ案(履歴)

- 次元は 3 固定(Formura の現行対応に合わせる)、場の種類 = scalar / vector /
  k-form / symmetric matrix / indexed family(LBM 用 `field f : family 19`)。
- 微分演算子: `d`, `(*d*)`, `grad/div/curl`(collocated), `d_i`(添字)、
  `laplace_beltrami`(metric scale 宣言があるとき)。
- init は式(CAS 経由で .fmr へ; 現行 fmrInit の一般化)。`where` でヘルパ。
- yaml(格子・分割・boundary・reduces)は Formura のまま。

## 5. ロードマップ

1. ✅ v0: 旧 fmrdsl + 添字つき関数族 + 成分名変換(maxwell3d で実証、バイト一致、現在は生成 `.egi` 側へ統合済み)
2. ✅ v0.5: elastic(対称テンソルビュー+添字導出スタガー)・maxwell_dec・
   metric_torus・kleingordon・diffusion3d を v0 様式へ移行(3例バイト一致)。
3. ✅ v1: **.fme 表層構文+コンパイラ実装済(2026-07-10)**。まず Python
   (fec.py)でプロトタイプし、同日 **Haskell 版に置換**(レビュー指摘)。
   現在は cabal パッケージ `fec`(ルート fec.cabal、ソース fec/src/Main.hs、
   base のみ)で、`cabal build` / `cabal run -v0 fec --` で使う。
   置換時に全5例で両実装の .egi 出力バイト一致を確認してから fec.py を撤去。移行済 = maxwell3d・maxwell_dec・
   diffusion3d・kleingordon・ks3d の5例、**うち4例は .fme → .egi → .fmr が
   バイト一致**(ks は整形差のみ)、全例 make green。.egi は生成中間物になった
   (ヘッダに GENERATED 印、ギャラリーは .fme → .egi → .fmr の3段表示)。
   文法は fec.py 冒頭のコメント参照(dimension/axes/field/param/extern/raw/
   init:/step:/let/local/assert-dd-zero、`:=` = CAS init、`=` = raw init)。
   **init もベクトルで書ける**: `E = [| 0, gauss1(i*dx), 0 |]`(成分展開は fec)。
   **ベクトル方程式は添字なしで書ける**: `E' = E + dt * curl B` /
   `B' = B - dt * curl E'`(X' は更新済み配列への参照 = symplectic かつ袖幅1;
   fec が成分化して withSymbols [i] 形に変換)。dimension/axes は必須で、
   現在の `.fme` 生成経路は 1D/2D/3D を扱う。CAS 内部の座標シンボルは
   宣言次元ぶんだけ `x,y,z` に正規化するが、
   Formura 出力の `axes ::` と `d<axis>`/`lower_<axis>` 系の名前は宣言軸を使う。
4. ✅ v1.5/v1.6(2026-07-10): **計量サポート実装済** —
   `metric scale [h1, h2, h3]`(直接指定)と **`embedding [X1..Xm]`
   (座標系からの計量自動導出)**。軸名(`axes r, theta, phi` 等)は内部
   `x,y,z` に正規化し、生成 Formura/C へ出すときに宣言名へ戻す。embedding では
   CAS が g_ab = ∂X/∂xₐ·∂X/∂x_b を計算(sin²+cos²=1 は自動簡約)、
   **直交性 g_ab=0 (a≠b) を記号検査してゲート**、h_a = √g_aa。quote
   (`` `(2+cos θ) ``)で因子を原子に保つと √ が閉じ、`expandAll` で
   quote を外してから半セル substitute(substitute は quote 非対応と判明;
   printer には quote ケースを追加)。宣言から hodge 因子 √g/hᵢ² の係数場
   (1D: ca/sg、2D: ca/cb/sg、3D: ca/cb/cc/sg)生成・半セル CAS 評価・保存流束・`lb`(Laplace–Beltrami)
   まで自動。トーラスを R⁴ 埋め込みから生成すると **hand-written スケール
   因子版と .fmr が extern sqrt 1行差で一致**。√ が閉じない埋め込みでも
   extern sqrt 経由で init が数値評価するので動く。球座標 hs=[1,r,r sinθ] は
   r=0・θ=0,π の座標特異点があるため、次例は円筒環状領域
   (embedding [r cos phi, r sin phi, zz]、r 壁は fork の boundary)推奨。
   残り = indexed family(`field f : family 19`)で LBM、ε_ijk とスカラー対象の
   添字和で yee/acoustic、ユーザ定義ヘルパ(def)で MHD。
5. ✅ v1.7(2026-07-10): **数式演算子と strict 添字記法** — レビュー指摘
   「dC2 のような関数でなく数式どおりに」を受け、.fme の座標軸微分は
   `∂_x` と `∂'^m_x` 形式を許す(dC/dC2/dTaylor は .fme から撤去)。
   現在は `field v~i @ staggered`・`field σ{~i~j} @ staggered` のように
   添字仕様から field layout を推論し、**テンソル添字方程式**が書ける:
   `v'~i = v~i + (dt/rho0) * contractWith (+) (∂_j σ~i~j)` /
   `σ'~i~j = σ~i~j + dt * (la * g~i~j * contractWith (+) (∂_k v'~k) + mu * (g~i~k . ∂_k v'~j + g~j~k . ∂_k v'~i))`。
   同じ上下添字が現れただけでは総和せず、縮約は `contractWith` または `.` で明示する。
   `metric g` 下の g~i~j は Euclidean 計量、∂_a は対象成分の配置にアンカーされた半セル差分
   (dYee)に落ち、対称成分は正準化(sigma_2_1 = sigma_1_2)。elastic3d.fme の生成
   .fmr は P/S 波速検証で green。
6. v2: 変数別境界条件、多段時間積分スキーム、Christoffel 一般計量、
   2D curl、4D 以上の Formura backend
   (Egison 側の sqrt(完全平方多項式) 簡約が前提; チップ発行済)。

## 6. 現在の到達点と残課題

現在の Formurae は、Egison のテンソル添字記法・微分形式・CAS を **表層言語から直接使える記述力**
として活用し始めている。Formurae が担当するのは、座標文脈、field layout、staggered 配置、
Formura 出力に必要な storage 名と境界だけであり、テンソル演算子の意味は
`withSymbols` / `contractWith` / ユーザ定義 `.` を中心とする Egison 型の規則へ寄せる。

1. **ユーザ定義テンソル演算子は実装済み**
   `def grad u = withSymbols [i] ∂_i u`、
   `def div X = contractWith (+) (∂_i X~i)`、
   `def Δ u = g~i~j . ∂_i ∂_j u` のように、結果添字を書かずに定義できる。
   `withSymbols` で導入された自由添字は呼び出し側の添字へ付け替えられる。

2. **縮約は `contractWith` と `.` だけが行う**
   同じ上下添字が現れただけでは暗黙総和しない。
   `∂_i X~i` は diagonal tensor であり、`contractWith (+) (∂_i X~i)` で scalar になる。
   `.` は標準 prelude の `def (.) A B = contractWith (+) (A * B)` として定義され、
   ユーザ定義で置き換えられる。

3. **`mode` が標準演算子族を選ぶ**
   旧 `use vector-calculus` / `use exterior-calculus` 宣言は撤去済みである。
   `mode collocated` は座標演算子を通常の TensorExpr prelude `Def` として登録し、
   `mode dec` は form context を生成する。ユーザーの同名 `def` は prelude を shadow する。
   標準座標演算子は `fec` が storage 成分へ特殊化し、`sym`/`wedge` など
   特殊化後にも残る Tensor 演算だけを Egison 側へ渡す。

4. **添字 equation は strict に保つ**
   添字付き field は宣言された添字つきで使う。各項の自由添字は LHS と上下まで一致する必要がある。
   上げ下げは自動化せず、必要なら `metric g` で宣言した計量と `.` を明示する。

5. **残課題**
   scalar 式は演算子優先順位を持つ TensorExpr AST として保持するようになった。
   parser error は式全体、失敗近傍、column を返すようになったため、次は source span つき診断と
   Egison 本体の添字規則との差分を小さくするテスト群を追加する。
   この整理が終わると、Formurae の新規性は「Egison の数式記法と CAS を、
   座標文脈つきの分散ステンシルコード生成へ接続する薄い表層言語」にさらに集中する。
