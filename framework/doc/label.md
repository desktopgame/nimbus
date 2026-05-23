# label
ラベルについての設計ノート。
テキストを 1 行描画するだけのもっとも単純な leaf ウィジェット。
v1 で唯一のビルトイン leaf ウィジェットとして、Component / Container / vtable 周りの動作検証も兼ねる。

## 型定義
```zig
pub const Label = struct {
    component: Component,
    text:      []const u8,           // Label が所有 (allocator で dup)
    font:      awt.Graphics.TextFont,
    color:     awt.Graphics.Color,

    pub const vtable = Component.VTable{
        .install      = install,
        .uninstall    = uninstall,
        .paint        = paint,
        .processEvent = noopEvent,
        .destroy      = destroy,
    };

    // ... メソッド
};
```

## ラベルの生成
```zig
pub fn create(
    allocator: std.mem.Allocator,
    text: []const u8,
    font: awt.Graphics.TextFont,
    color: awt.Graphics.Color,
) !*Label;
```

allocator で `Label` を確保し、`text` を dup して所有し、vtable をセット、install まで実行して返す。
`component.min_size` は `font.measureString(text)` から算出してセットされる。

### 事前条件
* `font.face` の寿命が Label と同じか長いこと（通常は Application の `default_font` を借用）

### 失敗時の保証
途中で失敗した場合、`create` 内で確保したメモリはすべて関数内で解放される。
呼び出し側に後片付け責任は発生しない（awt-c の `nmCreateXxx` と同じセマンティクス）。

## ラベルの破棄
```zig
fn destroy(self: *Component, allocator: std.mem.Allocator) void;
```

`Label.vtable.destroy` として登録される。
`@fieldParentPtr` で外側の `*Label` に戻し、内部状態を解放して `allocator.destroy(label)` まで行う。

利用者が直接呼ぶ機会は通常無い。
Container に add された Label は、Container.deinit が `elem.component.vtable.destroy(...)` を通じてこの経路を起動する。
スタンドアロンで使うなら `label.component.vtable.destroy(&label.component, allocator)` を呼ぶ。

## テキストの取得
```zig
pub fn getText(self: Label) []const u8;
```

Label が保持している text の slice を返す。
ポインタは Label が deinit されるまで有効。

## テキストの更新
```zig
pub fn setText(self: *Label, text: []const u8) !void;
```

引数の `text` を dup し直して古いものを free する。
`component.min_size` を新しい text の寸法で再計算する。
レイアウト変化と再描画は `setMinSize` が自動で dirty を立てるので、別途 repaint 不要。

## フォントの取得
```zig
pub fn getFont(self: Label) awt.Graphics.TextFont;
```

## フォントの設定
```zig
pub fn setFont(self: *Label, font: awt.Graphics.TextFont) void;
```

`font` を保持し、現在の text を新しい font で測りなおして `component.min_size` を再計算する。

## 色の取得
```zig
pub fn getColor(self: Label) awt.Graphics.Color;
```

## 色の設定
```zig
pub fn setColor(self: *Label, color: awt.Graphics.Color) void;
```

`color` を保持して再描画を要求する。
レイアウトには影響しない（dirty は paint のみ）。

---

## text の所有
text は Label が `allocator.dupe` で複製して所有する。
利用者は文字列の寿命を気にせず `label.setText("hello")` のような literal も渡せる。
コストは数十バイトの memcpy なので無視できる。

Swing `JLabel` の `String` と同じ「ラベルが持つ」セマンティクスである。

## MinimumSize の自動算出
Label は `component.min_size` を「現在の text を現在の font で描画したときに必要な寸法」に保つ責任を負う。
更新タイミングは次の 3 箇所のみ。

* `create` — 初期値から算出してセット
* `setText` — 新しい text の寸法を測ってセット
* `setFont` — 新しい font で現在の text の寸法を測ってセット

利用者がさらに大きな下限を指定したい場合は `component.setMinSize(...)` で上書きできるが、その後 `setText` / `setFont` を呼ぶと Label が再計算した値で上書きされる。
`max_size` / `grow_x` / `grow_y` は Label からは触らない（利用者が `Component` の setter で設定する）。

## 描画
`vtable.paint` は `Graphics` に対して font / color を設定したのち、`drawString` を `(0, 0)` を起点に呼ぶ。
`(0, 0)` は component ローカル座標で、`graphics.md` の方針に従って top-of-bounding-box が原点に合う。

`\n` を含む文字列は `drawString` が無視する（`graphics.md` 参照）。
複数行描画は別ウィジェット（TextArea 等）として扱う方針。

## install / uninstall
ビルトイン Label の install / uninstall は no-op。
Label の状態（text / font / color）はすべて `create` でセット済みであり、install hook は「カスタム vtable がプロパティに自前 state を登録したい」場合のための拡張点である（component.md 参照）。

## ライフサイクル
`create` が allocator 確保・init・vtable 登録・install をひとまとめに行う（component.md「ライフサイクル」と同じ pattern）。
Application 経由のファクトリ `app.label(text)` は `create` をラップして default_font と黒色を注入する（application.md 参照）。

破棄経路は `vtable.destroy` 経由（component.md「メモリ解放」参照）。
内部の deinit 順序は `component.deinit()` → `allocator.free(text)`。
`component.deinit` が先である理由は `vtable.uninstall` がプロパティを参照する可能性があるため。

## 拡張ポイント
ビルトイン Label の見た目を変えたい場合の選択肢（component.md / lookandfeel.md の方針に従う）。

* **個別差替**: `lbl.component.setVTable(&my_label_vt)` で 1 個だけ paint を差替
* **一斉差替**: `app.replaceVTable(&Label.vtable, &my_label_vt)` で全 Label を差替
* **新型を作る**: `MyLabel = struct { label: Label, ... }` で struct embed して独自 paint
* **setter で個別調整**: setColor / setFont で済む範囲

framework としては Label 自身に theme / L&F 機構を入れない。

## 利用例
Application 経由の典型コード。

```zig
var app = try nimbus.Application.init(allocator);
defer app.deinit();

const frame = try app.frame("hello", 800, 600);

const label = try app.label("こんにちは!");
label.setColor(awt.Graphics.Color.rgb(1, 0, 0));      // 赤に変更
try frame.window.add(&label.component);

// 後からテキスト更新
try label.setText("更新後");

try app.run();
```

直接 `Label.create` を使うパターン（Application 経由でない場合、例えばテストやスタンドアロン描画）。

```zig
const label = try Label.create(
    allocator,
    "framework Label",
    .{ .face = font, .pixel_size = 24 },
    awt.Graphics.Color.rgb(1, 1, 0),
);
defer label.component.vtable.destroy(&label.component, allocator);

label.component.setBounds(.{ .x = 30, .y = 30, .width = 400, .height = 32 });
// あとは container に add するか、直接 paintAt(&g) で描画
```

Component メソッド（`setBounds` 等）は委譲を生やしていないので、`label.component.setBounds(...)` の形で親フィールド経由で呼ぶ（component.md「派生型から Component メソッドへのアクセス」参照）。

## 機能要望
* 改行 (`\n`) 対応 — 現状 `drawString` が無視するため対応なし。複数行は別ウィジェットで扱う
* horizontal / vertical alignment — SwingConstants 相当を導入
* icon / image 同時表示 — Swing `JLabel` の icon 機能
* HTML / rich text — 当面スコープ外
* mnemonic / accelerator — キーイベント整備後
* `setTextBorrowed(text)` — 利用者が寿命を保証できるケースで dup を回避するための入口
