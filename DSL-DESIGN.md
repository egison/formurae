# Formurae 設計メモ — Egison 流の添字記法・微分形式をもつステンシル DSL

**命名(2026-07-10 確定)**: 表層言語(.fme)の名前は **Formurae**(フォーミュレ)。
Formura のラテン語風複数形で *formulae*(数式)への掛詞 — 「数式のまま書く」という
本言語の主題が名前になっている。Formura 設計者・村主崇行氏への敬意を込めた継承でもある
(「Formura 2」は本体の現行バージョン 2.3.2 と紛れるため回避)。

**v2.0(2026-07-11): pre-fec / Egison / FEIR / post-fecへのcutover** —
現在の責務境界は、以下のpipelineと `fec/src/Formurae/Pre/`、`fec/src/Formurae/FEIR/`、
`fec/src/Formurae/Post/` の実装、`spec/feir-primitives.sexp`、および検証testで規定する。
以下のv1.36以前の節は設計履歴として残すが、旧`fec`、native marker、generated derivative callback、
Egison-side FMR printerを現在の実装説明として読まない。

```text
.fme -> pre-fec -> .egi -> Egison -> .feir -> post-fec -> .fmr -> Formura -> C
```

`pre-fec`はfrontendとsource map、Egisonはtensor/index algebra・pure user function・analytic
differentiation、`post-fec`はplacement・exact stencil・auxiliary lifetime・storageを担当する。
pure operatorは`lib/formurae-operators.egi`の短い通常関数だけを定義元とし、
`grad`/`divg`/`curl`/`lap`/`d`等をHaskell macroやcomponent callbackへ複製しない。

**v2.1(2026-07-12): direct Egison user operator bodyとambient geometry** —
pure user `def`はsingle-line式だけでなく、`=`の次をindentしたEgison expression blockを受理する。
`let`、lambda、`match`、`withSymbols`、`generateTensor`の意味はEgisonが持ち、pre-fecは
source map、宣言scope、Formurae固有のeffect境界だけを扱う。model-local context引数は公開せず、
`dimension`、`coordinates`、`volume`、`epsilon`、`metric_i_j`、`inverseMetric~i~j`をambient
bindingとして生成する。`metric g`は`g_i_j := metric_i_j`と
`g~i~j := inverseMetric~i~j`を生成するため、whole tensorも`g_#_#` / `g~#~#`で参照できる。
これらのambient名とmetric宣言名はFormuraeの宣言siteでは予約し、raw Egison block内の局所binderだけは
通常のlexical shadowを許す。v1.27の同名scalarとmetricをwarningで共存させる規則は撤回し、衝突は
hard errorとする。

**v2.2(2026-07-13): quoted derivative、typed local、canonical form surface** —
通常の`∂_x e`は引き続きEgisonのproduct/quotient/chain ruleを使う解析微分である。
式全体を格子上でsampleしてから差分する場合は`` `(∂_x e) ``とbackquoteする。
`` `(∂_y (`(∂_x (`(∂_x e)))) ``の入れ子は内側からの軸順`x,x,y`と重複を保つ。
`TensorExpr`はこのchainと`[| e1, e2 |]_i`のtensor literalをstructured nodeとして保持し、
effect、source trace、normalizationをraw fallbackに逃がさない。

step-local storageは`local q_i @ primal = ...`の宣言に型・variance・policyを持たせる。
face fluxは`local q_i @ primal = [| ... |]_i`で保存し、通常の`divg q`と合成する。
暗黙のplacement変換は行わず、明示補間は`resample(value, bit...)`のみとする。
telescopingによる保存保証は周期境界またはfluxと整合するboundary処理の下で成り立ち、
物理境界条件自体はFormura/YAML側が権威である。

canonicalな微分形surfaceは`d`、`hodge`、`δ`、`Δ_H`、collocated scalar surfaceは`Δ`である。
`Δ`はcollocated-only、`δ`/`Δ_H`はDEC-onlyとする。variable geometryのscalar `Δ`と`δ`は
保存流束/weighted-adjointの内部discrete planへlowerする。constant geometryの`Δ_H`は
`d (δ A) + δ (d A)`のpureな合成であり、general variable-metric `Δ_H`は現IRで表現できないため
compile-time errorとする。離散化精度はoperator別名ではなくmodel-level profileに置く。
quoted derivativeとscalar `Δ`はscalar-only、form演算子は宣言済みscalar/`k-form`のみを受理し、
Egisonのcomponentwise tensor liftingへ入る前に検査する。symmetric/antisymmetric localとfield updateは
全rank-2成分の関係もnormalization境界で検査する。indexed `δ~i_j`はcompiler-owned Kronecker tensorへ
衛生的に解決し、ordinary ASCII `delta` user functionとは別namespaceとして振る舞う。

以下のv1履歴に現れる`gridD`、`orderedD`、`fluxDiv`、`materialize(expr)`、
`interpolate`、`dForm`、`codiff`、`formLaplacian`、`lb`、`flat`、`sharp`とそのaliasは当時の綴りであり、
現行surface APIとして読まない。

v2.1時点のPhase 10a（履歴、result variance規則はv2.5で置換）は、既存`TensorExpr`でparseできるbodyをFormurae derivative/opaque変換へ通し、
parseできないrich bodyをcontinuum-pureなraw Egison fallbackへ通す二経路である。raw body内の
Formurae derivative sugar、opaque primitive、branch単位のsource traceを同じdirect pathで扱うことと、
`TensorExpr` definition pathの削除はPhase 10bに属する。
structured bodyに名前が重複しないfree result indexが残る場合は、そのvarianceを構造的なfunction
contractとして付与するため、user-defined `curl`を`E + dt * curl B`のようなwhole-tensor合成へ使える。

このPhaseで使っていた解析微分のcanonicalization、離散精度profile、
whole-expression derivative、可変直交計量requestの綴りも、上記v2.2以前の履歴である。

FEIR v1はexact rational、stable logical ID、GeometryNF、FieldJet、opaque request、provenance、
registry/manifest/profile fingerprintを持つcanonical S-expressionである。FME exampleの追跡artifactと
gallery表示は`.fme / .egi / .feir / .fmr`の4段である。

**v2.3(2026-07-15): Egisonのrank-zero表現** —
`generateTensor f []`はtensor wrapperではなく唯一のcomponentを直接返す。このため、
`hodge`や`codiff`が生成するdegree-zeroの結果は`FE.tensorComponentAt ... []`を介さずscalarとして
合成できる。このruntime表現はFormurae frontendにおけるscalarと`0-form`の静的kindの区別を消さず、
FEIRでscalarを唯一のempty-basis componentとして符号化する規則も変更しない。

**v2.4(2026-07-15): ambient operator API** —
public `Formurae.*`のcontinuum operatorは数学的operandだけを引数に取り、
`coordinates`、`dimension`、`feGeometryScales`などのmodel情報はgenerated unitのtop-level
ambient bindingを直接参照する。normalization runnerはversioned library群とgenerated unitを
Egisonの同じinitial load batchに入れ、全definitionをrecursive bindした後にunitの`main`を呼ぶ。
generated `FormuraeInternal*`はambient引数を運ぶclosureではなく、lexical hygieneと
constant/variable geometryのdispatchだけを担う薄いoperand-only bridgeである。ただし、
汎用の`FE.*` tensor/geometry helperは再利用に必要な引数を明示的に取り、
`FEIR.encode*`もparameter/coordinate/field/function registryを明示的に受け取る。

**v2.5(2026-07-15): omitted down indexと明示的な計量縮約** —
user `def`のfunction headには結果添字を書かず、pre-fecはfunction名またはbodyからresult varianceを
推論・付与しない。`withSymbols`を出た自由な下添字はanonymousな省略軸になり、Egisonは各省略軸を
既存の明示添字とは別のfreshな下添字として補完する。したがって`E_i + A`でanonymous rank-1の
`A`を既存の`i`へ自動統合せず、両者は別軸である。equation targetにordinary covariant tensorが
明示されている場合だけ、normalization境界のindex completionがanonymous down軸をtargetの下添字へ
対応付ける。同じ下添字で中間式を合成する場合は、
`withSymbols [i] (E_i + (gradLike u)..._i)`のようにcall siteで明示する。up targetへの読み替えは行わず、
formの`dfOrder`もordinary tensorへ変換しない。

pre-fecはuser `def`本体の式構造や計算履歴を分類してresult contractを付けず、1行の式も
複数行のEgison式blockも同じ規則で評価する。評価結果をequationまたはindexed `local`へ格納する
時点でだけ、宣言targetが要求するshape・logical variance・`dfOrder`と実際の値を照合する。
関数headへ結果添字を追加する構文は導入しない。indexの上げ下げが必要なら、
`X'~i = withSymbols [j] (g~i~j . A_j)`またはindexed `local`の
`local A_i @ collocated = withSymbols [j] (g_i_j . X~j)`のように、計量との縮約を添字付きtargetへ
直接書く。`flat` / `sharp`はpublic Formurae operatorとして提供せず、計量操作の意味をsource
equationに可視化する。

**v2.6(2026-07-15): 座標∂の離散統一と解析`∂/∂`の表層化** —
「`∂_x u`が解析で`∂'_x u`が離散」という非対称を解消した。具体軸の添字つき`∂`
(`∂_a e`・`∂^m_a e`・`∂'^m_a e`)は全てexplicit-radiusの中心stencil要求
(`derivative.coordinate-wide@1`、radius = クォート数 + 1、素の`∂_a`はradius 1)に統一し、
operandは式全体をひとつのsampleとして保持する。model profileはこれらに影響しない。
既定profile(accuracy 2)ではradius-1要求と旧解析経路の選ぶstencilが一致するため、
既存exampleの生成Cは数値的に不変。解析微分の表層形はEgisonと同じ`∂/∂ e a`
(lexerが`FormuraeInternalAnalyticDerivative`へ写像し、emitがEgisonの`∂/∂`適用を生成、
FieldJetになりprofileが離散化を決める唯一の座標微分)。記号添字`∂_i`は従来どおり
解析テンソル微分+導入添字の自動縮約で変更なし。effect解析は、具体軸レイヤに
operand純粋性(`GridDerivativeOfDiscrete`、radius≥2も同様に強化)+coordinate-wide効果、
`∂/∂`に解析バリア(`AnalyticDerivativeOfDiscrete`)を割り当てる。
lib/FEIR encoderのradius>1検査はradius≥1へ緩和。

**v2.7(2026-07-16): 記号添字∂の離散化 — 「添字つき∂は常に離散」の完成** —
v2.6の残課題だった記号添字`∂_i`(解析テンソル微分)も離散へ統一し、
「解析は`∂/∂`(とそれを使うライブラリ演算子)だけ、添字つき∂は添字の種類によらず常に離散」
という規則を完成させた。記号添字`∂_i e`は**軸ごとのplacement誘導radius-1要求
(`derivative.grid-whole@1`)を並べたテンソル**に下り、導入した添字の自動縮約・自由添字の
扱いは従来機構をそのまま流用する(emit形`contractWith (+) (FormuraeInternalDiff e)..._i`は不変で、
ブリッジ本体だけ`Formurae.diff`(解析)→`Formurae.gridDiff`に交換)。`Formurae.gridDiff`は
`∂/∂`と同一のテンソル配管(`tensorMap2`+`flipIndices`)でカーネルだけ
`gridWholeDerivative`に差し替えた定義。placement誘導が本質で、centered限定にすると
elastic3dの半セルYee差分(∂_y σ^xy: [half,half,int]→[half,int,int])が書けない。
**検証: elastic3d(33微分葉が33 grid-wholeノードに1:1置換)とmaxwell3d(ユーザ定義curl、
12ノード)の.fmr/Cがbyte-identical+driver緑**。ライブラリ(grad/divg/curl/d/δ/Δ)は
`Formurae.diff`(`∂/∂ value coordinates`)を使い続けるため解析のままで、d²=0ゲート・
profile駆動の精度切替(highorder4)は無傷。effectは記号レイヤも格子要求
(grid-whole効果+operand純粋性)になり、入れ子の添字∂は「離散の離散」として
エラー(`local`で実体化するかΔ/hessianを使う)。残るStage 2候補=具体軸∂のplacement誘導化と
クォートの順序チェーン専用化。

**v2.8(2026-07-16): 素の∂のplacement誘導化とクォートのチェーン専用化(Stage 2)** —
離散∂族に残っていた振る舞いの分岐を畳んだ。**素(無プライム)の一階`∂_a e`は
記号添字と同じplacement誘導radius-1差分(`derivative.grid-whole@1`)**になり、
collocatedでは中心差分に退化、staggeredでは半セルYee差分を導出する
(旧centered限定では記号経由なら書ける操作が具体軸だとエラーになる非対称があった)。
次数・プライム付き(`∂^m_a`・`∂'^m_a`)はexplicit-radius中心stencil
(`derivative.coordinate-wide@1`)のまま。この結果、単発クォート`` `(∂_a e)``は
素の形と完全に同義になるため**エラー化**し(「write the coordinate derivative
unquoted」)、バッククォートの∂読みは**2段以上の順序チェーン専用**
(`derivative.ordered@1`、Schwarz正準化を適用しない列)に縮小した。
diffusion1d/2dのflux localとks3dのfluxはクォートなしの素の形に書き換え
(排出されるEgison呼び出し文字列は旧クォート形と同一で、生成.fmr/Cはbyte不変)。
CAS側のquote(`` `(2 + cos θ)``の原子化)は別機構でそのまま。
規則は「素の∂=格子の自然なradius-1差分/プライム=明示半径のcentered/
チェーン=順序列/解析=∂/∂」で完成。

**v2.9(2026-07-16): 表層`∂/∂`のcoordinates形 — 解析テンソル微分の表層化** —
表層`∂/∂`の第2引数にambientの`coordinates`ベクトル(添字なし・`coordinates~i`)を許した。
Egisonライブラリの慣用形(`Formurae.diff`の本体`∂/∂ value coordinates`、curl本体の
`∂/∂ X_k coordinates~j`)がそのまま.fmeで書けるようになり、v2.7で失われていた
「ユーザ定義の解析テンソル演算子」が新記法ゼロで復活
(`def gradLike u = ∂/∂ u coordinates`は解析gradientで、anonymousな微分軸が
equation boundaryで`q_i`へ補完される — 実測で(u[i+1]−u[i−1])/(2dx)の
profile中心差分に降りることを確認)。単一座標形は従来どおりoperandのkindを保ち、
coordinates形は微分軸が増えるためkindはStaticUnknown(`coordinates`を
ambient tensorとして静的環境に登録)。gradLike系のfixture 3本と論文§4の例を
解析綴りへ更新(境界診断の位置・文言は不変を実測)。これで表層は
「解析=∂/∂(単一座標またはcoordinatesベクトル)/添字∂=常に離散」の対称形になった。

**v2.10(2026-07-16): surface macro — let-insertion による文の生成** —
`def`(式=Egison が値に評価)と対になる **`macro`(文列=pre-fec が展開)** を導入した。

```
macro Δc u =
  local q~i @ primal = withSymbols [j] (volume * (inverseMetric~i~j . ∂_j u))
  in (divg q) / volume

step:
  u' = u + dt * Δc u
```

呼び出しは step 式の中に書け、展開は **parse 直後・全解析の前**に行われる:
本体の `local` 束縛は fresh 名(空いていれば元名を保持、衝突時は q2, q3, …)で
呼び出し元 step の直前へ持ち上げられ(let-insertion; MetaOCaml genlet /
Kameyama–Kiselyov–Shan / LMS の系譜)、呼び出し位置には `in` 式が入る。
下流(effect・kind・placement 検査、emit)はマクロを一切知らず、展開結果に
既存の全検査と展開トレース機構がそのまま働く。持ち上げ先が常に enclosing step
先頭で制御フローも高階束縛もないため、一般の let-insertion の難所
(scope extrusion)は生じない。v1 の制約: マクロは step 式専用(init・def・
metric/embedding 内はエラー)/引数は添字なしの出現のみ/再帰は深さ 32 で
エラー/本体の withSymbols 束縛子が引数の添字と衝突する呼び出しはエラー
(暗黙捕獲の拒否)。**検証: マクロ版トーラス Δc の生成 .fmr が手書き展開形と
完全一致**(tests/pre_macro_expansion.sh)+衛生(2 呼び出しで q/q2)+
エラー4種の CLI 検査。これで「lb.orthogonal はこのマクロ機構の不在を
post-fec への直書きで代替したもの」という位置づけが実装で裏づけられ、
Δ/δ のライブラリマクロ化(scheduled 要求の解消)への道が開いた。

**v2.11(2026-07-16): scalar/tensor 静的検査への縮約・遅延 local・汎用 codiff マクロ** —
静的 kind 検査から form 次数の追跡を撤去し、**scalar / tensor(/unknown)だけを
検査する**仕様に縮約した。次数の正は Egison と同じく値自身(`dfOrder`)にあり、
既存の encode 境界 assert(宣言 metadata と実測の突き合わせ)と FEIR Validate が
正規化時に検査する。canonical d/⋆/δ/Δ_H は静的には全 operand を受け、
非 form への適用はライブラリの実行時ガード
(`Formurae.isDifferentialForm` = `dfOrder = rank`;δ が通常テンソルを黙って 0 に
潰す事故をエラー化)が origin 経由の source 位置つきで落とす。scalar 専用検査
(quoted ∂・scalar Δ)は componentwise lift 事故防止のため静的なまま残す。

この上に **遅延 local(`local w : tensor @ policy = …`)** を導入した。宣言は
rank・variance・次数を書かず、writer の値から正規化時に決める: FEIR field 宣言は
値駆動で構築され(`FEIR.deferredLocalFieldDecl`)、reader 束縛・fieldEntry 列挙も
値の shape/dfOrder から生成される。registry fingerprint は schema 2 で
**step-local を identity から除外**した(local は runtime equations の
materialization 対象であり、equations は元々 identity の対象外という宣言に整合;
遅延宣言の placeholder/解決後の不一致も根治)。ゲート: 宣言版と桁を揃えた遅延版の
FEIR が identity マスク後に byte 一致(2-form / vector / scalar、
tests/pre_deferred_local.sh)。

最後に次数汎用のライブラリ部品
**`dFlux`(重みつき flux: w_I = V·∏_{i∈I}g^{ii}·A_I、同一添字集合なので staggered
parity と整合)/ `dFluxDiv`(符号込み随伴発散:
(δ-div w)_K = −(∏_{k∈K}g_kk/V)·Σ_i gridD_i w_{iK}。微分添字を先頭スロットに置く
規約で δ の次数依存符号 (−1)^{n(k+1)+1} は全次数で単一の − に潰れる)/
`dExterior`(placement 誘導 grid ∂ の交代和)/ `dHodge`(⋆ そのもの;
成分が補集合へ移るため materialize 用ではなく診断・flat 用)** を追加し、
**codifferential が 1 本のマクロ**になった:

```
macro δc A =
  local w : tensor @ primal = dFlux A
  in dFluxDiv w
```

次数分岐はどこにも書かれない — `dFlux`/`dFluxDiv` が `dfOrder` を読み、遅延 local が
その次数で実体化する。ゲート(tests/pre_generic_codiff.sh): (1) トーラス
(可変計量・staggered)で `u' = u + dt*(0 − δc (dExterior u))` の .fmr が
検証済み手書き保存形と **local 名を除いて byte 一致**; (2) maxwell_dec
(flat Yee)で `δc B`(2-form!)が組み込み `δ B` と、恒等 flux local の代入と
−(a−b)=(b−a) の正規化だけで .fmr 一致、**C 実行出力は bit 一致**。⋆ を
materialize しない理由も記録する: ⋆ は成分を補集合 basis へ移すため、staggered
格子では材料化した瞬間に basis parity と値の parity が食い違う。musical
重みづけ(dFlux)は添字集合を保つので parity 整合であり、これが「保存形は
flux 形で書く」ことの型・配置レベルの説明になっている。

**v2.12(2026-07-16): canonical Δ/δ の prelude マクロ化 — scheduled 要求の退役** —
宣言幾何(metric scale / embedding)を持つモデルでは、canonical **Δ と δ が
prelude マクロ**として注入され(ユーザ束縛が同名なら注入しない=shadow 優先;
'δ'/'Δ' はユーザマクロ名として書けないので衝突しない)、既存のマクロ展開機構が
呼び出し部位を書き換える。表層の綴りは不変のまま、下ろし先が opaque な
scheduled 要求(lb.orthogonal@1 / codiff.metric@1)から**公開演算子の展開**に変わる:

```
macro δ A = local codiffCoeff : tensor @ primal = dFluxWeights A
            local codiffFlux  : tensor @ primal = dFluxScale codiffCoeff A
            in dFluxDiv codiffFlux
macro Δ u = (同形、A = dExterior u、結果は 0 −)
```

係数 local は幾何のみ(dFluxWeights は operand を次数にしか使わない)なので、
post-fec が **field-jet を含まない materialize を凍結**する: per-basis の
init 割当+恒等 carry で persistent state 化し(compileMaterialization の
jet-free 分岐)、生成 .fmr は旧 lb と同型(init 係数配列+identity copy+
配列 flux+保存形 update)になる。凍結は性能だけでなく、壁境界(mirror/fixed)
が state 配列に働くという意味で境界条件との整合でもある。定曲率では従来どおり
解析経路(scalarLaplacian / codiff)。副作用として旧ゲート
「δ は mode dec 専用」は消滅し(要求時代の制約)、宣言幾何なら collocated でも
δ が書ける。def 本体・init・幾何式の中の Δ/δ は「macro ... expands to step
statements」でパース時に拒否される(文を生成するため)。

この移行で **vendored Formura の 7 年級バグ第 2 弾を根治**した:
`LoadIndex`(step 式中の裸添字算術)が (1) Manifestation の Shift cursor、
(2) カーネルの range offset、(3) フレームのコピー margin を全て無視していた。
Formura は全周期モデルを**シフト枠**(コピー margin 2·sleeve、`n->offset_*` が
毎ステップ −sleeve)、壁ありモデルを**アンカー枠**(margin sleeve、offset 固定)で
走らせており、正しい発行は
**`idx + cursor + toOffset(rng) − copyMargin + n.offset + block_offset`**
(copyMargin = 全周期 ? 2·sleeve : sleeve)。単段カーネルでは補正が 0 になるため
既存の veteran 生成物は不変で、位置依存係数を step で計算する多段プログラム
(まさに旧 lb が state field 化で回避していたクラス)だけが影響を受けていた。
検証: 1D 二段最小再現が bit 一致、metric_torus(シフト枠)3000 ステップ 2e-14、
metric_sphere(アンカー枠・mirror)4e-16 で参照一致。6 つの宣言幾何例題は
`field u : scalar @ primal` へ移行し(保存形は staggered flux の宣言)、check 群の
体積重みは生成配列読みから解析式へ分離した(コンパイラ内部名への依存を除去)。

**v2.13(2026-07-17): `assert-dd-zero` の撤去** —
表層唯一の assert 文だった `assert-dd-zero` を言語から削除した。解析経路の
well-kinded な形式に対して d(dA)=0 はライブラリの定理であり、ゲートが落ちるのは
(1) ライブラリ回帰 — compiler suite の一般形テスト(one-form の d∘d=0 等)が既に
カバー、(2) kind 誤り — ライブラリ d のガードとして同経路で報告される、
(3) 離散 request を含む operand — step 側の正規化が同じ欠落微分規則エラーで先に
落ちる — の3通りで、いずれも他所で同等以上に検出される。恒等式ごとに専用
キーワードを増やす設計はスケールせず、「ユーザが宣言する生成時 obligation」の
カテゴリごと撤去した(将来必要なら汎用 `assert-zero` として新規設計する)。
実装は mDd フィールド・dec 専用ゲート・feContinuumDD/feContinuumAssertions 生成・
main の条件分岐を全て削除し、`assert`/`main` 等の予約依存名の配管は維持。
maxwell_dec は行削除のみで .feir/.fmr バイト不変、離散 div B ≡ 0 は check driver の
実測で従来どおり成立。ついでに README / usage.html に残っていた v2.12 反映漏れ
(「可変計量の δ は post-fec が補助 field を計画」等の要求時代の記述)も
prelude マクロ+凍結の現行記述へ更新した。

**v2.14(2026-07-17): versioned 機構の撤去 — 契約同一性は fingerprint に一本化** —
手で振る版番号を protocol から全廃した: wire ヘッダは `(feir (model ...))`
(版数アトム削除)、op ID は `derivative.ordered` 等(`@1` 削除)、manifest の
`(op name version)`/`(schema ... 1)` は版数なし形へ、profile の `version` フィールド
(`formurae-discretization@1`)は削除、semantic key は `feir:`/`feir-group:` 接頭辞、
`VersionedOpId`→`OpId`・`feProgramVersion`/`opVersion`/schema version フィールド削除、
生成 binding の V1 命名(`primitiveManifestV1Id` 等)と内部予約ヘッドの V1 接尾辞も除去、
`spec/feir-primitives-v1.sexp`→`feir-primitives.sexp`・`egison-normalization-v1.list`→
`egison-normalization.list` に改名。**安全装置は fingerprint(manifest/registry/profile の
内容ハッシュ)に一本化**: 版番号が検出できた不整合はすべて fingerprint が内容ベースで
検出するため、独立に維持する意味がなかった(fingerprint preimage 内の schema タグは
ハッシュ入力の曖昧性排除として維持)。移行で1件の Egison 評価の癖を踏んだ:
版数アトム除去後の wire リテラル(`FEIR.list [atom, 巨大list, ...]`)がこの規模の unit
で偽の数学型エラーを誘発するため、renderWire はプログラムルートだけ等価な
`FEIR.record "feir" [...]` 綴りで出力する(レンダリング結果は同一バイト)。
検証: compiler suite 全緑・make all 38/38・**全例題の .fmr はバイト不変**
(.egi/.feir は op ID・semantic key・fingerprint の機械的差し替え)。

**v2.15(2026-07-17): スタガード奇数階の半整数半径 — 幅則をパリティ整合へ一般化** —
スタガード格子上の奇数階微分に半整数の実効半径を導入し、幅の禁止則を
「奇数階は不可」から「半径と階数のパリティ不一致は不可」へ縮小した。一般則は
2r ≡ m (mod 2)・点数 2r+1・形式精度 2r − m + 2(パリティ整合の対称 stencil は
奇数階でも +2 ボーナスが効く)。
(1) 明示半径∂(`derivative.coordinate-wide`): 自然ターゲットがトグルする場合
(スタガード×奇数階)、radius 属性 k をペア数と読み、ターゲット中心
±1/2…±(2k−1)/2 の半整数対称 stencil(実効半径 k − 1/2)を厳密に解く
(`staggeredTaylorAtPairs`: 倍オフセット整数表現+exact RREF+モーメント/
パリティ/端係数の再検証)。格納オフセットへの写像は operand の placement bit が
向きを決める(integer source → {−k+1..k}、half source → {−k..k−1};
`staggeredStorageWeights` = `yeeFirstWeights` の一般化)。不可能ケースが消えた
`WideCenteredPlacementChange` は撤去。プライム読みは全格子で一様に
「素の形 = 格子の最小 stencil、プライム 1 個 = +1 リング」になり
(collocated `∂'_x` = r2 ↔ staggered `∂'_x` = r3/2 = FDTD(2,4) の ±9/8 ∓1/24、
`∂''_x` = r5/2 の 6 点)、既存の有効プログラムの意味は不変(旧エラーだけが
意味を得る)。
(2) profile(解析 `∂/∂` 系): staggered/yee 行の accuracy 2 固定を撤廃し、任意の
正偶数 accuracy 2k を受理(pre 検査も同時に緩和; 次数 1/2 制限は維持)。
1 階則はペア数 k の半整数 stage を保持(`ResolvedYeeStencil` が解いた
`StaggeredStencil` を運ぶ)、**2 階則は 1 階 stage の自己合成**
(`composeStaggeredPair` → 半径 2k−1 の centered stencil、k=1 は [1,−2,1] に退化)。
これで Δ = divg∘grad が全精度で恒等的に成立する因数分解形が profile の正になり
(最小 Taylor の直接 5 点は明示 `∂'^2` の役割)、halo は 1 階 = k・2 階 = 2k−1。
`UnsupportedYeeFormalAccuracy` は撤去、`CenteredStencilError` は
`ProfileStencilError` に改名。**ワイヤ・manifest・fingerprint は不変**
(radius 属性の解釈だけを post-fec で精密化)。チェーン(ordered)各段と
grid-whole の素の∂は最小幅のままで設計不変。
検証: staggered stencil 単体 fixture(k=1/2/3・3 階・合成 7 点
[1/576, −3/32, 87/64, −365/144, …])+wide 両向き 4 点 lowering+profile
accuracy-4 規則を suite に追加し全緑、make all は全例題 .fmr バイト不変。
新例の実測: `∂'_x` → ±9/8 ∓1/24、`∂''_x` → ±75/64 ∓25/384 ±3/640、
accuracy 4 の Δ 形と flux 形が同一の合成 7 点に合流。
残: 3 階以上の staggered profile 則・境界の片側化は将来課題。

**v2.16(2026-07-17): staggered profile 則の全次数化 — m 階則 = 1 階 stage の m 重自己合成** —
v2.15 の残課題(1)を解消し、staggered/yee 規則の次数制限(1/2 のみ)を撤廃した。
一般構成は「m 階則 = 精度 2k の 1 階半整数 stage の m 重自己合成」
(`composeStages`: 倍オフセット畳み込み+正準レイアウト化、偶数重 →
centered stencil(operand の部分格子に着地)・奇数重 → staggered stencil
(双対部分格子に着地))。全段が同一シンボル ∂·(1 + O(h^{2k})) を共有するため
合成の形式精度は 2k のまま保たれ(最初の誤差項 ∂^{m+2k} が次数 m+2k−1 以下を
零化)、解決時に moment/パリティ/端係数検証器が各インスタンスを再検査する。
これで ∂^m = (∂)^m の恒等(Δ = divg∘grad・∂³ = grad∘Δ・∂⁴ = Δ∘Δ …)が
全次数・全精度で成立し、v2.15 で明示 `∂'^m` が獲得した任意次数と解析経路が
対称になった。最小幅では合成 = 直接解の縮退が全次数に伸びる
(3 重 = [−1, 3, −3, 1] = `staggeredTaylorAtPairs 3 2 2`・4 重 = [1, −4, 6, −4, 1] =
`centeredTaylor 4 2`、単体テストで一致を assert)。撤去: Pre 検査の次数上限・
`UnsupportedStaggeredDerivativeOrder`(validateRule は staggered/yee を無条件受理、
不正はステンシル層が検出)。`composeStaggeredPair` は `composeStages` に一般化
(2 重の特殊形は同一重みを出力するため既存例題はバイト不変)。halo は
resolvedRuleRadius が合成結果から自動導出(m(2k−1) の半分)。
検証: 単体(合成=直接の縮退 m=3/4・k=2 の 3 重 pairs 5/端 ±1/13824)+
suite 全緑+make all 全例バイト不変。実測: 解析 3 重 `∂/∂` が
(u[i+2] − 3u[i+1] + 3u[i] − u[i−1])/dx³(明示 `∂'^3_x` と同一 = 経路合流)、
`Δ (Δ u)` が [1, −4, 6, −4, 1]/dx⁴(解析エンジンが Δ∘Δ を 4 階 jet に畳む)、
accuracy 4 の 3 階が 10 点(端 ±1/13824 = ±(1/24)³、全 5 対が半点まわり反対称)。
残: 境界の片側化(staggered SBP 閉包)のみ。

**v2.17(2026-07-17): 境界の片側化 — staggered SBP 閉包+SAT(Phase 0–3)** —
v2.16 の残課題を実装し、物理境界を持つ領域で ghost を一切読まない
summation-by-parts 離散化を通した。
**Phase 0(作用素層)**: `SbpStaggeredPair`(2 次内部対)を Stencil.hs に構成。
D⁺ は閉包不要、D⁻ は両端 1 行の片側行(row₀ = (q₁ − q₀)/h)、
H_p = h·[1/2, 1, …, 1, 1/2]・H_d = h·I・外挿 d₀ = (3/2, −1/2)。
`validateSbpStaggeredPair` が有限 N(8/9/12/17)で**厳密 SBP 恒等式
H_d D⁺ + (H_p D⁻)ᵀ = d_N e_Nᵀ − d₀ e₀ᵀ を成分ごとに検証**し、さらに全行の
境界次数・外挿精度・ノルム正値・「2 階閉包行 = D⁻D⁺ の合成」まで再検査する。
高次内部(k ≥ 2)の閉包構成は未実装(`UnsupportedSbpInterior`)。
**Phase 1(言語配管)**: 新 opaque `derivative.sbp-staggered`(表層 `sbpd_x e`
= 1 階・`sbpd2_x e` = 合成 2 階)を grid-whole の写経で全層貫通
(sexp+生成器・operators/feir.egi・Pre の parse/effect/kind/emit・post-fec)。
post-fec は境界行を **index guard の FSelect**(`if i == 0 …
else if i == total_grid_a − 1 …`)で emit し、閉包行は域内サンプルしか
読まないため fork の `boundary: [fixed g]` でも周期でも安全。1 階は
half→int が閉包つき・int→half は閉包不要の interior のみ、2 階は
integer 配置限定(half は明示エラー)。collocated operand は
`SbpRequiresStaggeredLattice`。SAT は新機構なしで**表層の `if x < xlo …` +
param** で書ける(dx は CAS 非束縛のため係数・しきい値は param に置く)。
**Phase 2(拡散実測)**: 新例題 sbp_diffusion1d(壁 = primal 両端、
Dirichlet SAT = −2τκ/h²·u·guard、flux は `local q @ dual`)。driver 実測:
厳密モード誤差 2.74e-05(N=64, t=100)・SBP ノルムエネルギー毎ステップ単調・
壁 1.2e-05。**N=128 で誤差 6.75e-06 → 比 4.05 = 実測 2.02 次収束**。
**Phase 3(波動+2D 角)**: sbp_wave1d = pressure-release 壁の音響系を
Yee 流 leapfrog(`v' = v − dt ∂_x p; p' = p − dt (sbpd_x v' + SAT)`)で
1 周期(T = 2L)回して回帰誤差 5.0e-03・エネルギー帯 ±1.5%(成長なし)・
壁 1.7e-06。sbp_diffusion2d = 軸ごとの `sbpd2` + 4 辺 SAT の加法だけで
**角は自動成立**(専用処理なし): モード誤差 1.73e-04・エネルギー単調・
辺 7.8e-05・角 1.0e-08。3 例題とも make 登録済み。
新 primitive により manifest ハッシュが更新(既存例題は .egi/.feir の
ハッシュ行のみ差し替え・.fmr/C バイト不変)。
残: 高次(k ≥ 2)SBP 閉包の構成器・Neumann/特性 SAT の定型化・
境界宣言の言語化(現状は yaml + 表層 SAT の組で明示)。

**v2.18(2026-07-17): 成分射影 — 添字つき場の具体軸成分をスカラーとして名指す** —
`∂_x`/`∂_i` と同じ判定規則(添字が宣言済み軸名なら具体、そうでなければ記号)を
場の参照へ拡張し、宣言済みの添字つき field/local に対する `q_x`・`T_x_y` を
**成分射影**として定義した。preprocess(TensorExpr)が軸名添字を 1 始まりの
軸位置へ書き換え(`q_x` → `q_1`)、Egison のネイティブな具体添字アクセスに
そのまま乗る。**束縛テンソル値が対称/反対称の鏡像成分(符号・零対角込み)を
実体として持つため、正準化・符号処理は一切不要** — 射影は純粋な
軸→位置の改名だけで正しい。placement は従来どおり (policy, 成分基底) から
導出されるので、post-fec は無変更で `sbpd_x q_x` の閉包選択・配置検査・
パリティ法則が全部そのまま効く。検証は 2 段: token 層(Parse、`_` 綴り)と
AST 層(emit walk、`~` 綴りも捕捉)の `invalidAxisProjection` が、
混合添字(`T_x_j`)と宣言不一致(variance 反転 `q~x`・ランク超過 `q_x_y`)を
位置情報つきで拒否する(軸名を含まない添字は従来どおり記号読みで無変更)。
LHS は既存の whole-field target 制約により自然に対象外(RHS 専用)。
実測: sbp_diffusion2d を flux 形
(`local q_i @ primal = [| κ∂_x u, κ∂_y u |]_i; u' = u + dt*(sbpd_x q_x + sbpd_y q_y + SAT)`)
に書き換えた変種が全パイプラインを通り、**元の check driver をそのまま通過**
(モード誤差 1.726e-04・角 1.009e-08 = sbpd2 版と同一値;閉包∘D⁺ = sbpd2 の
合成恒等式が E2E で成立)。既存モデルへの影響: 軸名を記号添字に使う既存例は
なし(全例題 .fme を確認)、ワイヤ不変・全例題バイト不変。
残: 混合射影(`σ_x_j` = 行ベクトル)・式レベル一般射影(`(grad u)_x`)・
宣言レベル `component x @ primal`(FEIR スキーマ拡張が要る)は将来課題。

**v1.36(2026-07-11): runtime tensor lowering と Phase 7 完了** —
標準6演算子だけでなく、一般の indexed equation、implicit vector equation、rank-1/rank-2
indexed `let`、indexed CAS initializer を、成分別 Haskell 式へ展開せず whole runtime tensor として
Egison へ渡すようにした。`RuntimeTensorExpr` は symbolic index を予約内部名へ alpha rename し、
転置、`tensorMap`、`subrefs`、明示縮約、user `def` の複合式を保持する。LHS の添字数・上下から
rank/variance signature を作り、Egison の `FE.checkedTensorSignature` が `tensorShape`、
`tensorVariances`、`dfOrder` を最終検査する。production 生成経路から `ixExpand` /
`ixExpandInitializer` と legacy component operator expansion は撤去した。

runtime binding は located (`Collocated` / `Primal` / `Dual`) と placement-neutral を区別する。
定数だけの `let` はどの lattice でも使え、field を含む式は component basis ごとに policy を推論する。
binding は逐次 scope を持ち、self/forward reference、initializer から step binding・primed field への
参照を早期エラーにする。CAS initializer は neutral RHS を target 位置で sample し、located RHS は
`FE.relativePlacement` による target-minus-source offset だけを適用するため、同一 lattice の field を
二重 shift しない。explicit coordinate と non-collocated field-valued RHS の混在は単一 substitute で
正しく分離できないため、誤生成せず明示的に拒否する。

固定軸 `∂_x` と symbolic 軸 `∂_i`、微分階数・stencil radius は同じ runtime derivative bridge に
統合した。複合 operand の自由添字は source component basis として保持するため、
`∂_x (A_i * c)` も staggered `A_i` の実配置から微分する。`∂^m_i` は
`FE.diagonalCoordinateDerivative` が rank-1 tensor を作る。
`contractWith max` のような名前付き reducer は `FE.symbolicBinary` により Formura の symbolic function
call として保持し、field component の grid reference と区別して表示する。

`fec` に残る `TensorExpr` は surface parse、user `def` 展開、scope/source provenance、静的診断、
Egison runtime bridge を担う。`strictEinstein` は自由添字・variance・明示縮約の surface diagnostic、
basis-aware Haskell placement validator は Egison 実行前の frontend static oracle として意図的に残す。
どちらも component 式や stencil を生成する backend lowering ではない。runtime tensor 評価、
result signature、placement/stencil の実行意味は Egison kernel を権威とする。

**v1.35(2026-07-11): descriptor-driven whole fields + native tensor operators** —
Phase 2 の field descriptor を完成させ、生成 `.egi` は field ごとに
`(name, GridPolicy, shape, variances, layout, projection, storageMapping)` を一度だけ持つ。
`FMR.fieldEqs` / `FMR.fieldInits` は descriptor の整合性と RHS の policy/shape を検査し、
scalar/vector/symmetric/antisymmetric/full/form の独立成分を同じ metadata から射影する。
field-name map と policy table も descriptor から導出する。

Phase 3/4 では `grad` / `dGrad` / `divg` / `curl` / `lap` / `hessian` を generated equation
path から共有 `FE.*` tensor operator へ接続した。generated `feTensorDerivative` callback は
target/source policy、component basis、微分軸列を `FE.gridDerivativeChain` に渡す。
同一軸の二階微分は `dC2`、mixed derivative は一階微分の合成、配置が異なる場合は中間
placement を推論した `dYee` になる。標準演算子の marker は高階 `def` を通っても identity を
保ち、ユーザーの同名 `def` は従来どおり shadow する。

Phase 6 は複数の distinct `lb` source、metric-aware form Hodge/codiff、直交計量の rank-1
`flat` / `sharp` まで実装した。`lb` は metric coefficient/volume fields を共有し、request ごとに
flux/result bundle を持つ。`flat` / `sharp` は policy を保つ純粋な musical map であり、補間、
de Rham map、reconstruction を含めず、scale factor は component basis の配置で sample する。
この時点の Phase 7 は標準6演算子と whole-field printer までであり、native subset 外の複合式、
user tensor `def`、indexed initializer には component fallback が残っていた。この残余は v1.36 で
runtime tensor lowering へ移行した。元 `.fme` への source map は transliteration 前の
path/line/column を保持し、user `def` を跨ぐ backend request には definition-site / call-site を
nested trace として表示する。initializer の backend request も同じ provenance 経路を使う。

**v1.34(2026-07-11): Phase 6 geometry + structural `lb` planner** —
`embedding` からの induced metric、直交計量と逆計量、体積要素、Hodge coefficient
の純粋な記号式を `lib/formurae-geometry.egi` へ移した。Laplace--Beltrami も
`FE.lbFlux` と `FE.lbFromFluxes` の structural flux-divergence 合成として
Egison で評価し、生成コードは格子固有の gradient・divergence・coefficient
callback だけを与える。

表層の `lb u` は `BackendRequest` として TensorExpr から構造的に収集し、
`LbPlan` / `AuxFieldPlan` が係数場 `ca` / `cb` / `cc` / `sg` と flux 場
`f1` / `f2` / `f3` の role・placement・lifetime metadata を作り、専用 emitter が
固定 Laplace--Beltrami scheme の宣言・初期化・step を materialize する。旧 token scan の
`lbTargets` / `lbPass` は削除した。保存済み flux は divergence から実際に参照され、
既存 metric 5例の `.fmr` は移行前と一致した。この最初の planner を v1.35 で複数 request、
metric-aware form Hodge、orthogonal `flat` / `sharp` へ拡張した。各 `lb` operand が
unindexed collocated scalar field であるという制限は維持する。

**v1.33(2026-07-11): GridPolicy・Egison geometry・Tensor form** —
Phase 2/3 と Phase 5 を実装した。field の配置は型付き
`GridPolicy = Collocated | Primal | Dual` と成分添字 parity から
`lib/formurae-grid.egi` が導出し、生成コードに配置 vector を直書きしない。
異なる配置の assignment・加減算と、policy propagation に反する curl は
暗黙補間せずコンパイルエラーにする。Yee Maxwell は
`field E_i @ primal` / `field B_i @ dual` の `.fme` から生成する。

微分形式は旧 `(complex, degree, [components])` ではなく
`(GridPolicy, Tensor MathValue)` である。`FE.canonicalFormTensor` が反対称性、
`dfOrder` が degree、`FE.formComponents` が独立成分 projection を担う。
`d`・`hodge`・`δ` は `lib/formurae-geometry.egi` の共有定義へ移し、生成側は
座標依存の `feFormDerivative` だけを渡す。`FMR.fieldEqs` は field descriptor と whole-form equation
から Formura storage を生成するため、生成コードの `formComps` / `formDeg` と
成分別 form RHS は削除した。Phase 4 の共有 tensor operator
`FE.grad` / `FE.dGrad` / `FE.divg` / `FE.curl` / `FE.lap` / `FE.hessian` は
v1.35 で generated equation path へ統合済みである。

**v1.32(2026-07-11): Egison 中心の tensor equation への移行開始** —
テンソル・添字・格子配置の意味論を `fec` から Egison へ移す方針を定めた。配置は将来
`Collocated` / `Primal` / `Dual` の3 policy と補完後の成分添字 parity から導出する。
field 構文は `@ collocated` / `@ primal` / `@ dual` に統一した。実装の Phase 1 として Egison 本体に
構造化された `tensorIndices` と library helper `tensorSignature` を追加した。
Formura runtime には tensor-valued RHS の printer を追加し、collocated indexed vector の
生成を成分別 `feqE1...` から単一の tensor RHS へ変更した。その後 v1.35 で完全 field
descriptor と `FMR.fieldEqs` に統合し、target/storage 情報も descriptor の一箇所へ集約した。

**v1.31(2026-07-11): bare tensor binding への統一** — Egison 本体が
`def E := generateTensor ...` の全成分へ既定の下添字を補い、関数シンボルを
`E_1`, `E_2`, ... と命名するようになった。生成 `.egi` の field・primed field・
form・内部 metric はすべて bare binding にし、indexed `let` も
`def T := withSymbols [i] ...` と生成する。これにより `def E := E_#` のような
whole-tensor alias と、その必要性を判定する残余式走査を完全に撤去した。
bare Egison 名の衝突を防ぐため、`param`・`field`・`let`・`local` は同じ値名前空間を
共有し、同名を複数宣言した場合は `fec` がコンパイル時にエラーにする。
`feDim`、`feAxes`、`feCoords`、`feq...` など生成 Egison が所有する名前との衝突も
同様にコンパイル時エラーにする。`generateTensor` などの Egison 予約語と、
`contractWith` など生成コードが非修飾で参照する helper 名も予約する。

**v1.30(2026-07-10): 中間 Egison の特殊化と共有 runtime** —
`grad`、`dGrad`、`divg`、`curl`、`lap`、`Δ`、`hessian` は、モデルごとに
Egison 関数定義を出す方式をやめ、この段階では `fec` 内の TensorExpr prelude `Def` として
ユーザー `def` と同じ解決経路へ統合した。v1.35 ではさらに標準 operator の native identity を
保持して共有 `FE.*` kernel へ渡すため、標準演算子の storage 成分特殊化は generated path から
撤去した。ユーザー定義は標準定義を shadow できる。
この統合時に `hessian u` を `∂_i ∂_j u` として修正した。
Formura プリンタは `lib/formurae-runtime.egi` に一度だけ定義し、生成 `.egi` は
名前変換表・座標ベクトル・格子幅を明示的な data context として渡す。
さらに残余式の依存から collocated 微分、Yee helper、参照された metric variance を
必要時に限って生成し、DEC form context は `mode dec` で選択する。これにより
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
であるため、真の incidence-only cochain DEC と区別する。vector/covector 間の
`flat` / `sharp` は v1.35 で補間を含まない純粋な orthogonal musical map として追加した。
de Rham/reconstruction と DEC vector aliases は引き続き別設計である。
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

**v1.26(2026-07-09): Egison 型のユーザ定義テンソル演算子と縮約** —
`.fme` の `def` は Egison と同様に結果添字を書かない。
例えば `def grad u = withSymbols [i] ∂_i u`、
`def div X = ∂_i X~i`、
`def (.) A B = contractWith (+) (A * B)`、
`def Δ u = g~i~j . ∂_i ∂_j u` のように書く。
`withSymbols` の外へ出る自由添字は呼び出し側の添字へ付け替えられ、
`∂_i` は微分で生じた同名の上下添字を `contractWith (+)` で縮約する。
それ以外の縮約は `contractWith` と、その上にユーザ定義された `.` が行う。
平坦 Laplacian は `metric g` のもとで `g~i~j . ∂_i ∂_j u` から
`∂^2_x u + ∂^2_y u + ∂^2_z u`、さらに通常の3点二階差分へ下りる。

**v1.27(2026-07-09): `δ` と metric 名の分離** —
この節の同名scalar/metric共存とmixed metricは履歴仕様であり、v2.1で撤回した。現行仕様は
冒頭の現行仕様要約、実装、および検証testを正とする。
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
`embedding` から計量を導出する `feG a b` は `[x, y, z]` の直書きではなく
`feCoords_a`/`feCoords_b` を参照し、計量係数場の半セル評価も `feCoords_a`/`feHsteps_a`
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
`lib/fmrgen.egi` は `taylorStencil` の stencil 数学 core に縮小。
まだ `.fme` 化していない手書き `.egi` 例だけは `lib/fmrlegacy3d.egi` の 3D 互換文脈を読む。
全 `.fme` 例と手書き `.egi` 例で生成 `.fmr` はバイト一致。

**v1.19(2026-07-09): 上下添字を保持し、`metric NAME` で計量名を宣言** —
以下のmixed metric aliasと同名bindingのwarning共存はv2.1で撤回済みである。
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
添字方程式に参加する field は `field v~i @ primal`、
`field σ{~i~j} @ primal` のように宣言する。新構文では
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
`ixExpand` する。`@ primal` / `@ dual` field では `v~i` や `σ~i~j` の配置に合わせ、
生成 `.egi` 側で `x -> x + offset*hx` の半セル substitute をかけてから
`fmrInit` に渡す。
これは当時の component lowering であり、v1.36 では indexed initializer を whole runtime tensor と
`FMR.fieldInits` へ移し、sampling offset も target/RHS の相対配置から導出する。

反対称 rank-2 field `field A[_i_j] @ primal` も backend 対応した。
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

- **添字つき関数族**: `def E := generateTensor (\[i] -> function (x, y, z)) [3]`
  で E_1, E_2, E_3 が独立な抽象関数シンボルになる。LHS で省略した軸は
  Egison の添字補完により既定の下添字として関数シンボル名へ反映される。
- 計量 → `M.inverse`・`∂/∂`・Christoffel 記号 Γ の記号計算は全部サンプル済み
  (しかも T2 の例はまさに本リポジトリのトーラス)。
- 微分形式は本リポジトリの DEC 層が担う。当初は dF0/dF1/dF2/codF2 という独自名
  だったが、**Egison 本体の Yang–Mills サンプル(d・hodge・δ)と同じ構造・標準名に
  再構成済み**: 当時は形式=(複体, 次数, 成分)の3つ組、`hodge` は単位立方格子で成分不変の
  複体スワップ、`dForm` が離散外微分、余微分は `codiff = (−1)^(n(k+1)+1) ⋆d⋆`
  (別名 `δ`; codF2 は撤去)だった。この3つ組は v1.33 で
  `(GridPolicy, Tensor MathValue)` に置き換えた。d∘d=0 を CAS が 0 に簡約することも確認済み。

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
def E := generateTensor (\[i] -> function (x, y, z)) [3]
def B := generateTensor (\[i] -> function (x, y, z)) [3]
def En := withSymbols [i] E_i + dt * (curl B)_i
def Bn := withSymbols [i] B_i - dt * (curl En)_i
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
field v~i @ primal
field σ{~i~j} @ primal    -- 配置はpolicyと添字parityから導出(Virieux)

step:
  v'~i     = v~i + (dt/rho) * ∂_j σ~i~j
  σ'~i~j  = σ~i~j + dt * (la * g~i~j * ∂_k v'~k
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
  → fec(TensorExpr parser/def解決/scope/静的診断 + descriptor/backend planning)
  → whole runtime tensor 方程式と grid callback を持つモデル固有 .egi
  → Egison CAS + grid/tensor/geometry/runtime ライブラリ
  → descriptor-driven 共有プリンタが .fmr を出力
  → Formura(fork)→ MPI + temporal blocking つき C
```

- **標準 tensor/grid 意味論は Egison kernel に置く**。`fec` はユーザー `def` と標準
  operator marker を同じ TensorExpr 解決経路に通すが、通常の whole-tensor 式では標準6演算子を
  storage 成分へ特殊化せず `FE.grad` / `FE.dGrad` / `FE.divg` / `FE.curl` / `FE.lap` / `FE.hessian`
  として emit する。grid 固有 stencil は generated callback だけが与える。
  座標非依存の `.` / `.'` / `contractWith` / `trace` / `sym` / `antisym` / `wedge` は
  Egison標準のtensor・matrix・differential-form libraryを唯一の定義元とする。
  `lib/formurae-tensor.egi` はFormurae固有のsymbolic backend helperとcanonical-form bridgeだけを提供する。
  `lib/fmrgen.egi` は `taylorStencil` の stencil 数学 core、
  `lib/formurae-runtime.egi` は完全 field descriptor と明示 context を受け取る共有 `.fmr`
  プリンタである。
  生成 `.egi` にはモデル固有の場・残余式と、実際に参照される座標文脈だけを出す。
  生成 `.fmr` のバイト一致テストを意味のアンカーとして維持する。
- parser と TensorExpr の user `def` 解決、逐次 scope、strict free-index diagnostics、
  basis-aware placement diagnostics は Haskell(base のみ)で実装済みである。後二者は早期エラー用の
  frontend static oracle であり、component/stencil lowering ではない。一般の添字式は
  `RuntimeTensorExpr` bridge が whole tensor のまま Egison へ渡すため、`ixExpand` fallback はない。
  生成物はデバッグ可能な中間 `.egi` として追跡し、parser error は式全体・失敗近傍・
  column を返す。backend request は transliteration の長さ変化と user `def` substitution を
  跨いでも元 `.fme` の path/line/column を返し、各 expansion の definition/call site を表示する。

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
   **init もベクトルで書ける**: `E = [| 0, gauss1(i*dx), 0 |]`。
   **ベクトル方程式は添字なしで書ける**: `E' = E + dt * curl B` /
   `B' = B - dt * curl E'`(X' は更新済み配列への参照 = symplectic かつ袖幅1;
   標準 `curl` は現在 native whole-tensor operator のまま Egison へ渡る)。dimension/axes は必須で、
   現在の `.fme` 生成経路は 1D/2D/3D を扱う。CAS 内部の座標シンボルは
   宣言次元ぶんだけ `x,y,z` に正規化するが、
   Formura 出力の `axes ::` と `d<axis>`/`lower_<axis>` 系の名前は宣言軸を使う。
4. ✅ v1.5/v1.6(2026-07-10): **計量サポート実装済** —
   `metric scale [h1, h2, h3]`(直接指定)と **`embedding [X1..Xm]`
   (座標系からの計量自動導出)**。軸名(`axes r, theta, phi` 等)は内部
   `x,y,z` に正規化し、生成 Formura/C へ出すときに宣言名へ戻す。embedding では
   CAS が g_ab = ∂X/∂xₐ·∂X/∂x_b を計算(sin²+cos²=1 は自動簡約)、
   **直交性 g_ab=0 (a≠b) を記号検査してゲート**、h_a = √g_aa。quote
   (`` `(2+cos θ) ``)で因子を原子に保つと √ が閉じる。現在の Egison は
   quote 内部を保ったまま半セル substitute でき、printer もquoteを直接扱うため、
   展開・quote除去の中間処理は不要。宣言から hodge 因子 √g/hᵢ² の係数場
   (1D: ca/sg、2D: ca/cb/sg、3D: ca/cb/cc/sg)生成・半セル CAS 評価・保存流束・`lb`(Laplace–Beltrami)
   まで自動。embedding 内のスカラー関数と、√ が閉じない場合に必要な `sqrt` は
   安全側にexternとして自動収集するため、CASで消える関数も宣言に残ることがある。
   閉じない√もextern経由でinitが数値評価するので動く。球座標 hs=[1,r,r sinθ] は
   r=0・θ=0,π の座標特異点があるため、次例は円筒環状領域
   (embedding [r cos phi, r sin phi, zz]、r 壁は fork の boundary)推奨。
   残り = indexed family(`field f : family 19`)で LBM、ε_ijk とスカラー対象の
   添字和で yee/acoustic、ユーザ定義ヘルパ(def)で MHD。
5. ✅ v1.7(2026-07-10): **数式演算子と strict 添字記法** — レビュー指摘
   「dC2 のような関数でなく数式どおりに」を受け、.fme の座標軸微分は
   `∂_x` と `∂'^m_x` 形式を許す(dC/dC2/dTaylor は .fme から撤去)。
   現在は `field v~i @ primal`・`field σ{~i~j} @ primal` のように
   添字仕様から field layout を推論し、**テンソル添字方程式**が書ける:
   `v'~i = v~i + (dt/rho0) * ∂_j σ~i~j` /
   `σ'~i~j = σ~i~j + dt * (la * g~i~j * ∂_k v'~k + mu * (g~i~k . ∂_k v'~j + g~j~k . ∂_k v'~i))`。
   `∂_i` は自身が生成する下添字と対象の同名上添字を加法縮約する。
   `metric g` 下の g~i~j は Euclidean 計量、∂_a は対象成分の配置にアンカーされた半セル差分
   (dYee)に落ち、対称成分は正準化(sigma_2_1 = sigma_1_2)。elastic3d.fme の生成
   .fmr は P/S 波速検証で green。
6. v2: 変数別境界条件、多段時間積分スキーム、Christoffel 一般計量、
   2D curl、4D 以上の Formura backend
   (Egison 側の sqrt(完全平方多項式) 簡約が前提; チップ発行済)。

## 6. v1.36時点の到達点と残課題(履歴)

この節はv1.36時点の履歴であり、user result varianceと`flat` / `sharp`に関する記述はv2.5で
置換されている。v1.36当時の Formurae は、Egison のテンソル添字記法・微分形式・CAS を **表層言語から直接使える記述力**
として活用している。`fec` は parse、user `def` 解決、scope/source provenance、添字・配置の
静的診断、descriptor/backend planning、Egison runtime bridge を担当する。一方、runtime tensor
評価、result signature、GridPolicy parity、coordinate operators、whole-field/form printer、
微分形式、純粋な metric/Hodge/Laplace--Beltrami/musical-map 公式は Egison library が担う。

1. **ユーザ定義テンソル演算子は実装済み**
   `def grad u = withSymbols [i] ∂_i u`、
   `def div X = ∂_i X~i`、
   `def Δ u = g~i~j . ∂_i ∂_j u` のように、結果添字を書かずに定義できる。
   `withSymbols` で導入された自由添字は呼び出し側の添字へ付け替えられる。

2. **添字微分は微分添字を加法縮約する**
   `∂_i X~i` は `∂_i` の内部の `contractWith (+)` により scalar になる。
   それ以外の同じ上下添字は暗黙総和せず、`contractWith` または `.` で縮約する。
   `TensorExpr` は既定の `.` と user `def` を surface で解決するが、縮約値そのものは
   runtime Egison の `contractWith` が評価する。ユーザーが `def (.) ...` を定義した場合は
   そちらを優先する。

3. **`mode` が標準演算子族を選ぶ**
   旧 `use vector-calculus` / `use exterior-calculus` 宣言は撤去済みである。
   `mode collocated` は native coordinate operator marker を登録し、`mode dec` は form context を
   生成する。ユーザーの同名 `def` は標準定義を shadow する。通常の標準6演算子は whole-tensor の
   `FE.*` 呼び出しとして Egison へ渡り、generated `feTensorDerivative` callback が
   target/source policy・component basis・微分軸列から stencil を選ぶ。

4. **完全 field descriptor と whole-field printer を使う**
   shape、variance、layout、policy、canonical projection、storage mapping は
   `feFieldDescriptors` に一度だけ生成する。`FMR.fieldEqs` は descriptor と RHS の policy/shape を
   検査して独立成分を射影し、field-name map と policy table も descriptor から導出する。
   indexed CAS initializer も1個の whole tensor を `FMR.fieldInits` へ渡し、成分ごとの
   Haskell initializer は生成しない。

5. **runtime binding と initializer は配置を明示的に扱う**
   indexed `let` は LHS の添字数・上下から rank/variance を得て bare tensor として materialize する。
   scalar `let` を含む定数式は placement-neutral、field を参照する式は located policy を持つ。
   initializer は neutral RHS なら target 位置、located RHS なら target-minus-source の相対配置で
   sample し、同一 lattice の field を二重 shift しない。explicit coordinate と non-collocated
   field-valued RHS の混在は単一 substitute で正しく表せないため明示的に拒否する。

6. **計量と Laplace--Beltrami の純粋な公式は Egison にある**
   induced metric、直交計量と逆計量、体積要素、Hodge coefficient、
   flux-divergence 合成は `lib/formurae-geometry.egi` が評価する。
   宣言幾何の canonical Δ/δ は prelude マクロで、`dFluxWeights` / `dFluxScale` /
   `dFluxDiv` という公開演算子の展開に下ろす。幾何のみの係数 local は post-fec が
   凍結して persistent state 化し(init 一回+恒等 carry)、専用の backend planner や
   scheduled 要求は存在しない。複数の呼び出し部位はマクロ衛生で独立に展開される。
   metric-aware form Hodge/codiff と、policy を保つ orthogonal rank-1 `flat` / `sharp` も
   shared geometry にある。musical map は補間/de Rham/reconstruction を含まない。

7. **添字 equation は strict に保つ**
   添字付き field は宣言された添字つきで使う。各項の自由添字は LHS と上下まで一致する必要がある。
   上げ下げは自動化せず、必要なら `metric g` で宣言した計量と `.` を明示する。
   `strictEinstein` はこの surface diagnostic のために残す。一方、評価後 result の shape/variance/
   `dfOrder` は Egison の `FE.checkedTensorSignature` が検査する。

8. **Phase 7 後の境界と今後**
   scalar/添字式は演算子優先順位を持つ TensorExpr AST として保持し、parser error は式全体、
   失敗近傍、column を返す。backend request は完全な source provenance を保持する。
   production の `ixExpand` component fallback は削除済みである。Haskell の basis-aware placement
   validator は、Egison 実行前に配置不一致を source-level error として報告する static oracle として
   意図的に残す。これは stencil 選択や Formura component 生成には使わない。
   geometry 側の将来拡張として、非対角 metric、一般 rank の musical map、cochain 用
   de Rham/reconstruction、DEC vector aliases が残る。Formurae の新規性は「Egison の数式記法と
   CAS を、座標文脈つきの分散ステンシルコード生成へ接続する薄い表層言語」に集中する。
