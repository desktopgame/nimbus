---
unsafe: false
---

# robot
AI / 自動テストが nimbus アプリのインタラクションを再現・観測するための駆動レイヤー。
2 層に分かれる。
**`Robot`** は意味を知らないプリミティブで、合成イベントの注入 / イベントループの単一ステップ駆動 / 仮想時間 / 構造化スナップショットを行う。
**`Driver`** はその上の薄い意味ラッパーで、role + text でウィジェットを名指しする `find` / `clickOn` を提供する。
Swing の `java.awt.Robot` に相当するが、OS レベルではなく framework レベルで動き、ヘッドレス・決定的・意味的（role + text 指定）である点が異なる。
意味レイヤーは座標プリミティブへ解決して委譲するだけで、新しい機構は足さない。

## 型定義
```zig
pub const Robot = struct {
    app:    *Application,  // 借用。Robot は Application を所有しない
    window: *Window,       // 操作対象ウィンドウ（複数ある場合は対象を保持）
    // 直前に合成したカーソル位置（ウィンドウローカル）。mouseDown / mouseUp / scroll はこの位置で発火し、
    // moveMouse / click が更新する
    cursor: Component.Point,
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
    text:      ?[]const u8,       // a11y 名（後述「a11y ファセット」。未設定なら null）
    rect:      Component.Rect,    // ウィンドウローカルの絶対矩形
    focusable: bool,
    focused:   bool,              // この Component が Window の focus_owner か
    children:  []NodeSnapshot,    // 描画順（奥 → 手前）
};
```

詳細プロパティを出す `dump` ビュー（`DumpNode` 系）は未実装。
設計は `narrative/robot.md`「2 つのスナップショットモード」「詳細ダンプのフィールド選別」を、段階は「機能要望」段階 3.5 を参照。

## Robot の生成
```zig
pub fn init(app: *Application, window: *Window) Robot;
```

`app` と `window` を借用して `Robot` を初期化する。
`cursor` は原点から始まる。
メモリ確保を伴わないので失敗しない（スナップショットの確保は各メソッド側で行う）。

### 事前条件
`window` は `app` に登録済みのウィンドウであること。
ヘッドレスでデバッグする場合、`app` / `window` がヘッドレスモードで生成されていること（後述「ヘッドレスサーフェス」）。
実ウィンドウに対しても動作するが、その場合フォーカス奪取や OS のジッタの影響を受ける。

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
pub fn composition(self: *Robot, text: []const u8, target_start: usize, target_end: usize) void;
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

`window` の自動化ルート（synthetic `.window` ルート配下の container / menu_bar / overlays）を再帰的に走査し、`NodeSnapshot` の木を構築して返す。
ルート列は描画順と同じく container → menu_bar（存在する場合）→ overlays（登録順）で、overlay はモーダル / passthrough を区別せず含める。
各ノードの `role` / `text` は Component の a11y ファセット（後述）から取る。
`rect` は `absoluteOriginInWindow` を使ったウィンドウローカル絶対矩形。
`focused` は `window.focus_owner` との一致で決める。

コンパクトで安定した「画面に何があるか」のビュー。ナビゲーションと検証（クリックが効いたか等）向け。
返り値は `allocator` で確保される。呼び出し側が `freeTree` で解放する。

## ピクセルスナップショットの取得
```zig
pub fn snapshotPixels(self: *Robot, out_rgba: []u8) !void;
pub fn snapshotPng(self: *Robot, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void;
```

ヘッドレスサーフェスのオフスクリーン RT から RGBA8 を読み戻す。
`snapshotPixels` は `awt.RenderTarget.readback` のラッパー、`snapshotPng` は読み戻した結果を `awt.snapshot.writePng` で書き出す。
`out_rgba` の長さはフレームバッファの `width * height * 4` でなければならない。
構造化スナップショットで判定できない視覚バグ（色・描画位置・アンチエイリアス等）用のフォールバック。

### 事前条件
`window` がヘッドレスモードであること。実ウィンドウ（Swapchain）に対しては `error.NotHeadless` を返す。

## 意味レイヤー（Driver）
`find` / `clickOn` は `Robot` ではなく、その上の薄いラッパー `Driver` に置く。
`Driver` は `*Robot` を持つだけの便利クラスで、role + text を矩形に解決して `Robot` のプリミティブへ委譲する（新しい機構は持たない）。

```zig
pub const Driver = struct {
    robot: *Robot,                // 借用。act は robot へ委譲、解決は robot.snapshotTree を読む

    pub fn find   (self: *Driver, q: Query) QueryError!*Component;
    pub fn clickOn(self: *Driver, q: Query) QueryError!void;
};

pub const Query = struct {
    role: ?Component.Role = null,
    text: ?[]const u8 = null,     // a11y 名（後述「a11y ファセット」）との完全一致
    name: ?[]const u8 = null,     // Component.name との完全一致
};

pub const QueryError = error{ NotFound, Ambiguous, OutOfMemory };
```

`find` は条件 `q`（role / text / name の AND）に一致する live `*Component` を返す。
走査範囲は `snapshotTree` と同じ自動化ルート列（container / menu_bar / overlays）で、走査順も `Robot.buildNode` と同じプリオーダー（描画順の奥→手前）に揃える。
`find` は synthetic `.window` ルート自体は作らず、ルート列の各サブツリーだけを対象にする。
`text` は `snapshotTree` の `text` と同じ `Component.a11y.name` から取り、スナップショットに出るノードと query 対象が 1:1 で対応するようにする。
一致が 0 件なら `error.NotFound`、2 件以上なら `error.Ambiguous`。
`clickOn` は `find` の結果矩形の中心へ `robot.click` を合成する（座標計算を呼び出し側にさせない）。
`pump` は呼ばず、呼び出し側がイベント処理のタイミングを決める。
`Query` は最低 1 つの述語（role / text / name）を渡す前提。
全フィールド null の `find(.{})` は未サポートで、走査対象次第でルートを返すか `Ambiguous` / `NotFound` になりうる。

座標ベースの `Robot.click` が下位プリミティブ、`Driver.clickOn` がその上の意味的ラッパー。
AI は通常 `driver.clickOn(.{ .role = .button, .text = "Save" })` を使い、座標が必要なときだけ `robot.click` を使う。

## 利用例
Robot プリミティブ層、前提3ケイパビリティ、最小 a11y 名、`Driver.find` / `clickOn` は実装済み（「機能要望」の実装状況参照）。
`Application.initHeadless` / `frameHeadless` は実コード。
`Robot.init` / `click` / `keyDown` / `typeText` / `pump` / `advanceClock` / `snapshotTree` / `snapshotPixels` も実コード。
`Driver.find` / `clickOn` も実コード。
一方、`Scenario.fromJsonl` / `replay`（B-2）は**未実装**で、それらの行は設計イメージ（コメントで明示）。
座標ベースの `robot.click(x, y, .left)` は下位プリミティブとして今後も使える。

### コードから直接 Robot / Driver で書くテスト
`Robot`（プリミティブ）でイベントを注入し、`pump` で 1 ステップ進め、ハンドル（白箱）または `snapshotTree`（黒箱）で検証する。
座標を知らなくても `Driver.clickOn` が role + text で名指しする。

```zig
const std = @import("std");
const nimbus = @import("nimbus");

test "Save ボタンを role+text で押すと action が飛ぶ" {
    const gpa = std.testing.allocator;

    // ヘッドレス = OS ウィンドウを開かず描画先をオフスクリーン RT に向ける入口。
    // 具体シグネチャは application.md / window.md 側で確定（ここでは仮）。
    var app = try nimbus.Application.initHeadless(gpa, io);
    defer app.deinit();
    const frame = try app.frame("t", 320, 240);

    // 検証用に bool を立てるだけのボタン。
    const Ctx = struct { saved: bool = false };
    var ctx: Ctx = .{};
    const save = try app.button("Save");
    save.component.setBounds(.{ .x = 20, .y = 20, .width = 80, .height = 28 });
    try save.getModel().addActionListener(Ctx, struct {
        fn f(c: *Ctx, _: *const nimbus.ActionEvent) void { c.saved = true; }
    }.f, &ctx);
    try frame.window.add(&save.component);

    // Robot = 意味を知らないプリミティブ / Driver = その上の薄い意味ラッパー。
    var robot = nimbus.Robot.init(app, frame.window);
    var driver = nimbus.Driver{ .robot = &robot };

    try std.testing.expect(!ctx.saved);

    // 座標を知らなくても role+text で名指し → 内部で矩形に解決して click を合成。
    try driver.clickOn(.{ .role = .button, .text = "Save" });
    robot.pump();   // 積んだ合成イベントを 1 ループ分だけ処理（waitEvents しない＝ブロックしない）

    try std.testing.expect(ctx.saved);   // ホワイトボックス: ハンドルを直接見る
}

test "テキストを打つと TextField に反映される" {
    const gpa = std.testing.allocator;
    var app = try nimbus.Application.initHeadless(gpa, io);
    defer app.deinit();
    const frame = try app.frame("t", 320, 240);

    const field = try app.textField("");
    field.component.setBounds(.{ .x = 10, .y = 10, .width = 200, .height = 28 });
    try frame.window.add(&field.component);

    var robot = nimbus.Robot.init(app, frame.window);
    var driver = nimbus.Driver{ .robot = &robot };

    try driver.clickOn(.{ .role = .text_field });  // フォーカスを当てる
    robot.typeText("hello");                        // .char 列を合成（IME 確定相当）
    robot.pump();

    // 黒箱検証: ハンドルを使わず構造化スナップショットで見る経路（記録再生 / AI 駆動と同じ）。
    const snap = try robot.snapshotTree(gpa);
    defer nimbus.Robot.freeTree(gpa, snap);
    // snap を辿って role==.text_field のノードの .text が "hello" のはず。
    // ハンドルがあるなら白箱で直接見てもよい:
    try std.testing.expectEqualStrings("hello", field.getText());

    // 時間依存(キャレット点滅 / ダブルクリック / tween)は仮想クロックで決定的に:
    //   robot.advanceClock(600); robot.pump();   // 実時間 sleep を挟まない
}
```

### シナリオ形式（JSON-lines）を再生する
同じ手順をシリアライズしたのがシナリオ形式（`narrative/robot.md`「シナリオ形式とシナリオランナー」）。手書きでもレコーダー出力でもこの形。

```
{"window":[320,240]}
{"act":"click","target":{"role":"button","text":"Save"}}
{"pump":1}
{"act":"type","text":"hello"}
{"checkpoint":"typed","tree":[{"role":"text_field","text":"hello","rect":[10,10,200,28],"focused":true}]}
```

これを再生（バッチ）するのがシナリオランナーの再生モード `replay`。`target` 解決のため内部で `robot` を包む `Driver` を使う。

```zig
test "シナリオファイルを再生して checkpoint を照合" {
    const gpa = std.testing.allocator;
    var app = try nimbus.Application.initHeadless(gpa, io);
    defer app.deinit();
    const frame = try app.frame("t", 320, 240);
    try buildUi(app, frame);   // 上と同じ UI をコードで組む（窓サイズも一致させる＝再生の事前条件）

    var robot = nimbus.Robot.init(app, frame.window);

    // jsonl を Scenario に読む（writeJsonl の逆。シグネチャは要確定）。
    var scenario = try nimbus.Scenario.fromJsonl(gpa, io, "scenarios/typed.jsonl");
    defer scenario.deinit();

    var result = try nimbus.replay(&robot, scenario, gpa);   // ランナーのバッチモード
    defer result.deinit();
    try std.testing.expect(result.passed);   // 不一致なら result.failures に差分
}
```

対話（stdin REPL）モードや実アプリ内ライブ・サーバーも、同じ語彙・同じ `Driver` / `Robot` を叩くだけで動く。
入口（transport）が違うだけ（`narrative/robot.md`「シナリオ形式とシナリオランナー」「機能要望」参照）。

## 機能要望
段階的に組む想定。下にいくほど後段。

**実装状況 (2026-06-14)**: Robot プリミティブ層（act / `pump` / 仮想クロック / `snapshotTree` / `snapshotPixels`）は実装済み。
前提3ケイパビリティ（ヘッドレス / pump / 仮想クロック）も実装済み。
対応コードは `framework/src/Robot.zig`、`Application.initHeadless`/`frameHeadless`/`now`/`advanceClock`、`Window.initHeadless`/`postInput`。
最小5種（Button / Label / CheckBox / RadioButton / TextField）に a11y 名を配線済み。
メニュー4種（Menu / MenuItem / CheckBoxMenuItem / RadioButtonMenuItem）と `Driver`（`find` / `clickOn`）も実装済み。
`dump`・シナリオランナーは未実装。

* 段階 1: ✅ 実装済み (2026-06-07)。合成イベント注入（`Window.postInput`）+ 座標ベース `Robot.click` / `keyDown` / `typeText`。実ウィンドウに対しても動く
* 段階 2: ✅ 実装済み (2026-06-07)。
  ヘッドレスサーフェス + `pump`（= `Application.tickOnce`）+ 仮想クロック（framework 層、`Application.now`/`advanceClock`）。
  決定的な `inject → pump → snapshot` ループが成立する
* 段階 3: 実装済み。
  実装は `Component.role`（フィールド・全ウィジェット設定済み）、`snapshotTree`（curated; role/rect/focus/text）。
  さらに最小 a11y 名、意味レイヤー `Driver`（`find` / `clickOn`）。
  最小 a11y 名の対象は Button / Label / CheckBox / RadioButton / TextField / Menu / MenuItem / CheckBoxMenuItem / RadioButtonMenuItem。
  TextField の `name` は現時点では入力内容を返す。
  将来 `A11y.value` を additive に足す段階で、`name`（ラベル）と `value`（内容）を分離する。
  menu 系は `Component.tree_children` により MenuBar / PopupMenu / Menu popup ルートの専用 child list も走査対象になる。
  スナップショット / find は container / menu_bar / overlays を同じルート列として扱う。
* 段階 3.5: `A11y.dump` フック（ウィジェット毎にフィールド選別）+ 詳細ダンプ（`dumpTree` / `dumpNode`）。curated ツリーの上に深掘りビューを足す
* 段階 4: シナリオ形式 + シナリオランナー（再生 / 対話 stdin REPL）+ MCP サーバー化
* 段階 5: 入力レコーダー（`Window.input_observer` + `Recorder`）+ シナリオ再生（`replay`）。
  記録は実ウィンドウ、再生はヘッドレス。
  意味的解決とチェックポイントは段階 3 のファセットを前提とする
* ライブ・サーバー（当面見送り・メモ）。
  対話モードのシナリオランナーを、別実行ファイル(stdin)ではなく実アプリ内(別スレッド + socket)にホストした版。
  フラグで起動した実 nimbus アプリにローカルサーバーを立て、実行中の GUI を操作・内省する口を晒す（MCP がそれを叩く）。
  用途は「AI が実アプリを操作するエージェント」「開発時の GUI REPL」「再現しないバグの現地調査」。
  決定的テストとは別物（実時間・実イベントなので回帰には使えない）。
  語彙 / `Driver` / a11y(role+name) は他モードと共通。
  transport が socket・host が実アプリという違いだけなので薄く後付けできる（新規は socket とフラグゲートのみ、再アーキテクチャ不要）。
  後で詰める点のメモ:
  - 語彙はサブセット（`act` / `snapshot` / `query` のみ。実ループが回るので `pump` / `advance` は使わない）
  - サーバーは別スレッドなので、`EventQueue.postEvent`(act) / `invokeAndWait`(結果が要る スナップショット) で UI スレッドへマーシャルする。
    （CLAUDE.md「非同期処理」のプリミティブにそのまま乗る）
  - セキュリティ: 既定オフ・フラグ必須・loopback 限定（+トークン）。外向きの口なので release 既定オンにしない
  - `argc/argv` を framework が予約フラグ（`--nimbus-debug-server` 等）として食うか、アプリが `enableDebugServer(port)` で opt-in するかは要判断
  - 当面はヘッドレス（決定的検証）に集中する
* Zig テストコードの codegen: シナリオから `snapshot_test.zig` 隣に置ける Zig テスト関数を生成（v1 は JSON-lines のみ）
* チェックポイント比較で `rect` を無視するモード: ウィンドウサイズ非依存の比較（v1 はサイズ一致前提）
* 書記素クラスタ単位の `typeText`（v1 はコードポイント単位。CLAUDE.md「書記素クラスタ」と整合）
