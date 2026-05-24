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

---

## レイアウト
* 横方向: `(item label の最大幅) + PADDING_X * 2 + CHEVRON_W (16)`
* 縦方向: `line_height + PADDING_Y * 2`
* `grow_x = 0` (固定幅、 利用者が `setGrowX(1)` で拡張可)

## 描画
**閉じている状態**:
1. 背景塗り (enabled = false なら灰)
2. 枠 (focus 時青、 通常灰)
3. selected の item の文字 (左寄せ、 中央上下揃え)
4. 右側に下向き chevron (▼) を 1px 縞の三角形で描画

**popup (overlay)**:
1. 白背景
2. 各 item を縦に並べる (行高 = `line_height + ITEM_PADDING_Y * 2`)
3. hover している行は背景を青、 テキストを白に
4. 外周に 1px 枠

popup のサイズ:
* 幅: ComboBox 本体と同じ
* 高さ: `items.len * item_height`
* 位置: ComboBox 本体の下端

## イベント処理
### 閉じている状態 (本体に対する操作)
| 入力 | 動作 |
|---|---|
| マウス left press (内側) | フォーカス取得 + popup open (or 既に open なら close) |
| ↓ キー | `selected_index + 1` (リスト末尾でクランプ)、 ChangeListener 発火 |
| ↑ キー | `selected_index - 1` (0 でクランプ) |
| Enter / Space | popup open (or 既に open なら close) |
| Escape | open なら close |

### popup が open している状態
| 入力 | 動作 |
|---|---|
| マウス move (popup 内) | `hovered_index` 更新 + repaint |
| マウス left press (popup 内、 item 上) | その index を確定 (`setSelectedIndex`) + close |
| マウス left press (popup 外) | Window が `dismissAllOverlays` を呼ぶ → close (選択変更なし) |
| Escape | close (選択変更なし) |
| ↓ / ↑ | `hovered_index` 移動 |
| Enter / Space | `hovered_index` を確定 + close |

popup は Menu / PopupMenu と同じ Window overlay 機構の上に乗っており、 cascade 等の管理は Window 側に任せている。

## 寿命
ComboBox は `popup_root` を自身の中に embed しており、 open 時のみ Window の overlays リストにポインタが入る。
`uninstall` / `destroy` 時に open 中なら自動で `hide()` (= `Window.removeOverlay`) を呼ぶので、 利用者が手動で close する必要はない。

`popup_root` はどの Container にも属さない独立 Component なので、 ツリー側からは deinit されない。
`Window.addOverlay` が初回 open 時に `popup_root` のプロパティマップ (DirtyNotify / FocusController) を遅延確保するため、 `destroy` では本体 Component に加えて `popup_root` も明示的に deinit してこのマップを解放する。

各 item の文字列は `items` (ArrayList of dup) として所有しており、 `destroy` で全部 free。

## 機能要望
* `editable = true` モード (フィールドが TextField になり、 直接タイプ + popup から選択も可)
* 任意型 item + ListCellRenderer (Swing JComboBox<T>)
* item の動的変更 API (`addItem` / `removeItem` / `clearItems`)
* popup の最大高さ + スクロール (現状は item 数分の高さを全て確保する)
* キーボードによる incremental search ("A" を押すと "A" で始まる item へジャンプ)
* フォーカスリング描画
