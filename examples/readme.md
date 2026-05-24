# examples
サンプル集
framework を使うものは widget_* という名前にすること。

## hello
awtの低レベルAPIを使用して、フォントとプリミティブ図形（矩形、円）を描画する。

## snapshot
awtの低レベルAPIを使用して、プリミティブ図形（矩形、円）を描画して画像に書き出す。（ウィンドウを出さない）

## widget_simple
frameworkのAPIを使用して、ボタン、スライダー、ラベルを横一列に並べる。

## widget_menu
frameworkのAPIを使用して、メニュー、ポップアップメニューを表示する。

## widget_textfield
frameworkのAPIを使用して、テキストフィールドを表示する。あわせて、空Panelを使って余白（margin相当）を作るレシピのデモも兼ねる。

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

## widget_layoutcost
frameworkのAPIを使用して、向きが階層ごとに交互に変わる BoxLayout コンテナーを深く・多子にネストする（デフォルト ~3万ノード）。起動時に強制再レイアウトを多数回実行してコスト（1回あたりの所要時間）を計測・表示し、さらに**毎フレーム**ツリー全体を再レイアウトし続けるのでウィンドウが目に見えてカクつく。レイアウトエンジンのベンチマーク／体感用シーン（`doc/optimize.md` 参照）。描画が律速にならないよう葉の塗りは間引いている。引数で `depth fanout iters` を指定可能（例: より重くするなら `zig build run-widget_layoutcost -- 10 3 10`、軽くして比較するなら `-- 6 3 200`）。