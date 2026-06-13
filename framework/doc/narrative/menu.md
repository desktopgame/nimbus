---
unsafe: true
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
| Menu / PopupMenu の popup | 行形式（icon スロット + テキスト + 右端に `>` 矢印） |

判定は `self.parent` を辿って親が MenuBar 型かどうかで分岐する。
親が直接 popup Container の場合は「行形式」に倒す。

## サブメニュー展開のタイミング
親が MenuBar の場合：**クリック**で展開（`menu_bar.md`「目指したもの」）。
親が Menu の popup の場合：**hover**で展開（同「メニューはホバーで要素を展開」）。

行内 hover で 200ms 程度の遅延を設けて誤展開を防ぐ実装余地あり（機能要望）。

## leaf 項目の型分岐と共通化の保留
Menu / PopupMenu は子の leaf 項目（MenuItem / CheckBoxMenuItem / RadioButtonMenuItem）を
vtable identity で判定し、モデルの取得（`modelOf`）と起動（`activateItem`）を出し分ける。
新しい leaf 型を足すときは、これらの分岐箇所すべてに追加する必要がある。
追加漏れはコンパイルも単体テストも通り、メニューに入れて初めて壊れる
（auto-dismiss が効かない、キーボードで飛ばされる、など）。
そのため担保は単体テストではなく、メニュー統合テスト（`focus_test.zig`）で行う。

共通化の案は 2 つある。
分岐を 1 つの helper に集約する案と、Component に optional な facet
（モデルを返す・起動する能力。DropTarget と同じ opt-in 構造体）を持たせて leaf 自身に登録させる案である。
後者なら更新漏れが構造的に起きない。

ただし現状は保留する。
メニュー配下に置く leaf の組み合わせは限られ、型ごとの特殊対応のコストが小さいためである。
分岐箇所の更新が負担になるほど leaf が増えたら、上記いずれかで再検討する。
