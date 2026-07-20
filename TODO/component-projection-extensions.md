# 成分射影の拡張(混合射影・一般式射影・宣言レベル component)

## 現状(v2.18)

宣言済みの添字つき field/local への軸名添字は成分射影:
`q_x` → `q_1`(preprocess で軸 → 1 始まり位置へ改名、Egison の具体添字
アクセスに直結)。判定規則は ∂ と同じ「添字が宣言済み軸名なら具体、
そうでなければ記号」。鏡像成分(対称/反対称の符号・零対角)は束縛
テンソル値が持つため正準化不要。検証は token 層(Parse)+ AST 層
(emit walk、`~` 綴りを捕捉)の `invalidAxisProjection` 二段。
LHS は whole-field target 制約により対象外。

## 拡張 1: 混合射影 `σ_x_j`(小)

具体軸と記号添字の混在で「行ベクトル」(自由添字 j つき rank-1)を得る。
現在は明示エラー。実装は preprocess の全具体要件を緩め、具体部分だけ
位置へ改名して残りを記号のまま流す — Egison のテンソル添字は混在を
ネイティブに扱えるはずなので、主な作業は index completion /
`checkedTensorSignature` の簿記(具体添字はスロットを消費するが記号を
導入しない)の検証とテスト。

## 拡張 2: 一般式への射影 `(grad u)_x`(中)

TEIdent 直付けの添字だけでなく、括弧つき式への射影。文法は
`TEAppendIndexed`(call-site 添字追加 `..._i`)の具体軸版が自然。
評価順(式のテンソル正規化 → 成分取り出し)は Egison 側では自明だが、
表層の綴りと `..._i` 機構との整合を設計してから。

## 拡張 3: 宣言レベル `field qx : component x @ primal`(大)

x-flux だけを状態として持ちたい場合(残成分の記憶域が無駄)。
`LogicalFieldDecl` に宣言 basis を足す = **FEIR スキーマ変更**
(fingerprint 更新・全例題再生成の随伴作業)。placement は従来どおり
`componentPlacement(policy, basis)` 導出なので formurae-post の意味論は不変。
v2.18 の (B)+indexed local で当面代替できるため、必要が実証されてから。

## 完了条件(拡張 1 の場合)

- `∂_j σ_x_j`(x 行の発散)相当が書け、elastic3d の 1 成分版で実測一致。
- pre_emit に混合射影の正例+境界(全記号・全具体)の回帰。
