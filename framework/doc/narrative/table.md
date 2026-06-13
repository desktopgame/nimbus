---
unsafe: true
---

# table (narrative)
spec は [../table.md](../table.md)。ここには設計判断の理由と却下案を残す。

## ソートを Table がやらない理由
JTable は ビュー側に行の並び替え写像 (RowSorter、ビュー index ↔ モデル index 変換) を持つ。
nimbus v1 ではこれを採らず、「Table はヘッダークリックを通知してインジケータを出すだけ。
並べ替えは行 item の所有者 (アプリ) がモデルに対して行う」とした。理由:

* **モデルは借用**である (行 = `*anyopaque`、実メモリはアプリ所有)。Table が値を比較するには
  列ごとの比較プロトコル (comparator 登録) が要り、「Table は行の中身を解釈しない」という
  List から続く設計が崩れる。
* **写像は複雑さの税金が高い**。ビュー index と モデル index の二重系ができると、選択・活性化・
  コンテキストメニュー・セル束縛・将来の編集まで全 API が「どちらの index か」を背負う。
  JTable がまさにこの税金を払っている (RowSorter 導入時に互換の罠が多発した)。
* nimbus の実需 (ファイラー) ではアプリが既に自前でソートしている (フォルダ先行 +
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

## TableColumnModel を独立モデルにせず Table に畳んだ理由
Swing の JTable は珍しく 4 つのモデルに割れている。
- TableModel (データ)
- **TableColumnModel** — 列の構造を ビューオブジェクトとして持つ。
  各 TableColumn が幅 / レンダラ / ヘッダ値等を保持し、
  列のドラッグ並べ替え・幅変更・表示非表示はデータモデルに触れずここで起きる
- ListSelectionModel (選択)
- RowSorter (行の並び替え写像)

JList に対して JTable が余分に持つ「ビューモデル」の本体はこの TableColumnModel である。

nimbus v1 は **データモデル (`Model = List.ListModel`) だけを独立に保ち、残り 3 つ
(列の構造・選択・並び) は Table 自身のフィールドに畳んだ**:
* 列の構造 → `columns: []ColumnState` (Table 所有。幅はドラッグで変わる実行時状態込み)
* 選択 → `selected: ?usize` (List と同じく内蔵)
* 並び → 持たない (アプリがデータモデルを並べ替える。「ソートを Table がやらない理由」)

TableColumnModel を独立の差し替え可能オブジェクトにする利点は、(1) 1 つの列構成を複数
テーブルで共有する、(2) 列の動的な追加 / 削除 / 並べ替え、の 2 つ。どちらも v1 の実需に無い。
列を Table に焼き込めば単純になり、要るものは何も失わない。

後で独立化したくなっても安い (additive): データモデルと同じく `createWithColumnModel`
相当を `createWithModel` と並べて足し、`getColumnWidth` 等は内部の列モデルへ委譲できる。
公開シグネチャは温存される。これは「データモデルだけは今分離する」判断 (ListModel を
全シグネチャに織り込むのは後で変えると break) との対比で、列モデルは subset→superset で
追える側だから今は畳んでよい、という整理。

## ヘッダーを Table 自身が描く理由 (ScrollPane columnHeader を待たない)
Swing は JScrollPane の columnHeader 領域に JTableHeader を置く方式だが、nimbus の
ScrollPane に行 / 列ヘッダー領域はまだ無い (scrollpane.md 機能要望)。v1 は Table が
自分の描画の中でヘッダーを上端に固定表示する (スクロールオフセットを打ち消して描く)。
自己完結していて ScrollPane に手を入れずに済む。columnHeader 方式は「ヘッダーだけ
クリップ外に出したい」「複数テーブルでヘッダー共有」などの実需が出たら移行を検討する
(spec の機能要望に記載)。

## セル編集の範囲 (案A: 単一セル)
当初 v1 から外していたが、ファイラー M5 で詳細ビューのリネーム実需が出たため
framework#14 (案A) として追加した。List の CellEdit (start / commit / cancel +
リサイクル 除外 + フォーカス喪失決着) をそのまま移植し、編集対象は **1 セル**に限定する
(`edit(row, col)`)。編集可能列はその列のセルが `edit` を持つかで決まる。

案B (セル単位の 2 次元編集 + Tab で隣セルへ移動、スプレッドシート的) は採らなかった:
決め事 (どの方向に Tab で動くか、編集可能セルだけ巡るか、行端での折り返し等) が多く、
実需 (Name 列だけのインプレースリネーム) を超える。Tab 移動は機能要望に残す。

選択 index と同じく、編集位置 `EditPos{ row, col }` の row は**モデル順**
(view 写像を持たない方針と一貫)。編集中にアプリがモデルを並べ替えると編集セルの行が
変わりうるが、実需 (リネーム) では commit → 並べ替えの順なので問題にならない。
