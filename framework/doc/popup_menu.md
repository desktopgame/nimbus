---
unsafe: true
---

# popup_menu
任意の位置に表示できる popup 形式のメニュー。
Swing の `JPopupMenu` 相当。
右クリックメニュー（コンテキストメニュー）や、ボタンからのドロップダウン等に使う。

`MenuItem` / `CheckBoxMenuItem` / `MenuSeparator` / `Menu`（サブメニュー）をそのまま add できる。
専用の `PopupMenuItem` のような派生型は**作らない**（`doc/internal/menu-bar-requirements.md` 参照）。

## 型定義
```zig
pub const PopupMenu = struct {
    popup_root: Component,                     // overlay 登録時の root component
    items:      std.ArrayList(*Component),     // MenuItem / CheckBoxMenuItem / MenuSeparator / Menu
    open:       bool,                          // 表示中か
    open_child: ?*Menu,                        // hover で開いているサブメニュー (なければ null)
    window:     ?*Window,                      // 表示先の Window
    allocator:  std.mem.Allocator,
};
```

PopupMenu それ自体は `Component` の派生では**ない** (`component:` フィールドを持たない)。
代わりに内部に `popup_root` という独立した Component を持ち、`show` 時にそれを overlay として Window に登録する。
利用者は普段の `Container.add` ではなく、別の所有経路で持ち回す。

## PopupMenu の生成
```zig
pub fn create(allocator: std.mem.Allocator) !*PopupMenu;
```

allocator で PopupMenu を確保して初期化する。
`items` は空、`open` は false、`popup` は null で開始する。

### 失敗時の保証
途中で失敗した場合、`create` 内で確保したメモリはすべて関数内で解放される。

## PopupMenu の破棄
```zig
pub fn destroy(self: *PopupMenu) void;
```

`open == true` なら先に `hide` してから後片付けする。
保持している全 item を destroy 経由で解放、`popup` Container があれば解放、`items` ArrayList と PopupMenu 本体を free する。

利用者が呼ぶ。Component の vtable.destroy 系では**ない**（PopupMenu は Component 派生ではないため）。

## item の追加
```zig
pub fn add(self: *PopupMenu, item: *Component) !void;
```

末尾に item を追加する。
`item` は `MenuItem` / `CheckBoxMenuItem` / `MenuSeparator` / `Menu` のいずれかの `&xxx.component`。
所有権は PopupMenu に移る。

### 事前条件
* `item` が既に他の Menu / PopupMenu / MenuBar に追加されていない

## separator の追加
```zig
pub fn addSeparator(self: *PopupMenu) !void;
```

`MenuSeparator.create` して `add` する shorthand。

## 表示
```zig
pub fn show(self: *PopupMenu, window: *Window, x: f32, y: f32) !void;
```

`(x, y)` を左上として popup を開く（window ローカル座標）。
内部で `popup_root.position` を `(x, y)` にセットし、`items` を縦並びに配置、Window の overlays 層に登録する。
画面端で見切れる場合は反対側に反転（v1 はクライアント領域内に収まるよう reposition）。

`open = true`、`window = window` を記録する。
表示位置は `popup_root.position` に直接持つので別途 `anchor` フィールドは持たない。

### 事前条件
* 既に `open = true` の場合は no-op（または同じ位置で再表示扱い）

## 非表示
```zig
pub fn hide(self: *PopupMenu) void;
```

popup を Window の overlays 層から外す。
`open = false` にする (`window` は次回 `show` で再利用するためクリアしない)。
`popup_root` は破棄せず再利用のため保持する。

## item を追加した時点で popup を開いている場合
通常、`add` は popup が閉じている時に呼ぶ前提。
`open == true` の状態で `add` を呼んだ時の挙動は **未定義**（debug ビルドでは assert で弾く）。
利用者は「メニュー構成を組む → show → ユーザ操作 → hide → 必要なら構成を変える → show」の流れに従う。

## 利用例
右クリックメニュー（コンテキストメニュー）。

```zig
const font  = awt.Graphics.TextFont{ .face = app.default_font, .pixel_size = 14 };
const black = awt.Graphics.Color.rgb(0.1, 0.1, 0.1);

const ctx_menu = try PopupMenu.create(allocator);
defer ctx_menu.destroy();

try ctx_menu.add(&(try MenuItem.create(allocator, "Cut",        font, black)).component);
try ctx_menu.add(&(try MenuItem.create(allocator, "Copy",       font, black)).component);
try ctx_menu.add(&(try MenuItem.create(allocator, "Paste",      font, black)).component);
try ctx_menu.addSeparator();
try ctx_menu.add(&(try MenuItem.create(allocator, "Select All", font, black)).component);

// あるウィジェットの processEvent 内で右クリックを検知して表示
fn processEvent(self: *Component, ev: *Event) void {
    if (ev.payload == .mouse and ev.payload.mouse.action == .press
        and ev.payload.mouse.button == .right) {
        const w = ... // 親 Window への参照を取得
        ctx_menu.show(w, ev.payload.mouse.x, ev.payload.mouse.y) catch {};
        ev.consume();
    }
}
```

ボタンからのドロップダウン。

```zig
const dropdown = try PopupMenu.create(allocator);
try dropdown.add(&(try MenuItem.create(allocator, "Option A", font, black)).component);
try dropdown.add(&(try MenuItem.create(allocator, "Option B", font, black)).component);

const btn = try app.button("Choose ▾");
try btn.getModel().addActionListener(Ctx, struct {
    fn show(ctx: *Ctx, _: *const ActionEvent) void {
        const origin = ctx.btn.component.absoluteOriginInWindow();
        dropdown.show(ctx.win, origin.x, origin.y + ctx.btn.component.size.height) catch {};
    }
}.show, &my_ctx);
```

サブメニューを含む PopupMenu。

```zig
const ctx_menu = try PopupMenu.create(allocator);

const insert = try Menu.create(allocator, "Insert", font, black);
try insert.add(&(try MenuItem.create(allocator, "Image", font, black)).component);
try insert.add(&(try MenuItem.create(allocator, "Table", font, black)).component);

try ctx_menu.add(&insert.component);  // Menu を submenu として
try ctx_menu.add(&(try MenuItem.create(allocator, "Delete", font, black)).component);
```

## 機能要望
* `showRelativeTo(component, side)`: 指定 component の上 / 下 / 左 / 右に表示する shorthand
* タッチ操作対応（長押し → ctx menu）
* 開いた瞬間のフォーカス移動先指定（最初の項目にハイライト）
* 閉じた時のコールバック（`onClose: fn () void`）
