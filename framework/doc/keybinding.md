---
unsafe: true
---

# keybinding
キーストロークとハンドラの束縛を提供するモジュール (`keybinding.zig`)。
設計の経緯・配送モデル全体は [narrative/keybinding.md](narrative/keybinding.md) を参照。

## 型定義
```zig
/// アクセラレータをプラットフォーム中立に書くための抽象修飾キー。
/// command は照合時に解決される (Win/Linux = Ctrl、macOS = Cmd)。
pub const Mods = packed struct {
    command: bool = false,
    shift:   bool = false,
    alt:     bool = false,
};

pub const KeyStroke = struct {
    code: awt.Event.KeyCode,
    mods: Mods = .{},
};

/// 型消去されたコールバック。listener.zig と同じ thunk 方式。
pub const Handler = struct {
    ctx:    *anyopaque,
    invoke: *const fn (*anyopaque) void,
};

/// コンポーネント単位の可変な束縛表 (Component.bindKey が遅延生成)。
pub const KeyBindings = struct {
    entries:   std.ArrayList(Entry),
    allocator: std.mem.Allocator,

    pub const Entry = struct { stroke: KeyStroke, handler: Handler };
};
```

## 関数定義

### KeyStroke の生成
```zig
pub fn of(code: awt.Event.KeyCode) KeyStroke;        // 修飾なし
pub fn cmd(code: awt.Event.KeyCode) KeyStroke;       // command+code
pub fn cmdShift(code: awt.Event.KeyCode) KeyStroke;  // command+shift+code
pub fn alt(code: awt.Event.KeyCode) KeyStroke;       // alt+code
```

それぞれ対応する修飾ビットを立てた `KeyStroke` を返す。

### キーイベントとの照合
```zig
pub fn satisfies(self: KeyStroke, code: awt.Event.KeyCode, raw: awt.Event.Modifiers) bool;
```

raw なキーイベント (`code` + OS の修飾キー状態) がこのストロークに一致するとき true。
修飾キーの比較は完全一致 (`Ctrl+S` は素の `S` の束縛に一致しない)。
`command` は照合時に Win/Linux = `ctrl`、macOS = `meta` (Cmd) へ解決される。

### 型付きハンドラの生成
```zig
pub fn typed(comptime T: type, comptime f: fn (*T) void, ctx: *T) Handler;
```

`*anyopaque` キャストを隠した `Handler` を返す。thunk は (T, f) ごとに comptime 生成され
identity が安定する。

### 束縛の追加
```zig
pub fn bind(self: *KeyBindings, stroke: KeyStroke, handler: Handler) !void;
```

`stroke` を `handler` に束縛する。既に同じ `stroke` の束縛があれば**置き換える**
(実行時リバインドが第一級の操作)。

### 束縛の削除
```zig
pub fn unbind(self: *KeyBindings, stroke: KeyStroke) void;
```

`stroke` の束縛を削除する。存在しなければ no-op。

### 束縛の検索
```zig
pub fn lookup(self: *const KeyBindings, code: awt.Event.KeyCode, raw: awt.Event.Modifiers) ?Handler;
```

raw なキーイベントに `satisfies` する最初のエントリの `Handler` を返す。無ければ null。
発火条件 (press / repeat の両方で発火、release では発火しない) は呼び出し側
(`Window.dispatchInput`) が制御する。

### ニーモニック文字への変換
```zig
pub fn letterOf(code: awt.Event.KeyCode) ?u8;
```

英字 / 数字キーを小文字 ASCII に変換する (ニーモニック照合用)。それ以外は null。

---

## 利用例
```zig
// ウィジェットローカルな束縛 (フォーカス中のみ効く):
try field.component.bindKey(
    nimbus.KeyStroke.cmd(.d),
    nimbus.KeyHandler.typed(MyState, MyState.duplicateLine, &state),
);

// ウィンドウ全体の束縛は root へ (既定ボタンは専用 API がある):
try frame.window.setDefaultButton(ok_button);
```

## 機能要望
- バインディング単位の repeat 抑制フラグ (`Entry.repeat: bool = true`)。実需待ち。
- release バインド。稀なので後回し。
- リテラル Ctrl 修飾 (macOS の emacs 風バインド用)。ウィジェット内部 InputMap の領分。
