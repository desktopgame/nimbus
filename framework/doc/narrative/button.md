---
unsafe: false
---

# button
Button の描画モード・状態変化と Action の二系統・armed/pressed の違い・状態フロー。

## 描画モード
`text` と `icon` の有無で 3 通り自動切替する：

| text | icon | モード | 見た目 |
|---|---|---|---|
| 有 | 無 | standard | 角丸矩形 + 背景塗り（push button 風）。既存の挙動 |
| 有 | 有 | standard | 同上 + アイコンをラベルの左に並べる |
| 無 | 有 | flat | **枠なし**。hover / armed のときだけ薄グレーの矩形背景。toolbar 向け |

flat モードでは hover 時の背景色しか描かないので、toolbar に並べたとき周囲と自然に溶け込む。
standard モードでは常時の枠塗りがあり、独立したクリック対象として目立つ。


## 状態変化と Action の二系統
Button には 2 種類の通知系統がある。これは Swing の `JButton` も同じ。

| 通知 | 発火タイミング | 主な購読者 |
|---|---|---|
| ChangeListener | pressed / armed / rollover / enabled / selected が変化した時 | Button 自身（再描画）、L&F |
| ActionListener | クリックが完了した時（press 後 armed のまま release） | アプリケーションコード |

理由：

* 状態変化は再描画のフックとして頻繁に発生する（マウスが上に来ただけで rollover が変化、押下するだけで pressed が変化）
* アクションは「ユーザーが意図的にクリックした」セマンティクスを 1 回だけ通知すべきもの
* この 2 つを混ぜると、利用者が「ユーザーがクリックした時だけ何かしたい」と書きづらくなる

実装上は `state_listeners: ChangeListenerList`（`ChangeEvent` を配送）と
`action_listeners: ActionListenerList`（`ActionEvent` を配送）の 2 本を持ち、
`addChangeListener` / `addActionListener` という別エントリーポイントで登録する。
イベント型自体が `ChangeEvent` / `ActionEvent` に分かれているので、ハンドラのシグネチャを見れば
どちらの通知を受けるのかが分かる（`model.md`「ChangeEvent と ActionEvent」参照）。

## armed と pressed の違い
| | 意味 |
|---|---|
| `pressed` | マウスボタンが現在押されている |
| `armed` | 押下中かつカーソルが Button の bounds 内にある |

「ドラッグして Button から外に出ると armed が false になり、戻ると true になる」「離した時に armed なら action 発火」という挙動を可能にするための区別。
Swing の `ButtonModel` と同じ意味。

## 値変化から再描画と Action 発火までの流れ
ユーザー操作の典型シナリオ：

1. マウスが Button 上に乗る → `processEvent` が `setRollover(true)` を呼ぶ
2. ChangeListener fire → `component.repaint()`（hover 状態の見た目に切替）
3. マウスボタン押下 → `setPressed(true)`, `setArmed(true)`
4. ChangeListener fire → `component.repaint()`（押下中の見た目に切替）
5. マウスボタンを離す（カーソルが内側）→ `setPressed(false)`, `setArmed(false)` → ChangeListener fire → `component.repaint()`、その後 `fireAction()` → ActionListener fire → アプリのハンドラが呼ばれる
6. マウスボタンを離す（カーソルが外側）→ `setPressed(false)`, `setArmed(false)` → ChangeListener fire → `component.repaint()`（Action は発火しない）

これにより「ドラッグで取り消し」ができる UX が実装される。

## install / uninstall で Model にリスナーを登録する
vtable の `install` で Model に「自分自身を再描画するための ChangeListener」を登録する。
`uninstall` で外す。
L&F 差し替え時の挙動は `model.md`「ウィジェットとの連携」と同じ。

ActionListener の登録は利用者がアプリコードから直接行う（Button 自身は登録しない）。
