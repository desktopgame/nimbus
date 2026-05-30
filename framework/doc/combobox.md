---
unsafe: true
---

# combobox
ドロップダウン式の選択ウィジェット (read-only、 文字列リストのみ)。
クリックで item リスト popup を開いて 1 項目を選ぶ。

v1 スコープ:
* 文字列 (`[]const u8`) のみ
* editable 不可 (フィールドへの直接タイプ不可)
* レンダラーカスタマイズ不可

それぞれ将来 additive に拡張可能 (機能要望参照)。

## 型定義
```zig
pub const ComboBox = struct {
    component:        Component,
    popup_root:       Component,                    // overlay の root (Window に登録)
    items:            std.ArrayList([]const u8),   // 所有された UTF-8 dup
    selected_index:   usize,
    hovered_index:    ?usize,                       // popup 内の hover ハイライト用
    open:             bool,
    window:           ?*Window,                     // open 中は親 Window を持つ
    has_focus:        bool,
    enabled:          bool,
    font:             awt.Graphics.TextFont,
    color:            awt.Graphics.Color,
    change_listeners: ChangeListenerList,
    allocator:        std.mem.Allocator,
};
```

`popup_root` は ComboBox 自身が抱える別 Component で、 open 時に `Window.addOverlay` で登録される。
独立した vtable (`popup_vtable`) を持ち、 popup の描画 / マウス処理を担う。

## 生成
```zig
pub fn create(
    allocator: std.mem.Allocator,
    items: []const []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*ComboBox;
```

`items` の各文字列は内部で `allocator.dupe` してコピーされる (呼び出し後の解放 OK)。
失敗時は途中で確保した分を全て解放する。

ファクトリ:
```zig
const items = [_][]const u8{ "Apple", "Banana", "Cherry" };
const combo = try app.comboBox(&items);
```

## 選択の取得 / 設定
```zig
pub fn getSelectedIndex(self: ComboBox) usize;
pub fn setSelectedIndex(self: *ComboBox, idx: usize) void;
pub fn getSelectedItem(self: ComboBox) ?[]const u8;
```

`setSelectedIndex` は範囲外 / 不変なら no-op。 変化があれば ChangeListener を発火 + repaint。
`getSelectedItem` は item が 0 個 or index 不正なら null。

## アイテムへのアクセス
```zig
pub fn getItemCount(self: ComboBox) usize;
pub fn getItem(self: ComboBox, idx: usize) ?[]const u8;
```

返り値の slice は内部バッファへの借用 — 次の item 変更 (将来 `setItem` 等が追加されたら) まで有効。

## 有効 / 無効
```zig
pub fn isEnabled(self: ComboBox) bool;
pub fn setEnabled(self: *ComboBox, v: bool) void;
```

無効化時に open 中なら自動で閉じる。

## ChangeListener
```zig
pub fn addChangeListener   (self: *ComboBox, fn_ptr: ChangeListenerList.ListenerFn, user_data: *anyopaque) !void;
pub fn removeChangeListener(self: *ComboBox, fn_ptr: ChangeListenerList.ListenerFn, user_data: *anyopaque) void;
```

選択 (`selected_index`) が変化した瞬間に発火する。
hover やフォーカスでは発火しない。

## 機能要望
* `editable = true` モード (フィールドが TextField になり、 直接タイプ + popup から選択も可)
* 任意型 item + ListCellRenderer (Swing JComboBox<T>)
* item の動的変更 API (`addItem` / `removeItem` / `clearItems`)
* popup の最大高さ + スクロール (現状は item 数分の高さを全て確保する)
* キーボードによる incremental search ("A" を押すと "A" で始まる item へジャンプ)
* フォーカスリング描画
