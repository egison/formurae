# 波のページの空間分布動画 / Spatial movies on the wave pages

`html/ja/waves.html` と `html/en/waves.html` に掲載する6件の動画です。
数値計算の結果を空間上に表示し，各動画の全時刻と比較対象で色・矢印の尺度を固定します。

| モデル | 表示する量 | 表示の範囲 |
|---|---|---|
| `shallowwater` | 保存した水深 `h` | 水面の断面。上段は縦に拡大，下段は水底からの全水深 |
| `lbm_d3q19` | `velocity_down2` | 三次元計算の中央 z 断面の y 方向流速と矢印，流速の曲線 |
| `kinetic_coordinates` | `9*f_down2` | 右向きの一成分の分布を，直交格子と曲線格子で比較 |
| `kinetic_fv` | `9*f_down2` | 同じ曲線格子と二段階の時間積分で，急な分布の変化の保存を比較 |
| `kinetic_viscosity` | `momentumX/mass`，`momentumY/mass` | 直交格子・曲線格子の流速。色は y 成分 |
| `kinetic_hydrostatic` | `densityError`，`momentumX/mass`，`momentumY/mass` | 静水の密度からのずれの絶対値と流速。静止・比較用の静止・小さい乱れの3条件 |

分布の重みが1/9なので，該当する動画では値を9倍して表示します。
運動量と質量には同じ体積・面積換算が含まれるため，その比を表示用の流速にします。
静水計算では上下の境界処理用の行を除き，実際の32×32セルを表示します。
これらは描画用の変換だけで，計算状態には戻しません。
`shallowwater` 以外の5件は水面を持たない流体の計算です。
浅水波も水面の高さを求めるモデルであり，巻き込みや飛沫の計算ではありません。

## 再現

リポジトリのルートで実行します。通常の Formurae / Egison / Formura の環境と，
NumPy・Matplotlib を使える Python，H.264 を出力できる ffmpeg が必要です。

```sh
make wave-visualizations
```

すべてのコンパイルと計算を直列で実行します。
`.fme → Egison → FEIR → .fmr → Formura → C` の通常経路を使い，
既存検証の正規化結果はモデルと処理系のハッシュが一致した場合だけ再利用します。
既存の実行用 C ファイルは変更せず，そのコピーに `gallery/tools/field_frames.h` を
読み込ませ，初期化と更新の後に生成済みの場を保存します。生成ソルバーはこのヘッダーを
読み込まずに別途コンパイルします。物理計算・初期条件・更新式の追加はありません。

保存を加えた実行と通常実行の検証出力がバイト単位で一致すること，
予定した全フレームが存在し有限の値だけを含むことを確認します。
通常実行の水波・D3Q19の検証と，保存済み出力に対する粘性・静水の検証も実行します。
複数段階の時間積分では，途中の段階を動画に使わず，物理的な1ステップの完了時だけ保存します。
格納位置が時間とともに動く周期境界でも `to_pos_*` を使い，物理座標に対応する順序で保存します。
記録用の出力処理は1つの MPI プロセスに対応します。

生の場は `.build/wave-visualizations/<モデル>/<条件>/frames.npz` に保存します。
各動画に添えた JSON は，モデル・生成物・設定・記録処理のハッシュ，
実行引数，出力一致の確認，フレーム数と計算時刻，メディアのハッシュを記録します。
描画だけをやり直すには，保存済みの場がある状態で次を実行します。

```sh
make wave-visualizations-render
```

動画は自動再生せず，利用者が再生します。既存の検証グラフも引き続き掲載します。
4件の `examples/kinetic_*/gallery.py` も同じ動画挿入処理を呼ぶので，
カードを再生成しても動画は失われません。

## English

These six movies draw saved simulation fields on both wave pages. All frames and
comparison panels use fixed color and arrow scales. Only `shallowwater` has a
surface height: it shows a vertically enlarged surface cross-section and a full
depth view. The other five movies show populations, velocity, or absolute density
deviations in fluid without a free surface. They do not depict a water–air boundary.

Run `make wave-visualizations` from the repository root with the usual
Formurae/Egison/Formura toolchain, NumPy, Matplotlib and an H.264-capable ffmpeg.
Builds and runs are sequential. The ordinary generation pipeline is used;
normalization caches require matching source and toolchain identities. A generic
output-only header records generated fields through unchanged driver copies.
The solver is compiled separately without the recording header. Recorded and
ordinary runs must produce byte-identical diagnostic output. The water-wave and
D3Q19 driver checks and the saved-output viscosity and hydrostatic checks also run.

The recorder saves only completed integration steps, reorders periodic storage
through `to_pos_*`, and checks that every expected frame is present and finite.
It supports a single MPI process. Hydrostatic wall guard rows are removed only
for display. Coordinate maps, multiplication by the inverse population weight,
and conversion of stored momentum and mass to arrow velocities are drawing-only
operations. No drawing result is fed back to the simulation.

Field archives remain in `.build/wave-visualizations/`. Adjacent JSON files record
source and toolchain provenance, configurations, output comparisons, frame counts,
physical times and media hashes. `make wave-visualizations-render` redraws saved
archives and updates both pages. Videos have manual playback controls and posters;
the existing verification graphs remain available. Regenerating the four kinetic
cards preserves their movies.
