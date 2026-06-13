---
unsafe: true
---

# popup_menu
PopupMenu と Menu の関係・dismiss 規則。

## Menu との関係
PopupMenu と Menu は popup の挙動が酷似している（同じ item 型を縦に並べる、外クリックで閉じる、Escape で閉じる）。
内部実装は popup Container の管理ロジックを共有してよい（実装の自由）。

API として分かれているのは **トリガと所有モデル**が違うため：

| | Menu | PopupMenu |
|---|---|---|
| トリガ | MenuBar クリック / 親 Menu の hover | 利用者の `show(x, y)` |
| ラベル | あり（バー / 行のテキスト） | なし（popup 本体のみ） |
| ツリー位置 | MenuBar / 他 Menu の子 | コンポーネントツリーに属さない |
| Component 派生 | ○ | × |

## 外クリックでの dismiss
popup の外がクリックされたら自動で `hide` する。
これは Window 側の overlay dispatch が「モーダル overlay 外のクリックは dismiss」として実装することを想定
（`menu_bar.md`「目指したもの」参照）。
PopupMenu 自身は dismiss コールバックを受け取って `hide` を呼ぶだけ。

## item クリックでの自動 dismiss
PopupMenu の item が ActionListener を発火したら自動的に `hide` する。
これは PopupMenu の `add` 内部で item のモデルに内部 ActionListener を登録することで実現する。
利用者が ActionListener を追加する時、PopupMenu のリスナーと独立に動く（fire は両方に飛ぶ）。

サブメニュー（Menu を popup の中に入れた場合）は item ではなく Menu なので、Menu 自身の popup を開くだけで PopupMenu は閉じない（カスケード popup を維持する）。
