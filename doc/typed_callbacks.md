# typed-callbacks
nimbus のコールバック API を、C_ABI 互換を保ったまま Zig 層で型付きにする仕組み。
**実装済み (2026-05-31)。** `ChangeListenerList` に `addTyped`/`removeTyped`（comptime サンク）を追加し、
全 Model（`addChangeListener`/`addActionListener` 等）・全 widget の内部コールバック・全 examples を
型付き形へ移行した。同時にリスナー署名へ意味イベント（`*const Event`、`source = Model`）を追加した
（`framework/doc/model.md`）。保存・dispatch する形は `fn(*anyopaque, *const Event)` のままなので
C_ABI codegen はこれをそのまま使える。

## 動機
examples のブラインドレビューで最頻出かつ最も危険と指摘された点。
すべてのコールバックが次の一行で始まる。

```zig
const self: *State = @ptrCast(@alignCast(user_data));
```

登録側も毎回 `addActionListener(onClick, @ptrCast(&state))` のようにキャストを書く。
これは全 example・全コールバックに現れる定型で、しかも**型安全でない**。
実際 `widget_dialog` では同じ `*anyopaque` を `*Dialog` と `*State` の 2 つの型に取り違えてキャストしうる構造になっている（コンパイラは検出できない）。

## 2 つのレイヤーを混同しないこと
この問題は「レイヤー」を分けると判断が変わる。

* **C_ABI 層**（`{REPO_ROOT}/framework/src/c_api.zig` の `nimbus_*` エクスポート）
  コールバックは `fn(void*) + void* userdata` が**必須**。バインディングの契約そのもの。
  ここでの `void*` は死守する（型付きにはしない）。
* **Zig ネイティブ層**（examples が呼ぶ層。`app.button` / `addActionListener` など）
  これは C_ABI **ではない**。examples は Zig プログラムが Zig フレームワークを直接呼んでいるだけで、C_ABI の制約はかからない（Zig には comptime も `@fieldParentPtr` もある）。
  現状ここで `void*` + cast にしているのは「API を C_ABI と同じ形に寄せた設計選択」であって、C_ABI が強制しているわけではない。

つまり「型付き vs C_ABI」という二者択一ではない。

## 方針：Zig 層に型付き玄関を被せ、保存形は変えない
Zig 層に薄い型付き玄関を 1 枚足す。**保存・dispatch する形は今のまま `fn(*anyopaque) + *anyopaque` に保つ**。
これにより C_ABI codegen は無変更で、ABI 整合も保たれる（PyO3 / napi と同じ「ネイティブは型付き、下層は `void*`」）。
バインディング方針（C_ABI は契約だが生成物、Zig が真実 = `doc` のバインディング方針）とも整合する。

実装された comptime サンク（`ChangeListenerList`）:

```zig
fn thunk(comptime T: type, comptime f: fn (*T, *const Event) void) ListenerFn {
    return struct {
        fn call(p: *anyopaque, e: *const Event) void {
            f(@ptrCast(@alignCast(p)), e);   // キャストはここ 1 か所だけ
        }
    }.call;
}

pub fn addTyped(self: *ChangeListenerList, comptime T: type, comptime f: fn (*T, *const Event) void, user_data: *T) !void {
    try self.add(thunk(T, f), user_data); // 保存形は fn(*anyopaque, *const Event)+*anyopaque のまま
}
pub fn removeTyped(self: *ChangeListenerList, comptime T: type, comptime f: fn (*T, *const Event) void, user_data: *T) void {
    self.remove(thunk(T, f), user_data);   // (T,f) ごとに同一の関数ポインタ → 一致削除できる
}
```

各 Model はこれに委譲する型付き玄関（`addChangeListener` 等）を持つ。利用者・widget は
`fn (s: *State, e: *const Event) void` を書くだけでよく、`*anyopaque` のキャストは現れない。

* キャストは**フレームワークが 1 回だけ**書く（サンク）。利用者のコールバックは `fn(s: *State) void` でキャスト無し・型安全。
* 保存・dispatch 形は不変なので C_ABI シム / codegen はそのまま生の登録を使える。
* `widget_dialog` のような「同じ `void*` を別の型に取り違える」事故が**構文的に起きなくなる**（型付き化の一番の根拠）。

## 適用範囲
`ChangeListenerList` と、それを使う各 widget の登録メソッド。現状リスナー登録経路自体が widget ごとにバラついているので（後述）、型付き化はその統一とセットで行うと効果が高い。

* action: Button / CheckBox / RadioButton / MenuItem（`getModel().addActionListener`）
* change: Slider / ScrollBar（`getModel().addChangeListener`）、ComboBox / List / ScrollPane（widget 直）
* TextField: `addSubmitListener` / `addCancelListener`
* List のセル: `Cell.update` / `Cell.destroy`、`CellFactory.create`
* DnD: `DragSource` / `DropTarget` のコールバック

ただし最後の 2 つ（セル・DnD）は「登録メソッド」ではなく**構造体フィールドに `fn(*anyopaque) + user_data` を直接書く**形なので、同じ型付け方が素直には当たらない。別途検討する（下記）。

## 実装時に決めること
* 生の `void*` 登録 API を残すか、型付きを既定にして生を `addRaw…` に回すか。
* capability 構造体（`DropTarget` 等、コールバックが登録メソッドでなくフィールド）の型付けをどうするか。
  `user_data` が外側 widget 自身であるケースは `@fieldParentPtr` で cast 自体を無くせる可能性がある。
* リスナー登録経路の不統一（widget 直 vs `getModel()` 経由）の統一と同時にやるか、分けるか。

## 関連
* ブラインドレビューの横断指摘 #1（このキャスト定型）と #3（リスナー登録経路の不統一）。両者はセットで扱うのが自然。
* 「as Component」統一（#4）・`add` 統一（#2）と並ぶ API 安定化の High 項目。
* バインディングの codegen 方針（C_ABI は生成物、Zig が真実）。本計画はその方針の具体例。
