# application
Application についての設計ノート。
nimbus アプリのエントリーポイントとなる top-level オブジェクト。
アロケータ、ファクトリ、イベントループ、共有リソース、ウィンドウ追跡を一手に担う。

## 型定義
```zig
pub const Application = struct {
    allocator:    std.mem.Allocator,
    windows:      std.ArrayList(WindowEntry),
    context:      awt.Graphics.Context,
    default_font: awt.Font,
    event_queue:  *awt.EventQueue,

    // ... メソッド
};

const WindowEntry = struct {
    window:       *Window,
    synced_pos:   Point,
    synced_size:  Size,
    synced_title: []const u8,
};
```

## アプリケーションの初期化
```zig
pub fn init(allocator: std.mem.Allocator) !Application;
```

awt の初期化（GLFW）、Device の生成、Graphics.Context（programs / rings / atlas）の構築、デフォルトフォントの読み込み、EventQueue の生成までを一括で行う。
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

1. `awt.waitEvents()` でイベントを待つ（アイドル時の CPU は 0）
2. `event_queue.drain()` で別スレッドからポストされたタスクを UI スレッドで実行
3. 各 Window の `dirty_rect != null` なら `window.redraw()` を呼ぶ
4. position / size / title の差分を OS に push（後述「OS との同期」）
5. close フラグが立った Window を `windows` リストから外して `destroy`

最後のウィンドウが閉じたらループ抜け（「最後のウィンドウを閉じたら exit」セマンティクス）。

## イベントキューの取得
```zig
pub fn getEventQueue(self: *Application) *awt.EventQueue;
```

別スレッドから UI を触りたい場合の窓口。
`queue.invokeLater(...)` / `queue.invokeAndWait(...)` を呼ぶ。
詳細は後述「イベントキュー」を参照。

## デフォルトフォントの差し替え
```zig
pub fn setDefaultFont(self: *Application, path: []const u8) !void;
```

上級利用者向け。
差し替え後に作成したウィジェットは新フォントを使う。既存ウィジェットは変更前のフォントを保持する（font は値型でウィジェット内に複製されているため）。

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

---

## 責務
* アプリ全体の **アロケータ所有者**（ウィジェット / ウィンドウは全部ここの allocator で確保される）
* **ファクトリ**（`app.frame(...)`、`app.label(...)`、`app.button(...)` 等）
* **イベントループの主体**（`app.run()`）
* **共有リソースの所有者**（Graphics.Context、default font、EventQueue）
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

## OS との同期
各イベントループ末尾で、すべての WindowEntry について以下の比較を行う。

* `window.component.position != synced_pos` → `awt_window.setPos(...)` で OS に push、`synced_pos` を更新
* `window.component.size != synced_size` → `awt_window.setSize(...)` で OS に push、`synced_size` を更新
* `window.title != synced_title` → `awt_window.setTitle(...)` で OS に push、`synced_title` を更新

OS callback（ドラッグ / リサイズ等）は `component.position/size` と `synced_xxx` を**両方**更新する。
これがないと「OS が動かした → 末尾の diff で push し返す」の無限ピンポンになる。
詳細は `window.md`「OS との同期」を参照。

## イベントキュー（invokeLater / invokeAndWait）
別スレッドから UI を触る唯一の正規ルート。CLAUDE.md「非同期処理」セクションを参照。

`invokeLater` / `invokeAndWait` は Application のメソッドとしては生やさず、Application が所有する `awt.EventQueue` のメソッドとして提供する。
Application からは `getEventQueue()` でアクセスする。
`invokeAndWait` は別スレッドから呼ぶ前提（UI スレッド自身から呼ぶとデッドロック）。assert で弾く。

EventQueue 自体の詳細な API は awt 側の doc で扱う。
Application はその所有とイベントループ内でのドレイン（`event_queue.drain()`）だけを担当する。

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
Noto Sans（Latin + CJK JP）を `@embedFile` で焼き込んだものを Application init で読み込む。
Label / Button 等のウィジェットファクトリが借用する。寿命は Application と同じ。

`setDefaultFont(path)` で差し替え可能（上級利用者向け、CLAUDE.md「フォント」参照）。

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
var app = try nimbus.Application.init(std.heap.page_allocator);
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
* `textfield()` / `checkbox()` 等の追加ウィジェット factory — ウィジェット追加に合わせて生やす
* 「最後のウィンドウを閉じても常駐したい」ケース向けの hook（現状は全ウィンドウ閉でループ終了）
