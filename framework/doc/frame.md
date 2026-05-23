# frame
Frame についての設計ノート。
Window を embed した独立トップレベルウィンドウ。
Swing の `JFrame` 相当。

## 型定義
```zig
pub const Frame = struct {
    window:    Window,                // embed (共通機能はすべてここ)
    menu_bar:  ?*MenuBar = null,      // 上部固定のメニューバー (なくてもよい)
    owns_menu: bool      = false,     // setMenuBar の引数を所有するか

    // ... メソッド
};
```

## フレームの生成
```zig
pub fn init(
    allocator: std.mem.Allocator,
    app_ptr: *anyopaque,
    event_queue: *awt.EventQueue,
    title: []const u8,
    w: u32,
    h: u32,
    device: *awt.Device,
    context: *awt.Graphics.Context,
) !Frame;
```

`Window` を内部で構築し、Frame として返す。
`app_ptr` は Window が back-pointer として保持する。
`event_queue` / `device` / `context` は Application から借用するハンドル群で、すべての Window で共有される。

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

## メニューバーの設定
```zig
pub fn setMenuBar(self: *Frame, bar: ?*MenuBar) !void;
```

Frame の上部にメニューバーを取り付ける。
`null` を渡すと外す（既存があれば外して `owns_menu` に従って解放する）。
内部的には Window の `menu_bar` field（`window.md`「メニューバー層」参照）に bar をセットする。
Window.container の bounds はメニューバーぶん下にずれる。

引数の `bar` は **Frame に所有権が移る**（`owns_menu = true` になる）。
Frame の deinit 時に bar の `destroy` が呼ばれる。
外部で長く持ち回したい場合は `setMenuBarBorrowed` を使う（後述）。

OOM 等で内部の DirtyNotify 配線が失敗すると error を返す。
返ったあとは bar は **取り付けられていない** 状態で残る（Frame 側のフィールドはセットされない）。

### 事前条件
* `bar` が既に他の Frame にセットされていない（multi-mount は未対応）

## メニューバーの取得
```zig
pub fn getMenuBar(self: Frame) ?*MenuBar;
```

現在セットされているメニューバーへのポインタを返す。
無ければ `null`。

## メニューバーの設定（借用）
```zig
pub fn setMenuBarBorrowed(self: *Frame, bar: ?*MenuBar) !void;
```

`setMenuBar` と同じだが、所有権を移さない（`owns_menu = false`）。
Frame の deinit 時に bar は解放されない。
利用者が外部で寿命を管理する。

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
Application 経由で Frame を作ってウィジェットを追加する典型コード。

```zig
var app = try nimbus.Application.init(init.gpa, init.io);
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

メニューバーを取り付ける例 (Application factory 経由で font / color 注入を省略)。

```zig
const bar = try app.menuBar();

const file = try app.menu("File");
try file.add(&(try app.menuItem("Open")).component);
try file.add(&(try app.menuItem("Save")).component);
try file.addSeparator();
try file.add(&(try app.menuItem("Quit")).component);

try bar.add(file);
try frame.setMenuBar(bar);  // 所有権が Frame に移る
```

## 機能要望
* `icon`: タイトルバーアイコン
* `decoration_style`: 通常 / フレームレス / フルスクリーンの切替
* default close operation: 閉じた時に dispose する / hide する / アプリ終了する 等の選択（現状は dispose 固定）
* `maximize` / `minimize` / `restore` API
* `always on top` / `resizable` / `modal exclusion`
* Dialog 系派生型の追加（Frame と並列の Window 派生として）
