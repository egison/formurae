# 境界の言語化 — 「幅は演算子、境界は宣言、降下はその積」(sbpd 退役計画)

## 設計判断(2026-07-19 の議論で確定)

v2.17 の `sbpd`/`sbpd2` は**分類軸の取り違え**だった: 微分演算子の語彙は
一貫して「幅と離散化の選び方」(素 = 最小/プライム = +リング/
profile accuracy/チェーン)という 1 軸で切られているのに、`sbpd` は
**境界の扱い**という別の軸を演算子名に持ち込んでいる。境界処理は
個々の適用の属性ではなく**領域(軸)の属性**であり、エネルギー安定性は
「モデル内の全微分が同じ境界扱いを共有する」大域的性質なので、
per-call の opt-in では成立の検査ができない。opaque 演算子の道を選んだのは
ワイヤ変更を避ける実装都合(足場)であって、恒久設計ではない。

数学の因数分解(半整数半径族 = 内部の理論/SBP = その境界延長。
SBP 恒等式の内部制限 = 半整数ステンシルの反対称性)を言語へそのまま写す:

- **幅** — 演算子の綴り(現行どおり。パリティ則 2r ≡ m (mod 2) が唯一の幅規則)
- **領域の形** — 軸ごとのモデル宣言(新設)
- **降下** — 両者の積: 内部は幅どおり、宣言された物理境界の近傍だけ
  その幅に**整合する**閉包行へ

## 表層(案)

```
boundary x : sbp            -- 物理境界、SBP 閉包で降下
boundary y : periodic       -- 既定(宣言なし = periodic = 現状互換)
boundary z : ghost 0.0      -- fork の ghost 充填(dirichlet_diffusion の idiom の明示化)
```

この下で既存演算子がそのまま境界対応になる:
素の `∂_x` = 内部 Yee+端は閉包行(現 `sbpd_x` を吸収)、
`∂^2_x` = 合成閉包(現 `sbpd2_x`)、`∂'_x`・profile 幅 = 対応する
k≥2 閉包(構成器が入るまでは**明示エラー** — sbp 軸で閉包の無い幅を
黙って降ろさない)。periodic 軸は一切不変。

## 原則

0. **幅の半整数性は導出のみ(承認済みの不変条件)**: 半整数半径は表層にも
   FEIR にも書かれない。radius 属性は正整数(プライム数 + 1)のまま、
   post-fec が「staggered × 奇数階なら実効半径 = 属性 − 1/2」と解釈する。
   プライムはパリティ中立な「+1 リング」で、半分ずれるかどうかは格子が
   供給するため、パリティ不整合(collocated に 3/2 等)は表現不能。
   boundary 宣言の実装でもこの因数分解を崩さないこと — 宣言が変えるのは
   境界近傍の**降下**だけで、幅の語彙・ワイヤ表現には触れない。
1. **silent 禁止の回復**: sbp 宣言軸では、域外を読む降下も閉包なしの幅も
   静的エラー。現状の「bounded yaml + 素の ∂ が黙って ghost を読む」より厳格。
2. **検査可能性**: 宣言があるから「sbp 軸に閉包なし経路が混ざった」を
   静的に検出でき、モデル単位の安定性主張が意味を持つ。
3. **SAT は方程式の内容**: 閉包(微分の正しい降下)は自動、
   SAT(物理、BC の課し方)は表層に明示。宣言は H⁻¹ 端重み等を
   名前つき定数として式へ供給し(現 `param sat = 2.0*τ*κ/(dx*dx)` 手書きの解消)、
   定型は surface macro(v2.10)`satDirichlet_x(u, g, τ)` で展開する。
4. **合成則の境界延長**: sbp 軸上の m 階則 = 「閉包つき 1 階の m 重合成」
   (v2.17 の sbpSecond 行が合成恒等で検証済み。この不変式を全経路で保つ)。

## 実装の当たり

- Model/FEIR に軸ごとの boundary 宣言を追加(**ワイヤ変更**: fingerprint
  更新+全例題再生成の既知スイープ)。同時に opaque
  `derivative.sbp-staggered` を**削除** — grid-whole / wide / profile の
  既存降下が軸宣言を参照し、共有ヘルパ 1 つで閉包行に差し替える。
  語彙の差し引きはほぼ中立。
- `sbpd`/`sbpd2` は退役(単発クォートを退役させた v2.8 の前例どおり
  エラー化+「declare the boundary and write the plain derivative」診断)。
- yaml との整合: 宣言が semantics(compile-time)、yaml は runtime 設定という
  v2.19 の切り分けを維持。sbp 軸ではゴーストは読まれないので yaml の
  boundary はプレースホルダのままでよい(将来的には宣言から生成も可)。

## 段階

- **Phase A**: 宣言導入+素の ∂ と profile 1/2 階の閉包化+sbp_* 例題 3 本を
  宣言形へ書き換え+sbpd 退役(現行機能の完全被覆、.fmr は同値)。
- **Phase B**: k≥2 閉包構成器([sbp-high-order-closures.md](sbp-high-order-closures.md))
  が入り次第、プライム/accuracy 幅へ拡張 — 「幅 × 境界」の積が全域で定義される。
- **Phase C**: SAT マクロ([sbp-sat-patterns.md](sbp-sat-patterns.md) を統合)。

## 新セッション向け着手メモ(Phase A)

- 宣言のパース雛形 = `parseDiscretizationDecl`(`fec/src/Formurae/Pre/Parse.hs`)。
  Model → emit → `lib/formurae-feir.egi` の encoder → FEIR Syntax/Codec/Validate
  → post-fec、という縦の通し方は discretization 宣言と同型。
- 吸収すべき現行降下 = `lowerSbpStaggeredDerivative`
  (`fec/src/Formurae/Post/Compile.hs`): index guard の FSelect 化・
  閉包行→格納オフセット写像・`total_grid_<axis>` 参照はここに全部ある。
  閉包データは `SbpStaggeredPair`(`Post/Stencil.hs`、恒等式検証器つき)。
- ワイヤ変更の随伴作業(既知): manifest/fingerprint 更新 → 全例題
  .egi/.feir 再生成(make all)+ハッシュ・op 列挙を固定するテスト
  (feir_primitive_manifest.hs / feir_primitive_bindings.hs /
  formurae_primitive_bindings_lib.egi / pre_geometry_emit.hs 等)の更新。
  `derivative.sbp-staggered` の削除も同じスイープに乗せる。
- 同値性の確認: sbp_diffusion1d/2d・sbp_wave1d を宣言形に書き換えて
  生成 .fmr が現行とバイト一致すること(完了条件の第 1 項)。

## 完了条件

- 宣言つき .fme(2D、x=sbp/y=periodic)が sbpd 版と同一の .fmr を生成
  (バイト比較)。
- sbp 軸への閉包なし幅・素の ghost 読みが静的エラー。
- sbpd の綴りが移行診断つきで拒否される。
