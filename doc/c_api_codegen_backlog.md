# c_api-codegen バックログ
apigen（[c_api_codegen.md](c_api_codegen.md)）の残件。書き方・運用規約は [backlog.md](backlog.md) を参照。

2026-06-02 に新スタイルへ移行し、解決済み項目を削除して残件をゼロから採番し直した
（消した項目は git 履歴から復元可能）。実装済みの機能一覧は c_api_codegen.md「実装済み」を参照。

難易度の分類（この領域固有）:
- **A** = 今すぐ生成可（`nimbus.api` に書くだけ・生成器変更ゼロ）
- **B** = 小拡張で生成可（生成器に小機能追加）
- **C** = 手書き bespoke（preamble 3 点に手書き）

カバレッジ概数（2026-06-02）: A ≈ 70〜75% / B ≈ 10% / C ≈ 15〜20%。

完了条件の共通基準（各項目では固有条件のみ記す）: 対象 API が C から呼べる・apigen 再生成が決定的・
`zig build install` / `zig build test` が緑・`nimbus.h` の構文チェック OK。

次の一手の推奨: **残る A は #4（ScrollPane、依存 #6）のみ**（#1 / #2 / #3 / #13 と #5 は完了）。
#4 は #6（2 段 cast）で完結する。

---

## #1 Component 共通メソッドの公開
- 状態: 完了
- 優先度: 高
- 影響範囲: `nimbus.api`（全ウィジェットに効く。各 AsComponent 経由）、新規 value struct `nmRect`
- 更新日: 2026-06-02
- 依存: なし

完了（2026-06-02）: growY/alignY、isFocusable/setFocusable、requestFocus、repaint、markLayoutDirty、
getName（?str）、setName（?str・#5）、containsWindowPoint、getBounds/setBounds（`nmRect`）、
absoluteOriginInWindow（`nmPoint`）を公開。min/max size は方針どおり非公開。検証: 全緑。

### 何
Component の共通プロパティ系を公開する。前回 X 軸だけ出して漏れているものが中心:
- `getGrowY`/`setGrowY`、`getAlignY`/`setAlignY`（grow/align は X しか出していない）
- `isFocusable`/`setFocusable`、`requestFocus`、`repaint`、`markLayoutDirty`
- `getName`（`?str` 戻り）、`containsWindowPoint(f32,f32)->bool`
- `getBounds`/`setBounds`、`absoluteOriginInWindow` ← `nmRect{x,y,width,height:f32}` を宣言するだけ
  （awt.Graphics.Rect は素の値構造体・生成器変更不要）。`nmPoint` は既存。

### なぜ（保留理由）
純 A だが spec 行が未記述なだけ。全ウィジェットに効くので最優先。

### 決めること
- `setName(?str)` は `?str` 引数が要る（#5）。getName だけ先に出すか、#5 完了を待って両方出すか。

### 完了条件
上記メソッドが C から呼べる（`setName` を除く、または #5 完了後）。`nmRect` を宣言。

意図的に出さない: `getMinSize`/`setMinSize`/`getMaxSize`/`setMaxSize` は生成可能だが、CLAUDE.md が
「minimumSize/preferredSize/maximumSize の複雑さは取り入れない」と明言 → 設計判断で除外。

---

## #2 ウィジェットの取りこぼし公開
- 状態: 完了
- 優先度: 中
- 影響範囲: `nimbus.api`（Button / ComboBox / Container）
- 更新日: 2026-06-02
- 依存: なし

### 何
純 A だが未記述のもの: `Button.getModel`（→ `*ButtonModel` @borrowed）、`ComboBox.isEnabled`/`setEnabled`、
`Container.remove(*Component)`。

完了（2026-06-02）: `nmButtonGetModel` / `nmComboBoxIsEnabled` / `nmComboBoxSetEnabled` /
`nmContainerRemove`（detach のみ・child は借用）を公開。検証: 全緑。

---

## #3 Dialog 一式の公開
- 状態: 完了
- 優先度: 中
- 影響範囲: `nimbus.api`（opaque `Dialog`・enum `nmDialogResult`、Application ファクトリ、cast）＋
  preamble（bespoke destroy）
- 更新日: 2026-06-02
- 依存: なし

完了（2026-06-02）: 下記決定どおり実装。生成（A）= `nmAppDialog(owner:*Window,…)@owned`・`nmDialogShowModal`・
`nmDialogShow`・`nmDialogClose`・`nmDialogGetResult`・`nmDialogIsModal`・`nmDialogIsShown`・
`cast nmDialogAsWindow`（埋め込み Window でダイアログに widget を載せる）。手書き（C）= `nmDialogDestroy`
（deinit + allocator.destroy）。opaque 29・生成関数 192。検証: 全緑（clang で showModal・任意コードの
キャスト・destroy・AsWindow まで構文チェック）。

### 何
`app.dialog(owner:*Window, …) -> *Dialog`（ハンドル引数＋戻り）＋ `Result` enum ＋
`show`/`close(Result)`/`getResult`/`isModal`/`isShown`。`showModal` は二次ループ（ブロッキング）だが
値戻りなので生成自体は可。

### 決めること（決定: すべて案A）
- **Result の C 表現 → 案A: C 固定 enum `nmDialogResult{none,ok,cancel}`**。apigen の enum は
  `@enumFromInt`/`@intFromEnum` を通すので、native の非網羅 `enum(i32)+_` の任意コードも C 側で
  `(nmDialogResult)42` のキャストでそのまま通る（補完＋drift 検査を足しつつ非網羅性を失わない）。
- **showModal のブロッキング → 案A: 素直な同期ブロッキング関数**（`nmDialogShowModal(*Dialog) -> nmDialogResult`）。
  C ABI 層は特別な仕掛け不要。「UI スレッドをブロックする」注記はバインディング doc 側で扱う。
- **破棄/所有 → 案A: 専用 destroy シムを手書き**（`nmDialogDestroy` = `deinit` + `allocator.destroy`）。
  Dialog は非 Component かつ caller-owned（Application は `noopDestroy` で登録し解放しない）ため、汎用
  `nmComponentDestroy` が使えず 2 段破棄が要る（#11 ButtonGroup と同型）。factory は `@owned`。

### 完了条件
Dialog をファクトリで生成し、modal / 非 modal で開閉・結果取得が C から可能。← 達成。

---

## #4 ScrollPane の中身公開
- 状態: 未着手
- 優先度: 中
- 影響範囲: `nimbus.api`（新規 opaque `ScrollPane`・enum `Policy`、Application ファクトリ）
- 更新日: 2026-06-02
- 依存: #6（`asComponent` の 2 段 cast。無いと破棄経路が不完全）

### 何
`getView`/`setView`/`getScrollX`/`getScrollY`/`setScrollX`/`setScrollY`/`setUnitIncrement`/
`setHorizontalPolicy`/`setVerticalPolicy`（enum `Policy`）/`scrollRectToVisible(nmRect)`/change listener。
`asComponent` 以外は今すぐ出せる。

### 決めること
- `app.scrollPane(view:*Component)` の view 所有権（transfer）。
- `asComponent` を #6（2 段 cast）で出すか、1 行 bespoke シムで出すか。

### 完了条件
ScrollPane をファクトリで生成し、スクロール操作・policy 設定が C から可能。Component upcast 経路あり。

---

## #5 `?str` 引数のサポート
- 状態: 完了
- 優先度: 中
- 影響範囲: 生成器 `main.zig`（ArgType 追加）、`Component.setName`
- 更新日: 2026-06-02
- 依存: なし

### 何
nullable 文字列引数 `?str`（C は nullable `const char*`、Zig は `?[]const u8`）。戻りの `?str` はあるが
引数が無い。`?*T` と同型の小拡張。consumer = `Component.setName(?[]const u8)`。

完了（2026-06-02）: ArgType に `str_opt` を追加（C は nullable `const char*`、Zig シムは `?[*:0]const u8`、
呼出は `if (p) |_p| std.mem.span(_p) else null`、IR は `"optional": true`）。`nmComponentSetName(?str)` で実証。
検証: apigen 決定的・install/test 緑・clang で NULL 渡し構文チェック。

---

## #6 2 段 cast のサポート
- 状態: 未着手
- 優先度: 中
- 影響範囲: 生成器 `main.zig`（cast 構文）、`ScrollPane.asComponent`
- 更新日: 2026-06-02
- 依存: なし

### 何
`ScrollPane.asComponent` は `&self.container.component`（2 段）で現 cast 構文に乗らない。

### 候補アプローチ
- 案A: cast 構文を `cast = Type.field.subfield` に拡張（2 段以上を許す）。
  メリット: 同種が出ても再利用可。デメリット: 構文・生成器をやや複雑化。
- 案B: ScrollPane 用に 1 行 bespoke シムを preamble に手書き。
  メリット: 生成器を触らない。デメリット: ad-hoc・横展開しない。
- 判断軸: 2 段 cast が他にも出るなら A、ScrollPane 限りなら B。
- 推奨: 案A（cast は安価な機構で、今後 Panel 等でも `container.component` 形が出うる）。最終判断は作者。

### 完了条件
`ScrollPane` の Component upcast が出る（#4 が完結する）。

---

## #7 optional スカラ `?usize` / `?f64`
- 状態: 棚上げ
- 優先度: 低
- 影響範囲: 生成器 `main.zig`
- 更新日: 2026-06-02
- 依存: なし

### 何
optional なスカラ戻り / 引数。consumer 候補: `List.getEditing`（`?usize`）、`earliestDueIn`（`?f64`）。

### なぜ（保留理由）
live な利用メソッドが少なく、出す強い実需が未到来（point-of-need）。

### 完了条件
`?usize`/`?f64` が out 引数 or センチネルで生成でき、consumer で実証。

---

## #8 値＋エラー戻りの一般形
- 状態: 棚上げ
- 優先度: 低
- 影響範囲: 生成器 `main.zig`
- 更新日: 2026-06-02
- 依存: なし（#10 Timer と機構を共有）

### 何
値（スカラ / enum / struct / str）＋ `!error` の戻り。現状は「値戻りは失敗なし」のみ対応。

### 候補アプローチ
- 案A: out 引数 + bool/int（`#5` の optional 値構造体と同じ機構の一般化）。
  メリット: 既存パターンの踏襲。デメリット: シグネチャに out が増える。
- 案B: センチネル値（型ごとに「失敗値」を決める）。
  メリット: 戻り 1 個で素直。デメリット: 型ごとにセンチネル規約が要る・誤用しやすい。
- 判断軸: 一貫性・安全側なら A、呼び心地なら B。
- 推奨: 案A。最終判断は作者。

### 完了条件
値＋エラー戻りが生成でき、Timer の TimerId 等で実証。

---

## #9 値構造体のネスト対応
- 状態: 棚上げ
- 優先度: 低
- 影響範囲: 生成器 `main.zig`、`Panel.getBorder`/`setBorder`
- 更新日: 2026-06-02
- 依存: なし

### 何
フィールドにネストした値構造体を持つ struct。consumer = `Panel.Border{thickness:f32, color:Color}`
（現状 Panel は background のみ公開）。

### 候補アプローチ
- 案A: ネストを平坦化して 1 つの extern struct に（`border_thickness`,`border_r`,…）。
  メリット: 生成器が単純。デメリット: フィールド名が冗長・native との対応が見えにくい。
- 案B: ネスト struct をそのまま extern struct のフィールドに持つ。
  メリット: C ABI が native 構造を素直に反映。デメリット: 生成器に再帰的な詰め替えが要る。
- 判断軸: C ABI の素直さ（B）vs 生成器の単純さ（A）。
- 推奨: 未定（consumer が増えてから決める）。

### 完了条件
`Panel.getBorder`/`setBorder` が C から扱える。

---

## #10 Timer（setTimeout / setInterval / clearTimer）
- 状態: 棚上げ
- 優先度: 低
- 影響範囲: 生成器（callback 一般化）＋ preamble、`Application` のイベントループ
- 更新日: 2026-06-02
- 依存: #8（値＋エラー戻りの機構を共有）

### 何
`Application.setTimeout(ms:u32, cb:TimerCallback, user_data:*anyopaque) !TimerId`、`setInterval`、
`clearTimer(id:TimerId)`。`TimerCallback = *const fn(*anyopaque) void`（event 無し・生の関数ポインタ）。
`TimerId = u32`。戻りは `!TimerId`。

### なぜ bespoke（リスナーと違う 3 点）
1. event 無しコールバック（現 `callback` 機構は event 前提）。
2. raw 関数ポインタ登録（typed `addXxxListener(T,f,ud)` 経路でない）。
3. 値＋エラー戻り（`!TimerId`）。

### 候補アプローチ
- `callback` を native_event 省略可に一般化（トランポリン `fn(box){box.fn(box.ud)}`、C は `void(*)(void*)`）。
- 登録種別フラグ（typed listener / raw fnptr）を spec で区別。
- 値＋エラー戻りは out 引数（#8 と共通）。`clearTimer(id:u32)` はスカラ引数で容易。

### 決めること
- one-shot の box 寿命が肝: 発火後に誰がいつ box を解放するか（トランポリンで free か、TimerId 管理で
  clearTimer / 発火後に解放か）。interval は clearTimer まで生存。決めないとリーク or UAF。
- raw-fnptr 登録を spec でどう表すか（`callback … raw` 種別か fn 側注記か）。

### 完了条件
C から setTimeout / setInterval / clearTimer が使え、box がリーク / UAF なく回収される。

作者メモ: あまり使わないので優先度低（後回し可）。

---

## #11 ButtonGroup の公開
- 状態: 棚上げ
- 優先度: 低
- 影響範囲: preamble（bespoke destroy）、`nimbus.api`
- 更新日: 2026-06-02
- 依存: なし

### 何
`ButtonGroup`（ラジオの排他グループ）。`add`/`remove(*ToggleButtonModel)`、`getSelected() ?*ToggleButtonModel`。

### なぜ bespoke
`deinit` + `allocator.destroy` の 2 段破棄で、Component の vtable destroy に乗らない（非 Component）。
汎用 `nmComponentDestroy` が使えず、専用 destroy シムが要る。

### 候補アプローチ
- preamble に `nmButtonGroupDestroy`（deinit + allocator.destroy）を手書き。add/remove/getSelected は
  `?*T` 対応済みなので生成可（getSelected は `?*T` 戻り）。

### 決めること
- 専用 destroy を出すか、`destroy` 構文を「非 Component の deinit + free」型に一般化するか。

### 完了条件
C から buttonGroup を生成・add/remove・getSelected・破棄できる。

備考: RadioButton の排他自体はモデル経由で既に可能（ButtonGroup 未公開でも動く）。

---

## #12 Component の putProperty / getProperty / removeProperty
- 状態: 棚上げ
- 優先度: 低
- 影響範囲: preamble、`nimbus.api`
- 更新日: 2026-06-02
- 依存: なし

### 何
`Component.putProperty(key, *anyopaque)` / `getProperty(key) ?*anyopaque` / `removeProperty(key)`。
任意の `void*` userdata を component に紐づける汎用機構。

### なぜ bespoke
`*anyopaque`（C の `void*`）userdata で apigen のハンドル語彙に乗らない（List の item と同種）。

### 完了条件
C から void* プロパティの put / get / remove ができる。

---

## #13 LayoutManager とレイアウト適用 + Container.setLayout / getLayout
- 状態: 完了
- 優先度: 中
- 影響範囲: `nimbus.api`（opaque `LayoutManager`・enum `nmBorderRegion`、Container / BoxLayout / BorderLayout）
- 更新日: 2026-06-02
- 依存: なし

完了（2026-06-02）: 下記 spec 行どおり追加。opaque 28・生成関数 166。**初の receiver なし生成関数**
（`framework.BoxLayout.horizontal()` を直接呼ぶ）。検証: apigen 決定的・`zig build install`/`test` 緑・
`nimbus.h` を clang で構文チェック（singleton factory・`?*LayoutManager`・region enum・BorderLayout.add）。

### 何
`Container.setLayout(?*LayoutManager)` / `getLayout() ?*LayoutManager`、ビルトインレイアウトの取得
（`BoxLayout.horizontal`/`vertical`、`BorderLayout.get`）、`BorderLayout.add(container, region, child)`。
レイアウトは GUI の中核。

### 分類: A（生成器変更ゼロ）
当初 C（bespoke）と誤記していたが、実コード確認の結果 **A** に訂正（2026-06-02）。理由:
- ビルトインレイアウトは **allocator を取らないプロセス全体のシングルトン**。`BoxLayout.horizontal()` /
  `vertical()` / `BorderLayout.get()` は **receiver なし・引数なし**で `*LayoutManager` を返す（生成器の
  レシーバなしパスで出せる）。これが最初の receiver なし生成関数になる。
- `setLayout(?*LayoutManager)` / `getLayout() ?*LayoutManager` は `?*T` 引数・戻り（実装済み）に乗る。
- 所有: シングルトンは**借用・誰も解放しない**（`Container.deinit` は layout に触れない）→ `@borrowed`・destroy 不要。
- region 配置は `Container.addWithHint` が生 `*anyopaque` hint を使う（void* で bespoke）が、便利関数
  `BorderLayout.add(container, region, child)`（receiver なし static・enum 引数）がその void* を内部で包むので、
  これを公開すれば void* に触れず region 配置できる。

### 具体的な spec 行（すべて A）
```
opaque LayoutManager
enum nmBorderRegion = BorderLayout.Region { north south east west center }
fn nmBoxLayoutHorizontal = BoxLayout.horizontal () -> *LayoutManager @borrowed
fn nmBoxLayoutVertical   = BoxLayout.vertical   () -> *LayoutManager @borrowed
fn nmBorderLayoutGet     = BorderLayout.get     () -> *LayoutManager @borrowed
fn nmContainerSetLayout  = Container.setLayout (&self, layout:?*LayoutManager @borrowed) -> void
fn nmContainerGetLayout  = Container.getLayout (&self) -> ?*LayoutManager @borrowed
fn nmBorderLayoutAdd     = BorderLayout.add (container:*Container, region:nmBorderRegion, child:*Component @transfer) -> void !err
```

### 完了条件
C からビルトインレイアウトを取得して `setLayout` で適用でき、BorderLayout の region 配置ができる。

備考: `Container.addWithHint`（生 void* hint）だけは別途 bespoke（#12 系）。region 配置は上記でカバー済み。

---

## #14 Menu / MenuItem の icon get / set
- 状態: 棚上げ
- 優先度: 低
- 影響範囲: preamble、`nimbus.api`
- 更新日: 2026-06-02
- 依存: なし

### 何
`Menu.getIcon`/`setIcon`、`MenuItem.getIcon`/`setIcon`（`?awt.Image`）。現状 text / model のみ公開。

### なぜ bespoke
`awt.Image` 値の box / unbox が要る（Button の icon と同じ）。Image 関連は既に preamble 手書きなので
同じ手で足せる。

### 完了条件
C から Menu / MenuItem に icon を set / get できる。

---

## #15 投機的な生成器拡張（実需待ち）
- 状態: 棚上げ
- 優先度: 低
- 影響範囲: 生成器 `main.zig`
- 更新日: 2026-06-02
- 依存: なし

### 何
現状 live な consumer が無く、point-of-need で保留している生成器拡張をまとめて記録（実需が出た項目は
個別 item に切り出す）:
- enum の明示値・非連続値・フラグ（ビット或）。
- `@ctor` / `@dtor` を型側 IR に紐づける（現状はファクトリ + 汎用 destroy で代替）。
- コールバックの event に追加 typed 引数を持つ署名（今のリスナーは event 1 個のみ。DnD `onDragStart` 等が候補）。

### なぜ（保留理由）
実需が無い拡張は投機的・検証不能。使う公開メソッドが出た時点で concrete に実装する。

### 完了条件
本 item は index。実需が出た拡張を個別 item として起票・実装する。
