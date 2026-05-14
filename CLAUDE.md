# nimbus
このプロジェクトは Swing や wxWidgets のようなクロスプラットフォームGUIフレームワークを作るのが目標です。
実装には c, zig を使う予定です。
将来的には python や js 向けのバインディングも提供したいです。

## 目指すゴール
Swing の次の特徴を引き継いだものにしたいと思っています。
* 非即時UI（Retained UI）
* 便利なレイアウトマネージャ（BoxLayout, BorderLayout, GridBagLayout）
* コンポーネントのカスタムペイント（paintComponent）
* コードドリブン、手続き型のレイアウトの実装
* ルックアンドフィールの切り替え

逆に、以下はそのまま取り入れずに改善したいです。
* 複雑なレイアウト設定（minimumSize, preferredSize, maximumSize）

その他、やってみたいこと。
* 手続き型のレイアウトAPIをラップする形で、宣言型なレイアウトAPIも作りたい。

## リポジトリ構成
nimbus は以下3つのモジュールで構成されます。
* framework
* awt
* awt-c

### framework
framework はもっとも抽象的なレイヤーです。
Swing でいうところの JComponent, JContainer, JFrame, JButton... などがここで定義されます。

### awt
awt はウィンドウシステム、描画バックエンド、入力イベントを抽象化するレイヤーです。
MouseEvent, KeyEvent, Window, Graphics... などがここで定義されます。
※ここでのWindowは描画先のスワップチェインとしての機能のみ。レイアウトなどはない。
また、 awt は awt-c に依存する形で実装されます。

### awt-c
awt-c は glfw や freetype の薄いラッパーです。
なぜこれが必要かというと、 zig にあるC言語との連携機能、cImport/cIncludeは複雑なヘッダーをパース出来ないからです。
なので、このレイヤーでは内部的に glfw, freetype などに依存するものの、それらは .c からのみインクルードします。
zig 向けに公開されるヘッダーではそれらを直接露出しない設計になります。

## ビルド
内部で glfw や freetype を必要としますが、パッケージマネージャを使わずにソースコードをリポジトリ以下に展開します。
バージョンの固定が簡単かつ、将来サービスが落ちたり変わったりしても確実にビルド環境を保存できるメリットがあります。

## フォルダ構成
草案です。

nimbus/
├── include/                         # ★ 移動: Nimbus全体の公開C ABI
│   └── nimbus.h
│
├── framework/                       # Zig実装層 (ユーザー向け高水準API)
│   └── src/
│       ├── root.zig
│       ├── Window.zig
│       ├── widget/Button.zig
│       └── c_api.zig                # framework層の export fn
│
├── awt/                             # Zig実装層 (プラットフォーム抽象)
│   └── src/
│       ├── root.zig
│       ├── Window.zig
│       └── c_api.zig                # awt層の export fn
│
├── awt-c/                           # Cシム実装専用
│   └── src/                         #   (include/ がなくなった)
│       ├── internal.h               #   awt-c内部用、外には見せない
│       ├── glfw_shim.c
│       ├── ft_shim.c
│       └── platform/
│           ├── win32.c
│           ├── cocoa.m
│           └── x11.c
│
├── third_party/
│   ├── glfw/
│   └── freetype/
│
├── build.zig
├── build.zig.zon
├── build/
├── examples/
├── tests/
├── docs/
└── scripts/

### include/nimbus.h

```nimbus.h
// include/nimbus.h (公開C ABI、awt-c の内部詳細は出ない)
#ifndef NIMBUS_H
#define NIMBUS_H

#include <stdint.h>
#include <stdbool.h>

// ── 不透明ハンドル ───────────────────────────
typedef struct NimbusWindow    NimbusWindow;
typedef struct NimbusComponent NimbusComponent;
typedef struct NimbusGraphics  NimbusGraphics;
typedef struct NimbusEvent     NimbusEvent;

// ── awt層 (Zig実装、awt/src/c_api.zig で export) ──
NimbusWindow* nimbus_window_create(const char* title, int w, int h);
void nimbus_window_destroy(NimbusWindow*);

// ── framework層 (Zig実装、framework/src/c_api.zig で export) ──
typedef struct NimbusComponentVTable {
    void (*paint)(void* user_data, NimbusComponent* self, NimbusGraphics* g);
    bool (*handle_event)(void* user_data, NimbusComponent* self, const NimbusEvent* e);
    void (*destroy_user_data)(void* user_data);
} NimbusComponentVTable;

void nimbus_component_set_override(
    NimbusComponent*,
    const NimbusComponentVTable*,
    void* user_data);

NimbusComponent* nimbus_button_create(const char* label);

#endif
```

### 各モジュールの定義イメージ

```build.zig.zon
.{
    .name = .nimbus,
    .version = "0.1.0",
    .fingerprint = 0x0,  // zig init が生成した値
    .minimum_zig_version = "0.16.0",
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "build",
        "include",
        "framework",
        "awt",
        "awt-c",
        "third_party",
        "examples",
        "tests",
        "LICENSE",
        "NOTICE",
        "README.md",
    },
    .dependencies = .{},
}
```

```build.zig
const std = @import("std");
const third_party = @import("build/third_party.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_system_glfw = b.option(bool, "system-glfw",
        "Link against system glfw instead of vendored") orelse false;
    const use_system_ft = b.option(bool, "system-freetype",
        "Link against system freetype instead of vendored") orelse false;

    // ── third-party libs (vendored or system) ──────
    const glfw_lib = if (use_system_glfw) null else third_party.buildGlfw(b, target, optimize);
    const ft_lib   = if (use_system_ft)   null else third_party.buildFreetype(b, target, optimize);

    // ── awt-c: Cシム (内部のみ、install しない) ────
    const awt_c_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    awt_c_mod.addIncludePath(b.path("awt-c/src"));
    awt_c_mod.addCSourceFiles(.{
        .root = b.path("awt-c/src"),
        .files = &.{
            "glfw_shim.c",
            "ft_shim.c",
            "event_shim.c",
        },
        .flags = &.{ "-std=c11", "-Wall", "-Wextra" },
    });

    if (glfw_lib) |lib| awt_c_mod.linkLibrary(lib)
    else awt_c_mod.linkSystemLibrary("glfw", .{});

    if (ft_lib) |lib| awt_c_mod.linkLibrary(lib)
    else awt_c_mod.linkSystemLibrary("freetype", .{});

    switch (target.result.os.tag) {
        .windows => {
            awt_c_mod.linkSystemLibrary("user32", .{});
            awt_c_mod.linkSystemLibrary("gdi32", .{});
            awt_c_mod.linkSystemLibrary("shell32", .{});
            awt_c_mod.addCSourceFile(.{
                .file = b.path("awt-c/src/platform/win32.c"),
                .flags = &.{ "-std=c11" },
            });
        },
        .macos => {
            awt_c_mod.linkFramework("Cocoa", .{});
            awt_c_mod.linkFramework("IOKit", .{});
            awt_c_mod.linkFramework("CoreFoundation", .{});
            awt_c_mod.addCSourceFile(.{
                .file = b.path("awt-c/src/platform/cocoa.m"),
                .flags = &.{ "-fobjc-arc" },
            });
        },
        .linux => {
            awt_c_mod.addCSourceFile(.{
                .file = b.path("awt-c/src/platform/x11.c"),
                .flags = &.{ "-std=c11" },
            });
        },
        else => {},
    }

    const awt_c_lib = b.addLibrary(.{
        .name = "nimbus_awt_c",
        .linkage = .static,
        .root_module = awt_c_mod,
    });
    // 注: awt_c_lib は内部使用のみ。installArtifact しない。

    // ── translate-c: awt-c/src/internal.h を Zig から触る ──
    const internal_translate = b.addTranslateC(.{
        .root_source_file = b.path("awt-c/src/internal.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const c_bindings = internal_translate.createModule();

    // ── awt: 内部モジュール (createModule) ────────
    // 外部パッケージからは見えない。framework と libnimbus のみが使う。
    const awt_mod = b.createModule(.{
        .root_source_file = b.path("awt/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "c", .module = c_bindings },
        },
    });
    awt_mod.linkLibrary(awt_c_lib);

    // ── framework: 唯一の公開モジュール、"nimbus" として ──
    const framework_mod = b.addModule("nimbus", .{
        .root_source_file = b.path("framework/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "awt", .module = awt_mod },
        },
    });

    // ── 公開C ABI 共有ライブラリ libnimbus ──────
    const cabi_mod = b.createModule(.{
        .root_source_file = b.path("framework/src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "nimbus", .module = framework_mod },
            .{ .name = "awt", .module = awt_mod },
        },
    });
    const libnimbus = b.addLibrary(.{
        .name = "nimbus",
        .linkage = .dynamic,
        .root_module = cabi_mod,
    });
    b.installArtifact(libnimbus);
    b.installDirectory(.{
        .source_dir = b.path("include"),
        .install_dir = .header,
        .install_subdir = "",
    });

    // ── examples ──────────────────────────────────
    addExample(b, "hello", framework_mod, target, optimize);
    addExample(b, "form",  framework_mod, target, optimize);

    // ── tests ─────────────────────────────────────
    const test_step = b.step("test", "Run all unit tests");
    inline for (.{
        .{ "awt", awt_mod },
        .{ "framework", framework_mod },
    }) |entry| {
        const t = b.addTest(.{ .root_module = entry[1] });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}

fn addExample(
    b: *std.Build,
    comptime name: []const u8,
    nimbus_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/" ++ name ++ "/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nimbus", .module = nimbus_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run-" ++ name, "Run the " ++ name ++ " example");
    run_step.dependOn(&b.addRunArtifact(exe).step);
}
```

```awt/src/root.zig
//! Nimbus AWT layer: platform abstraction.
//!
//! Wraps the C shim (`awt-c`) and exposes Zig-friendly types for
//! windows, surfaces, events, input, and rendering. Holds no widget
//! logic — that belongs to the framework layer above.

const std = @import("std");

// Cシム (awt-c/src/internal.h) を translate-c した結果
pub const c = @import("c");

// 公開モジュール
pub const Window = @import("Window.zig");
pub const Surface = @import("Surface.zig");
pub const Application = @import("Application.zig");
pub const Renderer = @import("Renderer.zig");
pub const Font = @import("Font.zig");

pub const event = @import("event.zig");
pub const input = @import("input.zig");
pub const render = struct {
    pub const Gl = @import("render/gl.zig");
    pub const Software = @import("render/software.zig");
};

pub const geometry = @import("geometry.zig");
pub const Point = geometry.Point;
pub const Rect = geometry.Rect;
pub const Size = geometry.Size;

// グローバル初期化 / 終了
pub fn init(allocator: std.mem.Allocator) !void {
    if (c.nimbus_awt_init() != 0) return error.AwtInitFailed;
    _ = allocator;  // 将来用
}

pub fn deinit() void {
    c.nimbus_awt_terminate();
}

test {
    std.testing.refAllDecls(@This());
}
```

```framework/src/root.zig
//! Nimbus framework: Swing-inspired GUI on top of `awt`.
//!
//! This module is the root of the `nimbus` package — users get its
//! contents when they write `@import("nimbus")`. The `awt` submodule
//! is re-exported for advanced use cases.

const std = @import("std");

/// Low-level platform layer. Most users will not need this directly,
/// but it is available for custom rendering, raw event handling, etc.
pub const awt = @import("awt");

// ── Public API ────────────────────────────────────
pub const Application = @import("Application.zig");
pub const Window = @import("Window.zig");
pub const Container = @import("Container.zig");
pub const Component = @import("Component.zig");

pub const widget = struct {
    pub const Button = @import("widget/Button.zig");
    pub const Label = @import("widget/Label.zig");
    pub const TextField = @import("widget/TextField.zig");
    pub const Panel = @import("widget/Panel.zig");
};

pub const layout = struct {
    pub const Layout = @import("layout/Layout.zig");
    pub const BorderLayout = @import("layout/BorderLayout.zig");
    pub const FlowLayout = @import("layout/FlowLayout.zig");
};

pub const event = struct {
    pub const ActionEvent = @import("event/ActionEvent.zig");
    pub const MouseEvent = @import("event/MouseEvent.zig");
    pub const KeyEvent = @import("event/KeyEvent.zig");
};

// よく使う型は awt から re-export (利用者の利便性)
pub const Point = awt.Point;
pub const Rect = awt.Rect;
pub const Size = awt.Size;
pub const Color = @import("Color.zig");

test {
    std.testing.refAllDecls(@This());
}
```

## その他の決定項目

### アロケーター

Application が allocator を持ち、ウィジェット工場として振る舞う。

```.zig
pub const Application = struct {
    allocator: std.mem.Allocator,
    // ...

    pub fn init(allocator: std.mem.Allocator) !Application { ... }
    pub fn window(self: *Application, opts: Window.InitOptions) !*Window { ... }
    pub fn button(self: *Application, label: []const u8) !*Button { ... }
};
```

### 所有権

Containerが子Componentを所有し、開放の責任を持つ。

```.zig
pub const Container = struct {
    children: std.ArrayList(*Component),

    pub fn add(self: *Container, child: *Component) !void {
        try self.children.append(self.allocator, child);
        child.parent = self.asComponent();
    }

    pub fn deinit(self: *Container) void {
        for (self.children.items) |child| {
            child.deinit();       // 再帰
            self.allocator.destroy(child);
        }
        self.children.deinit(self.allocator);
    }
};
```

### スレッドモデル

単一UIスレッド。別スレッドからUIを操作することはできない。（その場合の動作は保証されない）

### 座標系

int32 ではなく、 float で管理する。

### エラーのC_ABIでの表現

NULLを返し、内部エラーを `GetLastError()` のように取得できるようにする。

```.zig
// framework/src/c_api.zig
const std = @import("std");
const framework = @import("nimbus");

// Zig側のerror unionを返す関数を、C ABI互換のNULL返しに変換
export fn nimbus_button_create(label: [*:0]const u8) ?*framework.widget.Button {
    const label_slice = std.mem.span(label);
    const btn = framework.widget.Button.init(getApp(), label_slice) catch |err| {
        setLastError(err);    // ★ ここでerror値を保存
        return null;          // ★ C ABIにはNULLで失敗を伝える
    };
    return btn;
}

// thread-local last error storage
threadlocal var last_error: ?anyerror = null;
threadlocal var last_error_buf: [256]u8 = undefined;
threadlocal var last_error_msg: []const u8 = "";

fn setLastError(err: anyerror) void {
    last_error = err;
    last_error_msg = std.fmt.bufPrint(&last_error_buf, "{s}", .{@errorName(err)}) catch "";
}

export fn nimbus_last_error_code() c_int {
    return errorToCode(last_error orelse return 0);
}

export fn nimbus_last_error_message() [*:0]const u8 {
    return @ptrCast(last_error_msg.ptr);  // 簡略化
}

fn errorToCode(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory => 1,
        error.WindowCreateFailed => 2,
        // ...
        else => 99,
    };
}
```