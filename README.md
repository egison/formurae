# Formurae

Formurae は、Egison のテンソル添字記法で書いた偏微分方程式を
[Formura](https://github.com/formura/formura) の stencil programへ変換し、
MPI・temporal blocking付きC codeを生成するための実験的な言語処理系です。

表層言語の拡張子は `.fme` です。数式の意味と離散化を分離し、次の4段で処理します。

```text
model.fme
  └─ pre-fec ──> model.egi
                    └─ Egison ──> model.feir
                                      └─ post-fec ──> model.fmr
                                                         └─ Formura ──> C
```

- `pre-fec` は構文、scope、宣言、source mapを検査し、Egison normalization unitを生成します。
- Egison はuser definition、tensor/index algebra、analytic differentiationを評価し、canonical FEIRを出力します。
- `post-fec` はplacement、stencil、補助field、storageを決め、Formura programを生成します。
- Formura は配列、loop、MPI通信、temporal blockingを含むC codeを生成します。

純粋な数学演算子はEgisonにだけ定義されます。`grad`、`divg`、`curl`、`hessian`、`lap`、`d`、
orthogonal-metric `hodge`、constant-metric `codiff`は、callbackやcomponent loopを含まない通常の短いEgison関数です。
具体的な差分係数や格子offsetをEgisonの演算子定義へ混ぜません。

user tensor operatorも同じ経路です。例えば次の自由な下添字はEgisonで匿名tensor軸になり、ordinary
covector targetへ代入するときだけ構造的index completionでexplicit down indexへ補われます。
operator名を見た型推論ではありません。up targetへの読み替えは拒否し、form targetの`dfOrder`は保持します。

```formurae
def gradLike u = withSymbols [i] (∂_i u)
field q_i
step:
  q' = gradLike u
```

## 最小例

```formurae
mode collocated
dimension 3
axes x, y, z

param κ = 1.0
param dt = 0.1*dx*dx

def Δ u = divg (grad u)

field u : scalar

init:
  u = gauss(i*dx,j*dy,k*dz)

step:
  u' = u + dt * κ * Δ u
```

`Δ`の定義は精度に依存しません。4次精度へ変更するときも演算子を`Δ4`や`∂'`で書き直さず、
model-level profileを追加します。

```formurae
discretization collocated derivative 2 centered accuracy 4
```

Egisonは`divg (grad u)`を二階のFieldJetへ正規化し、post-fecが4次精度を満たす最小半径2の
compact 5点stencilをexact rational coefficientで導出します。一階wide stencilを二重適用しません。

## 微分の意味

通常の`∂`は解析微分です。

```formurae
∂_x (u * u)          -- Egison: 2 * u * FieldJet(u,{x:1})
```

未知の解析微分則を0とみなすことはなく、Formurae用strict derivativeがerrorにします。
混合偏微分はcanonicalなmulti-indexへまとめられます。

式全体を先に格子上で評価してから差分したい保存形では、離散primitiveを明示します。

```formurae
gridD_x (u * u / 2)  -- post-fec: whole-expression centered/Yee stencil
```

per-occurrenceで半径を固定するlow-level wide derivativeもopaque requestとして扱います。
これらはmodel profileを参照せず、versionedな離散意味を保ちます。

同様に、離散順序・配置・保存境界を意図的に固定したい場合だけ、次の明示primitiveを使います。

```formurae
orderedD(q, x, y)   -- xのwhole derivativeの後にyを適用し、順序を保持
resample(q, 0, 1)   -- 2Dの絶対placement (integer, half) へ線形補間
fluxDiv(F)          -- Primal face flux tensorの保存divergence
materialize(q)      -- 同じ型・配置のstep-local barrier
```

`lb`や可変計量`codiff`に必要なmaterializationはpost-fecが自動計画するため、pureなユーザ演算子へ
`materialize`や`fluxDiv`を挿入する必要はありません。上の4つは数学的合成では表せない離散意味を
ユーザが明示する場合の境界です。

## Tensor、form、格子配置

fieldはscalar、vector、rank-1/rank-2 tensor、`k-form`を宣言できます。

```formurae
field E_i @ primal
field B_i @ dual
field σ{~i~j} @ primal
field F : 2-form
```

配置は`Collocated`、`Primal`、`Dual`のいずれかです。Primal/Dualの具体的な半セル位置は
field policyとcomponent basisのparityからpost-fecが推論します。異なるplacement間の補間は
暗黙に行わず、必要なら`resample(value, bit...)`を使います。

Maxwellはcollocated vector、Yee vector、DEC formの各形式で記述できます。

```formurae
mode dec
dimension 3
axes x, y, z

field E : 1-form
field B : 2-form

step:
  E' = E + dt * codiff B
  B' = B - dt * d E'

assert-dd-zero E'
```

`d`とconstant-metric `codiff`はEgisonのform algebraとして評価されます。variable-metric `codiff`は
weighted discrete-adjointのversioned requestとなり、post-fecがHodge係数・flux・resultの配置とlifetimeを計画します。
`assert-dd-zero`は`d(d E') = 0`を
normalization時に確認し、成立しなければFEIRを出力しません。

## GeometryとLaplace--Beltrami

直交計量はscale factorまたはembeddingで宣言します。

```formurae
axes θ, φ, z
embedding [ `(2 + cos θ) * cos φ, `(2 + cos θ) * sin φ, sin θ, z ]

def Δ u = lb u
```

Egisonはmetric、inverse metric、scale factor、volumeを記号的に作り、embeddingでは直交性を
検査します。`lb`は保存流束、half-cell coefficient、volume除算、補助fieldのlifetimeを伴うため、
短いversioned opaque requestとしてFEIRへ残します。post-fecがそのrequestから係数field、flux、
divergence、更新順序を計画します。同じsourceのrequestは共有され、異なるsourceは分離されます。

## FEIR

FEIR (Formurae Egison IR) はEgisonとpost-fecのversioned protocolです。

- exact rationalを保持するcanonical S-expression
- stable `AxisId`、`FieldId`、`FunctionId`、`OriginId`
- scalar/tensor normal formとderivative multi-index付き`FieldJet`
- `GeometryNF`、discretization profile、versioned opaque request
- registry/primitive-manifest/profile fingerprint
- `.fme`のpath・line・columnとdefinition expansion trace

list nodeの順序はcanonical S-expressionをrenderしたbyte列で決まり、Egison encoderとHaskell
validatorが同じ規則を使います。decoderはwire順を保持するため、非canonicalな入力順をparse時の
sortで隠さずhard errorにします。

成功したEgison stageのstdoutはFEIR 1個だけです。diagnosticはstderrへ分離され、warning、type error、
evaluation error、余分なstdoutはmachine runnerが拒否します。

## クイックスタート

前提はGHC 9.6系と、隣接する`../egison`の開発treeです。Formuraのbuildには`stack`を使いますが、
FormuraeとEgison自身は`cabal`でbuildします。1-rank用MPI stubを同梱しています。

```sh
make setup
cabal build
make diffusion3d
make maxwell3d_yee
make metric_torus
```

`make NAME`は`.fme -> .egi -> .feir -> .fmr -> C -> check`を通します。全例は次で検証できます。

```sh
make all
```

各stageを直接確認する場合:

```sh
cabal run -v0 pre-fec -- examples/diffusion3d/diffusion3d.fme > /tmp/model.egi

tools/run_formurae_normalization.sh ../egison \
  /tmp/model.egi > /tmp/model.feir

cabal run -v0 post-fec -- /tmp/model.feir > /tmp/model.fmr
```

## 生成物

`.fme`が編集対象です。23個のFME例では`.egi`、`.feir`、`.fmr`をreview可能な生成artifactとして
追跡し、Makefileから再生成します。galleryは4段すべてを表示します。`mhd_ot`、`lbm_d3q19`、
`acoustic3d`の3例はcompiler cutoverの対象外に置いたhand-written Egison exampleであり、
`fmrgen.egi`と`fmr-direct3d.egi`を使う独立したdirect Egison→Formura ruleで検査します。

## リポジトリ構成

| パス | 役割 |
|---|---|
| `fec/app/pre-fec/` | Formurae frontend CLI |
| `fec/app/post-fec/` | FEIR validation・discretization・Formura backend CLI |
| `fec/src/Formurae/FEIR/` | FEIR syntax、codec、validation、fingerprint |
| `fec/src/Formurae/Pre/` | parse、registry、effect analysis、Egison emitter |
| `fec/src/Formurae/Post/` | placement、stencil、geometry/backend plan、FMR AST/printer |
| `lib/formurae-operators.egi` | pure continuum operatorとopaque request constructor |
| `lib/formurae-primitives.egi` | primitive manifestから自動生成するversioned full-signature binding |
| `lib/formurae-feir.egi` | MathValue/Tensorからcanonical FEIRへのencoder |
| `spec/feir-primitives-v1.sexp` | 8 primitiveのfull signatureを規定する唯一のmanifest source |
| `spec/egison-normalization-v1.list` | Egison normalization libraryのversioned load順 |
| `examples/` | model、生成artifact、C numerical check |
| `gallery/` | sourceと数値結果のgallery |
| `design/20260711-pre-post-fec-pipeline.md` | normative compiler design |

## 検証

変更は次の層で検査します。

```sh
make compiler-tests
make all
```

- FEIR round-trip、malformed input、fingerprint、source diagnostic
- pre-fec scope/effect/dictionary-passing tests
- Egison strict differentiation、FieldJet、tensor/form operator tests
- post-fec profile、exact Taylor stencil、placement、wide/gridD、geometry/lb/metric-codiff tests
- collocated/Yee/DEC/variable-metric exampleのFormura parseとC numerical checks
- Egison math representative samples、mini-test全件、`cabal test`

Phase 0--9の受入れ基準と最終rerunの記録は
[`design/20260711-pre-post-fec-pipeline.md` section 13](design/20260711-pre-post-fec-pipeline.md#13-phase-0--9完了evidenceと最終検証記録)を参照してください。

設計上、旧`fec` CLI、旧generated `.egi` schema、callback/marker based loweringとの後方互換性は
提供しません。仕様変更時はexample、document、testを新しい意味へ同時に更新します。

## 関連資料

- [`DSL-DESIGN.md`](DSL-DESIGN.md): 表層構文と設計履歴
- [`design/20260711-pre-post-fec-pipeline.md`](design/20260711-pre-post-fec-pipeline.md): 現在の責務境界とFEIR contract
- [`gallery/usage.html`](gallery/usage.html): tutorialとusage guide
- [`APPLICATIONS.md`](APPLICATIONS.md): 応用例一覧
- [`UPSTREAM.md`](UPSTREAM.md): Formura側の拡張計画

## ライセンス

MIT。Formura本体とvendor sourceはそれぞれのlicenseに従います。
