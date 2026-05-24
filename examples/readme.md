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