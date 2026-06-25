# テキスト編集コア共通設計（framework_backlog #31 汎用 UndoStack ＋ #5 編集コア）

テキストエディタ地ならしの 2 ピースを 1 本で設計する。

- framework_backlog [#31](framework_backlog.md)（汎用 Undo/Redo スタック・buffer 非依存プリミティブ）
- framework_backlog [#5](framework_backlog.md)（TextField / TextArea の編集コア共通化）

実装（.zig）は本ドキュメントでは行わない。ゴールは設計 1 本。

2 つを一緒に設計するのは、**UndoStack の API を編集コアの applyEdit / ReplaceRange の実需に紙上で
合わせて検証するため**である。汎用プリミティブ（#31）を真空で決めず、最初の consumer（#5 のテキスト編集）が
それをどう叩くかを並べて、Command の最小 API・push のセマンティクス・coalescing の継ぎ目が実際に成立するかを
確認する。

実装は 2 コミットに分けられる形で書く（pm が段ごとに観測する）。

- コミット 1: #31（`UndoStack` + `Command`）を単体テスト付きで先に固める。consumer なしで回る。
- コミット 2: #5（編集コア）を実装し、#31 を消費する。最初の consumer で undo/redo を実証する。

関連: [ime_util_design.md](ime_util_design.md)（text#13・完成済み `ImeSession`）と接続するが、IME util は #5 の
コアに従属しない leaf utility。本コアは util の `on_cleared` を受ける側（5.7）。
[grapheme_edit_design.md](grapheme_edit_design.md)（text#3・完了）で境界歩行は `awt/src/grapheme.zig` に共有済み。

---

## 1. 目的とスコープ

### #31 の目的
GUI 横断の汎用 Undo/Redo プリミティブを framework に置く（text 層でなく framework に置く理由 ＝ ドロー /
フォーム / テキストなど領域横断で使うため）。最初の consumer はテキストだが、buffer にも widget にも依存しない。

### #5 の目的
TextField / TextArea が各自に重複保持している編集操作層（caret 移動・選択・クリップボード・編集操作・undo/redo）を、
描画／イベント処理を含まない共有モジュールへ切り出す。片方で直したバグがもう片方に残る古典的リスク
（text#3 を 2 回マージした実績で現実化済み）を構造的に潰す。

### スコープ（plain テキスト前提・2026-06-24 作者決定の踏襲）
共有コアは plain テキスト前提。データ構造は plain buffer（Swing PlainDocument 相当）。styled / rich モデル
（StyledDocument 相当）は将来の TextPane の別項目とし、本ピースをブロックしない。

---

## 2. 現状（実測・2026-06-25）

### 2.1 TextField はフラット ArrayList、編集が点在
- バッファ: `text: std.ArrayList(u8)`、caret は `caret_byte` / `mark_byte`（byte offset）。
- 編集サイト（バッファを mutate する箇所）: `deleteSelection`（`text.replaceRange`）/
  `deleteBackwardGrapheme` / `deleteForwardGrapheme`（同）/ `handleChar`（`text.insertSlice`）/
  `pasteFromClipboard`（同）/ `setText`（`clearRetainingCapacity` + `appendSlice`）。
- 各サイトが個別に caret / mark を更新し、個別に `change_listeners.fire` を `afterEdit(changed)` 経由で呼ぶ。
- 選択 = `[min(caret,mark), max(caret,mark))`、`hasSelection` / `selectionStartByte` / `selectionEndByte`。

### 2.2 TextArea は GapBuffer、編集が約 8 箇所に散在
- バッファ: `text: GapBuffer`、caret は `caret` / `mark`（logical byte offset）。
- 編集サイト: `handleChar`（`text.insert`）/ backspace（`text.delete`）/ delete キー（同）/ enter
  （`text.insert("\n")`）/ `deleteSelection`（`text.delete`）/ `insertStripCR`（`text.insert`・paste と
  setText が使う）/ `setText`（`clear` + insertStripCR）/ cut（`deleteSelection` 経由）。
  これが #5 の言う「散在した insert / delete（8 箇所）」の実体。
- caret / mark の更新も各サイト直書き。改行正規化（CRLF / lone CR → LF）は `insertStripCR` が担う。
- 選択・boundary 歩行は TextField とほぼ同形（`hasSelection` / `selectionStart` / `selectionEnd` /
  `prevBoundary` / `nextBoundary`）。GapBuffer は contiguous でないため boundary 系は `rangeSlice` で
  連続コピーを取ってから `awt.grapheme` を呼ぶ点だけ TextField と違う。

### 2.3 既に共有済みの資産（重複していないもの）
- 境界歩行: `awt/src/grapheme.zig`（`prev/nextGraphemeBoundary`）を両 widget が共有（text#3 完了）。
- IME preedit plumbing: `framework/src/ImeSession.zig`（text#13 完成）。両 widget が `ime: ImeSession` を所有し、
  `on_cleared`（composition ended の通知・payload なし）の継ぎ目を持つ。
- typed_callbacks: `framework/src/listener.zig` の `ListenerList(E)`（`addTyped` / `removeTyped` / `fire`、
  キャストは thunk 1 箇所）。`ChangeEvent { source: *anyopaque }` / `ActionEvent`。

### 2.4 GapBuffer は framework に既存（awt ではない）= 案A の buffer はこれ
本ピースで「awt 側のテキストバッファ型」を探したが、GapBuffer は **`framework/src/GapBuffer.zig`** に在り、
root.zig から `pub const GapBuffer` で export 済み。awt 層にバッファ型は無い。よって新規に作る必要はなく、
案A（単一フラット GapBuffer ＋ バイトオフセット）の buffer はこの既存 GapBuffer を共有コアが所有する形になる。
GapBuffer の API（logical byte offset 契約）:

- `insert(pos, bytes) !void` / `delete(pos, count) void`（clamp 付き）/ `replace(start, count, bytes) !void`
- `byteAt(i) u8` / `copyRange(dst, start, end) void`（gap を跨いでも 2 memcpy）/ `len()` / `moveGap(pos)` / `clear()`

`replace` が 1 ステップで「旧 count を消して新 bytes を入れる」を提供するので、ReplaceRange command（5.4）と
1 対 1 で対応する。

### 2.5 undo/redo は両 widget とも未実装
現状どちらにも undo は無い。エディタのドッグフーディングで実需化した（#31 の昇格理由）。

---

## 3. 全体構成と依存方向

```
            framework#31                         framework#5
   ┌──────────────────────────┐      ┌────────────────────────────────┐
   │ Command (interface)      │◀─────│ EditCore                       │
   │ UndoStack                │push  │  ├ GapBuffer (text)            │
   │  ├ list + index          │      │  ├ caret / mark (byte offset)  │
   │  ├ canUndo/canRedo        │      │  ├ applyEdit chokepoint       │
   │  ├ 可否変更リスナー       │      │  │   └ pushes ReplaceRange ───┘
   │  └ bounded eviction      │      │  └ line-lookup seam            │
   └──────────────────────────┘      └────────────────────────────────┘
        buffer 非依存                  TextField / TextArea が所有・driver
        consumer 不要で回る            描画 / イベント / 行モデルは widget に残す
```

依存方向: #31 は #5 を知らない（buffer も widget も Component も import しない）。#5 が #31 を import して
Command を push する。両者とも `std` と framework の `listener.zig` には依存してよい。

---

## 4. framework#31 汎用 UndoStack

### 4.1 Command インターフェイス
Zig に interface は無いので、repo 慣習（`Component.VTable`・`ImeSession.ClearedHook` の vtable + ctx 形）に従い、
**vtable ポインタ + 不透明 ctx ポインタ**の fat pointer 1 個で表す。

```zig
pub const Command = struct {
    vtable: *const VTable,
    ctx: *anyopaque,

    pub const VTable = struct {
        /// Re-apply the edit. The stack calls this on redo (NOT on push;
        /// see 4.2: push records an edit the editor already performed).
        redo: *const fn (ctx: *anyopaque) anyerror!void,
        /// Reverse the edit.
        undo: *const fn (ctx: *anyopaque) anyerror!void,
        /// Release ctx-owned memory. The stack calls this exactly once when the
        /// command is dropped (redo-tail truncation, eviction, clear, or after a
        /// successful merge of `next`). Optional only if ctx owns nothing.
        deinit: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void,
        /// Optional coalescing seam: try to absorb `next` (a newer command) into
        /// self. Returns true if merged — the stack then drops `next` instead of
        /// pushing it. Policy lives here, not in the stack (see 4.5 / 5.9).
        tryMerge: ?*const fn (ctx: *anyopaque, next: Command) bool = null,
        /// Optional human-readable label for menu/tooltip ("Typing", "Paste").
        displayName: ?*const fn (ctx: *anyopaque) []const u8 = null,
    };
};
```

- `redo` / `undo` が `anyerror!void` なのは、テキストの逆操作が GapBuffer の `insert`（OOM し得る）を伴うため。
  失敗時の扱いは 4.2 で扱う。
- ctx は典型的にヒープ確保したペイロード（テキストなら ReplaceRange・5.4）。`deinit` がそれを解放する。
  所有権は push した時点で stack へ移る。

### 4.2 UndoStack
```zig
pub const UndoStack = struct {
    list: std.ArrayList(Command),
    /// Number of commands currently "done": [0, index) are undoable,
    /// [index, list.len) are redoable. Invariant: 0 <= index <= list.len.
    index: usize,
    /// Bounded: when list.len exceeds this after a push, evict from the front.
    limit: usize,
    allocator: std.mem.Allocator,
    change_listeners: ChangeListenerList, // 4.3
};
```

操作:

- **`push(cmd)`**: 編集は**呼び出し側が既に実行済み**で、push はそれを記録するだけ（Swing `addEdit` 流。
  push が redo を呼ぶ設計にしない ＝ applyEdit がバッファを mutate してから記録を積む・5.4）。
  1. redo tail を切り捨て: `[index, list.len)` の各 Command を `deinit` して remove。
  2. coalescing: `index > 0` かつ `list[index-1].tryMerge(cmd)` が true なら、`cmd` を `deinit` して**積まない**
     （直前 Command が吸収した）。
  3. それ以外は `list.append(cmd)`、`index += 1`。
  4. bounded eviction: `list.len > limit` の間、`list[0]` を `deinit` して front から remove（`index` も減らす）。
  5. 可否（canUndo / canRedo）が変化したらリスナー発火（4.3）。
- **`undo()`**: `!canUndo()` なら no-op。`index -= 1`; `list[index].undo()`。可否変化で発火。
- **`redo()`**: `!canRedo()` なら no-op。`list[index].redo()`; `index += 1`。可否変化で発火。
- **`canUndo() = index > 0`** / **`canRedo() = index < list.len`**。
- **`clear()`**: 全 Command を `deinit` して空に（`index = 0`）。setText / ファイル読み込みで使う候補（5.4・6）。
- **`deinit()`**: `clear()` 相当 + `list` / `change_listeners` 解放。

undo / redo の失敗（`anyerror`）の扱いは 6 の決めること。素朴には「OOM は呼び出し側へ伝播、index は操作前に
戻す」だが、undo 中の OOM は稀でリカバリも難しいため初版は伝播のみ（policy は決めること）。

### 4.3 可否変更リスナー（listener.zig へ乗せる）
ボタン / メニューの活性更新に使う「canUndo / canRedo が変わったら発火」を、既存の `ListenerList` に寄せる
（新しいリスナー機構を作らない）。`ChangeListenerList`（`ChangeEvent { source }`）を再利用し、source は
UndoStack 自身。

```zig
pub fn addCanChangeListener(self: *UndoStack, comptime T, comptime f, user_data: *T) !void
pub fn removeCanChangeListener(self: *UndoStack, ...) void
```

発火条件は「(canUndo, canRedo) のタプルが push / undo / redo / clear の前後で変化したとき」のみ
（毎操作ではなく状態遷移時）。Swing の 2 リスナーのうち「可否が変わった通知」だけを採り、「edit が起きた通知
（Document → manager の配線）」は採らない（スコープ外・4.6）。

### 4.4 bounded eviction
上限は初版「件数」（`limit: usize`）。総バイト数キーは ReplaceRange のペイロードサイズを stack が知る必要があり
（command が不透明な以上、サイズ取得 API を VTable に足す＝表面積増）、テキスト以外の consumer では意味が
曖昧。よって件数を推奨し、総バイト案は決めること（6）に残す。古いものから捨てる（front eviction）。

### 4.5 merge / group の継ぎ目
- **tryMerge**: stack は push のステップ 2 で「直前 Command の `tryMerge(new)`」を 1 回だけ叩く。何を 1 単位と
  みなすか（policy）は Command 実装（テキストなら ReplaceRange・5.9）に住む。stack はタイミングだけ提供。
- **group（begin/end）**: 複合操作を 1 undo 単位にまとめる begin/endGroup は、初版では**入れない**。tryMerge で
  打鍵まとめは賄え、明示グループの実需（検索置換の一括など）はまだ無い。継ぎ目だけ将来に開けておき
  （CompoundEdit 再帰は採らない・4.6）、入れるかは決めること（6）。

### 4.6 スコープ外（Swing UndoManager 由来の過剰・採らない）
- Document から UndoableEditListener 経由で edit を集める間接層。nimbus はエディタが Command を直接 push する。
- `isSignificant`（些末な edit をスキップ）。
- UndoManager 自身が CompoundEdit でもあるという再帰構造。
- 「edit が起きた通知」リスナー（可否変更リスナーのみ採用・4.3）。

### 4.7 テスト方針（consumer 不要で回る・GPU 非依存）
テスト用の極小 Command（例: int カウンタを増減する `redo`/`undo`、`ctx` は `*i32`）を作れば stack 単体で
回せる。GapBuffer も Application も GPU も不要。

- push / undo / redo の順序（undo 後の redo が元に戻る）。
- redo tail 切り捨て（undo して別の push をすると redo できなくなる・捨てた Command の `deinit` が 1 回呼ばれる）。
- canUndo / canRedo の遷移（空 → push → undo → redo の各点）。
- 可否変更リスナーの発火（遷移時のみ・非遷移では鳴らない）。
- bounded eviction（limit 超過で最古が捨てられ `deinit` される・index が正しく減る）。
- tryMerge（true を返す Command 同士が 1 個に畳まれる・false なら 2 個）。

---

## 5. framework#5 編集コア（#31 を消費）

### 5.1 モジュールと所有
- 名前（推奨）: `EditCore`（`framework/src/EditCore.zig`、`const EditCore = @This();`）。別案
  `TextDocument` / `PlainDocument` / `text_edit`（backlog の例示名）。決めること（6）。
- 所有: TextField / TextArea が `core: EditCore` を 1 つ値で持ち、driver になる。コアは GapBuffer・caret・mark・
  UndoStack を所有し、描画・イベント・行モデル（VisualLine）は持たない。
- 依存方向: コアは `std` / `awt`（`grapheme`）/ #31 `UndoStack` に依存してよい。`Component` / `Window` /
  各 widget には依存しない（leaf。clipboard / IME / 描画の Window 接点は widget 側に残す・5.6 / 5.7）。

### 5.2 バッファ（案A 確定・GapBuffer 再利用）
コアは `text: GapBuffer` を所有（2.4 の既存型）。TextField は現在 `ArrayList(u8)` だが、コア採用で GapBuffer に
寄せる（フラット案A で両 widget 共通）。行は widget が派生する（コアは行構造を持たない）。改行正規化
（CRLF / CR → LF）は TextArea の `insertStripCR` 相当をコアの挿入経路に取り込むか widget 前処理に残すかを
決める（6・TextField は単一行なので無関係）。

### 5.3 caret / 選択モデル
コアが caret / mark（logical byte offset）を一元保持する。

```zig
caret: usize, // byte offset of the insertion point
mark: usize,  // selection anchor; caret == mark ⇒ no selection
```

- 選択 = `[min(caret, mark), max(caret, mark))`。`hasSelection` / `selectionStart` / `selectionEnd` /
  `selectionSlice`（GapBuffer から `copyRange` でコピーを返す）をコアが提供。
- caret 移動の grapheme 歩行（`prevBoundary` / `nextBoundary` / `snapToBoundary`）もコアへ集約。GapBuffer 上で
  `awt.grapheme` を叩くため `rangeSlice` 経由のコピーを取る形（TextArea の現実装と同じ）。TextField の
  ArrayList 直叩きはこの形に寄る。
- **行をまたぐ移動（上下・Home / End）はコアに置かない**: それは visual line（wrap 込み・描画依存）を要し、
  widget の `VisualLine` モデルに依存する。コアが提供するのは論理的な行ルックアップの継ぎ目だけ（5.8）。

### 5.4 applyEdit チョークポイント ＋ ReplaceRange command
**全 edit を 1 経路に通す**。TextArea の散在 insert / delete（2.2）と TextField の replaceRange（2.1）を、
この 1 経路へ畳む。

```zig
/// The single mutation entry point. Replaces logical bytes [pos, pos+del_len)
/// with `ins`, updates caret/mark, builds a ReplaceRange command capturing the
/// before/after state, and pushes it onto the undo stack. Every edit op (5.5),
/// clipboard paste/cut (5.6), and IME-committed char (5.7) funnels here.
pub fn applyEdit(self: *EditCore, pos: usize, del_len: usize, ins: []const u8) !void
```

applyEdit の手順:
1. before の caret / mark を控える。
2. 旧バイトを copy: `old = text.copyRange(pos, pos+del_len)`（undo 用・owned）。
3. `text.replace(pos, del_len, ins)`（GapBuffer・2.4）。
4. after の caret / mark を確定（典型: `caret = mark = pos + ins.len`）。
5. ReplaceRange command を構築し UndoStack へ push。
6. 「内容が変わった」通知（コアの change listener、または widget へのコールバック）。`afterEdit` 相当の
   repaint / reflow は widget が担う（コアは描画を知らない）。

ReplaceRange のペイロード（Command の ctx・コアが所有）:

```zig
const ReplaceRange = struct {
    pos: usize,
    old_bytes: []u8, // owned copy of the removed content (for undo)
    new_bytes: []u8, // owned copy of the inserted content (for redo)
    caret_before: usize, mark_before: usize,
    caret_after: usize,  mark_after: usize,
    buffer: *GapBuffer,  // the core's buffer (undo/redo mutate it)
    core: *EditCore,     // to restore caret/mark on undo/redo
};
```

- undo: `buffer.replace(pos, new_bytes.len, old_bytes)`; `caret/mark = before`。
- redo: `buffer.replace(pos, old_bytes.len, new_bytes)`; `caret/mark = after`。
- deinit: `old_bytes` / `new_bytes` / ReplaceRange 自身を解放。

caret / 選択の before-after をペイロードに持つことで、undo 後にカーソルが編集前の位置へ正しく戻る
（純粋なバッファ復元だけだと caret が編集後位置に残る）。

### 5.5 編集操作（applyEdit の上に薄く）
すべて applyEdit へ落ちる:

- 挿入（文字入力・IME 確定）: 選択があれば `applyEdit(selStart, selLen, ins)`、無ければ
  `applyEdit(caret, 0, ins)`。
- 後方削除（Backspace）: 選択ありは選択削除、無ければ `prev = prevBoundary(caret)`; `applyEdit(prev, caret-prev, "")`。
- 前方削除（Delete）: 選択ありは選択削除、無ければ `next = nextBoundary(caret)`; `applyEdit(caret, next-caret, "")`。
- 選択置換 / 選択削除: `applyEdit(selStart, selLen, replacement)`（削除は replacement = ""）。

空編集（del_len == 0 かつ ins.len == 0、例: 末尾で Backspace）は applyEdit に入る前に弾く（command を積まない）。
現状 widget が返す `changed: bool` 相当はコアが「実際に mutate したか」で表現する。

### 5.6 clipboard の継ぎ目
クリップボードは Window（`parentWindow` walk → `awt_window.setClipboardString` / `getClipboardString`）に縛られ、
コアは Window を知らない（leaf 原則）。よって役割を分ける:

- copy: 読み取りのみ。widget が `core.selectionSlice()` を取り、Window へ set。コアは関与しない。
- cut: widget が `core.selectionSlice()` を Window へ set してから `core.deleteSelection()`（= applyEdit）。
- paste: widget が Window から文字列を取り、`core.replaceSelection(text)`（= applyEdit）。CRLF 正規化の所在は
  5.2 の決めことに従う。

つまり cut / paste の**バッファ変更は applyEdit 経由**（undo に乗る）で、OS クリップボード I/O だけ widget に残る。

### 5.7 IME 確定（CharEvent → applyEdit）と on_cleared の接点
- 確定文字列は composition チャネルを通らず `CharEvent` 経由で届く（ime_util_design 2.3 の確定事実）。よって
  widget の `handleChar` は `core.insertChar(cp)`（= applyEdit）を呼ぶだけになり、IME 確定挿入も undo に乗る。
- `ImeSession.on_cleared`（composition ended・payload なし）の使い道はコア側では**coalescing の境界**:
  composition が終わった時点を undo group の区切りにできる（変換 1 回ぶんの確定文字をまとめて／個別に undo する
  かは coalescing policy・5.9）。継ぎ目は「on_cleared でコアの coalescing をフラッシュ（次の打鍵と merge させない）」
  という 1 フック。具体ポリシーは決めること（6）。
- preedit のインライン描画と caret 矩形算出は widget に残る（ime_util_design 5 章の境界線どおり）。コアは
  preedit を知らない（未確定文字はバッファに入らない）。

### 5.8 行ルックアップの継ぎ目
コアは論理行（'\n' 区切り）のルックアップを**差し替え可能な内部継ぎ目**として持つ:

```zig
fn lineStartAtByte(self: *EditCore, byte: usize) usize // 行頭の byte offset
fn byteAtLine(self: *EditCore, line: usize) usize       // n 行目の先頭 byte
```

- 初版は走査（`findNewline` 相当の O(n) スキャン）。後で行頭索引（line-start index）に差し替えても呼び出し側
  （コア API）は不変。
- TextArea の **visual** line（wrap 込みの `VisualLine`）は描画依存なので widget に残る（コアの論理行とは別物）。
  visual reflow が論理行ルックアップを使うかは移行時に決める（現状は widget が自前スキャン）。TextField は単一行で
  この継ぎ目を使わない。

### 5.9 undo coalescing ポリシー（#31 の tryMerge に乗る）
継ぎ目は #31 の `Command.tryMerge`（4.5）。ReplaceRange.tryMerge が「直前の編集に次の編集を畳めるか」を判定する。
作者支持は**時間 / アイドルベース**。素描（具体値は決めること）:

- merge する: 連続した純挿入（両方 del_len == 0）で、隣接（`prev.pos + prev.new_bytes.len == next.pos`）、
  かつ前回編集から一定アイドル時間内、かつ改行を跨がない。
- 区切る（merge しない）: 改行挿入 / 貼り付け / caret ジャンプ（マウスクリックや不連続なカーソル移動）/
  アイドル時間超過 / IME 確定境界（on_cleared・5.7）。
- 時刻ソース: アイドル判定には「前回編集からの経過」が要る。Application はタイマを持つので、最終編集時刻を
  コアが保持し applyEdit で更新する形になる（時刻の取り方＝決めること）。

policy は #5 で決める UX 判断であり、#31 は tryMerge の継ぎ目だけ用意する（4.5）。

### 5.10 TextField / TextArea の消費（リファクタ素描）
両 widget で共通:

- フィールド `text` / `caret(_byte)` / `mark(_byte)` を `core: EditCore` に置換。`getText` はコアの buffer を返す。
- 編集ハンドラ（handleChar / backspace / delete / cut / paste / 選択置換）は `core.*`（= applyEdit）呼び出しに縮約。
  各サイトの caret 更新・`change` 発火は applyEdit に集約され、widget は `afterEdit` / `afterReflow`
  （repaint / reflow / scroll / IME caret push）だけ残す。
- undo / redo キー（Ctrl+Z / Ctrl+Y など）を handleKey に追加 → `core.undo()` / `core.redo()` → reflow + repaint。
- 選択 / boundary ヘルパ（`hasSelection` / `selectionStart` 等）は widget から消えコアへ。描画は `core` を読む。

widget 固有で残るもの:

- TextField: 単一行・`scroll_x`・`ensureCaretVisible`（水平）・hit-test（`glyphXAtByte` / `hitTestByteAt`）。
- TextArea: `VisualLine` モデル・wrap・`reflowAt`・上下移動・ScrollPane 連携・改行正規化。
- 両者: 描画（preedit 下線・選択ハイライト・caret）・IME caret 矩形算出・clipboard の Window 接点（5.6）。

移行を本ピースに含めるか別ピースに割るかは決めること（6）。#5 の完了条件は両 widget がコアを使うことなので、
最終的には含むが、コミット 2 をさらに「コア新設」と「widget 載せ替え」に割る選択肢がある。

### 5.11 テスト方針（純ロジック・Robot 駆動・Application / GPU 非依存）
GapBuffer / listener と同じく、コアは Application も GPU も無しで単体テストできる。

- caret / 選択: 移動（grapheme 境界・選択拡張）・選択範囲・選択スライス。
- 編集操作: 挿入 / 前後削除 / 選択置換が buffer と caret を正しく更新する。
- undo / redo: applyEdit → undo で buffer と caret が編集前へ・redo で編集後へ。複数編集の連続 undo。
- coalescing: 連続打鍵が 1 undo に畳まれ、改行 / 貼り付け / caret ジャンプで区切られる。
- clipboard / IME: cut / paste / IME 確定挿入が applyEdit 経由で undo に乗る（Window 接点はテストダブルか
  widget 層でゲート。コア単体は文字列引数で叩く）。

描画依存（preedit 下線・選択ハイライトの見た目）だけ GPU ゲート下のスナップショットに置く。既存 snapshot /
examples（widget_textfield / widget_textarea）の挙動は不変であること（#5 完了条件）。

---

## 6. 決めること（作者判断）

### #31
- Command の最小 API: `redo` / `undo` / `deinit` / 任意 `tryMerge` / 任意 `displayName` のシグネチャ（4.1）で
  確定してよいか。undo / redo の失敗（`anyerror`）の扱い（伝播のみ / 握り潰し / index ロールバック）。
- 可否変更リスナーを `ChangeListenerList` 再利用（source = stack・4.3）で固定するか、専用 event 型にするか。
- bounded のキー: 件数（推奨・4.4）か総バイトか。既定 limit 値。
- group（begin/endGroup）を初版に入れるか、tryMerge だけにして group は将来に開けるだけにするか（4.5）。

### #5
- モジュール名 / 配置: `EditCore`（`framework/src/EditCore.zig`）か、`TextDocument` / `PlainDocument` /
  `text_edit` か（5.1）。
- undo coalescing の具体ポリシー: アイドル時間の閾値、区切りに含める操作、時刻の取り方（5.9）。
- 行ルックアップの初版: 走査でよいか・行頭索引をいつ入れるか（5.8）。
- TextField / TextArea 移行を本ピース（コミット 2）に含めるか、コア新設と widget 載せ替えで別ピースに割るか（5.10）。
- clipboard の扱い: cut / paste のバッファ変更を applyEdit 経由（undo 有り）にする方針（5.6）で確定か。copy が
  read-only でコア非関与なのは確定でよいか。
- setText の扱い: applyEdit 経由で undo に乗せるか、buffer リセット + UndoStack `clear()`（プログラム的読み込みは
  undo 境界をリセット）にするか。
- CRLF 正規化の所在: コアの挿入経路に取り込むか、widget 前処理（TextArea の現 `insertStripCR`）に残すか（5.2）。
- TextField の `ArrayList(u8)` → GapBuffer 移行（案A 共通化）を本ピースで行うことの確認（5.2）。

---

## 7. 完了条件

### #31（コミット 1）
`Command` + `UndoStack` が framework から export され、bounded eviction と可否変更リスナーが動く。consumer
不要の単体テスト（4.7）が緑。`doc` は本設計（必要なら spec を別途）。

### #5（コミット 2）
caret・選択・クリップボード・編集操作・undo/redo のロジックが単一モジュール（`EditCore` 等）に存在し、
TextField / TextArea 双方がそれを使う。全 edit が applyEdit チョークポイントを通り ReplaceRange を #31 の
UndoStack へ積む。編集系の単体テストが共有コアに対して書かれ（5.11）、既存 snapshot テスト・examples
（widget_textfield / widget_textarea）の挙動が変わらない。
