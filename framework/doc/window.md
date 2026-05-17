# window
ウィンドウについての設計ノート。Frame / Dialog の共通親となる抽象トップレベル。

## 立ち位置
nimbus の階層:
```
framework.Window (抽象トップレベル)
  ├─ framework.Frame    (独立トップレベル、タイトルバー / メニュー / 最大化最小化)
  └─ framework.Dialog   (オーナー必須、modal / modeless)   ← v2
```

Swing と同じく Window を抽象基底にし、Frame と Dialog を並列の派生型として持つ。
共通機能 (タイトル、close 処理、resize、root container、repaint dispatch) は Window に集約する。

## awt.Window との関係 (名前衝突注意)
**`awt.Window` と `framework.Window` は同名で別物**。役割は完全に違う。

| | awt.Window | framework.Window |
|---|---|---|
| 役割 | OS native window のラッパー、描画面 (swapchain ターゲット) | UI トップレベルの抽象、root Container を持つ |
| 内部に持つもの | glfw window ハンドルのみ | `awt.Window` + `awt.Swapchain` + Container + dirty フラグ + 描画状態 |
| 寿命 | framework.Window が所有 | Application が所有 |

framework.Window は内部に `awt.Window` を埋め込み、UI レイヤーとして肉付けする。

## 型定義
```zig
pub const Window = struct {
    container:  Container,             // root container (Component embed 経由で paint dispatch)
    awt_window: awt.Window,
    swapchain:  awt.Swapchain,
    context:    *awt.Graphics.Context, // Application から借用 (programs / rings / atlas を束ねたもの)
    dirty_rect: ?Component.Rect,       // null = clean、それ以外 = 再描画必要領域 (絶対 pt)
    title:      []u8,                  // 動的変更可能。allocator.dupe で所有
    window_w:   i32, window_h: i32,    // 論理ポイント
    fb_w:       i32, fb_h: i32,        // framebuffer pixel
    allocator:  std.mem.Allocator,

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
    pub fn redraw(self: *Window) void;        // CB acquire → root.paintAt → present

    // ── lifecycle ────────────────────
    pub fn shouldClose(self: Window) bool;
    pub fn dispose(self: *Window) void;       // close フラグを立てる (run loop が回収)
};
```

## root container
Window は内部に `Container` を 1 つ embed する。`window.add(child)` は内部で `container.add(child)` に委譲。
root container の bounds は常にウィンドウの論理サイズ全体 (`{0, 0, window_w, window_h}`) で、
resize 時に更新される。

paint dispatch は `container.component.paintAt(&g)` 経由。Container.paint が children を再帰描画するので、
Window 固有の paint ロジックは要らない (背景クリア + paintAt のみ)。

## 描画ループ
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

    var g = awt.Graphics.init(cb, self.context, self.window_w, self.window_h, self.fb_w, self.fb_h);
    self.container.component.paintAt(&g);    // root から再帰

    cb.end();
    cb.submit(...);
    self.swapchain.present();

    self.dirty_rect = null;                  // dirty クリア
}
```

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

### Application.windows: ArrayList(*Window)
Application がファクトリ (`app.frame()` 等) を経由して Window を生成する時に append する。
deinit / dispose 時に remove。

```zig
// 概念
pub const Application = struct {
    allocator: std.mem.Allocator,
    windows:   std.ArrayList(*Window),
    context:   awt.Graphics.Context,
    // ...

    pub fn frame(self: *Application, title: []const u8, w: u32, h: u32) !*Frame {
        const f = try self.allocator.create(Frame);
        f.* = try Frame.init(self.allocator, title, w, h, &self.context);
        try self.windows.append(self.allocator, &f.window);
        return f;
    }

    pub fn run(self: *Application) !void {
        while (self.windows.items.len > 0) {
            awt.waitEvents();                 // ブロック (glfwPostEmptyEvent で起きる)
            self.drainTaskQueue();            // invokeLater 用 (v2〜、v1 は no-op)
            for (self.windows.items) |w| {
                if (w.dirty_rect != null) w.redraw();
            }
            self.collectClosedWindows();      // shouldClose な window を deinit + remove
        }
    }
};
```

### awt 側 callback と window の紐付け
GLFW callback は `glfwGetWindowUserPointer` で任意のポインタを受け取れる。
Window.init で `awt.Window.setResizeCallback` / `setRefreshCallback` に自身のポインタを user_data として登録する。
callback の中では `*Window` を取り出して `window.handleResize(...)` / `handleRefresh()` を呼ぶ。

```zig
// awt の callback ハーネス (内部)
fn onAwtResize(_: ?*c.struct_nmWindow, fb_w: c_int, fb_h: c_int, user_data: ?*anyopaque) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(user_data.?));
    self.swapchain.resize(@intCast(fb_w), @intCast(fb_h)) catch {};
    self.fb_w = @intCast(fb_w);
    self.fb_h = @intCast(fb_h);
    const sz = self.awt_window.size();
    self.window_w = sz.width;
    self.window_h = sz.height;
    self.container.component.setBounds(.{ .x = 0, .y = 0, .width = @floatFromInt(self.window_w), .height = @floatFromInt(self.window_h) });
    self.repaint();   // resize 後の自動 dirty
}

fn onAwtRefresh(_: ?*c.struct_nmWindow, user_data: ?*anyopaque) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(user_data.?));
    self.repaint();
}
```

これで「グローバルレジストリなし」で window 個別の event をハンドリングできる。
Application はループの主体 (waitEvents + 全 window の dirty 走査 + close 回収) だけを担当し、
event の dispatch 自体は GLFW + user_data 経由。

## v1 スコープ

| 機能 | v1 でやる? | 備考 |
|---|---|---|
| Window 抽象型 (内部 awt.Window + Container) | やる | 共通親、Frame の embed 対象 |
| add / setTitle / repaint / redraw / dispose | やる | 基本 API |
| resize / refresh callback の hook | やる | self.repaint() を自動で呼ぶ |
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
    f.* = try Frame.init(self.allocator, title, w, h, &self.context);
    try self.windows.append(self.allocator, &f.window);
    return f;
}
```

deinit は子から先、自分が後:
1. `container.deinit()` で children 再帰開放
2. `swapchain.deinit()`
3. `awt_window.deinit()`
4. title バッファ free

破棄順序を間違えると swapchain が「破棄済み window」を参照して落ちるので、 awt_window より swapchain を先に dispose。
