---
unsafe: true
---

# menu_bar
MenuBar の描画・イベント処理・Window との連携・popup 発火。

## 描画
MenuBar は水平方向に Menu のラベルを並べる。
各ラベルは Menu の `text` + 左右の padding を bounds とする。
`open` 中の Menu のラベルは選択状態（ハイライト背景）で描画する。

## イベント処理
```
状態遷移:
  待機 → クリック → 該当 Menu を open → popup 表示
  open 中 → 別 Menu に hover → そっちに切替（前のを閉じてから新規 open）
  open 中 → 同じ Menu を再クリック → 閉じる
  open 中 → 別 Menu のラベル外で release → 何もしない（popup 側に dispatch）
```

クリックの hit-test：x 座標から該当 Menu を線形探索（メニュー数は通常 10 個未満）。
hover による切替は MenuBar.processEvent の `.move` で「open 中かつカーソルが別 Menu の bounds 内」を検知して発火する。

## Window の menu_bar field との接続
`Frame.setMenuBar(bar)` が `window.menu_bar = bar` をセットする。
Window 側はメニューバーぶんの高さ（`bar.component.min_size.height`）を確保し、`container` の bounds をその下に詰める。
詳細は `window.md`「メニューバー層」を参照。

## popup の発火
クリックを検知したら `menu.show(window, anchor)` を呼ぶ。
`anchor` はクリックされた Menu ラベルの **左下** ウィンドウ座標。
popup は Window の overlays 層に登録される（実装詳細は `menu.md`「popup の表示」と `window.md`「overlays 層」参照）。

`open` フィールドはどの Menu が popup を持っているかを覚えるためのもの。
popup が dismiss されたら `open = null` に戻る（popup 側から callback で通知）。
