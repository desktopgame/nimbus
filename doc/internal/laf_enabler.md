# LAF enabler（Look をツリーに当てる機構）設計

LAF 機構の **P3＝enabler** の設計提案。enabler とは「ある LAF（Look 一式）を既存のコンポーネントツリー全体へ
一括で当てる機構＋型ディスパッチ」を指す。`laf_design.md` §3（一括差し替えユーティリティ）と §5.3（P3・型識別の
宿題）の続きにあたり、ここでその 2 つを **確定提案**まで詰める。

この doc は `laf_design.md` の流儀を継ぎ、**「確定」と「未決」を明確に分ける**。実装はしない（コードは書かない）。

関連: [laf_design.md](laf_design.md)（§2 機構の確定・§3 ユーティリティの位置づけ・§5.3 フェーズ分け）、
`framework/src/Component.zig`（`LookVTable` / `UI` / `paintAt`）、`framework/tests/laf_test.zig`（既存の Look テスト）。

---

## 0. 現状確認（実装が doc を追い越している点）

`laf_design.md` は探索段階の記述で `ui` を移行期 optional として書くが（§2.10 / §5.2）、**実装は既に end-state に到達している**。
本 doc はこの現状を前提に書く（doc-impl-sync: 実装が doc を追い越すのは許容）。

- `Component.LookVTable = { paint, paintOver, measureMinSize }` は実在（`Component.zig:156`）。
  各シグネチャは `*const fn (self: *Component, ctx: *anyopaque, g: *awt.Graphics) void`（paint / paintOver）、
  `*const fn (self: *Component, ctx: *anyopaque) Size`（measureMinSize）。
- `Component.UI = { vtable: *const LookVTable, ctx: *anyopaque }` は **非 null フィールド** `ui: UI`（`Component.zig:162` / `:192`）。
  移行期フォールバックは既に撤去済み（§2.10 の end-state が実現済み）。`paintAt` は分岐レスで `self.ui` 経由
  （`Component.zig:620-629`）＝2 フェーズ paint（`paint` → 子再帰 → `paintOver`）も実装済み。
- 全 widget が create で自分の default Look をハードコードしている
  （例 `Button.zig:106` `b.component.ui = .{ .vtable = &look_vtable, .ctx = &Component.default_look_context }`）。
  各 widget ファイルに型ごと一意な `pub const look_vtable = Component.LookVTable{...}` がある。
- leaf の re-measure は各 widget の私的ヘルパ（例 `Button.updateMinSizeFromLook`、`Button.zig:121-124`）が
  `self.component.min_size = ui.vtable.measureMinSize(...)` で行う。container の `lookMeasureMinSize` は no-op で
  `{0,0}` を返す（`Container.zig:236-238`）＝container の最小は layout から導出する（§2.5）。

つまり **P1（足場＋代表 3 つ）と P2（全 widget 移行＋cutover）は完了済み**。残るのが本 doc の P3＝enabler である。

---

## 1. このフェーズのスコープ（確定）

enabler は **「機構＋FlatLaf 自己適用テスト」まで**を作る。

確定スコープ（本 doc で詰める）:

1. LAF の表現＝**vtable-remap 表**（§2）。
2. ツリーへ当てる**適用関数**（remap → re-measure → relayout）（§3）。
3. **部分 LAF**のセマンティクス（表に無い widget は据え置き）（§4）。
4. **FlatLaf 自己適用＝ゼロピクセル**の回帰ガードと、フェイク 2-widget LAF の headless テスト（§5）。
5. **ctx の所有・寿命**の置き方（§6）。

スコープ外（**次フェーズ＝Button 縦スライス**。依存として言及のみ）:

- 実 Metal Look（縦グラデーション body ＋ ベベル枠 ＋ measure）の描画ロジック。
- Metal パレット（自前ベイクの色・メトリクス定数）の中身。
- awt の 2 描画プリミティブ（linear グラデ／テクスチャ＋9-slice）。`awt_primitives_laf.md` で別途確定済み。

enabler の正しさは **Metal の絵がゼロのまま**（FlatLaf 自己適用＋フェイク LAF の純ロジック assert）で検証する。
実 Metal Look は enabler が完成してから縦スライスで足す。

---

## 2. LAF の表現＝vtable-remap 表（確定）

### 2.1 表のかたち

enabler に渡す「LAF」を、**「ある default look_vtable ポインタ → その LAF の `UI{vtable, ctx}`」の対応エントリの集合**
として表す。ツリー走査で各ノードの現 `component.ui.vtable` を鍵に引き、ヒットしたら `component.ui` を差し替える。

```zig
// 名前は仮（laf.zig など専用モジュールに置く想定。§3.2）
pub const RemapEntry = struct {
    /// 鍵＝差し替え対象の widget 型を表す default look_vtable ポインタ。
    /// 型ごとに一意な &Type.look_vtable をそのまま使う（§2.3）。
    from: *const Component.LookVTable,
    /// 値＝その LAF がこの型に与える Look（vtable＋ctx）。
    to: Component.UI,
};

/// LAF ＝ remap エントリのスライス。要素数は widget 型数オーダー（~25）。
pub const LookTable = []const RemapEntry;
```

- **スライス（`[]const RemapEntry`）で十分**。表の引きは線形走査でよい（型数は数十・走査はツリーノード数 × 表サイズで、
  init 時 1 回きり。perfect-hash や comptime map は過剰＝採用しない）。
- 表は呼び出し側（バインディング層 or テスト）が **静的に組む**。Zig コアは表の中身を知らない
  （§1.2: コアは機構のみ・名前付き LAF は上層）。

### 2.2 既存の型ごと一意な look_vtable を「型タグ」に流用する（§5.3 の宿題を解く）

`laf_design.md` §5.3 / §6 が「P3 で詰める型識別の宿題」と置いていた点を、ここで **新しい型タグ（enum 等）を足さずに解く**。

- 各 widget 型は `pub const look_vtable`（型ごとに 1 つの `const`）を持つ。`&Type.look_vtable` は
  **型ごとに一意で安定したアドレス**になる（同型の全インスタンスがこの 1 つを指す＝`laf_test.zig:48-54` が
  `button.component.ui.vtable == &nimbus.Button.look_vtable` で実証）。
- よってこのポインタ自体が **de-facto な型識別子**として機能する。enum タグを別途導入して各 widget に持たせる必要はない。
- enabler は「Button をこの Look にせよ」を「`&Button.look_vtable` → 新 `UI`」という 1 エントリで表現する。

### 2.3 ポインタ等価比較の安全性

鍵の照合は `node.ui.vtable == entry.from` の **ポインタ等値比較**で行う。これは安全:

- `*const LookVTable` 同士の `==` は **アドレス比較**で、Zig で well-defined。
- 各 `&Type.look_vtable` は単一の `const` のアドレスで、リンク後も実行中ずっと不変。comptime に確定し、
  重複しない（型ごとに別の `const`）。
- したがって「鍵がたまたま衝突する」ことは起きない。表に無いポインタは単にヒットせず据え置き（§4）。

**前提条件（呼び出し規約として明記）**: enabler は **default Look のままのツリー**（全ノードが `&Type.look_vtable` を
指す状態）に対し **init 時 1 回**当てる。これにより鍵が必ず default vtable に揃う。一度 remap した後のツリーに
別の表を重ねがけする使い方は v1 では想定しない（鍵が既に新 vtable に化けているため）。実行時差し替え非対応
（`laf_design.md` §1.1）と整合する。FlatLaf 自己適用（§5.1）は from と to の vtable が同一なので、唯一安全に
冪等な重ねがけになる。

---

## 3. 適用関数（確定）

### 3.1 署名

```zig
// root を起点に部分木全体へ table を当てる。失敗しない（純粋にポインタ書き換え＋measure）。
pub fn applyLook(root: *Component, table: LookTable) void
```

`root` には通常 Window のルートコンテナの `component`（`window.container.component`）を渡す。サブツリーにも当てられる
（部分適用も同じ関数で表現可能）。戻り値なし・エラーなし（割り当てを伴わない）。

### 3.2 置き場所

- **専用モジュール `framework/src/laf.zig`（仮）の自由関数**として置く。`Component` のメソッドにはしない。
- 理由: `laf_design.md` §3 が「power-user / irregular なツール。`init` / `initWithTheme` と並ぶ第一級 API では
  なく脇に置く」と確定済み。Component の基本 API 面を膨らませず、LAF 機構として隔離する。
- フレームワークルート（`nimbus`）から `pub const laf = @import("laf.zig");` で露出し、`nimbus.laf.applyLook(...)` で呼ぶ
  （露出の細部は実装時に決めてよい）。

### 3.3 巡回と処理（remap → re-measure → relayout）

1 ノードあたり次の順で処理し、ツリー全体に対し再帰で回す。

```
applyLook(root, table):
    walk(root, table)            // 全ノードを remap ＋ leaf を re-measure ＋ container キャッシュ無効化
    root.markLayoutDirty()       // 次フレームの redraw に relayout を任せる（§3.5）

walk(node, table):
    // 1. remap（型タグ照合）
    for entry in table:
        if node.ui.vtable == entry.from:
            node.ui = entry.to   // vtable と ctx をまとめて差し替え
            break                // 先勝ち（表に重複鍵は置かない前提）
    // 2. re-measure（leaf のみ）
    if node.container == null:                       // leaf＝コンテナでない
        node.min_size = node.ui.vtable.measureMinSize(node, node.ui.ctx)
    else:
        node.container.invalidateSizeCache()         // container は min を layout から再導出（§3.4）
    // 3. 子へ再帰（paintAt と同一の巡回）
    if node.container != null:
        for elem in node.container.children.items:
            walk(elem.component, table)
```

- **巡回は `paintAt` と同じ経路**（`component.container.?.children.items[].component`、`Component.zig:624-628`）。
  これにより「描かれるノード集合」と「Look が当たるノード集合」が一致する。`paintAt` が辿らないノード
  （あれば）はそもそも描画されないので Look を当てる必要も無い＝コンテナを通る単一の正準巡回で過不足ない。
- **remap は ui を `{vtable, ctx}` セットで差し替える**。paint と measureMinSize が同じ `LookVTable` に同居するため、
  「paint だけ替えて寸法が古いまま潰れる」不整合は起きない（`laf_design.md` §2.6）。

### 3.4 re-measure を leaf に限定する理由（重要）

re-measure（`node.min_size = measureMinSize(...)`）は **leaf（`node.container == null`）にだけ**行う。コンテナには行わない。

- コンテナの `lookMeasureMinSize` は no-op で `{0,0}` を返す（`Container.zig:236-238`）。
  これをコンテナの `min_size` に書き戻すと、`Container.getMinSize` が
  `@max(component.min_size, layout 由来)` で合成している **明示 floor（外部 `setMinSize`）を 0 で潰す**
  （`Container.zig:148-152`）。
- コンテナの最小は **子から layout が導出する**（`laf_design.md` §2.5: measureMinSize は leaf 用フック）。
  よってコンテナは re-measure せず、`invalidateSizeCache()` でメモを捨てるだけにする。次の relayout が
  子の新 `min_size` から再合成する。
- leaf の measureMinSize は新 Look の ctx・メトリクスを使って新しい intrinsic 最小を返す。これを `min_size` に
  焼くのが enabler の役目（各 widget の `updateMinSizeFromLook` がインスタンス内でやっていることを、
  enabler は型横断で 1 回やる）。

### 3.5 relayout の起こし方（既存経路の再利用）

enabler は **`doLayout` を直接呼ばない**。既存の dirty → redraw 経路に乗せる。

- 走査中に各コンテナの `invalidateSizeCache()` を呼ぶ（§3.3 step 2）。これは `markLayoutDirty` が
  「root へのパス上のコンテナ」しか無効化しない（`Component.zig:585-607`）のに対し、enabler は **全コンテナ**の
  メモを捨てる必要があるため（ツリー中の多数の leaf の `min_size` を変えたので）。走査が全ノードを訪れる
  この機会に各コンテナのキャッシュを落とすのが最も素直。
- 最後に `root.markLayoutDirty()` を 1 回呼ぶ。これがルートの `DirtyNotify` を叩き、Window の
  `layout_dirty` / `paint_dirty` を立てる（`Window.zig:583-589`）。実際の `doLayout` は次の
  `Window.redraw` が **唯一の正規の場所**で回す（`Window.zig:387-407`）。
- `doLayout` を enabler から直接叩かないのは、`Container.setBounds` が doLayout を呼ばない設計
  （2^k footgun 回避。`Container.zig:182-190`）と「`Window.redraw` が唯一の doLayout 起点」という不変条件を
  守るため（[[project_setbounds_dolayout_split]]）。

### 3.6 タイミング（確定）

- enabler は **init 時・最初の描画前に 1 回**呼ぶ（`laf_design.md` §1.1 のセッション固定を実現する唯一の入口）。
- `root` がまだ Window に接続されていない段階（ルートの `DirtyNotify` 未設置）で呼んでも安全:
  `markLayoutDirty` はルートで no-op になるだけで、ツリーの `min_size` とキャッシュ状態は正しく更新済み。
  その後 Window へ接続され最初の `redraw` が走れば、初回フレームは常に layout するため正しくレイアウトされる。

---

## 4. 部分 LAF のセマンティクス（確定）

**表に無い widget は default（FlatLaf）のまま残す**。これを明示的に正とする。

- 走査で `node.ui.vtable` が表のどの `from` にもヒットしなければ、その node は触らない（remap も re-measure も
  しない＝`min_size` も Look も据え置き）。
- 帰結: **Metal を全 widget 分そろえる前でも、Button だけ Metal・残りは FlatLaf** という状態が正当に動く。
  これは縦スライス開発（まず Button だけ Metal を作り込む次フェーズ）と整合する。表に Button エントリだけ
  入れて当てれば、Button だけ Metal Look になり、ほかは FlatLaf のまま破綻しない。
- 「全 widget をそろえないと当てられない」という all-or-nothing 制約を **持ち込まない**。

---

## 5. テスト方針（確定）

enabler の正しさを **Metal の絵ゼロ**で検証する。既存 `framework/tests/laf_test.zig` の作法
（`RecordingLookContext` / headless `Application`）を踏襲する。

### 5.1 FlatLaf 自己適用＝ゼロピクセル不変（回帰ガード）

各 widget 型の default vtable を **自分自身へ**写す identity 表を作る:

```
FlatLaf identity table = 各 widget 型 T について
    RemapEntry{ .from = &T.look_vtable, .to = .{ .vtable = &T.look_vtable, .ctx = &default_look_context } }
```

これをツリーに `applyLook` しても **見た目は一切変わらない**（from と to の vtable／ctx が同一）。検証は 2 段:

- **headless 純ロジック assert（主）**: 適用前後で全ノードの `ui.vtable` / `ui.ctx` / `min_size` が
  ビット同値であることを assert（rendering 不要・割り当て不要）。enabler の走査・照合・冪等性を直接突く。
- **snapshot golden ゼロ差分（従）**: 既存のスナップショット golden を 1 枚も動かさない（`laf_design.md` §5.1 の
  ゼロピクセル不変条件の再利用）。golden が動いたら enabler のバグを疑う。

これを回帰ガードに据える＝**Metal を 1 ピクセルも描かずに enabler の骨格を固められる**。

### 5.2 フェイク 2-widget LAF（純ロジック assert）

`recording_look_vtable` 系の作法でフェイク Look を 2 つ用意し（例 fake-button / fake-panel）、それぞれ
**判別可能な ctx** と **既知の固定サイズを返す `measureMinSize`** を持たせる。表は
`&Button.look_vtable → fake-button`、`&Panel.look_vtable → fake-panel` の 2 エントリのみ。

ツリーに Button・Panel・**Label（表に無い）**・素の Container を置いて `applyLook` し、次を assert:

- **差し替わったか**: `button.ui.vtable == &fake_button_look` かつ `button.ui.ctx` が指定したフェイク ctx。
- **re-measure が走ったか**: `button.min_size` がフェイク `measureMinSize` の返した既知サイズに一致
  （remap 後に新 Look の measure で焼き直された証拠）。
- **表に無い widget が据え置かれたか（部分 LAF）**: `label.ui.vtable == &Label.look_vtable`、`label.min_size` 不変。
- **container が re-measure されず・キャッシュが無効化されたか**: 親 Container の `min_size` フィールドは
  不変（leaf 限定 re-measure。§3.4）で、`min_cache` が `null` に落ちている（§3.5）。

すべて rendering を伴わない純ロジックで、enabler の 3 ステップ（remap / leaf re-measure / container キャッシュ無効化）を
独立に突ける。

---

## 6. ctx の所有・寿命（確定方針）

Metal Look の `ctx`（自前パレット等）が **ツリー生存中ずっと有効**であることを保証する。`laf_design.md` §6-3 の積み残しを
ここで確定する。

**推奨＝モジュールレベル `const` で静的寿命にする（既定の解）。**

- LAF は init 固定・実行時差し替え不可（§1.1）で、パレットは current Theme に依存せず自前ベイク（§2.9）。
  よって Metal パレットは **comptime 確定の immutable データ**にできる。`pub const metal_palette = MetalPalette{...}` を
  Look モジュールに置き、`to.ctx = &metal_palette` とすれば、static 寿命でプロセス全体で有効＝**所有者を問う必要が消える**。
- FlatLaf の既定 ctx が `&Component.default_look_context`（`u8` の `pub var` static、`Component.zig:167`）なのと同じ筋。
  ctx に状態が要らない Look は共有 static を指せばよい。

**フォールバック＝Application が所有する（ctx を実行時に組む必要が出た場合のみ）。**

- パレットを実行時に構築する必要が将来出たら（例: 起動時の設定から派生）、その ctx は **Application が所有**し、
  `Application.deinit` で解放する。Application はセッション全体（＝ツリーより長命）を生きるので、
  `applyLook` で配った ctx ポインタはツリー生存中ずっと有効。
- v1 の実 Metal Look 着手時（次フェーズ）は **まず静的 `const` で始める**。実行時 ctx が要ると判明した時点で
  Application 所有へ格上げする。enabler 側（`applyLook`）は ctx を **不透明ポインタとして配るだけ**で、所有も解放もしない
  （ctx の寿命は呼び出し側＝表を組んだ層の責任）。この責任分界を呼び出し規約として明記する。

---

## 7. 未決（解決しない・列挙のみ）

- **モジュール／関数名**: `laf.zig` / `applyLook` / `RemapEntry` / `LookTable` は仮。確定不要で進めてよい
  （`laf_design.md` §6-1 の命名未決の延長）。
- **`measureMinSize` と `size_query` の統合**: height-for-width の `size_query`（`Component.zig:211`）は
  enabler では触らない（layout が従来どおり読む）。統合可否は `laf_design.md` §6-2 のまま未決。
- **外部 `setMinSize` と delegate 自動計算の潰し合い**: leaf の re-measure が `min_size` を上書きするため、
  外部 `setMinSize` は enabler 後に消える（`laf_design.md` §6-4 の未決そのまま）。enabler はこの既存挙動を
  変えない（leaf 上書き・container は floor 同居）。explicit-set フラグ導入は未決。
- **重ねがけ／再適用**: 一度 remap したツリーへ別の表を当てる（実行時切替もどき）は v1 非対応（§2.3 前提）。
  将来やるなら「現 Look → default へ戻す逆写し」か「元 default vtable をノードに保持」かの設計が要る＝未決。

---

## 8. 確定／未決サマリ

| 区分 | 項目 |
|---|---|
| 確定 | enabler のスコープ＝機構＋FlatLaf 自己適用テストまで。実 Metal Look／パレット／awt プリミティブは次フェーズ（§1） |
| 確定 | LAF の表現＝vtable-remap 表。`RemapEntry{from: *const LookVTable, to: UI}` のスライス `LookTable`（§2.1） |
| 確定 | 型ごと一意な `&Type.look_vtable` を型タグに流用し §5.3 の宿題を解く（新 enum 不要）（§2.2） |
| 確定 | 鍵照合はポインタ等値比較（安全）。default Look のツリーへ init 時 1 回当てる前提（§2.3） |
| 確定 | `applyLook(root: *Component, table: LookTable) void` を専用モジュール `laf.zig` の自由関数として置く（§3.1-3.2） |
| 確定 | 巡回は `paintAt` と同一経路。remap → leaf のみ re-measure → container はキャッシュ無効化（§3.3-3.4） |
| 確定 | re-measure は leaf 限定（container の `min_size` を 0 で潰さない。最小は layout 導出）（§3.4） |
| 確定 | relayout は `doLayout` 直呼びせず、全 container の `invalidateSizeCache` ＋ root の `markLayoutDirty` で次 redraw に委ねる（§3.5） |
| 確定 | 適用は init 時・最初の描画前に 1 回。未接続ツリーに呼んでも安全（§3.6） |
| 確定 | 部分 LAF＝表に無い widget は FlatLaf 据え置き。all-or-nothing にしない（§4） |
| 確定 | FlatLaf identity 表でゼロピクセル不変を回帰ガードに。フェイク 2-widget LAF で remap／re-measure／据え置きを headless assert（§5） |
| 確定 | ctx は静的 `const`（既定）／実行時構築なら Application 所有。`applyLook` は ctx を不透明に配るだけで所有しない（§6） |
| 未決 | 命名／`measureMinSize`×`size_query` 統合／`setMinSize` 衝突／重ねがけ・再適用（§7） |
