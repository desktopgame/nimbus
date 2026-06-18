# examples
サンプル集
framework を使うものは widget_* という名前にすること。
nimbus の C ABI としてエクスポートされた機能を使うサンプルで、かつC言語で実装されたサンプルは cnimbus_* のような名前をつけてください。
ドッグフーディングとして作る実用アプリ（ファイラー、テキストエディター等）は app_* という名前にすること。

## hello
awtの低レベルAPIを使用して、フォントとプリミティブ図形（矩形、円）を描画する。

## snapshot
awtの低レベルAPIを使用して、プリミティブ図形（矩形、円）を描画して画像に書き出す。（ウィンドウを出さない）

## widget_simple
frameworkのAPIを使用して、ボタン、スライダー、ラベルを横一列に並べる。

## widget_menu
frameworkのAPIを使用して、メニュー、ポップアップメニューを表示する。

## widget_textfield
frameworkのAPIを使用して、テキストフィールドを表示する。あわせて、PaddingLayout（外周マージン）と BoxLayout の spacing（行間）で余白を作る正典レシピのデモも兼ねる。

## widget_textarea
frameworkのAPIを使用して、複数行のテキストエリアを `ScrollPane` に入れて表示・編集する。ボタンで折り返し（line wrap）の on/off を切り替えられ、折り返しなしは水平＋垂直スクロール、ありは垂直のみになる。編集中にキャレットが見えるよう自動スクロールする（キャレット追従）デモも兼ねる。

## widget_checkbox
frameworkのAPIを使用して、チェックボックスを縦に並べ、ラベルでチェック状態をミラー表示する。

## widget_radio
frameworkのAPIを使用して、ラジオボタン群を `ButtonGroup` でまとめ、相互排他選択をデモする。

## widget_combobox
frameworkのAPIを使用して、ドロップダウンから1つの項目を選び、ラベルに反映する。Popup は overlay で表示。

## widget_dialog
frameworkのAPIを使用して、モーダルダイアログ（OK/Cancel で結果を返す、表示中は親をブロック）とモードレスダイアログ（親と並行して使える）を開く。ダイアログは生成して使いまわす。

## widget_window
frameworkのAPIを使用して、2つのボタンからウィンドウ自身の位置とサイズをコード側で変更する。イベントループ末尾でのジオメトリ同期（`setPos`/`setSize` → OS への push）のデモを兼ねる。

## widget_scroll
frameworkのAPIを使用して、ウィンドウより大きいラベルのグリッドを `ScrollPane` に入れ、縦横にスクロールする。ホイール（Shift+ホイールで横）、バーのドラッグ／トラッククリックを試せる。

## widget_list
frameworkのAPIを使用して、`List` を `ScrollPane` に入れて 40 行を表示する。各セルはチェックボックス＋ラベル＋削除ボタンを持つ実コンポーネントで、可視範囲ぶんだけ生成され、スクロールで recycle される。チェック状態は行データに永続化され recycle で他行に漏れないこと、削除が正しい行を消すこと（逆引き不要）、行選択（クリック＋上下キー）をデモする。JavaFX VirtualFlow 方式のセル設計（`framework/doc/list.md`）の検証シーン。

## widget_listedit
frameworkのAPIを使用して、`List` のセル編集（CellEditor）をデモする。各セルは表示モードでラベル、編集モードで TextField に切り替わる「同じ実セルがトグルする」JavaFX 方式。ダブルクリック or 選択+Enter で編集開始、Enter で確定、Escape で取り消し、別行クリックで commit（フォーカス喪失=commit）。編集テキストは行データへ書き戻される。`framework/doc/list.md`「編集 (CellEditor)」の検証シーン。

## widget_listdnd
frameworkのDnD基盤を使用して、`List` の行をドラッグして同じ List の任意位置にドロップし並べ替える（自身へのドロップ）。`List` 本体は書き替えず、`Component.drag_source` / `drop_target` を外から付けるだけで実現する。ドラッグ中は挿入位置に青い線が出て（List の vtable をコピーして paint だけ装飾）、ドロップで `ListModel.move` により行が移動する。Escape で取り消し。`framework/doc/dnd.md`「List の行並べ替え」の検証シーン。

## widget_layoutcost
frameworkのAPIを使用して、向きが階層ごとに交互に変わる BoxLayout コンテナーを深く・多子にネストする（デフォルト ~3万ノード）。起動時に強制再レイアウトを多数回実行してコスト（1回あたりの所要時間）を計測・表示し、さらに**毎フレーム**ツリー全体を再レイアウトし続けるのでウィンドウが目に見えてカクつく。レイアウトエンジンのベンチマーク／体感用シーン（`doc/internal/optimize.md` 参照）。描画が律速にならないよう葉の塗りは間引いている。引数で `depth fanout iters` を指定可能（例: より重くするなら `zig build run-widget_layoutcost -- 10 3 10`、軽くして比較するなら `-- 6 3 200`）。

## widget_keyboard
frameworkのキーボード操作を一通り試すフォーム。Tab / Shift+Tab のフォーカス巡回（disabled ボタンはスキップ、端で wrap）、Space / Enter / 矢印キーでの操作、ニーモニック（Alt+F でメニューを開く、開いたメニュー内は素の S/O/Q、Alt+A / Alt+R でボタン起動。下線表示つき）、メニュー内キーボードナビゲーション（↑↓ でハイライト移動・wrap・disabled で停止、Enter で起動、→/← でサブメニューの出入り、Esc は1段ずつ閉じる）、アクセラレータ（メニューが閉じていても Ctrl/Cmd+S・Ctrl/Cmd+O が効き、メニュー展開中なら閉じてから実行）、既定ボタン（Enter で OK。ただしフォーカス中の TextField は Enter を submit として消費する＝フォーカスが勝つ実例）、ドロップダウン展開中の Tab（外クリック同様に閉じて次へ移動）をデモする。`framework/doc/narrative/keybinding.md` の検証シーン。

## app_filer
ドッグフーディングの実用アプリ第1号: ファイラー。現在は M5（リスト / 詳細ビュー）。
右ペインは**1つの共有モデル**（`Model = List.ListModel`）に対する2ビューを切り替えられる。ツールバーの「Details」/「List」ボタンで、リストビュー（アイコン+名前、インプレースリネーム + DnD 移動）と詳細ビュー（Name / Size / Modified 列の Table、ヘッダークリックでソート、列境界ドラッグで列幅変更、DnD 移動）を切り替える。非アクティブなビューは小さな CardLayout（カスタム LayoutManager）でゼロサイズにし、両方を holder に所有させたまま隠す。左ペインは場所一覧（シングルクリックで移動）。パスバーに絶対パスを入力して Enter で移動、ダブルクリック / Enter で開く、行の右クリックでコンテキストメニュー（Open / Rename / Delete）、背景右クリックまたは Ctrl+Shift+N で New Folder 作成 + 即インプレースリネーム、F2 でインプレースリネーム、Delete でモーダル確認してからファイル / 空フォルダ削除、F5 で再読み込み、↑ボタン / Backspace で親へ。起動時はカレントディレクトリ。
F2 リネームは両ビューでインプレース（詳細ビューは Table の Name 列が CellEdit を持つ。framework#14）。DnD 移動もリスト / 詳細の両ビューで動く。
SplitPane、Table（複数カラム / ヘッダーソート / 列幅ドラッグ）、共有モデルによる List⇄Table 両ビュー、CardLayout 風のカスタム LayoutManager、List の行アクティベーション / コンテキストメニュー、CellEditor の手動トリガ、`EventQueue.invokeLater`、Label のアイコン、ペイン跨ぎ DnD の検証シーンを兼ねる。

## cnimbus_editor
nimbus の C ABI（`include/nimbus.h` + `libnimbus`）だけを使い、**C 言語**でエディタ風の画面を組むサンプル（Zig を一切使わない）。メニューバー（File / Edit）、上部のツールバー（north）、スクロールペインに入れたテキストエリア（center）を BorderLayout で配置する。将来の Python / JS バインディングが C ABI をどう叩くかの実証も兼ねる。

**動的リンク（`nimbus.dll` を横に置く）が基本**。将来の Python / JS バインディングも結局 `nimbus.dll` を
読む形になるので、C サンプルもそれに合わせている。ビルド・実行は 2 通り：

1. **build.zig 経由**（他のサンプルと一緒に CI でビルド検証される）。`libnimbus`（動的）にリンクする：
   ```
   zig build run-cnimbus_editor      # run ステップが nimbus.dll を解決して起動
   ```
   `examples/` 配下に exe として置きたいなら、`exe` と `nimbus.dll` の両方をコピー：
   ```
   zig build
   copy zig-out\bin\cnimbus_editor.exe examples\cnimbus_editor\
   copy zig-out\bin\nimbus.dll        examples\cnimbus_editor\
   ```

2. **素朴に直叩き**（配布された `nimbus.h` + `nimbus.dll` を C アプリから使う最短経路）。
   まず一度 `zig build` してライブラリを出す（`zig-out/include/nimbus.h`・`zig-out/lib/nimbus.lib`・
   `zig-out/bin/nimbus.dll`）。あとは同梱の `build.bat` が zig cc コンパイル＋`nimbus.dll` コピーをして、
   この `examples/cnimbus_editor/` に exe + dll を並べる：
   ```
   examples\cnimbus_editor\build.bat
   examples\cnimbus_editor\cnimbus_editor.exe
   ```
   バッチがやっているのは次の 2 行だけ（`-I` でヘッダー、`-L` + `-lnimbus` で import ライブラリにリンク。
   clang / MSVC `cl` / gcc も同じ要領）。動的リンクなので、実行時に `nimbus.dll` が exe の隣か PATH 上に要る：
   ```
   zig cc examples/cnimbus_editor/main.c -I zig-out/include -L zig-out/lib -lnimbus -o examples/cnimbus_editor/cnimbus_editor.exe
   copy zig-out\bin\nimbus.dll examples\cnimbus_editor\
   ```

   > DLL 不要の単一 exe が欲しい場合は、build.zig で C ABI を `linkage = .static` の静的ライブラリとして
   > リンクすれば self-contained な exe（~21MB、nimbus/DX12/GLFW/FreeType を内包）が作れる。ただし手で
   > `zig cc` する場合は、静的アーカイブが依存する awt-c / GLFW / FreeType（キャッシュ内）やシステム lib
   > （d3d12 / dxgi / dxguid / d3dcompiler_47 / imm32 / user32 / gdi32 / shell32）を内包しないため全部
   > 並べる必要があり非現実的。単一 exe にするならビルドシステム経由で静的リンクするのが筋。
