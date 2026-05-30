---
unsafe: true
---

# filler
ボックスレイアウト中で余白を吸収するための「空の伸縮要素」。
Swing の `Box.createGlue()`、CSS の `flex: 1 1 0; min-width: 0` 相当。

nimbus は Filler 専用の型を持たない。
**`grow_x` / `grow_y` を 1 に設定した `Panel`** をファクトリで返すだけで実現する。

## ファクトリ
```zig
pub fn filler(self: *Application) !*Panel;
```

`Application.panel()` をラップして、戻り値の `grow_x` / `grow_y` を 1 にセットして返す。
背景色 / 境界線は null（透明）のまま。

`*Panel` を返すので、利用者はそのまま `container.add(&filler.component)` で追加できる。

## 利用例
右寄せのツールバー。

```zig
const toolbar = try app.container();
toolbar.setLayout(BoxLayout.horizontal());

try toolbar.add(&app.filler().component);    // 左側に伸縮スペース
try toolbar.add(&save_btn.component);
try toolbar.add(&cancel_btn.component);
// → save と cancel が右端に寄る
```

中央寄せの content。

```zig
const center = try app.container();
center.setLayout(BoxLayout.horizontal());

try center.add(&app.filler().component);
try center.add(&content.component);
try center.add(&app.filler().component);
// → content が中央に来る
```

垂直ボックスで「中段を伸ばす」（明示的に Filler を使う代わりに body の grow_y を立てる方が普通だが、Filler でも可）。

```zig
const root = try app.container();
root.setLayout(BoxLayout.vertical());

try root.add(&header.component);
try root.add(&app.filler().component);       // 中段を Filler が占有
try root.add(&footer.component);
// → header が上端、footer が下端、間が空く
```

## 機能要望
* `Spacer(w, h)` — 固定サイズの空白用ファクトリ（`Box.createRigidArea` 相当）
* 軸指定の Filler ファクトリ（`app.fillerH()` / `app.fillerV()`）が必要かどうかは経験を見て判断
* 描画フックを持たない極小 Component 型（Panel オーバーヘッドが気になった場合の最適化先）
