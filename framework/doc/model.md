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
// 状態が変わったときの通知（Swing の ChangeEvent 相当）。
pub const ChangeEvent = struct { source: *anyopaque };

// 確定的なアクション（ボタンのクリック、フィールドの submit / cancel 等）の
// 通知（Swing の ActionEvent 相当）。
pub const ActionEvent = struct { source: *anyopaque };

// イベント型 E を配送するリスナー管理プリミティブを返す総称関数。
pub fn ListenerList(comptime E: type) type {
    return struct {
        const Self = @This();

        pub const Event = E;   // このリストが配送するイベント型
        pub const ListenerFn = *const fn (user_data: *anyopaque, event: *const E) void;

        pub const Listener = struct {
            fn_ptr:    ListenerFn,
            user_data: *anyopaque,
        };

        items:     std.ArrayList(Listener),
        allocator: std.mem.Allocator,

        // ... メソッド
    };
}

pub const ChangeListenerList = ListenerList(ChangeEvent);
pub const ActionListenerList = ListenerList(ActionEvent);
```

`ChangeEvent` / `ActionEvent` は発火時に全リスナーへ渡る通知。`source` は発火した Model
（Model は Component から独立し共有もされ得るので、source は widget ではなく Model。
Swing の `EventObject.getSource` と同じ）。`awt.Event`（生の入力イベント）とは別物の高レベル通知で、
リスナー呼び出し中のみ有効（ポインタを保持しないこと）。

2 つは**別の型**であり、ハンドラのシグネチャがどちらを受け取るかを表す（Swing の
`ChangeEvent` / `ActionEvent` 分割と同じ）。両者は同一レイアウト（`source` だけ）だが、
型で意味（change か action か）を区別するのが設計の要点。`change` / `action` を見分けるための
タグフィールドは持たない。

`ListenerList(E)` は Model が embed して使うリスナー管理プリミティブで、change 用の
`ChangeListenerList` と action 用の `ActionListenerList` の 2 つに具体化される。
生の `add` / `remove` / `fire` に加え、`*anyopaque` キャストを消した型付きの
`addTyped` / `removeTyped` を提供する。以下のメソッド定義は具体化された型（例 `ChangeListenerList`）
のものとして示す。`Event` はその型が配送するイベント型（`ChangeListenerList` なら `ChangeEvent`）。

## リスナーリストの生成
```zig
pub fn init(allocator: std.mem.Allocator) ChangeListenerList;
```

空のリストを返す。内部の動的アロケーションは最初の `add` 呼び出しまで遅延される。

## リスナーリストの破棄
```zig
pub fn deinit(self: *ChangeListenerList) void;
```

`items` の内部バッファを解放する。
登録されているリスナー自身の所有物（user_data の指す先など）には触れない。

## リスナーの登録
```zig
pub fn add(self: *ChangeListenerList, fn_ptr: ListenerFn, user_data: *anyopaque) !void;

pub fn addTyped(
    self: *ChangeListenerList,
    comptime T: type,
    comptime f: fn (*T, *const Event) void,
    user_data: *T,
) !void;
```

`add` は生の `(fn_ptr, user_data)` を追加する（重複検査なし）。
`addTyped` は型付きコールバック（`*T` を直接受け取りキャスト不要）を登録する**推奨経路**。
`*anyopaque` → `*T` のキャストは `ListenerList` 内の 1 か所（comptime サンク）だけに書かれる
（`doc/internal/typed_callbacks.md` 参照）。サンクは `(T, f)` ごとに同一の関数ポインタを生むので、
`removeTyped` に同じ `(T, f, user_data)` を渡せば一致削除できる。

## リスナーの削除
```zig
pub fn remove(self: *ChangeListenerList, fn_ptr: ListenerFn, user_data: *anyopaque) void;

pub fn removeTyped(
    self: *ChangeListenerList,
    comptime T: type,
    comptime f: fn (*T, *const Event) void,
    user_data: *T,
) void;
```

`(fn_ptr, user_data)`（typed は `(T, f, user_data)`）と一致するエントリを 1 つ削除する。
見つからない場合は何もしない（エラーにしない）。

## 変更通知の発火
```zig
pub fn fire(self: *ChangeListenerList, event: *const Event) void;
```

`event` を渡しつつ、登録されている全リスナーを**登録順**で呼ぶ。
発火中にリスナーが `add` / `remove` を呼んでもこの発火呼び出し中には反映されない（次回発火から有効）。
Model は自分を `source` にした `Event` を組み立てて渡す（下記テンプレの `fireChange` 参照）。

## 利用例
新規 Model 定義の最小テンプレ（BoundedRangeModel の擬似コード）。`addChangeListener` は
型付き玄関として `addTyped` に委譲する。

```zig
const listener = @import("listener.zig");
const ChangeListenerList = listener.ChangeListenerList;
const ChangeEvent = listener.ChangeEvent;

pub const BoundedRangeModel = struct {
    min:    i32,
    value:  i32,
    max:    i32,
    extent: i32 = 0,
    change_listeners: ChangeListenerList,

    fn fireChange(self: *BoundedRangeModel) void {
        self.change_listeners.fire(&.{ .source = self });
    }

    pub fn setValue(self: *BoundedRangeModel, v: i32) void {
        const clamped = std.math.clamp(v, self.min, self.max - self.extent);
        if (clamped == self.value) return;   // skip fire when unchanged
        self.value = clamped;
        self.fireChange();
    }

    pub fn addChangeListener(self: *BoundedRangeModel, comptime T: type, comptime f: fn (*T, *const ChangeEvent) void, user_data: *T) !void {
        try self.change_listeners.addTyped(T, f, user_data);
    }

    pub fn removeChangeListener(self: *BoundedRangeModel, comptime T: type, comptime f: fn (*T, *const ChangeEvent) void, user_data: *T) void {
        self.change_listeners.removeTyped(T, f, user_data);
    }
};
```

change と action の両方を持つ Model（`ButtonModel`）は 2 本のリストを持ち、
それぞれ `ChangeEvent` / `ActionEvent` を発火する。

```zig
state_listeners:  ChangeListenerList,   // fire(&.{ .source = self }) -> ChangeEvent
action_listeners: ActionListenerList,   // fire(&.{ .source = self }) -> ActionEvent

pub fn addChangeListener(self: *ButtonModel, comptime T: type, comptime f: fn (*T, *const ChangeEvent) void, user_data: *T) !void { ... }
pub fn addActionListener(self: *ButtonModel, comptime T: type, comptime f: fn (*T, *const ActionEvent) void, user_data: *T) !void { ... }
```

ウィジェット側で install / uninstall にリスナーを仕込むテンプレ。コールバックはキャスト無し・型付き。

```zig
fn install(comp: *Component) void {
    const slider: *Slider = @fieldParentPtr("component", comp);
    slider.model.addChangeListener(Component, onModelChange, comp) catch {};
}

fn uninstall(comp: *Component) void {
    const slider: *Slider = @fieldParentPtr("component", comp);
    slider.model.removeChangeListener(Component, onModelChange, comp);
}

fn onModelChange(comp: *Component, _: *const ChangeEvent) void {
    comp.repaint();   // propagate dirty -> repaint next frame
}
```

アプリ側から直接登録する例（再描画とは別の用途、たとえば validation）。

```zig
fn onSliderChanged(ctx: *MyAppContext, _: *const ChangeEvent) void {
    ctx.recomputeTotal();
}

try slider.model.addChangeListener(MyAppContext, onSliderChanged, &app_ctx);
```

## 機能要望
* バッチ通知（複数 setter 呼び出しを 1 通知にまとめる `Model.beginUpdate` / `endUpdate`）
* PropertyChangeListener 相当（プロパティ単位の細かい通知）
* Model 間の bind ヘルパ（Model A の変化を Model B に反映する標準パターン）
* `ActionEvent` への情報追加（action command 文字列など。現状は `source` のみ）
