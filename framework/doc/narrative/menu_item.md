---
unsafe: true
---

# menu_item
MenuItem が ButtonModel を流用する理由・描画レイアウト・クリック挙動・install/uninstall。

## ButtonModel を流用する理由
MenuItem の状態（enabled / armed / rollover）とクリック完了 semantics は Button と完全に同じ。
`button.md`「状態変化と Action の二系統」を参照。
専用の `MenuItemModel` は冗長になるので作らない。

## 描画レイアウト
横並び 3 カラム（左から）：

1. **icon slot**: 固定幅 `icon_slot_width`（≒ 24px）。`icon` が non-null ならそれを描画、null なら空白
2. **label**: テキストを描画。左寄せ、cy は項目中央
3. **accel slot**: 固定幅 `accel_slot_width`（≒ 60px）。v1 は未使用（空白）。将来 `Ctrl+S` 等を右寄せで描画

| 状態 | 背景 | 文字色 |
|---|---|---|
| 通常 | 透明 | 標準 |
| hover (rollover) | アクセント色（淡） | 標準 |
| armed (押下中) | アクセント色（濃） | 反転 |
| disabled | 透明 | グレー |

slot 幅は親 Menu / PopupMenu が `computeMinSize` で全項目をスキャンして決める。
個別の MenuItem は単独描画では「ぴったり最小」で見えても、Menu の中に入ると左寄りに揃って描画される。

## クリック挙動
`Button.processEvent` と同じ：press → armed のまま release → `model.fireAction()`。
ドラッグで外れる → armed=false、戻る → armed=true。

クリックされた MenuItem は **自分で popup を閉じない**。Menu / PopupMenu 側が「子項目が action を発火した」のを ActionListener で検知して popup を hide する。
これにより MenuItem は popup の存在を知らずに済む。

## install / uninstall
`install` で model に「再描画用 ChangeListener」を登録する。
`uninstall` で外す。
親 Menu / PopupMenu が `add` した時に install されるのではなく、`create` 時点で install される（Button と同じ）。
