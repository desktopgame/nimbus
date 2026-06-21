# 列を意識した最小グリッドレイアウト 設計 spec

framework に **「列を意識したグリッド」レイアウトマネージャ**を最小サブセットから足す **設計 spec**。
実需は **非均等の 2 列フォーム**（ラベル列は自然幅・入力列は伸びる、の整列）。実装はしない（コードは書かない＝Codex 担当）。
`laf_metal_text.md` / `filechooser_swing.md` の流儀に倣い **「確定」と「未決」を分ける**。確定は pm 調査で固まった前提、未決は作者判断が要る点（特に §6 命名）。

到達点は GridBagLayout 相当（CLAUDE.md「目指すゴール」）だが、最初の一歩はこの最小版＝backlog
[framework_backlog.md](framework_backlog.md) #29 案A。均等セルの Swing 流 GridLayout（全セル同サイズ）は nimbus に実需が無いため **作らない**（#29「何」）。

関連: [framework_backlog.md](framework_backlog.md) #29（フォーム整列・案A 推奨）／#30（LAF×min_size footgun ＝この hack が踏んだ罠）、
[layout-design.md](layout-design.md)（レイアウトエンジン設計方針・1-pass clamp・hint 所有モデル）、
`framework/doc/layout.md`（`LayoutManager.VTable` 契約・キャッシュ・カスタム実装テンプレ）、
`framework/src/LayoutManager.zig` / `BoxLayout.zig` / `Component.zig`（`grow_x` / `align_x` / `min_size_explicit`）、`framework/src/laf.zig`（`applyLook` 再測定）。

---

## 0. 大前提とスコープ（確定・再議論しない）

pm 調査で確定済み（本タスクで指示済み）:

- **実需は非均等の 2 列フォーム**。同じ整列ハックが 3 箇所で独立に再実装されている（§1.1）。
  作るのは 1 本＝「列を意識したグリッド」を **最小サブセット**から。
- **均等セルのプレーン GridLayout は作らない**（Swing `GridLayout` ＝全セル同サイズの実需が nimbus にほぼ無い）。
- **フル GridBagLayout も今は作らない**（セル結合・weight・anchor・fill は additive な後追い＝§7）。
- **列幅はレイアウト時に算出する**。各 widget の `min_size` には焼き込まない（＝LAF 非依存・#30 の罠を踏まない＝§2.3）。
- **既存の制約フィールドを再利用する**。新規に要るのは「どの列に入るか＋列幅のレイアウト時算出」だけで、
  伸張は `grow_x` / `grow_y`、寄せは `align_x` / `align_y`（`start` / `center` / `end` / `stretch`）を使う（§3）。

スコープ外（確定・v1 に入れない）:

- セル結合（スパン）・明示セル指定・列／行ごとの明示 weight（→ §7 で継ぎ目だけ明記）。
- 行の縦方向 grow 分配（行高は行内自然高の最大に固定。§4.3）。
- 均等列モード（全列同幅）。実需が無い。

---

## 1. 既存構造の調査結果（重要・確定事実・行番号引用）

### 1.1 同一の整列ハックが 3 箇所で重複（撤去対象）

いずれも **ラベルの `min_size.width` を手で最大自然幅 or マジックナンバーへ合わせて**列をそろえている。
本 spec のレイアウトはこれらを 1 機構へ畳む。

1. **`framework/src/FileChooser.zig:730-736`** — 2 ラベルの自然幅を `@max` で取り、両方に `setMinSize` で焼く:
   ```zig
   const south_label_width = @max(file_name_label.component.min_size.width, files_type_label.component.min_size.width);
   file_name_label.component.setMinSize(.{ .width = south_label_width, .height = file_name_label.component.min_size.height });
   files_type_label.component.setMinSize(.{ .width = south_label_width, .height = files_type_label.component.min_size.height });
   ```
   south は縦 `BoxLayout.verticalSpaced(8)`、各行が横 `BoxLayout.horizontalSpaced(8)`（`FileChooser.zig:721-757`）。
   入力側は `filename_field.component.setGrowX(1)`（:732）/ `filter_combo.component.setGrowX(1)`（:738）で既に伸びる。

2. **`examples/widget_keyboard/main.zig:110-120`** の `labeledRow` — 幅 110 ベタ書き:
   ```zig
   l.component.setMinSize(.{ .width = 110, .height = l.component.getMinSize().height });
   ```
   行は横 `BoxLayout.horizontal()`、ラベル `setAlignY(.center)`、入力 `setAlignY(.center)`（:112-118）。

3. **`examples/widget_showcase/main.zig:86-101`** の `addFormRow` — 幅 100 を `setMinSize` ＋ `setMaxSize` 両方で固定:
   ```zig
   label.component.setMinSize(.{ .width = 100, .height = label.component.getMinSize().height });
   label.component.setMaxSize(.{ .width = 100, .height = std.math.inf(f32) });
   ```
   行は横 `BoxLayout.horizontalSpaced(8)`、入力 `setGrowX(1)` ＋ `setAlignY(.center)`（:88-96）。

共通項: いずれも **マジックナンバー直書き**（自然幅 `@max` / 110 / 100）で、`@max` 版（FileChooser）以外は当て推量。
FileChooser はさらに #30 の footgun を踏み、`min_size` 直書き → `setMinSize` 経由（`min_size_explicit`）へ直す修正を経ている（81cd075）。

### 1.2 再利用する Component の制約フィールド（`Component.zig`）

```zig
pub const Alignment = enum { start, center, end, stretch }; // :34

min_size: Size,              // :203
min_size_explicit: bool,     // :204  setMinSize 経由なら true、直書き / 派生は false
max_size: Size,              // :205
grow_x: f32,                 // :206  既定 0
grow_y: f32,                 // :207  既定 0
align_x: Alignment,          // :208  既定 .stretch
align_y: Alignment,          // :209  既定 .stretch
```

セル幅の測定に使う query（`Component.zig`）:

- `effectiveMinSize()`（:377）— leaf は `min_size`、コンテナーは layout 由来の最小と合成。
  **レイアウトはこれを読むべき**（`min_size` 直読みより推奨。BoxLayout も :123 / :184 でこれを使う）。
- `effectiveMaxSize()`（:386）— max 版。
- 純粋関数（observable state を書き換えない）なので `computeMinSize` のキャッシュ規約（`layout.md`「キャッシュ」）と整合する。

### 1.3 `LayoutManager.VTable` 契約（`LayoutManager.zig:9-19`）

```zig
pub const VTable = struct {
    doLayout:       *const fn (*LayoutManager, *Container) void,
    computeMinSize: *const fn (*LayoutManager, *const Container) Component.Size,
    computeMaxSize: *const fn (*LayoutManager, *const Container) Component.Size,
    deinit:         ?*const fn (*LayoutManager, std.mem.Allocator) void = null,
};
```

`doLayout` は **直接の子のみ** bounds を設定し、孫以下の再帰はしない（`layout-design.md`「再帰はコンテナーが行う」）。
`computeMinSize` / `computeMaxSize` は **純粋関数**（`*const Container`、Container 側で memoize）。
`deinit` はインスタンスを確保する LayoutManager のみ実装（const シングルトンは null）。前例: ギャップ付き `BoxLayout`（`BoxLayout.zig:72-75`）/ `PaddingLayout` / FileChooser 私有 `CardLayout`。

### 1.4 #30 footgun の所在（`laf.zig:28-30`）

```zig
if (node.container == null and node.tree_children == null and !node.min_size_explicit) {
    node.min_size = node.ui.vtable.measureMinSize(node, node.ui.ctx);
}
```

LAF 再適用（`applyLook`）が **非明示（`!min_size_explicit`）な leaf の `min_size` を再測定で上書き**する。
列幅を leaf の `min_size` に焼くと、後から LAF を当て直したとき黙って消える。これが §1.1 の hack が踏んだ罠の正体。

---

## 2. 最小グリッドの仕様（確定）

### 2.1 構成と流し込み

- **固定 N 列**。列数は生成時に決める（`create(allocator, n_cols, ...)`）。
- **行メジャー（row-major）**で `add` 順にセルへ流し込む。`i` 番目の子は `col = i % N`、`row = i / N`。
- 行数は `n_rows = ceil(children.len / N)`。最終行が埋まらない（ragged）場合、欠けたセルは**無いものとして扱う**
  （その列幅・行高の算出からスキップ。§4）。

### 2.2 v1 では per-component の新規状態を増やさない（確定）

固定 N 列 ＋ 行メジャー ＋ `add` 順という規約だけで、各セルの (row, col) は **追加インデックスから導出できる**。
したがって **per-component の新フィールドも `LayoutHint.hint` も v1 では不要**（VTable vs capability の原則：高コストを全 Component に乗せない＝[[feedback_vtable_vs_capability_cost]]）。
明示セル指定・スパン・列 weight が要るようになったら、その時に初めて `hint` 経由で足す（§7）。`hint` の座席は既に存在する（`layout-design.md`「レイアウトヒント」/ `layout.md`「動的アロケートした hint」）ので、v1 を hint 無しで作っても継ぎ目は塞がらない。

### 2.3 列幅はレイアウト時に算出する（確定・#30 根治）

各列の幅 = **その列に属するセルの自然幅（`effectiveMinSize().width`）の最大**を、`doLayout` のたびに算出する。
**どのセルの `min_size` にも焼き込まない**。

これにより §1.4 の `applyLook` 再測定分岐（`!min_size_explicit` の leaf を上書き）が **触れる先が無くなる**。
列の整列は毎レイアウトパスで自然幅から再構成されるため、**LAF を後から当て直しても崩れない**。
§1.1 の `min_size` 直書きハック（#30 の温床）を、フォーム整列という実需に対して構造的に潰す。

> 補足: グリッドのセル自身は `min_size_explicit=false` のまま（grid は `setMinSize` を呼ばない）。
> よって LAF 再測定は従来どおりセルの**自然幅**を更新でき、その更新が次のレイアウトで列幅へそのまま反映される（むしろ望ましい連動）。

---

## 3. 伸張・寄せは既存フィールドを再利用する（確定・レシピ）

新しい制約概念は足さない。`grow_x` / `grow_y` と `align_x` / `align_y` を二段（列レベル／セルレベル）で読む。

### 3.1 列が伸びるか ＝ `grow_x`（列レベル）

- **列の grow 重み** = その列のセルの `grow_x` の最大。
- コンテナー幅から全列の自然幅合計＋列間ギャップを引いた余白を、**列 grow 重みの比で各列へ分配**する（1-pass clamp。`layout-design.md`「子の分配アルゴリズム」と同じ思想）。
- 2 列フォームでは、入力列セルに `grow_x = 1` を立てれば**入力列だけが伸び**、ラベル列（`grow_x = 0`）は自然幅のまま。
  → §1.1 の `setGrowX(1)`（FileChooser / showcase の入力側）がそのまま意味を持つ。

### 3.2 セルが列内でどう収まるか ＝ `align_x` / `align_y`（セルレベル）

セルの矩形は「自分の列幅 × 自分の行高」のセル枠の中で、`align` に従って配置する。

- `align_x = .stretch`（既定）→ セルは**列幅いっぱい**に広がる（入力欄を列幅まで伸ばす典型）。
- `align_x = .start` / `.center` / `.end` → セルは**自然幅**のまま、列枠内で左／中央／右に置く。
- `align_y` も同様に行高に対して効く。ラベルを**縦中央**にそろえるのは `align_y = .center`
  （§1.1 の `setAlignY(.center)` がそのまま効く）。
- `max_size` でクランプ（`align_x = .stretch` でも列幅が `max_size.width` を超えたらそこで止め、`align_x` 既定の中央寄せで余白配置）。BoxLayout の cross 軸クランプ（`BoxLayout.zig:148-162`）と同じ作法。

### 3.3 2 列フォームの最小レシピ（確定・移行先の形）

```zig
const grid = try GridLayout.create(a, 2, .{ .col_spacing = 8, .row_spacing = 8 }); // 命名は §6 未決
form.setLayout(grid);

// row 0: ラベル（自然幅・縦中央）＋ 入力（列いっぱいに伸びる）
const name_label = try app.label("File Name:");
name_label.component.setAlignY(.center);          // grow_x=0 のまま → 列は自然幅
try form.add(&name_label.component);
filename_field.component.setGrowX(1);             // 入力列が伸びる
try form.add(&filename_field.component);          // align_x=.stretch 既定 → 列幅いっぱい

// row 1: 同じ列構成
const type_label = try app.label("Files of Type:");
type_label.component.setAlignY(.center);
try form.add(&type_label.component);
filter_combo.component.setGrowX(1);
try form.add(&filter_combo.component);
```

ラベル列の幅は `"File Name:"` と `"Files of Type:"` の自然幅の最大が**レイアウト時に**選ばれ、両行のラベルがそろう。
`setMinSize` も `@max` の手計算もマジックナンバーも要らない。

### 3.4 親 BoxLayout との整合（確定・落とし穴）

フォームの grid コンテナーは典型的に縦 `BoxLayout`（FileChooser の south など）の子になる。
BoxLayout の cross 軸 stretch は **子の `effectiveMaxSize()` でクランプする**（`BoxLayout.zig:148-155`）。
したがって grid が横方向に親幅まで広がるには、**grid の `computeMaxSize().width` が十分大きい（伸びる列があれば `inf`）必要がある**。
これを満たさないと「grid 自体が自然幅で止まり、入力列が伸びない」。§4.4 でこの max 方針を確定させる。

---

## 4. doLayout / computeMinSize / computeMaxSize（確定・レシピ）

`LayoutManager` を embed する標準形（`layout.md`「カスタム LayoutManager の実装テンプレ」）。
列幅・行高はすべて `effectiveMinSize()` から **その場で**算出し、状態に保存しない（純粋性＝キャッシュ整合）。

### 4.1 列幅の算出（`doLayout` / `computeMinSize` 共通の前段）

```
n_cols = self.n_cols                       // 生成時固定
n_rows = ceil(len(children) / n_cols)
for c in 0..n_cols:
    col_natural[c] = max over rows r of cell(r,c).effectiveMinSize().width   // 欠けセルはスキップ、無ければ 0
    col_grow[c]    = max over rows r of cell(r,c).grow_x                      // 欠けセルはスキップ、無ければ 0
natural_total = sum(col_natural) + col_spacing * (n_cols - 1)
```

### 4.2 列幅への余白分配（`doLayout` のみ）

```
avail   = container.component.size.width
excess  = avail - natural_total
dist    = max(0, excess)
sum_grow = sum(col_grow)
for c in 0..n_cols:
    col_width[c] = col_natural[c] + (sum_grow > 0 ? dist * col_grow[c] / sum_grow : 0)
```

1-pass clamp（再分配しない）。`layout-design.md`「子の分配アルゴリズム」と同方針。

### 4.3 行高の算出（`doLayout` / `computeMinSize` 共通）

```
for r in 0..n_rows:
    row_height[r] = max over cols c of cell(r,c).effectiveMinSize().height    // 欠けセルはスキップ
```

v1 では **行の縦 grow 分配はしない**（行高 = 行内自然高の最大に固定）。フォームの実需に十分。
縦 grow（行を縦に伸ばす）は additive（§7）。`align_y` による行内の縦寄せは行高に対して効く（§3.2）。

### 4.4 各セル矩形の決定（`doLayout`）

```
y = 0
for r in 0..n_rows:
    x = 0
    for c in 0..n_cols:
        cell = cell(r,c) or skip
        cmin = cell.effectiveMinSize(); cmax = cell.effectiveMaxSize()
        // 幅: stretch は列幅、その他は自然幅。max でクランプ。
        w = (cell.align_x == .stretch) ? col_width[c] : cmin.width
        w = clamp(w, cmin.width, cmax.width)
        off_x = align offset of w within col_width[c] by cell.align_x   // start=0 / center=(col-w)/2 / end=col-w
        // 高さ: align_y を row_height[r] に対して同様に
        h = (cell.align_y == .stretch) ? row_height[r] : cmin.height
        h = clamp(h, cmin.height, cmax.height)
        off_y = align offset of h within row_height[r] by cell.align_y
        cell.setBounds(.{ .x = x + off_x, .y = y + off_y, .width = w, .height = h })
        x += col_width[c] + col_spacing
    y += row_height[r] + row_spacing
```

`setBounds` のみ（孫再帰は Container が行う＝`layout-design.md`）。
`Container.setBounds` は doLayout を呼ばない現行契約（`layout-design.md`「setBounds と doLayout は分離する」）と整合。

### 4.5 `computeMinSize`（純粋）

```
width  = sum(col_natural) + col_spacing * (n_cols - 1)
height = sum(row_height)   + row_spacing * (n_rows - 1)
return { width, height }
```

`effectiveMinSize()` のみ読み、状態を書き換えないので memoize と整合（`layout.md`「キャッシュ」）。

### 4.6 `computeMaxSize`（純粋・§3.4 を満たす方針＝確定）

- **width**: `sum_grow > 0`（伸びる列が 1 つでもある）なら `inf(f32)`、無ければ `computeMinSize().width`。
  → §3.4 の「親 BoxLayout の cross stretch クランプ」を通すために必要。フォームは入力列が伸びるので通常 `inf`。
- **height**: `computeMinSize().height`（v1 は行を縦に伸ばさないので最小＝最大）。

> 注: これは「列の伸縮性をコンテナーの伸縮性へ素直に伝播させる」最小方針。
> 列ごとの max を厳密合算する案もあるが、フォーム実需では過剰なので採らない（未決として残すほどでもない＝この方針で確定）。

---

## 5. 所有・解放（確定）

- `GridLayout` は `n_cols` ＋ spacing を保持するため **const シングルトンにできない**（列数がインスタンスごとに違う）。
  → **allocator 所有**。`create` で `allocator.create(GridLayout)` し、`deinit` で `allocator.destroy` する。
  前例: ギャップ付き `BoxLayout`（`BoxLayout.zig:62-75` の `spaced_vtable` ＋ `deinit`）。
- 寿命は差した `Container` が肩代わりする（`layout.md`「LayoutManager の所有」）。
  `setLayout` の差し替え時と `Container` 破棄時に Container が `deinit` を呼ぶ。利用者は直接呼ばない。
- `deinit` を持つインスタンスは **1 つの Container が専有**（共有すると二重解放）。シングルトンではないので共有しない。
- VTable は **2 種を用意しない**（BoxLayout の singleton/spaced 二本立てとは違う）。GridLayout は常にインスタンス確保なので
  `deinit` 付き VTable 1 種でよい。

---

## 6. 命名（未決・要議論・作者判断）

Swing の `GridLayout` は **均等セル**なので、非均等列グリッドに同名を当てると Swing 利用者に紛らわしい。
一方 nimbus は均等 GridLayout を作らない（§0）ので **nimbus の名前空間では `GridLayout` は空いている**。到達点は GridBag（真のグリッド）でグリッド族ではある。

| 案 | 名前 | 利 | 不利 |
|---|---|---|---|
| 案ア | `GridLayout` | backlog #29 案A の呼称そのまま。グリッド族で GridBag への素直な前身。名前空間は空き | Swing の均等 GridLayout と意味がずれ、Swing 経験者が「均等セル」を期待する |
| 案イ | `FormLayout` | 実需（フォーム整列）に即した名。意図が明確 | JGoodies `FormLayout` は高機能な別物で、これも別方向の誤解。グリッド族の将来像と名がずれる |
| 案ウ | `GridFormLayout` | グリッド由来 ＋ フォーム用途を併記 | 長い。GridBag へ育てたとき「Form」が足枷の名に見える |

- **推奨: 案ア `GridLayout`**（最終判断は作者）。理由: ①均等 GridLayout を作らない以上、名前衝突は概念のみで実体は無い ②到達点 GridBag と同じグリッド族で命名系列が一貫 ③backlog #29 案A の呼称と一致。doc に「nimbus の `GridLayout` は **非均等列**（列幅 = 列内自然幅の最大）であり Swing の均等 GridLayout とは別物」と一文明記して誤解を閉じる。
- **app 側の利便 API（`app.gridLayout` 等）は足さない（推奨・未決）**。現行の組み込みレイアウトは **app ファクトリを通さず自由関数**で出している（`nimbus.BoxLayout.horizontal()` / `BoxLayout.horizontalSpaced(allocator, 8)`、`Application` に `boxLayout` は無い）。GridLayout もこれに合わせ `GridLayout.create(allocator, n_cols, opts)` の自由関数 1 本にするのが一貫する。レイアウトは theme 注入も不要（ファクトリの存在理由が無い）。`app.gridLayout` を足すと BoxLayout と非対称になるだけ。
  - 二段階破棄を避ける派生として `GridLayout.twoColumnForm(allocator, opts)`（`n_cols = 2` 固定の薄いラッパ）を足すかは **未決**。実需は 2 列だが、point-of-need では `create(a, 2, ...)` で足りる。先回りしない方針（[[feedback_lightweight_workflows]]）に倣い v1 では足さない推奨。

---

## 7. additive 拡張点（未決でよい・継ぎ目だけ明記）

いずれも **v1 には入れない**。後付けの座席が既にどこにあるかだけを記す（GridBag への道）。

- **スパン（セル結合）/ 明示セル指定**: `LayoutHint.hint` 経由で `GridConstraints{ col, row, col_span, row_span }` 風の制約を渡す。
  座席は既存（`layout-design.md`「レイアウトヒント」、`layout.md:117-128` の `hint` ＋ `hint_destroy` 動的アロケート例、`layout.md:161-176` の独自 hint 取り出し例）。
  v1 は hint を読まず行メジャー自動流し込み（§2.2）。additive 版は「hint があれば明示配置、無ければ自動」の二段にする。
  Container 側は無改修（hint の座席は既にある）。
- **列／行ごとの明示 weight**: §3.1 は「列 weight = 列内 `grow_x` の最大」で導出するが、セルと無関係に列へ直接 weight を与えたい需要が出たら、
  `GridLayout` に `col_weights: []const f32`（生成時オプション）を足すか、`GridConstraints.weight` を hint に積む。
  方向性は GridBag の `weightx` / `weighty`（`layout-design.md:49` / `layout.md:121-128` の `GridBagConstraints` 風 hint）。
- **行の縦 grow 分配**: §4.3 を「行 grow 重み = 行内 `grow_y` の最大」で列と対称に拡張すれば入る。v1 は行高固定。
- **均等列モード**: 全列を最大列幅にそろえる Swing 風 GridLayout 互換が要れば、列幅算出（§4.1）を「全列 = 全セル自然幅の最大」に切替えるフラグで足せる。実需が出るまで作らない。

これらはすべて §2/§4 のコアを壊さず重ねられる（自動流し込みは hint 不在時の既定として残る）。

---

## 8. テスト計画

CLAUDE.md / `doc/internal/test.md` 規律 ＝ **Application / GPU 非依存**・**手組み `Component.init` で常時実行**・GPU ゲート下に隠さない。
列幅算出・セル配置・伸張分配は **純レイアウト計算**として `GridLayout.zig` の test ブロックに置く（`BoxLayout.zig:219-242` の手組み Container ＋ `setMinSize` ＋ `doLayout` ＋ bounds アサートの作法に倣う）。

純ロジック（GPU 非依存・必須）:

1. **列幅 = 列内自然幅の最大**: 2 行 ×2 列で col0 のラベル幅が行ごとに違うとき、両行の col0 セルが**広いほうの幅**で左端そろい。
2. **2 列フォームの伸張**: col1 セルに `grow_x = 1`、コンテナー幅を自然幅合計より広くしたとき、col0 は自然幅・col1 が余白を全部食う。col0 セルの幅・x が不変。
3. **複数伸張列の比例分配**: col1 `grow_x=1` / col2 `grow_x=3` のとき余白が 1:3 で配分。
4. **行高 = 行内自然高の最大** ＋ `align_y=.center`: 低いラベルが高い入力に対し縦中央へ。
5. **align_x の列内配置**: `.start` / `.center` / `.end` でセルが列枠内の正しい x に、`.stretch` で列幅いっぱいに。
6. **`computeMinSize`**: `sum(col_natural)+col_gaps` × `sum(row_height)+row_gaps` に一致。
7. **ragged 最終行**: 子が N の倍数でないとき、欠けセルが列幅・行高の算出から除外され、既存列の整列が保たれる。
8. **LAF 非依存（#30 回帰）**: グリッドのセルに `setMinSize` を**一切呼ばず**列がそろうこと（＝ `min_size` に焼いていない）を、セルの `min_size_explicit == false` のまま整列が成立することで確認。可能なら `applyLook` 相当の再測定（セル自然幅の更新）後も列幅が追従することまで。
9. **所有**: `GridLayout.create` → `Container.setLayout` 差し替え／Container 破棄で `deinit` が走り、`std.testing.allocator` でリークしない。

Robot / smoke（最小）:

- 移行後のフォーム（FileChooser south など）が **落ちない** ことを既存 Robot 経路で確認。
- **ゴールデンは広げない**（snapshot scene を新規追加しない）。整列の正しさは上記 1〜7 の純ロジックが担保する。

---

## 9. 移行計画（継ぎ目を分けて提案）

framework への追加と consumer の移行を **別委譲（別段）**にする。本ブランチ `feat/grid-layout` では §10 の doc までで、実装は Codex が同ブランチで継ぐ。

### Phase 1（framework・先行）

- `GridLayout`（新モジュール）＋ §8 の純ロジックテストを追加し緑。
- spec / narrative の doc 追従（§10）。consumer は**まだ触らない**。
- 完了基準: `zig build test` 緑、`min_size` 直書きハックに依存しない列整列が純ロジックで実証される。

### Phase 2（consumer 移行・後続）

§1.1 の 3 箇所を `GridLayout` へ書き換え、`setMinSize` ハックとマジックナンバー（自然幅 `@max` / 110 / 100）を撤去する。

- **`FileChooser.zig:730-736,754-756`**: south の row1 / row2（フォーム 2 行）を **1 個の 2 列 grid コンテナー**へ置換。
  `south_label_width` の `@max` 計算と両ラベルの `setMinSize`（:734-736）を削除。ラベルは `setAlignY(.center)`、入力は既存の `setGrowX(1)` のまま。
  row3（OK / Cancel・右寄せ glue）は **フォームではない**ので grid に含めず、現状の横 `BoxLayout` ＋ glue を維持。
- **`widget_keyboard/main.zig:110-120`** `labeledRow` / **`widget_showcase/main.zig:86-101`** `addFormRow`:
  各行を独立した横 box で組む現方式をやめ、フォーム全体を **1 個の 2 列 grid** にして全ラベル・全入力をそのまま `add` する。
  幅 110 / 100 の `setMinSize`・showcase の `setMaxSize` を撤去。

### 重複ヘルパの統合可否（明記）

- `labeledRow`（widget_keyboard）と `addFormRow`（widget_showcase）は **同型**で、grid 化すると「行ヘルパ」自体が不要になる（grid コンテナーへセルを順に `add` するだけ）。よって **ヘルパを 1 本に統合する以前に、ヘルパが消える**のが本筋。
- ただし framework（FileChooser）と examples で **共有ヘルパ関数は作れない**（framework → examples の import は禁じ手・`filechooser_swing.md` §5 と同じ制約）。
  共通化の実体は **`GridLayout` という機構そのもの**であり、関数ヘルパの共有ではない。各 consumer は `GridLayout.create(a, 2, ...)` を直接呼ぶ。

---

## 10. 公開署名の変更列挙（作者承認事項）

framework の公開表面に増えるもの（v1）:

- **新モジュール `framework/src/GridLayout.zig`**（`LayoutManager` を embed）。`root.zig` から export。
  - `GridLayout.Options = struct { col_spacing: f32 = 0, row_spacing: f32 = 0 }`
  - `pub fn create(allocator: std.mem.Allocator, n_cols: usize, opts: Options) !*LayoutManager`
  - `deinit` 付き VTable 1 種（`create` 内部で接続。公開関数ではない）。
- **新 spec `framework/doc/grid_layout.md`** ＋ **narrative `framework/doc/narrative/grid_layout.md`**（命名の線引き・#30 根治の理由・GridBag への additive 方針）。
  `framework/doc/layout.md`「機能要望」の「組み込み GridBagLayout 相当」へ「最小 GridLayout は実装済み・GridBag は additive」の追従を入れる。
- **`Component.Role`** に grid 用の値は **足さない**（レイアウトは Role を持たない。Table 等ウィジェットとは別）。

**足さないもの（明示）**:

- per-component の新フィールド（§2.2）— **増やさない**。
- `LayoutHint` / `Container` の改修 — **無し**（hint の座席は既存。v1 は読まない）。
- 新 theme トークン — **無し**（レイアウトは色を持たない）。
- `Application` ファクトリ（`app.gridLayout`）— **足さない推奨**（§6。BoxLayout と同じく自由関数で出す）。

未確定で作者判断が要るもの（→ §11）:

- 命名（`GridLayout` / `FormLayout` / `GridFormLayout`）と doc の線引き文言（§6）。
- `GridLayout.twoColumnForm` の薄いラッパを足すか（§6 末尾。推奨は v1 で足さない）。

---

## 11. 決めること（未決まとめ）

| # | 項目 | 推奨 | 参照 |
|---|---|---|---|
| 1 | 名前（`GridLayout` / `FormLayout` / `GridFormLayout`） | 案ア `GridLayout` ＋ 「非均等列」明記の一文 | §6 |
| 2 | `app.gridLayout` ファクトリを足すか | 足さない（自由関数 `GridLayout.create` のみ。BoxLayout に揃える） | §6 |
| 3 | `twoColumnForm` 薄ラッパを足すか | v1 では足さない（point-of-need） | §6 |
| 4 | `Options` のフィールド名（`col_spacing` / `row_spacing`） | この名で確定でよいか（BoxLayout は `spacing` 一本だが grid は 2 軸） | §10 |

これら以外（列幅 = 列内自然幅の最大・行メジャー自動流し込み・per-component 新状態なし・`grow_x`/`align` 再利用・`computeMaxSize` の `inf` 方針・所有＝allocator）は **確定**。最終判断は作者。
