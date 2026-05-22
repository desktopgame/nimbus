# application
Application についての設計ノート。 nimbus アプリのエントリーポイントとなる top-level オブジェクト。

## 責務
* アプリ全体の **アロケータ所有者** (widget / window は全部ここの allocator で確保される)
* **ファクトリ** (`app.frame(...)`, `app.label(...)`, `app.button(...)` 等)
* **イベントループの主体** (`app.run()`)
* **共有リソースの所有者** (Graphics.Context, default font 等)
* **ウィンドウ追跡** (全 Window を `WindowEntry` で持ち、 OS state diff を末尾で push)

## なぜ Application を作るのか (Swing との違い)
Swing には Application 型が無く、 `JFrame` を直接 `new` する。 nimbus はあえて Application を持つ:

* **アロケータの集約**: Zig は GC が無いので allocator がアプリ全体に必要。 ファクトリが allocator を握るのが素直
* **イベントループの隠蔽**: 利用者が `glfwPollEvents` / `glfwWaitEvents` を直接触らなくて済む。 `app.run()` 1 つで起動
* **共有リソースの一元化**: Graphics.Context (programs / rings / atlas) や default font は重く、 アプリ全体で 1 セット使うのが自然
* **ウィンドウ追跡**: 全 Window を 1 箇所で管理する場所が必要 (OS state diff、 close 回収、 全ウィンドウクローズ判定)

参考: 後発の SwingApplicationFramework (JSR 296) は `Application` を導入していた (その後消えたが)。
nimbus は最初から入れる。

## 型定義
```zig
pub const Application = struct {
    allocator:    std.mem.Allocator,
    windows:      std.ArrayList(WindowEntry),
    context:      awt.Graphics.Context,
    default_font: awt.Font,
    task_queue:   ?*awt.EventQueue,        // v1 は null、 v2 で invokeLater 用

    pub fn init(allocator: std.mem.Allocator) !Application;
    pub fn deinit(self: *Application) void;

    // ── ファクトリ (window) ──────────────
    pub fn frame(self: *Application, title: []const u8, w: u32, h: u32) !*Frame;
    // pub fn dialog(self: *Application, owner: *Window, ...) !*Dialog;   // v2

    // ── ファクトリ (widget) ──────────────
    pub fn label(self: *Application, text: []const u8) !*Label;
    pub fn container(self: *Application) !*Container;
    // pub fn button(self: *Application, text: []const u8) !*Button;       // v2
    // pub fn textfield(self: *Application) !*TextField;                   // v2

    // ── イベントループ ────────────────────
    pub fn run(self: *Application) !void;

    // ── invokeLater / invokeAndWait (v2) ─
    // pub fn invokeLater(self: *Application, fn_ptr, user_data) !void;
    // pub fn invokeAndWait(self: *Application, fn_ptr, user_data) !void;

    // ── デフォルトフォント差し替え ─────────
    pub fn setDefaultFont(self: *Application, path: []const u8) !void;
};

const WindowEntry = struct {
    window:       *Window,
    synced_pos:   Point,
    synced_size:  Size,
    synced_title: []const u8,
};
```

## プロセス内で 1 インスタンス
GLFW は `glfwInit` がプロセス単位なので、 Application も実質シングルトン。 ただし型レベルでシングルトン強制
(`getInstance()` パターン) はしない。 単に「2 個作るとうまく動かない」と doc で握る。

理由: テスト時に複数 Application を入れ替えて使うケース (mock や差し替え) が将来出るかもしれないので、
強制よりは規約に留めておく。

## ファクトリの責務
ファクトリは「allocator 確保 + init + install + tracking 登録」を 1 まとめにする (component.md 「ライフサイクル」)。
利用者は戻り値のポインタを使って setter / add 等を呼ぶだけで、 メモリの面倒は見ない。

例:
```zig
pub fn label(self: *Application, text: []const u8) !*Label {
    return try Label.create(
        self.allocator,
        text,
        .{ .face = self.default_font, .pixel_size = 14 },
        awt.Graphics.Color.rgb(0, 0, 0),
    );
}

pub fn frame(self: *Application, title: []const u8, w: u32, h: u32) !*Frame {
    const f = try self.allocator.create(Frame);
    errdefer self.allocator.destroy(f);
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

Window 系のファクトリは追加で `windows` リストへの append が要る。 Widget 系のファクトリは widget の
`create` をラップするだけ (default font / color を注入する)。

## イベントループ

```zig
pub fn run(self: *Application) !void {
    while (self.windows.items.len > 0) {
        awt.waitEvents();                 // ブロック (event か glfwPostEmptyEvent で起きる)
        self.drainTaskQueue();            // v1 は no-op、 v2 で invokeLater 配信
        for (self.windows.items) |e| {
            if (e.window.dirty_rect != null) e.window.redraw();
        }
        self.syncOsState();               // pos/size/title の diff を OS に push
        self.collectClosedWindows();      // shouldClose な window を deinit + remove
    }
}
```

各ステップの責務は window.md 「イベントループとの関係」 を参照。

### syncOsState の実装
```zig
fn syncOsState(self: *Application) void {
    for (self.windows.items) |*e| {
        if (!e.window.container.component.position.eql(e.synced_pos)) {
            e.window.awt_window.setPos(e.window.container.component.position);
            e.synced_pos = e.window.container.component.position;
        }
        if (!e.window.container.component.size.eql(e.synced_size)) {
            e.window.awt_window.setSize(e.window.container.component.size);
            e.synced_size = e.window.container.component.size;
        }
        if (!std.mem.eql(u8, e.window.title, e.synced_title)) {
            e.window.awt_window.setTitle(e.window.title);
            e.synced_title = e.window.title;
        }
    }
}
```

OS callback が `component.position/size` と `synced_xxx` を **両方** 更新するので、
利用者が setter で書き換えた場合だけ diff が発生し、 OS に push される (window.md 参照)。

### 終了条件
全ウィンドウが閉じたらループ抜け (`while self.windows.items.len > 0`)。 「最後のウィンドウを閉じたら exit」
セマンティクス。 これを変えたい (ウィンドウ全閉じでも常駐したい) 利用者向けには将来 hook を生やす。

## invokeLater / invokeAndWait (v2)
別スレッドから UI を触る唯一の正規の手段。 CLAUDE.md の「EventQueue / invokeLater」 セクションを参照。
v1 では task_queue を持つだけで実装しない。

```zig
// v2 で実装予定 (API スケッチ)
pub fn invokeLater(self: *Application, fn_ptr: *const fn(*anyopaque) void, user_data: *anyopaque) !void;
pub fn invokeAndWait(self: *Application, fn_ptr: *const fn(*anyopaque) void, user_data: *anyopaque) !void;
```

`invokeAndWait` は別スレッドから呼ぶ前提 (UI スレッド自身から呼ぶとデッドロック)。 assert で弾く。

## SecondaryLoop (v2)
modal dialog 用の入れ子イベントループ。 「Application.run() の中から、 dialog 表示中だけ
小さな run() を回し、 dialog が閉じたら戻る」 という Swing の SecondaryLoop / Qt の QEventLoop 相当。

v1 では Dialog が無いので不要。 Dialog 着手時に再検討する。

## 共有リソース

### Graphics.Context
programs (Color / Image / RoundedRect / Text) と ring buffer (vertex_ring / uniforms / quad_index) と
glyph_atlas を束ねたもの。 Application が所有し、 全 Window が借用する。

なぜ Application 所有か:
* programs は shader compile を含むので 1 回作って共有が自然
* ring buffer / atlas はメモリが大きく、 Window 毎に持つと無駄
* 全 Window が同じ font atlas を共有すると glyph cache 効率が良い

### default_font
Noto Sans (Latin + CJK JP) を `@embedFile` で焼き込んだものを Application init で読み込む。
Label / Button 等の widget ファクトリが借用する。 寿命は Application と同じ。

`setDefaultFont(path)` で差し替え可能 (上級利用者向け、 CLAUDE.md 「フォント」 参照)。
差し替え後に作成した widget は新フォント、 既存 widget は変更前のフォントを保持 (font は値型で widget 内に複製される)。

## ライフサイクル

### init
```zig
pub fn init(allocator: std.mem.Allocator) !Application {
    try awt.init();                           // GLFW init 等
    errdefer awt.deinit();

    var device = try awt.Device.init();
    errdefer device.deinit();

    // programs / rings / atlas を構築 (省略)
    // ...

    const font = try awt.Font.init(builtin_noto_sans_jp, 0);
    errdefer font.deinit();

    return .{
        .allocator    = allocator,
        .windows      = .empty,
        .context      = ctx,
        .default_font = font,
        .task_queue   = null,
    };
}
```

### deinit (順序が重要)
```zig
pub fn deinit(self: *Application) void {
    // 1. 残ってる Window を全部 deinit (子 widget も再帰で解放される)
    for (self.windows.items) |e| {
        e.window.deinit();
        self.allocator.destroy(e.window);     // 実体は *Frame 等の外側 (今は Window pointer で持ってる点に注意)
    }
    self.windows.deinit(self.allocator);

    // 2. 共有リソース
    self.default_font.deinit();
    self.context.deinit();

    // 3. awt 終了
    awt.deinit();
}
```

注: WindowEntry には `*Window` を保持しているが、 実体は `*Frame` 等の外側型。 解放には
`vtable.destroy` を使う必要がある (component.md 「メモリ解放」 参照)。 上の deinit はラフな擬似コードで、
実装時には `window.container.component.vtable.destroy(...)` 経由になる。

破棄順序を間違えると、 残った Window が context を参照して落ちるので Window → context → awt の順。

## 機能要望
* `invokeLater` / `invokeAndWait` — 別スレッドから UI を触る正規ルート (CLAUDE.md「非同期処理」参照)。`task_queue` フィールドは予約済み、ドレインは現状 no-op。
* SecondaryLoop — modal dialog 用の入れ子イベントループ (Swing の SecondaryLoop / Qt の QEventLoop 相当)。Dialog 追加と同時に検討。
* `button()` / `textfield()` 等の widget factory — widget 追加に合わせて生やす。
* 「最後のウィンドウを閉じても常駐したい」 ケース向けの hook (現状は全ウィンドウ閉でループ終了)。

## 利用者から見た典型コード

```zig
var app = try nimbus.Application.init(std.heap.page_allocator);
defer app.deinit();

const frame = try app.frame("hello nimbus", 800, 600);
const label = try app.label("こんにちは!");
label.component.setBounds(.{ .x = 30, .y = 30, .width = 400, .height = 40 });
try frame.window.add(&label.component);

try app.run();   // event loop。 全ウィンドウ閉じで抜ける
```

## 関連 doc

* window.md — Window / WindowEntry の詳細、 イベントループとの関係
* frame.md — Frame factory の例
* component.md — ファクトリのライフサイクル / メモリ解放
* binding.md — Application 経由のファクトリが他言語バインディングでどう見えるか
