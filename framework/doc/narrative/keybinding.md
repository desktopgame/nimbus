---
unsafe: true
---

# keybinding
キーボード操作 — フォーカストラバーサル・キーストローク・ニーモニック — の設計ノート。
3 つは「キー入力 → 対象を決める → 動かす」という 1 本の連鎖で、フォーカスが背骨になる。
**まだ未実装**であり、実装時に確定したシグネチャを各 spec (`component.md` / `window.md` / `button.md` ほか) の `## 関数定義` へ昇格させる。

## 3 つの関係
```
キー押下
  ├─ ニーモニック   : Alt+S → 「S のボタン」を探して押す      ┐
  ├─ キーストローク : Cmd/Ctrl+S → 「保存アクション」を呼ぶ    ├ どれも 対象解決 → 起動
  └─ 通常のキー     : フォーカス中のウィジェットに渡す         ┘
```
ニーモニックはキーストロークの砂糖衣 (`Alt+文字` を「このウィジェットを起動」に割り当て + 下線描画)。
キーストロークも通常キーも「どのウィジェットに届けるか」をフォーカスが決める。
よって考える順序は フォーカス → キーストローク → ニーモニック で、下ほど上に乗る。

## 層
```
[配送]   遡り 1 本 + consume        ← 安定の背骨。「Component よ、このキー食う?」だけが契約
[束縛]   KeyBindings (KeyStroke→Handler, Component ごと)   ← Swing の InputMap+ActionMap を 1 枚に畳んだもの
[行為]   Action / Command          ← 後付け。Handler の指す先を共有 enabled 付きに格上げ
[分離]   InputMap / ActionMap       ← 後付け。束縛を名前経由に割り直す or 特定ウィジェット内だけで使う
```
配送の契約が「食ったか/食わないか」だけなので、[行為] と [分離] は契約の裏側で後から足せる (後述「後付け余地」)。

## データ構造 (計画)

### Mods — 抽象コマンド修飾キー
```zig
pub const Mods = packed struct {
    command: bool = false, // Win/Linux = Ctrl、macOS = Cmd(super) に照合時解決
    shift:   bool = false,
    alt:     bool = false,
};
```
アクセラレータをプラットフォーム中立に書くための抽象。`command` を照合時に解決する (Win/Linux は ctrl ビット、macOS は super ビット)。
リテラルな Ctrl (macOS の emacs 風バインド等) は v1 では持たない (ウィジェット内部 InputMap の領分として後回し)。

macOS の Cmd 照合には `awt.Event.Modifiers` に `super` ビットが必要だが現状未対応。awt バックログ `awt_backlog.md` #8 で対応する (Mac 対応は必須)。

### KeyStroke — キー和音
```zig
pub const KeyStroke = struct {
    code: awt.Event.KeyCode,
    mods: Mods = .{},

    pub fn of(code: awt.Event.KeyCode) KeyStroke;        // 修飾なし
    pub fn cmd(code: awt.Event.KeyCode) KeyStroke;       // command+code
    pub fn cmdShift(code: awt.Event.KeyCode) KeyStroke;
    pub fn alt(code: awt.Event.KeyCode) KeyStroke;       // ニーモニック用
};
```
発火は press のみ (release バインドは稀なので後回し)。

### Handler — typed callback
`listener.zig` の thunk と同型 ((T, f) ごとに安定 identity の thunk を comptime 生成し、登録解除で同じ関数ポインタが得られる)。
```zig
pub const Handler = struct {
    ctx:    *anyopaque,
    invoke: *const fn (*anyopaque) void,

    pub fn typed(comptime T: type, comptime f: fn (*T) void, ctx: *T) Handler;
};
```
いまは「ctx + invoke」だけ。将来 `invoke` の指す先を Command モデルにすれば enabled 共有が乗る (非破壊の広げ代)。

### KeyBindings — opt-in capability (可変 map)
```zig
pub const KeyBindings = struct {
    entries:   std.ArrayListUnmanaged(Entry) = .{},
    allocator: std.mem.Allocator,

    const Entry = struct { stroke: KeyStroke, handler: Handler };

    pub fn bind(self: *KeyBindings, stroke: KeyStroke, handler: Handler) !void;
    pub fn unbind(self: *KeyBindings, stroke: KeyStroke) void;             // リバインド用
    pub fn lookup(self: *const KeyBindings, code: awt.Event.KeyCode, raw: awt.Event.Modifiers) ?Handler;
    pub fn deinit(self: *KeyBindings) void;
};
```
HashMap ではなく ArrayList を使う: 1 コンポーネントあたり束縛は数個で線形走査で足り、`KeyStroke` のハッシュ実装も要らない。
**可変 map である**ことが「Swing の InputMap が別レイヤーで存在する理由 = 実行時リバインド」を最初から満たす保険になる。名前間接 (ActionMap 相当) が要るのは「1 つの行為を複数キーで」「ハンドラ実体を触らず差し替え」をやりたくなったときだけ。

照合での `command` 解決:
```zig
// stroke.mods.command を Win/Linux は ctrl、macOS は super に解決して raw と突き合わせる
fn satisfies(stroke: KeyStroke, code: awt.Event.KeyCode, raw: awt.Event.Modifiers) bool;
```

### Component への追加
```zig
key_bindings: ?*KeyBindings = null,   // 既定 null (DragSource / A11y 等と同じ opt-in)

pub fn bindKey(self: *Component, stroke: KeyStroke, handler: Handler) !void;  // 初回 lazy 生成
pub fn unbindKey(self: *Component, stroke: KeyStroke) void;
```
`Component.deinit` で `key_bindings` を解放する。フィールド方式は `a11y` / `drag_source` と同じで、関数ポインタ数個ぶんしか増えないので `VTable` は増やさない (`component.md`「VTable を増やすな」方針)。

## 配送 — 遡り 1 本
`Window.dispatchInput` の `.key` を、現状の `focus_owner → menu_bar → fan-out` から次へ一般化する:

```
1. focus_owner.processEvent(ev)              // 自前処理 + widget-local。consume なら終了
2. ev 未 consume なら focus_owner から親へ:    // 遡り
       node = focus_owner.parent
       while node: if node.key_bindings.lookup(...) |h| { h.invoke(); ev.consume(); return }
                   node = node.parent
3. root.key_bindings.lookup(...)             // グローバル (メニューアクセラレータ / 既定ボタン)
```

これは Swing の WHEN_FOCUSED → WHEN_ANCESTOR_OF_FOCUSED_COMPONENT → WHEN_IN_FOCUSED_WINDOW を「遡り 1 本」に畳んだもの。2 段目 (祖先) と 3 段目 (ウィンドウ全体) の違いは「遡り先が親か root か」だけなので、**スコープという分類自体を持たず**、root を遡りの終点にすることで両者を統合する。

最初に一致した `KeyBindings` が consume して止まる。フォーカス中ウィジェットが食えば祖先・グローバルより優先される (例: フォーカス中のテキスト部品の Cmd+C は、メニューの Cmd+C アクセラレータより先に勝つ = 直感どおり)。
`menu_bar` の特別扱いは「アクセラレータを root の `key_bindings` に登録する」へ解消され、固定段が減る。

## グローバル登録の流儀
> ウィンドウ全体にしたい束縛は、そのコンポーネント自身ではなく **root container の `key_bindings` に登録する**。

どのフォーカスチェーンも必ず root で終わるので、root の束縛はどこからでも届き、かつ必ず最後に評価される (= グローバルかつ最下位)。
- メニュー項目の `setAccelerator(KeyStroke.cmd(.s))` → root に `cmd+S → その項目の起動` を登録。
- `Window.setDefaultButton(btn)` → root に `Enter → btn.doClick` を登録。
- Dialog のキャンセル → root に `Esc → cancel` を登録 (ESC のオーバーレイ閉じは構造挙動として built-in のまま。Dialog はそれと別に登録する)。

Swing の WHEN_IN_FOCUSED_WINDOW は任意コンポーネントに登録でき親チェーン外でも効くが、本モデルは親チェーン上しか辿らない。差は「グローバルは root に登録」という明示ルールで吸収する。

## フォーカストラバーサル
- **focusable を拡大する**: Button / CheckBox / RadioButton / Slider / ComboBox / List を `focusable = true` にする。v1 の「ボタン等はマウス専用」を意図的に覆す判断。Label は据え置き。
- **トラバーサル順 = コンテナ子の追加順の DFS**。Swing の差し替え可能な `FocusTraversalPolicy` は持たない (過剰)。レイアウトが子を順に並べる前提なら視覚順と一致する。
```zig
// Window
pub fn focusNext(self: *Window) void;   // Tab
pub fn focusPrev(self: *Window) void;   // Shift+Tab
```
focusable を DFS で列挙し、`focus_owner` の次 / 前へ移す。端で wrap する。
- **Tab の扱い**: まず `focus_owner.processEvent` に渡す (将来 TextArea が Tab を文字として食う余地を残す)。食わなければ Window が `focusNext` / `focusPrev`。これは現状の「focus_owner 先取り → fallback」構造にそのまま乗る。
- **初期フォーカス**: ウィンドウ open 時に最初の focusable へ。
- **Space / Enter 起動**: フォーカス中ウィジェット自身の `processEvent` で処理する (widget-local)。Button は Space で起動。共通の起動口として **各ボタン系に `doClick()` を新設**する (press + fireAction + release を模す。マウス / Space / Enter / ニーモニックすべての入口)。
- **フォーカスリング描画**: ウィジェットは既に受け取っている `FocusEvent{ gained }` で `focused: bool` を保持し、`paint` でリングを描く。`Window.focus_owner` への逆参照は不要。

## ニーモニック (キーストロークの砂糖衣)
```zig
// Button / Menu / MenuItem 等
pub fn setMnemonic(self: *Self, ch: u8) void;
```
内部で 2 つを行う:
1. `root.key_bindings` に `Alt+ch → self.doClick` (メニューなら開く) を登録する。
2. ラベル中の該当文字の index を保存し、`paint` で下線を引く。

下線表示は v1 は **常時表示**。Alt 押下中のみ出す Windows 流 (Alt-reveal) は Alt キー状態の追跡 + 変化時 repaint が要るので後回し (将来「Alt タップでメニューバーにフォーカス」と一緒に入れるのが自然)。
Label の `labelFor` (ラベルのニーモニックで別フィールドにフォーカス) は Label→対象の紐付けが要るので後回し。

## 後付け余地
配送契約 (食う/食わない) が防火壁になるので、以下は今の決定を壊さず後から積める。
- **Action / Command**: `Handler.invoke` の先を Command モデル (`enabled` / `label` / `icon` / `on_invoke` + リスナー) にする。メニュー項目・ツールバーボタン・アクセラレータが 1 つの Command を指し、`enabled = false` で一斉グレーアウトが無料で付く。既存の Model パターンに乗る。今は不要。
- **ActionMap**: 「名前 → Action」の片割れ。InputMap (名前経由) を入れるときだけ意味を持つ。フレームワーク全体にも特定ウィジェット内にも入れられる。
- **InputMap で TextArea を再実装**: TextArea の `processEvent` 内部だけの話。配送から見れば相変わらず「食う/食わない」を返すだけなので、いつでもローカルに差し替えられる。テキスト編集キーを利用者がリバインドできるようにしたいときにやる。Swing の InputMap の親チェーン (共通ベース編集キーマップ) も、1 つのウィジェットが「食うか決める内部処理」に閉じるので別途入れられる。

## 確定済みの方針 (作者承認)
- P1: キーボード操作可能な UI にする (focusable 拡大 + Tab トラバーサル + Space/Enter 起動)。対象は上記一覧。
- P2: スコープ 3 種ではなく「遡り 1 本 + グローバルは root に登録」。
- P3: 抽象コマンド修飾キー (`command` = Win/Linux は Ctrl、macOS は Cmd)。macOS 対応は必須で、awt の super 対応は `awt_backlog.md` #8。
- `doClick()` を全ボタン系に新設。
- フォーカスリングは各ウィジェットが `focused` を持って自前描画。
- ニーモニック下線は v1 常時表示 (Alt-reveal は後回し)。
