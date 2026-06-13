---
unsafe: true
---

# button
クリック可能なウィジェット。
押下中 / マウスオーバー中 / disabled などの状態を `ButtonModel` で保持し、クリック完了時に ActionListener へ通知する。
Swing の `JButton` 相当。

状態変化（pressed / armed / rollover 等）と「クリック発生」は別の通知系統に分離されている。
前者は ChangeListener、後者は ActionListener が拾う。
詳細は本ドキュメントの「状態変化と Action の二系統」を参照。

## 型定義
```zig
pub const ButtonModel = struct {
    pressed:  bool = false,        // マウスボタンが押されている (Button 上での状態)
    armed:    bool = false,        // 押下中かつカーソルが Button 内にある (release で fire 発火)
    rollover: bool = false,        // マウスホバー中
    enabled:  bool = true,         // false なら入力無効 + 視覚的にグレーアウト
    state_listeners:  ChangeListenerList,
    action_listeners: ActionListenerList,

    // ... メソッド
};
```

選択状態 (`selected`) は CheckBox / RadioButton / ToggleButton 等が `ToggleButtonModel` (本モデルを embed する派生) 側に持つ。
素の momentary button では使わないのでここには無い。

```zig
pub const Button = struct {
    component:  Component,
    model:      *ButtonModel,
    owns_model: bool,
    text:       []const u8,         // allocator.dupe で所有
    font:       awt.Graphics.TextFont,
    color:      awt.Graphics.Color,

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

状態変化は `state_listeners`（`ChangeListenerList` = `ChangeEvent` を配送）、アクションは
`action_listeners`（`ActionListenerList` = `ActionEvent` を配送）に分かれる。
イベント型が `ChangeEvent` / `ActionEvent` で別なので、ハンドラのシグネチャでどちらの通知かが分かる。

## ButtonModel の初期化
```zig
pub fn init(allocator: std.mem.Allocator) ButtonModel;
```

全フラグを初期値で初期化する。
`state_listeners` / `action_listeners` も空で初期化する。

## ButtonModel の後片付け
```zig
pub fn deinit(self: *ButtonModel) void;
```

両リスナーリストを解放する。

## pressed / armed / rollover / enabled の setter / getter
```zig
pub fn setPressed(self: *ButtonModel, v: bool) void;
pub fn isPressed(self: *const ButtonModel) bool;

pub fn setArmed(self: *ButtonModel, v: bool) void;
pub fn isArmed(self: *const ButtonModel) bool;

pub fn setRollover(self: *ButtonModel, v: bool) void;
pub fn isRollover(self: *const ButtonModel) bool;

pub fn setEnabled(self: *ButtonModel, v: bool) void;
pub fn isEnabled(self: *const ButtonModel) bool;
```

setter は値が変化した時のみ `state_listeners.fire()` する。

## Action の発火
```zig
pub fn fireAction(self: *ButtonModel) void;
```

「クリックが完了した」セマンティクスを示す通知を発火する。
`action_listeners.fire()` を内部で呼ぶ。
通常は Button の `processEvent` が「press → armed のまま release」を検知した時に呼ぶ。
状態フラグは変えない（フラグ変化通知とは別系統）。

## ChangeListener の登録 / 削除
```zig
pub fn addChangeListener(
    self: *ButtonModel,
    comptime T: type,
    comptime f: fn (*T, *const ChangeEvent) void,
    user_data: *T,
) !void;

pub fn removeChangeListener(
    self: *ButtonModel,
    comptime T: type,
    comptime f: fn (*T, *const ChangeEvent) void,
    user_data: *T,
) void;
```

状態フラグ（pressed / armed / rollover / enabled / selected）が変化したときに呼ばれるリスナー。
主に L&F や Button 自身が「再描画が要る」と判断するために使う。

## ActionListener の登録 / 削除
```zig
pub fn addActionListener(
    self: *ButtonModel,
    comptime T: type,
    comptime f: fn (*T, *const ActionEvent) void,
    user_data: *T,
) !void;

pub fn removeActionListener(
    self: *ButtonModel,
    comptime T: type,
    comptime f: fn (*T, *const ActionEvent) void,
    user_data: *T,
) void;
```

「ボタンがクリックされた」セマンティクスのリスナー。
利用者がボタン押下のハンドラを登録するための入口。

## Button の生成（内部 Model）
```zig
pub fn create(
    allocator: std.mem.Allocator,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*Button;
```

`ButtonModel` を内部生成して所有する。
`text` を dup して保持し、`component.min_size` をテキスト寸法 + padding から算出する。
vtable をセットして install まで実行する。

### 失敗時の保証
途中で失敗した場合、`create` 内で確保したメモリはすべて関数内で解放される。

## Button の生成（外部 Model）
```zig
pub fn createWithModel(
    allocator: std.mem.Allocator,
    model: *ButtonModel,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*Button;
```

利用者が事前に作った `ButtonModel` を借用する。
`owns_model = false` となる。
同じ Model を複数の Button で共有することで、「複数の表示位置に同じ disabled / selected 状態を持つボタン」が作れる。

## Button の破棄
```zig
fn destroy(self: *Component, allocator: std.mem.Allocator) void;
```

`Button.vtable.destroy` として登録される。
`uninstall` 経由で Model からリスナーを外したのち、text バッファを解放、`owns_model` が true なら Model を deinit + 解放、最後に Button 本体を free する。

## テキストの取得 / 設定
```zig
pub fn getText(self: Button) []const u8;
pub fn setText(self: *Button, text: []const u8) !void;
```

`setText` は dup し直して `component.min_size` をテキスト寸法から再計算する。
Label の `setText` と同じ流れ（`label.md` 参照）。

## フォントの取得 / 設定
```zig
pub fn getFont(self: Button) awt.Graphics.TextFont;
pub fn setFont(self: *Button, font: awt.Graphics.TextFont) void;
```

## 色の取得 / 設定
```zig
pub fn getColor(self: Button) awt.Graphics.Color;
pub fn setColor(self: *Button, color: awt.Graphics.Color) void;
```

## Model の取得
```zig
pub fn getModel(self: Button) *ButtonModel;
```

利用者が `addActionListener` を直接呼ぶ場合などに使う。

## プログラム的な起動
```zig
pub fn doClick(self: *Button) void;
```

ボタンを起動する (armed/pressed の遷移を経て `fireAction`)。
Space / Enter (フォーカス時)・ニーモニック・既定ボタンが共有する単一の入口。
`model.enabled == false` のときは no-op (全入口共通のガード)。

## ニーモニックの設定
```zig
pub fn setMnemonic(self: *Button, ch: u8) void;
```

`Alt+ch` でこのボタンをウィンドウのどこからでも起動できるようにする
(登録ではなく、配送時の走査が `component.mnemonic` を照合する)。
ラベル中の該当文字 (大文字小文字無視で最初の一致) に下線を引く。v1 は常時表示。
重複時は走査順 (ツリーの DFS 順) で先勝ち。

### 事前条件
* `ch` は ASCII の英字または数字であること。

## フォーカスとキー操作
Button は focusable (Tab トラバーサルの対象)。disabled の間は
`FocusQuery` により Tab がスキップする。フォーカス中:
* Space / Enter (press) → `doClick`
* フォーカスリング (角丸枠線) を描画する

## アイコンの取得 / 設定
```zig
pub fn getIcon(self: Button) ?awt.Image;
pub fn setIcon(self: *Button, icon: ?awt.Image) void;
```

`null` でアイコンなし。Image の所有権は Button に**移らない**（borrow）。
アイコン有無で見た目モードが切り替わる（後述「描画モード」参照）。

## アイコン表示サイズの取得 / 設定
```zig
pub fn getIconSize(self: Button) ?Component.Size;
pub fn setIconSize(self: *Button, size: ?Component.Size) void;
```

`null` のとき Image の実寸で描画する。
non-null のとき指定サイズに縮小 / 拡大して描画する（`awt.Graphics.drawImageScaled` 経由）。
toolbar 用に大きな画像を 16x16 / 20x20 等へ縮小表示するのが主な用途。

## レイアウト属性
モード別の `min_size`:

| モード | 計算 |
|---|---|
| standard (text only) | テキスト寸法 + padding (左右 12px / 上下 8px) |
| standard (text + icon) | アイコン幅 + 6px + テキスト寸法 + padding |
| flat (icon only) | アイコン寸法 + padding (上下左右 4px) |

`max_size` は `inf, inf`（伸ばしても見た目は壊れない想定）。
`grow_x` / `grow_y`: 0（既定では伸びない）。

利用者が「ボタンを行いっぱいに広げたい」場合は `setGrowX(1)` で上書きする。

## 利用例
基本形（内部 Model）。

```zig
const button = try app.button("OK");
defer button.component.vtable.destroy(&button.component, app.allocator);

button.component.setBounds(.{ .x = 20, .y = 20, .width = 100, .height = 32 });
try frame.window.add(&button.component);

// クリックハンドラを登録
fn onOkClicked(ctx: *AppContext, _: *const ActionEvent) void {
    ctx.dialog_result = .ok;
    ctx.loop.exit(0);
}

try button.getModel().addActionListener(AppContext, onOkClicked, &app_ctx);
```

disabled の制御。

```zig
button.getModel().setEnabled(false);   // グレーアウト + 入力無効化
// ...処理が完了したら...
button.getModel().setEnabled(true);
```

共有 Model で「同じ enabled 状態の 2 つのボタン」を作る例。

```zig
const model = try allocator.create(ButtonModel);
model.* = ButtonModel.init(allocator);
defer {
    model.deinit();
    allocator.destroy(model);
}

const toolbar_save = try Button.createWithModel(allocator, model, "Save", font, color);
const menu_save    = try Button.createWithModel(allocator, model, "Save", font, color);

// model.setEnabled(false) で両方とも disabled になる
```

状態変化を観察したいケース（rollover 中だけ別のフィードバックを出すなど）。

```zig
fn onButtonStateChanged(btn: *Button, _: *const ChangeEvent) void {
    if (btn.getModel().isRollover()) showTooltip();
}

try button.getModel().addChangeListener(Button, onButtonStateChanged, button);
```

toolbar に並べる icon-only ボタン（flat モード）。

```zig
const icon = try awt.Image.fromMemory(allocator, app.device, png_bytes);

const btn = try app.button("");        // text 空 → アイコン専用 = flat
btn.setIcon(icon);
btn.setIconSize(.{ .width = 20, .height = 20 });  // toolbar 用に縮小
try btn.getModel().addActionListener(State, onSave, &state);

try toolbar.container.add(&btn.component);
```

text + icon の standard モード。

```zig
const btn = try app.button("Save");
btn.setIcon(save_icon);
btn.setIconSize(.{ .width = 16, .height = 16 });
// → 角丸矩形ボタンの中に「[icon] Save」が並ぶ
```

## 機能要望
* `doClick()` — 計画中。press + fireAction + release を模す共通起動口（マウス / Space / Enter / ニーモニック全部の入口）。設計は `narrative/keybinding.md`
* キーボード操作（focusable 化 + Space / Enter で押下、フォーカスリング描画）— 計画中。設計は `narrative/keybinding.md`
* ニーモニック（`setMnemonic(ch)` で Alt+ch を ルート に登録 → `doClick` + ラベル下線）— 計画中。下線は v1 常時表示。設計は `narrative/keybinding.md`
* トグルボタン（`selected` フラグを活用、ButtonGroup と組合せて排他選択）
* デフォルトボタンの装飾（Enter で発火する強調表示。`Window.setDefaultButton` と連動）
* アクセシビリティ用の追加属性（aria-label 相当）
* tint カラー指定（モノクロ SVG 風アイコンを色付けして表示）
