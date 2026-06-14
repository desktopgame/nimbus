---
unsafe: false
---

# robot
Robot / Driver の意図・依存・前提・a11y ファセット・スナップショットモード・ヘッドレス/仮想クロック・シナリオ形式とランナー・レコーダー・再生・寿命・制約。

## やりたいこと
表示のチェックは awt の `RenderTarget` で済んでいる（Scene → オフスクリーン → PNG）。
しかし「クリックしたらボタンが押下状態になる」「文字を打ったら TextField に反映される」のようなインタラクションの検証には、Component ツリーとイベントディスパッチ、すなわち framework の `Window` / `Application` を動かす必要がある。

Robot は次の 2 チャネルを提供する。

* **act（操作）**: マウス / キー / 文字 / IME イベントを合成し、実入力とまったく同じ経路（`EventQueue.postEvent` → `Window.dispatchInput`）に流す。ヒットテスト・mouse capture・focus・overlay が実入力と同一に駆動される
* **observe（観測）**: Component ツリーを構造化スナップショットとして取り出す（role / text / 矩形 / focus 等）。AI はピクセルを読まずにこの構造化データで状態を判定できる。視覚バグ用にピクセル readback も併せて取れる

この 2 チャネルを `pump`（イベントループの単一ステップ駆動）と仮想クロックで挟み、`inject → pump → snapshot → 検証` を決定的に繰り返す。

操作と観測のプリミティブは意味を知らない `Robot` に集約し（act / drive / observe）、role + text で名指しする意味ラッパー `Driver` をその上に薄く重ねる（`Driver` は `*Robot` を持つだけで、解決して `Robot` のプリミティブへ委譲する。robot.md「意味レイヤー」）。「driver（駆動するもの）」と呼ぶのはこの `Driver` だけ。

さらに、人間が実ウィンドウでアプリを操作した入力列を記録し、再生可能なテストシナリオに変換する**レコーダー**を提供する（後述「入力の記録」）。記録は実ウィンドウ、再生はヘッドレス。

最終的な利用形態は、操作と観測を JSON-lines の**シナリオ形式**で記述し、**シナリオランナー**が `Driver` / `Robot` に流して実行する形（後述「シナリオ形式とシナリオランナー」）。その土台となる Zig API（`Robot` / `Driver`）も同時に公開する。

## 依存関係
`framework` 層に属する。
`Application` / `Window` / `Component` と、`awt.Event` / `awt.EventQueue` / `awt.RenderTarget` に依存する。
ピクセル readback は `awt.RenderTarget.readback` を利用する。
GLFW（awt-c）には直接依存しない（ヘッドレスモードでは OS ウィンドウを開かない）。

## 前提となる 3 つのケイパビリティ
Robot は単独では成立せず、framework 側に次の 3 つが要る。
**3 つとも実装済み (2026-06-07)**: ①は `Window.initHeadless` + `Application.frameHeadless`、②は `Robot.pump`（= `Application.tickOnce`）、③は framework 層の `Application.now` / `advanceClock`（`clock_mode = .virtual`）。設計は以下に残す。

1. **ヘッドレスサーフェス** — `Window` を Swapchain ではなくオフスクリーン `RenderTarget` に向ける。OS ウィンドウを開かず、ピクセル取得は readback で行う（後述「ヘッドレスサーフェス」）
2. **決定的 pump** — `Application.run()` の OS ブロッキングループに対し、ブロックせず 1 反復だけ進める `pump` を用意する（後述「pump」）
3. **仮想クロック** — タイマー / caret 点滅 / ダブルクリック判定の時間源を差し替え可能にし、`advanceClock` で時間を進められるようにする（後述「仮想クロック」）

## Component の a11y ファセット
意味的クエリと構造化スナップショットのため、`Component` に「種別」と「アクセシブル名」を持たせる。
既存の `name`（`component.md` 参照）はデバッグ用でルックアップを想定しない旨が明記されているため、それとは別系統として用意する。

`Component` に `role` フィールドを追加する。

```zig
pub const Role = enum {
    none,
    button, toggle_button, checkbox, radio_button,
    label, slider, combobox, text_field, text_area,
    list, scroll_bar, scroll_pane, panel,
    menu, menu_item, checkbox_menu_item, menu_bar, popup_menu, separator,
    window,
};
```

各ウィジェットは `create` 内で自身の `role` をセットする（Button なら `.button` 等）。
デフォルトは `.none`。

アクセシブル名（ボタンのラベル等）と詳細ダンプは、`Component.VTable` を増やさず **opt-in の能力構造体**として持たせる。`drag_source` / `drop_target` / `size_query` と同じパターンで、`component.md`「VTable の関数はできるだけ増やすな」と整合する（全 widget に常時乗るのは VTable だけ、という方針）。テキストは各ウィジェット構造体（`Button.text` 等）が持つため、Component に重複保持しない。

```zig
pub const A11y = struct {
    name: *const fn (*const Component) ?[]const u8,                 // アクセシブル名。テキストを持たないなら null
    dump: ?*const fn (*Component, *Robot.DumpSink) void = null,     // 詳細ダンプ（後段の段階。最小投入では null）
};
// Component に追加: a11y: ?A11y = null
```

robot の**最小投入分は `role`（前述のフィールド）+ `A11y.name` だけ**。`name` は curated ツリーと意味的クエリ（`Driver.find` / `clickOn`）が使う軽いアクセサで、型消去された `*const Component` から comptime リフレクションでウィジェット実体に届かないため、具体型を知るこのアクセサ経由で引く（`@fieldParentPtr` で実体に戻して text を返す）。名前を持たないウィジェット（Filler / Separator 等）は `a11y = null` のままでよい。
2026-06-14 時点では最小5種（Button / Label / CheckBox / RadioButton / TextField）に `A11y.name` を配線済み。メニュー4種（Menu / MenuItem / CheckBoxMenuItem / RadioButtonMenuItem）にも配線済み。Button / Label / CheckBox / RadioButton とメニュー項目系は表示テキストが空でなければそれを返し、Menu はバーのラベル兼サブメニュー見出しの text を返す。TextField は既存の `snapshotTree` 慣行に合わせて現在の入力内容を空文字でも返す。将来 `A11y.value` を additive に足す段階で、TextField の `name`（ラベル）と `value`（内容）を分離する。
MenuBar / PopupMenu ルート / Menu popup ルートのような構造ノードは、名前ではなく `Component.tree_children` で専用 child list を automation tree に露出する。これにより `snapshotTree` と `Driver.find` は container / menu_bar / overlays を同じルート列で走査し、MenuBar と開いている popup menu の項目へ到達する。ComboBox / Slider / List / Table の a11y、`A11y.value`、`A11y.dump` は後段。

`A11y.dump` は詳細ビュー用のフックで、**段階として後回し**（最小投入は `role` + `name` のみ。詳細は後述「詳細ダンプのフィールド選別」と robot.md「機能要望」段階 3.5）。フック内では `name` と同じく `@fieldParentPtr` で実体に戻し、**診断に有用なフィールドを選んで** `sink.field(...)` で明示的に並べる。

```zig
fn dump(self: *Component, sink: *Robot.DumpSink) void {
    const btn: *Button = @fieldParentPtr("component", self);
    sink.field("armed", btn.armed);
    sink.field("pressed", btn.model.pressed);     // モデルから拾う
    sink.field("min_size", btn.component.min_size); // 入れ子 struct は object に展開
}
```

旧案にあった `accessibleState`（押下 / 選択を別途返す）は廃止する。`pressed` / `selected` 等は `dump` が `field` で出すため。

**本物のアクセシビリティとの関係**: ここで入れる `role` + `name` は、将来スクリーンリーダー対応をやるときにも最初に必要となる同じ核なので捨てにならない。その段では `A11y` に state / value / actions 等のアクセサを **additive に足す**だけで済む。OS の支援技術ブリッジ（UI Automation / NSAccessibility / AT-SPI）や通知・関係性は本 doc のスコープ外（後述「制約」）。

## 詳細ダンプのフィールド選別
（詳細ダンプ＝`A11y.dump` は最小投入には含めず、段階として後回し。以下はその設計。）
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
| `tree`（curated） | `snapshotTree` | role / text / rect / focused | 「画面に何があるか」。container / menu_bar / overlays を描画順に見る。ナビゲーション・検証。コンパクトで安定 |
| `dump`（詳細） | `dumpTree` / `dumpNode` | ウィジェットが選別した詳細プロパティ | 「なぜそうなっているか」。診断 |

通常は `tree` でアサートし、状態が想定と食い違ったノードだけ `dumpNode` で深掘りする、という流れを想定する。
`dump` は curated を置き換えるものではなく補完するもの。
意味的クエリ（`Driver.find` / `clickOn`）は軽い `tree` 側（`A11y.name`）を使う。

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

## シナリオ形式とシナリオランナー
robot の最終的な利用形態は、操作と観測を **JSON-lines のシナリオ形式**で記述し、それを**シナリオランナー**が `Driver` / `Robot` に流して実行する形。
「driver（実際にアプリを駆動するもの）」は in-proc の `Driver` / `Robot` であって、この JSON 層ではない。JSON 層は **シナリオの記述形式**と、それを解釈する薄いランナーに分かれる。

### シナリオ形式（記述言語）
1 行 1 ステップの JSON-lines。語彙は次の通り。
人間 / AI が手で書く、レコーダーが記録して吐く（後述「入力の記録」）、どちらも同じ形式を共有する。

| コマンド | 意味 | 主なフィールド |
|---|---|---|
| `act` | 操作を合成して積む | `kind`（click / move / down / up / key / type / scroll / composition）, `x`, `y`, `button`, `code`, `mods`, `text`, `target` |
| `pump` | ループを N ステップ進める | `count`（省略時 1） |
| `advance` | 仮想クロックを進める | `ms` |
| `snapshot` | 観測を返す | `what`（tree / dump / pixels）, `target`（dump 対象の限定。省略時は全体） |
| `query` | 意味的クエリの結果を返す | `role`, `text`, `name` |
| `checkpoint` | 期待状態（curated tree）を埋め込む | `label`, `tree` |
| `quit` | ランナーを終了する（対話モード） | — |

`act` の `target` は意味的指定（`{"role":"button","text":"Save"}`）で、座標の代わりに使える（ランナー内部で `Driver.clickOn` 等に解決する）。
`snapshot` の `tree` は curated ビュー、`dump` は詳細ビュー（`target` で 1 ノードに絞れる）。
座標 / ピクセルは初版から使えるが、`target` による意味的指定は `role` + a11y 名が入って初めて機能する。

### シナリオランナー（2 モード）
同じシナリオ形式・同じインタプリタを、入口だけ変えて 2 モードで使う。違いは「**次のステップを誰が決めるか**」だけで、どちらもランナー（シナリオ語彙 → `Driver` / `Robot` 呼び出し）を共有するので実行経路を二重実装しない。

* **再生（バッチ）** — シナリオ全体（ファイル）を順に実行し、`checkpoint` を照合する。順序は事前固定（記録 or 手書き）。決定的ヘッドレスでの回帰テスト用（後述「シナリオの再生」= `replay`）。
* **対話（stdin REPL）** — 1 行ずつ stdin で受け、即 stdout で応答する同期プロトコル。AI が直前の観測を見て次の 1 手を決める閉ループ。再ビルドなしにターン毎に駆動でき、MCP サーバー化も自然。

応答（対話モード）は `{"ok":true}` か、観測コマンドはペイロード（`tree` / `dump` / 画像パス）、失敗時は `{"error":"NotFound"}` 等。

対話モードの利用イメージ:

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

シナリオランナーの**再生モード**（前述「シナリオ形式とシナリオランナー」）。`Scenario` のステップを順に Robot / Driver 操作へ写して再生する。`target` 解決のため内部で `robot` を包む `Driver` を使う。

* `wait` → `advanceClock(ms)` の後 `pump`。再生クロックは仮想なので、人間の長い手休めもほぼ即座に消化される（実時間 sleep は挟まない）
* `act` → `Driver.clickOn`（`click` の `target` 解決）/ `robot.moveMouse` / `keyDown`+`keyUp` / `typeText` / `scroll` の後 `pump`
* `checkpoint` → `snapshotTree` を取り、`expected` と構造比較。差分があれば `failures` に積む

### 事前条件
再生に使う `robot.window` は、`Scenario.window_w` / `window_h` と同じサイズで生成されていること。
チェックポイントの `rect` 比較がサイズに依存するため、サイズが違うと座標差で偽の不一致が出る。

### シナリオ形式
JSON-lines。1 行 1 ステップで、前述「シナリオ形式とシナリオランナー」と同じ語彙を使う。
したがって「記録 = この形式で書き出す」「再生 = ランナーに食わせる」がそのまま成り立ち、再生経路を二重に実装しなくてよい。

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
* **2 層構造と命名**: 意味を知らないプリミティブ `Robot`（act / drive / observe）と、その上の意味ラッパー `Driver`（`find` / `clickOn`）に分ける。`Driver` は `*Robot` を持つだけ。「driver（駆動するもの）」と呼ぶのは `Driver` だけで、JSON 層は driver ではなく**シナリオ形式 + シナリオランナー**（前述）
* **スコープ外（v1）**: OS レベルのイベント注入（実ウィンドウへの本物のクリック）、複数プロセス分散、本物のアクセシビリティ（スクリーンリーダー / OS の支援技術ブリッジ）。いずれも本 doc の意味的ファセット（`role` + `name`）/ シナリオ形式を土台に後付けできる形にしておく

## 関連 doc
* `component.md` — Component。`role` フィールドと a11y 能力構造体（`A11y { name, dump }`）の追加先（VTable は増やさない）
* `application.md` — イベントループ / タイマー。pump と仮想クロックの追加先
* `window.md` — dispatchInput / 描画。ヘッドレスサーフェスと `input_observer`（レコーダー装着点）の追加先
* `awt/doc/event.md` — 合成する `awt.Event` の型
* `awt/doc/event_queue.md` — `postEvent` による注入経路
* `awt/doc/render_target.md` — ピクセル readback
