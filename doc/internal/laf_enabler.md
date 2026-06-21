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
2. ツリーへ当てる**適用関数**（remap → re-measure → relayout）＝統合 child アクセサ＋メニュー popup への
   到達を含む全 paint 到達ノードの走査（§3）。これに伴う **framework 側の小さな facet 追加**
   （popup_root を Look 走査の論理子として公開する detached look root facet）も enabler のスコープ内（§3.7）。
3. **部分 LAF**のセマンティクス（表に無い widget は据え置き）（§4）。
4. **FlatLaf 自己適用＝ゼロピクセル**の回帰ガードと、フェイク LAF（**メニュー系を含む**）の GPU 非ゲート
   headless テスト（§5）。
5. **ctx の所有・寿命**の置き方（§6）。

スコープ外（**次フェーズ＝Button 縦スライス**。依存として言及のみ）:

- 実 Metal Look（縦グラデーション body ＋ ベベル枠 ＋ measure）の描画ロジック。
- Metal パレット（自前ベイクの色・メトリクス定数）の中身。
- awt の 2 描画プリミティブ（linear グラデ／テクスチャ＋9-slice）。`awt_primitives_laf.md` で別途確定済み。

enabler の正しさは **Metal の絵がゼロのまま**（FlatLaf 自己適用＋フェイク LAF の純ロジック assert）で検証する。
実 Metal Look は enabler が完成してから縦スライスで足す（Button 縦スライスの設計 spec は
[laf_metal_button.md](laf_metal_button.md)）。

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

#### 3.3.1 当初設計の前提が誤っていた（正直な訂正）

初版の §3.3 は walk を `node.container.?.children` の再帰だけで定義し、「**walk の訪問集合＝`paintAt` の訪問集合**」
だから過不足ない、と書いていた。**これは偽だった**（adversarial レビューで FIX-NEEDED。`laf_design.md` の流儀に従い
取り繕わず訂正する）。実際には子の持ち方が `container.children` 一本ではない:

- **メニュー系は子を `container.children` に持たない**。`MenuBar` は `container == null`（`install` は何もしない、
  `MenuBar.zig:107`）で、子（バー項目の `Menu`）を private な `menus: ArrayList(*Menu)`（`MenuBar.zig:16`）に持ち、
  それを `tree_children` facet（`MenuBar.zig:54`）で公開する。`MenuBar.lookPaint` は `menus.items` を
  **手回しで `paintAt`** している（`MenuBar.zig:126`）。`Menu`/`PopupMenu` の項目も同様に private `items` ＋
  別 Component の `popup_root`（`Menu.zig:30,35,111` / `PopupMenu.zig:19,20,50`）に持つ。
- そもそも「`paintAt` の訪問集合」も `container.children` 一本ではない。Look paint が手回しで子を `paintAt` したり
  （MenuBar）、**popup は overlay 経由で別経路・別タイミング（show 時）に描かれる**（`Menu.zig:271`）。
  つまり「描かれるノード」は静的ツリーの `container.children` 再帰より広い。

→ 旧 walk は `MenuBar` を leaf 扱いして止まり、メニュー／項目／popup に Look が届かなかった。
正しい不変条件は「**walk の訪問集合 ⊇ セッション中に描かれうる全ノード（静的ツリー＋overlay attach される popup 含む）**」。
以下はこの正しい定義での walk。

#### 3.3.2 訂正後の walk

```
applyLook(root, table):
    walk(root, table)            // 全ノードを remap ＋ true-leaf を re-measure ＋ container キャッシュ無効化
    root.markLayoutDirty()       // 次フレームの redraw に relayout を任せる（§3.5）

walk(node, table):
    // 1. remap（型タグ照合）
    for entry in table:
        if node.ui.vtable == entry.from:
            node.ui = entry.to   // vtable と ctx をまとめて差し替え
            break                // 先勝ち（表に重複鍵は置かない前提）
    // 2. re-measure（true leaf のみ。判定は §3.4）
    if node.container == null and node.tree_children == null:
        node.min_size = node.ui.vtable.measureMinSize(node, node.ui.ctx)
    if node.container != null:
        node.container.invalidateSizeCache()         // container は min を layout から再導出（§3.4）
    // 3. 子へ再帰：論理子（container ∪ tree_children）＋ 遅延 attach される popup
    for i in 0 .. node.automationChildCount():        // container か tree_children を両対応（§3.3.3）
        walk(node.automationChildAt(i), table)
    if node has detached look roots:                  // メニュー popup_root（§3.7）
        for r in node.detachedLookRoots():
            walk(r, table)
```

#### 3.3.3 統合 child アクセサを使う

再帰は既存の統合アクセサ `automationChildCount` / `automationChildAt`（`Component.zig:369-378`）経由にする。
これは `container` があれば `container.children`、無く `tree_children` があればそちら、を両対応で返す
（Driver が意味ツリー走査に使う既存 API）。これにより:

- 通常のコンテナ（`container.children`）と `MenuBar`→`menus`（`tree_children`）を**同一の再帰で**辿れる。
- `MenuBar`→バー項目 `Menu` まで Look が届く（旧 walk の取りこぼしが解消）。

ただし `popup_root` への遅延 attach（§3.7）は automation tree に乗らないので、別の `detached look roots`
で補う（§3.7 で確定）。

- **remap は ui を `{vtable, ctx}` セットで差し替える**。paint と measureMinSize が同じ `LookVTable` に同居するため、
  「paint だけ替えて寸法が古いまま潰れる」不整合は起きない（`laf_design.md` §2.6）。

### 3.4 re-measure の判定＝「true leaf」（論理子を持たないノード）（重要）

re-measure（`node.min_size = measureMinSize(...)`）は **論理子を持たない true leaf にだけ**行う。
**判定は `node.container == null and node.tree_children == null`**（初版の「`container == null` だけ」は誤りだった）。

- 初版は leaf を `container == null` で判定していた。だが `MenuBar` は `container == null` でも `tree_children` を持つ
  **composite** であり（`MenuBar.zig:54`）、子を持つノードを re-measure してはいけない。判定に `tree_children == null` を
  足して composite を除外する。
- なぜ composite を re-measure しないか: コンテナの `lookMeasureMinSize` は no-op で `{0,0}` を返す
  （`Container.zig:236-238`）。これをコンテナの `min_size` に書き戻すと、`Container.getMinSize` が
  `@max(component.min_size, layout 由来)` で合成する **明示 floor（外部 `setMinSize`）を 0 で潰す**
  （`Container.zig:148-152`）。コンテナの最小は子から layout が導出する（`laf_design.md` §2.5: measureMinSize は
  leaf 用フック）。`MenuBar.lookMeasureMinSize` は `self.min_size` を返す identity（`MenuBar.zig:131-133`）なので
  書き戻しても実害は無いが、判定を「論理子の有無」で統一しておけば将来 composite の measure が変わっても安全。
- `container` を持つノードは re-measure しないが、`invalidateSizeCache()` でメモは捨てる（§3.5）。次の relayout が
  子の新 `min_size` から再合成する。
- true leaf の measureMinSize は新 Look の ctx・メトリクスで新しい intrinsic 最小を返す。これを `min_size` に
  焼くのが enabler の役目（各 widget の `updateMinSizeFromLook` がインスタンス内でやることを、enabler は
  型横断で 1 回やる）。
- **detached look root（§3.7）は再帰のソースであって re-measure 判定には絡めない**。たとえばバー項目 `Menu` は
  `container`・`tree_children` ともに null（popup_root 側が tree_children を持つ。`Menu.zig:111`）なので **true leaf
  として自身のバーラベル min を re-measure** しつつ、同時に detached root として `popup_root` へ再帰する。
  この 2 つは独立した判定であり、「popup を持つから re-measure しない」とはしない（バー項目は自分の寸法を持つ）。

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

### 3.7 popup_root の遅延 attach 問題（要設計判断・確定提案）

#### 3.7.1 何が難しいか

`Menu`/`PopupMenu` の `popup_root` は **別 Component**（独自 `popup_look_vtable`、`Menu.zig:67` / `PopupMenu.zig:33`）で、
**show 時に初めて overlay へ attach される**（`w.overlays.add(&self.popup_root, ...)`、`Menu.zig:271`）。
applyLook は「init 時 1 回」（§3.6）なので、その時点で popup サブツリーはどの木にも繋がっておらず、統合 child
アクセサ（§3.3.3）でも届かない。さらに **バー項目 `Menu.component` 自身は `tree_children` を持たず**、`tree_children` を
持つのは `popup_root` の方（`Menu.zig:111`：バー項目 → popup_root の論理エッジが無い）。一方 popup の `items` は
`add` 時点で `items` リストへ入る（show より前から存在。`PopupMenu.zig:63-72`）ので、**walk が popup_root まで降りられれば
items まで remap 可能**。要するに「バー項目 → popup_root」の 1 エッジが欠けているのが核心。

#### 3.7.2 採用案＝(a) 静的エッジ（専用フックで popup_root を論理子として公開）

**`Menu`（および standalone な `PopupMenu`）が、init 時から `popup_root` を「Look 走査用の論理子」として返す
専用フックを持つ。** enabler の walk はこのフック経由で popup_root へ降り、popup_root の `tree_children`（items）から
各項目まで remap する。これは framework 側に**小さなエッジ追加**が要る（Codex 実装）。必要な変更箇所:

- **`Component` に opt-in facet を 1 つ足す**（名前は仮 `detached_look_roots`／`look_extra_roots`）。
  形は他の opt-in facet（`tree_children` / `DropTarget` 等）と同じ「null 可・関数ポインタ束」:
  `detached_look_roots: ?struct { count: *const fn(*const Component) usize, at: *const fn(*const Component, usize) *Component }`。
  null＝遅延 attach される別木を持たない（ほとんどの widget）。
- **`Menu.create` でこの facet を設定し、`popup_root`（1 件）を返す**。`Menu` は bar/item どちらのモードでも
  自分の `popup_root` を返す（サブメニューの入れ子も、親 popup_root の `items` に入った item-mode `Menu` が
  さらに自分の popup_root を返すことで再帰的に降りられる）。
- **`PopupMenu` は静的ツリーに `component` を持たない**（`popup_root` のみ。`PopupMenu.zig:19`）。
  window root からは決して届かないので、利用者が **`applyLook(&popupMenu.popup_root, table)` を個別に当てる**
  運用にする（power-user の責務として doc 明記。§3.7.4）。`popup_root.tree_children` が items を返すので、
  この個別適用だけで popup 全体に Look が乗る。

なぜ **専用 facet** か（`tree_children` の拡張ではなく）:

- `tree_children` は **automation / accessibility ツリー**（Driver が消費）。バー項目 `Menu.component` の
  `tree_children` に popup_root をぶら下げると、**閉じている popup の項目まで automation 子として常時露出**し、
  既存の意味ツリー契約・Driver テストを変えてしまう。LAF 走査の都合で automation 木を歪めるのは筋が悪い。
- 専用 facet なら **enabler の走査だけに効き、automation 木は不変**。「walk ＝ automation 子 ＋ detached look root」と
  走査契約を明示でき、§3.3.1 で訂正した不変条件（walk ⊇ 全描画ノード）を正直な定義で復元できる。

#### 3.7.3 不採用案＝(b) 表を保持して show 時に遅延適用

「適用した table をセッション中保持し、menu show 時に popup_root へ applyLook する」案。**不採用**。

- applyLook＝init 1 回・実行時差し替え非対応（`laf_design.md` §1.1）という単純さを崩す。表をどこかが
  握り続け、全 popup の show 経路にフックを差す必要があり、init 一発で固定する設計思想と噛み合わない。
- (a) の静的エッジは framework に 1 facet 足すだけで、**走査は init の 1 パスに閉じる**。こちらが筋が良い。

#### 3.7.4 満たすべき不変条件

どちらの経路でも「**init 時 1 回の walk で、セッション中に描かれうる全ノード（popup 中身含む）に Look が当たる**」を満たす:

- window 配下: `applyLook(window.container.component, table)` が automation 子経由で MenuBar→menus→各 Menu、
  detached root 経由で各 Menu→popup_root→items まで到達。
- standalone PopupMenu: 利用者が生成した各 `PopupMenu` に `applyLook(&pm.popup_root, table)` を個別に当てる。
- popup のレイアウトは show 時に `Menu.show` が `items` の `min_size` から組む（`Menu.zig:258-269`）ので、
  re-measure で items の `min_size` が更新されていれば、次の show で正しい寸法に並ぶ（popup 用の特別な relayout は不要）。

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

enabler の正しさを **Metal の絵ゼロ**で検証する。既存 `framework/tests/laf_test.zig` の
`RecordingLookContext` 作法を踏襲する。

### 5.0 純ロジックは GPU ゲートから外す（test-validity・確定）

enabler の純ロジックテストは **GPU 非依存**で書く。初版が想定した `newApp()` 経由は不可
（adversarial レビューで FIX-NEEDED）。理由:

- `newApp()`＝`Application.initHeadless` → `Device.init()` の**ゲート下**にあり、GPU の無い環境では
  `error.SkipZigTest` で**黙って skip** される（`laf_test.zig:13-17`）。`newApp` を使っていたのは
  `app.default_font` を取るためだけで、enabler ロジックの検証に GPU は本来不要。
- このまま書くと CI/開発機の構成次第で enabler テストが**実行されずに緑**になり、回帰ガードが機能しない。

対策（手本＝同ファイルの既存 `"paintAt dispatches ..."` テスト。`laf_test.zig:99-137` が raw `Container.create` で
GPU 非依存に組めている）:

- **木は GPU 不要な経路で組む**。`Container` / `Panel` など**フォント無しで `create` できる widget**で骨格を作る。
- フォントを要する widget（Button / Label / Menu 等）を含めたい場合は、GPU を起こさず**スタブ／ヘッドレス
  フォント**を渡す（フォント取得を `Device.init` 経由にしない）。`measureString` が呼べれば足りる。
- いずれにせよ **`error.SkipZigTest` 経路を踏まない**こと。enabler の純ロジックテストは常に実行される。

### 5.1 FlatLaf 自己適用＝ゼロピクセル不変（回帰ガード）

各 widget 型の default vtable を **自分自身へ**写す identity 表を作る:

```
FlatLaf identity table = 各 widget 型 T について
    RemapEntry{ .from = &T.look_vtable, .to = .{ .vtable = &T.look_vtable, .ctx = &default_look_context } }
```

これをツリーに `applyLook` しても **見た目は一切変わらない**（from と to の vtable／ctx が同一）。検証は 2 段:

- **headless 純ロジック assert（主・§5.0 の非ゲートで）**: 適用前後で全ノードの `ui.vtable` / `ui.ctx` /
  `min_size` がビット同値であることを assert（rendering 不要・割り当て不要）。enabler の走査・照合・冪等性を直接突く。
- **snapshot golden ゼロ差分（従）**: 既存のスナップショット golden を 1 枚も動かさない（`laf_design.md` §5.1 の
  ゼロピクセル不変条件の再利用）。golden が動いたら enabler のバグを疑う。

これを回帰ガードに据える＝**Metal を 1 ピクセルも描かずに enabler の骨格を固められる**。

### 5.2 フェイク LAF（純ロジック assert・メニュー系を必ず含む）

`recording_look_vtable` 系の作法でフェイク Look を用意し（**判別可能な ctx** と **既知の固定サイズを返す
`measureMinSize`**）、表で default vtable をフェイクへ写す。テスト木には **Button・Panel・Label（表に無い）・
素の Container に加え、`MenuBar`＋バー項目 `Menu`＋`MenuItem`（popup 中身）を必ず含める**（§3.3 の取りこぼし FIX の
回帰ガード）。表は **メニュー系 vtable も差し替え対象**にする（identity 表だと from==to で不可視なので、
メニュー到達の検証はフェイク表で行う）。assert 項目:

- **差し替わったか**: `button.ui.vtable == &fake_button_look` かつ `button.ui.ctx` が指定したフェイク ctx。
- **re-measure が走ったか**: `button.min_size` がフェイク `measureMinSize` の返した既知サイズに一致
  （remap 後に新 Look の measure で焼き直された証拠）。
- **表に無い widget が据え置かれたか（部分 LAF）**: `label.ui.vtable == &Label.look_vtable`、`label.min_size` 不変。
- **container が re-measure されず・キャッシュが無効化されたか**: 親 Container の `min_size` フィールドは
  不変（true-leaf 限定 re-measure。§3.4）で、`min_cache` が `null` に落ちている（§3.5）。
- **メニューサブツリーが remap されたか（FIX 1 の回帰ガード）**: `MenuBar`→バー項目 `Menu`→`popup_root`→`MenuItem`
  の各 `ui.vtable` がフェイクへ化けていることを assert する。とくに **popup 中身（`popup_root` 配下の `MenuItem`）**が
  化けていることを突く（detached look root 経由の到達＝§3.7 の検証）。バー項目 `Menu` 自身が true leaf として
  re-measure されつつ popup へも降りた、という両立も確認する。

すべて rendering を伴わない純ロジックで、enabler の各ステップ（remap / true-leaf re-measure /
container キャッシュ無効化 / メニュー到達）を独立に突ける。

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

- **モジュール／関数名**: `laf.zig` / `applyLook` / `RemapEntry` / `LookTable`、および §3.7 の detached look root facet名
  （`detached_look_roots` 等）は仮。確定不要で進めてよい（`laf_design.md` §6-1 の命名未決の延長）。
- **`measureMinSize` と `size_query` の統合**: height-for-width の `size_query`（`Component.zig:211`）は
  enabler では触らない（layout が従来どおり読む）。統合可否は `laf_design.md` §6-2 のまま未決。
- **外部 `setMinSize` と delegate 自動計算の潰し合い**: true leaf の re-measure が `min_size` を上書きするため、
  外部 `setMinSize` は enabler 後に消える問題は **explicit-set フラグで解決**（`Component.min_size_explicit` を
  公開 `setMinSize` で立て、`applyLook` の re-measure を `!min_size_explicit` でガード）。
  確定設計は [min_size_explicit.md](min_size_explicit.md)。container は従来どおり floor 同居で無改修。
- **重ねがけ／再適用**: 一度 remap したツリーへ別の表を当てる（実行時切替もどき）は v1 非対応（§2.3 前提）。
  将来やるなら「現 Look → default へ戻す逆写し」か「元 default vtable をノードに保持」かの設計が要る＝未決。
- **standalone `PopupMenu` の個別適用を誰が呼ぶか**: §3.7.2 の通り window root から届かないため
  `applyLook(&pm.popup_root, table)` を個別に当てる必要がある。これを利用者の手作業に委ねるか、
  バインディング層の名前付き LAF 適用が PopupMenu 群を集めて自動で回すかは未決（コア機構は個別適用を提供するだけ）。
- **detached_look_roots は ComboBox にも要る**: ComboBox のドロップダウン（`popup_root`）も Menu と同型の遅延 attach
  なので、Metal を届けるには ComboBox にも detached facet を設定する（[laf_metal_selection.md](laf_metal_selection.md) §4.2 で確定）。
  対照的に **ScrollPane の ScrollBar は通常の `container.children`** なので automation walk だけで届き、detached facet は要らない
  （[laf_metal_range.md](laf_metal_range.md) §1.3）。

---

## 8. 確定／未決サマリ

| 区分 | 項目 |
|---|---|
| 確定 | enabler のスコープ＝機構＋FlatLaf 自己適用テストまで。実 Metal Look／パレット／awt プリミティブは次フェーズ（§1） |
| 確定 | LAF の表現＝vtable-remap 表。`RemapEntry{from: *const LookVTable, to: UI}` のスライス `LookTable`（§2.1） |
| 確定 | 型ごと一意な `&Type.look_vtable` を型タグに流用し §5.3 の宿題を解く（新 enum 不要）（§2.2） |
| 確定 | 鍵照合はポインタ等値比較（安全）。default Look のツリーへ init 時 1 回当てる前提（§2.3） |
| 確定 | `applyLook(root: *Component, table: LookTable) void` を専用モジュール `laf.zig` の自由関数として置く（§3.1-3.2） |
| 訂正 | 初版の「walk＝`container.children` 再帰＝`paintAt` 訪問集合」は**偽**だった。メニュー系は子を `tree_children`／別 popup_root に持つ（§3.3.1） |
| 確定 | walk は統合アクセサ `automationChildCount/At`（container ∪ tree_children）＋ detached look root を辿る（§3.3.2-3.3.3） |
| 確定 | re-measure は **true leaf**（`container == null` かつ `tree_children == null`）限定。MenuBar 等 composite を除外（§3.4） |
| 確定 | バー項目 `Menu` は true leaf として自身を re-measure しつつ detached root（popup_root）へも降りる（独立判定）（§3.4） |
| 確定 | popup_root の遅延 attach は (a) 静的エッジ＝専用 facet で popup_root を論理子公開（automation 木は不変）。(b) show 時遅延適用は不採用（§3.7） |
| 確定 | standalone `PopupMenu` は静的ツリーに無いので `applyLook(&pm.popup_root, table)` を個別適用（§3.7.2） |
| 確定 | relayout は `doLayout` 直呼びせず、全 container の `invalidateSizeCache` ＋ root の `markLayoutDirty` で次 redraw に委ねる（§3.5） |
| 確定 | 適用は init 時・最初の描画前に 1 回。未接続ツリーに呼んでも安全（§3.6） |
| 確定 | 部分 LAF＝表に無い widget は FlatLaf 据え置き。all-or-nothing にしない（§4） |
| 確定 | 純ロジックテストは **GPU 非ゲート**で書く（`newApp` の `Device.init` skip を踏まない）。raw `create`／スタブフォントで木を組む（§5.0） |
| 確定 | FlatLaf identity 表でゼロピクセル不変を回帰ガードに。フェイク LAF は **MenuBar＋Menu＋MenuItem を必ず含め** popup 中身の remap 到達を assert（§5） |
| 確定 | ctx は静的 `const`（既定）／実行時構築なら Application 所有。`applyLook` は ctx を不透明に配るだけで所有しない（§6） |
| 未決 | 命名（含 detached root facet）／`measureMinSize`×`size_query` 統合／`setMinSize` 衝突／重ねがけ・再適用／PopupMenu 個別適用の呼び手（§7） |
