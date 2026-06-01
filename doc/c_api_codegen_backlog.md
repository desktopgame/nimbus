# c_api-codegen バックログ（棚上げ案件）
apigen（[c_api_codegen.md](c_api_codegen.md)）で**後回しにした項目**のメモ。
2026-05-31 時点で `#1` ブートストラップ / `#2` 文字列戻り / `#3` 文字列配列引数 / `#5` optional 値構造体 /
`#6c` リスナー remove は実装済み。ここに残すのは「bespoke（機械生成に乗りにくく、手書きアダプタや
設計判断が要る）」3 件と、軽微な未対応の一覧。明日以降の検討用。

各項目は「何 / なぜ bespoke / 候補アプローチ / 決めること」で書く。

---

## #4 List の CellFactory
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
所有モデルは確定。残る未決は lucide 引数の出し方 1 点のみ（→「決めること」）。

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

### 決めること（残り 1 点）
- **lucide ビルトインアイコン引数の出し方**。`lucide.Icon` は数百メンバの巨大 enum で、そのまま C/Python に
  出すのは非現実的。候補: 文字列キー / 整数 id の薄い API / よく使う一部だけ curate。ここだけ未決。

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
