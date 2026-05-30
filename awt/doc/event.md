---
unsafe: true
---

# event
入力イベントの型定義。
キー入力、テキスト入力、マウス入力、フォーカス変更を表現する `Event` と、消費フラグ・座標変換のサポートを提供する。
イベントループ自体は awt-c の `nmPollEvents` / `nmWaitEvents` が担当する（`awt-c/doc/event.md` 参照）。
イベントを実際にコンポーネントへ dispatch するのは framework 層の責務。

## 型定義
```zig
pub const Event = struct {
    consumed:       bool        = false,
    capture_target: ?*anyopaque = null,  // マウスキャプチャ要求の格納先 (詳細は「マウスキャプチャ」参照)
    payload:        Payload,

    pub const Payload = union(enum) {
        key:         KeyEvent,
        char:        CharEvent,
        mouse:       MouseEvent,
        focus:       FocusEvent,
        composition: CompositionEvent,
    };

    // ... メソッド
};

pub const KeyEvent = struct {
    code:      KeyCode,
    action:    KeyAction,
    modifiers: Modifiers,
};

pub const CharEvent = struct {
    codepoint: u32,                // OS キーボードレイアウト適用後の Unicode codepoint
};

pub const FocusEvent = struct {
    gained: bool,                  // true: フォーカス獲得, false: 喪失
};

pub const CompositionEvent = struct {
    text:         []const u8,      // 借用 UTF-8 (callback の有効期間のみ)
    target_start: usize,           // text 内の byte offset (変換中クローズの開始)
    target_end:   usize,           // text 内の byte offset (変換中クローズの終了)
};

pub const MouseEvent = struct {
    x:         f32,            // ウィンドウ左上 (0, 0) からの座標
    y:         f32,
    button:    ?MouseButton,   // press / release のときのみ non-null
    action:    MouseAction,
    wheel:     f32,            // scroll のときのみ non-zero (正で上方向)
    modifiers: Modifiers,

    // ... メソッド
};

pub const KeyCode    = enum(i32) { /* GLFW キーコードに対応 */ };
pub const KeyAction  = enum { press, release, repeat };
pub const MouseButton = enum { left, middle, right };
pub const MouseAction = enum { press, release, move, scroll };

pub const Modifiers = packed struct {
    shift: bool = false,
    ctrl:  bool = false,
    alt:   bool = false,
    meta:  bool = false,    // macOS の cmd、Linux の super
    _pad:  u4   = 0,
};

pub const Point = struct { x: f32, y: f32 };
```

## イベントの消費
```zig
pub fn consume(self: *Event) void;
```

`consumed` フィールドを true にする。
framework のイベント dispatcher は親へのバブリング中に消費済みを検知して伝搬を止める。

## 消費済みかの確認
```zig
pub fn isConsumed(self: Event) bool;
```

`consumed` の getter。
直接フィールド read もショートカットとして許容（Zig 慣用）。

## マウスイベントの座標変換
```zig
pub fn translated(self: MouseEvent, offset: Point) MouseEvent;
```

`x` / `y` から `offset` を引いた新しい `MouseEvent` を返す。
元のイベントは変更されない。
他のフィールド（button / action / wheel / modifiers）はそのままコピー。

framework 層はこの helper を使って、コンポーネントツリーを下る際に絶対ウィンドウ座標から各コンポーネントのローカル座標へ変換する。
ローカル座標とは「コンポーネントの bounds 左上を (0, 0) としたときの座標」を指す。

## イベント全体の座標変換
```zig
pub fn translated(self: Event, offset: Point) Event;
```

`payload` が `.mouse` ならその座標を `offset` で平行移動する。
それ以外（`.key` / `.char` / `.focus` / `.composition`）は変更なしで返す。
`consumed` フラグはコピーされる。

## 修飾キーの組み合わせ確認
```zig
pub fn has(self: Modifiers, m: Modifiers) bool;
```

`self` に `m` のすべての true ビットが含まれているかを返す。
`mods.has(.{ .ctrl = true })` のように使う。

## マウスキャプチャの要求
```zig
pub fn requestCapture(self: *Event, target: *anyopaque) void;
```

`capture_target` に `target` を設定する。
`.press` の dispatch 中に呼ばれることを想定。
target は通常 `&self.component` を渡す（呼び出し元の widget 自身）。

framework 側の dispatcher（`framework.Window`）はこのフラグを press 後に観測し、以降の `.move` / `.release` イベントを hit-test なしで `target` へ直接配送する。
`.release` で自動的に解除される。

awt 層は型を持たないので `*anyopaque` で受け取る。
framework 側が `*Component` にキャストし直す。

## 利用例
ハンドラからイベントを消費する例。

```zig
fn processEvent(self: *Component, event: *Event) void {
    switch (event.payload) {
        .key => |k| {
            if (k.code == .escape and k.action == .press) {
                // ESC で何か処理して消費
                doDismiss(self);
                event.consume();
            }
        },
        .char => |ch| {
            // テキスト入力。文字フィールドにのみ意味がある。
            insertCodepoint(self, ch.codepoint);
            event.consume();
        },
        .mouse => |m| {
            if (m.action == .press and m.button == .left) {
                handleClick(self, m.x, m.y);   // 既にコンポーネントローカル座標
                event.consume();
            }
        },
        .focus => |f| {
            // フォーカス獲得・喪失時に再描画 (キャレットの表示切替等)。
            if (f.gained) startCaretBlink(self) else stopCaretBlink(self);
        },
    }
}
```

修飾キー組み合わせの確認例。

```zig
const k = event.payload.key;
if (k.action == .press and k.code == .s and k.modifiers.has(.{ .ctrl = true })) {
    // Ctrl+S
    save();
    event.consume();
}
```

座標変換 helper の低レベル使用例（通常は framework が自動で行うので利用者が直接書くことは少ない）。

```zig
const local_offset = Point{ .x = 50, .y = 30 };
const local_event  = mouse_event.translated(local_offset);
// local_event.x / .y はコンポーネントローカル
```

## 機能要望
* タッチ / ジェスチャイベント（マルチタッチ環境向け）
* キーリピート間隔の設定
* ドラッグ&ドロップ専用イベント
* マウス enter / leave イベント（hover 検出用）
* CompositionEvent の attribute 配列拡張（現状は target 1 区間のみ。色分け 4 段階等にしたい場合は struct に attribute 配列を additive に足す）
