# menu_bar
Frame の上部に固定で配置するメニューバー。
水平に `Menu` を並べ、ラベルクリックで対応する Menu を popup として展開する。
Swing の `JMenuBar` 相当。

通常コンポーネントツリーとは別レイヤ（Window の `menu_bar` 専用 field）に置かれる。
`Container.add` 経由ではなく、`Frame.setMenuBar(MenuBar)` で取り付ける（`frame.md` 参照）。

## 型定義
```zig
pub const MenuBar = struct {
    component: Component,
    menus:     std.ArrayList(*Menu),
    open:      ?*Menu,                  // 現在 popup を展開中の Menu (なければ null)
    allocator: std.mem.Allocator,

    pub const vtable = Component.VTable{
        .install      = install,
        .uninstall    = uninstall,
        .paint        = paint,
        .processEvent = processEvent,
        .destroy      = destroy,
    };
};
```

## メニューバーの生成
```zig
pub fn create(
    allocator: std.mem.Allocator,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*MenuBar;
```

allocator で MenuBar を確保して初期化する。
`menus` は空、`open_menu` は null で開始する。
`font` / `color` は配下の Menu ラベル描画用 (`add` した Menu は MenuBar の font / color を参照する想定)。
vtable をセットして install まで実行する。

### 失敗時の保証
途中で失敗した場合、`create` 内で確保したメモリはすべて関数内で解放される。

## メニューバーの破棄
```zig
fn destroy(self: *Component, allocator: std.mem.Allocator) void;
```

`MenuBar.vtable.destroy` として登録される。
保持している全 `Menu` を `destroy` で解放したのち、`menus` ArrayList と MenuBar 本体を free する。
Frame.setMenuBar(null) や Frame.deinit から呼ばれる。

## Menu の追加
```zig
pub fn add(self: *MenuBar, menu: *Menu) !void;
```

末尾に `menu` を追加する。
所有権は MenuBar に移る（destroy 時に menu も解放）。

### 事前条件
* `menu` が既に他の MenuBar / Menu に追加されていない

## Menu の削除
```zig
pub fn remove(self: *MenuBar, menu: *Menu) void;
```

指定 menu を取り除く。
所有権を放棄するだけで Menu 自体は解放しない（利用者責任）。
そもそも remove はあまり使わない想定（メニュー構成は起動時に組んで以降固定）。

## 子 Menu 数の取得
```zig
pub fn count(self: MenuBar) usize;
```

## index 指定で Menu を取得
```zig
pub fn at(self: MenuBar, index: usize) ?*Menu;
```

範囲外なら null。

---

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

## レイアウト属性
* `min_size.height`: 標準 24〜28px（フォント高 + padding）
* `min_size.width`: 全 Menu ラベル幅の合計
* `max_size`: width=inf, height=min_size.height（縦には伸ばさない）
* `grow_x` / `grow_y`: 共に 0

実際の bounds は Window 側が「`(0, 0, window_width, min_size.height)`」で setBounds する。

## popup の発火
クリックを検知したら `menu.show(window, anchor)` を呼ぶ。
`anchor` はクリックされた Menu ラベルの **左下** ウィンドウ座標。
popup は Window の overlays 層に登録される（実装詳細は `menu.md`「popup の表示」と `window.md`「overlays 層」参照）。

`open` フィールドはどの Menu が popup を持っているかを覚えるためのもの。
popup が dismiss されたら `open = null` に戻る（popup 側から callback で通知）。

---

## 利用例
3 つの Menu を持つメニューバー。

```zig
const font  = awt.Graphics.TextFont{ .face = app.default_font, .pixel_size = 14 };
const black = awt.Graphics.Color.rgb(0.1, 0.1, 0.1);

const bar = try MenuBar.create(allocator, font, black);

const file = try Menu.create(allocator, "File", font, black);
try file.add(&(try MenuItem.create(allocator, "New",  font, black)).component);
try file.add(&(try MenuItem.create(allocator, "Open", font, black)).component);
try file.addSeparator();
try file.add(&(try MenuItem.create(allocator, "Quit", font, black)).component);
try bar.add(file);

const edit = try Menu.create(allocator, "Edit", font, black);
try edit.add(&(try MenuItem.create(allocator, "Undo", font, black)).component);
try edit.add(&(try MenuItem.create(allocator, "Redo", font, black)).component);
try bar.add(edit);

const help = try Menu.create(allocator, "Help", font, black);
try help.add(&(try MenuItem.create(allocator, "About", font, black)).component);
try bar.add(help);

try frame.setMenuBar(bar);
```

## 機能要望
* 右寄せメニュー（Help を右端に置く等。Swing でいう glue）
* ニーモニック表示（`Alt+F` で File メニューを開く、`Alt` 押下中はラベルに下線を引く）
* メニューバーの非表示 / 自動隠し（F11 で hide のような UX）
* 縦置きメニューバー（モバイル UI 風、優先度低）
