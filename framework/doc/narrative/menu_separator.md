---
unsafe: false
---

# menu_separator
MenuSeparator の描画スタイル・配置可否・イベント処理。

## 描画
中央に水平線を 1 本引く。

| パラメータ | 値（v1） |
|---|---|
| 線の色 | RGB(0.75, 0.75, 0.78) 程度の淡いグレー |
| 線の厚さ | 1px |
| 上下 padding | 4px ずつ |

合計高さは `1 + 4*2 = 9px`。将来 theme 化する余地あり。

## 配置できる場所
* Menu の popup 内 ✓
* PopupMenu 内 ✓
* MenuBar の直接の子としては**配置できない**（バーは水平方向の Menu 並びで、区切り線の意味がない）

`MenuBar.add` に MenuSeparator を渡した場合の挙動は **未定義**（debug ビルドでは assert で弾く）。

## イベント
* マウス hover に反応しない（rollover state を持たない）
* クリックを消費しない（無視する）
* 親 Menu / PopupMenu のキーボードナビゲーションでは「スキップ可能な項目」として扱う（v1 ではキーボードナビ自体が機能要望なので関係なし）

vtable の `processEvent` は no-op 実装。

## install / uninstall
特に何もしない（no-op）。
state も listener も持たないため。
