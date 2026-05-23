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
        key:   KeyEvent,
        char:  CharEvent,
        mouse: MouseEvent,
        focus: FocusEvent,
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
それ以外（`.key` / `.char` / `.focus`）は変更なしで返す。
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

---

## 消費モデル
イベントは Component ツリーで dispatch されるが、ある時点で「これは私が処理した」と宣言できる仕組みが必要。
nimbus では `Event.consumed: bool` フィールドで表現する。

* ハンドラ（`Component.vtable.processEvent`）は `event.consume()` を呼んで消費を宣言する
* framework の dispatcher は親へのバブリング前に `event.isConsumed()` を確認し、true なら伝搬を止める
* `consumed` は読み取り可能なので、複数ハンドラがある場合に「既に他のハンドラが処理したか」を見て挙動を変えられる

Java AWT の `AWTEvent.consume()` / `isConsumed()`、DOM の `Event.stopPropagation()` に近い設計。
vtable.processEvent のシグネチャは `*Event`（mutable）+ `void` 返却で、消費は戻り値ではなくフィールド経由。

### 部分的な処理を許す
return-bool 方式（消費 = 伝搬停止）と異なり、フィールド方式は「読み取るが消費しない」処理を表現できる。
たとえば「キーログを取るが、実際のキー処理は子に任せる」ような透明ハンドラが書ける。

## 座標系
MouseEvent の `x` / `y` は **ウィンドウローカル座標**（ウィンドウの左上が `(0, 0)`、右下が `(window_width, window_height)`）で届く。
ウィンドウの OS 絶対座標とは別物（OS 絶対座標は `framework.Window` の `component.position` 経由でアクセス可、`window.md` 参照）。

コンポーネントの bounds は「親 Container 内のローカル座標」で表現されているので、深くネストされたコンポーネントがマウスイベントを受け取るときには、ウィンドウローカル座標から自身のローカル座標へ変換する必要がある。

```
window-local mouse pos (300, 250)
   - container.position           (200, 200)   ← Container 自身の位置
   - label.position               (50, 30)     ← Container 内の Label 位置
   = label-local mouse pos        (50, 20)
```

これは framework の dispatcher が tree を辿りながら累積的に `translated` を適用する形で実現される。
利用者の `processEvent` には常にコンポーネントローカル座標の Event が届く。

### 親階層の絶対オフセット計算
framework は `Component.absoluteOriginInWindow(c: *const Component) Point` のような helper を提供する（詳細は `framework/doc/component.md` 参照）。
awt 層は座標計算ロジック自体を持たず、`Event.translated(offset)` という汎用 helper だけを提供する。

## KeyCode の値域
`KeyCode` は GLFW のキーコード（`GLFW_KEY_*`）に対応する `i32` enum。
具体的な値の対応は実装側で `c.GLFW_KEY_*` を直接 `@enumFromInt` する。
利用者は文字（`'a'`、`'5'` 等）ではなく enum 名（`.a`、`.digit_5`、`.enter` 等）で参照する。

主要なものを抜粋:

| 名前 | 用途 |
|---|---|
| `.a` ... `.z` | アルファベット |
| `.digit_0` ... `.digit_9` | 数字キー |
| `.f1` ... `.f12` | ファンクションキー |
| `.enter` / `.space` / `.tab` / `.escape` / `.backspace` / `.delete` | 制御キー |
| `.arrow_left` / `.arrow_right` / `.arrow_up` / `.arrow_down` | 矢印キー |
| `.shift_left` / `.shift_right` / `.ctrl_left` / `.ctrl_right` / ... | 修飾キー単体 |

修飾キーの状態は `Modifiers` 経由で取得する方が普通（`KeyEvent.modifiers.ctrl == true` 等）。
修飾キー自体の押下を検知したいときだけ `KeyCode.shift_left` 等を見る。

## マウスキャプチャ
ドラッグ操作（Slider つまみのドラッグ、Button の押下中ドラッグ取り消し等）では、カーソルが widget の bounds 外に出ても `.move` / `.release` を受け取り続ける必要がある。
hit-test ベースの素朴な dispatch では、カーソルが外れた瞬間にイベントが届かなくなりドラッグが途切れる。

これを解決するのが「マウスキャプチャ」。
具体的な流れ：

1. widget の `processEvent` が `.press` を受け取り、ドラッグ中の追跡が必要だと判断する
2. `ev.requestCapture(@ptrCast(self))` を呼ぶ（`self` は `*Component`）
3. framework 側 dispatcher が press 終了後にこの値を読み取り、capture state に保存する
4. 以降の `.move` イベントは hit-test を経由せず capture 先へ直接配送される
5. `.release` イベントも capture 先へ直接配送され、その後 capture state はクリアされる

awt 層自身は capture state を持たない。
awt は型を提供するだけで、実際の routing は framework の責務。
詳細は `framework/doc/window.md`「マウスキャプチャ」を参照。

## MouseAction の意味
| `action` | `button` | `wheel` | 意味 |
|---|---|---|---|
| `.press` | non-null | 0 | ボタン押下 |
| `.release` | non-null | 0 | ボタン解放 |
| `.move` | null（ボタン押下中のドラッグ時は ?） | 0 | カーソル移動 |
| `.scroll` | null | 非 0 | ホイール |

ドラッグ中の `move` で `button` を non-null にするか null にするかは、framework 層が dispatcher で決める。
awt 層は OS から来た情報をそのまま MouseEvent に詰めるだけ。

## CharEvent と KeyEvent の使い分け
`KeyEvent` は **物理キーの押下** を表す（`.code` は GLFW の `GLFW_KEY_*` 相当）。
`CharEvent` は **入力された文字** を表す（`.codepoint` は OS のキーボードレイアウトを通過した後の Unicode codepoint）。

| 用途 | 使うべきイベント |
|---|---|
| テキストフィールドへの文字入力 | `CharEvent` |
| ショートカット（Ctrl+S 等）の検出 | `KeyEvent`（`modifiers` を見る） |
| カーソル移動・編集操作（矢印 / Home / Backspace / Del） | `KeyEvent` |
| IME 変換中の文字列表示 | （将来）独立した composition イベント |

両者は同じキー操作に対して**両方発火する**ことがある。
たとえば `'a'` キーの押下では `KeyEvent{ .code = .a, .action = .press }` と `CharEvent{ .codepoint = 'a' }` が両方流れてくる（OS から見ると別系統のイベント）。

`CharEvent.codepoint` に修飾キーフィールドは持たない。
Shift+1 は OS がすでに `'!'` に変換した状態で来るので、利用者は文字そのものだけ見ればよい。

## FocusEvent
キーボード入力先のコンポーネント（フォーカスオーナー）が切り替わる際に dispatch される。
OS から来るのではなく framework 側（`Window.requestFocusFor`）が生成する点が他の payload と異なる。

旧オーナーには `FocusEvent{ .gained = false }`、新オーナーには `FocusEvent{ .gained = true }` がそれぞれ届く。
両方に届く順序は「旧オーナー lost → 新オーナー gained」。

`null → Component` や `Component → null` への切り替えも有効（片側だけが dispatch される）。

## awt-c との関係
awt-c は GLFW の C 関数ポインタ型でコールバックを受ける（`nmKeyCallback`、`nmCharCallback`、`nmMouseButtonCallback`、`nmCursorPosCallback`、`nmScrollCallback` 等）。
これらのコールバックは個別の引数（コード / 文字 / ボタン / 座標 / スクロール量）を受け取る形になる。

awt 層がそれらを Zig の `Event` 型に統合してから framework に渡す。
`FocusEvent` は OS 由来ではなく framework が生成するため対応するコールバックは存在しない。
このため awt-c では「Event」という統合型は存在せず、event.md は awt 層のみに存在する。

---

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
* IME composition イベント（変換中文字列の inline 表示）
* タッチ / ジェスチャイベント（マルチタッチ環境向け）
* キーリピート間隔の設定
* ドラッグ&ドロップ専用イベント
* マウス enter / leave イベント（hover 検出用）
