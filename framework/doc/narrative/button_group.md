---
unsafe: true
---

# button_group
ButtonGroup の動作・全 off 許容ポリシー・ChangeListener signature 制約。

## 動作
member のどれかが `setSelected(true)` で false → true へ transition した瞬間、 group が listener を介して検知し、 **他の全 member を `setSelected(false)`** で deselect する。
1 サイクル内で複数 transition が起きても (`add` 直後のクリア処理など)、 `muting` フラグで再入を防いで O(n) で完了する。

何も selected でない状態 (= 全 member off) は許容する。
利用者が `model.setSelected(false)` で現在の選択を解除した場合、 group は新規 winner を選び直さない (= 「一度ピックしたら戻せない」 仕様の Swing JButtonGroup とは異なる、 nimbus は permissive)。

「最低 1 個は selected であってほしい」 場合は、 利用者が `RadioButton` を直接使えばよい。
RadioButton の `processEvent` は「クリックで `selected = true` を強制」 する (= toggle ではない) ので、 ユーザー操作でグループ全 off にはならない。

## ChangeListener の signature 制約
`ChangeListener` の callback は `(user_data: *anyopaque) -> void` だけで、 「どの model が変化したか」 を直接渡さない。
このため group は自前で「前回の selected 状態」 を `prev_selected` に持って差分で source model を判定する。
将来 `ChangeListener` が source を渡せるようになれば snapshot は不要になる (機能要望)。
