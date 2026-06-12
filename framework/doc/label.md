---
unsafe: false
---

# label
ラベルについての設計ノート。
テキストを 1 行描画する leaf ウィジェット。オプションでテキストの左にアイコンを表示できる (Swing `JLabel` 相当)。
v1 で唯一のビルトイン leaf ウィジェットとして、Component / Container / vtable 周りの動作検証も兼ねる。

## 型定義
```zig
pub const Label = struct {
    component: Component,
    text:      []const u8,           // Label が所有 (allocator で dup)
    font:      awt.Graphics.TextFont,
    color:     awt.Graphics.Color,
    icon:      ?awt.Image,           // 借用 (例: Application のアイコンキャッシュ)。null = 無し
    icon_size: ?Component.Size,      // null = 画像の自然サイズ、非 null = 拡縮して描画

    pub const vtable = Component.VTable{
        .install      = install,
        .uninstall    = uninstall,
        .paint        = paint,
        .processEvent = processEvent,
        .destroy      = destroy,
    };

    // ... メソッド
};
```

## ラベルの生成
```zig
pub fn create(
    allocator: std.mem.Allocator,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*Label;
```

allocator で `Label` を確保し、`text` を dup して所有し、vtable をセット、install まで実行して返す。
`component.min_size` は `font.measureString(text)` から算出してセットされる。

### 事前条件
* `font.face` の寿命が Label と同じか長いこと（通常は Application の `default_font` を借用）

### 失敗時の保証
途中で失敗した場合、`create` 内で確保したメモリはすべて関数内で解放される。
呼び出し側に後片付け責任は発生しない（awt-c の `nmCreateXxx` と同じセマンティクス）。

## ラベルの破棄
```zig
fn destroy(self: *Component, allocator: std.mem.Allocator) void;
```

`Label.vtable.destroy` として登録される。
`@fieldParentPtr` で外側の `*Label` に戻し、内部状態を解放して `allocator.destroy(label)` まで行う。

利用者が直接呼ぶ機会は通常無い。
Container に add された Label は、Container.deinit が `elem.component.vtable.destroy(...)` を通じてこの経路を起動する。
スタンドアロンで使うなら `label.component.vtable.destroy(&label.component, allocator)` を呼ぶ。

## テキストの取得
```zig
pub fn getText(self: Label) []const u8;
```

Label が保持している text の slice を返す。
ポインタは Label が deinit されるまで有効。

## テキストの更新
```zig
pub fn setText(self: *Label, text: []const u8) !void;
```

引数の `text` を dup し直して古いものを free する。
`component.min_size` を新しい text の寸法で再計算する。
レイアウト変化と再描画は `setMinSize` が自動で dirty を立てるので、別途 repaint 不要。

## フォントの取得
```zig
pub fn getFont(self: Label) awt.Graphics.TextFont;
```

## フォントの設定
```zig
pub fn setFont(self: *Label, font: awt.Graphics.TextFont) void;
```

`font` を保持し、現在の text を新しい font で測りなおして `component.min_size` を再計算する。

## 色の取得
```zig
pub fn getColor(self: Label) awt.Graphics.Color;
```

## 色の設定
```zig
pub fn setColor(self: *Label, color: awt.Graphics.Color) void;
```

`color` を保持して再描画を要求する。
レイアウトには影響しない（dirty は paint のみ）。

## アイコンの取得
```zig
pub fn getIcon(self: Label) ?awt.Image;
```

## アイコンの設定
```zig
pub fn setIcon(self: *Label, icon: ?awt.Image) void;
```

テキストの左に表示するアイコンを設定する（null でクリア）。
`component.min_size` をアイコン + 間隔 + テキストで再計算する。

アイコンが無いときの描画は従来どおり左上起点（既存レイアウト / スナップショットに影響しない）。
アイコンがあるときはアイコン・テキストとも割り当てボックス内で**垂直センタリング**して描画する
（行の中に置かれる用途で上揃えは破綻して見えるため）。

### 事前条件
* `icon` は借用。Label より長生きさせること（`Application.icon()` が返すビルトインアイコンは
  Application 寿命なのでこの条件を満たす）。

## アイコンサイズの取得 / 設定
```zig
pub fn getIconSize(self: Label) ?Component.Size;
pub fn setIconSize(self: *Label, size: ?Component.Size) void;
```

null なら画像の自然サイズで、非 null ならそのサイズに拡縮して描画する（`Button` の `icon_size` と同じ意味論）。

## 利用例
Application 経由の典型コード。

```zig
var app = try nimbus.Application.init(allocator);
defer app.deinit();

const frame = try app.frame("hello", 800, 600);

const label = try app.label("こんにちは!");
label.setColor(awt.Graphics.Color.rgb(1, 0, 0));      // 赤に変更
try frame.window.add(&label.component);

// 後からテキスト更新
try label.setText("更新後");

try app.run();
```

直接 `Label.create` を使うパターン（Application 経由でない場合、例えばテストやスタンドアロン描画）。

```zig
const label = try Label.create(
    allocator,
    "framework Label",
    .{ .face = font, .pixel_size = 24 },
    awt.Graphics.Color.rgb(1, 1, 0),
);
defer label.component.vtable.destroy(&label.component, allocator);

label.component.setBounds(.{ .x = 30, .y = 30, .width = 400, .height = 32 });
// あとは container に add するか、直接 paintAt(&g) で描画
```

Component メソッド（`setBounds` 等）は委譲を生やしていないので、`label.component.setBounds(...)` の形で親フィールド経由で呼ぶ（component.md「派生型から Component メソッドへのアクセス」参照）。

## 機能要望
* 改行 (`\n`) 対応 — 現状 `drawString` が無視するため対応なし。複数行は別ウィジェットで扱う
* horizontal / vertical alignment — SwingConstants 相当を導入
* HTML / rich text — 当面スコープ外
* mnemonic / accelerator — キーイベント整備後
* `setTextBorrowed(text)` — 利用者が寿命を保証できるケースで dup を回避するための入口
