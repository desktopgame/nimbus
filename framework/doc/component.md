# component
コンポーネントについての設計ノート。

## 型定義
```zig
pub const Component = struct {
    pub const VTable = struct {
        install:      *const fn (*Component) void,
        uninstall:    *const fn (*Component) void,
        paint:        *const fn (*Component, *awt.Graphics) void,
        processEvent: *const fn (*Component, *const Event) bool,
    };

    vtable:     *const VTable,                  // ★ 書き換え可能 (個別差替 / 一斉差替)
    position:   Point,
    size:       Size,
    parent:     ?*Component,
    container:  ?*Container,                    // Container embed のみ self を指す
    name:       ?[]const u8,                    // Java AWT 互換
    properties: ?std.StringHashMap(Property),   // Swing putClientProperty 互換
    allocator:  std.mem.Allocator,

    // ... メソッド
};
```

※Event は framework/doc/event.md に記載予定。

## プラッガブルな設計
Component を継承した Button, Label などで VTable を独自に実装する。
特にカスタマイズしないのであれば、ユーザーはそのまま Button や Label の機能を使える。
カスタマイズしたいユーザーは自分で VTable を入れ替える必要がある。
これはルックアンドフィールのような一斉に全てのコンポーネントの VTable を入れ替える処理も想定して設計されている。
とはいえ、ルックアンドフィールそのものの設計は nimbus では提供しない。
設計が難しいというのが理由の一つ、
そしてルックアンドフィールそのものではなくルックアンドフィールを後付けできる程度にカスタマイズポイントを露出しておけば
ユーザー側でそれは（必要なら）実装することができる、というのがもう一つの理由。

Componentごとに以下のカスタマイズポイントがある。
- install
- uninstall
- paint
- processEvent
そしてこれを入れ替えられるなら、その上にルックアンドフィールを載せること自体は可能なはず。
どんな形でやるかまではいまは判断できない。

## プロパティ
VTable によってユーザーが好きな処理を入れられるだけでは不十分な場合もある。
例えばコンポーネントが追加で独自の状態を保持して、それがイベントで変化するような場合。
このような場合のために、 `Component.properties` が存在している。

## ライフサイクル
アロケーターで Component を確保、initしたのち、呼び出し側で VTable.install() まで実行すること。
ただし、ファクトリー経由で Component を生成する場合、内部で必要な処理を実行してくれる。
なので、一般的なユースケースにおいてはユーザーが気にすることはない。

factory コード例 (内部):

```zig
pub fn label(self: *Application, text: []const u8) !*Label {
    const lbl = try self.allocator.create(Label);
    lbl.* = Label.init(self.allocator, text);            // ← フィールド初期化
    lbl.component.vtable = &Label.vtable;                // ← デフォルト vtable
    lbl.component.vtable.install(&lbl.component);        // ← 必ず install
    return lbl;
}
```

deinit の前に uninstall を呼び出すのを忘れずに。

## コンポーネントの列挙
コンポーネントを再帰的に辿るとき、コンポーネントかコンテナーか判別できる手段が必要になる。
そのために `Component.container` を使う。

## コンポーネントのデバッグ
コンポーネントに名前をつけることができる。
ルックアップに使えないこともないが、基本的にはダンプ用を想定している。

## VTableの差し替え
差し替え時は必ず uninstall/install が必要。
```zig
pub fn setVTable(self: *Component, new_vt: *const VTable) void {
    self.vtable.uninstall(self);
    self.vtable = new_vt;
    self.vtable.install(self);
}
```

## ルックアンドフィールの想定実装
コンポーネントを再帰的に列挙して、 `setVTable` を行う、というのが想定ではある。
とはいえユーザーの実装なので自由。

## install/uninstall
install を呼んだら必ず uninstall も呼び出さなければならない。