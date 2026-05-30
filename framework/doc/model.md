---
unsafe: true
---

# model
状態を持つウィジェット（Slider、Button、TextField 等）が内部状態を観測可能な形で保持し、変更時にリスナーへ通知する仕組み。
Swing の `BoundedRangeModel` / `ButtonModel` / `Document` 等と同じ位置付け。

このドキュメントは個別の Model 型ではなく**共通プリミティブとパターン**を定義する。
個別の Model 型（`BoundedRangeModel` / `ButtonModel` 等）は対応するウィジェットの doc で定義する。

## 型定義
```zig
pub const ChangeListener = struct {
    fn_ptr:    *const fn (*anyopaque) void,
    user_data: *anyopaque,
};

pub const ChangeListenerList = struct {
    items:     std.ArrayList(ChangeListener),
    allocator: std.mem.Allocator,

    // ... メソッド
};
```

`ChangeListener` は「変更があったときに呼ばれる関数 + その引数」のペア。
`user_data` は登録元（typically Component や Model）が自分自身を渡し、コールバック内でキャストして使う。

`ChangeListenerList` は Model が embed して使うリスナー管理プリミティブ。
add / remove / fire の標準実装を提供する。

## リスナーリストの生成
```zig
pub fn init(allocator: std.mem.Allocator) ChangeListenerList;
```

空のリストを返す。
内部の動的アロケーションは最初の `add` 呼び出しまで遅延される。

## リスナーリストの破棄
```zig
pub fn deinit(self: *ChangeListenerList) void;
```

`items` の内部バッファを解放する。
登録されているリスナー自身の所有物（user_data の指す先など）には触れない。

## リスナーの登録
```zig
pub fn add(
    self: *ChangeListenerList,
    fn_ptr: *const fn (*anyopaque) void,
    user_data: *anyopaque,
) !void;
```

`(fn_ptr, user_data)` のペアをリストに追加する。
同じペアを複数回登録した場合は複数回発火される（重複検査はしない）。

## リスナーの削除
```zig
pub fn remove(
    self: *ChangeListenerList,
    fn_ptr: *const fn (*anyopaque) void,
    user_data: *anyopaque,
) void;
```

`(fn_ptr, user_data)` のペアと完全一致するエントリを 1 つ削除する。
見つからない場合は何もしない（エラーにしない）。

## 変更通知の発火
```zig
pub fn fire(self: *ChangeListenerList) void;
```

登録されている全リスナーを**登録順**で呼ぶ。
発火中にリスナーが `add` / `remove` を呼んでもこの発火呼び出し中には反映されない（次回発火から有効）。

## 利用例
新規 Model 定義の最小テンプレ（BoundedRangeModel の擬似コード）。

```zig
pub const BoundedRangeModel = struct {
    min:    i32,
    value:  i32,
    max:    i32,
    extent: i32 = 0,
    change_listeners: ChangeListenerList,

    pub fn init(allocator: std.mem.Allocator, min: i32, value: i32, max: i32) BoundedRangeModel {
        return .{
            .min = min, .value = value, .max = max,
            .change_listeners = ChangeListenerList.init(allocator),
        };
    }

    pub fn deinit(self: *BoundedRangeModel) void {
        self.change_listeners.deinit();
    }

    pub fn setValue(self: *BoundedRangeModel, v: i32) void {
        const clamped = std.math.clamp(v, self.min, self.max - self.extent);
        if (clamped == self.value) return;   // skip fire when unchanged
        self.value = clamped;
        self.change_listeners.fire();
    }

    pub fn addChangeListener(self: *BoundedRangeModel, fn_ptr: *const fn (*anyopaque) void, user_data: *anyopaque) !void {
        try self.change_listeners.add(fn_ptr, user_data);
    }

    pub fn removeChangeListener(self: *BoundedRangeModel, fn_ptr: *const fn (*anyopaque) void, user_data: *anyopaque) void {
        self.change_listeners.remove(fn_ptr, user_data);
    }
};
```

ウィジェット側で install / uninstall にリスナーを仕込むテンプレ。

```zig
// registered as Slider.vtable
fn install(comp: *Component) void {
    const slider: *Slider = @fieldParentPtr("component", comp);
    slider.model.addChangeListener(onModelChange, comp) catch {};
}

fn uninstall(comp: *Component) void {
    const slider: *Slider = @fieldParentPtr("component", comp);
    slider.model.removeChangeListener(onModelChange, comp);
}

fn onModelChange(user_data: *anyopaque) void {
    const comp: *Component = @ptrCast(@alignCast(user_data));
    comp.repaint();   // propagate dirty -> repaint next frame
}
```

共有 Model で 2 つのウィジェットを同期させる利用者コード。

```zig
const model = try app.allocator.create(BoundedRangeModel);
model.* = BoundedRangeModel.init(app.allocator, 0, 50, 100);
defer {
    model.deinit();
    app.allocator.destroy(model);
}

const slider_a = try Slider.createWithModel(app.allocator, model);
const slider_b = try Slider.createWithModel(app.allocator, model);
// moving slider_a syncs slider_b automatically

// direct mutation from app code
model.setValue(75);   // both sliders repaint
```

アプリ側から ChangeListener を直接登録する例（再描画とは別の用途、たとえば validation）。

```zig
fn onSliderChanged(user_data: *anyopaque) void {
    const ctx: *MyAppContext = @ptrCast(@alignCast(user_data));
    ctx.recomputeTotal();
}

try slider.model.addChangeListener(onSliderChanged, &app_ctx);
```

## 機能要望
* 専用イベント型（`DocumentEvent` 相当、何が変わったかを引数で渡す）
* バッチ通知（複数 setter 呼び出しを 1 通知にまとめる `Model.beginUpdate` / `endUpdate`）
* PropertyChangeListener 相当（プロパティ単位の細かい通知）
* Model 間の bind ヘルパ（Model A の変化を Model B に反映する標準パターン）
