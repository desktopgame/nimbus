---
unsafe: false
---

# menu
Menu が ButtonModel を流用する理由・親コンテキストによる描画差異・展開タイミング。

## ButtonModel を使う理由
Menu は「クリックで反応する」「hover で armed 状態が変わる」「disabled できる」など、Button と同じ state パターンを持つ。
個別に `MenuModel` を定義するメリットが薄いので ButtonModel を流用する。
`selected` フラグは Menu では使わない（popup の開閉は `open` フィールドで別管理）。

CheckBoxMenuItem / MenuItem も同じ理由で ButtonModel を使う（`checkbox_menu_item.md` / `menu_item.md` 参照）。

## 親コンテキストによる描画差異
Menu の `paint` は親 Container を判定して 2 種類の描画を出し分ける：

| 親 | 描画 |
|---|---|
| MenuBar | ラベルのみ（テキストを padding 付きで描画、open 中はハイライト） |
| Menu / PopupMenu の popup | 行形式（icon slot + テキスト + 右端に `>` 矢印） |

判定は `self.parent` を辿って親が MenuBar 型かどうかで分岐する。
親が直接 popup Container の場合は「行形式」に倒す。

## サブメニュー展開のタイミング
親が MenuBar の場合：**クリック**で展開（`menu-bar-requirements.md`「メニューバーはクリックで要素を展開」）。
親が Menu の popup の場合：**hover**で展開（同「メニューはホバーで要素を展開」）。

行内 hover で 200ms 程度の遅延を設けて誤展開を防ぐ実装余地あり（機能要望）。
