# c_api-codegen バックログ（棚上げ案件）
apigen（[c_api_codegen.md](c_api_codegen.md)）で**後回しにした項目**のメモ。

2026-06-02 時点の状況:
- 実装済み: `#1` ブートストラップ / `#2` 文字列戻り / `#3` 文字列配列引数 / `#5` optional 値構造体 /
  `#6c` リスナー remove、そして **`#4` List CellFactory / `#6a` Image**（正式記述は c_api_codegen.md に移動）。
- **純 A のウィジェット一括公開も完了**（2026-06-02）: Label/Panel/CheckBox/RadioButton/Slider/ScrollBar/
  TextField/TextArea/Window/Menu 系/3 モデル/残り Application ファクトリ。詳細は末尾「次の一手の候補」。
- 棚上げ中（bespoke）: **`#6b` Timer のみ**。
- その他: 「軽微な未対応」一覧と、末尾の「公開 API の C ABI 生成カバレッジ調査」。

`#4` / `#6a` の項は実装後も検討経緯の記録として残してある（この backlog を削除する時に一緒に捨てて良い）。
各 bespoke 項目は「何 / なぜ bespoke / 候補アプローチ / 決めること」で書く。

---

## #4 List の CellFactory
**実装済み（2026-06-01）。正式な記述は [c_api_codegen.md](c_api_codegen.md)「List / CellFactory」へ移動した。**
factory→cell の 2 段アダプタ（C 関数ポインタ → native fnptr）、cell プロトコル構造体、ListModel /
選択 / index 群を preamble 手書き、typedef・rowHeight・change-listener・upcast は生成、という形で確定。
セル編集（`Cell.edit`）と `ScrollPane` ラップは未公開（制約として doc に記載）。以下は検討経緯の記録
（この backlog 削除時に一緒に捨てて良い）。

### 何
`Application.list(factory: List.CellFactory) !*List`。`CellFactory` は関数ポインタの構造体
（`create: fn(*anyopaque, allocator) !Cell` など）で、生成物 `Cell` 自体も
`{ component: *Component, update: fn(*anyopaque, ctx) void, destroy: fn(*anyopaque, allocator) void }`
のように**関数ポインタ＋状態を持つ**。JavaFX VirtualFlow 方式（可視ぶんの実セル + recycle、
[[project-list-cell-design]] 相当）なので update は recycle のたびに呼ばれる。

### なぜ bespoke
単一コールバックではなく「**インターフェースを返すインターフェース**」。`callback` 機構（box +
トランポリン 1 段）では表せない。Cell の状態の所有・寿命、CellContext（行 index 等）の受け渡し、
recycle 時の update 再呼び出しまで絡む。

### 候補アプローチ
preamble に **C フレンドリーな cell API を手書き**してアダプトする（ブートストラップと同類の bespoke グルー）。
たとえば:
```c
typedef struct { void* component; void (*update)(void* cell_ud, /* ctx */); void (*destroy)(void* cell_ud); } nmCell;
typedef struct { void* userdata; nmCell (*create)(void* userdata); } nmCellFactory;
```
を受け取り、native の `CellFactory`/`Cell` に変換する薄い Zig アダプタを書く。

### 決めること
- C 側の cell / factory API の具体形（CellContext の何を C に渡すか：index・selected 等）。
- cell 状態の所有（バインディングが cell userdata を所有し、destroy で解放）。
- recycle の update に何を渡すか（行データは userdata 経由か、ctx で index を渡すか）。

---

## #6a awt.Image（値返し / setIcon）
**実装済み（2026-06-01）。正式な記述は [c_api_codegen.md](c_api_codegen.md)「Image / icon」へ移動した。**
以下は検討経緯の記録（この backlog 削除時に一緒に捨てて良い）。実装は curated `nmIcon` enum +
`nmAppIconNamed` 文字列フォールバック、借用は alloc-free フィールド参照、owned は loader 産のみ、
Image 関数群は preamble 手書き・`nmImage` typedef のみ生成、という確定どおり。

### 何
`awt.Image = { texture: Texture, width: i32, height: i32 }`（GPU テクスチャを包む値型、awt/src/Image.zig）。
関連 API: `Button.getIcon() ?Image` / `setIcon(?Image)`、`Image.fromMemory(allocator, device, bytes) !Image`、
`Image.deinit()`（texture を解放）、`Application.icon(id: lucide.Icon) !Image`（lucide/icons.zig）。

### 所有モデル（確定）
Image の入口は 3 つ、所有は **owned 一系統（loader 産のみ）/ あとは全部借用** にきれいに割れる。

| 入口 | texture の所有者 | 解放するのは | C ハンドル | nmImageDestroy |
|---|---|---|---|---|
| `Image.fromMemory` (loader) | 呼び出し元 owned | 呼び出し元が一度 | heap box（1 alloc） | **する** |
| `Application.icon(id)` | App の `icon_cache` | App.deinit のみ | 借用 = cache スロットへの参照 | しない |
| `Button.getIcon()` | 元の owner（loader or App icon） | その owner | 借用 = `&button.icon.?` | しない |

確認根拠:
- `Button.icon: ?awt.Image` は値保持だけ（Button.zig:28）。`setIcon` は `self.icon = img;` の値コピー、
  `getIcon` は `return self.icon;` の値コピー。**`Button.destroy` は icon を deinit しない**（Button.zig:291–300）。
- `Application.icon` はコメントに `The returned Image is borrowed; do not call deinit on it.`（Application.zig:642）。
  `icon_cache: [lucide.Icon.count]?awt.Image` を遅延デコードしてキャッシュし借用を返す。解放は App.deinit のみ。
  App はルートで最後まで生きるので**この借用は実質ダングリングしない**＝最も安全な借用クラス。

ライフタイム危険は「**owner が先に free → 借用している widget / getIcon 戻りが use-after-free**」の向き
（widget が死んで texture が消えるのではない）。owner は常に一点なので構造は単純。

### なぜ bespoke
- 値型だが内部に GPU `Texture`（バックエンドハンドル）を持つ。nmColor のような純データ値構造体には
  できない（texture は C にとって意味のある値ではなく、コピーは外部所有の GPU 実体を指す借用になる）。
- **C から Image を得る手段が無い**：`icon(id)` の引数 `lucide.Icon` は数百メンバの巨大 enum（公開非現実的）、
  `fromMemory` は device/allocator が要る。→ setIcon に渡す Image を C 側で用意できない＝**生成口を手書き必須**。

### アプローチ（確定）：opaque ハンドル + 借用は alloc-free
所有を loader 産 owned 一系統に寄せ、借用は箱を作らずフィールド参照で返す。

- **生成口は手書き**：`nmImage* nmImageLoadPng(const char* path)` 等（owned → `nmImageDestroy` で `Image.deinit`）。
  device/allocator は内部の Application から取る。**loader だけが alloc（heap box）を払う。**
- `setIcon(?Image)`：C は `nmImage*`、シムは deref して**値コピーを Button に渡す**（所有は移さない＝今の Zig と同じ借用）。
- `getIcon() ?Image`：**(b) alloc-free に確定**。`&button.icon.?` 相当でフィールドのアドレスを返す（box を作らない）。
  寿命は widget 従属。none は null。
- `Application.icon(id)`：**借用に確定**。`&self.icon_cache[idx].?`（cache は App 上の固定長配列でアドレス安定）を返す。
  初回デコードで `!Image` なので失敗 = NULL + last_error。`nmImageDestroy` は呼ばない。
- `nmImageDestroy` は **loader 産の owned ハンドルにのみ呼ぶ**。借用 2 つ（getIcon / Application.icon）は
  裸のフィールド参照で box を持たず、destroy しない。

不採用: 値構造体で texture を opaque フィールド露出（内部漏れ・脆い）。

### バインディング側の keep-alive（free/no-free とは別軸）
binding は「**widget が借用先 Image を生かし続ける**」方向に pin する:
```python
img = nm.Image.load_png("a.png")  # owned
btn.set_icon(img)                 # 生成器が btn._icon_ref = img を仕込む
del img                           # 変数が消えても Button が参照保持 → texture 生存
```
副作用として **`btn.get_icon()` は新規ラッパーを作らず、キャッシュ済みの同じ Python オブジェクト
(`btn._icon_ref`) を返せる** → alloc-on-return も寿命問題も消える（icon が binding 経由で set された場合）。
`Application.icon` の借用は App を pin すればよいが、App はルートで全てより長生きするので keep-alive は実質コスト 0。

`ownership` タグ（owned/borrowed）が double-free を防ぎ、この keep-alive が use-after-free を防ぐ。2 軸の役割が違う。

### lucide 引数の出し方（確定）：curated enum + 文字列フォールバック
`lucide.Icon` は ~1700 メンバの巨大 enum（icons.zig 自動生成、各 variant が 64×64 PNG）。全 enum 露出は
不採用 — メンバ順を**上流が所有**するため、lucide 更新で値がズレ、shared-lib + バインディングで「黙って違う
アイコンが出る」ABI 破壊になる（nmAlignment は nimbus 所有 4 個なので安全、という違い）。代わりに 2 入口:

```c
nmImage* nmAppIcon     (nmApplication* self, nmIcon id);        // curated, 補完が効く
nmImage* nmAppIconNamed(nmApplication* self, const char* name); // それ以外も文字列で（未知 = NULL + last_error）
```
- **curated `nmIcon`** は nimbus 所有の小さな安定 enum（種は CLAUDE.md ビルトインアセット: open/save/save_as/
  undo/redo/cut/copy/paste …）。順序を nimbus が所有するので値が安定（追加は末尾 append）。
- **文字列パス**は int の ABI 値を持たず、契約は文字列名。lucide が改名/削除しても**黙って誤アイコンではなく
  明示エラー**（`stringToEnum` → null → NULL + last_error）。全 enum 露出の弱点をエラーに変換でき、むしろ堅い。
- 名前は lucide メンバ名で揃える（`nmIcon.save` ⇔ `"save"`）。binding は型で振り分けてメソッド 1 個に統合可
  （`app.icon(nm.Icon.SAVE)` / `app.icon("circle_plus")`）。
- **コスト**: curated リストを nimbus が手で保つ（＝どのアイコンを補完対象にするかの設計判断。小さく負担軽）。

### apigen への影響（実装時にやること）
- **名前マップ型 curated enum** 構文を追加。既存の「ネイティブ enum を同順ミラー + index assert」は使えない
  （curated は部分集合で index が native と不一致）。代わりに `nmIcon → lucide.Icon` の switch を生成し、各腕を
  `@field(lucide.Icon, "save")` で引く＝**drift 検査が名前ベース**（上流の改名/削除がコンパイルエラーになる）。
- `nmAppIconNamed` は `stringToEnum` 一発なので apigen 汎用化せず **preamble.zig に手書きシム**で足す。
- 借用 2 つ（getIcon / Application.icon）は **(b) alloc-free のフィールド参照**で出す（box を作らない）。
  loader (`nmImageLoadPng` 等) だけが owned＝heap box を払い、`nmImageDestroy` の対象もそれだけ。

---

## #6b Timer（setTimeout / setInterval / clearTimer）
### 何
`Application.setTimeout(ms: u32, cb: TimerCallback, user_data: *anyopaque) !TimerId`、`setInterval`、
`clearTimer(id: TimerId)`。`TimerCallback = *const fn(*anyopaque) void`（**event 無し・生の関数ポインタ**）。
`TimerId = u32`。戻りは `!TimerId`（値 + エラー）。

### なぜ bespoke（リスナーと違う点が 3 つ）
1. **event 無し**のコールバック（現 `callback` 機構は event 前提）。
2. **raw 関数ポインタ登録**：setTimeout は `*const fn(*anyopaque)void` を直接取る。リスナーの
   typed `addXxxListener(comptime T, f, ud)` 経路ではない。→ コールバック引数の展開が違う
   （リスナー= `(T, トランポリン, box)`、Timer= `(トランポリンの fn ポインタ, box)` の 2 ランタイム引数）。
3. **値 + エラー戻り**（`!TimerId`）。

### 候補アプローチ
- `callback` を **native_event 省略可**に一般化：トランポリン `fn(box: *Box) void { box.fn(box.userdata); }`、C は `void(*fn)(void*)`。
- 登録の種別フラグ：そのメソッドが「typed listener」か「raw fnptr」かを spec で区別（callback 宣言か fn 側に印）。
- **値 + エラー戻りは out 引数**で（`#5` の optional 戻りと同じ機構を一般化）：
  `int nmAppSetTimeout(nmApplication*, uint32_t ms, nmTimerCallback* cb, uint32_t* out_id)`。
- `clearTimer(id: u32)` はスカラ引数で容易。

### 決めること
- **one-shot の box 寿命**が肝。setTimeout は一度発火したら消える → box をいつ誰が解放するか
  （発火後にトランポリン側で free？ それともバインディングが TimerId で管理し clearTimer / 発火後に解放？）。
  interval は clearTimer まで生存。ここを決めないとリーク or use-after-free になる。
- raw-fnptr 登録を spec でどう表すか（`callback ... raw` のような種別、または fn 側の注記）。

---

## 軽微な未対応（bespoke ではない、拡張で済む）
詳細は [c_api_codegen.md](c_api_codegen.md)「実装済み / 未対応」を参照。

- optional ハンドル `?*T`：nullable ポインタで容易だが、現状 live な利用メソッドが無く未生成。
- 値（スカラ/enum/struct/str）戻り + エラーの一般形（out 引数 or センチネル。#6b の TimerId と共通）。
- `@ctor` / `@dtor` を型側 IR に紐づけ（現状はファクトリ + 汎用 destroy で代替できている）。
- enum の明示値・非連続値・フラグ（ビット或）。
- 値構造体のネスト / 配列 / enum フィールド。
- コールバックの event に追加 typed 引数を持つ署名（今の nimbus のリスナーは event 1 個のみ）。

方針（2026-06-02 確認）: これらは **live な利用者が無い** ので先回り実装しない（投機的・検証不能）。
各項目は「それを使う公開済みメソッドが出た時点」で concrete に実装する（point-of-need）。

**usize スカラは実装済み（2026-06-02）**: `Scalar` に `usize`（→ C `size_t`）追加。実需があったので
例外的に先行実装し、実利用者で検証 — `List.edit` を手書き `nmListEdit` から**生成に移行**、`ComboBox` の
index API（`getSelectedIndex`/`setSelectedIndex`/`getItemCount` = `size_t`、`getItem(size_t)->?str`）を公開。

---

## 公開 API の C ABI 生成カバレッジ調査（2026-06-02）
「現状の apigen で nimbus.api を書くだけでどれだけ露出できるか」を `framework/src` の公開 `pub fn` で
分類した結果（内部 = vtable 実装 / GapBuffer / log / 各 create・init・deinit は除外）。
A = 今すぐ生成可、B = 小拡張で生成可、C = bespoke 手書き。

### 概数
- **A（追記ゼロで生成可）≈ 70〜75%**（usize 実装後。index/count/size 系が A に昇格）
- **B（小拡張で生成可）≈ 10%**
- **C（手書き必須）≈ 15〜20%**

> 補正: 初回調査はリスナー登録（`addXxxListener`/`removeXxxListener`）と `?Size`/`?str` 戻りを手書き側に
> 数えていたが、これらは**既に生成対応済み**（callback 機構・optional 値構造体・?str）。よって実際の A は
> 調査の素の値（~55%）より高い ~65〜70%。

### A（今すぐ生成可）— ウィジェット API の主流
プロパティ get/set・ファクトリ・リスナー登録のスタイルは丸ごと生成可:
- Label / Button / CheckBox / RadioButton / Slider / ScrollBar（text・color・bool・enum・f32 系）
- TextField / TextArea（text・各色）、Menu / MenuItem / CheckBoxMenuItem / Panel / Frame
- Component の bounds / grow / align / focus / name 系 ~25 メソッド
- Application のファクトリ ~28 個（label/panel/button/.../textArea — 全部「widget 確保 → `*T` 返し」）
- 各 Model の bool/i32 state（ButtonModel / ToggleButtonModel / BoundedRangeModel / ScrollBar）
- リスナー（既存 callback 機構）、`?Size`/`?str` 戻り（実装済み）、value struct（Color/Size/Border 等）

### B（小拡張で生成可）— ROI 順
| 拡張 | 影響 | 備考 |
|---|---|---|
| ~~usize / size_t スカラ追加~~ | ~~最多~~ | **✅ 実装済み（2026-06-02）。`Scalar` に usize 追加・`ComboBox` index API + `List.edit` で実証** |
| optional スカラ `?usize` / `?f64` | 数件（`List.getEditing` / `earliestDueIn`） | 残 |
| 値 + エラー戻り `!T`（T が値） | 数件 | #6b TimerId と共通機構。残 |
| Panel `Border` 等の value struct | 数件 | フィールドが f32+Color なら平坦化で A。残 |

usize 実装により index/count/size 系が A に昇格済み（残る B は optional スカラ・値+エラー等）。

### C（手書き必須）— 性質が判明済み・パターン確立済み
- bespoke プロトコル（関数ポインタ構造体）: List `CellFactory`/`Cell`（実装済み）、DnD transfer、overlay/popup 配置
- `void*` / `*anyopaque` userdata: `Component.putProperty`/`getProperty`、`OverlayManager.remove(owner)`
- event 以外の追加引数を持つコールバック: DnD `onDragStart`/`onOver` 等
- allocator / io ブートストラップ: `Application.init`（→ `nmAppCreate` 実装済み）、`Window.init`

### 次の一手の候補
1. ~~**純 A のウィジェット一括公開**~~ — ✅ 実装済み（2026-06-02）。Label / Panel / CheckBox /
   RadioButton / Slider / ScrollBar / TextField / TextArea / Window / Menu 系（Menu / MenuItem /
   CheckBoxMenuItem / MenuBar / MenuSeparator / PopupMenu）/ 3 モデル（ButtonModel /
   ToggleButtonModel / BoundedRangeModel）/ 残り Application ファクトリ（label/container/panel/
   checkBox/radioButton/slider/scrollBar/textField/textArea/filler/toolBar/menu 系）を nimbus.api に
   手書きゼロで追記。opaque 27・関数 154（生成）。新規 value struct（nmWindowPoint/nmWindowSize/
   nmPoint）・enum（nmOrientation/nmScrollOrientation）・cast 14 個。`zig build install`/`test` 緑・
   apigen 決定的・C ヘッダー構文 OK。
2. ~~usize スカラ追加~~ — ✅ 実装済み（2026-06-02）。

#### 一括公開で判明した「あと一歩」の point-of-need 項目
純 A の網羅中に、すぐ隣にあるが現状の語彙では出せず**意図的に外した**ものを記録しておく
（いずれも「使う公開メソッドが出た時点」で対処する方針）。
- **optional ハンドル引数 `?*T`**: `Frame.setMenuBar(?*MenuBar)` / `Window.setMenuBar(?*Component)` /
  `Window.requestFocusFor(?*Component)`。メニューバーを Frame に取り付ける最後の一手がこれ待ち。
  parseArgType に `?*` を足すだけの小拡張（B 相当、実需が出た）。
- **optional ハンドル戻り `?*T`**: `MenuBar.at(usize) ?*Menu` / `ButtonGroup.getSelected()`。軽微な未対応のまま。
- **Menu/MenuItem の icon get/set**: `awt.Image` 値の box/unbox が要る → Button の icon と同じ bespoke
  （preamble 手書き。#6a と同じ手で足せる）。今回は text/model のみ公開。
- **ButtonGroup**: `deinit` + `allocator.destroy` の 2 段破棄で、Component の vtable destroy に乗らない
  （非 Component）。bespoke な destroy シムが要るので今回は除外（RadioButton 排他はモデル経由で可能）。
- **Panel.Border**: フィールドが `thickness:f32` + ネストした `Color` → 値構造体のネスト未対応。background のみ公開。
- **ScrollPane**: `asComponent` が 2 段（`&self.container.component`）で cast 構文に乗らない（既出の棚上げ）。
