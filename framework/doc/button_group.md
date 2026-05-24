# button_group
複数の `ToggleButtonModel` を束ねて 「常に 1 個だけ selected」 を保証するヘルパー。
典型的には RadioButton 群に使う。

## 型定義
```zig
pub const ButtonGroup = struct {
    allocator:     std.mem.Allocator,
    members:       std.ArrayList(*ToggleButtonModel),
    prev_selected: std.ArrayList(bool),    // 内部: ChangeListener から「どの member が新たに true になったか」を diff で割り出すための snapshot
    muting:        bool = false,           // 内部: clearOthers 中の listener 再入防止
};
```

`prev_selected` は内部実装の詳細 (`ChangeListener` の signature が source model を渡さないので、 「false → true へ transition した member」 を判定するために spec snapshot を持つ)。

## 生成
```zig
pub fn init(allocator: std.mem.Allocator) ButtonGroup;
pub fn create(allocator: std.mem.Allocator) !*ButtonGroup;
```

`init` は値で返す (caller がスタック / 構造体フィールドに置く)。
`create` はヒープに確保して `*ButtonGroup` を返す (factory 経由)。
Application factory:
```zig
const group = try app.buttonGroup();
defer { group.deinit(); allocator.destroy(group); }
```

## 後片付け
```zig
pub fn deinit(self: *ButtonGroup) void;
```

各 member から `ChangeListener` を解除し、 内部の `members` / `prev_selected` を解放する。

**寿命の注意**: `deinit` は各 member の listener 配列にアクセスする。
member (= owning RadioButton / CheckBox / model) が先に destroy / deinit されていると use-after-free になる。
**ButtonGroup の deinit は member より前** に呼ぶこと。
defer を使う場合、 group の defer を後に書けば LIFO により先に実行される (`widget_radio` example 参照)。

## メンバーの追加
```zig
pub fn add(self: *ButtonGroup, model: *ToggleButtonModel) !void;
```

`model` をグループに加えて、 selected 変化を tracking する `ChangeListener` を仕込む。
追加時点で既に `model.isSelected() == true` の場合、 グループ内の他の selected メンバーを自動で false にする (= 後勝ち)。

## メンバーの削除
```zig
pub fn remove(self: *ButtonGroup, model: *ToggleButtonModel) void;
```

指定 model をグループから外す (idempotent)。
listener も解除する。

## 現在の選択取得
```zig
pub fn getSelected(self: ButtonGroup) ?*ToggleButtonModel;
```

現在 selected なメンバーを返す。 1 つも selected でなければ null。

---

## 動作
member のどれかが `setSelected(true)` で false → true へ transition した瞬間、 group が listener を介して検知し、 **他の全 member を `setSelected(false)`** で deselect する。
1 サイクル内で複数 transition が起きても (`add` 直後のクリア処理など)、 `muting` フラグで再入を防いで O(n) で完了する。

何も selected でない状態 (= 全 member off) は許容する。
利用者が `model.setSelected(false)` で現在の選択を解除した場合、 group は新規 winner を選び直さない (= 「一度ピックしたら戻せない」 仕様の Swing JButtonGroup とは異なる、 nimbus は permissive)。

「最低 1 個は selected であってほしい」 場合は、 利用者が `RadioButton` を直接使えばよい。
RadioButton の `processEvent` は「クリックで `selected = true` を強制」 する (= toggle ではない) ので、 ユーザー操作でグループ全 off にはならない。

## ChangeListener の signature 制約
`ChangeListener` の callback は `(user_data: *anyopaque) -> void` だけで、 「どの model が変化したか」 を直接渡さない。
このため group は自前で「前回の selected 状態」 を `prev_selected` に持って差分で source model を判定する。
将来 `ChangeListener` が source を渡せるようになれば snapshot は不要になる (機能要望)。

## 機能要望
* グループに「最低 1 個 selected を強制する」 モード (Swing JButtonGroup の挙動)
* グループの ActionListener (どの member が選ばれても 1 個の listener で通知)
* ChangeListener の signature 拡張で `prev_selected` snapshot を不要に
