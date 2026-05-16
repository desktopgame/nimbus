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

## コーディング規約

### C
インクルードガードはプラグマを使う。
````h
#pragma once
````

プレフィックスとして `nm` を用いる。
```h
#define NM_SYMBOL
typedef enum nmEnum;
typedef struct nmStruct;
````

関数のプレフィックスもこのルールに従う。
加えて、メソッドとして振舞う関数についてはさらに以下の規則に従う。
* 第一引数の名前は常に `self` とする。
* 常に nm{struct_name}Xxx という形式の名前にする必要は**ない**
```h
void nmInitStruct(nmStruct* self)
```


### Zig
Zigの一般的な規則に従う。このプロジェクト特有の方針はない。

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