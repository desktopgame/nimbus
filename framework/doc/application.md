# application
Application についての設計ノート。
nimbus アプリのエントリーポイントとなる top-level オブジェクト。
アロケータ、ファクトリ、イベントループ、共有リソース、ウィンドウ追跡を一手に担う。

## 型定義
```zig
pub const Application = struct {
    allocator:    std.mem.Allocator,
    device:       awt.Device,
    context:      awt.Graphics.Context,
    default_font: awt.Font,
    event_queue:  *awt.EventQueue,
    windows:      std.ArrayList(WindowEntry),
    timers:       std.ArrayList(Timer),           // 登録中のタイマー (詳細は「タイマー」)
    next_timer_id: TimerId,                       // タイマー id 採番カウンター
    icon_cache:   [lucide.Icon.count]?awt.Image,  // ビルトインアイコン (詳細は後述)

    // 内部所有: programs / ring バッファ / glyph atlas (Graphics.Context が借用)
    // ... メソッド
};

const WindowEntry = struct {
    window:  *Window,
    outer:   *anyopaque,                                          // Frame / Dialog 等の外側ウィジェット
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,      // outer の解放関数
};
```

## アプリケーションの初期化
```zig
pub fn init(allocator: std.mem.Allocator, io: std.Io) !*Application;
```

awt の初期化（GLFW）、Device の生成、Graphics.Context（programs / rings / atlas）の構築、デフォルトフォントの読み込み、EventQueue の生成までを一括で行う。
デフォルトフォントは framework に同梱された Noto Sans JP（`framework/src/noto/`、`nimbus.noto.noto_sans_jp_regular` でも参照可）を `@embedFile` で焼き込んで使う。利用者がフォントバイトを渡す必要は無い。
失敗時は途中まで確保したリソースを全部解放する（強い例外保証）。

## アプリケーションの後片付け
```zig
pub fn deinit(self: *Application) void;
```

残っている Window をすべて破棄したのち、EventQueue → default font → Graphics.Context → awt の順に解放する。
順序を変えると残った Window が context を参照して落ちる。

## イベントループの実行
```zig
pub fn run(self: *Application) !void;
```

全ウィンドウが閉じるまでイベントループを回す。
各反復で次を順に行う。

1. 次のタイマー deadline までイベントを待つ（タイマーが無ければ `awt.waitEvents()`、あれば `awt.waitEventsTimeout(...)`）。アイドル時の CPU は 0
2. due 時刻に達したタイマーを発火する（詳細は「タイマー」参照）
3. `event_queue.drain()` で別スレッドからポストされたタスクを UI スレッドで実行
4. 各 Window の `paint_dirty` または `layout_dirty` が true なら `window.redraw()` を呼ぶ
5. close フラグが立った Window を `windows` リストから外して `destroy`

OS と Window state の同期（位置 / サイズ / タイトル）は v1 では未実装。
将来 `WindowEntry` に `synced_xxx` を追加してループ末尾で diff push する予定（「OS との同期」参照）。

最後のウィンドウが閉じたらループ抜け（「最後のウィンドウを閉じたら exit」セマンティクス）。

## イベントキューの取得
```zig
pub fn getEventQueue(self: *Application) *awt.EventQueue;
```

別スレッドから UI を触りたい場合の窓口。
`queue.invokeLater(...)` / `queue.invokeAndWait(...)` を呼ぶ。
詳細は後述「イベントキュー」を参照。

## フレームの生成
```zig
pub fn frame(self: *Application, title: []const u8, w: u32, h: u32) !*Frame;
```

`Frame` を allocator で確保 → `Frame.init` → `windows` リストに WindowEntry を append、までを行う。
利用者は戻り値の `*Frame` で setter / add を呼ぶだけ。

## ラベルの生成
```zig
pub fn label(self: *Application, text: []const u8) !*Label;
```

`Label.create` をラップして default font と黒色を注入する。

## コンテナーの生成
```zig
pub fn container(self: *Application) !*Container;
```

`Container.create` をラップする。

## パネルの生成
```zig
pub fn panel(self: *Application) !*Panel;
```

`Panel.create` をラップする。
背景色と境界線はデフォルトで null（透明 / 線なし）。
利用者が `panel.setBackground(...)` / `panel.setBorder(...)` で設定する。

## ボタンの生成
```zig
pub fn button(self: *Application, text: []const u8) !*Button;
```

`Button.create` をラップして default font と黒色を注入する。
ButtonModel は内部生成される（`owns_model = true`）。
利用者が共有 Model を使いたい場合は `Button.createWithModel` を直接呼ぶ。

## スライダーの生成
```zig
pub fn slider(
    self: *Application,
    orientation: Slider.Orientation,
    min: i32,
    value: i32,
    max: i32,
) !*Slider;
```

`Slider.create` をラップする。
BoundedRangeModel は内部生成される（`owns_model = true`）。
共有 Model 版は `Slider.createWithModel` を直接呼ぶ。

## ビルトインアイコンの取得
```zig
pub fn icon(self: *Application, id: lucide.Icon) !awt.Image;
```

`nimbus.lucide.Icon` で定義されたビルトインアイコン（PNG 化済み、64×64）を、デコード済みの GPU `awt.Image` として返す。
初回呼び出し時に PNG をデコードして GPU テクスチャにアップロードし、内部キャッシュに格納する。
2 回目以降の同じ `id` に対する呼び出しは、キャッシュ済みの `awt.Image` をそのまま返す。

返り値は `Application` が所有する。利用者は `deinit` を呼んではならない。
寿命は `Application` と同じで、`app.deinit()` 時にキャッシュごとまとめて解放される。

利用者独自の PNG / JPEG を使いたい場合は `app.icon` ではなく `awt.Image.fromMemory` を直接呼ぶ。
こちらは利用者が `deinit` を呼んで寿命を管理する。

## ツールバーの生成
```zig
pub fn toolBar(self: *Application) !*Panel;
```

`Panel` を内部で生成し、ツールバー向けにプリセットを適用して返す：

* 背景色: 薄グレー（メニューバーと揃える）
* レイアウト: `BoxLayout.horizontal()`
* 高さ: 32px 固定（`min_size.height` / `max_size.height` 共に 32）

返り値は普通の `*Panel` なので、`tb.container.add(&btn.component)` で子ボタンを追加して、`BorderLayout.add(window.container, .north, &tb.container.component)` で Frame 上部（メニューバーがあればその下）に取り付ける。
専用型 `ToolBar` は作らない（Panel + BoxLayout のレシピに名前を付けただけ）。

## メニュー系の生成
```zig
pub fn menu             (self: *Application, text: []const u8) !*Menu;
pub fn menuItem         (self: *Application, text: []const u8) !*MenuItem;
pub fn checkBoxMenuItem (self: *Application, text: []const u8) !*CheckBoxMenuItem;
pub fn menuBar          (self: *Application) !*MenuBar;
pub fn popupMenu        (self: *Application) !*PopupMenu;
pub fn menuSeparator    (self: *Application) !*MenuSeparator;
```

各 widget の `create` をラップする。
`menu` / `menuItem` / `checkBoxMenuItem` / `menuBar` は default font (`pixel_size = 14`) と濃いグレー (`rgb(0.1, 0.1, 0.1)`) を注入する。
`popupMenu` / `menuSeparator` は font / color を取らないので素通しのラッパー。

専用フォント・色を使いたい場合は各 widget の `create` / `createWithModel` を直接呼ぶ。

利用例:
```zig
const bar = try app.menuBar();
const file = try app.menu("File");
const open = try app.menuItem("Open");
try open.getModel().addActionListener(onOpen, &ctx);
try file.add(&open.component);
try file.addSeparator();
try file.add(&(try app.menuItem("Quit")).component);
try bar.add(file);
try frame.setMenuBar(bar);
```

## テキストフィールドの生成
```zig
pub fn textField(self: *Application, initial_text: []const u8) !*TextField;
```

`TextField.create` をラップして default font (14px) と黒色を注入する。
背景はデフォルトで白。
`initial_text` は内部 UTF-8 バッファにコピーされる (呼び出し後すぐ free しても安全)。

詳細は `textfield.md` を参照。

## ワンショットタイマーの登録
```zig
pub fn setTimeout(self: *Application, ms: u32, cb: TimerCallback, user_data: *anyopaque) !TimerId;
```

`ms` ミリ秒経過後に `cb(user_data)` を **UI スレッドで一度だけ**呼ぶよう登録する。
返り値の `TimerId` は `clearTimer` でキャンセルに使える（発火前に widget が destroy される場合など）。
発火後は内部リストから自動的に外れる。
内部で `awt.postEmptyEvent()` を呼んで run ループを起こすので、別スレッドから安全には呼べない（タイマーは UI スレッドで呼び出す前提）。

## 繰り返しタイマーの登録
```zig
pub fn setInterval(self: *Application, ms: u32, cb: TimerCallback, user_data: *anyopaque) !TimerId;
```

`ms` ミリ秒ごとに `cb(user_data)` を繰り返し UI スレッドで呼ぶよう登録する。
最初の発火は登録から `ms` 経過後。停止は `clearTimer` で行う。
ループが詰まって複数 tick 分遅延した場合、tick を取り戻すような catch-up は行わず**まとめて 1 回**だけ発火する（次回 due は `now + period`）。

## タイマーの解除
```zig
pub fn clearTimer(self: *Application, id: TimerId) void;
```

指定 id のタイマーを内部リストから外す。
既に発火・解除済み、または未知の id は no-op。

---

## 責務
* アプリ全体の **アロケータ所有者**（ウィジェット / ウィンドウは全部ここの allocator で確保される）
* **ファクトリ**（`app.frame(...)`、`app.label(...)`、`app.button(...)` 等）
* **イベントループの主体**（`app.run()`）
* **共有リソースの所有者**（Graphics.Context、default font、EventQueue、ビルトインアイコンキャッシュ）
* **ウィンドウ追跡**（全 Window を `WindowEntry` で持ち、OS state diff を末尾で push）

## なぜ Application を作るのか（Swing との違い）
Swing には Application 型が無く、`JFrame` を直接 `new` する。
nimbus はあえて Application を持つ。

* **アロケータの集約**: Zig は GC が無いので allocator がアプリ全体に必要。ファクトリが allocator を握るのが素直
* **イベントループの隠蔽**: 利用者が `glfwPollEvents` / `glfwWaitEvents` を直接触らなくて済む。`app.run()` 1 つで起動
* **共有リソースの一元化**: Graphics.Context（programs / rings / atlas）や default font は重く、アプリ全体で 1 セット使うのが自然
* **ウィンドウ追跡**: 全 Window を 1 箇所で管理する場所が必要（OS state diff、close 回収、全ウィンドウクローズ判定）

参考: 後発の SwingApplicationFramework（JSR 296）は `Application` を導入していた（その後消えたが）。
nimbus は最初から入れる。

## プロセス内で 1 インスタンス
GLFW は `glfwInit` がプロセス単位なので、Application も実質シングルトン。
ただし型レベルでシングルトン強制（`getInstance()` パターン）はしない。
単に「2 個作るとうまく動かない」と doc で握る。

理由: テスト時に複数 Application を入れ替えて使うケース（mock や差し替え）が将来出るかもしれないので、強制よりは規約に留めておく。

## ファクトリの責務
ファクトリは「allocator 確保 + init + install + tracking 登録」を 1 まとめにする（`component.md`「ライフサイクル」参照）。
利用者は戻り値のポインタを使って setter / add 等を呼ぶだけで、メモリの面倒は見ない。

Window 系のファクトリは追加で `windows` リストへの append が要る。
ウィジェット系のファクトリはウィジェットの `create` をラップするだけ（default font / color を注入する）。

## OS との同期 (機能要望)
v1 では未実装。
将来は各イベントループ末尾で、すべての WindowEntry について以下の比較を行う予定。

* `window.component.position != synced_pos` → `awt_window.setPos(...)` で OS に push、`synced_pos` を更新
* `window.component.size != synced_size` → `awt_window.setSize(...)` で OS に push、`synced_size` を更新
* `window.title != synced_title` → `awt_window.setTitle(...)` で OS に push、`synced_title` を更新

OS callback（ドラッグ / リサイズ等）は `component.position/size` と `synced_xxx` を**両方**更新する想定。
これがないと「OS が動かした → 末尾の diff で push し返す」の無限ピンポンになる。
現状の `Window.setTitle` / `Window.dispose` は best-effort no-op、または awt-c が直接 push する暫定実装になっている (`window.md` 参照)。

## イベントキュー（invokeLater / invokeAndWait）
別スレッドから UI を触る唯一の正規ルート。CLAUDE.md「非同期処理」セクションを参照。

`invokeLater` / `invokeAndWait` は Application のメソッドとしては生やさず、Application が所有する `awt.EventQueue` のメソッドとして提供する。
Application からは `getEventQueue()` でアクセスする。
`invokeAndWait` は別スレッドから呼ぶ前提（UI スレッド自身から呼ぶとデッドロック）。assert で弾く。

EventQueue 自体の詳細な API は awt 側の doc で扱う。
Application はその所有とイベントループ内でのドレイン（`event_queue.drain()`）だけを担当する。

## タイマー
caret 点滅、ツールチップの遅延表示、tween アニメーション等の「未来のある時刻に UI スレッドで処理を実行したい」用途を、Application が一元的に提供する。

仕組み:
* `setTimeout` / `setInterval` で登録すると `timers` リストに `Timer` が積まれ、`due_time = awt.time() + delay` がセットされる
* run ループは毎回開始時に最も近い `due_time` までの残り秒を計算し、`awt.waitEventsTimeout(delta)` でブロックする
* OS イベント到着 or タイムアウトのどちらで戻っても `fireDueTimers` が `due_time <= now` の Timer を順に呼ぶ
* ワンショット (`period_ms = 0`) は発火後にリストから外す。繰り返し (`period_ms > 0`) は `due_time = now + period_ms / 1000` で更新する

精度:
* GLFW の `glfwWaitEventsTimeout` 精度に依存。Windows では 1ms オーダーまで詰められるが、OS スケジューラ遅延で数ミリ秒のジッタは普通に発生する
* ms 精度が要求される用途 (60fps 連続アニメーション等) には不向き。`requestAnimationFrame` 相当は機能要望

スレッド:
* `setTimeout` / `setInterval` / `clearTimer` / `cb` の呼び出しはすべて UI スレッドで完結する前提
* 別スレッドから時間遅延でタスクを差し込みたい場合は、別スレッド側で `std.Thread.sleep` してから `event_queue.invokeLater(...)` を呼ぶ方が安全

注意:
* タイマー登録の所有権は Application。`clearTimer` を呼ばずに widget を destroy するとコールバックが解放済みメモリを触る。widget の `uninstall` で必ず `clearTimer` を呼ぶ規約
* 発火順は「due_time の昇順」ではなく `timers` への登録順なので、同時刻に複数 due があるケースでは登録順に発火する (ms 単位で別なら昇順と等価)

## SecondaryLoop
入れ子イベントループ。
`Application.run()` の中からさらに小さなイベントループを回し、何らかの条件が満たされたら呼び出し元に戻る。
Swing の SecondaryLoop / Qt の QEventLoop に相当する。

主な用途は将来追加されるモーダルダイアログの実装だが、それ以外にも「同期的に応答待ちしたいがイベントは流したい」という場面で利用者が直接使える。

SecondaryLoop は awt 側のプリミティブとして提供される。
Application は内部実装では利用しないが、必要なら利用者が直接インスタンス化して使用する。

## 共有リソース

### Graphics.Context
programs（Color / Image / RoundedRect / Text）と ring バッファ（vertex_ring / uniforms / quad_index）と glyph_atlas を束ねたもの。
Application が所有し、全 Window が借用する。

なぜ Application 所有か:
* programs は shader compile を含むので 1 回作って共有が自然
* ring バッファ / atlas はメモリが大きく、Window 毎に持つと無駄
* 全 Window が同じ font atlas を共有すると glyph cache 効率が良い

### default_font
framework に同梱された Noto Sans JP（Latin + CJK JP）を `@embedFile` で焼き込んだものを Application init で読み込む。
本体は `framework/src/noto/NotoSansJP-Regular.ttf`、Zig 側からは `nimbus.noto.noto_sans_jp_regular` でバイト列としても参照できる（awt を直接叩く利用者向け）。
Label / Button 等のウィジェットファクトリが借用する。寿命は Application と同じ。

v1 ではランタイムでの差し替え API は無い。
差し替えたい場合は CLAUDE.md「フォント」を参照しつつ、利用者が独自 widget factory を組む形になる（機能要望）。

### icon_cache
ビルトインアイコン（`nimbus.lucide.Icon` の各エントリ）を、初回参照時にデコード + GPU テクスチャ化した `awt.Image` のキャッシュ。
`[lucide.Icon.count]?awt.Image` の配列で、添字は `@intFromEnum(icon)`。
Application init 時は全スロット null で、`app.icon(.foo)` の初回呼び出しでスロットが埋まる。
Application が所有し、Button / MenuItem 等が借用する。寿命は Application と同じ。

なぜ Application 所有か:
* 同じアイコンを複数のウィジェットが使い回しても GPU テクスチャは 1 つで済む
* 利用者が `awt.Image.fromMemory` / `deinit` を自分で書く必要が無くなり、boilerplate が消える
* デコード + GPU アップロードは重いので、初回 1 回だけにしたい
* 寿命がウィジェットより長い場所に置く必要があり、Application が自然な置き場所

### サイズコストの整理
ランタイムメモリ:
* `?awt.Image` 1 スロットは数十バイト程度。1711 エントリでも数十 KB に収まるため、Application が常時抱える分は無視できる。
* GPU 側のメモリは初回呼び出し時にしか確保されないので、未使用アイコンに対する GPU メモリのコストは 0。

バイナリサイズ:
* `Application.icon` がランタイムの `Icon` 値を受け取る設計のため、コンパイラ／リンカは「どのアイコンが使われるか」を静的に判定できず、`framework/src/lucide/icons.zig` の `all_bytes` 経由で**全 PNG が実行ファイルに残る**。
* 実測値: `widget_menu` (ReleaseSmall) で +1.7 MB（アイコンを 1 つも使わない `widget_simple` は影響なし）。
* これは設計上の意図的トレードオフ。`app.icon(.foo)` の使い勝手と、コンパイル時 typo チェックを優先した結果。
* switch 分岐版 (`switch (self) { .save => @embedFile(...), ... }`) でも実測差は出なかった。`Icon.bytes()` という間接層を挟む限り、デッドコード除去は原理的に効かない。

## 終了条件
`run()` は `windows.items.len > 0` の間ループする。
最後のウィンドウが閉じた時点でループを抜けて return する。
「ウィンドウが全部閉じても常駐したい」ケース向けの hook は将来追加する（機能要望参照）。

## 関連 doc
* `window.md` — Window / WindowEntry の詳細、イベントループとの関係
* `frame.md` — Frame factory の流れ
* `component.md` — ファクトリのライフサイクル / メモリ解放
* `binding.md` — Application 経由のファクトリが他言語バインディングでどう見えるか

---

## 利用例
基本形。

```zig
var app = try nimbus.Application.init(init.gpa, init.io);
defer app.deinit();

const frame = try app.frame("hello nimbus", 800, 600);
const label = try app.label("こんにちは!");
label.component.setBounds(.{ .x = 30, .y = 30, .width = 400, .height = 40 });
try frame.window.add(&label.component);

try app.run();   // event loop。全ウィンドウ閉じで抜ける
```

別スレッドから UI に値を反映する例。

```zig
// UI スレッド
const queue = app.getEventQueue();

// 別スレッドで時間のかかる処理
const worker_thread = try std.Thread.spawn(.{}, struct {
    fn run(q: *awt.EventQueue, lbl: *Label) !void {
        const result = doExpensiveWork();
        try q.invokeLater(updateLabelTask, .{ .label = lbl, .text = result });
    }
}.run, .{ queue, label });
defer worker_thread.join();

try app.run();
```

## 機能要望
* `checkbox()` / `radio()` / `combo()` 等の追加ウィジェット factory — ウィジェット追加に合わせて生やす
* 「最後のウィンドウを閉じても常駐したい」ケース向けの hook（現状は全ウィンドウ閉でループ終了）
* `requestAnimationFrame` 相当 — vsync 同期での連続再描画 (現状のタイマーは ms オーダーの精度)
* min-heap でタイマーを管理して `earliestDueIn` を O(1) に（現状は O(n)、数十〜数百個までは問題ない）
