# frame
Frame についての設計ノート。Window を embed した独立トップレベルウィンドウ。

## 立ち位置
```
framework.Window (抽象トップレベル)
  ├─ framework.Frame    ← これ
  └─ framework.Dialog   (v2 以降)
```

Swing の `JFrame` 相当。タイトルバー / 最大化最小化 / ウィンドウクローズボタン / (将来) メニューバー を持つ、
オーナーを持たない独立したトップレベルウィンドウ。

## 型定義
```zig
pub const Frame = struct {
    window: Window,                // embed (共通機能はすべてここ)

    // v1 では Frame 固有のフィールドは無し。将来 menu_bar / icon / decoration_style 等を追加する場所。

    pub fn init(allocator: std.mem.Allocator, title: []const u8, w: u32, h: u32,
                context: *awt.Graphics.Context) !Frame;
    pub fn deinit(self: *Frame) void;
    pub fn asWindow(self: *Frame) *Window { return &self.window; }

    // 利便性のための add / setTitle / repaint 委譲 (window 経由でも書けるが Frame 直で使いたい)
    pub fn add(self: *Frame, child: *Component) !void;
    pub fn setTitle(self: *Frame, title: []const u8) !void;
    pub fn getTitle(self: Frame) []const u8;
    pub fn repaint(self: *Frame) void;
};
```

v1 では Frame は **ほぼ Window のラッパー**。固有機能の置き場として用意しておく形。

## なぜ Window と分けるのか
v1 では Frame = Window と書ける、と思える。が、Frame と Dialog (v2) を並列派生にする設計上、
共通部分を Window に置き、 Frame 固有部分を Frame に置く分離は必要。

「v1 では Frame に固有機能が無いが、v2 以降で増える」を見越して **最初から分離しておく**。
Frame の利用例 (`app.frame(...)`) が広く使われる前に統合してしまうと、後で分離する時に
ユーザー API の変更が発生する。

## 将来追加する固有機能 (v2 以降)
- **menu_bar**: トップに固定のメニューバー (`MenuBar` widget が要る)
- **icon**: タイトルバーアイコン
- **decoration_style**: 通常 / フレームレス / フルスクリーン
- **default close operation**: 閉じた時 dispose する? hide する? アプリ終了する?
- **maximize / minimize / restore API**
- **always on top**, **resizable**, **modal exclusion**

これらが入った時に Frame 固有のフィールドが増えていく。Dialog は Frame ではなく Window を embed するので、
これらの機能を共有しない (Dialog はメニューバーを持たない etc.)。

## ライフサイクル
factory コード例 (Application 内部):
```zig
pub fn frame(self: *Application, title: []const u8, w: u32, h: u32) !*Frame {
    const f = try self.allocator.create(Frame);
    f.* = try Frame.init(self.allocator, title, w, h, &self.context);
    try self.windows.append(self.allocator, &f.window);
    return f;
}
```

Application が `windows: ArrayList(*Window)` に **Window ポインタを** 登録する点に注意。
Frame ポインタではなく Window ポインタを登録するのは、 Application.run のループが
Frame と Dialog を区別せず一律で扱えるようにするため。

```
Application
  ├─ windows: ArrayList(*Window)   ← Frame も Dialog も同じ Window として並ぶ
  ├─ allocator
  ├─ context (programs / rings / atlas)
  └─ ...
```

deinit はラッパーなので window のものを呼ぶ:
```zig
pub fn deinit(self: *Frame) void {
    self.window.deinit();
    // v2 で固有フィールドが増えたらここで free
}
```

## v1 スコープ

| 機能 | v1 でやる? | 備考 |
|---|---|---|
| Window embed | やる | 共通機能を全部委譲 |
| factory `app.frame(title, w, h)` | やる | Application が tracking |
| add / setTitle / repaint の委譲 | やる | window 経由でも書けるが利便性のため |
| menu_bar | やらない | v2 以降 (MenuBar widget も同時) |
| icon | やらない | v2 以降 |
| default close operation | やらない | v1 は dispose 固定 (close ボタン = window 破棄) |
| maximize / minimize / fullscreen | やらない | v2 以降 |

## ユーザーから見た典型コード
```zig
var app = try nimbus.Application.init(std.heap.page_allocator);
defer app.deinit();

var frame = try app.frame("hello nimbus", 800, 600);
try frame.setTitle("hello again");

var label = try app.label("こんにちは!");
label.component.setBounds(.{ .x = 30, .y = 30, .width = 400, .height = 40 });
try frame.add(&label.component);

try app.run();   // event loop。close で抜ける
```

`Window` 抽象を直接生成する API は提供しない (`app.window()` は無い)。
Frame か Dialog のどちらかを必ず選ぶ設計にする。Swing の `Window` も直接 new する API は提供されていない
(`new Window(owner)` という protected 系 ctor のみ)。
