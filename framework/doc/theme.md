---
unsafe: true
---

# theme
既定ルックアンドフィールが描画時に参照する色のカタログ (`theme.zig`)。
public な固定 struct であり、自前 LAF (vtable 差し替え) からも参照できる。
設計の経緯・却下案は [narrative/theme.md](narrative/theme.md) を参照。

**注記: 本ドキュメントは実装に先行する設計版である（実装時にこの注記を外す）。**

## 型定義
```zig
const Color = awt.Graphics.Color;

pub const Theme = struct {
    // ── 役割トークン（複数ウィジェット横断。テーマ作者が主に触る面）──
    accent:           Color = Color.rgb(0.30, 0.55, 0.95), // 選択・チェック・focus border・slider thumb 等
    accent_soft:      Color = Color.rgb(0.90, 0.93, 0.99), // メニュー hover 背景
    selection_bg:     Color = Color.rgb(0.80, 0.87, 0.98), // List 選択行
    focus_ring:       Color = Color.rgb(0.25, 0.45, 0.85), // フォーカスリング
    text:             Color = Color.rgb(0.10, 0.10, 0.10), // 通常テキスト
    text_disabled:    Color = Color.rgb(0.55, 0.55, 0.55),
    text_on_accent:   Color = Color.rgb(1.00, 1.00, 1.00), // 選択中メニュー文字・チェックマーク
    surface_window:   Color = Color.rgb(0.94, 0.94, 0.94), // ウィンドウ / メニューバー / Panel 背景
    surface_input:    Color = Color.rgb(1.00, 1.00, 1.00), // TextField / List / popup / ComboBox 背景
    surface_disabled: Color = Color.rgb(0.93, 0.93, 0.93),
    border:           Color = Color.rgb(0.55, 0.55, 0.55), // 入力欄・popup の枠
    border_soft:      Color = Color.rgb(0.78, 0.78, 0.82), // メニューバー下線等の弱い枠
    separator:        Color = Color.rgb(0.75, 0.75, 0.78),
    indicator_border: Color = Color.rgb(0.50, 0.50, 0.50), // CheckBox 四角 / RadioButton 円の枠

    // ── ウィジェット別（役割トークンに畳むと意味が変わる面）──
    button_bg:             Color = Color.rgb(0.85, 0.85, 0.90),
    button_bg_hover:       Color = Color.rgb(0.92, 0.92, 0.97),
    button_bg_armed:       Color = Color.rgb(0.55, 0.65, 0.85), // 意図的に accent より淡い
    button_bg_disabled:    Color = Color.rgb(0.75, 0.75, 0.78),
    button_flat_hover:     Color = Color.rgb(0.88, 0.88, 0.92),
    button_flat_armed:     Color = Color.rgb(0.78, 0.82, 0.92),
    scrollbar_track:       Color = Color.rgb(0.88, 0.88, 0.90),
    scrollbar_thumb:       Color = Color.rgb(0.62, 0.62, 0.66),
    scrollbar_thumb_hover: Color = Color.rgb(0.48, 0.48, 0.52),
    slider_track:          Color = Color.rgb(0.70, 0.70, 0.75),
    ime_preedit_underline: Color = Color.rgb(0.40, 0.40, 0.40), // TextField / TextArea 共有
    ime_preedit_target:    Color = Color.rgb(0.20, 0.20, 0.20),

    /// ビルトインの既定テーマ。全フィールドの既定値そのもの。
    pub const default = Theme{};
};
```

全フィールドが既定値を持つため、テーマ定義は**差分だけ**書けばよい
（`Theme{ .accent = ..., .surface_window = ... }` — 触らないフィールドは既定ルックのまま）。

メトリクス（角丸半径・パディング等）は v1 では含めない。実需が出たら additive に
フィールドを追加する（テーマは起動時固定のため、生成時に `min_size` へ焼き込まれる
メトリクスとも矛盾しない）。

### Component との関係
```zig
// Component への追加フィールド
theme: *const Theme = &Theme.default,
```

各コンポーネントは**単一の Theme への参照を 1 本だけ**持つ。既定値は comptime 定数
`Theme.default`（immutable データであり、可変グローバルではない）。
`Application` のファクトリが生成時に `&app.theme` を注入する（DI）。
ファクトリを通さず `create` を直接呼んだコンポーネントは既定テーマで描画される
（壊れない・呼び順の罠なし）。

vtable 差し替えで paint を書く自前 LAF も `component.theme` を読んでよい
（読めばアプリのテーマ設定に追従する）。読まない LAF も存在できる —
Theme は公開基盤であって契約ではない。

## 関数定義

### テーマ付きの Application 初期化
```zig
pub fn initWithTheme(allocator: std.mem.Allocator, io: std.Io, theme: Theme) !*Application;
```

`Application.init` と同じ初期化を行い、`theme` を**値でコピーして**保持する
（以後、ファクトリが生成する全ウィジェットは `&app.theme` を参照する）。
渡した `theme` 変数の寿命は呼び出し後は問わない（コピーされるため）。
既存の `init` はビルトイン既定テーマで動作する。

### 事前条件
* テーマは起動時固定。`initWithTheme` 以後にテーマを変更する手段は提供されない
  （切り替えはアプリ再起動で行う。理由は [narrative/theme.md](narrative/theme.md)「実行中切り替えを非対応にした理由」）。

---

## 利用例
ダーク系テーマの差分定義。

```zig
pub fn main(init: std.process.Init) !void {
    const dark = nimbus.Theme{
        .surface_window   = Color.rgb(0.13, 0.13, 0.14),
        .surface_input    = Color.rgb(0.18, 0.18, 0.20),
        .surface_disabled = Color.rgb(0.16, 0.16, 0.17),
        .text             = Color.rgb(0.92, 0.92, 0.92),
        .text_disabled    = Color.rgb(0.50, 0.50, 0.50),
        .border           = Color.rgb(0.35, 0.35, 0.38),
        // 触らないフィールド（accent 等）は既定のまま
    };
    const app = try nimbus.Application.initWithTheme(init.gpa, init.io, dark);
    defer app.deinit();
    // 以後のファクトリ生成ウィジェットはすべて dark で描画される
}
```

自前 LAF（vtable 差し替え）からの参照。

```zig
fn myPaint(self: *Component, g: *awt.Graphics) void {
    const t = self.theme; // アプリのテーマ設定に追従したければ読む。独自の見た目なら無視してよい
    g.setColor(t.accent);
    // ...
}
```

## 機能要望
* メトリクス（角丸半径・パディング・ボーダー幅等）の Theme 化
* 実行中のテーマ切り替え（全ツリーの re-metrics + 再レイアウトの無効化プロトコルが本体。実需待ち）
* C ABI への露出（capi バックログ。struct 引数対応に依存。getter/setter 関数で包む案あり）
* ビルトインのダークテーマプリセット（`Theme.dark` のような提供）
