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
    selected: bool = false,        // toggle button / checkbox 用 (将来)
    state_listeners:  ChangeListenerList,
    action_listeners: ChangeListenerList,

    // ... メソッド
};

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

`ActionListener` は専用の型ではなく、`ChangeListener` の構造（`fn_ptr` + `user_data`）を再利用する。
内部の `action_listeners` も `ChangeListenerList` の使い回し。
意味上だけ区別する。

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

## pressed / armed / rollover / enabled / selected の setter / getter
```zig
pub fn setPressed(self: *ButtonModel, v: bool) void;
pub fn isPressed(self: *const ButtonModel) bool;

pub fn setArmed(self: *ButtonModel, v: bool) void;
pub fn isArmed(self: *const ButtonModel) bool;

pub fn setRollover(self: *ButtonModel, v: bool) void;
pub fn isRollover(self: *const ButtonModel) bool;

pub fn setEnabled(self: *ButtonModel, v: bool) void;
pub fn isEnabled(self: *const ButtonModel) bool;

pub fn setSelected(self: *ButtonModel, v: bool) void;
pub fn isSelected(self: *const ButtonModel) bool;
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
    fn_ptr: *const fn (*anyopaque) void,
    user_data: *anyopaque,
) !void;

pub fn removeChangeListener(
    self: *ButtonModel,
    fn_ptr: *const fn (*anyopaque) void,
    user_data: *anyopaque,
) void;
```

状態フラグ（pressed / armed / rollover / enabled / selected）が変化したときに呼ばれるリスナー。
主に L&F や Button 自身が「再描画が要る」と判断するために使う。

## ActionListener の登録 / 削除
```zig
pub fn addActionListener(
    self: *ButtonModel,
    fn_ptr: *const fn (*anyopaque) void,
    user_data: *anyopaque,
) !void;

pub fn removeActionListener(
    self: *ButtonModel,
    fn_ptr: *const fn (*anyopaque) void,
    user_data: *anyopaque,
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

---

## 状態変化と Action の二系統
Button には 2 種類の通知系統がある。これは Swing の `JButton` も同じ。

| 通知 | 発火タイミング | 主な購読者 |
|---|---|---|
| ChangeListener | pressed / armed / rollover / enabled / selected が変化した時 | Button 自身（再描画）、L&F |
| ActionListener | クリックが完了した時（press 後 armed のまま release） | アプリケーションコード |

理由：

* 状態変化は再描画のフックとして頻繁に発生する（マウスが上に来ただけで rollover が変化、押下するだけで pressed が変化）
* アクションは「ユーザーが意図的にクリックした」セマンティクスを 1 回だけ通知すべきもの
* この 2 つを混ぜると、利用者が「ユーザーがクリックした時だけ何かしたい」と書きづらくなる

実装上は両方とも `ChangeListenerList` を内部で使うが、API として別エントリーポイント（`addChangeListener` vs `addActionListener`）を提供して区別する。

## armed と pressed の違い
| | 意味 |
|---|---|
| `pressed` | マウスボタンが現在押されている |
| `armed` | 押下中かつカーソルが Button の bounds 内にある |

「ドラッグして Button から外に出ると armed が false になり、戻ると true になる」「離した時に armed なら action 発火」という挙動を可能にするための区別。
Swing の `ButtonModel` と同じ意味。

## 値変化から再描画と Action 発火までの流れ
ユーザー操作の典型シナリオ：

1. マウスが Button 上に乗る → `processEvent` が `setRollover(true)` を呼ぶ
2. ChangeListener fire → `component.repaint()`（hover 状態の見た目に切替）
3. マウスボタン押下 → `setPressed(true)`, `setArmed(true)`
4. ChangeListener fire → `component.repaint()`（押下中の見た目に切替）
5. マウスボタンを離す（カーソルが内側）→ `setPressed(false)`, `setArmed(false)` → ChangeListener fire → `component.repaint()`、その後 `fireAction()` → ActionListener fire → アプリのハンドラが呼ばれる
6. マウスボタンを離す（カーソルが外側）→ `setPressed(false)`, `setArmed(false)` → ChangeListener fire → `component.repaint()`（Action は発火しない）

これにより「ドラッグで取り消し」ができる UX が実装される。

## install / uninstall で Model にリスナーを登録する
vtable の `install` で Model に「自分自身を再描画するための ChangeListener」を登録する。
`uninstall` で外す。
L&F 差し替え時の挙動は `model.md`「ウィジェットとの連携」と同じ。

ActionListener の登録は利用者がアプリコードから直接行う（Button 自身は登録しない）。

## レイアウト属性
* `min_size`: テキスト寸法 + padding（既定: 上下 8px、左右 12px ぐらい）
* `max_size`: inf, inf（伸ばしても見た目は壊れない想定）
* `grow_x` / `grow_y`: 0（既定では伸びない）

利用者が「ボタンを行いっぱいに広げたい」場合は `setGrowX(1)` で上書きする。

---

## 利用例
基本形（内部 Model）。

```zig
const button = try app.button("OK");
defer button.component.vtable.destroy(&button.component, app.allocator);

button.component.setBounds(.{ .x = 20, .y = 20, .width = 100, .height = 32 });
try frame.window.add(&button.component);

// クリックハンドラを登録
fn onOkClicked(user_data: *anyopaque) void {
    const ctx: *AppContext = @ptrCast(@alignCast(user_data));
    ctx.dialog_result = .ok;
    ctx.loop.exit(0);
}

try button.getModel().addActionListener(onOkClicked, &app_ctx);
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
fn onButtonStateChanged(user_data: *anyopaque) void {
    const btn: *Button = @ptrCast(@alignCast(user_data));
    if (btn.getModel().isRollover()) showTooltip();
}

try button.getModel().addChangeListener(onButtonStateChanged, button);
```

## 機能要望
* キーボード操作（Space / Enter で押下）
* ニーモニック（Alt+x ショートカット）
* アイコン表示（テキスト + アイコン併用）
* トグルボタン（`selected` フラグを活用、ButtonGroup と組合せて排他選択）
* デフォルトボタンの装飾（Enter で発火する強調表示）
* アクセシビリティ用の追加属性（aria-label 相当）
