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
        destroy:      *const fn (*Component, std.mem.Allocator) void,
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
- destroy
そしてこれを入れ替えられるなら、その上にルックアンドフィールを載せること自体は可能なはず。
どんな形でやるかまではいまは判断できない。

(`destroy` は L&F カスタマイズというよりは内部的な責務分担。後述「メモリ解放」を参照。)

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

## メモリ解放
Container が子を解放するとき、 `allocator.destroy(child)` で素直に free できないのが Zig の制約。
`child` の型は `*Component` だが、実体は外側の widget (Label, Button など) で、
`allocator.destroy` は引数の静的サイズ (sizeof Component) しか free しない。
このままだと Label 固有のフィールドぶんが leak する。

そのため VTable に `destroy` を持ち、各 widget が自前で `@fieldParentPtr` を使って
外側のサイズで free する責務を負う。

```zig
// Label.destroy 例
fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const label: *Label = @fieldParentPtr("component", self);
    label.deinit();                  // text の free 等、widget 固有の cleanup
    allocator.destroy(label);        // 正しいサイズで free
}
```

`Component.deinit` 自体はメモリ解放を行わない (uninstall + properties cleanup まで)。
メモリ解放は `vtable.destroy` の責務。Container.deinit はこれを順番に呼ぶ。
ファクトリー経由で生成された widget をユーザーが自分で free する場合も
`component.vtable.destroy(&comp, allocator)` を呼ぶのが正規ルート。

## コンポーネントの列挙
コンポーネントを再帰的に辿るとき、コンポーネントかコンテナーか判別できる手段が必要になる。
そのために `Component.container` を使う。

## コンポーネントのデバッグ
コンポーネントに名前をつけることができる。
ルックアップに使えないこともないが、基本的にはダンプ用を想定している。

## setter / getter の方針
書き換え可能なプロパティは **setter / getter をペアで提供する** (Swing 流の対称性)。

| 用途 | 方法 |
|---|---|
| 書き換え (副作用あり) | `setXxx(...)` 必須。内部で dup / repaint / (将来) PropertyChangeEvent 等を行う |
| 読み (副作用なし) | `getXxx()` が公式。フィールド直接 read もショートカットとして許容 (Zig 慣用) |

Zig はフィールド単位の private 修飾子を持たないので、 言語レベルでフィールド直接 write を禁止することはできない。
しかし「副作用を必要とする書き換え」は setter 経由しないと壊れる (例: text の単純代入は旧 text が leak)。
このため:

- **read**: getter 経由 / 直接 read どちらも可
- **write**: setter 必須 (直接 write は禁止 — doc / レビューでカバー)

将来 PropertyChangeListener (Swing の PCE 相当) を v2 で導入する余地を残している。
入った時に setter が listener 通知を担う。

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