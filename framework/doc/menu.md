---
unsafe: true
---

# menu
ラベルを持ち、子 menu item を popup として展開できるコンテナー。
Swing の `JMenu` 相当。
2 つのコンテキストで使われる：

1. `MenuBar` の子としてバー上にラベル表示（クリックで popup 展開）
2. 他の Menu / PopupMenu の子としてサブメニュー行表示（hover で popup 展開、右端に `>` 矢印）

同じ Menu 型でこの両方を担う。
表示形式は親コンテキストが決めるので、Menu 自身は描画ロジックを 2 系統持つ（または親が描画を引き受ける）。

## 型定義
```zig
pub const Mode = enum { bar, item };

pub const Menu = struct {
    component:  Component,                     // バー/行として描画される本体
    popup_root: Component,                     // 開いた popup の root (overlay として Window に登録)
    text:       []const u8,
    icon:       ?awt.Image,
    font:       awt.Graphics.TextFont,
    color:      awt.Graphics.Color,
    items:      std.ArrayList(*Component),    // MenuItem / CheckBoxMenuItem / MenuSeparator / Menu
    model:      *ButtonModel,                  // enabled / armed / rollover (ButtonModel 流用)
    owns_model: bool,
    mode:       Mode,                          // bar (バー上のラベル) / item (行ラベル + サブメニュー矢印)
    open:       bool,                          // popup 表示中か
    open_child: ?*Menu,                        // 開いているサブメニュー (なければ null)
    window:     ?*Window,                      // overlay 登録先 (`setWindow` で配線)
    allocator:  std.mem.Allocator,

    pub const vtable = Component.VTable{
        .install      = install,
        .uninstall    = uninstall,
        .paint        = paint,
        .processEvent = processEvent,
        .destroy      = destroy,
    };
};
```

`popup_root` は通常コンポーネントツリーに含まれず、`show` 時に Window の overlays 層に登録される独立 root。
`mode` は親コンテキスト (MenuBar / 親 Menu) が `setMode` でセットする。

## Menu の生成
```zig
pub fn create(
    allocator: std.mem.Allocator,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*Menu;
```

allocator で Menu を確保、内部 ButtonModel を生成して所有する。
`text` を dup して保持し、`font` / `color` を保持し、`component.min_size` をテキスト寸法 + アイコン slot + padding + サブメニュー矢印分（コンテキストにより）から算出する。
vtable をセットして install まで実行する。

### 失敗時の保証
途中で失敗した場合、`create` 内で確保したメモリはすべて関数内で解放される。

## Menu の破棄
```zig
fn destroy(self: *Component, allocator: std.mem.Allocator) void;
```

`Menu.vtable.destroy` として登録される。
保持している全 child item を destroy 経由で解放、`text` バッファ・`icon`（所有していれば）・`popup` Container（あれば）を解放、`owns_model` が true なら model を deinit + 解放、最後に Menu 本体を free する。

## item の追加
```zig
pub fn add(self: *Menu, item: *Component) !void;
```

末尾に item を追加する。
`item` は `MenuItem` / `CheckBoxMenuItem` / `MenuSeparator` / `Menu`（サブメニュー）の `&xxx.component` を渡す。
所有権は Menu に移る。

### 事前条件
* `item` が既に他の Menu / PopupMenu / MenuBar に追加されていない

## separator の追加
```zig
pub fn addSeparator(self: *Menu) !void;
```

`MenuSeparator.create` して `add` する shorthand。

## テキストの取得 / 設定
```zig
pub fn getText(self: Menu) []const u8;
pub fn setText(self: *Menu, text: []const u8) !void;
```

`setText` は dup し直して `component.min_size` を再計算する。

## アイコンの取得 / 設定
```zig
pub fn getIcon(self: Menu) ?awt.Image;
pub fn setIcon(self: *Menu, icon: ?awt.Image) void;
```

`MenuItem` と同じ規則（borrow、null 可、slot 幅は揃う）。

## Model の取得
```zig
pub fn getModel(self: Menu) *ButtonModel;
```

enabled / disabled を切り替えたいときに使う。
disabled の Menu はクリックしても popup が開かない。

## popup の表示
```zig
pub fn show(self: *Menu, window: *Window, anchor: Component.Point) !void;
```

`anchor` を起点に popup を開く。
`anchor` は Window ローカル座標。
* MenuBar から呼ばれる時は「Menu ラベルの左下」が anchor
* サブメニューとして呼ばれる時は「親 Menu 行の右上」が anchor

内部で popup 用 Container を生成（既存があれば再利用）、`items` を縦並び BoxLayout で配置、Window の overlays 層に登録する。
画面端で popup が見切れる場合は反対側に反転（v1 はクライアント領域内に収まるよう reposition、`doc/menu-bar-requirements.md`「描画と当たり判定」参照）。

`open = true` にする。

### 事前条件
* 既に `open = true` の場合は no-op

## popup を閉じる
```zig
pub fn hide(self: *Menu) void;
```

popup を Window の overlays 層から外す。
`open = false` にする。
popup Container は破棄せず再利用のため保持する（次回 show 時に再表示）。
親が MenuBar の場合、MenuBar 側の `open` も連動して `null` に戻す（callback 経由）。

## ライフサイクル
* MenuBar.add(menu) / Menu.add(submenu_as_component) で menu の所有権が親に移る
* 親の destroy で連鎖的に menu も destroy される
* popup の Container は menu が所有（hide 後も再利用）
* model は内部生成され menu が所有する（Menu は外部 model を受け取らない）

## レイアウト属性
親が MenuBar の時：
* `min_size`: テキスト寸法 + 左右 padding
* `max_size`: 同上（伸ばさない）
* `grow_x` / `grow_y`: 0

親が popup の時：
* `min_size`: icon slot + テキスト寸法 + arrow slot + padding
* `max_size`: width=inf, height=min_size.height
* `grow_x` / `grow_y`: 0（popup 内 BoxLayout で full width に揃う）

## 利用例
基本的な File メニュー。

```zig
const font  = awt.Graphics.TextFont{ .face = app.default_font, .pixel_size = 14 };
const black = awt.Graphics.Color.rgb(0.1, 0.1, 0.1);

const file = try Menu.create(allocator, "File", font, black);
try file.add(&(try MenuItem.create(allocator, "New", font, black)).component);
try file.add(&(try MenuItem.create(allocator, "Open", font, black)).component);
try file.addSeparator();
try file.add(&(try MenuItem.create(allocator, "Quit", font, black)).component);
try menu_bar.add(file);
```

サブメニューの例（Edit → Find → {Find, Find Next, Find Previous}）。font / black は上記と同じ。

```zig
const edit = try Menu.create(allocator, "Edit", font, black);
try edit.add(&(try MenuItem.create(allocator, "Undo", font, black)).component);
try edit.add(&(try MenuItem.create(allocator, "Redo", font, black)).component);
try edit.addSeparator();

const find = try Menu.create(allocator, "Find", font, black);
try find.add(&(try MenuItem.create(allocator, "Find...", font, black)).component);
try find.add(&(try MenuItem.create(allocator, "Find Next", font, black)).component);
try find.add(&(try MenuItem.create(allocator, "Find Previous", font, black)).component);
try edit.add(&find.component);   // submenu

try menu_bar.add(edit);
```

disabled な Menu。

```zig
const debug = try Menu.create(allocator, "Debug", font, black);
debug.getModel().setEnabled(false);
try menu_bar.add(debug);  // クリックしても開かない、グレー表示
```

## 機能要望
* sub-menu hover 展開の遅延（200ms 程度）
* キーボードナビゲーション（矢印キーで item 移動、Enter で発火）
* Menu の最小幅を指定する API（popup の見た目を整える）
