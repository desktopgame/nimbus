# frame
Frame についての設計ノート。
Window を embed した独立トップレベルウィンドウ。
Swing の `JFrame` 相当。

## 型定義
```zig
pub const Frame = struct {
    window: Window,                // embed (共通機能はすべてここ)

    // Frame 固有のフィールドは現状なし。将来 menu_bar / icon / decoration_style 等を追加する場所。

    // ... メソッド
};
```

## フレームの生成
```zig
pub fn init(
    allocator: std.mem.Allocator,
    app: *Application,
    title: []const u8,
    w: u32,
    h: u32,
    context: *awt.Graphics.Context,
) !Frame;
```

`Window` を内部で構築し、Frame として返す。
`app` は Window が back-pointer として保持する（OS callback が Application 側 synced cache を更新する経路に使う、`window.md` 参照）。

利用者が直接呼ぶことは想定していない。
`app.frame(title, w, h)` factory から呼ばれる。

## フレームの破棄
```zig
pub fn deinit(self: *Frame) void;
```

内部の `Window.deinit` を呼ぶ。
将来 Frame 固有のフィールドが増えた場合はそれらの解放もここで行う。

## Window へのアップキャスト
```zig
pub fn asWindow(self: *Frame) *Window;
```

`&self.window` を返すだけの helper。
Application 内部の WindowEntry に格納する時など、`*Window` を期待する API に渡すために使う。

---

## 階層と依存関係
```
framework.Window (抽象トップレベル)
  ├─ framework.Frame    ← これ
  └─ framework.Dialog   (機能要望: 後述)
```

タイトルバー / 最大化最小化 / ウィンドウクローズボタン /（将来）メニューバーを持つ、オーナーを持たない独立したトップレベルウィンドウ。
`framework.Window` を embed し、共通機能はそちらに集約する（`window.md` 参照）。

## 委譲メソッドは生やさない
`add` / `setTitle` / `repaint` 等の委譲メソッドは Frame に生やさない。
Window のメソッドは `frame.window.add(...)` / `frame.window.setTitle(...)` のように親フィールド経由で直接呼ぶ（`component.md`「派生型から Component メソッドへのアクセス」と同じ方針）。

理由は Label / Container と同じで、委譲はボイラープレートになる割に使われない。

* `setTitle` は利用者が毎フレーム呼ぶものではない。出番が少ない
* `add` も大量に呼ぶものではない（典型的には起動時に数個）
* `repaint` は setter 内部で自動的に呼ばれるので、利用者が直接呼ぶ機会は稀

将来「本当に頻出」と判明したものが出てきたら、その時に Frame に委譲を生やす。
デフォルトは **ゼロ**。

## なぜ Window と分けるのか
v1 では Frame ≒ Window と書ける、と思える。
が、Frame と Dialog（機能要望）を並列派生にする設計上、共通部分を Window に置き、Frame 固有部分を Frame に置く分離は必要。

Frame の利用例（`app.frame(...)`）が広く使われる前に統合してしまうと、後で分離する時に利用者 API の変更が発生する。
**最初から分離しておく**のが安全。

将来の Frame 固有機能候補は末尾の `## 機能要望` を参照。

## Window 抽象を直接生成する API は提供しない
`app.window()` のような API は用意しない。
Frame か Dialog のどちらかを必ず選ぶ設計にする。
Swing の `Window` も直接 new する API は提供されていない（`new Window(owner)` という protected ctor のみ）。

## Application との連携
Application のファクトリ `app.frame(title, w, h)` が Frame を生成し、`windows: ArrayList(WindowEntry)` に `*Window`（= `&frame.window`）を含む entry を登録する。
Frame ポインタではなく Window ポインタを WindowEntry に入れるのは、Application のループが Frame と Dialog を区別せず一律で扱えるようにするため。

詳細は `application.md` 参照。

---

## 利用例
Application 経由で Frame を作って widget を追加する典型コード。

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

Frame 直に setter / add を生やしていないので、`frame.window.xxx` 経由で呼ぶ。
`&frame.window` は `*Window` として他の API に渡せる。

## 機能要望
* `menu_bar`: トップに固定のメニューバー（`MenuBar` widget が要る）
* `icon`: タイトルバーアイコン
* `decoration_style`: 通常 / フレームレス / フルスクリーンの切替
* default close operation: 閉じた時に dispose する / hide する / アプリ終了する 等の選択（現状は dispose 固定）
* `maximize` / `minimize` / `restore` API
* `always on top` / `resizable` / `modal exclusion`
* Dialog 系派生型の追加（Frame と並列の Window 派生として）
