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
`awt.Image = { texture: Texture, width: i32, height: i32 }`（GPU テクスチャを包む値型、awt/src/Image.zig）。
関連 API: `Button.getIcon() ?Image` / `setIcon(?Image)`、`Image.fromMemory(allocator, device, bytes) !Image`、
`Image.deinit()`（texture を解放）、`Application.icon(id: lucide.Icon) !Image`（lucide/icons.zig）。

### 現状の所有モデル（重要・ここを誤解しやすい）
**Image の texture を所有しているのは `Image.fromMemory(...)` を呼んだコードだけ**。`deinit()` を一度呼ぶ
責任もそこにある。widget は借用しているだけで所有しない:
- `Button.icon` は `?awt.Image` を**値で保持**するだけ（Button.zig:28）。
- `setIcon(img)` は `self.icon = img;` で**構造体を値コピー**（= texture handle の借用コピー）。
- `getIcon()` は `return self.icon;` で**借用コピーを値返し**。
- **`Button.destroy` は icon を一切 deinit しない**（Button.zig:291–300 は text / model / button 本体のみ解放）。

したがってライフタイム危険は「**所有者(fromMemory 呼び出し元)が先に free → 借用している widget が
use-after-free**」の向き。widget が死んで texture が消えるのではない。所有者は常に一点（loader 産の
Image 1 個）で、それを destroy するまで texture が生きる、という単純な構造。

### なぜ bespoke
- 値型だが内部に GPU `Texture`（バックエンドハンドル）を持つ。nmColor のような純データ値構造体には
  できない（texture は C にとって意味のある値ではなく、コピーは外部所有の GPU 実体を指す借用になる）。
  opaque ハンドル化するには**箱詰め（heap alloc）**が要る。
- **C から Image を得る手段が無い**：`icon(id)` の引数 `lucide.Icon` は数百メンバの巨大 enum（公開非現実的）、
  `fromMemory` は device/allocator が要る。→ setIcon に渡す Image を C 側で用意できない＝**生成口を手書き必須**。
- `getIcon() ?Image` は値返しなので、借用を返すだけでも **alloc-on-return**（箱を確保 → 失敗時に none と
  error が曖昧）。または借用を `&self.icon` で直接返せば alloc 不要だが、ライフタイムが widget に従属する。

### 候補アプローチ
- (A) **opaque ハンドル + 箱詰め**。所有は一系統（loader 産＝owned のみ）に寄せるのが素直:
  - **C 用の生成口を手書き**：`nmImage* nmImageLoadPng(const char* path)` など（owned → `nmImageDestroy` で
    `Image.deinit`）。device/allocator は内部の Application から取る。
  - `setIcon(?Image)`：C は `nmImage*`、シムは deref して**値コピーを Button に渡す**（所有は移さない＝今の Zig と同じ借用）。
  - `getIcon() ?Image`：同じ texture の借用を返す。box を alloc して返す（失敗は null + last_error）か、
    `&self.icon` 相当で alloc-free にするか（→「決めること」）。
  - `nmImageDestroy` は **loader 産の owned Image にのみ呼ぶ**。setIcon/getIcon の借用には呼ばない。
- (B) 値構造体で texture を opaque フィールド露出 → 内部漏れ・脆く、不採用寄り。

### バインディング側の keep-alive（free/no-free とは別軸）
所有が loader 産一点なので、binding は「**widget が借用先の Image を生かし続ける**」方向に pin する:
```python
btn.set_icon(img)   # 生成器が裏で btn._icon_ref = img を仕込む
                    # img が GC されても Button が参照を持つので texture が残る
```
getIcon が返す借用ラッパーも同じ owner(img) へ keep-alive。`ownership` タグ（owned/borrowed）が
double-free を防ぎ、この keep-alive が use-after-free を防ぐ。2 軸の役割が違う点に注意。

### 決めること
- C から Image を作る入口（ファイルパス loader / バイト列 loader、device は内部の Application から取る？）。
- `getIcon` の借用戻りを **box-alloc で返すか alloc-free（フィールド参照）で返すか**（後者は widget 従属の寿命）。
- binding の keep-alive 規約（setIcon 時に widget → Image を pin、getIcon 戻りも owner へ pin）をどう IR/生成器に持たせるか。
- lucide ビルトインアイコンの公開方法（巨大 enum を出さず、文字列キーか id 整数の薄い API にする等）。

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
