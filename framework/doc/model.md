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

---

## Model の役割
Model は次の 3 つを担う。

1. **状態の保持** — 値そのもの（slider なら min/value/max、button なら pressed/armed/enabled 等）
2. **観測可能性** — 変更を外部から検知できる仕組み（ChangeListener 登録）
3. **共有可能性** — 複数のウィジェットが同じ Model を参照して同じ状態を共有できる

特に 3 が「setter で直接 dirty を立てる」方式と決定的に違う点。
Model があれば「左右に並んだ 2 つの Slider が同じ値を表示する」「アプリコードから `model.setValue(50)` を呼ぶと Slider が自動的に追従する」が表現できる。

## 個別 Model はウィジェット側で定義する
nimbus は汎用的な抽象 Model 型を提供しない。
各 Model は対応するウィジェットの doc で個別に定義する。

| ウィジェット | Model | 主なフィールド |
|---|---|---|
| Slider | `BoundedRangeModel` | `min, value, max, extent` |
| Button | `ButtonModel` | `pressed, armed, rollover, enabled, selected` |
| TextField（将来） | `Document` | テキストバッファ |
| Checkbox（将来） | `ButtonModel`（再利用） | `selected` フィールドを使う |

共通するのは「`ChangeListenerList` を embed する」「変更があったら `fire()` を呼ぶ」だけ。
状態の型 / 変更の意味 / setter の名前は Model 個別に決める。

## 標準的な Model の実装パターン
新規 Model を作るときの標準パターンは以下。

* 状態フィールドを直接フィールドとして持つ
* `change_listeners: ChangeListenerList` を embed する
* setter は「値変更 → 実際に変化したら `change_listeners.fire()` を呼ぶ」の順
* `addChangeListener` / `removeChangeListener` は `change_listeners` への薄いラッパ

setter の中で「変化しなかったら発火しない」が重要（無駄な再描画を防ぐ）。
`if (new_value == self.value) return;` の早期 return を入れる。

## ウィジェットとの連携（install / uninstall で配線する）
ウィジェット本体は Model を**参照するだけ**でリスナー登録のコードは持たない。
リスナーの登録は `Component.vtable.install` で行い、`uninstall` で外す。

これにより：

* **vtable 差し替え（ルックアンドフィール）が安全**: 旧 vtable の `uninstall` がリスナーを外し、新 vtable の `install` が必要なリスナーを付け直す
* **リスナーの寿命が vtable の寿命と一致**: Model にゴーストリスナーが残らない

これは Swing の `ComponentUI.installUI` / `uninstallUI` が `BoundedRangeModel.addChangeListener` を行うパターンと同じ。

## Model の所有モデル
ウィジェットは Model を内部生成して所有することも、外部から受け取って借用することもできる。
両方の入口を提供する。

| 入口 | Model の出所 | 所有者 |
|---|---|---|
| `Widget.create(allocator)` | ウィジェットが内部生成 | ウィジェット |
| `Widget.createWithModel(allocator, *Model)` | 利用者が事前に作って渡す | 利用者 |

ウィジェットの `destroy` は所有フラグを見て、自分が生成した場合のみ Model を解放する。
借用の場合は触らない。

```zig
pub const Slider = struct {
    component:   Component,
    model:       *BoundedRangeModel,
    owns_model:  bool,
    // ...
};
```

## 通知のタイミング
`fire()` は **同期実行**。
setter のスタックの中でリスナーが呼ばれて、setter が return する時点ですべてのリスナーの実行が完了している。

非同期にしたい場合はリスナー側で `EventQueue.invokeLater` を使う。
Model 自体は同期発火の単純な仕様に留める。

## ChangeEvent と専用イベント型
nimbus の `ChangeListener` は引数を持たない（fn ptr の引数は user_data のみ）。
「何が変わったか」を伝える必要があれば、リスナーは user_data 経由で Model のポインタを受け取り、Model の現在値を直接読む。

Swing は変更内容を `DocumentEvent.getOffset()` のように伝えるが、nimbus はシンプルにする。
「変わった、現在値はこれ」だけを観測する。

将来「何が変わったか」を細かく区別したい Model（Document の挿入 / 削除など）が出てきたら、その Model に専用のリスナー型を追加する（`DocumentListener` 等）。
共通プリミティブは `ChangeListenerList` を踏襲できる（fn_ptr の型とイベント型をジェネリック化）。

---

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
