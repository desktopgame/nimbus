---
unsafe: true
---

# slider
Slider の値変化フロー・入力処理・install/uninstall・共有 Model の用途。

## 値変化から再描画までの流れ
Slider は次の連鎖で動く。

1. 利用者がツマミをドラッグ → `processEvent` が MouseEvent を受ける
2. `processEvent` が新しい値を計算して `model.setValue(new)` を呼ぶ
3. `model.setValue` が値変化を検知して `change_listeners.fire()` する
4. ChangeListener A（Slider 自身、`install` で登録済み）: `component.repaint()` を呼ぶ
5. ChangeListener B（利用者が `addChangeListener` で登録）: アプリ独自のロジック

利用者の `setValue(75)` から直接呼ばれた場合も 3 以降は同じ経路を通る。
ドラッグ操作とプログラム的なミューテーションが同じ通知経路に乗るのが重要なポイント。

## install / uninstall で Model にリスナーを登録する
vtable の `install` / `uninstall` で Model に自身を ChangeListener として登録 / 削除する。
これにより L&F 差し替えのために `setVTable` した場合も、旧 vtable がリスナーを外して新 vtable が必要なリスナーを登録するという挙動が成立する（`model.md`「ウィジェットとの連携」参照）。

## 入力処理
`processEvent` で MouseEvent を受け、以下を行う。

* `.press` でツマミ位置を確定（ドラッグ開始）
* `.move` でドラッグ中のツマミ追従、Model 値更新
* `.release` でドラッグ終了

KeyEvent も将来サポート予定（矢印キーで増減）。
イベント座標は dispatch 側で Slider のローカル座標に変換済み（`awt/doc/event.md`「座標系」参照）。

## 共有 Model のユースケース
複数の Slider が同じ Model を共有することで、片方を動かすともう片方も追従する。
具体例は v1 の典型用途では少ないが、「同じパラメータを違うレイアウトで複数表示する」や「内部 Model と外部 Model を切り替える」場面で使える。
