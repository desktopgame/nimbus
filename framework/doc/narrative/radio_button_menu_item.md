---
unsafe: true
---

# radio_button_menu_item (narrative)
spec は [../radio_button_menu_item.md](../radio_button_menu_item.md)。 ここに設計判断の理由を残す。

## CheckBoxMenuItem と別型にした理由
データ構造 (text / font / color / `ToggleButtonModel`) とレイアウトは CheckBoxMenuItem と同じ。
違うのは 3 点だけ: クリックがトグルでなく常に on、 インジケータがチェックでなく radio 円、
排他性を ButtonGroup が担う。 CheckBox と RadioButton を別ウィジェットにしているのと同じ理由で、
メニュー項目でも別型にする。 共有部分は CheckBoxMenuItem の実装を雛形にして差分だけ変える。

## クリックをトグルにしない理由
radio は「選んだものが on、 他は off」が意味。 同じ項目を再クリックして off にできると
「どれも選ばれていない」状態を作れてしまい、 排他選択の不変条件が壊れる。
なので RadioButton と同じく、 クリックは常に selected = true にする (冪等)。
off になるのは別の項目が選ばれたとき (group 経由) だけ。

## 排他性を型に内蔵せず ButtonGroup に任せる理由
「どの項目同士が排他か」はメニュー項目自身には分からない。 グルーピングは利用者の都合で決まる。
RadioButton と全く同じ構図なので、 同じ仕組み (`getModel()` を `ButtonGroup` に add) を使う。
ButtonGroup は group hook で破棄順序が前後どちらでも安全 (`button_group.md`「寿命」)。
型に内蔵すると、 メニューをまたいだグループや toolbar と混在するグループが作れなくなる。

## インジケータを選択時だけ描く理由
CheckBoxMenuItem がチェックマークを checked のときだけ描くのに揃えた。
非選択の項目に空の円を描くスタイルもある (Swing の一部 L&F) が、 それは機能要望に回す。
icon スロットの使い方 (専有・幅の確保) は CheckBoxMenuItem と同一なので、 縦の揃いも自動で合う。
