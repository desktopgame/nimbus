# robot
AI / 自動テストが nimbus アプリのインタラクションを再現・観測するためのドライバ。
合成イベントの注入・イベントループの単一ステップ駆動・仮想時間・コンポーネントツリーの構造化スナップショットを提供する。
Swing の `java.awt.Robot` に相当するが、OS レベルではなく framework レベルで動き、ヘッドレス・決定的・意味的（role + text 指定）である点が異なる。

## やりたいこと
表示のチェックは awt の `RenderTarget` で済んでいる（Scene → オフスクリーン → PNG）。
しかし「クリックしたらボタンが押下状態になる」「文字を打ったら TextField に反映される」のようなインタラクションの検証には、Component ツリーとイベントディスパッチ、すなわち framework の `Window` / `Application` を動かす必要がある。

Robot は次の 2 チャネルを提供する。

* **act（操作）**: マウス / キー / 文字 / IME イベントを合成し、実入力とまったく同じ経路（`EventQueue.postEvent` → `Window.dispatchInput`）に流す。ヒットテスト・mouse capture・focus・overlay が実入力と同一に駆動される
* **observe（観測）**: Component ツリーを構造化スナップショットとして取り出す（role / text / 矩形 / focus 等）。AI はピクセルを読まずにこの構造化データで状態を判定できる。視覚バグ用にピクセル readback も併せて取れる

この 2 チャネルを `pump`（イベントループの単一ステップ駆動）と仮想クロックで挟み、`inject → pump → snapshot → 検証` を決定的に繰り返す。

さらに、人間が実ウィンドウでアプリを操作した入力列を記録し、再生可能なテストシナリオに変換する**レコーダー**を提供する（後述「入力の記録」）。記録は実ウィンドウ、再生はヘッドレス。

最終的な利用形態は**アウトプロセス JSON ドライバ**（後述「JSON ドライバ」）だが、その土台となる Zig API も同時に公開する。

## 依存関係
`framework` 層に属する。
`Application` / `Window` / `Component` と、`awt.Event` / `awt.EventQueue` / `awt.RenderTarget` に依存する。
ピクセル readback は `awt.RenderTarget.readback` を利用する。
GLFW（awt-c）には直接依存しない（ヘッドレスモードでは OS ウィンドウを開かない）。

## 前提となる 3 つのケイパビリティ
Robot は単独では成立せず、framework 側に次の 3 つが要る。
いずれも本 doc で設計し、未実装分は「機能要望」に段階を記す。

1. **ヘッドレスサーフェス** — `Window` を Swapchain ではなくオフスクリーン `RenderTarget` に向ける。OS ウィンドウを開かず、ピクセル取得は readback で行う（後述「ヘッドレスサーフェス」）
2. **決定的 pump** — `Application.run()` の OS ブロッキングループに対し、ブロックせず 1 反復だけ進める `pump` を用意する（後述「pump」）
3. **仮想クロック** — タイマー / caret 点滅 / ダブルクリック判定の時間源を差し替え可能にし、`advanceClock` で時間を進められるようにする（後述「仮想クロック」）

## 型定義
```zig
pub const Robot = struct {
    app:    *Application,         // 借用。Robot は Application を所有しない
    window: *Window,             // 操作対象ウィンドウ（複数ある場合は対象を保持）
    // 直前のマウス座標 / 装飾キー / ボタン状態など、合成イベント組み立て用の保持状態
    cursor: Component.Point,
    buttons: awt.Event.Modifiers, // 押下中のボタン / 装飾キー
};
```

`Robot` 自身は Component ツリーやウィンドウを所有しない。
`Application` と `Window` を借用するだけで、寿命はそれらより短くなければならない（後述「ライフタイム」）。

スナップショットには 2 つのモードがある（後述「2 つのスナップショットモード」）。
curated な `tree` ビューのノード:

```zig
pub const NodeSnapshot = struct {
    role:      Component.Role,    // ウィジェット種別（後述「Component の a11y ファセット」）
    name:      ?[]const u8,       // Component.name（デバッグ名。未設定なら null）
    text:      ?[]const u8,       // accessibleText()（ボタンのラベル等。未設定なら null）
    rect:      Component.Rect,    // ウィンドウローカルの絶対矩形
    focusable: bool,
    focused:   bool,              // この Component が Window の focus_owner か
    children:  []NodeSnapshot,    // 描画順（奥 → 手前）
};
```

詳細 `dump` ビューのノード。
ノード毎に、ウィジェットが**自分で選別した**プロパティを並べる（機械的な全件走査ではない。後述「詳細ダンプのフィールド選別」）。
構造（親子）は `children` で表す。

```zig
pub const DumpNode = struct {
    type_name: []const u8,        // 実体の型名（"Button" 等）
    fields:    []Field,           // ウィジェットが選別したプロパティ
    children:  []DumpNode,
};

pub const Field = struct {
    name:  []const u8,
    value: Value,
};

pub const Value = union(enum) {
    int:    i64,
    float:  f64,
    boolean:bool,
    string: []const u8,           // []const u8 / [:0]const u8 など
    enum_:  []const u8,           // enum はタグ名で出す（決定的）
    object: []Field,              // 入れ子 struct（Size / Rect 等）を展開したもの
};

pub const QueryError = error{ NotFound, Ambiguous };
```

## Robot の生成
```zig
pub fn init(app: *Application, window: *Window) Robot;
```

`app` と `window` を借用して `Robot` を初期化する。
`cursor` は原点、`buttons` は空で始まる。
メモリ確保を伴わないので失敗しない（スナップショットの確保は各メソッド側で行う）。

### 事前条件
`window` は `app` に登録済みのウィンドウであること。
ヘッドレスでデバッグする場合、`app` / `window` がヘッドレスモードで生成されていること（後述「ヘッドレスサーフェス」）。実ウィンドウに対しても動作するが、その場合フォーカス奪取や OS のジッタの影響を受ける。

## マウスの移動
```zig
pub fn moveMouse(self: *Robot, x: f32, y: f32) void;
```

ウィンドウローカル座標 (`x`, `y`) への `.move` イベントを合成して `EventQueue.postEvent` でキューに積む。
`cursor` を更新する。
ディスパッチは次の `pump` で行われる（即時ではない）。実入力の `onCursorPos` と同じ経路を通る。

## マウスボタンの押下 / 解放
```zig
pub fn mouseDown(self: *Robot, button: awt.Event.MouseButton) void;
pub fn mouseUp  (self: *Robot, button: awt.Event.MouseButton) void;
```

現在の `cursor` 位置で `.press` / `.release` の `.mouse` イベントを合成して積む。
`buttons` の対応ビットを更新する。
mouse capture / focus 遷移は `Window.dispatchInput` 側が処理するので、Robot は座標とボタンだけを与える。

## クリック
```zig
pub fn click(self: *Robot, x: f32, y: f32, button: awt.Event.MouseButton) void;
```

(`x`, `y`) へ `moveMouse` → `mouseDown` → `mouseUp` を続けて積む簡略ヘルパ。
ダブルクリックは `click` を 2 回呼び、間に `advanceClock` でダブルクリック閾値未満だけ時間を進めて表現する。

## スクロール
```zig
pub fn scroll(self: *Robot, dy: f32) void;
```

現在の `cursor` 位置で `.scroll` イベント（`wheel = dy`）を合成して積む。

## キーの押下 / 解放
```zig
pub fn keyDown(self: *Robot, code: awt.Event.KeyCode, mods: awt.Event.Modifiers) void;
pub fn keyUp  (self: *Robot, code: awt.Event.KeyCode, mods: awt.Event.Modifiers) void;
```

`.key` イベント（`.press` / `.release`）を合成して積む。
ショートカット（Ctrl+S 等）は `mods` に装飾キーを立てて表現する。
キーイベントは focus_owner（無ければ container fan-out）に届く。

## 文字の入力
```zig
pub fn typeText(self: *Robot, utf8: []const u8) void;
```

`utf8` をコードポイントに分解し、各コードポイントに対し `.char` イベントを合成して順に積む。
TextField 等への文字入力を再現する。物理キーの `.key` ではなく `.char` を流すので、テキスト入力の検証はこちらを使う（IME を経た確定文字に相当）。

実際のテキスト編集（カーソル移動・削除）は `.key`（矢印 / Backspace 等）を `keyDown` / `keyUp` で送る。

### IME の合成
```zig
pub fn composition(self: *Robot, text: []const u8, target_start: i32, target_end: i32) void;
```

`.composition` イベント（変換中文字列）を合成し、focus_owner へ届ける。
inline 変換表示（TextField 内の preedit）の検証に使う。
composition イベントは借用文字列の寿命の都合で同期ディスパッチされる経路（`Window.onComposition`）に倣い、`pump` を介さず即時に focus_owner へ渡してよい。

## イベントループの単一ステップ駆動
```zig
pub fn pump(self: *Robot) void;
```

`Application.run()` の 1 反復ぶんを **ブロックせずに** 実行する。順序は `run` と同じ。

1. due 時刻に達した仮想タイマーを発火する
2. `event_queue.drain()` で積まれた合成イベント / タスクを処理する
3. `paint_dirty` または `layout_dirty` のウィンドウを `redraw`（ヘッドレスならオフスクリーン RT へ描画）する

`run` と違い OS イベントを待たない（`waitEvents` を呼ばない）。
これにより `inject → pump → snapshot` が実時間に依存せず決定的になる。

## 仮想時間の前進
```zig
pub fn advanceClock(self: *Robot, ms: u32) void;
```

仮想クロックを `ms` ミリ秒進める。
これにより caret 点滅・ツールチップ遅延・ダブルクリック判定・tween アニメーション等の時間依存挙動が決定的に検証できる。
時間を進めただけでは発火しないので、続けて `pump` を呼んでタイマーを処理する。

## ツリースナップショットの取得（curated）
```zig
pub fn snapshotTree(self: *Robot, allocator: std.mem.Allocator) !NodeSnapshot;
pub fn freeTree(allocator: std.mem.Allocator, root: NodeSnapshot) void;
```

`window` の Component ツリー（container / menu_bar / overlays）を再帰的に走査し、`NodeSnapshot` の木を構築して返す。
各ノードの `role` / `text` は Component の a11y ファセット（後述）から取る。
`rect` は `absoluteOriginInWindow` を使ったウィンドウローカル絶対矩形。
`focused` は `window.focus_owner` との一致で決める。

コンパクトで安定した「画面に何があるか」のビュー。ナビゲーションと検証（クリックが効いたか等）向け。
返り値は `allocator` で確保される。呼び出し側が `freeTree` で解放する。

## ダンプスナップショットの取得（詳細）
```zig
pub fn dumpTree(self: *Robot, allocator: std.mem.Allocator) !DumpNode;
pub fn dumpNode(self: *Robot, allocator: std.mem.Allocator, target: *Component) !DumpNode;
pub fn freeDump(allocator: std.mem.Allocator, root: DumpNode) void;
```

`dumpTree` はツリー全体、`dumpNode` は単一ノードのサブツリーについて、各ウィジェットが**選別した詳細プロパティ**を `DumpNode` として返す。
「なぜそうなっているか」を診断するための深いビュー。
curated `tree` が role / text / rect の最小集合なのに対し、これは内部状態（`min_size` / `grow_x` / モデルの選択インデックス / caret 位置等）のうちウィジェットが診断に有用と判断したものを出す。

各ノードのフィールド収集は Component の `dump` VTable フック（後述）が行う。
返り値は `allocator` で確保される。呼び出し側が `freeDump` で解放する。

## ピクセルスナップショットの取得
```zig
pub fn snapshotPixels(self: *Robot, allocator: std.mem.Allocator, out_rgba: []u8) !void;
pub fn snapshotPng(self: *Robot, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void;
```

ヘッドレスサーフェスのオフスクリーン RT から RGBA8 を読み戻す（`awt.RenderTarget.readback` / `readbackToPng` のラッパー）。
構造化スナップショットで判定できない視覚バグ（色・描画位置・アンチエイリアス等）用のフォールバック。

### 事前条件
`window` がヘッドレスモードであること。実ウィンドウ（Swapchain）に対しては未サポート（UB）。

## 意味的クエリ
```zig
pub fn find(self: *Robot, q: Query) QueryError!*Component;
pub fn clickOn(self: *Robot, q: Query) QueryError!void;

pub const Query = struct {
    role: ?Component.Role = null,
    text: ?[]const u8 = null,     // accessibleText() との完全一致
    name: ?[]const u8 = null,     // Component.name との完全一致
};
```

`find` は条件 `q`（role / text / name の AND）に一致する Component をツリーから探して返す。
一致が 0 件なら `error.NotFound`、2 件以上なら `error.Ambiguous`。
`clickOn` は `find` の結果矩形の中心へ `click` を合成する（座標計算を呼び出し側にさせない）。

座標ベースの `click` が下位プリミティブ、`clickOn` がその上の意味的ラッパー。
AI は通常 `clickOn(.{ .role = .button, .text = "Save" })` を使い、座標が必要なときだけ `click` を使う。

---

## Component の a11y ファセット
意味的クエリと構造化スナップショットのため、`Component` に「種別」と「アクセシブル名」を持たせる。
既存の `name`（`component.md` 参照）はデバッグ用でルックアップを想定しない旨が明記されているため、それとは別系統として用意する。

`Component` に `role` フィールドを追加する。

```zig
pub const Role = enum {
    none,
    button, toggle_button, checkbox, radio_button,
    label, slider, combobox, text_field, scroll_bar,
    menu, menu_item, menu_bar, panel, window,
};
```

各ウィジェットは `create` 内で自身の `role` をセットする（Button なら `.button` 等）。
デフォルトは `.none`。

アクセシブル名（ボタンのラベル等）は Component には保持せず、VTable 経由でウィジェットから引く。
テキストは各ウィジェット構造体（`Button.text` 等）が持つため、Component に重複保持しないのが自然。
`Component.VTable` に 2 エントリを追加する（既存 5 エントリ → 7 エントリ）。

```zig
pub const VTable = struct {
    install:        *const fn (*Component) anyerror!void,
    uninstall:      *const fn (*Component) void,
    paint:          *const fn (*Component, *awt.Graphics) void,
    processEvent:   *const fn (*Component, *awt.Event) void,
    destroy:        *const fn (*Component, std.mem.Allocator) void,
    accessibleText: ?*const fn (*Component) ?[]const u8,            // ★ 追加。テキストを持たないなら null
    dump:           ?*const fn (*Component, *Robot.DumpSink) void,  // ★ 追加。詳細ダンプ
};
```

`accessibleText` は curated ツリーと意味的クエリ用の軽いアクセサ。
text を引くためだけに詳細ダンプを走らせたくないので、curated 側専用に独立させる（dump とは別エントリ）。
テキストを持たないウィジェット（Filler / Separator 等）は null のままでよい。

`dump` は詳細ビュー用のフック。
型消去された `*Component` からは Zig の comptime リフレクションでウィジェット実体のフィールドに届かないため、具体型を知るこのフックが必要になる。
フック内で `@fieldParentPtr` で実体に戻し、**診断に有用なフィールドを選んで** `sink.field(...)` で明示的に並べる。

```zig
fn dump(self: *Component, sink: *Robot.DumpSink) void {
    const btn: *Button = @fieldParentPtr("component", self);
    sink.field("armed", btn.armed);
    sink.field("pressed", btn.model.pressed);     // モデルから拾う
    sink.field("min_size", btn.component.min_size); // 入れ子 struct は object に展開
}
```

ダンプを持たないウィジェットは null のままでよい（その場合 `DumpNode.fields` は空）。
旧案にあった `accessibleState`（押下 / 選択を別途返す）は廃止する。`pressed` / `selected` 等は `dump` が `field` で出すため。

## 詳細ダンプのフィールド選別
`dump` フックが出すフィールドは、機械的な全件走査ではなく**各ウィジェットが明示的に選別**する（allowlist 方式）。
`DumpSink.field` はフィールド名と値を 1 つ受け取り、型に応じて `Value` に変換して `DumpNode.fields` に積む。

```zig
pub fn field(self: *DumpSink, name: []const u8, value: anytype) void;
```

`value` の型は comptime に判定して `Value` のバリアントへ振り分ける。

| `value` の型 | `Value` |
|---|---|
| int / comptime_int | `int` |
| float | `float` |
| bool | `boolean` |
| `[]const u8` / `[:0]const u8` | `string` |
| enum | `enum_`（タグ名。アドレスではないので決定的） |
| struct（`Size` / `Rect` 等） | `object`（フィールドを再帰展開） |

### 機械的全件走査を採らない理由
全フィールドを自動で吐くと、点滅フェーズ・アニメ進行度・キャッシュ済みレイアウト値・最終イベント時刻のような「正当に変動するが診断に無関係なフィールド」までダンプに乗り、スナップショット比較で偽陽性を生む。
どのフィールドが意味を持つかはウィジェット作者が一番分かっているので、選別を作者に委ねる。
新しい内部状態を足したときに `field` 呼び出しを追加する保守は要るが、ダンプの安定性と意図の明瞭さを優先する。

### 選別の指針
* 生ポインタ / アドレス / 関数ポインタは `field` に渡さない（実行毎に変わり、ダンプ比較が成り立たなくなる。本 doc の決定性の主目的に反する）
* 派生・キャッシュ値より、状態の source of truth となるフィールドを優先する
* 親子構造はダンプの責務ではない（`DumpNode.children` のツリー走査が担う）。`parent` / `container` を `field` に出さない

## 2 つのスナップショットモード
観測には粒度の違う 2 モードを用意し、用途で使い分ける。

| モード | API | 内容 | 用途 |
|---|---|---|---|
| `tree`（curated） | `snapshotTree` | role / text / rect / focused | 「画面に何があるか」。ナビゲーション・検証。コンパクトで安定 |
| `dump`（詳細） | `dumpTree` / `dumpNode` | ウィジェットが選別した詳細プロパティ | 「なぜそうなっているか」。診断 |

通常は `tree` でアサートし、状態が想定と食い違ったノードだけ `dumpNode` で深掘りする、という流れを想定する。
`dump` は curated を置き換えるものではなく補完するもの。
意味的クエリ（`find` / `clickOn`）は軽い `tree` 側（`accessibleText`）を使う。

## ヘッドレスサーフェス
`Window` は現状 `awt.Window`（GLFW）+ `awt.Swapchain` に固く結びついており、生成すると実 OS ウィンドウが開く。
ヘッドレスデバッグでは OS ウィンドウを開かず、描画先をオフスクリーン `RenderTarget` にしたい。

描画先を「Swapchain か オフスクリーン RT か」を選べる継ぎ目を `Window` に入れる。

* `redraw` が `bindRenderTarget` する対象を、Swapchain の `getTarget()` ではなくオフスクリーン RT に切り替えられるようにする
* OS 入力コールバック（`onMouseButton` 等）はヘッドレスでは登録しない。入力はすべて Robot の合成イベント経由
* ウィンドウサイズはヘッドレスでは固定値（生成時に指定）

`Application` / `Window` のファクトリにヘッドレス用の入口を設ける（具体的なシグネチャは `application.md` / `window.md` 側で定義する）。
実ウィンドウモードとヘッドレスモードで Component ツリー / レイアウト / イベントディスパッチのコードは共通で、差異は描画先と入力源だけに閉じ込める。

## 仮想クロック
タイマー（`application.md`「タイマー」）と時間依存のウィジェット挙動は現状 `awt.time()`（GLFW の時刻）を直接読む。
これを差し替え可能な時間源にする。

* 通常モードでは従来通り `awt.time()` を返す
* ヘッドレス / Robot モードでは内部カウンタを返し、`advanceClock(ms)` でだけ進む

`fireDueTimers` の `now` 比較、ダブルクリック / 長押し / caret 点滅の経過時間判定はすべてこの時間源を経由させる。
これにより実時間 sleep を一切挟まずに時間依存挙動を検証できる。

## JSON ドライバ
最終的な利用形態。
Robot の Zig API をラップしたヘッドレス実行ファイルを用意し、stdin で JSON-lines コマンドを受け、stdout で観測結果（JSON）を返す。
AI エージェントが再ビルドなしにターン毎に対話駆動でき、MCP サーバー化も自然。

1 行 1 コマンド。コマンド → 即応答の同期プロトコル。

| コマンド | 意味 | 主なフィールド |
|---|---|---|
| `act` | 操作を合成して積む | `kind`（click / move / down / up / key / type / scroll / composition）, `x`, `y`, `button`, `code`, `mods`, `text`, `target` |
| `pump` | ループを N ステップ進める | `count`（省略時 1） |
| `advance` | 仮想クロックを進める | `ms` |
| `snapshot` | 観測を返す | `what`（tree / dump / pixels）, `target`（dump 対象の限定。省略時は全体） |
| `query` | 意味的クエリの結果を返す | `role`, `text`, `name` |
| `quit` | ドライバを終了する | — |

`act` の `target` は意味的指定（`{"role":"button","text":"Save"}`）で、座標の代わりに使える。
ドライバ内部で `clickOn` 等に解決する。
`snapshot` の `tree` は curated ビュー、`dump` は詳細ビュー（`target` で 1 ノードに絞れる）。

応答は `{"ok":true}` か、観測コマンドはペイロード（`tree` / `dump` / 画像パス）、失敗時は `{"error":"NotFound"}` 等。

利用イメージ:

```
> {"act":"click","target":{"role":"button","text":"Save"}}
< {"ok":true}
> {"pump":1}
< {"ok":true}
> {"snapshot":"tree"}
< {"tree":[{"role":"button","text":"Save","rect":[12,40,80,24],"focused":true}]}
> {"snapshot":"dump","target":{"role":"button","text":"Save"}}
< {"dump":{"type_name":"Button","fields":[{"name":"armed","value":true},{"name":"pressed","value":true}],"children":[]}}
```

座標 / ピクセルは初版から使えるが、`target` による意味的指定は Component の a11y ファセットが入って初めて機能する。

## 入力の記録（レコーダー）
人間が実ウィンドウでアプリを操作した入力列を記録し、再生可能なテストシナリオに変換する。
記録は実ウィンドウ（人間が見て操作する）、再生はヘッドレス（決定的）という非対称構成で、両者をイベント間のクロック差分が橋渡しする。
Playwright の codegen に相当する。

### 記録点
入力は実イベントも合成イベントも `Window.dispatchInput`（および composition の同期パス）を必ず通る。
ここに観測フックを 1 つ足し、流れるイベントを記録する。
`DirtyNotify` / `FocusController` と同じく、Window のオプショナルなフィールドとして持たせる（グローバルにしない）。

```zig
pub const InputObserver = struct {
    user_data: *anyopaque,
    on_event:  *const fn (*anyopaque, *const awt.Event) void,
};
// Window に追加: input_observer: ?InputObserver
```

`dispatchInput` は処理の冒頭で `input_observer` が non-null なら `on_event` を呼ぶ。
合成イベント（Robot 由来）も同じ経路を通るが、レコーダーは記録モード中の実ウィンドウにのみ装着される想定。

### 型定義
```zig
pub const Recorder = struct {
    app:       *Application,        // 借用
    window:    *Window,            // 借用。観測フックを装着する対象
    steps:     std.ArrayList(Step),
    last_time: f64,                // 直前イベントの時刻（wait 差分の算出用）
    allocator: std.mem.Allocator,
};

pub const Scenario = struct {
    window_w: u32,                 // 記録時のウィンドウサイズ（再生時に一致させる）
    window_h: u32,
    steps:    []Step,
};

pub const Step = union(enum) {
    wait:       u32,               // 直前ステップからの経過 ms（再生時 advanceClock + pump）
    act:        ActStep,
    checkpoint: Checkpoint,
};

pub const ActStep = union(enum) {
    click:  Query,                 // 意味的に解決したクリック対象（後述「クリックの解決」）
    move:   Component.Point,       // ドラッグ等。解決できないので座標で残す
    down:   Component.Point,
    up:     Component.Point,
    key:    KeyStep,
    type_:  []const u8,            // 確定文字列（.char 列をまとめたもの）
    scroll: f32,
};

pub const Checkpoint = struct {
    label:    ?[]const u8,
    expected: NodeSnapshot,        // 記録時点の curated tree（期待状態）
};
```

### 記録の開始 / 停止
```zig
pub fn init(allocator: std.mem.Allocator, app: *Application, window: *Window) !*Recorder;
pub fn start(self: *Recorder) void;
pub fn stop(self: *Recorder) void;
pub fn deinit(self: *Recorder) void;
```

`init` は `Recorder` を確保し、`window.input_observer` に自身を装着する。
`start` / `stop` で記録の on/off を切り替える（`stop` 後も装着は残り、再 `start` できる）。
`deinit` は観測フックを外して解放する。フックを外し忘れると dangling になるため、`deinit` は必ず `window` より先に呼ぶ。

### シナリオの取り出し
```zig
pub fn scenario(self: *Recorder) Scenario;
pub fn writeJsonl(self: *Recorder, io: std.Io, path: []const u8) !void;
```

`scenario` は記録済みステップを `Scenario` として返す（`Recorder` が所有する steps を借用）。
`writeJsonl` は JSON-lines 形式（後述「シナリオ形式」）でファイルに書き出す。

### クリックの解決
`.press` と `.release` が同一コンポーネント上で起きたクリックは、記録時にクリック地点をヒットテストして role + text + name に解決し、`click: Query` ステップとして残す（意味的指定。レイアウト変更に強い）。
ヒットテストには Robot の `find` と同じ走査を使う。

ドラッグ（press → move → … → release が別位置 / 別コンポーネント）や、解決先が曖昧なクリックは、解決を諦めて座標ベースの `down` / `move` / `up` ステップで残す。
解決した `text` / `name` は元コンポーネントからの借用なので、`Recorder` 内に複製して保持する（コンポーネントが変化・破棄されても安全に）。

### チェックポイントの記録
記録中に人間が予約キー（既定 `F12`。装着時に変更可）を押すと、その入力は**ステップとして記録せず**、代わりにその時点の curated tree を `snapshotTree` で取得して `Checkpoint` として積む。
これが再生時の期待状態（アサート）になる。
予約キーはアプリ本来の入力と衝突しないものを選ぶ（必要なら修飾キー併用）。

curated tree（role / text / rect / focused）だけをチェックポイントにするのは、安定していて偽陽性が出にくいため（詳細ダンプを golden 比較に使わない方針と整合）。
特定フィールドの値を検証したい場合は、再生スクリプト側で `dumpNode` を名指しで確認する。

## シナリオの再生
```zig
pub fn replay(robot: *Robot, scenario: Scenario, allocator: std.mem.Allocator) !ReplayResult;

pub const ReplayResult = struct {
    passed:    bool,
    failures:  []CheckpointFailure,  // 一致しなかったチェックポイント
};
```

`Scenario` のステップを順に Robot 操作へ写して再生する。

* `wait` → `advanceClock(ms)` の後 `pump`。再生クロックは仮想なので、人間の長い手休めもほぼ即座に消化される（実時間 sleep は挟まない）
* `act` → `clickOn` / `moveMouse` / `keyDown`+`keyUp` / `typeText` / `scroll` の後 `pump`
* `checkpoint` → `snapshotTree` を取り、`expected` と構造比較。差分があれば `failures` に積む

### 事前条件
再生に使う `robot.window` は、`Scenario.window_w` / `window_h` と同じサイズで生成されていること。
チェックポイントの `rect` 比較がサイズに依存するため、サイズが違うと座標差で偽の不一致が出る。

### シナリオ形式
JSON-lines。1 行 1 ステップで、JSON ドライバのコマンド列と同じ語彙を使う。
したがって「記録 = この形式で書き出す」「再生 = ドライバに食わせる」がそのまま成り立ち、再生経路を二重に実装しなくてよい。

```
{"window":[800,600]}
{"act":"click","target":{"role":"button","text":"Save"}}
{"advance":120}
{"act":"type","text":"hello"}
{"checkpoint":"after-typing","tree":[{"role":"text_field","text":"hello","rect":[12,40,200,28],"focused":true}]}
```

ヘッダ行（`window`）でサイズを宣言し、以降はステップ。
`checkpoint` 行は期待 tree を埋め込み、ドライバは再生時にその行で現在の tree と比較する。

## ライフタイム
* `Robot` は `Application` と `Window` を**借用**する。両者より先に破棄しなければならない（`Robot` → `Window` → `Application` の順は不可）
* `snapshotTree` / `dumpTree` の返り値は呼び出し側が `freeTree` / `freeDump` で解放する。ノード内の文字列（`name` / `text` / dump の string 値）は元 Component の文字列を**借用**するので、対応する Component が生きている間だけ有効（snapshot 後に widget を destroy したらダングリング）。文字列の所有が必要なら呼び出し側で複製する
* 合成イベントは `postEvent` でキューにコピーされるため、`inject` 系メソッドの引数（`utf8` 等）は呼び出し後すぐ解放してよい。ただし `.composition` の借用文字列だけは同期ディスパッチなので呼び出し中のみ有効
* `Recorder` は `Application` / `Window` を**借用**し、`window.input_observer` に自身を装着する。`deinit` で必ずフックを外す。`Window` より先に `deinit` すること（さもないと dangling フックが残る）。解決済みの `text` / `name` は複製して保持するので、元コンポーネントが破棄されてもシナリオは安全

## 制約 / 非機能要件
* **単一 UI スレッド**: Robot のメソッドはすべて UI スレッドから呼ぶ前提（CLAUDE.md「スレッドモデル」）。`postEvent` 自体はスレッド安全だが、`pump` / `snapshotTree` は UI スレッド限定
* **決定性が最優先**: 実時間・実 OS イベントに依存しないことを設計の主目的とする。これがフレーキーなテストとの分かれ目。詳細ダンプも生ポインタ / 関数ポインタ / アドレスを `field` に出さない（実行毎に変わり比較不能になる。「詳細ダンプのフィールド選別」参照）
* **実入力との同一経路**: 合成イベントは独自の short-cut を作らず、必ず `postEvent` → `dispatchInput` を通す。Robot のためだけの分岐をディスパッチャに増やさない
* **記録は実ウィンドウ / 再生はヘッドレス**: レコーダーは実ウィンドウに装着して人間の操作を採るが、再生は決定的なヘッドレス + 仮想クロックで行う。両者をイベント間のクロック差分が橋渡しする
* **スコープ外（v1）**: OS レベルのイベント注入（実ウィンドウへの本物のクリック）、複数プロセス分散、スクリーンリーダー API 連携。いずれも本 doc の意味的ファセット / JSON プロトコルを土台に後付けできる形にしておく

## 関連 doc
* `component.md` — Component / VTable。a11y ファセット（`role` / `accessibleText`）と詳細ダンプ用 `dump` フックの追加先
* `application.md` — イベントループ / タイマー。pump と仮想クロックの追加先
* `window.md` — dispatchInput / 描画。ヘッドレスサーフェスと `input_observer`（レコーダー装着点）の追加先
* `awt/doc/event.md` — 合成する `awt.Event` の型
* `awt/doc/event_queue.md` — `postEvent` による注入経路
* `awt/doc/render_target.md` — ピクセル readback

## 機能要望
段階的に組む想定。下にいくほど後段。

* **段階 1**: 合成イベント注入（`postEvent` ラッパー）+ 座標ベース `click` / `keyDown` / `typeText`。既存 API でほぼ実現でき、実ウィンドウに対しても動く
* **段階 2**: ヘッドレスサーフェス + `pump` + 仮想クロック。決定的な `inject → pump → snapshot` ループが成立する
* **段階 3**: Component の a11y ファセット（`role` / `accessibleText`）+ `snapshotTree`（curated）+ 意味的クエリ（`find` / `clickOn`）
* **段階 3.5**: `dump` フック（ウィジェット毎にフィールド選別）+ 詳細ダンプ（`dumpTree` / `dumpNode`）。curated ツリーの上に深掘りビューを足す
* **段階 4**: アウトプロセス JSON ドライバ + MCP サーバー化
* **段階 5**: 入力レコーダー（`Window.input_observer` + `Recorder`）+ シナリオ再生（`replay`）。記録は実ウィンドウ、再生はヘッドレス。意味的解決とチェックポイントは段階 3 のファセットを前提とする
* Zig テストコードの codegen: シナリオから `snapshot_test.zig` 隣に置ける Zig テスト関数を生成（v1 は JSON-lines のみ）
* チェックポイント比較で `rect` を無視するモード: ウィンドウサイズ非依存の比較（v1 はサイズ一致前提）
* 書記素クラスタ単位の `typeText`（v1 はコードポイント単位。CLAUDE.md「書記素クラスタ」と整合）
