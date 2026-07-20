# yaml boundary と宣言の整合 — 検査から入る

## 現状(v2.19 / v2.22)

- 切り分けは v2.19 で確定: **.fme = semantics(compile-time)、yaml =
  runtime 設定**。Formurae は yaml を一切読まない(ツール契約の一部)。
- sbp 軸ではゴーストが読まれないので yaml の boundary はプレースホルダ
  (`fixed 0.0`)のまま。`boundary z : ghost 0.0` の fill 値と yaml の
  `fixed` 値の**不一致は現在どこも検査しない**(既知の silent の穴)。
- 宣言側の語彙は sbp | periodic | ghost VALUE(軸ごと・両壁同種)。
  fork 側の yaml 語彙は periodic | fixed | mirror(軸ごと)。

## 設計判断(着手前に決める)

1. **生成ではなく整合検査から入るのを推奨**: yaml 全体の生成は
   grid_per_node・mpi_shape 等の runtime 知識と混ざり v2.19 の切り分けを
   壊す。boundary 行だけの部分生成は「生成半分・手書き半分」の運用に
   割れる。実利のほぼ全部は ghost fill の不一致検出にある。
2. **置き場所 = Makefile 段の独立チェッカ**: 宣言は .feir(axis レコードの
   boundary 属性)から読めるので、Formurae に yaml 読みを入れず「Formurae は yaml を
   読まない」契約を保てる。
3. **語彙の対応規則**: periodic ↔ periodic、ghost VALUE ↔ fixed VALUE
   (値の一致まで検査)。sbp 軸はゴースト不読なので「検査免除」か
   「不一致は警告」かを決める(免除を推奨: どの値でも意味が変わらない
   ことが宣言の帰結)。mirror に対応する宣言語彙が無い — `boundary a :
   mirror` を足すか、mirror 使用軸は宣言なし(periodic 既定)のまま
   検査対象外とするかは語彙拡張の判断。
4. **ghost fill の文法**: 現在は raw 文字列(式も書ける)。yaml の fixed は
   数値リテラルなので、検査(将来生成)するなら fill を数値リテラルに
   制限するかを決める。
5. **片側(per-end)宣言は保留**: 現文法は軸ごと両壁同種で、fork の yaml
   も同様。必要が出た時点での文法判断とする。

## 差し込み口

- チェッカ本体: .feir の axis boundary と <example>.yaml の boundary 行を
  突き合わせる小さなツール(tools/ 配下、suite の .sh から呼ぶ)。
- 例題側: 全 .yaml が検査を通る状態を初期条件にする(sbp 軸は免除規則で
  現状のまま通るはず)。

## 完了条件

- チェッカが compiler suite に入り、ghost fill 不一致の fixture が
  検出される。
- 全例題の yaml が検査を通過する。
