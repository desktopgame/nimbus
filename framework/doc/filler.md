# filler
ボックスレイアウト中で余白を吸収するための「空の伸縮要素」。
Swing の `Box.createGlue()`、CSS の `flex: 1 1 0; min-width: 0` 相当。

nimbus は Filler 専用の型を持たない。
**`grow_x` / `grow_y` を 1 に設定した `Panel`** をファクトリで返すだけで実現する。

## なぜ専用型を作らないか
Filler に必要な性質は次の 3 つだけ。

* 描画しない（透明）
* 最小サイズ 0（誰にも邪魔されない）
* 余白があれば食う（`grow` が non-zero）

これらは既に `Panel` が満たせる：

| 性質 | Panel での実現 |
|---|---|
| 描画しない | `background = null`, `border = null`（デフォルト） |
| 最小サイズ 0 | `component.min_size = (0, 0)`（Container のデフォルト） |
| 余白を食う | `component.grow_x = 1; component.grow_y = 1`（setter で設定） |

専用 `Filler` 型を作っても Panel と同じデータ構造になる。
別型にする理由は意味的な区別だけで、それはファクトリの名前（`app.filler()`）で表現すれば足りる。

子を持たない Panel として残るぶんの「children リスト + Container の vtable」のオーバーヘッドはあるが、実用上問題ない。

## ファクトリ
```zig
pub fn filler(self: *Application) !*Panel;
```

`Application.panel()` をラップして、戻り値の `grow_x` / `grow_y` を 1 にセットして返す。
背景色 / 境界線は null（透明）のまま。

`*Panel` を返すので、利用者はそのまま `container.add(&filler.component)` で追加できる。

---

## ボックスレイアウト内での挙動
水平ボックスに Filler を 1 個入れた場合：

* Filler の `grow_x = 1` が「主軸の余白を食う」と解釈される
* 他の子はすべて `grow = 0`（デフォルト）なので、`min` サイズで配置される
* 残った余白はすべて Filler が吸収する

これにより「左寄せの右に余白」「右寄せの左に余白」「中央寄せの両側」などのパターンが Filler を置く位置で表現できる。

垂直ボックスでも同様（`grow_y` 側が効く）。
`app.filler()` は両軸 grow=1 で返すので、ボックスの方向に応じて自動的に主軸方向が選ばれる。

## 既知のパターン
| 配置したいもの | Filler の使い方 |
|---|---|
| 右寄せ | `[Filler, content...]` |
| 左寄せ | `[content..., Filler]`（既定の左寄せ + 末尾に明示の Filler。grow なしのデフォルト挙動と同じ結果） |
| 中央寄せ | `[Filler, content..., Filler]` |
| 両端寄せ（justify-between） | `[a, Filler, b]` |
| 等間隔（justify-around） | `[Filler, a, Filler, b, Filler]` |

これは Swing `Box.createGlue()` のパターンそのもの。

## Filler 自身の bounds
Filler の sizing は他の Panel と同じく LayoutManager 任せ。
BoxLayout が `grow_x = 1` を見て主軸方向に伸ばし、交差軸はコンテナーいっぱい（または max まで）に広がる。

クリック等のイベントは透明な Panel として子へ dispatch されるが、Filler に子はいないので何も起きない。
マウスホバー検出に使いたい場合は通常の Panel を使う方が筋がいい。

## 固定サイズの「余白」が欲しい場合
Swing の `Box.createRigidArea(Dimension)` 相当の「決まった大きさの空白」が欲しい場合は、Filler ではなく次のいずれかで対処する。

* `Panel` を `min_size = max_size = (w, h)` で作る（伸縮しない）
* `grow = 0` の Filler（事実上 Panel と同じ）
* 専用の `Spacer(w, h)` ファクトリ — 機能要望参照

---

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
