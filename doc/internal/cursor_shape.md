# カーソル形状の機構 設計 spec

マウス位置に応じてウィンドウのカーソル形状（I-beam / リサイズ）を切り替える機構の設計 spec。
`framework_backlog.md` の #32（`{REPO_ROOT}/doc/internal/framework_backlog.md:1187`）の起票を受けたもの。
テキストエディタ v1 の実機確認で表面化した既存ギャップで、現状 framework にカーソル形状機構そのものが無い
（`glfwSetCursor` 系が awt / awt-c に出ていない）。実需は TextArea / TextField 上の I-beam と
SplitPane 分割線上のリサイズカーソル。

実装はしない（コードは書かない＝Codex 担当）。`border_model.md` / `laf_metal_text.md` の流儀に倣い
**「確定」と「未決」を分ける**。load-bearing な主張には実ファイルの行番号を引用する。

関連:
[capability_structs.md](capability_structs.md)（`?T` 能力構造体パターン。Provider サブパターン §1）、
[framework_backlog.md](framework_backlog.md)（#32 起票・決めること）、
`{REPO_ROOT}/framework/src/Component.zig`（能力構造体フィールド群・`absoluteOriginInWindow`）、
`{REPO_ROOT}/framework/src/Container.zig`（hover 追跡 `last_hovered`・child 走査）、
`{REPO_ROOT}/framework/src/SplitPane.zig`（`overDivider` / 分割線描画）、
`{REPO_ROOT}/framework/src/Window.zig`（`dispatchInput` / `onCursorPos`）、
`{REPO_ROOT}/awt/src/Window.zig`（薄ラッパ群）、
`{REPO_ROOT}/awt-c/src/internal.h`・`glfw_shim.c`・`window_internal.h`（glfw 境界）。

---

## 0. 背景・確定方針（pm ＋ 作者で合意済み・再議論しない）

以下4点は決定済み。本 spec はこれに沿って縦の配線を具体化するだけで、選択肢の再検討はしない。

1. **カーソルの持ち方＝位置依存 capability 1本**。Component に optional の能力構造体を1つ足す
   （既存 `FocusQuery` / `SizeQuery` / `A11y` と同じ `?Capability` パターン・VTable は太らせない）。
   全面一律のウィジェット（TextArea / TextField）は座標を無視して `.ibeam` を返す自明な関数、
   SplitPane は `overDivider` で `.hresize` / `.vresize` を返し分割線外では `null`。
   plain field 案・field+capability 併用案は**却下済み**（単一機構で位置依存も表現する）。
2. **カーソル種別 enum は最小4種**: `arrow` / `ibeam` / `hresize` / `vresize`
   （`arrow` は「指定なし＝null」を既定 arrow に落とす形でも良い）。
   hand / crosshair / カスタムビットマップは初版スコープ外（実需が出たら別項目）。
3. **標準カーソルオブジェクトの寿命＝window 単位でキャッシュ**。awt-c の C 層
   （`glfw_shim.c` の per-window 状態 `nmWindowCallbacks`）に `GLFWcursor*` を遅延生成してキャッシュし、
   `nmDestroyWindow` で `glfwDestroyCursor`。グローバル／シングルトンの cursor レジストリは
   CLAUDE.md「グローバルを選ばない」方針違反なので採らない。
4. **hit-test は既存の mouse-move 配送に相乗り**。専用 walk は作らない。move のたびにポインタ下の
   最深コンポーネントから `cursor_query` を解決し、最終形状が前回と変わった時だけ awt の `setCursor` を呼ぶ
   （毎 move の glfw 呼び出しは避ける＝Window が `current_cursor` を持って dedup）。

---

## 1. 確定: API 形

### 1.1 framework — `Component.cursor_query`（Provider 能力構造体）

`SizeQuery` / `FocusQuery` / `A11y` と同じ並びに optional フィールドを足す
（`Component.zig:220` `size_query`、`:226` `a11y`、`:241` `focus_query` のすぐ隣）。

```zig
/// Opt-in position-dependent cursor shape (held as an optional field, mirroring
/// `FocusQuery` / `SizeQuery`). `at(self, x, y)` returns the cursor shape the
/// pointer should show at window-local point (x, y), or null = "no preference,
/// ask my ancestor" (ultimately falls back to `.arrow`). Coordinates are in
/// WINDOW space — the widget re-derives its own local origin via
/// `absoluteOriginInWindow`, the same idiom every widget's `processEvent` uses.
pub const CursorQuery = struct {
    at: *const fn (self: *const Component, x: f32, y: f32) ?CursorShape,
};

cursor_query: ?CursorQuery,   // init: null （`Component.init` の `.focus_query = null` 等の並び）
```

- `CursorShape` の実体は awt 側に1つだけ定義し（§1.3）、framework はそれを参照する
  （`A11y` が `Role` を field で持つのと同様、enum を二重定義しない）。
- `Component.init`（`Component.zig:258`）の初期化リストに `.cursor_query = null` を追加する
  （`.focus_query = null`（`:282`）の隣）。

**座標系の確定**: `at` が受け取る `(x, y)` は**ウィンドウ座標**（`onCursorPos` が
content scale で割った後の logical points・`Window.zig:1302` の `cursor_x` / `cursor_y` と同じ単位）。
各 widget は `self.absoluteOriginInWindow()`（`Component.zig:687`）で自分のローカルに変換してから判定する。
これは SplitPane の `processEvent` が `main = m.x - origin.x` を計算する既存の流儀
（`SplitPane.zig:287-291`）と一致する。コンポーネントローカルを渡す案は、walk-up（§3）で複数階層の
`at` を順に叩く際に各階層ぶんローカルを再計算する手間が増えるので採らない。

### 1.2 awt — `Window.setCursor`

`awt/src/Window.zig` に薄ラッパを1本足す（`setFloating`（`awt/src/Window.zig:124`）の隣）。

```zig
/// Standard cursor shapes nimbus can request. Mirrors the awt-c `nmCursorShape`
/// enum 1:1 (which mirrors GLFW_*_CURSOR). `.arrow` is the OS default.
pub const CursorShape = enum { arrow, ibeam, hresize, vresize };

/// Set the OS cursor shape for this window. Idempotent at the glfw layer is NOT
/// assumed — the caller (framework.Window) dedups and only calls on change.
pub fn setCursor(self: Window, shape: CursorShape) void {
    c.nmSetWindowCursor(self.handle, @intFromEnum(shape));   // or an explicit map
}
```

- **enum の置き場**: `awt/src/Window.zig` 内（カーソルは window 状態で、`setCursor` がそこに居るため）。
  代替として `awt/src/Event.zig`（入力系 enum 並び）も可だが、消費するのが `Window.setCursor` だけなので
  Window.zig を推す。framework の `CursorQuery.at` 戻り値はこの `awt.Window.CursorShape` を使う。
- glfw 型（`GLFWcursor*`）はここには一切露出しない（既存方針）。`@intFromEnum` で C の int enum へ渡すだけ。
  順序が `nmCursorShape` と一致していれば `@intFromEnum` で足りる。明示 `switch` マップにするかは実装裁量。

### 1.3 awt-c — `nmCursorShape` ＋ `nmSetWindowCursor`

`internal.h`（Zig 向け・translate-c に食わせるヘッダー）には不透明 enum と関数宣言だけ出す。
既存 `nmKeyCode = typedef int`（`internal.h:76`）や `map_mouse_button`（`glfw_shim.c:53`）の流儀に倣う。

```c
/* internal.h — Window セクション（nmKeyCode の近く）に追加 */

/* Standard cursor shapes. Values mirror GLFW_*_CURSOR; the GLFWcursor* objects
 * are created lazily and cached per window (see glfw_shim.c). */
typedef enum nmCursorShape {
    nmCursorShapeArrow,
    nmCursorShapeIBeam,
    nmCursorShapeHResize,
    nmCursorShapeVResize,
} nmCursorShape;

/* Set the window's cursor to a standard shape. The GLFWcursor* is created on
 * first use for this window and cached; cleared in nmDestroyWindow. */
void nmSetWindowCursor(nmWindow* self, nmCursorShape shape);
```

- `GLFWcursor*` 型は `glfw_shim.c` と `window_internal.h`（translate-c に食わせない `.h`）だけに留める。
  `internal.h` には不透明 enum と関数宣言しか出さない（glfw 型を Zig 層へ漏らさない既存設計）。
- **per-window キャッシュの置き場**: `nmWindowCallbacks`（`window_internal.h:20-50`）に
  `GLFWcursor*` の小さな配列を足す（4 形状ぶん・`NULL` 初期化）。`nmWindowCallbacks` は
  `nmCreateWindow` が `calloc` で確保し（`glfw_shim.c:164`）user pointer に格納するので、
  `calloc` の zero-fill でそのまま全 `NULL` 初期化済みになる。
  arrow は glfw の既定カーソル（`glfwSetCursor(gw, NULL)`）で良いのでキャッシュ対象外にしても良い。

```c
/* window_internal.h: nmWindowCallbacks の末尾に追加（GLFWcursor* は .c からのみ可視） */
GLFWcursor* cursors[4];   /* lazy GLFWcursor* per nmCursorShape; NULL = not yet created */
```

```c
/* glfw_shim.c: 新規実装。GLFW の標準カーソル ID へマップして遅延生成＋キャッシュ */
void nmSetWindowCursor(nmWindow* self, nmCursorShape shape) {
    GLFWwindow* gw = (GLFWwindow*)self;
    nmWindowCallbacks* cb = (nmWindowCallbacks*)glfwGetWindowUserPointer(gw);
    if (!cb) return;
    if (shape == nmCursorShapeArrow) { glfwSetCursor(gw, NULL); return; }
    if (!cb->cursors[shape]) {
        int glfw_id = /* ibeam→GLFW_IBEAM_CURSOR, hresize→GLFW_HRESIZE_CURSOR, ... */;
        cb->cursors[shape] = glfwCreateStandardCursor(glfw_id);
    }
    glfwSetCursor(gw, cb->cursors[shape]);   /* NULL なら glfw が既定に戻すので失敗時も安全 */
}
```

- **破棄**: `nmDestroyWindow`（`glfw_shim.c:182`）で `glfwDestroyWindow` の**前に**
  `cb->cursors[i]` を全て `glfwDestroyCursor`（非 `NULL` のみ）。`cb` の `free` はその後（既存の順序のまま）。

---

## 2. 確定: 縦の配線（framework.Window が解決して dedup）

### 2.1 解決トリガと dedup

`framework/src/Window.zig` に `current_cursor: awt.Window.CursorShape`（init `.arrow`）を持たせ、
move を処理し終えたあとに**1回だけ**カーソルを解決する。

- 配送は既存の `dispatchInput`（`Window.zig:669`）の `.mouse` → `.move` 経路にそのまま乗る。
  Container 側 `processEvent` の child 走査（`Container.zig:244-258`）が move のたびに
  `updateHover`（`Container.zig:212-219`）で各 Container の `last_hovered`（`Container.zig:30`）を更新するので、
  配送が終わった時点で「ポインタ下の最深コンポーネント」は `last_hovered` チェーンを root から辿れば分かる
  （**専用 walk を新設しない** ＝決定事項4）。
- 解決結果 `shape` が `current_cursor` と異なる時だけ `awt_window.setCursor(shape)` を呼び、`current_cursor` を更新する。
  毎 move では glfw を叩かない。

呼ぶ場所（推奨）: `dispatchInput` の `.mouse` ブランチ末尾、`m.action == .move` のときに
`self.updateCursorFromHover()` を1回呼ぶ。container 配送（`Window.zig:776`）・menu_bar の move 配送
（`Window.zig:759-762`）が済んで `last_hovered` が最新になった後である必要がある。

### 2.2 最深 hovered の特定と walk-up（§3 で詳述）

`updateCursorFromHover` の擬似コード:

```zig
// 1. last_hovered チェーンを root container から最深まで降りる。
var node: *Component = &self.container.component;
while (node.container) |c| {
    const next = c.last_hovered orelse break;   // last_hovered==null で停止（=この node が最深）
    node = next;
}
// 2. 最深から親方向へ登り、最初に非 null を返した cursor_query を採る。
var shape: awt.Window.CursorShape = .arrow;
var cur: ?*Component = node;
while (cur) |comp| : (cur = comp.parent) {
    if (comp.cursor_query) |q| {
        if (q.at(comp, x, y)) |s| { shape = s; break; }
    }
}
// 3. dedup。
if (shape != self.current_cursor) { self.awt_window.?.setCursor(shape); self.current_cursor = shape; }
```

`(x, y)` は `self.cursor_x` / `self.cursor_y`（`Window.zig:1302-1303` で更新済みの最新ウィンドウ座標）。

### 2.3 widget 側の配線

- **TextArea**: `create` 内（`TextArea.zig:135` で `ta.component.role = .text_area;` を置く箇所）に
  `ta.component.cursor_query = .{ .at = ibeamAlways };` を足す。`ibeamAlways` は座標を無視して `.ibeam` を返す自明関数。
- **TextField**: 同様に `create` 内（`TextField.zig:125` の `tf.component.role = .text_field;` の隣）に
  `tf.component.cursor_query = .{ .at = ibeamAlways };`。共通の `ibeamAlways` をどこに置くか（各 widget 内 / 共有 util）は実装裁量。
- **SplitPane**: `create` 内（`SplitPane.zig:106` で `sp.container.component.role = .split_pane;` を置く箇所）に
  `sp.container.component.cursor_query = .{ .at = dividerCursor };` を足す。`dividerCursor` は:

```zig
fn dividerCursor(self: *const Component, x: f32, y: f32) ?awt.Window.CursorShape {
    const sp = fromComponent(@constCast(self));   // const 経由の純 query（state は変えない）
    const origin = self.absoluteOriginInWindow();
    const main: f32 = switch (sp.orientation) {
        .horizontal => x - origin.x,
        .vertical => y - origin.y,
    };
    if (!sp.overDivider(main)) return null;        // 分割線外は祖先へ委譲
    return switch (sp.orientation) {
        .horizontal => .hresize,
        .vertical => .vresize,
    };
}
```

`overDivider`（`SplitPane.zig:181-184`）・`mainAxis`（`SplitPane.zig:163-168`）をそのまま使う。
これは pure query（state を変えない）でなければならない（`SizeQuery` の純 query 契約と同格・`Component.zig:56-60`）。

---

## 3. 確定: 分割線上ではどのコンポーネントが query に答えるか（実コードで確認した詰め）

#32 の「決めること」と本タスクで詰めるべき最重要点。**実コードを読んで確定した**。

**結論: 分割線上では SplitPane の container 自身が最深 hovered になり、SplitPane 自身の `cursor_query.at` が答える。
ancestor への walk-up は分割線ケースでは発生しない。**

根拠（SplitPane の分割線は子ではなく SplitPane 自身が描く帯）:
- レイアウト（`SplitPane.zig:197` 以降 `layoutDoLayout`）は `first` に `[0, dividerStart)`、
  `second` に分割線の先、その間の `divider_size` ぶんの帯は**どちらの子にも割り当てない**。
- 帯は SplitPane の `lookPaint`（`SplitPane.zig:255-274`）が `dividerStart()` から `divider_size` ぶん自分で塗る。
- したがって分割線上の点に対し、`first` / `second` の `containsWindowPoint`（`Component.zig:699`）は
  いずれも false。Container の child 走査（`Container.zig:250`）は hovered を見つけられず、
  `updateHover(null, ...)`（`Container.zig:258` → `:212`）で SplitPane の `last_hovered` が **null** になる。
- 結果、§2.2 の降下ループは SplitPane の container で `last_hovered == null` を見て停止し、
  最深 hovered ＝ SplitPane の container 自身になる。その `cursor_query.at`（`dividerCursor`）が `.hresize` /
  `.vresize` を返す。

**walk-up が一般には必要な理由**（分割線以外）: 最深 hovered が `cursor_query` を持たない場合
（例: 分割線外の `first` ペイン背景の Panel）に備え、最深から親方向へ登って最初の非 null を採る（§2.2 step 2）。
このとき `first` ペイン上では `dividerCursor` が `overDivider` false で `null` を返すので、さらに上の root まで登って
最終的に既定 `.arrow` に落ちる。TextArea 上では最深 hovered が TextArea（leaf・container 無し）で、
その `ibeamAlways` が `.ibeam` を返してそこで止まる。

→ 「最深 hovered が SplitPane container 自身になる」ケースで確定。祖先 walk-up は汎用の fallback として残すが、
分割線の解決はそれに依存しない。

---

## 4. テスト計画（framework 変更ゆえ必須）

hit-test → cursor 種別決定は **GPU 非依存の純ロジック**にする。手組みの `Component.init` /
`Container.create` で常時実行でき、ヘッドレスで検証できる形にする。実際のカーソル切替（glfw）は実機確認。

### 4.1 純ロジックとして検証する対象
- `CursorQuery.at` の解決（TextArea/TextField → `.ibeam`、SplitPane → 分割線上だけ `.hresize`/`.vresize`、外は null）。
- 最深 hovered の特定（`last_hovered` チェーン降下）と walk-up（非 null 祖先の採択・既定 arrow）。
- dedup（同一形状が続く間は `setCursor` を呼ばない／変わった時だけ呼ぶ）。

### 4.2 dedup と切替を観測可能にする
実 glfw を呼ばずに「`setCursor` が呼ばれたか・どの形状で」を観測したい。設計上の選択肢:
- `Window.current_cursor` を pub にし、`updateCursorFromHover` を直接叩いて `current_cursor` の遷移と
  「呼ばれた回数」をテストから観測する（`awt.Window.setCursor` を実際に呼ぶ前段の純ロジックだけを検証）。
- もしくは解決ロジックを `awt.Window` 非依存の純関数 `resolveCursor(root, x, y) CursorShape` に切り出し、
  それを単体テストする（dedup は呼び出し側 Window の責務として別途）。
- いずれにせよ「最深 hovered → 形状決定」は `awt.Window`/glfw を介さず到達できる形に保つ。

### 4.3 GPU ゲート下に純ロジックを置かない（教訓）
純ロジック（hit-test → 形状）を `initHeadless` で**実 DX12 デバイスを生成する形にしない**。
`focus_disabled` / `fc-swing` で「build 緑でも `--listen` 下で test.exe 非ゼロ終了」を踏んだ教訓
（純文字列・純幾何ロジックを GPU ゲート下に置かない）。手組み Component で完結させる。

### 4.4 真の回帰ガード
SplitPane の `overDivider` と TextArea の query が「修正前は別形状を返さない」ような回帰ガードにする。具体的には:
- 同じ Window レイアウト（SplitPane に TextArea を差した木）で、ポインタを「TextArea 内」「分割線上」「ペイン背景」に
  置いたときに `.ibeam` / `.hresize`(or `.vresize`) / `.arrow` がそれぞれ出ることを assert。
- 機構が無い／配線漏れの実装では3点とも `.arrow` に潰れるので、この3点 assert が配線の有無を弁別する。

---

## 5. 未決事項

- **ドラッグ中のカーソル維持**: SplitPane 分割線をドラッグ中、配送は mouse-capture 経路
  （`Window.zig:714-718`）で早期 return し、container 配送に届かないため `last_hovered` チェーンが更新されない。
  ドラッグ中もカーソルは `.hresize` のままであるべき。推奨: `self.mouse_capture` が非 null のときは
  capture 対象の `cursor_query.at(cap, x, y)` を直接引いて解決する（最深 hovered 経路をスキップ）。
  初版スコープに含めるか、ドラッグ中は前回形状を据え置く簡易版にするかは作者判断。
- **menu_bar / overlay 上のカーソル**: メニュー・ポップアップ上では現状 `.arrow` で十分（実需なし）。
  overlay 配送（`Window.zig:722-753`）は早期 return するので、その経路でも `current_cursor` を arrow に
  落とすか触らないかは要確認（初版は触らず arrow 据え置きで良さそう）。
- **List のセル**: List は可視セルを container 木の外に materialize する（`Window.zig:789-791` のコメント・
  List 自身の `last_hovered`・`List.zig:196`）。セル上の I-beam 需要が出たら、List の `cursor_query` か
  セル解決経路を別途設計する。初版スコープ外。
- **`@intFromEnum` 直結 vs 明示マップ**（§1.2 / §1.3）: enum 順序を `nmCursorShape` と一致させて
  `@intFromEnum` で渡すか、awt 側で明示 `switch` マップを書くか。順序契約を1か所に閉じる明示マップの方が安全だが、
  実装裁量に委ねる。

---

## 6. 実装の段割り提案

**薄い縦スライス1本**を推奨（framework → awt → awt-c を一気に通す）。理由: カーソルは末端の glfw 呼び出しまで
届いて初めて実機確認できる feature で、層ごとに分けても中間層単独では観測できない。最小スライスは:

1. awt-c: `internal.h` に `nmCursorShape` ＋ `nmSetWindowCursor` 宣言、`window_internal.h` の
   `nmWindowCallbacks` に `cursors[4]`、`glfw_shim.c` に実装（遅延生成＋キャッシュ）＋ `nmDestroyWindow` で破棄。
2. awt: `Window.zig` に `CursorShape` enum ＋ `setCursor` 薄ラッパ。
3. framework: `Component.cursor_query` 追加（init null）、`Window.updateCursorFromHover` ＋ `current_cursor`、
   `dispatchInput` の move 末尾で呼ぶ。
4. 配線: TextArea / TextField の `ibeamAlways`、SplitPane の `dividerCursor`。
5. テスト: §4 の純ロジック検証（手組み Component）＋3点回帰ガード。実機で I-beam / リサイズカーソルを目視確認。

この順なら各ステップは下から積み上がり、最後の実機確認まで通せる。テスト（5）は 3〜4 と同じスライスに含める
（framework 変更を緑のまま保つ）。
