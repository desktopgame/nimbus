---
unsafe: false
---

# label
Label の所有モデル・自動算出・描画・install/uninstall・拡張ポイント。

## text の所有
text は Label が `allocator.dupe` で複製して所有する。
利用者は文字列の寿命を気にせず `label.setText("hello")` のような literal も渡せる。
コストは数十バイトの memcpy なので無視できる。

Swing `JLabel` の `String` と同じ「ラベルが持つ」セマンティクスである。

## MinimumSize の自動算出
Label は `component.min_size` を「現在の text を現在の font で描画したときに必要な寸法」に保つ責任を負う。
更新タイミングは次の 3 箇所のみ。

* `create` — 初期値から算出してセット
* `setText` — 新しい text の寸法を測ってセット
* `setFont` — 新しい font で現在の text の寸法を測ってセット

利用者がさらに大きな下限を指定したい場合は `component.setMinSize(...)` で上書きできるが、その後 `setText` / `setFont` を呼ぶと Label が再計算した値で上書きされる。
`max_size` / `grow_x` / `grow_y` は Label からは触らない（利用者が `Component` の setter で設定する）。

## 描画
`vtable.paint` は `Graphics` に対して font / color を設定したのち、`drawString` を `(0, 0)` を起点に呼ぶ。
`(0, 0)` は component ローカル座標で、`graphics.md` の方針に従って top-of-bounding-box が原点に合う。

`\n` を含む文字列は `drawString` が無視する（`graphics.md` 参照）。
複数行描画は別ウィジェット（TextArea 等）として扱う方針。

## install / uninstall
ビルトイン Label の install / uninstall は no-op。
Label の状態（text / font / color）はすべて `create` でセット済みであり、install hook は「カスタム vtable がプロパティに自前 state を登録したい」場合のための拡張点である（component.md 参照）。

## ライフサイクル
`create` が allocator 確保・init・vtable 登録・install をひとまとめに行う（component.md「ライフサイクル」と同じ pattern）。
Application 経由のファクトリ `app.label(text)` は `create` をラップして default_font と黒色を注入する（application.md 参照）。

破棄経路は `vtable.destroy` 経由（component.md「メモリ解放」参照）。
内部の deinit 順序は `component.deinit()` → `allocator.free(text)`。
`component.deinit` が先である理由は `vtable.uninstall` がプロパティを参照する可能性があるため。

## 拡張ポイント
ビルトイン Label の見た目を変えたい場合の選択肢（component.md / lookandfeel.md の方針に従う）。

* **個別差替**: `lbl.component.setVTable(&my_label_vt)` で 1 個だけ paint を差替
* **一斉差替**: `app.replaceVTable(&Label.vtable, &my_label_vt)` で全 Label を差替
* **新型を作る**: `MyLabel = struct { label: Label, ... }` で struct embed して独自 paint
* **setter で個別調整**: setColor / setFont で済む範囲

framework としては Label 自身に theme / L&F 機構を入れない。
