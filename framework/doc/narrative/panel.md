---
unsafe: true
---

# panel
Panel と Container の分離理由・描画順序・境界線とレイアウトの関係。

## なぜ Container と分けるのか
Container は「子を持つ」という最小機能のみで、自身は透明である方が再利用しやすい。
背景色や境界線が必要な場面では Panel を使う。
役割を分けることで：

* Container を Window や Frame のルートとして使う時に「透明である」前提を壊さない
* Panel は「背景塗り + 境界線 + 子を持つ」をひとまとめにした便利型

利用者が「子をグルーピングしたいだけ、背景は不要」なら Container を直接使う。
「視覚的なグルーピング（カードや枠）を作りたい」なら Panel を使う。

## 描画順序
`vtable.paint` は以下の順で描画する。

1. 背景色（non-null の場合）— Panel の bounds 全体を塗る
2. 子コンポーネント（Container の paint と同じ、`getBounds()` でクリップして再帰）
3. 境界線（non-null の場合）— Panel の bounds の縁を描く

境界線を最後に描くのは「子のはみ出しを境界線で隠す」ためではなく、「子の描画と独立してフレームとして見える」ようにするため。
将来 angle rect の角丸境界線などを入れた時にも順序を変えなくて済む。

## 境界線と子のレイアウト
境界線の厚さは Panel のクライアント領域（content area = 子が配置できる領域）には**影響しない**。
LayoutManager は Panel 全体の bounds を基準に子を配置する。
境界線は子の上に重なって描画される可能性がある。

これは設計判断の一つで、Swing の `JPanel + EmptyBorder` のように「境界線が content insets を取る」モデルとは異なる。
nimbus が後者を採るなら `Border` に inset 計算ロジックを足し、LayoutManager 側で content area を縮めて扱う必要があり、設計が一気に重くなる。
v1 は単純さを優先して「境界線は装飾、レイアウトには影響しない」と割り切る。
子が境界線と重ならないようにしたい場合は、利用者が手動で内側に余白を取るか、`Border.thickness` 相当の inner padding を含む LayoutManager を使う。

## 子の追加 / 削除
内部の `Container` のメソッドを直接使う（委譲メソッドは生やさない）。

```zig
try panel.container.add(&child.component);
panel.container.setLayout(box_layout);
```

`component.md`「派生型から Component メソッドへのアクセス」と同じ方針。

デフォルト LayoutManager は `BorderLayout`。
追加設定なしで toolbar / status / sidebar / center のシェルが組める。
別の layout を使いたい場合は `panel.container.setLayout(BoxLayout.vertical())` などで差し替える。

## install / uninstall
Panel 固有の install / uninstall は基本 no-op。
内部の Container はすでに `create` 時に install 済み。
