# textfield-plan
TextField 実装の計画メモ。コンパクション後に拾い直して着手するための前提とステップを並べる。
完了したら本ファイルは削除してよい。

## 現状 (この計画を書いた時点)
- audit (`doc/audit-2026-05-23.md`) の High 項目はすべて解消済み (Application.frame errdefer 含む)。
- Medium の doc 整合性 (menu* 型定義、popup_menu の popup_root、render_target の io 引数、device.md の nmWaitDeviceIdle、component.md の getBounds/getName レシーバ、window.md の dirty_rect 残存) も解消済み。
- examples/hello の二重 deinit も解消済み。
- framework.log / awt.log 独立 dispatcher 体制が整っており、握りつぶし箇所には `log.warn` が仕込まれている。
- ビルド: `zig build test --summary all` で計 23 tests (awt 8 + framework 6 + snapshot 9) すべて pass、`exit=0`。
- 次のステップは**ステップ B: TextField の必須インフラ**から。

## v1 スコープ (CLAUDE.md「文字コード」「書記素クラスタ」より)
- 単一行 (TextArea は別タスク)
- LTR 言語のみ
- **codepoint 単位** で OK (書記素クラスタは将来移行、ただし「内部 byte 位置を直接外に出さない」抽象を v1 から守る)
- IME 最小: composition string inline 表示は強推奨だが、ASCII 動作する素体を先行で出してよい
- 標準編集: insert / delete / cursor move (←/→/Home/End/Backspace/Del) / 選択 (Shift+arrow / mouse drag) / Ctrl+C/V (clipboard)

---

## ステップ B: 必須インフラ (依存順)

### B-1. char (text input) コールバック
**目的**: `'a'` 押下で `'a'` が入る、Shift+1 で `'!'` が入る (キーボードレイアウト依存の文字を OS から受け取る)。`KeyEvent` だけでは AZERTY 等のレイアウトを再構成できない。

**touch**:
- `awt-c/src/internal.h`: 追加
  ```c
  typedef void (*nmCharCallback)(nmWindow* w, uint32_t codepoint, void* user_data);
  void nmSetCharCallback(nmWindow* self, nmCharCallback cb, void* user_data);
  ```
- `awt-c/src/glfw_shim.c`: `glfwSetCharCallback` をブリッジ。`nmWindowCallbacks` に `char_cb` / `char_user_data` フィールドを足す。on_char ヘルパーで dispatch。
- `awt/src/Event.zig`: `Payload` に `char: CharEvent` 追加。`CharEvent { codepoint: u32 }` だけでよい (modifiers は char callback の入力に含まれない)。`fromCBits` 系のヘルパーは不要。
- `awt/src/Window.zig`: char callback 配線メソッド `setCharCallback(cb, user_data)` を生やす。
- `framework/src/Window.zig`: install で `awt_window.setCharCallback(onChar, ...)` を追加。`onChar` 内で `awt.Event{.payload = .{.char = .{.codepoint = cp}}}` を組んで `event_queue.postEvent(...)` で post (既存の onKey と同じパターン)。

**動作確認**:
- 既存ウィジェットは char を無視するので、追加だけでは挙動変化なし。
- TextField を後で実装した段階で「a を押すと a が入る」で検証。

### B-2. フォーカス管理 (最小サブセット)
**目的**: 複数 TextField がある時、どこに文字を流すか決める。

**touch**:
- `framework/src/Component.zig`:
  - フィールド追加: `focusable: bool` (デフォルト false)。
  - メソッド追加:
    ```zig
    pub fn isFocusable(self: Component) bool;
    pub fn setFocusable(self: *Component, v: bool) void;
    pub fn requestFocus(self: *Component) void;  // parent chain を上って Window を見つけ requestFocusFor を呼ぶ
    ```
- `awt/src/Event.zig`: `Payload` に `focus: FocusEvent { gained: bool }` 追加。
- `framework/src/Window.zig`:
  - フィールド追加: `focus_owner: ?*Component = null`。
  - メソッド追加:
    ```zig
    pub fn requestFocusFor(self: *Window, c: ?*Component) void;
    // 旧 owner に FocusEvent{.gained=false} を dispatch、新 owner に {.gained=true} を dispatch、
    // それぞれ paint_dirty を立てる (focus ring 描画切替のため)。
    ```
  - `dispatchInput` (`framework/src/Window.zig:377-471`) の `.key` / `.char` 分岐を「`focus_owner` が non-null ならそこだけに送る、null ならフォールバックで現状通り全 fan-out」に変更。
  - mouse `.press` の hit-test 後に「当たった widget が `isFocusable()` なら自動で `requestFocusFor(widget)`」を追加。overlay/menu_bar 経路は除外 (menu クリックで focus を奪わない)。
- `framework/src/Container.zig:171-178` の素朴な key fan-out コメントを更新 (新仕様への参照を追加するか、focus_owner null 時のフォールバックである旨を明記)。
- `framework/doc/window.md`: 「フォーカス」セクション追加。
- `framework/doc/component.md`: `focusable` / `requestFocus` を追加。
- `awt/doc/event.md`: `FocusEvent` を「機能要望」から本文に昇格。

**Tab traversal は B-2 のスコープ外**: マウスクリックで切替できればまず動く。Tab/Shift+Tab は ステップ D (後回し OK) で実装。

**動作確認**:
- 既存ウィジェット (Button/Slider 等) は `focusable = false` のままなので挙動変化なし。
- TextField で `focusable = true` にセットし、複数置いてマウスクリックで切り替わるか確認。

### B-3. クリップボード
**目的**: Ctrl+C/V/X が TextField v1 スコープ内。

**touch**:
- `awt-c/src/internal.h`: 追加
  ```c
  /* Returned pointer owned by awt-c; valid until next nmGet/SetClipboardString
   * call. NULL if clipboard is empty / not text. */
  const char* nmGetClipboardString(nmWindow* self);
  void        nmSetClipboardString(nmWindow* self, const char* utf8);
  ```
- `awt-c/src/glfw_shim.c`: `glfwGetClipboardString` / `glfwSetClipboardString` をラップ。
- `awt/src/Window.zig`: `pub fn getClipboardString() ?[*:0]const u8` と `pub fn setClipboardString([*:0]const u8) void` を生やす。または独立 `awt/src/Clipboard.zig` でも可 (Window メソッドの方がシンプル)。
- `framework/src/Application.zig`: ヘルパー `pub fn clipboardGet(self: *Application, win: *Window) ?[]const u8` 等を生やすかは判断 (TextField が `&frame.window` を持っているなら Window 直叩きで十分)。
- `awt/doc/window.md`: 新規セクション「クリップボード」 (`awt/src/Window.zig` には現状 doc 無いがこのタイミングで作るのが良い)。

**動作確認**:
- TextField を実装してから「Ctrl+C で選択範囲がコピーされる、Ctrl+V で貼り付けされる」で検証。

### B-4. タイマー (caret blink 用)
**目的**: caret を 500ms 周期で点滅させる。

**touch**:
- `awt-c/src/internal.h`: 追加
  ```c
  /* Wait up to `seconds` (relative). Returns even if no events arrive. */
  void nmWaitEventsTimeout(double seconds);
  ```
- `awt-c/src/glfw_shim.c`: `glfwWaitEventsTimeout(seconds)` を呼ぶだけの薄ラッパー。
- `awt/src/root.zig`: `pub fn waitEventsTimeout(seconds: f64) void { c.nmWaitEventsTimeout(seconds); }`
- `framework/src/Application.zig`:
  - 内部に `timers: std.ArrayList(Timer)` を持つ (`Timer { id: u32, due_time: f64, period_ms: u32, cb: ..., user_data: ... }`)。`period_ms == 0` がワンショット、>0 が繰り返し。
  - メソッド追加:
    ```zig
    pub const TimerId = u32;
    pub fn setTimeout (self: *Application, ms: u32, cb: TimerCb, ud: *anyopaque) !TimerId;
    pub fn setInterval(self: *Application, ms: u32, cb: TimerCb, ud: *anyopaque) !TimerId;
    pub fn clearTimer (self: *Application, id: TimerId) void;
    ```
  - `run` ループ (`framework/src/Application.zig:144-168`) を `awt.waitEvents` → `awt.waitEventsTimeout(next_due - awt.time())` に変更。次の `due_time` を計算する内部ヘルパーを足す。
- `framework/doc/application.md`: 「タイマー」セクション追加。

**動作確認**:
- 別途 `examples/timer_demo` を作るほどではないが、TextField 実装後に caret が点滅すれば OK。
- 単体テスト: `setTimeout(50ms, ...)` を仕込んで 50ms 後にコールバックが呼ばれることを `std.time.Timer` で測る、くらいは追加してよい。

---

## ステップ C: TextField 本体

### C-1. TextField の設計
**ファイル**: `framework/src/TextField.zig` (新規)、`framework/doc/textfield.md` (新規)。

**state (内部)**:
```zig
component:        Component,
text:             std.ArrayList(u8),    // UTF-8 内部表現
caret_byte:       usize,                 // caret のバイト位置
mark_byte:        usize,                 // 選択の他端 (caret == mark なら選択なし)
font:             awt.Graphics.TextFont,
color:            awt.Graphics.Color,
background:       awt.Graphics.Color,
caret_visible:    bool,                  // タイマーで toggle
blink_timer_id:   ?Application.TimerId,
allocator:        std.mem.Allocator,
change_listeners: ChangeListenerList,
```

**重要な抽象境界**: caret_byte / mark_byte は内部実装。外に出すヘルパー (`selectionStart() Codepoint`, `setCaretAtCodepoint(idx)` 等) は codepoint index で受け、内部で byte position に変換する。これにより将来書記素クラスタへ移行する時、抽象を一段挟む。

**factory**:
- `pub fn create(allocator, font, color) !*TextField`
- `Application.textField(text: []const u8) !*TextField` (default font / black / white 背景を注入)

**vtable**:
- `install`: `addChangeListener` 不要 (内部ロジックのみ)、`focusable = true` をセット、`Application.setInterval(500, blinkTick, ...)` を仕込んで `blink_timer_id` を保存。
- `uninstall`: `clearTimer(blink_timer_id)`。
- `paint`: 背景塗り → 選択範囲ハイライト (`fillRect`) → テキスト描画 (`drawString`) → caret 描画 (`caret_visible && focus_owner == self` のとき 1px 縦線 `fillRect`)。
- `processEvent`: 後述の state machine。
- `destroy`: text バッファ free + Component 解放。

### C-2. キー処理 (state machine)
- `.key` (action=press) 受領時:
  - `Left` / `Right`: caret_byte を 1 codepoint 左右へ。Shift 押下時は mark_byte を維持 (選択拡張)、未押下なら mark_byte = caret_byte。
  - `Home` / `End`: caret_byte を 0 / text.items.len へ。Shift 同上。
  - `Backspace`: 選択あり → 選択範囲を削除。なし → caret 直前 1 codepoint を削除。
  - `Delete`: 選択あり → 選択削除。なし → caret 直後 1 codepoint を削除。
  - `Enter`: 単一行なので無視 (将来 `submit` イベント発火?)
  - Ctrl+A: 全選択 (caret_byte = text.len, mark_byte = 0)。
  - Ctrl+C: `selectedText()` を clipboard.setString に。
  - Ctrl+X: copy + 削除。
  - Ctrl+V: clipboard.getString を caret 位置に insert。
- `.char` 受領時: 選択あればまず削除、その後 caret 位置に codepoint を UTF-8 で insert、caret_byte を進める。fireChangeListeners。

### C-3. マウス処理
- `.mouse press` (left, inside): hit-test で caret_byte を click 位置に、mark_byte = caret_byte。`ev.requestCapture(self)` で drag を捕まえる。
- `.mouse move` (drag 中): caret_byte を更新 (mark_byte は維持) → 選択拡張。
- `.mouse release`: capture 解除 (automatically via Window.mouse_capture clear)。

### C-4. hit-test ヘルパー (TextField 内ローカル)
```zig
/// Walk UTF-8 codepoints, sum font.glyphAdvance, return the byte position
/// whose left edge is closest to `x` (in widget-local coords, accounting for
/// internal scroll if added later).
fn hitTestByteAt(self: TextField, x: f32) usize;

/// Inverse: byte position → pixel x (left edge of the codepoint).
fn xAtByte(self: TextField, byte_pos: usize) f32;
```
`awt.Font.glyphAdvance(codepoint, pixel_size) f32` (`awt/src/Font.zig:89-91`) があるので自前計算で済む。`awt.Font` への新規 API は v1 では不要。

### C-5. selection 描画
- `selectionStartByte()` = `min(caret, mark)`, `selectionEndByte()` = `max(caret, mark)`。
- 範囲が空でなければ `xAtByte(start)` から `xAtByte(end)` までを薄い青で `fillRect`。
- そのあとテキストを通常色で `drawString` (text を背景の上に重ねる)。

### C-6. caret 描画
- focus_owner != self → caret 描画なし。
- focus_owner == self → `caret_visible` (タイマーで toggle される) のときだけ 1px × line_height の縦線を `xAtByte(caret_byte)` の位置に `fillRect`。
- focus gained 時に `caret_visible = true` リセット + 500ms タイマー再起動。focus lost 時に caret 描画停止。

### C-7. レイアウト
- `applyMetrics`: `min_size.width = font.glyphAdvance('M') * default_column_count + padding`、`min_size.height = font.metrics().line_height + padding * 2`。`max_size.height = min_size.height` (1 行で固定)。`grow_x = 1` (フォーム幅に伸びる)。
- default_column_count は 20 程度をデフォルトに。setter で外から変更可能。

### C-8. Application factory
```zig
pub fn textField(self: *Application, initial_text: []const u8) !*TextField {
    return try TextField.create(self.allocator, self.menuFont(), menu_color, initial_text);
}
```
(menuFont を流用するか、`labelFont()` 等にリネームするか要検討。)

### C-9. doc
- `framework/doc/textfield.md` 新規。型定義 / create / setText / getText / 選択範囲 API / focus 連携 / clipboard / IME 状況。
- `framework/doc/application.md`: factory リストに `textField` 追加。

### C-10. tests
- 単体: hit-test の純粋計算 (空文字列 / 1 文字 / multi-byte UTF-8)、selection 範囲計算、insert/delete の byte 位置整合性。GPU 不要なロジックは多い。
- snapshot: `textfield_empty` / `textfield_typed` / `textfield_selected` / `textfield_caret_visible`。focus 中の caret 描画は静的画像で取れるよう、テスト時は blink_timer を止めて `caret_visible = true` 固定で。

### C-11. 例題
- `examples/textfield_demo/main.zig` 新規: 上に label「入力されたテキスト:」、下に TextField、`addChangeListener` でリアルタイムに label を更新する小さな例。`zig build run-textfield_demo` で起動できる形に。
- `build.zig` に `addExample(b, "textfield_demo", ...)` を追加。

---

## ステップ D (後回し OK)
ステップ C をマージしたあとに着手:

- **IME composition (Windows WM_IME_* / macOS NSTextInputClient)**: 別作業として `awt-c/src/glfw_shim.c` で WNDPROC subclass、`awt-c/src/internal.h` に `nmSetCompositionCallback` / `nmSetCompositionCursorPos` 追加、`awt.Event.Payload` に `composition` variant 追加、TextField 側で preedit string を inline 描画。CLAUDE.md「優先度高で取り組みたい」項目だが分量が大きいので feature flag で切れる構造に。
- **Tab / Shift+Tab traversal**: `Container` に「次の focusable な子を探す」depth-first ヘルパー、Tab キーで Window が `focus_owner` を次の focusable に移す。
- **部分再描画 (dirty rect)**: caret 点滅で全画面再描画になるのが嫌な規模になったら。
- **書記素クラスタ移行**: C-1 の codepoint API を grapheme cluster API に置き換える内部実装変更だけで済む形にしておく。

---

## 着手の入口チェックリスト
コンパクション後にこの計画を拾った時に、最初に確認すること:

1. `git status` でリポジトリの状態確認。前回 `zig build test` が通っていたかを `zig build test --summary all` で再確認。
2. このメモの「現状」セクションに書いた前提が崩れていないか軽くスキャン (audit doc の High が再オープンしてないか等)。
3. ステップ B-1 (char コールバック) から着手。`awt-c/src/internal.h` と `awt-c/src/glfw_shim.c` を読み、既存の `nmSetKeyCallback` の流儀を真似て `nmSetCharCallback` を足す。
4. 各ステップ完了ごとに `zig build test` を走らせ pass を確認してから次へ。

---

## 主な参照ファイル (絶対パス)
- `C:\Users\dansaka\Work\Repository\nimbus\awt-c\src\internal.h` — C surface 追加先 (char / clipboard / waitEventsTimeout)
- `C:\Users\dansaka\Work\Repository\nimbus\awt-c\src\glfw_shim.c` — GLFW ブリッジ実装先
- `C:\Users\dansaka\Work\Repository\nimbus\awt\src\Event.zig` — Payload に `char` / `focus` variant 追加
- `C:\Users\dansaka\Work\Repository\nimbus\awt\src\Window.zig` — char / clipboard コールバック配線
- `C:\Users\dansaka\Work\Repository\nimbus\awt\src\Font.zig` — `glyphAdvance` (TextField hit-test の素材)
- `C:\Users\dansaka\Work\Repository\nimbus\awt\src\root.zig` — `waitEventsTimeout` 追加
- `C:\Users\dansaka\Work\Repository\nimbus\framework\src\Component.zig` — focusable / requestFocus 追加
- `C:\Users\dansaka\Work\Repository\nimbus\framework\src\Window.zig` — focus_owner、char/key の routing 変更 (`dispatchInput` `:377-471`、`onKey` `:581`)
- `C:\Users\dansaka\Work\Repository\nimbus\framework\src\Application.zig` — タイマー基盤、`run` ループ、textField factory
- `C:\Users\dansaka\Work\Repository\nimbus\framework\src\Button.zig` — TextField の雛形として参照 (vtable + processEvent state machine + applyMetrics)
- `C:\Users\dansaka\Work\Repository\nimbus\doc\audit-2026-05-23.md` — 全体監査の元データ (本計画の根拠の一部)
