# フォーカスリング残留 ＋ 無効アイコン減色 設計（ブランチ feat/focus-disabled）

テキストエディタ v1（`examples/app_texteditor`）の実機確認で出た framework 層の欠陥 2 件を直すための設計。

- ① フォーカスリングが旧 owner に残留する（フォーカス表示が 2 箇所に見える）
- ② 無効ボタンのアイコンが灰色化せず enabled と見分けがつかない（描画のみの不具合・機能は正しい）

実装（.zig）は本ドキュメントでは行わない。ゴールは設計 1 本で、実装は次段（Codex）がこのブランチ上で行う。
カーソル形状機構の欠落（③）は本ブランチでは着手せず、[framework_backlog.md #32](framework_backlog.md) に起票済み。

---

## 1. ① フォーカスリング残留

### 症状（作者報告）
ツールバーの Undo（flat アイコンボタン）をクリックしてフォーカスを得たあと、テキストエリアに caret を移して
フォーカスが移っても、Undo ボタンに focus ring が残り続ける（2 箇所が同時に focus 表示に見える）。

### 作者仮説と、実コード調査による訂正
作者仮説は「focus owner 切替時に旧 owner へ focus イベント（`.gained = false`）が配送されていないのでは」だった。
実コードを追った結果、**この仮説は誤り**であることが分かった。配送経路そのものは正しい:

- `Window.requestFocusFor`（`framework/src/Window.zig:495-509`）は、focus owner が変わるとき
  **旧 owner に `FocusEvent{ .gained = false }` を同期配送し、`repaint()` も呼んでいる**（:499-502）。
  続いて新 owner に `.gained = true` を配送する（:504-507）。
- `FocusEvent` は `gained: bool` のみ（`awt/src/Event.zig:191-193`）。
- 受け側 `Button.processEvent` の `.focus` アームは `button.focused = f.gained;`（`framework/src/Button.zig:399-401`）で、
  `.gained = false` さえ届けば `focused` は false に落ち、ring は消える。

つまり Window 側の配送は健全で、ここを直す必要はない。

### 真因
`Button.processEvent` の**先頭に置かれた無効ガードが、focus-lost イベントごと飲み込んでいる**。

```zig
fn processEvent(self: *Component, ev: *Component.Event) void {
    const button: *Button = @fieldParentPtr("component", self);
    if (!button.model.enabled) return;   // framework/src/Button.zig:353 ← ここ
    switch (ev.payload) {
        .mouse => |m| { ... },
        .key   => |k| { ... },
        .focus => |f| { button.focused = f.gained; },  // :399-401（disabled だと到達しない）
        .char, .composition => {},
    }
}
```

このガードは「無効なら入力を一切処理しない」意図だが、`.mouse` / `.key`（利用者操作）だけでなく
構造イベントである `.focus` まで止めてしまう。

### なぜ症状が出るのか（タイミング）
エディタの活性ロジックは正しく配線されている（example の `updateActionEnabled → canUndo → setEnabled`）。
Undo をクリックして 1 回 undo が走ると、これ以上 undo できなくなった瞬間に Undo ボタンが `setEnabled(false)` される。
その後にテキストエリアへフォーカスが移ると、`requestFocusFor` は旧 owner（＝**今や無効になった** Undo ボタン）へ
`.gained = false` を配送するが、`Button.processEvent:353` の無効ガードが早期 return するため `focused` は true のまま残る。
→ ring が残留する。「無効化された直後に focus を失う」という順序が成立する経路で再現する。

### 影響範囲（Button 固有ではない・共通欠陥）
「processEvent 先頭で無効ガード → switch 内で `.focus` を処理して focus フラグを更新」という同じ形が
複数ウィジェットにあり、すべて同じ欠陥を持つ。

| ウィジェット | 無効ガード | focus フラグ更新 | 欠陥 |
|---|---|---|---|
| Button | `Button.zig:353` | `:399-401`（`focused`） | あり |
| CheckBox | `CheckBox.zig:272` | `:316-317`（`focused`） | あり |
| RadioButton | `RadioButton.zig:242` | `:288-289`（`focused`） | あり |
| ComboBox | `ComboBox.zig:351` | `:410-411`（`has_focus`） | あり |

安全（修正不要）なもの:

- Slider（`Slider.zig:287-288` で `focused` を更新するが、processEvent 先頭に無効ガードが無い）。
- TextField / TextArea（`has_focus` を更新するが先頭ガードが無い）。

よって本修正は**全 focusable widget 共通の方針**として設計する。toolbar button を `focusable = false` にして
症状を隠す小手先は採らない（残留 ring の真因は配送ロジックではなく受け側ガードであり、focusable を切っても
他の無効化されうる focusable で同じ問題が出る）。

### 修正方針
無効ガードを **processEvent 先頭から `.mouse` / `.key` アームの内側へ移す**。`.focus`（および text 系では
`.char` / `.composition`）は無効状態でも常に処理させる。Button を例にすると:

```zig
switch (ev.payload) {
    .mouse => |m| { if (!button.model.enabled) return; ... },
    .key   => |k| { if (!button.model.enabled) return; ... },
    .focus => |f| { button.focused = f.gained; },   // 無条件
    .char, .composition => {},
}
```

同じ移動を Button / CheckBox / RadioButton / ComboBox に適用する。

設計上の判断:

- **focus は構造イベントであり、利用者操作ではない**。無効ウィジェットも「自分が今フォーカスを持っているか」の
  内部状態は正しく追従すべき（持っていないなら ring を描かない、が正）。`.gained = true` を無効ウィジェットが
  受け取るのは、本来 traversal が無効ウィジェットを飛ばす（別の不変条件）ので通常起きないが、仮に届いても
  害は無い（フラグが立つだけで、無効時に ring を描くかは paint 側の判断に委ねられる）。
- これは「無効でも focus 状態だけは追う」一点に閉じた最小修正で、無効ウィジェットがマウス / キー操作に反応しない
  という既存の正しい挙動は保たれる。

### テスト（GPU 非依存・純ロジック）
真因は `processEvent` 単体に閉じているため、Application / Window / GPU 不要で駆動できる:

1. ウィジェットを手組みで生成（`Button.create` 相当、allocator ＋ 既定 Theme `&Theme.default`、GPU 無し）。
2. 合成 focus イベントを `component.vtable.processEvent` に直接流す:
   - `FocusEvent{ .gained = true }` → `focused`（ComboBox は `has_focus`）が true。
   - `model.setEnabled(false)`。
   - `FocusEvent{ .gained = false }` → focus フラグが **false に落ちる**（修正前はここが落ちず失敗 ＝ 回帰検出点）。
3. 同じ 3 ステップを CheckBox / RadioButton / ComboBox にも適用。

`requestFocusFor` 経由の end-to-end は既存の `framework/tests/focus_test.zig`（`initHeadless` + Robot、GPU 必須・
device 無しでは skip）に 1 ケース足してもよいが、回帰の本命は上記の GPU 非依存テスト。置き場所は
`framework/tests/focus_test.zig` か各 widget の埋め込みテストのいずれか（実装時に決める）。

---

## 2. ② 無効ボタンのアイコンが灰色化しない

### 現状
活性ロジックは正しく、機能的には無効（押せない）。見た目だけが enabled と同一になる。

- 既定 LAF `Button.zig`: flat 分岐（`:277-287`）は無効時に背景を一切塗らない（flat としては正しい）。
  アイコンは `enabled` を無視してフル色で描画（`:322` `g.drawImageScaled(...)`）。
  text だけは無効時に `t.text_disabled` を使う（`:327-346`、色選択は `:329`）。
- metal LAF `metal.zig`: flat 分岐（`:285-294`）も無効時は背景なし。`paintContent` のアイコン描画（`:1234`）が
  同様に `enabled` を無視。text は `palette.text_disabled` を使う（`:1241`）。

結果、無効なツールバーアイコンボタンが enabled と見分けつかない（押せそうに見えて押せないアフォーダンス不一致）。

### 描画契約の検証（grey 乗算ではなく alpha 低下を採る根拠）
アイコン描画は最終的に `Graphics.imageQuad`（`awt/src/Graphics.zig:450`）→ Image program の tint uniform に乗る。
ピクセルシェーダは**純粋な乗算**で、blend は `.alpha`:

```hlsl
// awt/src/shaders/Image/image.hlsl.ps
return g_tex.Sample(g_samp, i.uv) * tint;   // sample * tint、blend = .alpha
```

ここから機械的に導ける重要事実:

- **tint の RGB に灰色を掛けても、暗い / 黒いアイコンは灰色化しない**（黒 `(0,0,0)` × 任意 = 黒）。
  乗算は色を暗くする方向にしか効かず、暗いアイコンを「淡い灰色」に持ち上げることはできない。
  ビルトインアイコン（Open / Save / Undo …）はモノクロ寄りの暗色想定なので、grey 乗算では減色に見えない。
- **tint の alpha を下げると、アイコンの色に依らず背景へ溶けて淡く見える**（`sample.a * tint.a`、blend `.alpha`）。
  これが「無効＝淡色」の一般的アフォーダンスと一致し、どんなアイコン色でも機能する。

よって減色は **tint = `Color.rgba(1, 1, 1, α)`（α < 1 の alpha 低下）** で行う。
（grey 乗算案は暗色アイコンで破綻するため不採用。）

### 必要な Graphics API（最小追加・additive）
内部 `imageQuad` は既に tint を取り、`drawTextureNineSlice`（`:479`）は公開 API で tint を受けている前例がある。
公開のスケール描画 `drawImageScaled`（`:446-448`）だけが tint を `(1,1,1,1)` 固定で隠している。

追加するのは tint を取る公開関数 1 本:

```zig
/// Like drawImageScaled, but modulates the image by `tint`. Pass a reduced
/// alpha (e.g. white with a<1) to render disabled icons faded. The pixel
/// shader multiplies the sample by tint, so RGB tint only darkens; use alpha
/// to fade regardless of the icon's own colors.
pub fn drawImageScaledTinted(self: *Graphics, image: Image, x: f32, y: f32, w: f32, h: f32, tint: Color) void {
    self.imageQuad(image, .{ .x = x, .y = y, .width = w, .height = h }, 0, 0, 1, 1, tint);
}
```

`drawImageScaled` は既存のまま（`drawImageScaledTinted(..., Color.rgba(1,1,1,1))` 相当）。既存の呼び出し元
（`Button.zig:322` / `Label.zig:312` / `metal.zig:1234` / `MenuItem.zig:210`）は変更不要。Zig には既定引数が無いため、
`drawImageScaled` に省略可能 tint を生やす案は採らず、関数を分ける。

### 両 LAF への適用
- `Button.zig:322` と `metal.zig:1234` のアイコン描画を `drawImageScaledTinted` に差し替え、
  enabled なら `Color.rgba(1,1,1,1)`、disabled なら `Color.rgba(1,1,1,α)` を渡す。
- flat 無効時の扱いも統一: 背景は従来どおり塗らない（flat の正しい挙動）。text は既存の `text_disabled` を踏襲。
  アイコンのみ上記 alpha 低下を足す。これで flat / 非 flat とも「無効＝text も icon も淡い」で一貫する。

### 減色 α の置き場（決めること）
- 案A: 各 LAF 内の名前付き定数（例 `disabled_icon_alpha`）。実需 1 件（本修正）に絞り、point-of-need に忠実。
- 案B: `Theme` / `MetalPalette` にスカラーフィールド（例 `icon_disabled_alpha: f32`）を additive に足す。
  既存の `text_disabled` がトークン化されている流儀と揃うが、第 2 の消費者が無い今は先回り。
- 推奨: 案A（定数）。`framework_backlog #4` の Theme 方針は「色のみ・メトリクスは実需が出たら additive」で、
  スカラー alpha も同じ後付けで足せる。最終判断は作者。

### テスト
- **ロジック（GPU 非依存）**: 「disabled なら淡い tint を選ぶ」判断を小さな純関数に切り出し
  （例 `iconTint(enabled) Color` を LAF 内に置く）、enabled / disabled で返る tint を直接アサート。
  paint 全体を回さずに減色判断だけを単体テストできる。
- **視覚契約（snapshot）**: 「無効アイコンボタンが実際に淡く描かれる」ことは見た目そのものが契約なので
  `snapshotPng` で押さえる。`framework_backlog #2` が既に「無効状態の Button の snapshot scene」を未カバーとして
  挙げており、icon-only / icon+text の無効ボタンを scene に足す形でそこへ寄せる。

---

## 3. ③ カーソル形状機構の欠落（本ブランチ対象外）
framework にカーソル形状の機構そのものが無く、テキストエリア上で I-beam、SplitPane 分割線上でリサイズカーソルに
ならない。これはエディタ回帰ではない既存ギャップで、awt / awt-c まで配線が要る大きめ feature。本ブランチでは
実装せず、[framework_backlog.md #32](framework_backlog.md) に 1 項目として起票した。
