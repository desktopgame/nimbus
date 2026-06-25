# IME 共通機能 util 切り出し 設計（text_backlog #13）

TextField / TextArea が各自で持っている IME preedit（変換中表示）の plumbing を、
バッファ非依存の単体モジュールへ切り出すための設計。実装（.zig）は本ドキュメントでは行わない。
対応バックログは [text_backlog.md](text_backlog.md) #13（および表裏の #1 inline 表示）。

関連: framework_backlog #5（編集コア共通化・applyEdit チョークポイント）と接続するが、
本 util は #5 の編集コアに**従属しない**（作者方針「コアにくっつけず単体で切り出す」）。

---

## 1. 目的とスコープ

preedit plumbing を `ImeSession`（仮称）という standalone モジュールへ集約し、
TextField / TextArea の双方をそこへ載せ替える。バッファ非依存の標準 plumbing として完結させ、
片方だけ直すずれ（重複バグ）を構造的に防ぐ。

スコープに入る = preedit 状態保持・awt-c 連携の接点・caret 矩形 push・composition ライフサイクルの通知。
スコープに入らない = 確定文字列のバッファ挿入（編集コア）と preedit のインライン描画（widget）。
詳細は「5. 境界線」。

---

## 2. 現状（実測）

起票時バックログの記述と実装にずれがあったため、本節は 2026-06-25 の実測に基づいて現状を訂正する。

### 2.1 TextField / TextArea はどちらも preedit を実装済み

backlog #13 / #1 は「TextField は実装済み・TextArea 未対応」「util を TextArea へ展開」と記すが、
**TextArea も既に完全な preedit を持つ**（`ec78383 Add: TextArea を実装` 以来）。
両者は次の同形コードを各自に重複保持している。

- 状態フィールド: `preedit_text: std.ArrayList(u8)` / `preedit_target_start: usize` / `preedit_target_end: usize`
  （TextField.zig:68-70、TextArea.zig:76-78）。
- `.composition` ハンドラ: borrow された UTF-8 を copy on receipt し、target 範囲を保存、repaint
  （TextField.zig:406-414、TextArea.zig:630-636）。ほぼ逐語的に同一。
- インライン描画: preedit 全体に細い下線＋変換対象 clause に太い下線、合成中は caret 非表示
  （TextField.zig:347-387、TextArea.zig:585-612）。色は theme の `ime_preedit_underline` / `ime_preedit_target`。
- caret 矩形 push: `pushCaretToIme` が widget 幾何から window-local 座標を作り
  `awt.Window.setCompositionCursorPos` を呼ぶ（TextField.zig:581-593、TextArea.zig:852-861）。
- push の発火タイミング（共通）: focus gain・mouse press・編集後（afterEdit / 各 edit 末尾）。

したがって #13 の本質は「未対応 widget への展開」ではなく**既存重複の de-dup**。
#1 (b)「TextArea へ inline 表示を展開」は実態としては既に満たされており、残るのは共通化のみ。
（このずれは backlog 側へ反映する。本ドキュメントの追加に合わせて #13/#1 の文面を訂正する。）

### 2.2 awt-c ブリッジ（変更しない既存契約）

OS から framework までの経路は確立済みで、本 util はこの上に乗るだけで**契約は変えない**。

- awt-c 内部ヘルパ: `nm_ime_attach` / `nm_ime_set_cursor_pos`
  （Windows 実装 = win32_ime.c、非 Windows = ime_stub.c の no-op）。glfw_shim.c から無条件で呼ばれる。
- 公開 API（internal.h）: `nmCompositionEvent { text, text_len, target_start, target_end }`、
  `nmCompositionCallback`、`nmSetCompositionCallback`、`nmSetCompositionCursorPos`。
  preedit 状態は `nmWindow` 内（window_internal.h の `composition_*` フィールド）に住む。
- awt 層: `awt.Window.setCompositionCallback` / `setCompositionCursorPos`（Window.zig:205/212）が薄く wrap。
- framework 層: `framework.Window.onComposition`（Window.zig:1372）が `focus_owner` へ**同期**で
  `processEvent(.composition)` を投げる。同期なのは borrow された UTF-8 が callback の間しか有効でないため
  （キュー経由にすると borrow 窓を越える）。

### 2.3 確定文字列は composition チャネルを通らない

重要。win32_ime.c:307-320 のとおり、確定結果（`GCS_RESULTSTR`）は composition callback で運ばれない。
確定文字は WM_CHAR → `glfwSetCharCallback` → `CharEvent` 経由で届く（コメント「we do not duplicate the commit
path here」）。WM_IME_ENDCOMPOSITION は**空の** composition イベント（text_len == 0 = "cleared"）を出すだけ。

帰結: composition チャネルが運ぶのは preedit と "cleared" シグナルのみ。**確定文字列は util から見えない**
（既存の `handleChar` 経路を素通りして widget / 編集コアへ入る）。
これは backlog #13「onCommit が確定文字列を渡す」/ #5「util の onCommit を受けて applyEdit」の想定と
現行トランスポートが食い違う点であり、後述「4.4」「9. 決めること」で扱う。

### 2.4 デッドコードと Robot の no-op（テスト前提に影響）

- `framework.Window.dispatchInput` の `.composition` branch（Window.zig:910-914）は
  「not yet routed to focus_owner」とコメントしつつ silently drop する**stale なデッドコード**。
  実際の routing は 2.2 の `onComposition`（同期）が担っており、本物の composition はキューを通らない。
- `Robot.composition()`（Robot.zig:112）は `postInput` → イベントキュー → `dispatchInput` 経由で投げるため、
  上記デッドブランチに当たり**現状ドロップされる（no-op）**。IME のテストは 1 本も存在しない（実測 0 件）。
- これは「8. テスト方針」の前提に直結する。Robot から preedit を駆動するには、この branch を
  `onComposition` と同じく `focus_owner.processEvent` へ繋ぐ必要がある（小修正）。

---

## 3. モジュール提案（名前・配置・依存方向）

### 名前
`ImeSession`。「1 つの widget の進行中 composition セッション（preedit 状態 ＋ caret push ＋ ライフサイクル）」
を表す。`ImeManager` 案より、widget ごとに 1 インスタンス持つ性質（focus 単位の session）に素直。

### 配置
`framework/src/ImeSession.zig`。ファイル = 型の repo 慣習（`const ImeSession = @This();`）に従う。
standalone モジュールの先例 `framework/src/OverlayManager.zig` と同じ並びに置く。

### 依存方向（core への従属を作らない）
- 依存してよい: `std`、`awt`（`awt.Event.CompositionEvent`、`awt.Window`）。
- 依存しない: framework の `Component` / `Window`、編集コア（framework_backlog #5）、各 widget。
  → leaf utility。widget が `ImeSession` を field として所有し、driver になる（逆向き依存は作らない）。
- awt-c コールバック登録（`setCompositionCallback`）は util に**入れない**。registration は引き続き
  `framework.Window.onComposition`（focus_owner への単一ブリッジ）が持つ。util は dispatch 済みの
  `CompositionEvent` を consume する側。

---

## 4. API 表面（設計・シグネチャ）

以下は設計上のシグネチャ素描であり、実装ではない。最終的な細部は実装時に詰める。

### 4.1 保持する状態

```zig
const ImeSession = @This();

allocator: std.mem.Allocator,
/// Owned UTF-8 copy of the latest preedit (the C-side pointer is valid only
/// during the callback, so we copy on receipt). Empty when not composing.
preedit: std.ArrayList(u8),
/// Byte offsets into `preedit` marking the clause under active conversion.
/// Collapse to the preedit caret position when no clause is targeted.
target_start: usize,
target_end: usize,
/// Composition-cleared hook (see 4.4). Optional.
on_cleared: ?Hook,
```

### 4.2 ライフサイクル

| 局面 | API | 意味 |
| --- | --- | --- |
| 生成 | `init(allocator) ImeSession` | 空状態。widget の create で 1 つ持つ。 |
| 更新 | `update(self, ev: awt.Event.CompositionEvent) !void` | preedit を copy on receipt し target を保存。`ev.text.len == 0` なら下記 clear と同義。 |
| 確定 / キャンセル | （明示 API 不要・`update` の空イベントで表現） | OS は確定もキャンセルも空 composition で通知する（2.3）。clear に集約。 |
| クリア | `clear(self) void` | preedit を空に戻す（`on_cleared` を発火）。 |
| 破棄 | `deinit(self) void` | `preedit` の解放。widget の destroy で呼ぶ。 |
| 問い合わせ | `isComposing(self) bool` / `preeditSlice(self) []const u8` / `targetRange(self) struct{start,end}` | widget の描画・caret 非表示判定が読む。 |

`update` / `clear` は `awt.Event.CompositionEvent` のセマンティクス（空 text = cleared）をそのまま踏襲する。
widget の `processEvent(.composition)` は `self.ime.update(comp)` を呼んで repaint するだけになる。

### 4.3 caret 矩形 push（util に入る forwarding）

caret 矩形の**算出**は widget 幾何依存なので widget に残す（境界線参照）。
util は算出済みの矩形を OS へ流す forwarding glue を 1 箇所に集約する。

```zig
pub const CaretRect = struct { x: f32, y: f32, height: f32 }; // window-local

/// Forward the caret rect to the OS IME so it anchors its candidate window.
/// No-op if `window` is headless (awt_window == null). Centralizes the
/// awt_window null-check + float→int cast that both widgets duplicate today.
pub fn pushCaret(self: *ImeSession, window: *awt.Window, rect: CaretRect) void;
```

push を呼ぶ**タイミング**（focus gain / press / 編集後）は widget が引き続き決める（geometry を持つのは widget）。
util が集約するのは「awt_window を取り出して `setCompositionCursorPos(@intFromFloat(...))` する」定型のみ。
（現状の dedup は控えめだが、null チェック・キャスト・座標契約を 1 点に閉じる意味がある。）

### 4.4 onCommit / on_cleared（現行トランスポートに合わせた設計）

2.3 のとおり、確定文字列は composition チャネルを**通らない**（CharEvent 経由で widget / 編集コアに入る）。
よって util が「確定文字列を運ぶ onCommit」を持つことは、現行 awt-c 契約のままでは**実現できない**。

本設計は次の 2 案を提示し、案 A を推奨する。

- **案 A（推奨・トランスポート不変）**: util は確定文字列を運ばない。composition が空になった瞬間に
  `on_cleared`（composition ended の通知のみ。payload なし）を発火する。確定文字の挿入は従来どおり
  `handleChar` → （将来）編集コアの `applyEdit` が担う。util はバッファ非依存・awt-c 不変を保てる。
  backlog #13 の「onCommit（確定文字列を渡す）」は、この `on_cleared`（文字列を持たない composition-ended
  フック）へ reframe する。
- **案 B（将来・トランスポート変更を要する）**: `GCS_RESULTSTR` を composition チャネル経由で
  「commit イベント」として別途配送し、util が `onCommit(text)` → 編集コア `applyEdit(text)` を駆動する。
  これは awt-c（win32_ime.c / cocoa_ime.m）と `awt.Event` の変更を伴う別スコープ。確定挿入を CharEvent から
  composition へ移す利点（IME 由来の挿入を 1 経路に集約し undo の境界を IME 単位で切れる等）が felt need に
  なった時に検討する。本 util 切り出しでは採らない。

`Hook` の形は repo の typed_callbacks 規約（[[project-event-listener-redesign]]）に合わせる
（`addTyped` 系で `*T` ユーザーデータ ＋ キャスト 1 箇所）。詳細は実装時に決める。

---

## 5. 境界線（util に入る / 入らない）

backlog #13 の線引きを実態に合わせて確定する。

### util に入る（バッファ非依存の plumbing）
- preedit 状態の保持（未確定文字列の owned copy・target 範囲）。
- awt-c 連携の接点（dispatch 済み `CompositionEvent` の consume と "cleared" 検出）。
  ※コールバック登録自体は `framework.Window` 側に残す（3 章）。
- caret 矩形の OS への push（forwarding glue。矩形の算出は除く）。
- composition ライフサイクル通知（`on_cleared`。案 A）。

### util に入らない
- (1) 確定 → キャレット位置へのバッファ挿入。編集状態に触るので編集層
  （framework_backlog #5 の `applyEdit`）に残す。現行では `handleChar` がこの役割。
- (2) preedit のインライン描画（下線・変換対象強調）。widget の caret x / measure（`glyphXAtByte` /
  `caretGeom` / `measureUtf8` / `measureSlice`）に依存するので widget 側に残す。util は描画フックを持たない
  （widget が `isComposing` / `preeditSlice` / `targetRange` を読んで自前で描く）。
- (3) caret 矩形の**算出**。widget 幾何依存。util へは算出結果（`CaretRect`）だけ渡す。

---

## 6. TextField の消費（リファクタ素描）

- フィールド `preedit_text` / `preedit_target_start` / `preedit_target_end` を 1 つの `ime: ImeSession` に置換。
- `create`: `.ime = ImeSession.init(allocator)`。`destroy`: `tf.ime.deinit()`。
- `processEvent(.composition)`: `tf.ime.update(comp) catch {}; tf.component.repaint();` に縮約。
- 描画（lookPaint 内 preedit ブロック）: `tf.ime.isComposing()` / `tf.ime.preeditSlice()` /
  `tf.ime.targetRange()` を読む形へ。下線・強調・色（theme）はそのまま widget に残す。
- caret 非表示判定: `tf.preedit_text.items.len == 0` → `!tf.ime.isComposing()`。
- `pushCaretToIme`: 矩形算出は残し、forwarding を `tf.ime.pushCaret(window, rect)` へ委譲。
- `handleKey` の「合成中は OS IME がキーを持つので bail」（preedit 非空判定）も `tf.ime.isComposing()` へ。

確定挿入（handleChar）は不変。util に移さない（5 章 (1)）。

## 7. TextArea の採用

TextArea は既に同形の preedit を持つ（2.1）。よって採用は新規対応ではなく **TextField と同じ置換を
逐語的に適用する** だけ。両 widget が同一 `ImeSession` を共有することで、#13 の完了条件
（同一 util で変換中表示・確定・候補ウィンドウ追従を行う）を満たす。

- TextArea 固有差分は caret 算出のみ（`caretGeom` が複数行 → `CaretRect` を返す）。util 側は不変。
- これにより backlog #1 (b)「TextArea へ展開」は「TextArea も同じ util に載せ替え」へ意味が変わる
  （inline 表示自体は既存）。

---

## 8. テスト方針

nimbus のテスト規律（Application / GPU 非依存の純ロジックは Robot 駆動、デバイス依存のみ GPU ゲート）に従う。

### 8.1 純ロジック（GPU 非依存・Robot 駆動）
- `ImeSession` 単体テスト: `update` の copy on receipt（borrow 後に元バッファを壊しても保持が無事）、
  空イベントでの clear と `on_cleared` 発火、target 範囲の保存、`isComposing` の遷移。Application 不要。
- widget 経由の状態遷移: Robot で focus → `composition(text, ts, te)` → 確定（空 composition）→ `typeText`
  で確定文字が入る、というシナリオを GPU 無しで検証。preedit 中は caret 非表示・編集キー無視（handleKey の
  bail）といった状態を、描画ではなく状態フラグで観測する。

### 8.2 前提となる小修正（テストを成立させるために必要）
2.4 のとおり `Robot.composition()` は現状デッドブランチでドロップされ no-op。Robot から preedit を駆動するには
`framework.Window.dispatchInput` の `.composition` branch を `onComposition` と同じく `focus_owner.processEvent`
へ繋ぐ（または同等の経路で focus_owner へ届ける）必要がある。これは util 切り出しと同じ PR で行うのが自然
（テストが書けるようになって初めて純ロジックの回帰ガードが置ける）。本物の OS composition は引き続き
`onComposition` 同期経路を通るので、この修正は Robot/合成イベント経路だけを生かす。

### 8.3 GPU ゲート（デバイス依存のみ）
- 下線・変換対象強調の描画結果。スナップショット系が必要なら GPU ゲート下に置く。util の純ロジックとは分離する。

---

## 9. 決めること（作者判断）

- モジュール名 `ImeSession` と配置 `framework/src/ImeSession.zig` を採るか。
- onCommit の扱い: 案 A（`on_cleared` のみ・確定文字列は CharEvent 経路のまま・トランスポート不変）を採るか、
  案 B（確定文字列を composition 経由に移す・awt-c 変更を伴う）を将来項目に回すか。**推奨は A**。
- caret push の forwarding を util に寄せる範囲（`pushCaret(window, rect)` の粒度）。
- 8.2 の `dispatchInput` `.composition` branch 修正を本 PR スコープに含めるか（テスト前提として推奨）。
- backlog #13 / #1 の文面訂正（TextArea は実装済み＝de-dup である旨）を本 PR で行うか。

## 10. 完了条件

- TextField / TextArea が同一の `ImeSession` を使い、変換中表示・確定・候補ウィンドウ追従を行う。
- preedit 状態保持と awt-c 連携の接点・caret push forwarding が util に集約され、確定挿入は編集層
  （CharEvent / #5）・インライン描画と caret 矩形算出は widget に分離している。
- preedit の状態遷移（更新・clear・isComposing）が Application / GPU 非依存で Robot 駆動テストできる。
