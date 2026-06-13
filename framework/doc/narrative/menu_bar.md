---
unsafe: true
---

# menu_bar
MenuBar の描画・イベント処理・Window との連携・popup 発火。

## 目指したもの
メニューはクライアント領域に自前描画する (OS ネイティブメニューは使わない)。
見た目とルックアンドフィールを nimbus 側で完全に制御するため。
v1 ははみ出しをクライアント領域内に reposition / clip で収める (別ウィンドウ化は backlog)。

設計上の狙い:

* MenuBar / Menu / MenuItem / MenuSeparator / CheckBoxMenuItem / PopupMenu を最低限揃える。 Menu のネストは任意の深さ。
* 典型的には決まった項目だけと想定しつつ、 任意のコンポーネントも入れられる
  (利用者が多少ハックしてよい)。 `PopupMenuItem` のような派生型は作らない。
* アイコン領域は MenuItem / CheckBoxMenuItem / サブメニュー間で共通幅を確保し、 アイコン無し項目とも縦に揃う。
* メニューバーはクリックで開き、 メニューはホバーで開く。 ESC / 外クリックで閉じる。
* 展開中は下層が入力を受け取らない。 dismiss を伴う外クリックは下層に届けない (dismiss のみ)。

ネイティブメニューへ切り替える抽象は持たない (作者判断)。 自前コンポーネントを載せられることを優先する。

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
popup が dismiss されたら `open = null` に戻る（popup 側からコールバックで通知）。
