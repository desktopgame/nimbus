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

`add` 時に各 member の `ToggleButtonModel` に group hook (`setGroupHook`) を仕込む。
これにより member が group より先に破棄されても、 member の `deinit` から group が通知を受けて自分の参照を外せる (後述の「寿命」参照)。

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

まだ生きている各 member から `ChangeListener` を解除し、 group hook を外し、 内部の `members` / `prev_selected` を解放する。

**寿命**: group と member (= owning RadioButton / CheckBox / model) の破棄順序はどちらが先でも安全。
- group が先: `deinit` が生きている member の listener を解除する。
- member が先: member の `deinit` が group hook 経由で group に通知し、 group は自分の `members` からその member を取り除く。 そのため後で走る group の `deinit` は freed なモデルに触れない。

これは特に重要で、 GUI アプリでは典型的に `Application.run` がウィンドウ close 時にウィジェットツリー (= radio とそのモデル) を破棄する一方、 `ButtonGroup` は呼び出し側のスタックに残って `run` 復帰後の defer で破棄される。 つまり member が先に死ぬのが普通であり、 hook なしでは use-after-free になっていた。

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
