---
unsafe: true
---

# toggle_button_model
チェックボックス / ラジオボタン / トグルメニュー項目の共通モデル。
`ButtonModel` (押下・armed・hover・enabled) を embed し、 加えて二値の `selected` フラグを持つ。

## 型定義
```zig
pub const ToggleButtonModel = struct {
    button:     ButtonModel,        // pressed / armed / rollover / enabled + listener list
    selected:   bool = false,
    group_hook: ?GroupHook = null,  // 所属する ButtonGroup への detach 通知口 (なければ null)

    // メソッド (後述)
};

pub const GroupHook = struct {
    ctx:       *anyopaque,
    on_deinit: *const fn (ctx: *anyopaque, model: *ToggleButtonModel) void,
};
```

`group_hook` は `ButtonGroup` が `add` 時に仕込む back-channel。
`ButtonGroup` を import せず opaque ctx + 関数ポインタで持つことで循環依存を避ける (DirtyNotify / FocusController と同じ方針)。
model が group より先に破棄されるケースで、 `deinit` から group に通知して dangling 参照を外させるために使う。
最大 1 つの group にのみ属せる (Swing 同様)。

`ButtonModel` から `selected` を切り出した理由は、 通常の momentary `Button` には selected 状態がなく、 `selected` フィールドを共通モデルに残すと「使われないフィールド」がぶら下がって意味が伝わりにくくなるため。
チェック状態を持つ widget (`CheckBox` / `RadioButton` / `CheckBoxMenuItem`) はこの型を使う。

## 生成
```zig
pub fn init(allocator: std.mem.Allocator) ToggleButtonModel;
```

`ButtonModel.init` を内部で呼んで `selected = false` で初期化する。

## 後片付け
```zig
pub fn deinit(self: *ToggleButtonModel) void;
```

`group_hook` が設定されていれば、 まずそれを呼んで所属 group に自分の破棄を通知する (group が listener を解除し参照を外す)。
通知は `button.deinit` の **前** に行う — listener list がまだ有効なうちに group が解除できるようにするため。
その後、 埋め込んだ `button` の `deinit` を呼ぶ (listener list のメモリ解放)。
それ以外のリソースは持たない。

## 選択状態の取得
```zig
pub fn isSelected(self: *const ToggleButtonModel) bool;
```

## 選択状態の設定
```zig
pub fn setSelected(self: *ToggleButtonModel, v: bool) void;
```

`selected` を更新する。
値が変化した場合のみ、 **埋め込んだ `button` の state_listeners を fire する**。
これは Swing の流儀で、 selected と pressed / rollover 等の状態変化を同じ `ChangeListener` で受けられるという考え方。
利用側 (widget) はこの listener 経由で `repaint` を仕込む。

## リスナー登録
```zig
pub fn addChangeListener   (self: *ToggleButtonModel, comptime T: type, comptime f: fn (*T, *const ChangeEvent) void, user_data: *T) !void;
pub fn removeChangeListener(self: *ToggleButtonModel, comptime T: type, comptime f: fn (*T, *const ChangeEvent) void, user_data: *T) void;
pub fn addActionListener   (self: *ToggleButtonModel, comptime T: type, comptime f: fn (*T, *const ActionEvent) void, user_data: *T) !void;
pub fn removeActionListener(self: *ToggleButtonModel, comptime T: type, comptime f: fn (*T, *const ActionEvent) void, user_data: *T) void;
```

いずれも内部の `button` に委譲するだけのラッパー。
`model.button.addChangeListener(...)` を直接呼ぶのと同等だが、 こちらのほうが「toggle model 経由で十分」と分かりやすい (利用例の表記レベルが揃う)。

## アクション発火
```zig
pub fn fireAction(self: *ToggleButtonModel) void;
```

`button.fireAction` への委譲。
クリック等で widget が toggle を反転させたあと、 これを呼んで ActionListener を起こす。

## group hook の設定
```zig
pub fn setGroupHook(self: *ToggleButtonModel, hook: ?GroupHook) void;
```

`group_hook` を設定 / 解除する (`null` で解除)。
`ButtonGroup` が `add` / `remove` で呼ぶ内部向け API で、 利用者が直接呼ぶことは想定しない。

## 機能要望
* 三状態 (intermediate / mixed) 対応 — ツリーチェックボックス等で「子の一部だけ選択」を表現したい場合に追加 (`selected: enum { off, on, mixed }`)。 現状は二値固定
