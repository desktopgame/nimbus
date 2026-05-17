# framework overview

nimbus の最上位レイヤー。Swing でいう `JComponent` / `JContainer` / `JFrame` / `JLabel` ... に相当するユーザー向け API を提供する。`awt` 層（`Graphics` / `Window` / `Device` ...）の上に乗り、`awt-c` の存在は隠す。

CLAUDE.md「リポジトリ構成」「所有権」「スレッドモデル」「イベントループ / 複数ウィンドウ」を前提とした **v1 草案**。コードはまだ書いていない。

## 立ち位置

- レイヤー: framework（最上位）
- 依存: `awt`（特に `Graphics`, `Window`, `Swapchain`, `Device`, `programs` etc.）
- ユーザーは framework だけ触る、awt-c の存在は知らない

CLAUDE.md レイヤー分担規約より:

> awt-c: DX12/Metal 用語に追従。GUI primitive のみ
> awt (Zig): cross-API 抽象 + Programs / Renderer / Graphics
> framework: Application / Container / Component / widget。Graphics 経由で描画、awt-c の存在は知らない

## クラス階層

Zig には継承がないので **vtable + struct embedding** で表現する（CLAUDE.md「所有権」セクションの Container 例と整合）。

```
Component (base: vtable + bounds + parent)
  ├─ Container (Component embed + children: ArrayList(*Component))
  │    ├─ Frame (Container embed + Window + Swapchain + Graphics.Context)
  │    └─ （将来: Panel など）
  └─ Label / (v2: Button / TextField / ...)
```

`Container` は `Component` を **embed する**（継承ではない）。`Container` の中の `Component` ポインタを `&container.component` で取り出し、`children.append(&child.component)` のように扱う。

## 所有権モデル

- `Application` が `std.mem.Allocator` を持つ
- ファクトリメソッド（`app.frame(...)` / `app.label(...)`）が widget を `allocator.create(T)` で確保し、`*T` を返す
- `Container.add(child: *Component)` で親に登録、`child.parent = self.asComponent()`
- `Application.deinit()` で全 Frame を再帰的に `deinit()` → `allocator.destroy()`
- ユーザーは個別の widget の `deinit` を呼ばない（`app.deinit()` で一括）

寿命の階段: **Application > Frame > Container > Component**

```zig
pub const Container = struct {
    component: Component,
    children:  std.ArrayList(*Component),
    allocator: std.mem.Allocator,

    pub fn add(self: *Container, child: *Component) !void { ... }
    pub fn deinit(self: *Container) void {
        for (self.children.items) |child| {
            child.deinit();                   // vtable.dtor
            self.allocator.destroy(child);    // メモリ解放はここで一律
        }
        self.children.deinit(self.allocator);
    }
};
```

Container は **Component の特別扱いではなく単なる派生 widget**。vtable.paint の中で children をループするのが「Container らしさ」の正体で、framework が Container 概念を hard-code しているわけではない。ユーザーが「子を持つ widget」を作りたいなら同じパターンで自前で書ける。

## Component

ミニマル設計。L&F 機構は持たず、vtable 4 つだけのフック点でユーザーに自由を与える（詳細は [lookandfeel.md](./lookandfeel.md)）。

```zig
pub const Component = struct {
    pub const VTable = struct {
        ctor:         *const fn (self: *Component) void,                   // 初期化 hook (v1 未使用、枠だけ予約)
        dtor:         *const fn (self: *Component) void,                   // 破棄
        paint:        *const fn (self: *Component, g: *awt.Graphics) void, // 描画
        processEvent: *const fn (self: *Component, ev: *const Event) bool, // イベント (v2〜本格化)
    };

    vtable:   *const VTable,
    position: Point,        // 親 Container 内のローカル座標 (論理pt)
    size:     Size,         // 論理pt
    parent:   ?*Component,  // root Frame の component は null

    pub fn getBounds(self: Component) Rect;
    pub fn setBounds(self: *Component, r: Rect) void;
    pub fn repaint(self: *Component) void;
    pub fn repaintRect(self: *Component, r: Rect) void;
    pub fn deinit(self: *Component) void { self.vtable.dtor(self); }
};
```

**Swing と違って `paintComponent` と `ComponentUI.paint` の二重構造はない**。vtable.paint がただ一つの描画フック。ビルトイン widget もユーザー定義 widget も同じ vtable.paint を使う。

### paint の流れ

`vtable.paint(self, g)` は呼ばれた時に「自分の描画」を行う。Container の場合は paint の中で **自分で** 子の再帰描画も行う:

```zig
// Container の vtable.paint 実装 (ビルトイン)
fn paint(self: *Component, g: *awt.Graphics) void {
    const container: *Container = @fieldParentPtr("component", self);
    // 自分の背景描画 (もしあれば) ...
    for (container.children.items) |child| {
        var child_g = g.clip(child.getBounds());
        child.vtable.paint(child, &child_g);
    }
}
```

leaf widget (Label / Button) の vtable.paint は自分だけ描く（子のループはない）。

paint の中で「自分の clip 内 (0, 0) ~ (size.width, size.height)」のローカル座標で描けばよい。clip 経由で渡された `Graphics` が origin 加算と scissor を持つ。

### vtable フィールドの責務

| フィールド | v1 | v2〜 | 役割 |
|---|---|---|---|
| `ctor` | 枠だけ (no-op default) | hook 化 | widget 初期化後の post-init (将来) |
| `dtor` | 実装 | 同 | 破棄時のクリーンアップ。Container は子を再帰開放 |
| `paint` | 実装 | 同 | 描画。 Container は子も自分で paint |
| `processEvent` | 枠だけ (no-op default) | 実装 | mouse / key / focus event を処理。Container は子に dispatch |

v1 では `paint` と `dtor` だけが実体を持ち、`ctor` と `processEvent` は noop デフォルト。Event 型定義 (v2 で event 機構を入れる時) まで vtable の形だけ予約しておく。

### repaint と invalidate の用語整理

**nimbus は Swing と同じ用語分けを採用する**:

| Swing 用語 | 意味 | v1 nimbus |
|---|---|---|
| `repaint()` / `repaint(Rect)` | 再描画 dirty (全体 / 部分) | **採用** |
| `invalidate()` / `revalidate()` / `validate()` | レイアウト再計算 dirty | **採用しない**（LayoutManager 未実装のため概念ごと無し） |

Win32 / Cocoa / Qt / Android 等は `invalidate` を「再描画リクエスト」の意味で使うが、nimbus は Swing 由来なので Swing 用語に倣う。

### repaint の API

```zig
/// 自分の bounds 全体を dirty にする (Swing の repaint() 相当)
pub fn repaint(self: *Component) void;

/// 自分のローカル座標系内の `r` を dirty にする (Swing の repaint(Rect) 相当)
pub fn repaintRect(self: *Component, r: Rect) void;
```

呼ばれると親方向を遡って Frame の dirty 領域に union する。Frame は `dirty_rect: ?Rect` を 1 個持ち、複数の `repaint(r)` 呼び出しを集約する（外接矩形を取る、最適 fit ではない）。

```zig
pub const Frame = struct {
    // ...
    dirty_rect: ?Rect,  // null = clean、それ以外 = 再描画必要領域 (絶対座標、論理pt)
};
```

### v1 における dirty rect の扱い

ここが Swing と現代 GPU 描画の差。**v1 では dirty rect API を公開するが、内部実装は当面「scissor の hint」としてしか機能しない**。

理由: 今の swapchain 構成（DX12 `FLIP_DISCARD`、Metal `CAMetalLayer` のデフォルト）は **前 frame の back buffer 内容を保持しない**。dirty rect 外を「前のまま残す」のは出来ず、毎フレーム背景含めて全部描き直す必要がある。

ただし dirty rect が分かっていれば次の最適化はできる:
- root Graphics に `g.clip(dirty_rect)` を入れて scissor を絞る → clip 外の draw call は GPU 側でラスタライズされない
- 上位レイヤーで `if (!component.bounds.intersects(dirty_rect)) skip;` 判定して **glyph rasterize / vertex 構築自体を skip** → CPU コスト削減

v1 では最低限「scissor 絞り」だけ実装。`bounds 交差 skip` 最適化は計測してから入れる。

### 真の部分更新は v2 課題

dirty rect 外を本当に「前 frame のまま残す」には:
- swapchain を `FLIP_SEQUENTIAL` 等に変えて前 back buffer を保持
- もしくは off-screen color target に retained 描画して frame ごとに dirty 部分だけ blit
- Mac: `CAMetalLayer.framebufferOnly = NO` + 適切な storage mode

どれも awt 層の swapchain 設計変更が必要。v1 のスコープから外す。

### Component.repaint の実装

```zig
pub fn repaint(self: *Component) void {
    self.repaintRect(.{ .x = 0, .y = 0, .width = self.bounds.width, .height = self.bounds.height });
}

pub fn repaintRect(self: *Component, r: Rect) void {
    // ローカル r を絶対座標に変換しながら親を辿って Frame まで上がる
    var x = r.x;
    var y = r.y;
    var n: ?*Component = self;
    while (n) |c| {
        x += c.bounds.x;
        y += c.bounds.y;
        n = c.parent;
        // 最後 (parent == null) が root component。Frame がそれを保持している前提
    }
    // Frame に到達したら frame.dirty_rect = union(frame.dirty_rect, abs_r)
}
```

呼び出しのコスト感: parent 鎖を辿るだけで pointer chase。typical UI 深さで 5〜10 hop なので無視できる。

将来 LayoutManager が入った段階で `Component.invalidate()` / `Container.validate()` を別途追加する。`repaint` と `invalidate` は別系統のフラグになる。

## Container

`Component` を embed + children を持つ。

```zig
pub const Container = struct {
    component: Component,
    children: std.ArrayList(*Component),
    allocator: std.mem.Allocator,

    pub fn add(self: *Container, child: *Component) !void;
    pub fn remove(self: *Container, child: *Component) void; // 解放はしない、付け替え用
    pub fn deinit(self: *Container) void;                    // 再帰解放
    pub fn asComponent(self: *Container) *Component { return &self.component; }
};
```

Container の vtable.paint はデフォルトで「背景塗りなし + children を再帰描画」。子描画ロジックは Container vtable に書かれていて、Component base には無い (= framework が container を hard-code しない、上記方針の通り)。

ユーザーが直接 `Container` を生成することは少ない。実用上は `Frame` の中の content として暗黙に存在し、`frame.add(label)` で frame の content に追加されるイメージ。

## Frame

`Container` を embed + `awt.Window` + `awt.Swapchain` + 描画コンテキストを持つ。Swing の `JFrame` 相当。

```zig
pub const Frame = struct {
    container: Container,
    window:    awt.Window,
    swapchain: awt.Swapchain,
    // 描画は Application が共有する Graphics.Context を借用
    context:   *awt.Graphics.Context,
    dirty:     bool,
    // logical size + framebuffer size (HiDPI)
    window_w: i32, window_h: i32,
    fb_w: i32,    fb_h: i32,

    pub fn add(self: *Frame, child: *Component) !void;     // container.add 委譲
    pub fn setTitle(self: *Frame, title: [:0]const u8) void;
    pub fn repaint(self: *Frame) void { self.dirty = true; }
};
```

- ユーザーは `app.frame(title, w, h)` で生成、`frame.add(label)` で widget 追加
- 内部で `window.setResizeCallback` / `window.setRefreshCallback` をフックして自動 repaint
- resize 時は swapchain.resize + logical/fb サイズ更新 + dirty フラグ
- root container の bounds は `(0, 0, window_w, window_h)`

## Application

```zig
pub const Application = struct {
    allocator: std.mem.Allocator,
    device:    awt.Device,
    // 全 Frame で共有する描画コンテキスト群（programs / ring buffers / atlas）
    context:   awt.Graphics.Context,
    // 上記の実体（context が指す先）
    color_program, image_program, rrect_program, text_program: ...,
    vertex_ring, uniforms, quad_index, atlas, default_font: ...,
    windows: std.ArrayList(*Frame),

    pub fn init(allocator: std.mem.Allocator) !*Application;
    pub fn deinit(self: *Application) void;

    // ── factory ────────────────────────────────────────────────
    pub fn frame(self: *Application, title: [:0]const u8, w: u32, h: u32) !*Frame;
    pub fn label(self: *Application, text: []const u8) !*Label;

    // ── event loop ─────────────────────────────────────────────
    pub fn run(self: *Application) !void;
};
```

### init / deinit

- `init`: `awt.init` → device 作成 → programs / ring buffers / atlas を確保
- default font も埋め込み Noto Sans CJK を一個ロード（CLAUDE.md「フォント」決定通り）
- `deinit`: windows を逆順に閉じる → programs / rings / atlas を deinit → device.deinit → awt.deinit

### factory メソッド

CLAUDE.md「アロケーター」セクション通り、`allocator` を持つ Application が「ウィジェット工場」。各 factory は:
1. `try self.allocator.create(T)`
2. T を `init(...)` 状態にセット（vtable をバインド、bounds 初期値、内部 state）
3. `*T` を返す（ユーザーが利用、最終的に親 Container に add される）

### run loop（v1 草案）

```
while (self.windows.items.len > 0) {
    awt.waitEvents();          // ブロック。glfwPostEmptyEvent で起きる
    for (windows) |frame| {
        if (frame.dirty) {
            frame.repaint();   // CB acquire → reset → root.paint → submit → present
            frame.dirty = false;
        }
    }
    // shouldClose な Frame を windows から外して deinit
}
```

v1 では「dirty フラグ駆動」までやる。`glfwPostEmptyEvent` 相当の awt API（追加が必要なら awt-c に生やす）で UI スレッドを起こせるようにする。`invokeLater` / `invokeAndWait` は v2。

## Label（v1 唯一の widget）

```zig
pub const Label = struct {
    component: Component,
    text:      []const u8,
    font:      awt.Graphics.TextFont,
    color:     awt.Graphics.Color,

    pub const vtable = Component.VTable{
        .ctor = noop, .dtor = dtor, .processEvent = noop_event,
        .paint = paint,
    };

    pub fn setText(self: *Label, text: []const u8) void;  // 内部で repaint
    pub fn setFont(self: *Label, font: awt.Graphics.TextFont) void;
    pub fn setColor(self: *Label, color: awt.Graphics.Color) void;
    pub fn preferredSize(self: Label) Size;               // font.measureString

    fn paint(self: *Component, g: *awt.Graphics) void {
        const label: *Label = @fieldParentPtr("component", self);
        g.setFont(label.font);
        g.setColor(label.color);
        g.drawString(label.text, 0, 0);  // top-of-bbox at component origin
    }
};
```

- text は `[]const u8` を **借用** (CLAUDE.md「アロケーター」では allocator は Application 寿命と書かれているが、ここでは label.text のバイト列は呼び出し側持ち)。動的に書き換えたいときは setText で diff
- font は値型なので Label が値で持つ。`*awt.Font` (face) の寿命は Application.default_font
- 改行は drawString 側で無視（graphics.md 通り）

これが「ビルトイン nimbus L&F の Label」。ユーザーが見た目を変えたければ自前 widget で paint を書き直せばよい。framework が L&F 機構を持たない方針なので、Label は単に「固定見た目の defaults を持つ widget」というだけ。

## レイアウト

**v1 は manual `setBounds` のみ**。`LayoutManager` は v2 以降の課題。

CLAUDE.md「目指すゴール」に挙げられている BoxLayout / BorderLayout / GridBagLayout は順次追加。v1 は骨格の検証に集中する。

## イベント処理

**v1 では未対応**。mouse / key / focus traversal は v2。CLAUDE.md「EventQueue / invokeLater」もまとめて v2 タスク。`Component.vtable` に `mousePressed` 等を生やすのは構造を作るときに考える。

## v1 のスコープ

| 機能 | v1 でやる? | 備考 |
|---|---|---|
| Component / Container vtable | やる | embed + 再帰 paint + repaint |
| Frame | やる | resize/refresh hook で auto repaint |
| Application + run loop | やる | waitEvents + dirty 駆動、 invokeLater は無し |
| Label | やる | text/font/color、setter で repaint |
| Button | やらない | mouse event 機構待ち（v2） |
| Layout manager | やらない | manual setBounds のみ |
| 入力イベント (mouse / key) | やらない | EventQueue 整備後（v2） |
| invokeLater / invokeAndWait | やらない | 単一 UI スレッド前提でいい |
| 複数 Frame | やる（基盤だけ） | factory で複数生成可、Application が tracking |
| LookAndFeel 機構 | やらない | framework に組み込まない方針。詳細 [lookandfeel.md](./lookandfeel.md) |

## v2 以降に想定

- イベント処理（MouseEvent / KeyEvent / focus）、vtable.processEvent を本格使用
- Button / TextField / Panel / ScrollPane（ビルトイン widget の拡充）
- BoxLayout（最初の LayoutManager）と invalidate / validate 機構
- EventQueue + invokeLater + invokeAndWait

LookAndFeel は **framework に組み込まない方針** ([lookandfeel.md](./lookandfeel.md))。ユーザーが vtable.paint override と setter / 自前 Theme struct で実現できる構造になっているため、framework としての切替機構は不要。ビルトイン widget の見た目だけは light / dark 等の variant を v2 で検討する余地あり。

## 想定する hello のコード（v1 完成後イメージ）

```zig
const std = @import("std");
const nimbus = @import("nimbus");

pub fn main() !void {
    var app = try nimbus.Application.init(std.heap.page_allocator);
    defer app.deinit();

    var frame = try app.frame("hello nimbus", 800, 600);
    try frame.setTitle("hello nimbus");

    var label = try app.label("こんにちは、世界！");
    label.setColor(.{ .r = 1, .g = 0, .b = 0, .a = 1 });
    label.component.bounds = .{ .x = 30, .y = 30, .width = 400, .height = 40 };
    try frame.add(&label.component);

    try app.run();
}
```

awt 層の直叩きは出てこない（`Graphics` / `Window` / `Device` 等は Application の内部に隠れる）。これで CLAUDE.md レイヤー分担規約が成立する。
