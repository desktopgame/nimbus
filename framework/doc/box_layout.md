# box_layout
水平または垂直に子を並べる `LayoutManager`。
分配アルゴリズムは `{REPO_ROOT}/doc/layout-design.md`「子の分配アルゴリズム」の 1-pass clamp を採用する。
Swing の `BoxLayout` / CSS flexbox の単純化版に相当する。
hint は使わない（常に null）。

## 型定義
```zig
pub const Orientation = enum { horizontal, vertical };

pub const BoxLayout = struct {
    base:        LayoutManager,
    orientation: Orientation,

    pub const vtable = LayoutManager.VTable{
        .doLayout       = doLayout,
        .computeMinSize = computeMinSize,
        .computeMaxSize = computeMaxSize,
    };

    // ... メソッド
};
```

利用者は `BoxLayout` 自体を直接インスタンス化せず、シングルトンを返すヘルパで使う（後述）。

## 水平ボックスレイアウトの取得
```zig
pub fn horizontal() *LayoutManager;
```

水平方向に子を並べるシングルトン `BoxLayout` への `*LayoutManager` を返す。
`Container.setLayout` に渡せる。

## 垂直ボックスレイアウトの取得
```zig
pub fn vertical() *LayoutManager;
```

垂直方向に子を並べるシングルトン `BoxLayout` への `*LayoutManager` を返す。

---

## 主軸と交差軸
ボックスレイアウトでは「主軸（main axis）」と「交差軸（cross axis）」の 2 つの軸を区別する。
方向ごとの対応関係：

| Orientation | 主軸 | 交差軸 |
|---|---|---|
| `.horizontal` | x | y |
| `.vertical` | y | x |

子の bounds は両軸独立に決まる。
主軸は分配アルゴリズム、交差軸はストレッチ。

## 主軸の分配アルゴリズム
1. すべての子の主軸 `min_size` を合計する
2. コンテナーの主軸サイズから合計 min を引く（= 余白）
3. 余白を `grow_x` / `grow_y`（主軸側）の重みに従って一括配分する
4. 配分結果が主軸 `max_size` を超える子はそこでクランプする
5. クランプで生じた余りは隙間としてコンテナー末尾に残す

CSS flexbox の「再分配ループ」は採用しない。
利用者が余白を確実に埋めたい場合は **Filler**（`filler.md` 参照）を末尾に置く。

## 交差軸の処理
各子の交差軸サイズと位置は、子の `align_x` / `align_y`（コンテナの主軸に応じて参照する軸が決まる）で決まる。

| Orientation | 参照する align | 意味 |
|---|---|---|
| `.horizontal` | `align_y` | 子の垂直方向の配置 |
| `.vertical` | `align_x` | 子の水平方向の配置 |

`Alignment` の値ごとの挙動：

| 値 | 交差軸サイズ | 交差軸位置 |
|---|---|---|
| `.stretch`（デフォルト） | コンテナの交差サイズ（min / max でクランプ） | 0（左端 / 上端） |
| `.start` | `min` | 0 |
| `.center` | `min` | `(container_cross - child_min) / 2` |
| `.end` | `min` | `container_cross - child_min` |

子の cross max が無限（典型）なら `.stretch` でコンテナ交差サイズに広がる。
固定値（例: 高さ 32 のボタン）なら `.stretch` でも max でクランプされる。
`.start` / `.center` / `.end` は常に `min` サイズで配置される。

利用者はウィジェットの作成後 `widget.component.setAlignY(.center)` のように指定する。

## computeMinSize の計算
| 軸 | 計算 |
|---|---|
| 主軸 | 子の主軸 `min_size` の総和 |
| 交差軸 | 子の交差軸 `min_size` の最大値 |

子が 0 個なら `(0, 0)`。
これに Container 自身の `component.min_size` との max を取った値が最終的な `Container.getMinSize()` の戻り値になる（`container.md` 参照）。

## computeMaxSize の計算
| 軸 | 計算 |
|---|---|
| 主軸 | 子の主軸 `max_size` の総和（無限が混ざれば結果も無限） |
| 交差軸 | 子の交差軸 `max_size` の最大値 |

無限値の加算は `std.math.inf(f32)` で吸収される（無限 + 何か = 無限）。

## hint は使わない
BoxLayout は `LayoutElement.hint` を無視する。
すべての分配ロジックは Component の `min_size` / `max_size` / `grow_x` / `grow_y` から導出される。
利用者は `container.add(child)` を使えばよく、`addWithHint` は不要。

## シングルトンとして提供する理由
BoxLayout はインスタンス固有の状態を持たない（orientation の 2 種類があるだけ）。
したがって horizontal / vertical の 2 つだけプロセス全体で共有すれば足りる。
利用者が allocator で確保する手間と、いつ deinit するかを考える手間が省ける。

内部実装は `pub var` の static インスタンスを 2 つ用意し、`horizontal()` / `vertical()` がそのアドレスを返す。
LayoutManager の vtable は `deinit = null`（解放不要）。

---

## 利用例
水平ボックスでラベルを並べる。

```zig
const wrapper = try app.container();
wrapper.setLayout(BoxLayout.horizontal());

const a = try app.label("A");
const b = try app.label("B");
const c = try app.label("C");
try wrapper.add(&a.component);
try wrapper.add(&b.component);
try wrapper.add(&c.component);

wrapper.component.setBounds(.{ .x = 0, .y = 0, .width = 600, .height = 32 });
// a, b, c は左から順に min_width 分ずつ配置。grow=0 なので余白は右端に残る
```

垂直ボックスで grow を使って中央のコンテンツを伸ばす。

```zig
const wrapper = try app.container();
wrapper.setLayout(BoxLayout.vertical());

const header = try app.label("Header");
const body   = try app.label("Body");
body.component.setGrowY(1);                    // 余白を body が食う
const footer = try app.label("Footer");

try wrapper.add(&header.component);
try wrapper.add(&body.component);
try wrapper.add(&footer.component);
```

Filler を使った右寄せ。

```zig
const toolbar = try app.container();
toolbar.setLayout(BoxLayout.horizontal());

try toolbar.add(&app.filler().component);      // 左に伸縮スペース
try toolbar.add(&save_button.component);
try toolbar.add(&cancel_button.component);
// → save と cancel が右端に寄る
```

Filler を両端に置いた中央寄せ。

```zig
const center = try app.container();
center.setLayout(BoxLayout.horizontal());

try center.add(&app.filler().component);
try center.add(&content.component);
try center.add(&app.filler().component);
// → content が中央に来る
```

水平ボックスで子を垂直中央に揃える例（背の高い行に短いボタンを置く場合など）。

```zig
const row = try app.container();
row.setLayout(BoxLayout.horizontal());
row.component.setBounds(.{ .x = 0, .y = 0, .width = 600, .height = 80 });

const btn = try app.button("OK");
btn.component.setAlignY(.center);    // 80px 行の中で min 高さで垂直中央
try row.add(&btn.component);
```

ネスト（vertical の中に horizontal）。

```zig
const root = try app.container();
root.setLayout(BoxLayout.vertical());

const toolbar = try app.container();
toolbar.setLayout(BoxLayout.horizontal());
try toolbar.add(&btn_a.component);
try toolbar.add(&btn_b.component);

const status = try app.label("Ready");

try root.add(&toolbar.component);
try root.add(&body.component);
try root.add(&status.component);
```

## 機能要望
* 主軸方向の justify-content 相当（space-between / space-around / center 等を Filler なしで指定）
* 子の間に固定ギャップを入れるオプション（`spacing: f32`）
* min が container を超えた場合の挙動（現状は overflow、将来 clip / scroll の選択肢）
* CSS flexbox 流の再分配ループ（max にぶつかった余りを残りの growable な子に再配分）
