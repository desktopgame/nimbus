---
unsafe: true
---

# tabbed_pane
上端にタブ列を持ち、選択中の 1 つの内容コンポーネントだけを表示するコンテナである。
Swing の `JTabbedPane` の最小サブセットに相当する。v1 は上端タブ、マウスによる選択、
内容コンポーネントの所有だけを扱う。

## 型定義
```zig
pub const TabbedPane = struct {
    container:        Container,          // 公開 Component は container.component
    layout:           TabLayout,          // 内部 LayoutManager
    tabs:             std.ArrayListUnmanaged(Tab),
    selected:         ?usize,             // 空なら null
    font:             awt.Graphics.TextFont,
    change_listeners: ChangeListenerList,
    allocator:        std.mem.Allocator,
};

const Tab = struct {
    title:   []u8,        // TabbedPane が所有する UTF-8 タイトル
    content: *Component,  // embedded container が所有する内容
};

const TabLayout = struct {
    base: LayoutManager,
};
```

`TabbedPane` は `SplitPane` と同じ構築形で、先頭フィールドに `Container` を埋め込む。
公開コンポーネントは `container.component` であり、vtable は `paint`、`processEvent`、
`destroy` だけを差し替える。子コンポーネントは埋め込み `Container` の子として保持する。

レイアウトではタブ列の高さを 26px とし、選択中の内容だけを
`(0, 26, width, height - 26)` に置く。非選択の内容は `(0, 26, 0, 0)` に置く。
これは既存コンテナで使っているゼロ境界による非表示の慣習である。

最小サイズはタブ列の合計幅と内容の最大最小幅の大きい方を幅にし、高さは
26px と内容の最大最小高さの合計にする。最大サイズは無限大である。

## 関数定義

### 生成
```zig
pub fn create(
    allocator: std.mem.Allocator,
    font: awt.Graphics.TextFont,
) !*TabbedPane;
```

空のタブペインを作る。`selected` は `null` で始まる。
`app.tabbedPane()` ファクトリは既定フォント 14px を注入し、アプリケーションのテーマを適用する。

### コンポーネントの取得
```zig
pub fn asComponent(self: *TabbedPane) *Component;
```

### タブの追加
```zig
pub fn addTab(
    self: *TabbedPane,
    title: []const u8,
    content: *Component,
) !void;
```

`title` は内部で複製される。`content` の所有権は成功時も失敗時も `TabbedPane` に移る。
最初のタブを追加したときは選択 index が 0 になり、変更リスナーが発火する。
追加された内容のサブツリーには、現在の `TabbedPane` と同じテーマを適用する。

### タブの削除
```zig
pub fn removeTab(self: *TabbedPane, index: usize) void;
```

範囲外は no-op である。範囲内なら該当内容をコンテナから外し、内容サブツリーを破棄し、
タイトルを解放する。選択は残りのタブ数に合わせて再クランプされる。タブが空になった場合、
`getSelectedIndex` は `null` を返す。削除時は変更リスナーを発火する。

### タブ情報
```zig
pub fn count(self: TabbedPane) usize;
pub fn getTitleAt(self: TabbedPane, index: usize) []const u8;
pub fn getContentAt(self: TabbedPane, index: usize) *Component;
```

`getTitleAt` の戻り値は借用である。次のタイトル変更、削除、破棄まで有効である。

### 事前条件
`getTitleAt` と `getContentAt` の `index` は `index < count()` でなければならない。
範囲外の動作は未定義である。

### 選択
```zig
pub fn getSelectedIndex(self: TabbedPane) ?usize;
pub fn setSelectedIndex(self: *TabbedPane, index: usize) void;
```

タブが空なら `getSelectedIndex` は `null` を返す。`setSelectedIndex` は範囲内にクランプする。
選択が変わると変更リスナーが発火し、再レイアウトと再描画を要求する。

### 変更リスナー
```zig
pub fn addChangeListener(
    self: *TabbedPane,
    comptime T: type,
    comptime f: fn (*T, *const ChangeEvent) void,
    user_data: *T,
) !void;
```

選択が変わったとき、またはタブ削除で選択状態が再計算されたときに発火する。
イベントの `source` は `*TabbedPane` である。

## 利用例
```zig
const tabs = try app.tabbedPane();

const general = try app.panel();
const advanced = try app.panel();

try tabs.addTab("General", general.asComponent());
try tabs.addTab("Advanced", advanced.asComponent());

tabs.asComponent().setGrowX(1);
tabs.asComponent().setGrowY(1);
try nimbus.BorderLayout.add(&frame.window.container, .center, tabs.asComponent());
```

## 機能要望
* タブの閉じるボタン
* 下端、左端、右端のタブ配置
* キーボードによるタブ移動
* タブ列のスクロールまたは overflow 表示
* ドラッグによるタブ並べ替え
* タブアイコン
