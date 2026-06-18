---
unsafe: true
---

# panel
Panel と Container の分離理由・2 コンテナー構造・描画順序・overpaint バグ修正・境界線と余白の扱い。

## なぜ Container と分けるのか
Container は「子を持つ」という最小機能のみで、自身は透明である方が再利用しやすい。
背景色・境界線・余白が必要な場面では Panel を使う。
役割を分けることで：

* Container を Window や Frame のルートとして使う時に「透明である」前提を壊さない
* Panel は「背景塗り + 境界線 + 余白 + 子を持つ」をひとまとめにした装飾型

利用者が「子をグルーピングしたいだけ、装飾は不要」なら Container を直接使う。
「視覚的なグルーピング（カードや枠）を作りたい」なら Panel を使う。

## 2 コンテナー構造（決定）
Panel は内側余白を `PaddingLayout` の合成で実現する。
構造は外側 `container` と内側 `content` の 2 つの Container からなる。

* **外側 `container`**: Panel の vtable を持ち、背景と境界線を描く描画ハンドル。layout は `PaddingLayout` 固定、子は `content` 1 個だけ。
* **内側 `content`**: 利用者が子を追加し、レイアウトを差す先。`PaddingLayout` によって inset ぶん内側に配置される。

inset のロジックを Panel 内で二重に持たず、`PaddingLayout`（`padding_layout.md`）に集約するための構造。
`PaddingLayout` に渡す各辺の inset は `border.thickness + padding.<edge>`。
`setBorder` / `setPadding` のたびにこの値を再計算して `PaddingLayout.setInsets` で差し替え、`markLayoutDirty` を撃つ。

余白も境界線も無い Panel でもこの 2 ノード構造になる（中間 Container が 1 つ増える）。
これは「散ったスペーサより規則的なノードの方が綺麗」という余白プリミティブ全体の方針（`narrative/padding_layout.md`）に従う割り切りで、
将来 `role` による走査の読み飛ばしで吸収する余地を残す。

## content の露出（決定）
利用者から見た API は 2 つのアップキャストに集約する。

* `asComponent()` → 外側 `container.component`（描画ハンドル。親への追加・`setBounds`・grow に使う）
* `asContainer()` → 内側 `content`（子の追加・`setLayout` に使う）

`panel.container` フィールド自体は外側のまま据え置く。
これにより既存コードで最頻出の「`panel.container.component` を親へのハンドルとして使う」用法は無改修で通る。
一方、従来 `panel.container.add` / `panel.container.setLayout` と書いていた content 操作は `panel.asContainer()` 経由へ移行する
（外側 `container` に子を足すと `PaddingLayout` の単一子契約を破るため）。
`asContainer()` の戻り値の意味が「外側」から「content」へ変わる再定義であり、旧 `asContainer()` 呼び出し箇所（`tabbed_pane.md` の例など）は併せて見直す。

却下案: 外側を `container` 以外へ改名して直接フィールドアクセスを全廃する案もあったが、
`panel.container.component` ハンドル参照が `scenes.zig` / 各テストに大量にあり、改名はそれら全箇所の churn を生む。
最頻出のハンドル参照を温存し、content 操作だけを移行する方が軽い。

## 描画順序と overpaint バグ修正
`vtable.paint` は以下の順で描画する。

1. 背景色（non-null の場合）— 外側 bounds 全体を塗る
2. content（唯一の子。`getBounds()` でクリップして再帰）
3. 境界線（non-null の場合）— 外側 bounds の縁を 4 枚の rect で描く

従来は content の inset を予約せず、子を Panel 全体の bounds に配置していた。
このため境界線（最後に縁へ描く）が子の外周を上塗りする overpaint バグがあり、stretch する子で顕在化していた。
今回 `PaddingLayout` が各辺 `border.thickness + padding` の inset を予約することで content が境界線の内側へ収まり、上塗りが起きなくなった。
境界線の 4 枚の rect の幾何（外周 `thickness` ぶんの帯）は従来どおりで変えていない。修正の本体は「content を内側へ寄せる」点にある。

## 境界線と余白とレイアウト（旧判断の撤回）
従来 narrative は「境界線の厚さは content area に影響しない。子は境界線と重なりうる」と割り切っていた。
余白プリミティブの導入に伴いこれを撤回する。

`PaddingLayout` 合成により、境界線の厚さと `padding` は content のレイアウト領域を内側へ削る（Swing の `JPanel + EmptyBorder` に近いモデル）。
当時は「inset 計算を全 LayoutManager に行き渡らせるのは重い」として避けていた。
だが wrapper 方式（単一の子をずらすデコレータ）なら既存レイアウトを無改修で済むため、重さの懸念は解消した
（`narrative/padding_layout.md`「なぜ wrapper 方式なのか」）。

## install / uninstall
Panel 固有の install / uninstall は基本 no-op。
外側 Container・内側 content はともに `create` 時に install 済み。

## テスト方針
`Application` / GPU 非依存の純ロジックテスト（`Panel.create` + `Container.create` の手組みで常時走らせる）。

* inset 予約: 境界線厚 `t` と `padding` を設定し、外側に bounds を与えて `doLayout()` を呼ぶ。
  content の bounds が各辺 `t + padding.<edge>` ぶん内側にある（`x >= t`、右端 `<= W - t` 等）ことを確認する。
* overpaint 回帰ガード: content が境界線の内側に収まることを上記で確認する。
  これは revert（content を全体 bounds に戻す旧実装）で必ず落ちる真のガードになる。
* 解放: Panel を破棄したとき content と合成 `PaddingLayout` が解放され、リーク・二重解放が無いこと（`std.testing.allocator`）。
