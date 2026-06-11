---
unsafe: true
---

# slider
範囲 [min, max] の中で 1 つの値を選択するウィジェット。
水平 / 垂直のいずれかの方向に表示される。
Swing の `JSlider` 相当。

状態は `BoundedRangeModel` に分離される（`model.md` 参照）。
Slider 本体は Model を参照して描画と入力処理を担い、状態の保持と通知は Model が担当する。

## 型定義
```zig
pub const BoundedRangeModel = struct {
    min:    i32,
    value:  i32,
    max:    i32,
    extent: i32 = 0,                  // value から +extent の範囲を「選択中」とみなす (スクロールバーで使う)
    change_listeners: ChangeListenerList,

    // ... メソッド
};

pub const Orientation = enum { horizontal, vertical };

pub const Slider = struct {
    component:   Component,
    model:       *BoundedRangeModel,
    owns_model:  bool,                // true なら destroy で model も解放
    orientation: Orientation,

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

## BoundedRangeModel の初期化
```zig
pub fn init(
    allocator: std.mem.Allocator,
    min: i32,
    value: i32,
    max: i32,
) BoundedRangeModel;
```

`min <= value <= max` を前提に Model を初期化する。
`extent` は 0 で開始する。
内部の `ChangeListenerList` も空で初期化する。

## BoundedRangeModel の後片付け
```zig
pub fn deinit(self: *BoundedRangeModel) void;
```

`change_listeners` の内部リストを解放する。
登録済みリスナーの所有物（user_data の指す先）には触れない。

## 値の設定
```zig
pub fn setValue(self: *BoundedRangeModel, v: i32) void;
```

`v` を `[min, max - extent]` にクランプして保持する。
クランプ後の値が現在値と異なる場合のみ `change_listeners.fire()` する。

## 値の取得
```zig
pub fn getValue(self: *const BoundedRangeModel) i32;
```

## 範囲の設定
```zig
pub fn setRange(self: *BoundedRangeModel, min: i32, max: i32) void;
```

`min` / `max` を同時に更新し、必要なら `value` / `extent` をクランプする。
何か変化があれば `change_listeners.fire()` する。

## extent の設定
```zig
pub fn setExtent(self: *BoundedRangeModel, extent: i32) void;
```

`extent >= 0` かつ `value + extent <= max` の制約に合わせて更新する。
変化があれば `change_listeners.fire()` する。

## min / value / max / extent の一括設定
```zig
pub fn setRangeProperties(
    self: *BoundedRangeModel,
    min: i32,
    value: i32,
    max: i32,
    extent: i32,
) void;
```

4 つのプロパティを同時に更新し、最後にまとめてクランプを 1 回だけ適用する。
適用順は `extent` を `[0, max - min]` に、続いて `value` を `[min, max - extent]` にクランプ。
何か変化があれば `change_listeners.fire()` する。

`setRange` + `setExtent` を順に呼ぶと、 中間状態で「`value > max` だが `setRange` がそれをクランプしないため、 続く `setExtent` で extent が縮められる」という縮退が起きうる (例: ScrollPane で大きく成長したコンテンツが縮んで `value` が古いまま残るケース)。
複数プロパティを同時に変えるときはこちらを使う。
Swing の `DefaultBoundedRangeModel.setRangeProperties` 相当。

## リスナーの登録 / 削除
```zig
pub fn addChangeListener(
    self: *BoundedRangeModel,
    comptime T: type,
    comptime f: fn (*T, *const ChangeEvent) void,
    user_data: *T,
) !void;

pub fn removeChangeListener(
    self: *BoundedRangeModel,
    comptime T: type,
    comptime f: fn (*T, *const ChangeEvent) void,
    user_data: *T,
) void;
```

`change_listeners` への薄いラッパ。
詳細は `model.md` 参照。

## Slider の生成（内部 Model）
```zig
pub fn create(
    allocator: std.mem.Allocator,
    orientation: Orientation,
    min: i32,
    value: i32,
    max: i32,
) !*Slider;
```

`BoundedRangeModel` を allocator で確保して内部生成する。
vtable をセットして install まで実行する。
`owns_model = true` となり、`destroy` 時に Model も解放される。

### 失敗時の保証
途中で失敗した場合、`create` 内で確保したメモリはすべて関数内で解放される。

## Slider の生成（外部 Model）
```zig
pub fn createWithModel(
    allocator: std.mem.Allocator,
    orientation: Orientation,
    model: *BoundedRangeModel,
) !*Slider;
```

利用者が事前に作った `BoundedRangeModel` を借用する。
`owns_model = false` となり、`destroy` 時に Model は解放されない（呼び出し側責務）。
同じ Model を複数の Slider で共有することで「2 つの Slider が同じ値を表示・操作」が実現できる。

## Slider の破棄
```zig
fn destroy(self: *Component, allocator: std.mem.Allocator) void;
```

`Slider.vtable.destroy` として登録される。
`uninstall` 経由で Model からリスナーを外したのち、`owns_model` が true なら Model を deinit + 解放する。
最後に Slider 本体を allocator で free する。

## 方向の取得
```zig
pub fn getOrientation(self: Slider) Orientation;
```

## 方向の設定
```zig
pub fn setOrientation(self: *Slider, o: Orientation) void;
```

方向を変更して再レイアウト + 再描画を要求する。
描画コードは方向で分岐するため、変更後の `paint` は新方向で描画する。

## Model の取得
```zig
pub fn getModel(self: Slider) *BoundedRangeModel;
```

利用者が `addChangeListener` を直接呼びたい場合などに使う。

## フォーカスとキー操作
Slider は focusable (Tab トラバーサルの対象)。フォーカス中:
* `→` / `↑` (press / repeat) → 値を +1
* `←` / `↓` (press / repeat) → 値を -1 (クランプは model 側)
* フォーカスリング (枠線) を描画する

## レイアウト属性
* `min_size`: ツマミ + 数 px の余白が収まる最小寸法（方向に応じて）
* `max_size`: 主軸方向は inf、交差軸方向は固定値（垂直 Slider の幅、水平 Slider の高さ）
* `grow_x` / `grow_y`: 主軸方向のみ 1、交差軸方向は 0（典型）

これらは `create` 時に方向から自動算出してセットされる。
利用者は必要なら `component.setMinSize` 等で上書きできる。

## 利用例
基本形（内部 Model）。

```zig
const slider = try Slider.create(allocator, .horizontal, 0, 50, 100);
defer slider.component.vtable.destroy(&slider.component, allocator);

slider.component.setBounds(.{ .x = 20, .y = 20, .width = 200, .height = 24 });
try frame.window.add(&slider.component);
```

値変化を監視する例。

```zig
fn onValueChanged(ctx: *AppContext, _: *const ChangeEvent) void {
    const v = ctx.slider.getModel().getValue();
    std.debug.print("slider value = {d}\n", .{v});
}

try slider.getModel().addChangeListener(AppContext, onValueChanged, &app_ctx);
```

共有 Model で 2 つの Slider を同期させる例。

```zig
const model = try allocator.create(BoundedRangeModel);
model.* = BoundedRangeModel.init(allocator, 0, 50, 100);
defer {
    model.deinit();
    allocator.destroy(model);
}

const slider_a = try Slider.createWithModel(allocator, .horizontal, model);
const slider_b = try Slider.createWithModel(allocator, .vertical, model);
// slider_a を動かすと slider_b の表示も同期する

// プログラム的に変更しても両方に反映
model.setValue(75);
```

## 機能要望
* 矢印キーで増減（KeyEvent サポート）
* 目盛り / ラベル表示（major / minor tick）
* スナップ（指定値に吸着）
* `setInverted(bool)` で方向反転（min 側を右 / 上に）
* 範囲スライダー（2 つのツマミで `[a, b]` 区間を選ぶ）
* ホイールスクロールで値変更
* float / double 値の対応（現状 `BoundedRangeModel` は `i32` 固定 = Swing `JSlider` 準拠）。連続値（音量 / 不透明度 / 0.0〜1.0 の比率など）を扱いたいケース向け。pixel 位置 ↔ 値の写像はすでに float 計算なので、Model の値型を広げるのが本体。実装案: 別系統の浮動小数 Model（例 `BoundedFloatRangeModel`）を足すか、`BoundedRangeModel` を値型で総称化するか。ScrollBar が同じ `BoundedRangeModel` を共有しており、そちらは整数ステップが自然なので、共有 Model を総称化すると影響が広い点に注意（着手時に backlog 化して案を比較する）
