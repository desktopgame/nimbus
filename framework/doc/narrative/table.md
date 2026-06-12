---
unsafe: true
---

# table (narrative)
spec は [../table.md](../table.md)。ここには設計判断の理由と却下案を残す。

## ソートを Table がやらない理由
JTable は view 側に行の並び替え写像 (RowSorter、view index ↔ model index 変換) を持つ。
nimbus v1 ではこれを採らず、「Table はヘッダークリックを通知してインジケータを出すだけ。
並べ替えは行 item の所有者 (アプリ) がモデルに対して行う」とした。理由:

* **モデルは借用**である (行 = `*anyopaque`、実メモリはアプリ所有)。Table が値を比較するには
  列ごとの比較プロトコル (comparator 登録) が要り、「Table は行の中身を解釈しない」という
  List から続く設計が崩れる。
* **写像は複雑さの税金が高い**。view index と model index の二重系ができると、選択・活性化・
  コンテキストメニュー・セル束縛・将来の編集まで全 API が「どちらの index か」を背負う。
  JTable がまさにこの税金を払っている (RowSorter 導入時に互換の罠が多発した)。
* nimbus の実需 (ファイラー) では**アプリが既に自前でソートしている** (フォルダ先行 +
  名前順)。ヘッダーソートはその比較キーを切り替えるだけで、アプリ側 5 行の仕事。

却下案: 案 - view 写像 (JTable 型)。将来、モデルを直接並べ替えられない利用者
(共有モデルを複数ビューが異なる順で見たい等) が現れたら再検討するが、それまでは
「index は常にモデル順」という単一系を守る。

## 列ごとの CellFactory にして値取り出しプロトコルを持たない理由
Swing TableModel は `getValueAt(row, col) -> Object` で値を返す。これは動的型の言語機能に
寄り掛かった設計で、Zig で同じことをすると tagged union か `*anyopaque` の値プロトコルが要る。
nimbus は List で確立した「セルは実コンポーネントで、 行 item から自分で表示を取り出す」を
列に拡張した: 列ごとに factory があり、そのセルは自分の列の意味を知っている
(`NameCell` は `entry.name` を読む)。framework は行にも列の値にも触れない。
ソートを Table がやらない判断 (上記) とセットで、これにより値プロトコルが丸ごと不要になった。

## Model を List.ListModel と同一型にした理由
行コレクションとしての要件 (借用 item 列 + 変更通知) は List と完全に同じ。
別型を作ると「同じデータを List 表示と Table 表示で切り替える」(ファイラーの
リスト / 詳細ビュー切替) ときに二重管理になる。同一型なら 1 つのモデルを両ビューが
そのまま借用できる。将来 ListModel を独立モジュールに昇格させる余地はある
(現状は List.zig 内の定義を Table が参照する)。

## ヘッダーを Table 自身が描く理由 (ScrollPane columnHeader を待たない)
Swing は JScrollPane の columnHeader 領域に JTableHeader を置く方式だが、nimbus の
ScrollPane に行 / 列ヘッダー領域はまだ無い (scrollpane.md 機能要望)。v1 は Table が
自分の描画の中でヘッダーを上端に固定表示する (スクロールオフセットを打ち消して描く)。
自己完結していて ScrollPane に手を入れずに済む。columnHeader 方式は「ヘッダーだけ
クリップ外に出したい」「複数テーブルでヘッダー共有」などの実需が出たら移行を検討する
(spec の機能要望に記載)。

## セル編集を v1 から外した理由
List の CellEdit (start / commit / cancel + recycle 除外 + フォーカス喪失決着) は
そのまま Table セルにも適用できる形をしているが、編集対象セル (row, col) の二次元化、
Tab での隣セル移動など追加の決め事が多い。バックログ framework#9 の完了条件
(詳細表示 + ヘッダーソート + 列幅ドラッグ) に編集は含まれておらず、実需
(ファイラー詳細表示でのリネーム) が出た時点で List の機構を移植する。
それまでファイラーのリネームは List 表示側 or ダイアログで行う。
