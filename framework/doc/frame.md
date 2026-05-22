# frame
Frame についての設計ノート。Window を embed した独立トップレベルウィンドウ。

## 階層と依存関係
```
framework.Window (抽象トップレベル)
  ├─ framework.Frame    ← これ
  └─ framework.Dialog   (機能要望: 後述)
```

Swing の `JFrame` 相当。タイトルバー / 最大化最小化 / ウィンドウクローズボタン / (将来) メニューバー を持つ、
オーナーを持たない独立したトップレベルウィンドウ。

`framework.Window` を embed し、共通機能はそちらに集約する (window.md 参照)。

## 型定義
```zig
pub const Frame = struct {
    window: Window,                // embed (共通機能はすべてここ)

    // v1 では Frame 固有のフィールドは無し。将来 menu_bar / icon / decoration_style 等を追加する場所。

    pub fn init(allocator: std.mem.Allocator, app: *Application,
                title: []const u8, w: u32, h: u32,
                context: *awt.Graphics.Context) !Frame;
    pub fn deinit(self: *Frame) void;
    pub fn asWindow(self: *Frame) *Window { return &self.window; }
};
```

v1 では Frame は **ほぼ Window のラッパー**。固有機能の置き場として用意しておく形。

## 委譲メソッドは生やさない
`add` / `setTitle` / `repaint` 等の委譲メソッドは Frame に生やさない。Window のメソッドは
`frame.window.add(...)` / `frame.window.setTitle(...)` のように親フィールド経由で直接呼ぶ
(component.md 「派生型から Component メソッドへのアクセス」と同じ方針)。

理由は Label / Container と同じで、 委譲はボイラープレートになる割に使われない:
* `setTitle` は利用者が毎フレーム呼ぶものではない。 出番が少ない
* `add` も大量に呼ぶものではない (典型的には起動時に数個)
* `repaint` は setter 内部で自動的に呼ばれるので、 利用者が直接呼ぶ機会は稀

将来「本当に頻出」と判明したものが出てきたら、 その時に Frame に委譲を生やす。 デフォルトは **ゼロ**。

## なぜ Window と分けるのか
v1 では Frame = Window と書ける、と思える。が、Frame と Dialog (v2) を並列派生にする設計上、
共通部分を Window に置き、 Frame 固有部分を Frame に置く分離は必要。

「v1 では Frame に固有機能が無いが、v2 以降で増える」を見越して **最初から分離しておく**。
Frame の利用例 (`app.frame(...)`) が広く使われる前に統合してしまうと、後で分離する時に
利用者 API の変更が発生する。

これらの固有機能が入った時に Frame のフィールドが増えていく。Dialog は Frame ではなく Window を embed するので、これらの機能を共有しない (Dialog はメニューバーを持たない等)。具体的な機能候補は末尾の `## 機能要望` を参照。

## ライフサイクル
factory コード例 (Application 内部):
```zig
pub fn frame(self: *Application, title: []const u8, w: u32, h: u32) !*Frame {
    const f = try self.allocator.create(Frame);
    f.* = try Frame.init(self.allocator, self, title, w, h, &self.context);
    try self.windows.append(self.allocator, .{
        .window       = &f.window,
        .synced_pos   = f.window.container.component.position,
        .synced_size  = f.window.container.component.size,
        .synced_title = f.window.title,
    });
    return f;
}
```

`Frame.init` に `self: *Application` を渡しているのは、 Window が `app` back-pointer を持つため
(OS callback が Application 側の synced cache を更新する経路、 詳細は window.md)。

Application が `windows: ArrayList(WindowEntry)` に **Window ポインタを含む entry を** 登録する点に注意。
Frame ポインタではなく Window ポインタを WindowEntry に入れるのは、 Application.run のループが
Frame と Dialog を区別せず一律で扱えるようにするため。

```
Application
  ├─ windows: ArrayList(WindowEntry)   ← Frame も Dialog も同じ Window として並ぶ
  │     WindowEntry = { window: *Window, synced_pos, synced_size, synced_title }
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

## 機能要望
* `menu_bar`: トップに固定のメニューバー (`MenuBar` widget が要る)。
* `icon`: タイトルバーアイコン。
* `decoration_style`: 通常 / フレームレス / フルスクリーンの切替。
* default close operation: 閉じた時に dispose する / hide する / アプリ終了する 等の選択 (現状は dispose 固定)。
* `maximize` / `minimize` / `restore` API。
* `always on top` / `resizable` / `modal exclusion`。
* Dialog 系派生型の追加 (Frame と並列の Window 派生として)。

## 利用者から見た典型コード
```zig
var app = try nimbus.Application.init(std.heap.page_allocator);
defer app.deinit();

var frame = try app.frame("hello nimbus", 800, 600);
try frame.window.setTitle("hello again");

var label = try app.label("こんにちは!");
label.component.setBounds(.{ .x = 30, .y = 30, .width = 400, .height = 40 });
try frame.window.add(&label.component);

try app.run();   // event loop。close で抜ける
```

Frame 直に setter / add を生やしていないので、 `frame.window.xxx` を経由する。 `&frame.window`
は `*Window` として他の API に渡せる。

`Window` 抽象を直接生成する API は提供しない (`app.window()` は無い)。
Frame か Dialog のどちらかを必ず選ぶ設計にする。Swing の `Window` も直接 new する API は提供されていない
(`new Window(owner)` という protected 系 ctor のみ)。
