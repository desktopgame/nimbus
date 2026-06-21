# FileChooser Swing 風レイアウト再構築 設計 spec

`framework/src/FileChooser.zig` のダイアログを **Swing `JFileChooser` 風**へ作り直す **設計 spec**。
参照画像 `tmp/filechooser-example.png`（古典的 Swing JFileChooser: 上に「Look In:」コンボ＋ツールバー、中央にファイル一覧、
下に「File Name:」「Files of Type:」の 2 行ラベル付き入力＋右下に OK/Cancel）に寄せる。
実装はしない（コードは書かない＝Codex 担当）。`laf_design.md` / 各 `laf_metal_*.md` の流儀に倣い **「確定」と「未決」を分ける**。

これは v1 設計ノート [file_chooser_design.md](file_chooser_design.md) の **後継**にあたる。
v1 が「将来拡張として構造だけ見据える」とした **details / Table ビュー**（[file_chooser_design.md](file_chooser_design.md) §決定 3 末尾・§v1 で欲張らないもの）を
本 spec で実装に昇格し、合わせて上部レイアウトを Swing 風（Look In コンボ＋ツールバー）へ差し替える。
spec `framework/doc/filechooser.md` の公開 API 本体（mode / show / getSelectedPath / addFilter）は **変えない**＝ダイアログの中身（レイアウトと view 層）だけを作り直す。

関連: [file_chooser_design.md](file_chooser_design.md)（`DirSource` seam・`ChooserCore` のロジック層分離・cardHolder 差し替え点・所有/解放表・テスト方針＝**本 spec の前提土台**）、
`examples/app_filer/main.zig`（実証済みの List/Details 切替・`ViewMode`・Table セル・folders-first sort・`CardLayout`＝**形の参照元**。ただし framework → examples の import は禁じ手・§5）、
[laf_metal_container.md](laf_metal_container.md) / [laf_metal_text.md](laf_metal_text.md)（単一真実源・Part C 教訓・確定/未決の分離・テスト計画の作法）。

---

## 0. 大前提とスコープ（確定・再議論しない）

作者確定（本タスクで指示済み）:

- **上部**: `Up` ボタンを削除し、`path_field`（TextField）を **「Look In:」ComboBox**（現在地の祖先チェーンを列挙する階層コンボ）へ置換。
  コンボは **非編集で確定**（Swing 同様、選ぶだけ。任意パスのタイプ移動・`onPathSubmit` は **廃止**）。現状 `ComboBox` は editable 非対応なので非編集前提でよい（§1.4）。
- **ツールバー**: コンボの右に 4 ボタン `上へ`（`onUp` 再利用）/ `ホーム`（places の home へ移動）/ `詳細` / `リスト`（ビュー切替）。
- **下部**: south を縦 2 行＋ラベルに。1 行目 `File Name:` ＋ `filename_field`、2 行目 `Files of Type:` ＋ `filter_combo`。
  その下にもう 1 行 `OK` / `Cancel` を **右寄せ**（glue で右詰め）。
- **詳細ビュー**: `app_filer` の Table を **フル移植**（Name / Size / Modified 列・ソート可ヘッダ）。リスト＝現状の単列 `List`、詳細＝`Table`。
  `詳細` / `リスト` ボタンで切替。
- **core ロジックは不変**: `ChooserCore`・places・filters・`loadDir`/`cd`/`up`/`selectPlace` はそのまま再利用（§7）。**レイアウトと view 層だけ**変える。
- **公開 API 不変**: `Mode`・`showOpenDialog`/`showSaveDialog`/`showDialog`・`getSelectedPath`/`getCurrentDirectory`・`addFilter`・`setSelectedFileName`・`setCurrentDirectory` のシグネチャは変えない。

スコープ外（確定）:

- **複数選択は入れない**（FileChooser は単一選択のまま・`ChooserCore.selected` は 1 本・`FileChooser.zig:167-168`）。
  app_filer は `setSelectionMode(.multiple)`（`app_filer:1693,1715`）だが、FileChooser の List/Table は **single 選択**で揃える。
- **rename / DnD / 新規フォルダ / コンテキストメニュー / 検索は入れない**（app_filer の機能。FileChooser は選ぶだけ）。
  → Table セルの `CellEdit`（rename）・`drag_source`/`drop_target`・popup は **移植しない**（§5.2）。
- LAF（Metal 化）は別レイヤー。本 spec は FlatLaf 既定のレイアウト/view 構成のみ扱う。

---

## 1. 既存構造の調査結果（重要・確定事実・行番号引用）

### 1.1 現状レイアウト（`FileChooser.buildUi`・`FileChooser.zig:523-583`）

```
root = dialog.window.container, PaddingLayout(all 8)        (:526-527)
 body: BorderLayout                                         (:529-531)
  north: BoxLayout.horizontalSpaced(8)                      (:533-534)
     [ up_button "Up" ]  [ path_field TextField, growX ]    (:535-541)   ← 廃止対象
  center: PaddingLayout(top8,bottom8) > SplitPane.horizontal(:556-566)
     first : ScrollPane( places_list List ), min_w 180      (:544-549)
     second: card_holder(BorderLayout) > ScrollPane(files_list List) (:550-558)
  south: BoxLayout.horizontalSpaced(8)                      (:568-569)
     [ filename_field TextField, growX ][ filter_combo ][ OK ][ Cancel ]  (:570-582)
```

注目点（確定事実）:

- **`card_holder` は既に存在**（`:556-558`）。現状は `BorderLayout.center` に `files_sp` 1 枚だけ（[file_chooser_design.md](file_chooser_design.md) §details ビューの差し替え点の通り）。
  ここを **`CardLayout` 化して List/Table を 2 枚差し替える**のが詳細ビューの注入点（§6）。骨格は壊さない。
- `places_list` のサイドバー（`:544-549`）・SplitPane（`:560-562`・`setDividerLocation(180)`/`setResizeWeight(0)`）は **不変**。
- north / south だけを作り直す。center の SplitPane 構造は維持（card_holder の中身だけ変わる）。

### 1.2 廃止する配線（確定・行番号）

- `up_button`（field・`:406`／生成 `:535`／`onUp` 配線 `:538`）: **ボタン自体は削除**するが **`onUp` の本体（`:650-655`）は残してツールバー『上へ』に再利用**。
- `path_field`（field・`:401`／生成 `:536-537`／`onPathSubmit` 配線 `:539`）: **削除**。
- `onPathSubmit`（`:657-659`）: **削除**（任意パスのタイプ移動を廃止＝Swing は非編集コンボ）。
- `syncFieldsFromCore`（`:613-616`）が `path_field.setText`（`:614`）を呼んでいる: **Look In コンボの再構築呼び出しへ差し替え**（§3.4）。
  `filename_field.setText`（`:615`）の側は残す。

### 1.3 `ChooserCore`＝ロジック層（不変・再利用・`FileChooser.zig:157-388`）

[file_chooser_design.md](file_chooser_design.md) §テスト計画の通り、FS ロジックは `ChooserCore` に分離済みで **GPU/Application 非依存**。本 spec で **一切変更しない**:

- ナビゲーション: `loadDir`（`:227-253`）/ `cd`（`:255-259`）/ `up`（`:261-265`）/ `selectPlace`（`:267-270`）。
- 現在地: `getCurrentDirectory`（`:195-197`＝`cur[0..cur_len]` 借用）。`up` は Windows ドライブルートで `dirname==null`→no-op（`:263`）。
- places: `places`（`:162`）。`Place.kind`（`home`/`root`・`:154`/`PlaceEntry.Kind` `:41`）。home は `osPlaces` が先頭に積む（`:104-115`）。
- filters: `addFilter`/`setFilter`/`applyFilter`（`:204-225`,`:365-369`）・可視投影 `visibleEntryCount`/`visibleEntryAt`（`:294-310`）。
- sort: `entryLess`（`:828-831`＝**folders-first ＋ 名前 ignore-case**）を `sortEntries`（`:361-363`）が `loadDir` 内で適用（`:251`）。
  → **詳細ビューも `ChooserCore` の sort 済み可視リストをそのまま投影する**（再 sort のロジックは core 側に既存。§6.3）。
- 既存テスト（`:1036-1108`・FakeDirSource）は core に対するもので **そのまま緑**（本 spec で core を触らないため）。

### 1.4 `ComboBox`＝非編集・文字列 item のみ（`ComboBox.zig`）

- v1 scope: **string items only / not editable / no custom renderer**（`ComboBox.zig:10-12`）。本 spec の Look In コンボはこの制約内（非編集・文字列）。
- API: `setItems([]const []const u8)`（`:152-169`）/ `setSelectedIndex(usize)`（`:129-135`）/ `getSelectedIndex`（`:125-127`）/ `addChangeListener`（`:182-189`）。`role=.combobox`（`:114`）。
- **footgun（確定・重要）**: `setItems` は末尾で `change_listeners.fire`（`:167`）＝**ChangeListener を発火**し、かつ `selected_index=0` にリセット（`:164`）。
  `setSelectedIndex` も値が変われば `fire`（`:133`）。→ コンボ item を**再構築するだけで onChange が飛ぶ**。
  ナビゲーション起因の再構築（§3.4）で**自己再帰ナビゲーション**を起こさないガードが要る（§3.5）。
- 既存 `filter_combo` も同じ `ComboBox`（生成 `:572`／`onFilterChanged` `:575,682-686`／再構築 `rebuildFilterCombo` `:600-611`）。この配線は **下部 2 行目へ移すだけ**で中身不変。

### 1.5 `app_filer` の詳細(Table)ビュー＝移植元（**私有**・`examples/app_filer/main.zig`）

FileChooser へ移植する「形」。**コードのコピーではなく framework 語彙で再構築**（§5）。app_filer 側で関与する私有要素:

- `ViewMode`（`enum { list, details }`・`:42`）。`view_mode` field（`:166`）。
- view 切替の同期ヘルパ（`:588-648`）: `selectedIndex`（`:590-595`）/ `setActiveSelected`（`:597-602`）/ `focusActiveView`（`:604-609`）/
  `activeFilesComponent`（`:611-616`）/ `activeRowAt`（`:618-623`）が **`switch (view_mode)`** で List/Table に分岐。
  `setViewMode`（`:633-648`）が `carry = selectedIndex()`（`:635`）→ `card.active` 差し替え（`:637-640`）→ `setActiveSelected(carry)`（`:641`＝**選択を切替で持ち越し**）→ view ボタン文言反転（`:642-645`）→ `markLayoutDirty`/`repaint`（`:646-647`）。
- `CardLayout`（私有 `LayoutManager`・`:118-144`）: `active` の子だけ実サイズ、他は 0×0。コメントに **「nimbus に CardLayout は無い。dogfooding finding、backlog 価値あり」**（`:116-117`）。
- Table 構築（`:1707-1722`）: `app.tableWithModel(&model, &.{ Name 300 / Size 90 / Modified 150 })`（`:1708-1712`）・`setSortIndicator(0,.ascending)`（`:1716`）・`addSortListener`（`:1719,892-904`）・`setColumnHeaderView(headerView())`（`:1721`）。
  両 view（List/Table）が **同一 `model`（`List.ListModel`）を共有**（`:1689,1708` コメント「Table over the SAME model」）。
- Table セル（私有・`:1334-1459`）: `NameCell`（icon+名・`:1334-1395`／rename 用 `CellEdit` 付き）/ `TextCell`（size/date・`:1399-1417`）/ `createNameCell`/`createSizeCell`/`createDateCell`。
  整形: `fmtSize`（`:1121-1128`）/ `fmtDate`（`:1130-1144`・`std.time.epoch`）。
- sort: `SortCtx`（`:146`）/ `sortLess`（`:292-306`＝**folders-first ＋ 列キー**）/ `applySort`（`:310-314`）/ `onSort`（`:892-904`）。

### 1.6 `Driver` / role（`Driver.zig`・テスト前提）

- `Driver.clickOn(.{ role, text, name })`（`:39-45`）＝role＋text で意味駆動クリック。`find`（`:20-25`）。
- role は `combobox` / `table` / `list` / `button` / `text_field` / `label` を持つ（`Component.zig:91-117`）＝**Look In コンボ・OK/Cancel・詳細/リスト・filter は role+text で叩ける**。
- 既存スモーク（`FileChooser.zig:1137-1164`）が `initHeadless`＋`Robot`＋`Driver.clickOn(.{ .role=.button, .text="OK" })` で OK 押下を検証済み＝**この形を拡張する**（§10）。

---

## 2. 目標レイアウトとレシピ（確定提案）

### 2.1 全体図（Swing JFileChooser 風）

```
┌─ root: PaddingLayout(all 8) ───────────────────────────────────────────────┐
│ body: BorderLayout                                                          │
│ ┌ north: BoxLayout.horizontalSpaced(8) ───────────────────────────────────┐ │
│ │ [Label "Look In:"] [ look_in_combo  growX ] [Up][Home][Details][List]    │ │  ← §3 / §4
│ └──────────────────────────────────────────────────────────────────────────┘ │
│ ┌ center: PaddingLayout(top8,bottom8) > SplitPane.horizontal (既存・不変) ─┐ │
│ │  first : ScrollPane( places_list )  180px                                │ │
│ │  second: card_holder( CardLayout ) ── list_sp(List) / table_sp(Table)    │ │  ← §6
│ └──────────────────────────────────────────────────────────────────────────┘ │
│ ┌ south: BoxLayout.verticalSpaced(8) ─────────────────────────────────────┐ │
│ │  row1: BoxLayout.horizontalSpaced(8)  [Label "File Name:"]    [ filename_field growX ] │ │  ← §2.3
│ │  row2: BoxLayout.horizontalSpaced(8)  [Label "Files of Type:"][ filter_combo  growX ]  │ │
│ │  row3: BoxLayout.horizontalSpaced(8)  [ glue growX ][ OK ][ Cancel ]                    │ │  ← §2.4
│ └──────────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 north（Look In 行）レシピ

- `north = Container`、`BoxLayout.horizontalSpaced(8)`（既存 `:534` と同）。
- 子の順: `Label "Look In:"` → `look_in_combo`（`ComboBox`・`component.setGrowX(1)`）→ ツールバー子（`Up`/`Home`/`Details`/`List` の 4 `Button`）。
  ツールバーは個別ボタンを north に直接並べてよい（別 Container でまとめても可・どちらでも layout 不変。§11-1 で粒度は実装判断）。
- ボタンはアイコン付きにできる（app_filer は `Up`=`app.icon(.arrow_up)`・`:1808-1810`）。`詳細`/`リスト` は文字で十分（Swing も小アイコンだが文字で可・§12-3）。

### 2.3 south（2 行ラベル付き入力）レシピ

- `south = Container`、`BoxLayout.verticalSpaced(8)`。子は row1 / row2 / row3 の 3 Container。
- row1 / row2 = `BoxLayout.horizontalSpaced(8)`: `[Label] [field growX]`。`filename_field`・`filter_combo` をそれぞれ `setGrowX(1)`。
- **ラベル列の幅そろえ**: `File Name:` と `Files of Type:` の左端を揃えたい（Swing は揃う）。nimbus に GridBagLayout は未実装（CLAUDE.md「目指すゴール」は目標止まり）。
  v1 は **2 ラベルに同じ固定 `min_size.width` を焼く**（`places_sp` が `min_size.width=180` を直接設定している `:549` と同手）で近似する。厳密なグリッド整列は §12-4 に倒す。

### 2.4 row3（OK/Cancel 右寄せ）レシピ

- row3 = `BoxLayout.horizontalSpaced(8)`: `[ glue ][ OK ][ Cancel ]`。
- **glue**: BoxLayout に glue/spacer ヘルパは無い（`BoxLayout.zig` は `horizontal`/`vertical`/`*Spaced` のみ・確認済み）。
  **空 `Container` に `setGrowX(1)` を立てたもの**を glue として先頭に置き、OK/Cancel を右へ押す（[file_chooser_design.md](file_chooser_design.md) §決定 3「OK / Cancel は右寄せ（間に filler を挟む）」の具体化）。
  この glue は **右寄せのための機能的 filler**（行間スペーサの先回り生成ではない＝lightweight workflows に反しない・用途が明確）。
- 既存 `ok_button`/`cancel_button`（field `:404-405`／生成 `:573-574`／配線 `:576-577`）は **生成・配線そのまま、置き場所だけ row3 へ**。
  `showDialog` の `ok_button.setText(approve_text)`（`:510`）も不変。

---

## 3. Look In コンボ＝祖先チェーン（確定提案・純ロジック）

### 3.1 振る舞い（Swing 準拠）

- コンボの items ＝ **現在地の祖先チェーン**（root … 現在地）を上位から並べたもの。閉じた表示（selected）は **現在地**。
- ドロップダウンで祖先を選ぶと、その祖先ディレクトリへ移動（`ChooserCore.loadDir(ancestor_path)`）。
- 非編集（タイプ移動なし）。これで `path_field` + `onPathSubmit` を完全に置換する。

### 3.2 祖先チェーン生成＝純関数（GPU 非依存・テスト対象）

`ChooserCore` のメソッド（or 隣の純関数）として **`ancestorChain` 相当を新設**。シグネチャ案（実装判断・§12-5）:

```
// 絶対パス cur を root..cur の祖先列に分解する。各要素は { name: 表示名, path: 絶対パス }。
// 末尾（index = len-1）が cur 自身。呼び出し側は path をコピーするか即使用する（借用）。
fn ancestorChain(cur: []const u8, out: *std.ArrayList(Segment)) !void
```

- 分解は `std.fs.path.dirname` を root に当たるまで畳む（`up` と同じ `dirname` 基準・`:263`）。
  Windows ドライブルート（`C:\`・`dirname==null`・`:263`）／POSIX `/` で停止。表示名は各セグメントの basename（root は `C:\` / `/` をそのまま）。
- **純ロジック**＝`DirSource` に触れない（パス文字列操作のみ）。FakeDirSource すら不要で `std.fs.path` だけでテストできる（§10b）。
- 既存の `joinPath`/`hasTrailingSep`/`pathSepFor`（`:850-878`）と整合する区切り扱いにする（混在セパレータの既存配慮を踏襲）。

### 3.3 コンボへの投影

- `rebuildLookInCombo`（新・`rebuildFilterCombo` `:600-611` と同型）: `ancestorChain(core.getCurrentDirectory())` → 表示名配列を `look_in_combo.setItems` → `setSelectedIndex(len-1)`（現在地）。
- セグメントの絶対 path は **FileChooser 側に並行配列で保持**（コンボ item は文字列のみなので、選択 index → path の対応表を持つ）。
  `core.places`/`core.entries` と同じ「実体は FileChooser/core 所有、UI は借用/投影」の所有形（[file_chooser_design.md](file_chooser_design.md) §決定 4）。

### 3.4 `syncFieldsFromCore` の差し替え

- 現 `syncFieldsFromCore`（`:613-616`）の `path_field.setText(getCurrentDirectory())`（`:614`）を **`rebuildLookInCombo()` 呼び出し**へ置換。
- `loadDir` 後に走る既存経路（`reloadPath` `:618-623` / `onPlaceSelected` `:661-667` / `openEntry` `:637-648` / `onUp` `:650-655`）は
  すべて末尾で `syncFieldsFromCore` を呼ぶので、**ナビゲーションのたびにコンボが現在地へ追従**する（追加配線は最小）。

### 3.5 自己再帰ナビゲーションのガード（確定・§1.4 の footgun 対策）

`rebuildLookInCombo` 内の `setItems`/`setSelectedIndex` は ChangeListener を発火する（`:167`/`:133`）。`onLookInChanged` がそれを受けて
`loadDir(chain[idx])` すると、**`loadDir`→`syncFieldsFromCore`→`rebuildLookInCombo`→`setItems`→onChange→…** の再帰になる。対策（いずれか・実装判断・§12-6）:

1. **再構築中フラグ**（`syncing_look_in: bool`）を立て、`onLookInChanged` はフラグ中は早期 return（最も明示的・推奨）。
2. **パス比較ガード**: `onLookInChanged` で `chain[idx].path == core.getCurrentDirectory()` なら no-op（既に現在地＝再構築由来）。
   既存 `onPlaceSelected`/places でも同種の「同一パスなら無視」を app_filer がしている（`app_filer:1545,1566` のドロップ先比較と同思想）。

→ どちらでも純ロジックに落ちる（フラグ／比較は GPU 非依存）。§10b で「再構築が onChange 経由のナビを誘発しない」を assert。

---

## 4. ツールバー 4 ボタン（確定提案）

| ボタン | 動作 | 実装 |
|---|---|---|
| `Up`（上へ） | 親へ移動 | **既存 `onUp`（`:650-655`）を再利用**（`up_button` は消すがハンドラ本体は残す）。ドライブルートで no-op（core `up` が `dirname==null` 吸収・`:263`）。 |
| `Home`（ホーム） | home place へ移動 | `core.places` から `kind==.home` の index を引いて `core.selectPlace(i)`（`:267-270`）→ `rebuildFilesModel`/`syncFieldsFromCore`（`onPlaceSelected` と同シーケンス・`:661-667`）。home が無い環境（`osPlaces` が USERPROFILE/HOME 取得失敗・`:104`）ではボタンを no-op or 無効。 |
| `Details`（詳細） | 詳細(Table)へ切替 | `setViewMode(.details)`（§6.2）。 |
| `List`（リスト） | リスト(List)へ切替 | `setViewMode(.list)`（§6.2）。 |

- `Up`/`Home` は **既存 core API のみ**で実装＝framework 署名追加なし。
- `Details`/`List` は **常に 2 ボタン**（app_filer は 1 ボタン文言反転 `:642-645`。Swing 風参照画像は詳細/リストの別アイコン）。
  作者指示が「4 ボタン（…『詳細』『リスト』）」なので **2 ボタン固定**で実装（トグル 1 ボタンにしない）。押下で対応モードへ切替（同モードなら no-op・`setViewMode` 冒頭 `:634`）。
- home index 解決は純ロジック（places 走査）＝§10b でテスト可能。

---

## 5. 継ぎ目 A: 詳細(Table)ビューの置き場所（確定判断＋根拠）

### 5.1 判断: **(b) FileChooser 内に実装する**（framework へ共有部品抽出はしない）

根拠（単一真実源・Part C 教訓を踏まえた上で）:

1. **Table ウィジェット自体は既に framework 単一真実源**。`framework/src/Table.zig`＋`Application.table`/`tableWithModel`（`:767,774`）は
   framework グレードで、app_filer も FileChooser も**同じ Table を使う**＝ウィジェット契約の単一真実源は既に framework 側にある（抽出済み）。
   「共有すべき本体」は **もう共有されている**。残るのは各アプリ私有のセル/整形/レイアウトだけ。
2. **app_filer 私有のセルは行アイテム型に密結合で、そのままでは共有できない**。app_filer の `NameCell`/`TextCell` は
   **`app_filer.Entry`**（`name: []u8` 可変・rename 用・`:54-59`）をキャストする。FileChooser の **`Entry`**（`name: []const u8` 不変＋`visible: bool` フィルタ用・`:143-149`）は別型。
   共有「FileTableView」を作ると **2 つの Entry モデルの統合**を強いられる（app_filer は rename/DnD 用に mutable name、FileChooser はフィルタ用に visible）。これは v1 に対し早すぎる結合＝**却下**。
3. **app_filer のセルは FileChooser に不要な機能を抱える**: `NameCell` の `CellEdit`（rename・`:1350-1366`）/ `drag_source`（`:1761`）/ context menu（`:1718`）。
   FileChooser は選ぶだけ（§0 スコープ外）。共有部品にすると**使わない機能を持ち込む**か、機能を出し分ける分岐が増える＝部品が太る。FileChooser 専用の**読み取り専用セル**（icon+名 / size / date）を書く方が小さい。
4. **[file_chooser_design.md](file_chooser_design.md) が既に方針を確定済み**: §「なぜ framework か」＝
   **「app_filer から抽出せず、framework グレードで作り直す。コードのコピーではなく、動くと分かっている形を framework の語彙で再構築」**。
   `ChooserCore` の `entryLess`（`:828`）は app_filer の `sortLess`（`:292`）を **既に再構築済み**（コピーでなく core 語彙で）。詳細ビューも同じ流儀＝FileChooser に読み取り専用セルを実装し、**core の sort 済み可視リストを投影**する。

### 5.2 移植の内訳（FileChooser 内に新設するもの）

| app_filer 私有（移植元） | FileChooser 側の扱い |
|---|---|
| `Table` 構築（`:1707-1722`） | **そのまま `app.tableWithModel`**（framework 共有・単一真実源）。列 Name/Size/Modified。`setColumnHeaderView(headerView())`。 |
| `NameCell`（icon+名・rename 付き `:1334-1395`） | FileChooser 内に **読み取り専用 NameCell**（icon+名のみ・`CellEdit` 無し）。`FileCell`（`:743-782`）の icon ロジックを Table セル化したもの。 |
| `TextCell`（size/date `:1399-1417`）＋`fmtSize`/`fmtDate`（`:1121-1144`） | FileChooser 内に size/date セル。整形は **`fmtSize`/`fmtDate` を framework 語彙で再実装**（§5.3 のドリフト方針）。 |
| `sortLess`/`SortCtx`/`applySort`/`onSort`（`:146,292-314,892-904`） | sort は **core に既存**（`entryLess`・`:828`）。ヘッダクリックで列キーを変える分だけ薄く足す（§6.3）。 |
| `CardLayout`（私有 `:118-144`） | **§6.1 で判断**（FileChooser 私有 copy か framework 昇格か）。 |

### 5.3 重複/ドリフト回避の方針（単一真実源・Part C 教訓）

- **Table ウィジェット契約**（virtualization / header / sort 通知 / 列幅）は framework `Table.zig` が単一真実源＝両アプリ共有で **ドリフト不能**（最重要部分は既に一本化済み）。
- **sort（folders-first）**: FileChooser は **core の `entryLess`**（`:828`）を真実源にする。app_filer の `sortLess`（`:292`）と*概念は同じ*だが、
  app_filer は size/date 列キーでの sort（`:300-305`）を持ち、FileChooser core は名前固定 sort（`:828-831`）。**列キー sort を core に足すか view 層に置くかは §6.3 で判断**。
  いずれにせよ FileChooser の真実源は 1 つ（core or view のどちらか一方）に集約し、app_filer のコピーにはしない。
- **fmtSize/fmtDate（整形）**: 純粋・小（数行）。FileChooser に再実装する。これは **表示上の選択**で、app_filer と多少違っても**整合性の単一真実源違反ではない（cosmetic）**。
  ただし「同じ整形を 2 箇所が持つ」ドリフト自体を嫌うなら、**framework に整形ヘルパを 1 つ切り出して両者で使う**案も成立（§9・§12-7。署名追加になるので作者承認事項）。v1 は**再実装**を既定提案（Part C 教訓は「契約・幾何の単一真実源」が対象で、表示整形の数行重複は別物）。
- **CardLayout**: 「同じ ~15 行 LayoutManager を 2 アプリが私有」になるのが唯一の構造的重複。§6.1 で **framework 昇格 vs 私有 copy** を判断（app_filer 自身が「backlog 価値あり」と注記済み・`:116-117`）。

---

## 6. 継ぎ目 B: ビュー切替状態と選択/現在地の同期（確定提案）

### 6.1 `CardLayout` の置き場所（判断＋未決の明示）

card_holder（`:556-558`）を CardLayout 化して list_sp / table_sp を 2 枚差し替える（app_filer `:1726-1732` と同型）。CardLayout 実体の置き場所:

- **v1 既定提案＝(b1) FileChooser 私有 copy**: app_filer の `CardLayout`（`:118-144`）と同じ ~15 行を FileChooser 内に持つ。
  **framework 署名追加ゼロ**で済み、「v1 は additive・framework を先回りで太らせない」に合致。重複は CardLayout 1 個だけで局所的。
- **対案＝(b2) framework 昇格**: `CardLayout` を framework の `LayoutManager` 公開プリミティブにし、app_filer も FileChooser も使う（重複ゼロ）。
  app_filer のコメント（`:116-117`「dogfooding finding、backlog 価値あり」）がこの道を既に示唆。ただし **framework 署名追加**＝作者承認事項。

→ **§12-2 / §9 に「framework 署名変更候補」として列挙**。3 個目の利用者（テキストエディター）が出たら昇格、が無難。v1 は private copy で進めても詳細ビューは成立する。

### 6.2 view 切替状態＝app_filer パターンを単一選択で踏襲（GPU 非依存に寄せる）

FileChooser に `ViewMode`（`enum { list, details }`）と `view_mode` field を新設。app_filer の同期ヘルパ（`:588-648`）を **単一選択版**で踏襲:

- `activeFilesComponent()` / `selectedIndex()` / `setActiveSelected(?usize)` を `switch (view_mode)` で List/Table に分岐（app_filer `:590-616` と同型。ただし selection は single）。
- `setViewMode(mode)`（app_filer `:633-648` と同型）:
  1. 同モードなら no-op（`:634`）。
  2. `carry = selectedIndex()`（現 view の選択 index・`:635`）。
  3. `card.active` を list_sp / table_sp に差し替え（`:637-640`）→ `markLayoutDirty`/`repaint`（`:646-647`）。
  4. `setActiveSelected(carry)`（**選択を新 view へ持ち越し**・`:641`）。
- **両 view は同一 `files_model` を共有**（app_filer `:1689,1708` と同じ＝「同じモデルに 2 つの view」）。→ 行集合・並びは常に一致し、index の持ち越しが意味を持つ。
- 現在地は `ChooserCore` 単一保持（`cur`・`:165-166`）で view に依存しない。選択確定（`getSelectedPath`）は **view に依存せず**「現在地 ＋ 選択 Entry 名」（core `commitName`・`:383-387`）。

### 6.3 列キー sort（ヘッダクリック）の置き場所（判断）

app_filer は列キー sort を view 層（`SortCtx`/`sortLess`/`applySort`・`onSort` `:892-904`）に持つ。FileChooser core は名前固定 sort（`entryLess` `:828`）。選択肢:

- **(i) view 層に sort 状態を持つ**（app_filer 同型・推奨）: `onSort`（`Table.SortEvent`）で `sort_col`/`sort_dir` を更新し、
  **core の可視リストを view 側で並べ替えてから model 投影**。core は名前 sort のまま不変（§7 の「core 不変」を厳密に守れる）。
- **(ii) core に列キー sort を足す**: `ChooserCore.setSort(col, dir)` を新設。core が真実源になるが **core を変更**＝§7 の「core 不変」に反する。

→ **(i) を既定提案**（core 不変を守る・§7）。sort 状態と並べ替えは純ロジック（Entry 配列の比較関数）＝GPU 非依存でテスト可能（§10b）。
「リスト」ビューは単列なので sort UI 無し（core の folders-first 既定のまま）。ヘッダ sort は詳細ビューのみ。

### 6.4 同期ロジックの純粋性（テスト容易性）

- **真にGPU非依存な核**: 「選択 index → 可視 Entry → 確定パス」は `ChooserCore`（`visibleEntryAt` `:302` / `commitName` `:383`）で既に純粋＝FakeDirSource で常時テスト（既存 `:1067-1076`）。
- **view 切替の持ち越し**: `selectedIndex`/`setActiveSelected` は widget を触るが、`initHeadless`（GPU RT 無し）で `list.setSelected(i)` →
  `setViewMode(.details)` → `table.getSelected()==i` を **ヘッドレスで** assert できる（app_filer のスモークが `files_list.setSelected(1)` を使う `:1153` のと同じ手）。
- **列キー sort** と **祖先チェーン生成**（§3.2）と **home index 解決**（§4）は純関数として切り出し、GPU 無しで直接テスト（§10b）。

---

## 7. 継ぎ目 C: core ロジックは不変・view/レイアウト層だけ変える（確定方針）

- **変えない**: `ChooserCore`（`:157-388`）全体・`DirSource`/`os*`/`Fake*`・filters・places・`loadDir`/`cd`/`up`/`selectPlace`/`commitName`・`entryLess`。
  既存 core テスト（`:1036-1108`）は **無改変で緑**。
- **変える**: `FileChooser.buildUi`（`:523-583`・north/south 全面・center は card_holder の中身のみ）／`syncFieldsFromCore`（path_field→Look In コンボ・§3.4）／
  struct fields（§8）／view 層（List に加え Table・CardLayout・ViewMode・sort 状態）。
- **削る**: `up_button`/`path_field` field・`onPathSubmit`（§1.2）。
- 列キー sort は **view 層**に置き core を触らない（§6.3-(i)）。祖先チェーンは `ChooserCore` に**新規純関数追加**（既存挙動は不変＝additive・§3.2）。
  ※「core 不変」は厳密には「既存の振る舞いを変えない」。`ancestorChain` の **追加**は既存挙動を壊さないので方針に反しない（純関数 additive）。列キー sort を core に足す案(ii)だけは「不変」に抵触するため避ける。

---

## 8. `FileChooser` struct の増減（確定提案・`FileChooser.zig:390-410`）

削除:

- `path_field: *TextField`（`:401`）／`up_button: *Button`（`:406`）。

追加（詳細ビュー / Look In / ツールバー / view 状態）:

- `look_in_combo: *ComboBox` ＋ 祖先 path 対応表（並行配列 or `ArrayList`・§3.3）。
- `table: *Table` ／ `table_sp: *ScrollPane` ／ `list_sp: *ScrollPane`（現状 List 側 SP はローカル `:554`。card 切替で両 SP を field 保持）。
- `card: CardLayout`（§6.1 で private copy の場合）／ `card_holder` を field 化（現状ローカル `:556`）。
- `view_mode: ViewMode`（既定 `.list`）／ `up_button`→ツールバー 4 ボタンの field（`home_button`/`details_button`/`list_button`。`Up` は既存ハンドラ再利用だがボタンは新規）。
- `sort_col: usize` / `sort_dir: Table.SortDirection`（§6.3-(i)）。
- icon 追加は不要（`icon_folder`/`icon_file` 既存 `:407-408` を Table NameCell でも使う）。

所有/解放は **[file_chooser_design.md](file_chooser_design.md) §決定 4 の表に従う**＝widget ツリーは `dialog.destroy()`（`:473`）単一経路でまとめて解放（新 teardown 経路を作らない）。
Table も List と同じく `dialog.window.container` 配下に add するので追加解放不要。`look_in` の祖先 path 対応表は FileChooser 所有 → `destroy`（`:472-478`）で解放。
`files_model`（`:445`・両 view 共有・borrow 契約）は既存どおり `destroy` で deinit（`:475`）。CardLayout が private copy なら field 値で解放不要。

---

## 9. 新トークン / framework 署名変更（列挙・作者承認事項）

- **新トークン**: なし（LAF はスコープ外。レイアウト/view のみ）。
- **framework 公開 API 署名変更**: **必須はゼロ**で詳細ビューは成立する（Table/ComboBox/ScrollPane/SplitPane/BoxLayout は既に十分）。
  ただし **任意の昇格候補**を以下に列挙（採否は作者判断・§12）:
  1. **`CardLayout` の framework 昇格**（§6.1-(b2)）: `LayoutManager` プリミティブ化。app_filer と共有し重複ゼロ。署名追加（新公開型）。
  2. **`fmtSize`/`fmtDate` 整形ヘルパの framework 化**（§5.3）: 両アプリで 1 実装共有。署名追加（新公開関数）。小さく cosmetic なので必須ではない。
  3. **ComboBox editable 化**: 本 spec は **不要**（非編集で確定・§0）。将来 Swing の Look In 編集対応をするなら別途（ComboBox 側の機能要望）。
- `framework/doc/filechooser.md` の本体 API（mode/show/getSelectedPath/addFilter）は **不変**。doc 追従（[doc-impl-sync](.claude/rules/doc-impl-sync.md)）の観点では「Look In/詳細ビュー」は内部レイアウトで public 署名に出ないため spec 本文の改訂は最小（必要なら「機能要望」節の details ビュー記述を実装済みへ昇格）。

---

## 10. テスト計画（確定提案）

[file_chooser_design.md](file_chooser_design.md) §決定 5 の枠組み（フェイク DirSource の純ロジック ＋ Robot スモーク ＋ ゴールデンは使わない）を踏襲。
app 機能なので **Robot スモーク ＋ GPU 非依存の純ロジック**を主軸に。`Driver.clickOn(role+text)` を優先。

### 10a. Robot スモーク（`initHeadless`＋`Driver`・既存 `:1137-1164` を拡張）

- **詳細ビュー切替**: chooser を開く → `driver.clickOn(.{ .role=.button, .text="Details" })` → Table が active（`card.active==table_sp`）・行が出る →
  `driver.clickOn(.{ .role=.button, .text="List" })` で戻る。role=`.table`/`.list` の存在も `driver.find` で確認。
- **選択持ち越し**: list で行選択 → Details へ → 同じ Entry が選択されたまま → `OK` → `getSelectedPath` が一致（§6.2 の carry を黒箱で）。
- **Look In ナビ**: 深い階層に `loadDir` → `look_in_combo`（role=`.combobox`）で祖先選択 → `getCurrentDirectory` が祖先へ（クリックは Robot で combo を開いて item 押下、または `setSelectedIndex` 直叩き＋pump）。
- **ホーム/上へ**: `clickOn(.{ .role=.button, .text="Home" })` → home place の path へ。`"Up"` → 親へ。
- **OK 既存スモーク**（`:1137-1164`）は **そのまま維持**（List ビュー既定での選択→OK）。フェイク DirSource で決定的（実 FS 不使用）。

### 10b. GPU 非依存の純ロジック（常時実行・FakeDirSource or std.fs.path のみ）

[file_chooser_design.md](file_chooser_design.md) §決定 5 / [laf_enabler.md](laf_enabler.md) §5.0 の通り **`Device.init` ゲート下に置かない**。

- **祖先コンボ生成**（§3.2）: `ancestorChain("/home/me/docs")` → `["/", "home", "me", "docs"]` 相当（path/表示名）。
  Windows `C:\Users\me` → `["C:\\", "Users", "me"]`。ドライブルート/`/` で停止。`std.fs.path` だけでテスト（DirSource 不要）。
- **ビュー切替状態**（§6.2）: `setViewMode` の純粋な部分（`view_mode` 遷移・carry 値の決定）を、可能なら widget 非依存の小関数に切り出して assert。
  widget が要る持ち越しは 10a（ヘッドレス）でカバー。
- **ナビゲーション**（core・既存）: `cd`/`up`/`selectPlace` で `getCurrentDirectory` が動く（既存 `:1036-1053` 緑のまま）。
- **home index 解決**（§4）: places から `kind==.home` を引く純走査を assert（home 無し環境で no-op になることも）。
- **列キー sort**（§6.3-(i)）: Entry 配列に対し sort_col/sort_dir で folders-first＋列キーが効くことを比較関数で assert（GPU 不要）。
- **Look In 再構築が自己ナビを誘発しない**（§3.5）: `rebuildLookInCombo` 由来の onChange でガードが効き `loadDir` が再帰呼びされないことを assert（フラグ/比較の純粋部）。
- `error.SkipZigTest` 経路を踏まないこと（フェイク DirSource は Application 不要で組める）。

### 10c. ゴールデン（最小・新ダイアログ全体に 1 枚程度・広げない）

- **使わないのが既定**（[file_chooser_design.md](file_chooser_design.md) §決定 5「ゴールデン PNG は使わない」）。構造化スナップショット（`snapshotTree`・`:1161`）＋ハンドル検証で足りる。
- どうしても見た目回帰を 1 枚押さえるなら **新ダイアログ全体レイアウト 1 枚**（north Look In 行＋ south 2 行＋OK/Cancel 右寄せの構図）に留める。
  詳細ビューや各状態を**何枚も増やさない**（作者指示）。view 切替・選択・sort はすべて 10a/10b の構造/ロジックで担保する。

### 10d. デモ（既存 example の追従）

- `examples/widget_filechooser` / `examples/app_filer` は現状 `M` 変更あり（git status）。本タスクは doc のみだが、Codex 実装時に
  `widget_filechooser` で Look In/詳細ビューが動くことを目視（`examples/readme.md` は項目追加不要＝既存デモの内部更新）。

---

## 11. 実装の分割提案（Codex への継ぎ目）

詳細ビュー（B）と上部レイアウト（A）は独立性が高い。署名追加（CardLayout 昇格）の有無で粒度が変わる。推奨 3 継ぎ目:

- **継ぎ目 1＝上部 Swing 化（Look In ＋ ツールバー）**: `up_button`/`path_field`/`onPathSubmit` 削除 → `ancestorChain`（core 純関数追加）→
  `look_in_combo` ＋ `rebuildLookInCombo` ＋ 自己ナビガード（§3.5）＋ ツールバー 4 ボタン（Up 再利用 / Home / Details・List はスタブ）。
  **framework 署名追加ゼロ**・core は additive のみ。祖先チェーン純ロジックテスト（§10b）をここに同梱。view 切替ボタンは継ぎ目 2 までスタブ可。
- **継ぎ目 2＝詳細(Table)ビュー ＋ 切替**: `CardLayout`（private copy・§6.1-b1）＋ list_sp/table_sp の card 化 ＋ Table 構築（読み取り専用 Name/Size/Modified セル・fmtSize/fmtDate 再実装）＋
  `ViewMode`/`setViewMode`/同期ヘルパ（単一選択・§6.2）＋ 列キー sort（view 層・§6.3-i）。`Details`/`List` ボタンを実配線。
  ビュー切替・選択持ち越し・sort の純ロジック/ヘッドレステスト（§10a-b）を同梱。**framework 署名追加ゼロ**。
- **継ぎ目 3（任意・別 PR 可）＝framework 昇格**: `CardLayout` を framework プリミティブ化（§9-1）＋ app_filer を昇格 API へ載せ替え（重複解消）。
  **署名追加を含む唯一の継ぎ目**＝隔離。整形ヘルパ共有（§9-2）も入れるならここ。作者承認後に着手。

推奨: **1 → 2** で詳細ビュー込みの Swing 風ダイアログが完成（framework 改変ゼロ）。**3** は重複解消の最適化で、実需（3 個目の利用者）が出てから。
1 委譲でまとめても通る（core 不変・署名追加ゼロ）。pm が粒度を決める材料とされたい。

---

## 12. 未決（解決しない・列挙のみ）

1. **ツールバーの Container 化**: 4 ボタンを north に直置きか別 Container でまとめるか（layout 不変・実装判断・§2.2）。
2. **`CardLayout` の framework 昇格**: private copy（v1 既定）か framework プリミティブ昇格か（§6.1・§9-1）。3 個目の利用者で昇格が無難。
3. **詳細/リストの UI 形**: 2 ボタン（作者指示・確定）。アイコン付きにするか文字のみか（§4・§2.2）は目視判断。
4. **ラベル列の整列**: `File Name:`/`Files of Type:` の左端そろえを固定 min_width 近似（v1）にするか、将来 GridBag で厳密化するか（§2.3）。
5. **`ancestorChain` のシグネチャ/置き場所**: core メソッドか隣接純関数か・`Segment` 型の形（§3.2）は実装判断。
6. **Look In 自己ナビガードの方式**: 再構築フラグ（推奨）かパス比較か（§3.5）。
7. **整形ヘルパ共有 vs 再実装**: `fmtSize`/`fmtDate` を framework 化して app_filer と共有するか各自再実装か（§5.3・§9-2）。v1 は再実装。
8. **詳細ビューのソート初期状態**: Name 昇順固定（app_filer `:1716` 同）でよいか。リストビューは core の folders-first 既定（sort UI 無し）。

---

## 13. 確定／未決サマリ

| 区分 | 項目 |
|---|---|
| 確定 | 上部＝`Up`/`path_field`/`onPathSubmit` 削除、`Look In:` 非編集コンボ（祖先チェーン）＋ツールバー 4 ボタン（Up 再利用/Home/Details/List）（§0/§1.2/§3/§4） |
| 確定 | 下部＝south 縦 2 行（`File Name:`＋filename / `Files of Type:`＋filter）＋ row3 OK/Cancel 右寄せ（glue=growX 空 Container）（§2.3/§2.4） |
| 確定 | center の SplitPane/places は不変。card_holder（既存 `:556`）を CardLayout 化して List/Table 2 枚を切替（§2.1/§6.1） |
| 確定 | 詳細ビューは **(b) FileChooser 内実装**。Table ウィジェットは framework 既存（単一真実源）を使い、読み取り専用 Name/Size/Modified セルを新設。app_filer 私有セル（rename/DnD 付き・別 Entry 型）は抽出共有しない（§5.1/§5.2） |
| 確定 | ドリフト回避＝Table 契約は framework 一本化済み・sort は core `entryLess` 真実源・列キー sort は view 層に新設（core 不変）・fmtSize/fmtDate は再実装（cosmetic）（§5.3/§6.3） |
| 確定 | view 切替＝app_filer パターン（`ViewMode`/`setViewMode`/同期ヘルパ）を**単一選択版**で踏襲。両 view は同一 `files_model` 共有・選択 index を切替で持ち越し・現在地は core 単一保持（§6.2） |
| 確定 | core（`ChooserCore`/places/filters/loadDir/cd/up/selectPlace/entryLess）は不変・既存テスト緑。`ancestorChain` は additive 純関数追加（既存挙動不変）（§7） |
| 確定 | 新トークン 0・framework 必須署名変更 0（詳細ビューは既存 Table/ComboBox/ScrollPane で成立）。CardLayout/整形ヘルパの framework 昇格は**任意**（作者承認）（§9） |
| 確定 | テスト＝Robot スモーク（Driver.clickOn role+text で詳細切替/選択持ち越し/Look In ナビ/Home/Up・OK 既存維持）＋ GPU 非依存純ロジック（祖先チェーン/ビュー切替/home 解決/列キー sort/自己ナビガード）。ゴールデンは新ダイアログ全体 1 枚に留め広げない（§10） |
| 確定 | 実装分割＝1 上部 Swing 化（署名追加 0）→ 2 詳細ビュー＋切替（署名追加 0）→ 3 任意 framework 昇格（CardLayout・署名追加を隔離）。1→2 で完成（§11） |
| 未決 | ツールバー Container 化／CardLayout 昇格／詳細・リストのアイコン／ラベル整列／ancestorChain 署名／自己ナビガード方式／整形ヘルパ共有／ソート初期状態（§12） |
