# toggle_button_model
チェックボックス / ラジオボタン / トグルメニュー項目の共通モデル。
`ButtonModel` (押下・armed・hover・enabled) を embed し、 加えて二値の `selected` フラグを持つ。

## 型定義
```zig
pub const ToggleButtonModel = struct {
    button:   ButtonModel,    // pressed / armed / rollover / enabled + listener list
    selected: bool = false,

    // メソッド (後述)
};
```

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

埋め込んだ `button` の `deinit` を呼ぶ (listener list のメモリ解放)。
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
pub fn addChangeListener   (self: *ToggleButtonModel, fn_ptr: ChangeListenerList.ListenerFn, user_data: *anyopaque) !void;
pub fn removeChangeListener(self: *ToggleButtonModel, fn_ptr: ChangeListenerList.ListenerFn, user_data: *anyopaque) void;
pub fn addActionListener   (self: *ToggleButtonModel, fn_ptr: ChangeListenerList.ListenerFn, user_data: *anyopaque) !void;
pub fn removeActionListener(self: *ToggleButtonModel, fn_ptr: ChangeListenerList.ListenerFn, user_data: *anyopaque) void;
```

いずれも内部の `button` に委譲するだけのラッパー。
`model.button.addChangeListener(...)` を直接呼ぶのと同等だが、 こちらのほうが「toggle model 経由で十分」と分かりやすい (利用例の表記レベルが揃う)。

## アクション発火
```zig
pub fn fireAction(self: *ToggleButtonModel) void;
```

`button.fireAction` への委譲。
クリック等で widget が toggle を反転させたあと、 これを呼んで ActionListener を起こす。

---

## button フィールドへの直接アクセス
press / armed / rollover / enabled の操作 / 取得には、 ラッパーを介さず `model.button.setPressed(...)` / `model.button.isEnabled()` のように **直接アクセス**する。
Zig の慣用 (`component.md`「派生型から Component メソッドへのアクセス」と同じ方針) で、 委譲メソッドを生やさないことでボイラープレートを避ける。

```zig
// widget 側の処理イメージ
const btn = &cb.model.button;
if (!btn.enabled) return;
btn.setPressed(true);
btn.setArmed(true);
// ... toggle 反転は ToggleButtonModel API で
cb.model.setSelected(!cb.model.isSelected());
cb.model.fireAction();
```

## 機能要望
* 三状態 (intermediate / mixed) 対応 — ツリーチェックボックス等で「子の一部だけ選択」を表現したい場合に追加 (`selected: enum { off, on, mixed }`)。 現状は二値固定
