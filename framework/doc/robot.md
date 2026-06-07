---
unsafe: true
---

# robot
AI / 自動テストが nimbus アプリのインタラクションを再現・観測するための駆動レイヤー。
2 層に分かれる: **`Robot`**（意味を知らないプリミティブ。合成イベントの注入 / イベントループの単一ステップ駆動 / 仮想時間 / 構造化スナップショット）と、**`Driver`**（その上の薄い意味ラッパー。role + text でウィジェットを名指しする `find` / `clickOn`）。
Swing の `java.awt.Robot` に相当するが、OS レベルではなく framework レベルで動き、ヘッドレス・決定的・意味的（role + text 指定）である点が異なる。意味レイヤーは座標プリミティブへ解決して委譲するだけで、新しい機構は足さない。

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
    text:      ?[]const u8,       // a11y 名（後述「a11y ファセット」。未設定なら null）
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

各ノードのフィールド収集は Component の opt-in 能力構造体 `a11y.dump` フック（`narrative/robot.md`「a11y ファセット」参照。段階としては後回し）が行う。
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
```

`find` は条件 `q`（role / text / name の AND）に一致する Component を、`robot.snapshotTree`（curated）の走査で探して返す。
一致が 0 件なら `error.NotFound`、2 件以上なら `error.Ambiguous`。
`clickOn` は `find` の結果矩形の中心へ `robot.click` を合成する（座標計算を呼び出し側にさせない）。

座標ベースの `Robot.click` が下位プリミティブ、`Driver.clickOn` がその上の意味的ラッパー。
AI は通常 `driver.clickOn(.{ .role = .button, .text = "Save" })` を使い、座標が必要なときだけ `robot.click` を使う。

## 利用例
robot は未実装（段階は「機能要望」）。以下は設計どおりに書いた場合のイメージ。
ヘッドレス入口（`initHeadless`）やシナリオ読み込み（`Scenario.fromJsonl`）など未確定シグネチャは仮で、コメントで示す。

### コードから直接 Robot / Driver で書くテスト
`Robot`（プリミティブ）でイベントを注入し、`pump` で 1 ステップ進め、ハンドル（白箱）または `snapshotTree`（黒箱）で検証する。座標を知らなくても `Driver.clickOn` が role + text で名指しする。

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

対話（stdin REPL）モードや実アプリ内ライブ・サーバーも同じ語彙・同じ `Driver` / `Robot` を叩くだけで、入口（transport）が違うだけ（`narrative/robot.md`「シナリオ形式とシナリオランナー」「機能要望」参照）。

## 機能要望
段階的に組む想定。下にいくほど後段。

* **段階 1**: 合成イベント注入（`postEvent` ラッパー）+ 座標ベース `click` / `keyDown` / `typeText`。既存 API でほぼ実現でき、実ウィンドウに対しても動く
* **段階 2**: ヘッドレスサーフェス + `pump` + 仮想クロック。決定的な `inject → pump → snapshot` ループが成立する
* **段階 3**: `Component.role`（フィールド）+ a11y 名（`A11y` 能力構造体）+ `snapshotTree`（curated）+ 意味レイヤー `Driver`（`find` / `clickOn`）
* **段階 3.5**: `A11y.dump` フック（ウィジェット毎にフィールド選別）+ 詳細ダンプ（`dumpTree` / `dumpNode`）。curated ツリーの上に深掘りビューを足す
* **段階 4**: シナリオ形式 + シナリオランナー（再生 / 対話 stdin REPL）+ MCP サーバー化
* **段階 5**: 入力レコーダー（`Window.input_observer` + `Recorder`）+ シナリオ再生（`replay`）。記録は実ウィンドウ、再生はヘッドレス。意味的解決とチェックポイントは段階 3 のファセットを前提とする
* ライブ・サーバー（当面見送り・メモ）: **対話モードのシナリオランナーを、別実行ファイル(stdin)ではなく実アプリ内(別スレッド + socket)にホストした版**。フラグで起動した実 nimbus アプリにローカルサーバーを立て、実行中の GUI を操作・内省する口を晒す（MCP がそれを叩く）。用途は「AI が実アプリを操作するエージェント」「開発時の GUI REPL」「再現しないバグの現地調査」で、**決定的テストとは別物**（実時間・実イベントなので回帰には使えない）。語彙 / `Driver` / a11y(role+name) は他モードと共通で、transport が socket・host が実アプリという違いだけなので**薄く後付けできる**（新規は socket とフラグゲートのみ、再アーキテクチャ不要）。後で詰める点のメモ:
  - 語彙はサブセット（`act` / `snapshot` / `query` のみ。実ループが回るので `pump` / `advance` は使わない）
  - サーバーは別スレッドなので `EventQueue.postEvent`(act) / `invokeAndWait`(結果が要る snapshot) で UI スレッドへマーシャルする（CLAUDE.md「非同期処理」のプリミティブにそのまま乗る）
  - セキュリティ: 既定オフ・フラグ必須・loopback 限定（+トークン）。外向きの口なので release 既定オンにしない
  - `argc/argv` を framework が予約フラグ（`--nimbus-debug-server` 等）として食うか、アプリが `enableDebugServer(port)` で opt-in するかは要判断
  - 当面はヘッドレス（決定的検証）に集中する
* Zig テストコードの codegen: シナリオから `snapshot_test.zig` 隣に置ける Zig テスト関数を生成（v1 は JSON-lines のみ）
* チェックポイント比較で `rect` を無視するモード: ウィンドウサイズ非依存の比較（v1 はサイズ一致前提）
* 書記素クラスタ単位の `typeText`（v1 はコードポイント単位。CLAUDE.md「書記素クラスタ」と整合）
