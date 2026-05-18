# window
ウィンドウについての設計ノート。Frame / Dialog の共通親となる抽象トップレベル。

## 立ち位置
nimbus の階層:
```
framework.Window (抽象トップレベル、Container 派生 = 推移的に Component 派生)
  ├─ framework.Frame    (独立トップレベル、タイトルバー / メニュー / 最大化最小化)
  └─ framework.Dialog   (オーナー必須、modal / modeless)   ← v2
```

Swing と同じく Window を抽象基底にし、Frame と Dialog を並列の派生型として持つ。
共通機能 (タイトル、close 処理、resize、root container、repaint dispatch) は Window に集約する。

## Container 派生として扱う
Window は `Container` を embed する。Container は `Component` を embed しているので、
推移的に「Window は Component」「Window は Container」として扱える (Swing の `Window extends Container extends Component` と同じ階層)。

これにより:
- `window.container.add(child)` で root level に子を足せる
- `window.container.component` (= Component) として汎用 walker / paint dispatch に流せる
- Layout manager (v2) も他の Container と同じ機構で挿せる

## awt.Window との関係 (名前衝突注意)
**`awt.Window` と `framework.Window` は同名で別物**。役割は完全に違う。

| | awt.Window | framework.Window |
|---|---|---|
| 役割 | OS native window のラッパー、描画面 (swapchain ターゲット) | UI トップレベルの抽象、Container 派生 |
| 内部に持つもの | glfw window ハンドルのみ | `awt.Window` + `awt.Swapchain` + Container embed + dirty フラグ |
| 寿命 | framework.Window が所有 | Application が所有 |

framework.Window は内部に `awt.Window` を埋め込み、UI レイヤーとして肉付けする。

## 型定義
```zig
pub const Window = struct {
    container:  Container,             // Container embed = Container 派生 = 推移的に Component 派生
    awt_window: awt.Window,
    swapchain:  awt.Swapchain,
    context:    *awt.Graphics.Context, // Application から借用 (programs / rings / atlas を束ねたもの)
    app:        *Application,          // back-pointer。OS callback が Application 側の synced cache を更新するため
    dirty_rect: ?Component.Rect,       // null = clean、それ以外 = 再描画必要領域 (絶対 pt)
    title:      []u8,                  // 動的変更可能。allocator.dupe で所有
    fb_w:       i32, fb_h: i32,        // framebuffer pixel (HiDPI 用)
    allocator:  std.mem.Allocator,

    pub const vtable = Component.VTable{
        .install      = install,
        .uninstall    = uninstall,
        .paint        = paintWindow,   // Container.paint と挙動が違う (後述「paint dispatch」)
        .processEvent = processEvent,
        .destroy      = destroy,
    };

    // ── 子の管理 (container 委譲) ─────
    pub fn add(self: *Window, child: *Component) !void;
    pub fn addWithHint(self: *Window, child: *Component, hint: *anyopaque,
                       hint_destroy: ?*const fn(*anyopaque, std.mem.Allocator) void) !void;

    // ── プロパティ ────────────────────
    pub fn setTitle(self: *Window, title: []const u8) !void;
    pub fn getTitle(self: Window) []const u8;

    // ── 描画 ──────────────────────────
    pub fn repaint(self: *Window) void;
    pub fn repaintRect(self: *Window, r: Component.Rect) void;
    pub fn redraw(self: *Window) void;        // CB acquire → paintWindow → present

    // ── lifecycle ────────────────────
    pub fn shouldClose(self: Window) bool;
    pub fn dispose(self: *Window) void;       // close フラグを立てる (run loop が回収)
};
```

## position / size のセマンティクス
**Window では `component.position` / `component.size` は OS 絶対座標で扱う** (Swing の `Window.getBounds` が screen 座標を返すのと同じ特例)。

通常 Component の position は parent-relative だが、Window は parent を持たない root なので「parent-relative」と「OS 絶対」は実用上区別不能。なら OS 座標として使うのが素直で、ツリー走査で「子の絶対 screen 座標」を計算する時に親方向に積み上げれば自然に screen pt に到達できる。

### OS との同期 (Application が責務を負う)
Window 自身は OS と「同期済みの値」を覚えない。Application が `WindowEntry` で per-window に保持し、毎イベントループ末尾で diff → 差分があれば OS に push する。

```zig
const WindowEntry = struct {
    window: *Window,
    synced_pos:   Point,
    synced_size:  Size,
    synced_title: []const u8,
};
```

フロー:

| イベント | 動作 |
|---|---|
| ユーザーが `window.component.setBounds(...)` | `component.position/size` を書き換えるだけ。OS には未反映 |
| OS callback (ドラッグ / リサイズ等) | `component.position/size` と `app.windows[i].synced_xxx` を**両方**更新 |
| イベントループ末尾 (Application.run) | 全 entry で `component.position != synced_pos` なら `awt_window.setPos(...)` → `synced_pos` 更新。size / title も同様 |

OS callback が両方更新するのがポイント。これがないと「OS が動かした → 末尾の diff で push し返す」の無限ピンポンになる。

これにより:
- `Component.setBounds` の override 不要 (通常規約のまま)
- 同一フレーム内で setBounds を複数回呼んでも自動 coalesce (最後の値だけ push)
- Window struct は sync 用フィールドで汚れない

## paint dispatch
Window の paint は他の Container と挙動が違うため、**専用 vtable.paint (`paintWindow`)** を持つ。

通常 Component.paintAt は親から渡された `g` に対して `g.translate(position)` してから `vtable.paint(self, g)` を呼ぶ。Window では `position` が OS 絶対座標なので、これをそのまま translate に使うと描画が壊れる。

対処: Window は paintAt 経由で描画しない。Application.run が `window.redraw()` を直接呼び、そこで:

```zig
pub fn redraw(self: *Window) void {
    const cb = awt.CommandBuffer.acquire(...) catch return;
    defer cb.release();
    self.context.uniforms.reset();
    self.context.vertex_ring.reset();

    cb.begin();
    cb.bindRenderTarget(self.swapchain.getTarget());
    cb.clearColor(...);
    cb.clearStencil(0);

    // root として g を生成。position は無視 (OS 絶対座標なので translate に使えない)
    const sz = self.awt_window.size();
    var g = awt.Graphics.init(cb, self.context, sz.width, sz.height, self.fb_w, self.fb_h);

    // children を直接走査 (paintWindow vtable は children だけ paint)
    self.container.component.vtable.paint(&self.container.component, &g);

    cb.end();
    cb.submit(...);
    self.swapchain.present();

    self.dirty_rect = null;
}
```

`paintWindow` vtable の中身は「children を再帰描画」だけ (= 実質 Container.paint と同じ)。Container.paint をそのまま流用しても良い。`paint` を別名にしておくのは「Window は paintAt 経由で呼ばれない」という意図表明と、将来 Window 固有の描画 (背景色 / 装飾) を入れる時の hook を残しておくため。

## repaint と dirty 駆動
`Component.repaint()` / `repaintRect(r)` が呼ばれると、parent を遡って Window まで上がり、
`window.dirty_rect` に union で蓄積される。これは framework.Component で実装する責務。

```zig
// Component.repaint 内 (擬似)
pub fn repaint(self: *Component) void {
    var n: ?*Component = self;
    var x: f32 = 0; var y: f32 = 0;
    while (n) |c| {
        // ... 親方向に bounds 累積
        n = c.parent;
    }
    // Window に到達したら window.dirty_rect = union(window.dirty_rect, abs_rect)
}
```

`dirty_rect` の扱いは graphics 層に伝える scissor のヒントとして使う。v1 では full redraw に倒すが、
API としては rect 単位で受けられるようにしておく (framework/doc/component.md 「repaint」参照)。

## close 処理
GLFW が close リクエストを受け取ると `awt_window.shouldClose()` が `true` になる。
Window 自体は何もしない (close ボタンを押した瞬間に dispose しない)。Application.run のループが:
1. `shouldClose()` をチェック
2. true なら window を `windows` リストから外して `dispose` → `deinit`

これにより Window 側で「閉じる前に保存しますか?」のような確認ダイアログを差し挟む余地が生まれる
(v2 以降で WindowListener 相当を追加した時に活きる)。

## イベントループとの関係

### グローバル singleton は **不要**
GLFW のイベントキューはプロセス単位なので「全ウィンドウのループ」は 1 本でよく、
そのループを **Application が単一管理する**。Application が windows を tracking している限り、
window 側はグローバル状態を持たない (Singleton レジストリ / `var all_windows = ...` は使わない)。

### Application.windows: ArrayList(WindowEntry)
Application がファクトリ (`app.frame()` 等) を経由して Window を生成する時に append する。
deinit / dispose 時に remove。

```zig
// 概念
pub const Application = struct {
    allocator: std.mem.Allocator,
    windows:   std.ArrayList(WindowEntry),
    context:   awt.Graphics.Context,
    // ...

    pub fn frame(self: *Application, title: []const u8, w: u32, h: u32) !*Frame {
        const f = try self.allocator.create(Frame);
        f.* = try Frame.init(self.allocator, self, title, w, h, &self.context);
        try self.windows.append(self.allocator, .{
            .window       = &f.window,
            .synced_pos   = f.window.component.position,
            .synced_size  = f.window.component.size,
            .synced_title = f.window.title,
        });
        return f;
    }

    pub fn run(self: *Application) !void {
        while (self.windows.items.len > 0) {
            awt.waitEvents();                 // ブロック (glfwPostEmptyEvent で起きる)
            self.drainTaskQueue();            // invokeLater 用 (v2〜、v1 は no-op)
            for (self.windows.items) |e| {
                if (e.window.dirty_rect != null) e.window.redraw();
            }
            self.syncOsState();               // pos/size/title の diff を OS に push
            self.collectClosedWindows();      // shouldClose な window を deinit + remove
        }
    }

    fn syncOsState(self: *Application) void {
        for (self.windows.items) |*e| {
            if (!e.window.component.position.eql(e.synced_pos)) {
                e.window.awt_window.setPos(e.window.component.position);
                e.synced_pos = e.window.component.position;
            }
            if (!e.window.component.size.eql(e.synced_size)) {
                e.window.awt_window.setSize(e.window.component.size);
                e.synced_size = e.window.component.size;
            }
            if (!std.mem.eql(u8, e.window.title, e.synced_title)) {
                e.window.awt_window.setTitle(e.window.title);
                e.synced_title = e.window.title;
            }
        }
    }
};
```

### awt 側 callback と window の紐付け
GLFW callback は `glfwGetWindowUserPointer` で任意のポインタを受け取れる。
Window.init で `awt.Window.setResizeCallback` / `setRefreshCallback` に自身のポインタを user_data として登録する。
callback の中では `*Window` を取り出して、`component.position/size` と Application 側の `WindowEntry.synced_xxx` を**両方**更新する (片方だけだと末尾 diff で OS に押し返してしまう)。

```zig
// awt の callback ハーネス (内部)
fn onAwtResize(_: ?*c.struct_nmWindow, fb_w: c_int, fb_h: c_int, user_data: ?*anyopaque) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(user_data.?));
    self.swapchain.resize(@intCast(fb_w), @intCast(fb_h)) catch {};
    self.fb_w = @intCast(fb_w);
    self.fb_h = @intCast(fb_h);

    const sz = self.awt_window.size();
    self.component.size = .{ .width = @floatFromInt(sz.width), .height = @floatFromInt(sz.height) };
    self.app.markSynced(self, .size);    // Application 側 synced_size も同期

    self.repaint();
}

fn onAwtMove(_: ?*c.struct_nmWindow, x: c_int, y: c_int, user_data: ?*anyopaque) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(user_data.?));
    self.component.position = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
    self.app.markSynced(self, .position);
}

fn onAwtRefresh(_: ?*c.struct_nmWindow, user_data: ?*anyopaque) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(user_data.?));
    self.repaint();
}
```

これで「グローバルレジストリなし」で window 個別の event をハンドリングできる。
Application はループの主体 (waitEvents + 全 window の dirty 走査 + OS sync + close 回収) だけを担当し、
event の dispatch 自体は GLFW + user_data 経由。

## v1 スコープ

| 機能 | v1 でやる? | 備考 |
|---|---|---|
| Window 抽象型 (Container 派生 + awt.Window 内蔵) | やる | 共通親、Frame の embed 対象 |
| add / setTitle / repaint / redraw / dispose | やる | 基本 API |
| resize / refresh / move callback の hook | やる | self.repaint() / synced 更新を自動で行う |
| Application 末尾の OS state diff push | やる | pos / size / title |
| dirty_rect 蓄積 | やる | API は rect 単位、実装は full redraw に倒す (v1) |
| shouldClose 検出 → run loop で回収 | やる | Application 側 |
| Dialog | やらない | v2 |
| WindowListener (close 確認等) | やらない | v2 |
| 複数モニタ対応 | やらない | v2 以降 |
| アニメーション駆動 (requestAnimationFrame 相当) | やらない | v2 以降 |

## ライフサイクル
factory コード例 (Application 側):
```zig
pub fn frame(self: *Application, title: []const u8, w: u32, h: u32) !*Frame {
    const f = try self.allocator.create(Frame);
    f.* = try Frame.init(self.allocator, self, title, w, h, &self.context);
    try self.windows.append(self.allocator, .{
        .window       = &f.window,
        .synced_pos   = f.window.component.position,
        .synced_size  = f.window.component.size,
        .synced_title = f.window.title,
    });
    return f;
}
```

deinit は子から先、自分が後:
1. `container.deinit()` で children 再帰開放 (Container embed なので)
2. `swapchain.deinit()`
3. `awt_window.deinit()`
4. title バッファ free

破棄順序を間違えると swapchain が「破棄済み window」を参照して落ちるので、 awt_window より swapchain を先に dispose。
