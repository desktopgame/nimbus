---
unsafe: false
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
ニーモニックは `Alt+文字` を「このウィジェットを起動」に対応させたもの + 下線描画 (解決は登録ではなく走査。「ニーモニック」参照)。
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
発火は **press と repeat の両方** (区別しない)。Swing / Win32 と同じで、ツールキットとしての
リピートポリシーは持たない — OS がイベントを繰り返すなら束縛も繰り返し発火する。
undo / paste / キャレット移動はリピート発火が望ましい側であり、連射されて困るハンドラ
(べき等でない処理) の自衛はハンドラ側の責任とする。
将来「この束縛だけリピート発火させたくない」が出たら `Entry` に `repeat: bool = true` を足すだけ
(消費点は lookup 1 か所、既定 true で挙動不変の後付け)。
release バインドは稀なので後回し。

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
3. root.key_bindings.lookup(...)             // ウィンドウ紐づけの束縛 (既定ボタン / Dialog の Esc)
4. アクセラレータ走査                         // メニューツリーを setAccelerator 値で照合 → 項目を起動
5. ニーモニック走査 (Alt+文字のときのみ)       // コンポーネントツリーを mnemonic 値で照合 → doClick
```
段 4・5 は登録された束縛の lookup ではなく、配送時にツリーを走査する built-in 段
(理由は「root 登録と走査の線引き」)。

これは Swing の WHEN_FOCUSED → WHEN_ANCESTOR_OF_FOCUSED_COMPONENT → WHEN_IN_FOCUSED_WINDOW を「遡り 1 本」に畳んだもの。2 段目 (祖先) と 3 段目 (ウィンドウ全体) の違いは「遡り先が親か root か」だけなので、**スコープという分類自体を持たず**、root を遡りの終点にすることで両者を統合する。

最初に一致した `KeyBindings` が consume して止まる。フォーカス中ウィジェットが食えば祖先・グローバルより優先される (例: フォーカス中のテキスト部品の Cmd+C は、メニューの Cmd+C アクセラレータより先に勝つ = 直感どおり)。
`menu_bar` の特別扱いは段 4 のアクセラレータ走査へ解消され、固定段が減る。

### processEvent に `.key` が届く範囲
raw なキーイベント (`processEvent` への `.key`) を受け取るのは **focus_owner (とモーダルオーバーレイの top) だけ**である。
遡り段の祖先は `key_bindings.lookup` でのみ参加し、`processEvent` は呼ばれない。
Swing と同型 (祖先コンポーネントは `processKeyEvent` を受けない。祖先の関与はバインディングという宣言的な仕組みに限る)。
「祖先の `processEvent` にも `.key` が来るかもしれない」という曖昧さを契約から排除するための明文化。

### 遡りの実体は parent ポインタの鎖
遡りは `focus_owner.parent` を root まで辿るだけで、コンテナの子リストは走査しない。
よって List のセルのようにコンテナツリーの外で実体化されるコンポーネントでも、
`parent` が root まで繋がってさえいれば配送は正しく機能する
(`Window.findFocusableAt` のヒットテストから見えない実体でも、フォーカスさえ取れば遡りは成立する)。
逆に Tab トラバーサル (コンテナ子の DFS) からは見えないままだが、
それは「セル内エディタはクリックでフォーカスを取る」という既存の割り切りと整合する。

### 却下案: キャプチャ段 (トンネリング)
DOM / WPF / JavaFX が持つ「root → target の前置き走査 (祖先がターゲットより先に横取りできる段)」は採らない。
キーイベントには座標がなく、階層から配送先を導けない以上、root から降ろしても
ターゲットに着くまで全員が素通しする線形 walk になるだけで純粋な無駄。
「祖先が必ず勝つべき」構造的挙動は、汎用のキャプチャ段ではなく `Window.dispatchInput` の固定前段として処理する
(実例: ドラッグ中の ESC / キー全飲み込み、モーダルオーバーレイの最優先 + 非伝播)。
将来「ウィンドウ全体でキーを横取りしたい」類の需要が出たときの答えも、固定前段を 1 つ足すことであり、
キャプチャ段の導入ではない。

### 削除予定: フォーカス不在時の fan-out (一斉配布)
現行実装には遡りと別系統のキー配送が残っている。`Window.dispatchInput` は focus_owner がいないとき
キーイベントを root コンテナに渡し、`Container.processEvent` の `.key, .char` 分岐が
ヒットテストもフォーカスも見ずに**子全員へ追加順にブロードキャストする** (誰かが consume するまでツリー全体に撒く)。
v1 で Button / List 等が focusable でなく、キーを欲しがるウィジェットを特定する手段が無かった時代の代替品である。

これは**壊れており、削除する**(作者承認済み):
- 配送先が位置にもフォーカスにも基づかず、同じキーに反応するウィジェットが複数あると
  「先に add された方が勝つ」という利用者に説明のつかない決まり方をする。
- P1 (focusable 拡大) 後は「フォーカスを持てないのにキーが欲しいウィジェット」が存在しなくなり、
  存在理由そのものが消える。

削除後の定義: **focus_owner == null のときは遡りの起点を root にする** (= ステップ 3〜5 のみ実行)。
root の束縛 (既定ボタン / Dialog の Esc) と走査段 (アクセラレータ / ニーモニック) だけが評価され、
それ以外のキーは捨てられる。
フォーカスが誰にもない状態で矢印キーが List に届くような現行の暗黙挙動は消える
(P1 後はクリックか Tab でフォーカスを取ってから操作する、という一貫した形になる)。

削除対象は `Container.processEvent` の `.key, .char` 分岐と、`Window.dispatchInput` の
focus_owner 不在時に root コンテナへ渡す fallback の 2 か所。**P1 の focusable 拡大が前提条件**なので、
削除はそれと同時かそれ以降に行う (先に消すと現行の List 矢印キー等が操作不能になる)。

## root 登録と走査の線引き
キーが遡りで消費されなかったあとの「ウィンドウ全体」の解決は 2 つに分かれる。

> **コンポーネントに紐づく意味 (ニーモニック / アクセラレータ) は登録せず、配送時に走査で解決する。**
> **ウィンドウ自身への呼び出し (既定ボタン / Dialog の Esc) だけが root の `key_bindings` に登録する。**

- ニーモニック: Component の mnemonic フィールド。段 5 でコンポーネントツリーを走査 (詳細「ニーモニック」)。
- アクセラレータ: MenuItem の accelerator フィールド (`setAccelerator` は保存のみ)。段 4 で
  メニューバー配下のメニューツリーを走査し、一致した項目を起動する。

走査を選ぶのはコスト判断である。登録式は 2 つの構造的な罠を持つ:
- **順序罠** — 「作る → 設定する → add する」という自然な書き順では、`setMnemonic` / `setAccelerator` の
  時点で parent chain が root に到達できない。遅延登録 (install で bind) も、install はコンテナ配置時に
  発火するため未接続サブツリーで同じ問題が再発し、正しく解くには「サブツリーが root に接続された瞬間」を
  全子孫へ伝搬する新機構が要る。
- **寿命罠** — 束縛の置き場所 (root) と対象の寿命 (ウィジェット本人) が分離し、unbind を忘れると
  対象破棄後の dangling handler (UAF) になる。

一方、配送時の走査はキー押下というコールドパスでの小さな木の走査 1 回で、コストは無視できる。
走査なら生きている木が常に真実であり、順序罠も寿命罠も構造的に存在しない。
この判断はコスト前提に依存する: 走査が高くつく状況が現実になったら登録式を再検討する。

root に登録が残るのはウィンドウ自身に対する呼び出しだけ:
- `Window.setDefaultButton(btn)` → root に `Enter → btn.doClick` を登録。
- Dialog のキャンセル → root に `Esc → cancel` を登録 (ESC のオーバーレイ閉じは構造挙動として built-in のまま。Dialog はそれと別に登録する)。

これらはウィンドウが存在する時点でしか呼べないので順序罠は起きない。ただし寿命罠は残る:
**root 登録がコンポーネントを参照する場合 (既定ボタン等)、そのコンポーネントの破棄時に unbind する**のが
登録側の責任 (uninstall 時に root へ到達できるか、teardown 順に注意)。

Swing の WHEN_IN_FOCUSED_WINDOW は任意コンポーネントに登録でき親チェーン外でも効くが、本モデルは親チェーン + 走査段で解決する。差は上記の線引きで吸収する。

## フォーカストラバーサル
- **focusable を拡大する**: Button / CheckBox / RadioButton / Slider / ComboBox / List を `focusable = true` にする。v1 の「ボタン等はマウス専用」を意図的に覆す判断。Label は据え置き。
- **トラバーサル順 = コンテナ子の追加順の DFS**。Swing の差し替え可能な `FocusTraversalPolicy` は持たない (過剰)。レイアウトが子を順に並べる前提なら視覚順と一致する。
```zig
// Window
pub fn focusNext(self: *Window) void;   // Tab
pub fn focusPrev(self: *Window) void;   // Shift+Tab
```
focusable を DFS で列挙し、`focus_owner` の次 / 前へ移す。端で wrap する。
- **BorderLayout と追加順の規約**: BoxLayout は追加順＝視覚順なので常に一致する。BorderLayout は
  配置が region ヒントで決まり**追加順は配置に影響しない**ので、タブオーダーを読み順 (north → west →
  center → east → south 等) にしたければ add をその順に呼べばよい。幾何ソートは持たない。
  この規約は利用者向け doc (spec 昇格時) に明記する。
- **スキップ条件 = 静的 `focusable` + 動的 `FocusQuery`**: トラバーサルが止まるのは
  「`focusable == true` かつ (`focus_query == null` または `isEligible()` が true)」のウィジェットだけ。
  disabled なボタンに Tab が止まらないようにするための動的判定で、enabled がモデル側
  (`ButtonModel` 等) にあり Component 層から見えない問題を opt-in capability で埋める
  (`A11y` / `SizeQuery` と同型のフィールド方式、VTable は増やさない)。
```zig
pub const FocusQuery = struct {
    isEligible: *const fn (self: *const Component) bool,
};
// Component への追加 (既定 null = focusable であれば常に適格)
focus_query: ?FocusQuery = null,
```
  モデルを持つウィジェットが `install` で設定し、`@fieldParentPtr` で自分へ戻って `model.enabled` を返す。
  不採用: Component に `enabled: bool` を複製してモデル変化時に同期する案 (同期忘れの余地があり、
  真実が 2 か所になる)。
- **フォーカス喪失時の行き先は null**: フォーカス中のウィジェットが削除 / 無効化されたら
  `focus_owner = null` に戻すだけ。Swing 的な「次の候補へ自動移動」はしない (次の Tab で
  先頭から再スタートすれば十分)。
- **列挙の一本化 (実装制約)**: focusable の DFS 列挙は 1 つの関数に集約し、`focusNext` /
  `focusPrev` / 初期フォーカスのすべてがそれを共有する。将来の Order 値 (「後付け余地」参照) の
  差し込み点をこの 1 か所に保つため。DFS を複数箇所に複製しない。
- **オーバーレイ開放中の Tab = 外クリックと同じ扱いで閉じて移動**: モーダルオーバーレイ
  (ComboBox のドロップダウン / ポップアップメニュー等) が開いている間に Tab が来たら、
  `Window.dispatchInput` の ESC 処理と同じ場所で拾い、`dismissAll` (= キャンセル、ComboBox の値は
  変えない) してから通常の `focusNext` / `focusPrev` を実行する。
  原理: ポップアップは transient な UI であり、フォーカスを動かす意図はそれを閉じる
  (外クリックと Tab で閉じ方の意味を統一する)。
  - 不採用: 案A (Tab を飲み込む = 現状の挙動)。Tab 連打でフォームを移動する操作が
    ドロップダウンで引っかかる。
  - 実需待ち: 案C (Windows 流にハイライト中の項目を**確定**してから閉じて移動)。
    オーバーレイ機構に「閉じ方の意味 (commit / cancel)」の契約を持ち込む必要がある。
    後付けコスト: 消費点は同じ分岐 1 か所なので、ComboBox で違和感の実需が出たら
    そこだけ commit 化すればよい (時間で増えない型)。
- **Tab 移動時のスクロールイン (scrollRectToVisible 相当) は v1 に入れる**: `focusNext` /
  `focusPrev` でフォーカスが移った先が ScrollPane の視界外にあるとき、視界内へスクロールさせる。
  配管は既存の `Component.ScrollController` (汎用 rect API、TextArea キャレット追従用に実装済み) を
  そのまま使う: `scrollIntoView(component)` ヘルパーを 1 つ書き、component の bounds を
  スクロールされる view の座標系へ変換して `scroll_rect_to_visible` に渡す。
  - フックは `focusNext` / `focusPrev` のみ。クリックフォーカスは定義上すでに見えている場所で、
    プログラム由来の `requestFocus` での自動スクロールは利用者コードと喧嘩する余地があるため、
    `requestFocusFor` には入れない (不採用)。
  - ネストした ScrollPane は最寄りの 1 段だけ (外側への連鎖は実需が出たら)。
- **Tab の扱い**: まず `focus_owner.processEvent` に渡す (将来 TextArea が Tab を文字として食う余地を残す)。食わなければ Window が `focusNext` / `focusPrev`。これは現状の「focus_owner 先取り → fallback」構造にそのまま乗る。
- **初期フォーカス**: ウィンドウ open 時に最初の focusable へ。
- **Space / Enter 起動**: フォーカス中ウィジェット自身の `processEvent` で処理する (widget-local)。Button は Space で起動。共通の起動口として **各ボタン系に `doClick()` を新設**する (press + fireAction + release を模す。マウス / Space / Enter / ニーモニックすべての入口)。
- **フォーカスリング描画**: ウィジェットは既に受け取っている `FocusEvent{ gained }` で `focused: bool` を保持し、`paint` でリングを描く。`Window.focus_owner` への逆参照は不要。

## ニーモニック (Component のフィールド + 走査で解決)
```zig
// Button / Menu / MenuItem 等
pub fn setMnemonic(self: *Self, ch: u8) void;
```
`setMnemonic` は**登録を行わない**。コンポーネント自身に 2 つを保存するだけ:
1. ニーモニック文字 (照合用)。
2. ラベル中の該当文字の index (`paint` で下線を引く用)。

起動は配送の段 5 で行う。`Alt+文字` が root まで消費されずに落ちてきたら、Window が
コンポーネントツリーを走査して `mnemonic == ch` のウィジェットを探し `doClick()` する
(メニューバー直下の Menu なら開く)。登録が無いので順序罠も寿命罠も無い (「root 登録と走査の線引き」参照)。

- **重複は先勝ち** (走査順 = ツリーの DFS 順で最初の一致)。Windows 流の「重複時は起動せず該当コントロール間を
  フォーカス巡回」は実需待ち (走査方式なら全一致を集めるだけなので後付けは容易)。
- **disabled は発火しない**。ガードは走査側ではなく `doClick()` 自身が持つ — `model.enabled == false` なら
  no-op。マウス / Space / Enter / ニーモニックのどの入口から来ても同じ 1 か所で守られる。
- **MenuItem のニーモニックは root 走査の対象外**。スコープは「親メニューが開いている間だけ」、照合は
  Alt なしの素の文字キー。開いたメニューはモーダルオーバーレイとしてキーを最初に受けるので、メニュー自身の
  processEvent が表示中項目の mnemonic と突き合わせる (オーバーレイ内ローカル処理)。root 走査に含めると
  メニューが閉じていても発火してしまい、それはニーモニックではなくアクセラレータの挙動になる。

下線表示は v1 は **常時表示**。Alt 押下中のみ出す Windows 流 (Alt-reveal) は Alt キー状態の追跡 + 変化時 repaint が要るので後回し (将来「Alt タップでメニューバーにフォーカス」と一緒に入れるのが自然)。
Label の `labelFor` (ラベルのニーモニックで別フィールドにフォーカス) は Label→対象の紐付けが要るので後回し。

## 後付け余地
配送契約 (食う/食わない) が防火壁になるので、以下は今の決定を壊さず後から積める。
- **Action / Command**: `Handler.invoke` の先を Command モデル (`enabled` / `label` / `icon` / `on_invoke` + リスナー) にする。メニュー項目・ツールバーボタン・アクセラレータが 1 つの Command を指し、`enabled = false` で一斉グレーアウトが無料で付く。既存の Model パターンに乗る。今は不要。
- **ActionMap**: 「名前 → Action」の片割れ。InputMap (名前経由) を入れるときだけ意味を持つ。フレームワーク全体にも特定ウィジェット内にも入れられる。
  **要る判定の引き金**: 利用者アプリの「ショートカットのユーザーカスタマイズ + 永続化」の実需が出たとき。
  Handler (関数ポインタ) はシリアライズできないので、設定ファイルへの保存・設定画面での一覧表示には
  `"save" → Ctrl+S` のような安定した名前が必須になる — それが名前間接層でなければ買えない唯一のもの
  (リバインドは KeyBindings の可変性、複数キー→同一動作は同じ Handler の複数 bind、プラットフォーム差は
  抽象 `command` 修飾キー、mac テキスト編集キー差はウィジェット内部 InputMap で、それぞれ名前なしで賄える)。
  それまでは入れない。後付けの形: KeyBindings はそのまま、上に「名前 → Handler」レジストリと
  bind-by-name の砂糖衣を載せるだけ (配送契約は不変)。
- **InputMap で TextArea を再実装**: TextArea の `processEvent` 内部だけの話。配送から見れば相変わらず「食う/食わない」を返すだけなので、いつでもローカルに差し替えられる。テキスト編集キーを利用者がリバインドできるようにしたいときにやる。Swing の InputMap の親チェーン (共通ベース編集キーマップ) も、1 つのウィジェットが「食うか決める内部処理」に閉じるので別途入れられる。
- **明示タブオーダー (Order 値)**: HTML `tabindex` / WinForms `TabIndex` 相当の上書き値。入れるなら
  **コンテナ内ローカル**のソートキーにする — 兄弟間で `(order, 追加index)` の安定ソート、既定 `order = 0`
  (= 未設定なら純粋な追加順のまま)。グローバル番号 (HTML の正の tabindex) は「1 個挟むだけで全部
  振り直し」の罠があるので採らない。**v1 では実装しない**: BoxLayout は追加順＝視覚順で常に一致し、
  BorderLayout は追加順が配置に影響しないので add の並べ替えで常に直せる = 実需となるケースが無い。
  唯一の衝突は「追加順が z オーダー (描画順 / ヒットテスト逆順) を兼ねていて動かせない」場合だが、
  重なり合う兄弟はオーバーレイ以外では稀。その実需が出たときにこの形で足す。
  **後付けコストの見積もり** (実需待ちの条件として記録): ① `Component` にフィールド 1 個
  (既定 0 = 挙動不変、利用者側マイグレーション無し)、② トラバーサルの列挙関数 1 か所に
  兄弟の安定ソートを挿入、③ setter + apigen 1 行 (ただし C ABI 露出は capi のスカラー引数対応待ち)。
  消費点が列挙関数 1 つに閉じているため、繰り延べコストは時間で増えない (LAF のような
  「不在が多数の paint に焼き込まれる」型と逆)。
  前提条件: 下記「列挙の一本化」が守られていること。

## 確定済みの方針 (作者承認)
- P1: キーボード操作可能な UI にする (focusable 拡大 + Tab トラバーサル + Space/Enter 起動)。対象は上記一覧。
- P2: スコープ 3 種ではなく「遡り 1 本 + ウィンドウ全体は root 登録 / 走査の線引きで解決」
  (「root 登録と走査の線引き」参照)。
- P3: 抽象コマンド修飾キー (`command` = Win/Linux は Ctrl、macOS は Cmd)。macOS 対応は必須で、awt の super 対応は `awt_backlog.md` #8。
- `doClick()` を全ボタン系に新設。
- フォーカスリングは各ウィジェットが `focused` を持って自前描画。
- ニーモニック下線は v1 常時表示 (Alt-reveal は後回し)。
- フォーカス不在時の fan-out は削除する (P1 と同時かそれ以降。「削除予定: フォーカス不在時の fan-out」参照)。
- トラバーサル順は追加順 DFS で確定。幾何ソート / 差し替え Policy は不採用。BorderLayout は
  「読み順に add する」規約で吸収 (追加順は配置に影響しないため常に可能)。
- 動的フォーカス適格性 (disabled スキップ) は `FocusQuery` capability (フィールド方式)。
  Component への `enabled` 複製案は不採用。
- フォーカス喪失時 (削除 / 無効化) は `focus_owner = null` に戻す。自動移動はしない。
- 明示タブオーダー (Order 値) は v1 では実装しない。実需が出たら「後付け余地」記載の形
  (コンテナ内 `(order, 追加index)` 安定ソート) で足す。
- オーバーレイ開放中の Tab は「外クリックと同じ扱いで閉じて (キャンセル)、focusNext」(案B)。
  確定して閉じる Windows 流 (案C) は実需待ち。
- Tab 移動時のスクロールインは v1 に入れる。フックは `focusNext` / `focusPrev` のみ、
  既存 `ScrollController` を流用、ネストは最寄り 1 段。
- ニーモニック / アクセラレータは root 登録ではなく配送最終段の走査で解決 (`setMnemonic` /
  `setAccelerator` は保存のみ)。根拠はコスト判断 — 配送時走査はコールドパスで無視できる、
  登録式は順序罠と寿命罠を持つ。コスト前提が変われば再判断 (「root 登録と走査の線引き」参照)。
- root の `key_bindings` に登録するのはウィンドウ自身への呼び出し (既定ボタン / Dialog の Esc) だけ。
  コンポーネントを参照する root 登録は当該コンポーネント破棄時に unbind する (寿命契約)。
- MenuItem のニーモニックは開いている親メニューのローカル照合 (素の文字キー)。root 走査の対象外。
- ニーモニック重複は先勝ち。Windows 流フォーカス巡回は実需待ち。
- `doClick()` は `model.enabled == false` なら no-op (マウス / Space / Enter / ニーモニック共通のガード)。
- 束縛の発火は press と repeat の両方 (区別しない。Swing / Win32 と同じ「リピートポリシーを持たない」)。
  per-binding の repeat 抑制フラグは実需待ち、release バインドは後回し。
