---
unsafe: false
---

# checkbox_menu_item
CheckBoxMenuItem のクリック挙動・icon slot 使用法・ButtonModel 流用の理由。

## クリック挙動
`MenuItem` と同じ流れだが、`fireAction` の前に **checked のトグル**を挟む：

1. press → armed=true, pressed=true
2. release (armed のまま、内側) → `model.setSelected(!model.selected)` でトグル → `model.fireAction()`
3. release (外側) → トグルせず、action も発火せず

ChangeListener は selected が変化した時点で発火、ActionListener はその直後に発火する。
利用者は ActionListener で「クリックされた時の処理」を、ChangeListener で「selected の状態反映」を扱える。
（多くの場合は ActionListener 1 つで十分）

## icon slot の使い方
icon slot にはチェックマークを描画する（`model.selected == true` の時のみ）。
`MenuItem` のような任意 Image はサポートしない（slot を占有しているため）。
チェックマークの描画スタイル：

| 状態 | 描画 |
|---|---|
| checked=true | アクセント色でチェックマーク（✓）を描画 |
| checked=false | 空白 |

## 描画レイアウト
基本は `MenuItem` と同じ 3 カラム構成（icon slot / label / accel slot）。
icon slot はチェックマーク描画専用になる点だけ違う。
背景・文字色の state ルールも `MenuItem` と同じ。

## ButtonModel を流用する理由
* enabled / armed / rollover は `MenuItem` と同じ要件
* `selected` フィールドが既に ButtonModel にある（トグルボタン用途として）
* 専用の `CheckBoxMenuItemModel` を作る冗長性を回避
