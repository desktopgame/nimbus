---
unsafe: false
---

# border_layout
5 つの region (north / south / east / west / center) に子を配置する `LayoutManager`。
ツールバー (north)、ステータスバー (south)、サイドバー (west / east)、メインコンテンツ (center) の典型レイアウトを構成するための定番。
Swing の `BorderLayout` を簡素化したもの。
hint で region 指定が必須。

## 型定義
```zig
pub const Region = enum(u8) { north, south, east, west, center };

pub const BorderLayout = struct {
    base: LayoutManager,

    pub const vtable = LayoutManager.VTable{
        .doLayout       = doLayout,
        .computeMinSize = computeMinSize,
        .computeMaxSize = computeMaxSize,
    };

    // ... メソッド
};
```

利用者は `BorderLayout` 自体を直接インスタンス化せず、シングルトンを返すヘルパで使う（後述）。

## レイアウトの取得
```zig
pub fn get() *LayoutManager;
```

シングルトン `BorderLayout` への `*LayoutManager` を返す。
`Container.setLayout` に渡す。

## 子の追加
```zig
pub fn add(container: *Container, region: Region, child: *Component) !void;
```

`container.addWithHint(child, region_marker, null)` の薄いラッパ。
hint には region 識別用の static pointer が入る（allocator 不要）。

### 事前条件
* `container` の layout が `BorderLayout` であること（そうでない場合 hint は無視される）
* 同じ region に複数回 `add` してはいけない（後勝ち / 無視は未定義、利用者が責任を持つ）

## 利用例
基本のシェル（toolbar + status bar + sidebar + content）。

```zig
const root = try app.container();
root.setLayout(BorderLayout.get());

const toolbar = try app.panel();
toolbar.container.component.min_size = .{ .width = 0, .height = 32 };
toolbar.setBackground(awt.Graphics.Color.rgb(0.85, 0.85, 0.85));

const status = try app.panel();
status.container.component.min_size = .{ .width = 0, .height = 24 };
status.setBackground(awt.Graphics.Color.rgb(0.4, 0.4, 0.5));

const sidebar = try app.panel();
sidebar.container.component.min_size = .{ .width = 200, .height = 0 };
sidebar.setBackground(awt.Graphics.Color.rgb(0.92, 0.92, 0.94));

const content = try app.panel();
content.setBackground(awt.Graphics.Color.rgb(1, 1, 1));

try BorderLayout.add(root, .north,  &toolbar.container.component);
try BorderLayout.add(root, .south,  &status.container.component);
try BorderLayout.add(root, .west,   &sidebar.container.component);
try BorderLayout.add(root, .center, &content.container.component);

try frame.window.add(&root.component);
```

toolbar 内に複数のボタンを並べる例（toolbar 自体は BoxLayout でラップ）。

```zig
toolbar.container.setLayout(BoxLayout.horizontal());
try toolbar.container.add(&save_btn.component);
try toolbar.container.add(&open_btn.component);
try toolbar.container.add(&app.filler().container.component);  // 右側のスペース
try toolbar.container.add(&settings_btn.component);
```

center を BoxLayout でさらに分割する例（左右ペイン）。

```zig
const split = try app.container();
split.setLayout(BoxLayout.horizontal());

const left  = try app.panel();
left.container.component.min_size = .{ .width = 300, .height = 0 };
const right = try app.panel();
right.container.component.setGrowX(1);

try split.add(&left.container.component);
try split.add(&right.container.component);

try BorderLayout.add(root, .center, &split.component);
```

## 機能要望
* region 間 gap (spacing) のサポート
* corners を W/E に渡すオプション（Photoshop / Figma 系のレイアウト）
* N/S の `align_x` 尊重（full width にせず min 幅で配置可）
* 同一 region への複数 add をエラーにする debug assertion
