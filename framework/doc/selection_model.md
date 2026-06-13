---
unsafe: true
---

# selection_model
List と Table が共有する行選択の状態モデル。
単一・複数選択の両方を表し、 ウィジェットは入力ジェスチャをこのモデルへの操作に翻訳する。
設計の経緯は [narrative/selection_model.md](narrative/selection_model.md) を参照。

## 型定義
```zig
pub const SelectionModel = struct {
    mode: Mode,                  // .single (既定) / .multiple
    items: std.ArrayList(usize), // 選択中の行 index。 昇順・重複なし
    anchor: ?usize,              // 範囲ジェスチャ (shift) の起点
    lead: ?usize,                // 現在行 (focus / キーボードの対象)
    allocator: std.mem.Allocator,

    pub const Mode = enum { single, multiple };
};
```

`.single` モードでは、 どの変更操作も結果を 1 行に畳む。
`lead` は選択されていない行を指すこともある (Swing の lead と同じ)。

## 関数定義

### 生成
```zig
pub fn init(allocator: std.mem.Allocator) SelectionModel;
```

`.single` モード・空選択で初期化する。 確保は最初の選択時まで遅延する。

### 破棄
```zig
pub fn deinit(self: *SelectionModel) void;
```

`items` を解放する。

### 選択の問い合わせ
```zig
pub fn isSelected(self: SelectionModel, i: usize) bool;
pub fn count(self: SelectionModel) usize;
pub fn indices(self: SelectionModel) []const usize; // 昇順
pub fn getLead(self: SelectionModel) ?usize;
pub fn getAnchor(self: SelectionModel) ?usize;
```

`indices` は内部バッファの借用ビューで、 次の変更操作まで有効。

### 選択の変更
```zig
pub fn clear(self: *SelectionModel) bool;
pub fn selectOnly(self: *SelectionModel, i: ?usize) Allocator.Error!bool;
pub fn toggle(self: *SelectionModel, i: usize) Allocator.Error!bool;
pub fn extendTo(self: *SelectionModel, i: usize) Allocator.Error!bool;
pub fn setMode(self: *SelectionModel, mode: Mode) Allocator.Error!bool;
```

いずれも「何か変化したか」を返す。 ウィジェットはこれを見て ChangeEvent 発火と再描画をする。
変化が無ければ `false` を返すので、 無駄な通知・再描画が起きない。

* `selectOnly(i)` — `i` だけを選択 (他を解除)。 null は全解除。 anchor と lead は `i` になる。
* `toggle(i)` — `i` の選択を反転 (ctrl+click)。 `.single` では `selectOnly(i)` と同じ。
* `extendTo(i)` — anchor から `i` までの連続範囲を選択 (shift)。 anchor は据え置き、 lead は `i`。
  anchor が無い、 または `.single` のときは `selectOnly(i)` と同じ。
* `setMode(mode)` — `.single` へ切り替えると、 既存の複数選択を lead (無ければ先頭) に畳む。

### モデル縮小への追従
```zig
pub fn clampToSize(self: *SelectionModel, size: usize) bool;
```

`size` 以上の index を捨て、 lead / anchor をクランプする。
ウィジェットはデータモデルの変更通知でこれを呼ぶ。
v1 は挿入 / 削除での index ずらしはしない。 範囲外を捨てるだけ (従来の単一選択と同じ割り切り)。

---

## 利用例
List / Table は `SelectionModel` をフィールドに持ち、 薄いラッパ API を出す。
入力ジェスチャの割り当ては各ウィジェットの doc を参照 (`list.md` / `table.md`)。

```zig
// ウィジェット側 (List の例)
const changed = if (m.modifiers.ctrl)
    self.selection.toggle(r) catch return
else if (m.modifiers.shift)
    self.selection.extendTo(r) catch return
else
    self.selection.selectOnly(r) catch return;
self.applySelectionChange(changed); // 変化時のみ再投影 + 通知 + 再描画
```

## 機能要望
* 挿入 / 削除での index ずらし (現状は範囲外を捨てるだけ)
* SINGLE_INTERVAL モード (連続 1 区間のみ。 Swing にはある)
* 範囲の追加 (shift+ctrl で既存選択に区間を足す)
