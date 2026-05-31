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
### 何
`awt.Image = { texture: Texture, width: i32, height: i32 }`（GPU テクスチャを包む値型）。
関連 API: `Button.getIcon() ?Image` / `setIcon(?Image)`、`Application.icon(id: lucide.Icon) !Image`、
`Image.fromMemory(allocator, device, bytes)`、`Image.deinit()`（テクスチャを解放）。

### なぜ bespoke
- 値型だが内部に GPU `Texture`（バックエンドハンドル）を持つ。opaque 化するには箱詰めが要り、
  **借用（getIcon は widget 所有のコピー）と所有（loader で作ったもの）が混在**＝ nmImageDestroy の
  意味が一意でない（box だけ free か、texture も deinit か）。
- **C から Image を得る手段が無い**：`icon(id)` の引数 `lucide.Icon` は数百メンバの巨大 enum（公開非現実的）、
  `fromMemory` は device/allocator が要る。→ setIcon に渡す Image を C 側で用意できない。
- `getIcon() ?Image` は値返しなので、ハンドル化すると **alloc-on-return**（確保失敗時に none と error が曖昧）。

### 候補アプローチ
- (A) **opaque ハンドル + 箱詰め**。所有種別をハンドルに持たせ（owned/borrowed）、
  - `setIcon(?Image)`：C は `nmImage*`、シムは deref（箱の所有は移さない）。
  - `getIcon() ?Image`：借用コピーを箱詰めして返す。alloc 失敗は null + last_error。`nmImageDestroy` は box だけ free。
  - **C 用の Image 生成口を手書き**：`nmImage* nmImageLoadPng(const char* path)`（owned → nmImageDestroy で deinit）など。
- (B) 値構造体で texture を opaque フィールド露出 → 内部漏れ・脆く、不採用寄り。

### 決めること
- C から Image を作る入口をどうするか（ファイルパス loader / バイト列 loader、device は内部の Application から取る？）。
- 所有の二系統（loader=owned で deinit / getIcon=borrowed で box のみ free）をハンドルにどう持たせるか。
- lucide ビルトインアイコンの公開方法（enum を出さず、文字列キーか id 整数の薄い API にする等）。

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
