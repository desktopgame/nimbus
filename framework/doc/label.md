# label
ラベルについての設計ノート。テキストを 1 行描画するだけのもっとも単純な widget。

v1 で唯一のビルトイン leaf widget として、Component / Container / vtable 周りの動作検証も兼ねる。

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

## 役割
- テキスト 1 行を `(0, 0)` (component ローカル) を起点に描画
- フォント・色は setter で動的変更可能
- `preferredSize` でテキストの自然なサイズを返す (将来 LayoutManager 用)

## 描画
vtable.paint は単純に Graphics の API を叩く:

```zig
fn paint(self: *Component, g: *awt.Graphics) void {
    const label: *Label = @fieldParentPtr("component", self);
    g.setFont(label.font);
    g.setColor(label.color);
    g.drawString(label.text, 0, 0);  // top-of-bbox at component origin (graphics.md の方針)
}
```

`\n` を含む文字列は `drawString` 側で無視される (graphics.md 通り)。複数行描画は v2 で
別 widget (TextArea / MultilineLabel) として扱う。

## install / uninstall
ビルトイン Label の install/uninstall は no-op。Label 自身の状態 (text / font / color) は
`Label.init` で全部セットされる。 install hook は「カスタム vtable がプロパティに自前 state を
登録したい」場合のためにあるもので、ビルトインでは使わない (component.md 参照)。

## text の所有
Label が `allocator.dupe` で複製を持つ。setter は古い text を free して新しい dup を保持する。

```zig
pub fn setText(self: *Label, text: []const u8) !void {
    const new_text = try self.allocator.dupe(u8, text);
    self.allocator.free(self.text);
    self.text = new_text;
    self.component.repaint();
}
```

理由: Swing JLabel の String と同じ「Label が持つ」セマンティクス。ユーザーは文字列の寿命を
考えずに `label.setText("hello")` を書ける。コストは数十バイトの memcpy なので無視できる。

ユーザーが寿命を保証できるケース (literal `"hello"` や静的バッファ) で dup を avoid したい場合は、
将来 `setTextBorrowed(text)` を追加する余地はある。v1 では一律 dup で割り切る。

## font と color
font は値型 `awt.Graphics.TextFont = { face: *awt.Font, pixel_size: i32 }`。
Label は値で持ち、`face` ポインタは Application 寿命の `default_font` を借用する。

```zig
pub fn setFont(self: *Label, font: awt.Graphics.TextFont) void {
    self.font = font;
    self.component.repaint();
}

pub fn setColor(self: *Label, color: awt.Graphics.Color) void {
    self.color = color;
    self.component.repaint();
}
```

初期値は Application のデフォルト (default_font + 黒) を factory で注入する。

## preferredSize
font の metrics と text 長さから「テキストが自然に収まるサイズ」を返す。
v1 では LayoutManager が無いので使われないが、将来のために生やしておく。

```zig
pub fn preferredSize(self: Label) Size {
    return self.font.measureString(self.text).asSize();
}
```

## ライフサイクル
factory コード例 (内部):

```zig
pub fn label(self: *Application, text: []const u8) !*Label {
    const lbl = try self.allocator.create(Label);
    lbl.* = try Label.init(self.allocator, text, self.default_font, awt.Graphics.Color.rgb(0, 0, 0));
    lbl.component.vtable = &Label.vtable;
    lbl.component.vtable.install(&lbl.component);
    return lbl;
}
```

`Label.init` は text を `allocator.dupe` で複製する。失敗時は `allocator.create` で確保したメモリを
解放してエラーを返す責任を持つ (awt-c の Create 関数失敗時セマンティクスと同様、強い例外保証)。

deinit では:
1. `component.deinit()` で uninstall + properties cleanup
2. `allocator.free(self.text)` で text の dup を解放

順序は `component.deinit` が先 (vtable.uninstall がプロパティを参照する可能性があるため)。

Label 自身のメモリ解放は `vtable.destroy` が担当する (component.md「メモリ解放」参照)。
`Label.destroy` は `@fieldParentPtr` で外側に戻し、`label.deinit()` + `allocator.destroy(label)` を呼ぶ:

```zig
fn destroy(self: *Component, allocator: std.mem.Allocator) void {
    const label: *Label = @fieldParentPtr("component", self);
    label.deinit();
    allocator.destroy(label);
}
```

Container が子として保持している Label については、Container.deinit が
`elem.component.vtable.destroy(elem.component, self.allocator)` を呼ぶことで
この経路を通って free される。

## v1 のスコープ

| 機能 | v1 でやる? | 備考 |
|---|---|---|
| 1 行テキスト描画 | やる | top-of-bbox at (0, 0) |
| setText / setFont / setColor | やる | setter で repaint |
| preferredSize | やる | font.measureString。LayoutManager 無いので使い手は無し |
| 改行 (`\n`) 対応 | やらない | drawString が無視。複数行は別 widget で |
| horizontal / vertical alignment | やらない | v2 で SwingConstants 相当を導入 |
| icon / image 同時表示 | やらない | Swing JLabel の icon 機能。v2 以降 |
| HTML / rich text | やらない | スコープ外 |
| mnemonic / accelerator | やらない | キーイベント整備後 (v2 以降) |

## 拡張ポイント
ユーザーがビルトイン Label の見た目を変えたい時は (component.md / lookandfeel.md の方針通り):

- **個別差替**: `lbl.component.setVTable(&my_label_vt)` で 1 個だけ paint を差替
- **一斉差替**: `app.replaceVTable(&Label.vtable, &my_label_vt)` で全 Label を差替
- **新型を作る**: `MyLabel = struct { label: Label, ... }` で struct embed して独自 paint
- **setter で個別調整**: setColor / setFont で済む範囲

framework としては Label 自身に theme / L&F 機構を入れない。
