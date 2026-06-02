# c_api-codegen
nimbus の公開 C ABI（`include/nimbus.h` と `framework/src/c_api.zig`）と、
他言語バインディング用のメタデータ（`bindings/nimbus_api.json`）を、
独自フォーマットの入力ファイルから決定的に自動生成する仕組みについてまとめる。

C ABI は他言語バインディングの契約そのものなので死守する。
ただしその実体は手で維持するのではなく**生成物として扱う**。
生成器 `tools/apigen` がこの方針を担う。

加えて、Python / JS などのバインディング生成器が必要とする意味情報
（クラスとメソッドの対応づけ、継承、イベントハンドラとして使う関数ポインタ）を
機械可読な IR（JSON）として同時に吐く。各言語バインディングはこの JSON を読むだけで、
Zig も C ヘッダも解析せずに済む。

関連: バインディング全体の設計方針は [binding](framework/doc/binding.md)、
エラーの C ABI 表現は CLAUDE.md「エラーのC_ABIでの表現」を参照。

## 何を真実とするか
2 つの真実を区別する。

* **挙動・シグネチャの真実は Zig 実装**（`framework/src/*.zig` の各メソッド）。
  引数や戻り値の型はここが正であり、生成器はこれを書き換えない。
* **ABI 表面の真実は `tools/apigen/nimbus.api`**。
  「どのメソッドを C に公開するか」「opaque ハンドル名や失敗規約をどうするか」を選択する。

両者がズレた場合、生成されたシムは実際の Zig メソッドを呼ぶので**コンパイル時に必ず落ちる**
（後述「ドリフト検出」）。よって `.api` がシグネチャを二重に持っていても、
サイレントな不整合は起きない。

当初は Zig ソースを `std.zig.Ast` で解析して公開関数を拾う案だったが、
`Color` / `[]const u8` / エラーユニオン / optional などリッチな型の C 写像規則を
生成器に内蔵する必要があり複雑だった。代わりに、公開する関数とその写像を
人間が読み書きできる小さなテキストで明示する方式を採る。

## パイプライン
```
tools/apigen/nimbus.api          （入力スペック / ABI 表面の真実）
tools/apigen/preamble.h          （手書き: C ヘッダ前置き）
tools/apigen/preamble_protos.h   （手書き: C プロト。typedef の後に差し込み）
tools/apigen/preamble.zig        （手書き: Zig ランタイム支援前置き）
tools/apigen/preamble_ir.txt     （手書き: IR エントリ。生成 IR にマージ）
        │
        ▼  zig build apigen   （tools/apigen/main.zig を host で実行）
        │
        ├─► include/nimbus.h          = preamble.h + 生成 typedef + preamble_protos.h + 生成プロト + 末尾
        ├─► framework/src/c_api.zig   = preamble.zig + 生成 export fn シム
        └─► bindings/nimbus_api.json  = 生成 IR に preamble_ir.txt の手書きエントリをマージ
```
手書きと生成は **3 出力すべてでマージ**される（.h は preamble.h/preamble_protos.h、.zig は preamble.zig、
.json は preamble_ir.txt）。手書きコードを足したら preamble_ir.txt にも IR を足す、で対称が保たれる。
生成物 2 ファイルはリポジトリにコミットする。
ABI の変更が PR の差分に現れ、契約の破壊的変更をレビューで検知できるようにするため。

## 運用
1. `tools/apigen/nimbus.api` を編集する（公開する関数を追加・変更）。
2. `zig build apigen` を実行して `include/nimbus.h` と `framework/src/c_api.zig` を再生成する。
3. `zig build`（既定）で `libnimbus` に生成 `c_api.zig` がコンパイル・リンクされることを確認する。
4. 生成物 2 ファイルをコミットする。

生成器は決定的（タイムスタンプ・乱数・ハッシュ順序に依存しない）。
同じ入力からは同じバイト列を出力するので、再生成しても無関係な差分は出ない。

## 入力フォーマット
1 行 1 文。`#` から行末はコメント。空行は無視。

### opaque 宣言
```
opaque <ZigType> [: <Parent>]
```
opaque ハンドルを宣言する。次を出力する。
```c
typedef struct nm<ZigType> nm<ZigType>;
```
ハンドルは常にポインタで ABI を越える。C 側の型名は `nm` + ZigType。

`: <Parent>` は単一継承を記録する（任意）。C ヘッダには影響しないが、IR の
`extends` に出る。これによりバインディング側でクラス継承（親のメソッドを継承、
`asXxx` キャスト）を組み立てられる。例: `opaque Frame : Window`。

### struct 宣言（値構造体・中身を公開する型）
```
struct <CName> { <field>:<scalar> ... }
```
レイアウトを ABI に公開する値型を宣言する。`<scalar>` は `f32` / `f64` / `i32` /
`u32` / `usize` / `bool`。引数（`<name>:<CName>`）や戻り（`-> <CName>`）に使える。
例: `struct nmColor { r:f32 g:f32 b:f32 a:f32 }`。詳細は後述「値構造体」。

### enum 宣言
```
enum <CName> = <NativeZigPath> { <member> ... }
```
ABI を int として越える enum を宣言する。メンバはネイティブの宣言順（値 0,1,2,…）。
`<NativeZigPath>`（framework 相対、例 `Component.Alignment`）に対する comptime チェックを
生成するので、ネイティブ enum の並び替え・改名はビルドエラーになる。詳細は後述「列挙型」。
例: `enum nmAlignment = Component.Alignment { start center end stretch }`。

### 関数宣言
```
fn <CName> = <ZigType>.<method> ( [<recv> ,] <arg>* ) -> <ret> [!<fail>] [<own>]
```
* `<CName>`: 生成される C 関数名。
* `<ZigType>.<method>`: 包む Zig メソッド（`framework.<ZigType>.<method>`）。
* `<recv>`: レシーバ（第一引数 `self`）の渡し方。
  * `&self` — Zig 側 `self: *T`。C 側 `nmT* self`。
  * `=self` — Zig 側 `self: T`（値渡し）。C 側 `const nmT* self`
    （opaque は値で渡せないのでポインタのまま渡し、シムが間接参照する）。
  * 省略時はレシーバなし（静的関数として `framework.<ZigType>.<method>` を呼ぶ）。
* `<arg>`: `<name>:<type> [<own>]` 形式。`<type>` は `str` / `strs`（文字列配列）/
  `*<ZigType>`（ハンドル）/ `?*<ZigType>`（optional ハンドル、nullable ポインタ）/
  スカラ（`f32`/`f64`/`i32`/`u32`/`usize`/`bool`）/ 宣言済み値構造体 /
  `?<値構造体>`（optional、nullable const ポインタ）/ 宣言済み enum。
* `<ret>`: `void` / `*<ZigType>` / `?*<ZigType>`（optional ハンドル、null=none）/ スカラ /
  宣言済み値構造体 / `?<値構造体>`（out 引数 + bool）/ 宣言済み enum /
  `str`（借用 `[]const u8` → `nmStr`）/ `?str`（`?[]const u8` → `nmStr`、none は ptr=null）。
  `?*<ZigType>` 戻りは NULL が none を兼ねるので `!fail` とは併用できない。
* `<fail>`: 失敗の通知方法。省略可。
  * `!null` — 失敗時 NULL を返し `last_error` を設定する（`*T` 戻り向け）。
  * `!err`  — 失敗時 0 以外の int コードを返す（`void` 戻り向け、0 = 成功）。
* `<own>`: 所有権の注記（省略可）。戻りと各引数に付けられる。後述「所有権」参照。
  * `@owned` — 戻りハンドルは呼び出し側が所有する（解放責任あり）。
  * `@borrowed` — 戻りハンドルは借用（解放してはいけない）。
  * `@transfer` — その引数の所有権が呼ばれた側へ移る（`Container.add` の子など）。

### cast 宣言（アップキャスト）
```
cast <CName> = <ZigType>.<field> -> <Target>
```
`&self.<field>` を `*<Target>` ハンドルとして返す 1 行関数を生成する
（例: `cast nmButtonAsComponent = Button.component -> Component`）。
バインディングが任意の widget から Component のメソッドへ到達したり、後述の
`nmComponentDestroy` に渡すための土台。IR の `casts` に出る。

### destroy 宣言（汎用デストラクタ）
```
destroy <CName> = <ZigType>
```
`self.vtable.destroy(self, self.allocator)` を呼ぶ関数を生成する。
vtable ディスパッチなので、Component を持つ任意の widget をこの 1 本で破棄できる
（`destroy nmComponentDestroy = Component`）。IR の `destructors` に出る。

## 型マッピング
現状サポートする写像（PoC 範囲）。

| スペック表記 | C 型 | Zig シム引数/戻り | 備考 |
|---|---|---|---|
| `opaque T`（レシーバ） | `nmT*` | `*framework.T` | ハンドルはポインタ |
| `str`（引数） | `const char*` | `[*:0]const u8` | シムが `std.mem.span` で `[]const u8` に変換 |
| `*T`（引数） | `nmT*` | `*framework.T` | ハンドルをそのまま渡す |
| `?*T`（引数） | `nmT*`（nullable） | `?*framework.T` | NULL=none。そのまま渡す（`Frame.setMenuBar` 等） |
| `*T`（戻り、`!null`） | `nmT*` | `?*framework.T` | `catch` で `null` |
| `?*T`（戻り） | `nmT*`（nullable） | `?*framework.T` | none を NULL で返す。`!fail` 併用不可（`Frame.getMenuBar`/`MenuBar.at` 等） |
| スカラ（引数・戻り） | `int32_t`/`float`/`size_t`/… | `i32`/`f32`/`usize`/… | そのまま素通し（変換なし）。`usize`=`size_t` |
| enum（引数・戻り） | `<CName>`（C enum） | `c_int` | `@enumFromInt` / `@intFromEnum` で変換 |
| 値構造体（引数） | `<CName>` | `<CName>`（extern） | シムがフィールドごとに native へ詰め替え |
| 値構造体（戻り） | `<CName>` | `<CName>`（extern） | native からフィールドごとに詰め替え |
| `str` / `?str`（戻り） | `nmStr {ptr,len}` | `nmStr`（extern） | 借用スライスを ptr+len で返す（コピーなし）。`?str` の none は ptr=null |
| `strs`（引数） | `const char* const*` + `size_t _len` | `[*]const [*:0]const u8` + `usize` | シムが一時 `[][]const u8` を確保→呼出→解放（callee がコピー） |
| `?<struct>`（引数） | `const <CName>*`（nullable） | `?*const <CName>` | null=none。present 時フィールド詰め替え |
| `?<struct>`（戻り） | `bool fn(…, <CName>* out)` | out 引数 + `bool` | present で true + `out` 書込、none で false |
| `void`（戻り、`!err`） | `int` | `c_int` | `catch` で `errorToCode`、成功時 `0` |
| `void`（戻り、失敗なし） | `void` | `void` | そのまま呼ぶ |

所有権タグ（`@owned` / `@borrowed` / `@transfer`）は C/Zig のコード生成には影響せず、
IR にのみ出る（バインディングの解放判断に使う。「所有権」参照）。

## 値構造体（レイアウトを公開する型）
`Color` のように**中身（フィールド）をポインタ越しでなく値で公開する**型の扱い。

通常の Zig `struct` は C ABI 互換のレイアウトが保証されない（`extern struct` のみ保証）。
`awt.Graphics.Color` は普通の struct なので、そのままでは値渡しできない。これを
**native 型に手を入れずに**公開するため、次のようにする。

* `struct nmColor { … }` から **ABI 専用の `extern struct nmColor` を生成**（レイアウト保証）。
* シムが境界でフィールドごとに native と詰め替える。
  * 引数: `nmColor` → `self.setColor(.{ .r = c.r, .g = c.g, … })`（匿名リテラルが native 型に coerce）。
  * 戻り: `const _ret = self.getColor(); return .{ .r = _ret.r, … };`（native → `nmColor`）。
* フィールド名は native と一致させる。ズレると**コンパイルエラー**（ドリフト検知）。
* IR には `structs`（`name` とフィールド）を出すので、Python/JS は `Color(1,0,0,1)` のような
  **中身の見える普通のレコード**として生成できる。

native 型自体を `extern struct` 化する案（変換ゼロ）は不採用。awt の既存型に手を入れる必要があり、
`extern` の制約（デフォルト値・タグ無し enum フィールド等）と「公開する型は extern」という縛りが
native 設計に染み出すため。値型は小さく、詰め替えのコピーコストは実質無視できる。

> 制約: 現状フィールドはスカラ（`f32`/`f64`/`i32`/`u32`/`usize`/`bool`）のみ。ネストした構造体・
> 配列・enum フィールドは未対応。値構造体の戻りと `!fail` の組み合わせも未対応（getter は
> 失敗しない前提）。

## 列挙型（enum）
enum は **ABI を int として越える**。C 側は型付きの `enum` を生成し、Zig シムは `c_int` で
受けて `@enumFromInt` / `@intFromEnum` で native enum と変換する。

* C: `typedef enum { nmAlignment_start, nmAlignment_center, … } nmAlignment;`
* Zig 引数: `a: c_int` → `self.setAlignX(@enumFromInt(a))`（呼び出し先の型に coerce）。
* Zig 戻り: `return @intFromEnum(self.getAlignX());`。

**ドリフト検知**: enum は値が位置依存なので、ネイティブ側を並び替えると ABI の値が**黙って**ずれる。
これを防ぐため、`<NativeZigPath>` に対する comptime チェックを生成する。
```zig
comptime {
    std.debug.assert(@intFromEnum(framework.Component.Alignment.start) == 0);
    std.debug.assert(@intFromEnum(framework.Component.Alignment.center) == 1);
    // …
}
```
メンバを改名すると native のフィールドが解決できずコンパイルエラー、並び替えると assert が
落ちる。つまり値構造体と同じく、ズレはビルドで必ず顕在化する。

IR には `enums`（`name` と `members`＝名前＋値）を出すので、Python/JS は `Alignment.start`
のような列挙として生成できる。

> 制約: スカラのバッキング型は int（C enum）固定。明示値・非連続値・フラグ（ビット或）は未対応。

## 文字列の戻り（借用 nmStr）
`getText` のようなスライス戻り（`[]const u8`）は **`nmStr { const char* ptr; size_t len; }`
を値で返す**。UTF-8、NUL 終端なし、**借用**（source の widget が所有。次の `setText` 等で
無効化されうるので呼び出し側は即コピーする）。`?str`（`?[]const u8`）は none を `ptr == null`
で表す。シムはスライスの `ptr`/`len` を詰めるだけ（コピーも確保もしない）。

これは wxPython / PyGObject 等と同じ「**境界で即コピーし、ターゲット言語が所有する文字列に移す**」
方式。借用で足りるのは変換の一瞬だけ有効ならよいため。IR の戻りには `"ownership": "borrowed"`
（と `?str` は `"optional": true`）が出るので、バインディングは「コピーして free しない」で一様に扱える。

## バインディング用メタデータ（IR）
`bindings/nimbus_api.json` は、Python / JS などのバインディング生成器が読む一枚の IR。
**Zig パーサも C ヘッダ解析も不要**で消費できるよう JSON にしている。
バインディングは別リポジトリ・別マイルストーン（[binding](framework/doc/binding.md)）だが、
この JSON を入力に取ることで「nimbus core が変わったら JSON も変わる」一点だけ追えばよい。

形（実際の出力）:
```json
{
  "types": [
    { "name": "Component", "c": "nmComponent", "extends": null },
    { "name": "Button", "c": "nmButton", "extends": "Component" }
  ],
  "callbacks": [],
  "functions": [
    {
      "c": "nmAppButton", "owner": "Application", "method": "button",
      "names": { "py": "button", "js": "button" },
      "kind": "method", "receiver": "ptr",
      "params": [{ "name": "text", "type": "str" }],
      "ret": { "type": "handle", "handle": "Button", "ownership": "owned" }, "fail": "null"
    },
    {
      "c": "nmContainerAdd", "owner": "Container", "method": "add",
      "names": { "py": "add", "js": "add" },
      "kind": "method", "receiver": "ptr",
      "params": [{ "name": "child", "type": "handle", "handle": "Component", "ownership": "transfer" }],
      "ret": { "type": "void" }, "fail": "err"
    }
  ],
  "casts": [
    { "c": "nmButtonAsComponent", "from": "Button", "to": "Component" }
  ],
  "destructors": [
    { "c": "nmComponentDestroy", "type": "Component" }
  ]
}
```

意味:
* `types[].extends` — 継承。バインディングのクラス階層と `asXxx` の土台。
* `functions[].owner` / `method` / `kind` — **クラスとメソッドの対応づけ**。
  `owner` でグルーピングし、`kind` が `method`（`self` あり）か `static` かを区別する。
* `functions[].names` — ターゲット言語のメソッド名。`js` は Zig の camelCase をそのまま、
  `py` は snake_case に機械変換（`setText`→`set_text`）。将来スペックで上書きできるようにする。
* `functions[].ret.type == "handle"` — そのメソッドはハンドルを生む「ファクトリ」だと分かる
  （例: `Application.button -> Button`）。バインディングは `app.button(...)` でも
  `nimbus.Button(app, ...)` でも、この 1 関数に対応づけできる。
* `ownership`（戻り・引数）— `@owned` / `@borrowed` / `@transfer`。バインディングの
  解放判断（後述「所有権」）。未指定なら出ない（既定の慣習に従う）。
* `structs` — 値構造体の一覧（`name` とフィールド）。引数・戻りは `"type":"struct"`,
  `"struct":"<name>"` で参照する。バインディングは中身の見えるレコードとして生成できる。
* `enums` — enum の一覧（`name` と `members`＝名前＋値）。引数・戻りは `"type":"enum"`,
  `"enum":"<name>"` で参照する。
* `casts` — アップキャスト一覧（`from` → `to`）。
* `destructors` — 汎用デストラクタ一覧（`type` のハンドルを破棄する `c` 関数）。
* `callbacks` — 後述。コールバック型の一覧。現状は空配列だが、契約として常に存在する。

### 手書き関数の IR（preamble_ir.txt のマージ）
preamble に手書きした関数（Image / icon・List / CellFactory 等）は spec を通らないので、
そのままでは IR に出ない。これを埋めるため `tools/apigen/preamble_ir.txt` に**手書きの IR エントリ**を
置き、生成器が各配列（`functions` など）の生成分の**後ろにマージ**する（.h / .zig の preamble と同じ
発想の、JSON 版の前置き）。

* 形式: `@<section>` 行（`@functions` / `@types` / …）に続けて、その配列の生 JSON 要素を**そのまま**書く
  （生成分と同じ字下げ・カンマ区切り）。`@` より前の行はコメントとして無視。
* 手書きエントリには `"impl": "manual"` を付ける（生成分には付かない＝由来が一目で分かる）。
* 生成器が表現できない型は**説明的な型文字列**で書き、バインディング生成器が特別扱いする:
  `bytes`（ptr+len バイト列）・`opaque_ptr`（`void*` userdata / item）・`cell_factory`（nmCellFactory 構造体）・
  `i64` / `usize`（生成スカラ集合外の整数）・`enum`+`nmIcon`（手書き curated enum）。
* **同期責任**: 手書きコード（preamble.zig / preamble_protos.h）と preamble_ir.txt は人手で一致させる
  （`.h` プロトと `.zig` 実装を一致させるのと同じ手作業）。生成器は IR の妥当性チェックまではしないので、
  追加後は `bindings/nimbus_api.json` を JSON パーサで検証する運用とする。

> 限界: マージは「既存の配列へ要素を足す」だけ。生成器が型として知らない構造体（`nmCell` 等の関数ポインタ
> 構造体）の**完全な形**は IR には出さず、関数引数を `cell_factory` 等の文字列で指し、構造体の具体形は本書
> （「List / CellFactory」）に委ねる。真に bespoke な型は結局どの言語バインディングでも手当てが要るため。

## コールバック / イベントハンドラ（実装済み・案 C）
リスナー登録のような「関数ポインタを渡す」API を、1 つの宣言で各レイヤーへ展開する。
ネイティブ前提は整っている: Model のリスナーは `fn(user_data: *anyopaque, event: *const Event) void`
に統一され、保存・dispatch 形が C_ABI 契約の形そのもの（`framework/doc/model.md` / `doc/typed_callbacks.md`）。

スペック:
```
callback nmChangeListener = ChangeListenerList.Event   # native の event 型

fn nmComboBoxOnChange = ComboBox.addChangeListener (&self, cb:nmChangeListener) -> void !err
```
`cb:nmChangeListener` という **1 引数**が各レイヤーでこう展開される:

| レイヤー | 形 |
|---|---|
| C ABI | `typedef struct {{ void (*fn)(void* userdata, const void* event); void* userdata; }} nmChangeListener;` の**ポインタ**を渡す。event は不透明 `const void*`（`nmEventKind`/`nmEventSource` で読む） |
| Zig（生成） | 署名ごとに box (`extern struct`) と Zig 規約トランポリン `fn(*box, *const NativeEvent)` を生成。トランポリンは型付きリスナーそのものなので **typed `addXxxListener(T, f, ud)` にそのまま渡せる**（raw 登録不要）。`callconv(.c)` は box の `fn` フィールド型 1 か所だけ |
| Zig シム | `self.addChangeListener(nmChangeListener, nm_trampoline_nmChangeListener, cb)` を呼ぶ（cb が user_data） |
| Python / JS | **1 つの呼び出し可能オブジェクト**。box をバインディングが所有し、クロージャを userdata に詰め、`remove` 時に解放 |

event を C 側へ変換せず**不透明ポインタのまま渡す**のが要点（native の `*const Event` をそのまま）。
フィールドは preamble 手書きのアクセサ（`nmEventKind` / `nmEventSource`）で読む。Event は固定の
framework 型（source ポインタ + enum）で codegen 向きのスカラ構造体でないため、これだけ手書き。

IR ではこの引数を `{"type":"callback","callback":"nmChangeListener","role":"event_handler"}` と印し、
`callbacks` 配列に出す（署名ごとに box + トランポリン + C 関数ポインタ型が 1 セット）。検証:
`ComboBox.addChangeListener` を生成 → libnimbus ビルド成功（トランポリンが typed 登録に型整合）。

> 未対応: event に追加の typed 引数を持つコールバック（現状 nimbus のリスナーは event 1 個のみ）。
> 値戻り＋エラーを伴う登録（`setTimeout` の `!TimerId` 等）。リスナーの `remove`（解除）エクスポート。

## Image / icon（実装済み・手書き bespoke）
`awt.Image`（GPU テクスチャを包む値型 `{ texture, width, height }`）と、それを使う
`Button.getIcon`/`setIcon`・`Application.icon` の C ABI。**ハンドル typedef `nmImage` は生成**
（spec に `opaque Image` の 1 行）だが、**関数群はすべて preamble に手書き**する。

### なぜ生成せず手書きか
どれも apigen の語彙（「ネイティブメソッドを呼ぶシム」）に乗らないため。

* `getIcon` は **optional フィールドのアドレスを返す**（メソッド呼び出しではない。`&self.icon.?`）。
* `setIcon(?Image)` は **optional ハンドルを deref** して `?awt.Image` 値に詰め替える。
* loader は値返し（`Image.fromMemory` は `!Image`）を **heap に box** して所有ハンドルにする。
* `Application.icon` は**メソッドを呼んだ後にキャッシュスロットのアドレスを返す**借用。

### 所有モデル（owned 一系統 + 借用）
Image の入口は 3 つ、所有は **owned（loader 産のみ）/ 残りは全部借用** にきれいに割れる。

| 入口 | texture の所有者 | C ハンドル | `nmImageDestroy` |
|---|---|---|---|
| `nmAppLoadImage(app, bytes, len)` | 呼び出し側 owned | heap box（確保あり） | **する** |
| `nmAppIcon(app, id)` / `nmAppIconNamed(app, name)` | App の `icon_cache` | 借用 = キャッシュ参照 | しない |
| `nmButtonGetIcon(btn)` | 元の owner | 借用 = `&button.icon` | しない |

借用 2 つは安定アドレスへの裸ポインタで、**box を確保しない**（alloc は loader 産だけが払う）。
`Button.getIcon`/`setIcon` は値コピー（借用）で、`Button` は texture を所有も解放もしない
（`Button.destroy` は icon を deinit しない）。`Application.icon` は cache 所有・App.deinit で解放
（コメントにも `do not call deinit` と明記）。危険の向きは「owner が先に free → 借用が
use-after-free」。バインディングは「widget → Image を pin」する keep-alive でこれを防ぐ。
所有権タグ（`@owned`/`@borrowed`）が double-free を、keep-alive が use-after-free を防ぐ別軸。

### lucide アイコン引数: curated enum + 文字列フォールバック
`lucide.Icon` は ~1700 メンバの巨大 enum（自動生成、各 variant が PNG）。**全 enum 露出は不採用** —
メンバ順を**上流が所有**するため、lucide 更新で int 値がズレ、shared-lib + バインディングで「黙って
違うアイコンが出る」ABI 破壊になる（`nmAlignment` は nimbus 所有 4 個なので安全、という違い）。
代わりに 2 入口:

* **curated `nmIcon`**（nimbus 所有・補完が効く小さな安定 enum、種は CLAUDE.md ビルトインアセット
  open/save/save_as/undo/redo/cut/copy/paste）。順序を nimbus が所有するので値が安定（追加は末尾）。
  メンバは lucide 実名へ写像する（`cut → scissors`, `paste → clipboard_paste`,
  `open → folder_open`, `save_as → save_all`）。
* **`nmAppIconNamed(name)`**（文字列フォールバック）。int の ABI 値を持たず、契約は文字列名。
  lucide が改名/削除しても黙って誤アイコンではなく**明示エラー**（`stringToEnum` → null →
  NULL + last_error）になり、むしろ堅い。

`nmIcon → lucide.Icon` の写像は preamble 手書きの `switch`。各腕が `lucide.Icon.scissors` 等を
**直接参照する**ので、上流の改名/削除は**コンパイルエラー**＝ドリフト検知（生成 enum の comptime
assert と同じ役割を手書き switch が担う）。バインディングは型で振り分けてメソッド 1 個に統合できる
（`app.icon(Icon.SAVE)` / `app.icon("circle_plus")`）。

> IR について: `opaque Image` により `nmImage`（型）は生成で IR に出る。Image メソッド群
> （load/destroy/width/height/getIcon/setIcon/icon/iconNamed）は手書きだが、**`preamble_ir.txt` に手書き
> IR エントリを置いて IR にマージ**している（`"impl":"manual"`、上記「バインディング用メタデータ」）。
> `nmIcon` 自体（enum 定義）は IR には出さず、引数で `"type":"enum","enum":"nmIcon"` と参照するに留める
> （curated enum を生成に乗せる「名前マップ型 enum」機能は、消費者が手書きだけのうちは未実装）。

## List / CellFactory（実装済み・手書き bespoke）
`List`（JavaFX VirtualFlow 方式: 可視範囲のセルだけ実体化し、スクロールで recycle）と
その `ListModel` の C ABI。**ハンドル typedef・rowHeight・change-listener・Component upcast は生成**
（spec の `opaque List : Component` / `opaque ListModel` / `fn nmListGet・SetRowHeight` /
`fn nmListOnChange・OffChange` / `cast nmListAsComponent`）だが、**factory / cell / model / 選択 API は
preamble に手書き**する。

### なぜ生成せず手書きか
* **「インターフェースを返すインターフェース」**: `CellFactory.create` が `Cell`（さらに関数ポインタ
  `update`/`destroy` + 状態を持つ）を返す。`callback` 機構（box + トランポリン 1 段）では表せない。
* インデックスが軒並み **`usize`**（apigen のスカラ集合 f32/f64/i32/u32/bool に無い）。
* `ListModel` の item は **`*anyopaque`**（C の `void*`。利用者の行データ）で、apigen のハンドル引数
  （`*framework.T`）にも値構造体にも当てはまらない。
* 選択は `?usize`（optional スカラ）で未対応形。

### C 側の cell プロトコル
利用者が factory を渡し、List が「セルを 1 個作る／行に bind する／壊す」を駆動する。

```c
typedef struct { nmList* list; void* value; size_t index; bool selected; bool focused; } nmCellContext;
typedef struct {
    void* component;                                  /* セル subtree 根。NULL = 生成失敗 */
    void (*update)(void* cell_ud, const nmCellContext* ctx);
    void (*destroy)(void* cell_ud);
    void* user_data;                                  /* セル状態。利用者所有・destroy で解放 */
} nmCell;
typedef struct { nmCell (*create)(void* factory_ud); void* factory_ud; } nmCellFactory;
```
* `value` は `nmListModelAdd` に渡した `void*`（利用者の行構造体へキャストし直す）。
* `update` は recycle のたびに呼ばれる（JavaFX `updateItem`）。`destroy` は `component` の解体
  （`nmComponentDestroy`）と `user_data` の解放の両方を行う。
* `create` は失敗時 `component == NULL` の `nmCell` を返す（native 側は `error` 化し、その行は
  そのフレーム materialize しない＝graceful）。

### アダプタ（手書き Zig）
C の関数ポインタ群を native の `List.CellFactory` / `List.Cell`（Zig fnptr）へ橋渡しする。

* 1 段目: native `CellFactory.create` を `nm_list_factory_create` に。native の `user_data` には
  **C の `nmCellFactory*` をそのまま入れる**（factory は借用＝利用者が List 寿命まで保持。box 不要）。
* 2 段目: C の `create` が返す `nmCell` を **heap に box**（native `Cell.user_data` は単一ポインタなので、
  C の `update`/`destroy`/`user_data` を箱に詰める）。`nm_list_cell_update` が native `CellContext` を
  C 構造体へ詰め替えて C へ、`nm_list_cell_destroy` が C の destroy を呼んでから箱を解放。
* このアダプタは戻り値・引数が native の `List.Cell` / `CellContext` に**型チェックされる**ので、
  cell プロトコルとのズレ（フィールド名・署名）は**コンパイルエラー**になる（ドリフト検知）。

### 関数（手書き）
`nmAppList(app, factory) → nmList*`（内部 ListModel を所有）、`nmListGetModel`、
`nmListGetSelected`（-1 = 無選択）/ `nmListSetSelected`（<0 でクリア）、`nmListEdit`、
`nmListModelAdd`（`void*` item、失敗で非 0）/ `Remove` / `Clear` / `Move` / `GetSize` /
`GetElementAt`（範囲外で NULL）。破棄は `nmListAsComponent` → `nmComponentDestroy`
（List が pool の全セル destroy・所有 model 解放まで行う）。

手書き関数（`nmAppList` / `nmListGetModel` / `nmListModel*` / 選択 / edit）は **`preamble_ir.txt` に手書き
IR エントリを置いて IR にマージ**している（`"impl":"manual"`）。factory 引数は IR 上 `"type":"cell_factory"`
と印すに留め、`nmCell` 等の関数ポインタ構造体の具体形は本節に委ねる（真に bespoke なため）。

> 制約: セル編集（`Cell.edit` = テキスト編集の durational セッション）は C ABI 未公開（v1 のセルは
> 読み取り専用 / atomic write-back のみ）。スクロールには `ScrollPane` のラップが要るが、未公開
> （ScrollPane の Component upcast は `&self.container.component` の 2 段で単一 `cast` に乗らない。別途）。

## init / deinit（コンストラクタ・デストラクタ）の見せ方
Zig には 2 つの生成の流儀がある。

* `create` / `destroy` — ヒープに確保して `*T`（ハンドル）を返す。**これだけが C ABI を
  ハンドルとして越える。**
* `init` / `deinit` — 値型（`Button` を値で返す、各 model）。値返しはハンドルにできないので
  当面は内部扱い（箱詰めが要る）。

→ 規則: **ポインタを返すコンストラクタだけがハンドル ctor になる。**

### 構築 = ファクトリ（型サポート不要）
nimbus の実際の構築経路は `Application` のファクトリ（`app.button(text)`）で、ここが
allocator とデフォルト（font/color）を供給する。つまり `Button.create(allocator, …)` を
直接公開する必要はなく、**ファクトリがバインディングのコンストラクタになる**。
`nimbus.Button(app, "x")` → `nmAppButton` に対応づけるだけ。IR では戻りが
`ret.type == "handle"` であることでファクトリだと判別できる（型サポート拡張は不要）。

### 破棄 = 単一の汎用デストラクタ + アップキャスト（実装済み）
`Container.deinit` が子を `component.vtable.destroy(component, allocator)` で解放するとおり、
**vtable 経由の破棄は全 widget 共通の入口**。よって破棄 API は 1 本に集約する。

* `destroy nmComponentDestroy = Component` → 任意の widget を `nmComponent*` で破棄。
* `cast nmXxxAsComponent = Xxx.component -> Component` → 各型から `nmComponent*` への upcast。

バインディングは `__del__` でアップキャスト → `nmComponentDestroy` を呼ぶ。allocator は
Component に保持されているので C から渡す必要はない。

### 所有権（ライフタイム）
nimbus のライフタイムは「木の所有」: `container.add(child)` で子の所有権はコンテナへ移り、
コンテナ（最終的には Frame / Application）が解放する。add していない単独 widget だけ
呼び出し側が解放する。一部の戻りは借用（`app.icon()` は「deinit するな」）。

このため `__del__` が無条件に解放すると二重解放になる。そこで所有権の移動を
**spec → IR に明示**し、バインディングが「所有フラグ」を自動管理できるようにする。

* 戻り `@owned` / `@borrowed`、引数 `@transfer` を `.api` に付ける（IR の `ownership` に出る）。
* 既定の慣習（未指定時）: ハンドル戻り = owned、ハンドル引数 = borrowed。`@transfer` で上書き。
* 典型: `Application.button -> *Button @owned`、`Container.add(child:*Component @transfer)`、
  借用を返す getter は `@borrowed`。

> 未実装: `@ctor` / `@dtor` で `nmCreateXxx` / `nmDestroyXxx`（CLAUDE.md）を型側 IR に
> 紐づける案。実 `create` が allocator / font / Color を取るため、これは型サポート拡張
> （`struct` 値・allocator）が入ってから。現状は上記ファクトリ + 汎用デストラクタで足りる。

## 失敗規約
CLAUDE.md「エラーのC_ABIでの表現」に従う。
失敗は NULL もしくは 0 以外の int で C に伝え、詳細は thread-local に退避する。
退避と取り出しのランタイム支援は `tools/apigen/preamble.zig` に手書きで置く。

* `setLastError(err)` / `errorToCode(err)` — 退避とコード変換（手書き、表は随時拡張）。
* `nmLastErrorCode()` / `nmLastErrorMessage()` — C から取り出す（手書き export）。

## ドリフト検出
生成された各シムは実際の Zig メソッドを呼ぶ（例: `self.setText(std.mem.span(text))`）。
`.api` の記述が実体のシグネチャとズレると、生成 `c_api.zig` のコンパイルが落ちる。
したがって「`.api` が古い／間違っている」状態はビルドで必ず顕在化し、サイレントには通らない。

## 手書きプリアンブルの役割
機械的に導けないものはプリアンブルに手書きで置き、生成器がその後ろに生成物を連結する。
preamble は 4 ファイルに分かれる: `preamble.h`（C ヘッダ先頭＝include / `nmStr` / extern C 開き）、
`preamble_protos.h`（手書き C プロトタイプ。**opaque typedef を参照できるよう生成器が型定義の後に差し込む**）、
`preamble.zig`（Zig 実装）、`preamble_ir.txt`（手書き IR エントリ。生成 IR の各配列にマージ。上記
「手書き関数の IR」）。手書きコードを足したら preamble_ir.txt にも IR を足すことで、.h / .zig / .json の
**3 出力すべてで手書き + 生成がマージ**される。

* ランタイム支援（last-error 退避とアクセサ）。
* awt 層への単純なパススルー（`nmGetBackendVersion`）。
* イベントの不透明アクセサ（`nmEventKind` / `nmEventSource`）。
* **ブートストラップ（実装済み）**: `nmAppCreate` / `nmAppDestroy`。`Application.init` は
  allocator / io を要し C から渡せないため手書き。既定は libc allocator
  （`std.heap.c_allocator`）+ std の単一スレッド Io（`std.Io.Threaded.global_single_threaded`、
  nimbus は単一 UI スレッドなので適合）。`nmAppRun` は生成（`run()` は素の `!void` メソッド）。
* **Image / icon（実装済み・bespoke）**: `nmAppLoadImage` / `nmImageDestroy` / `nmImageWidth` /
  `nmImageHeight` / `nmAppIcon` / `nmAppIconNamed` / `nmButtonGetIcon` / `nmButtonSetIcon`、および
  curated `nmIcon` enum と `nmIconToLucide` 写像。フィールドアドレス返し・optional deref・値返しの
  box 化・キャッシュ参照返しで生成に乗らないため手書き（上記「Image / icon」）。`nmImage` typedef
  だけは `opaque Image` で生成。
* **List / CellFactory（実装済み・bespoke）**: cell プロトコル構造体（`nmCell` / `nmCellContext` /
  `nmCellFactory`）と C↔native アダプタ（`nm_list_factory_create` / `nm_list_cell_update` /
  `nm_list_cell_destroy`）、`nmAppList` / `nmListGetModel` / `nmListGet・SetSelected` / `nmListEdit` /
  `nmListModel*`。インターフェースを返すインターフェース・`usize` index・`void*` item で生成に乗らない
  （上記「List / CellFactory」）。typedef・rowHeight・change-listener・upcast は生成。

## 実装済み / 未対応
実装済み（生成器が出力する）:

* opaque 宣言・継承（`: <Parent>` → IR `extends`）。
* `&self` / `=self` / レシーバなしの関数、`str` 引数、ハンドル引数 `*T` / `?*T`、
  `*T`（`!null`）/ `?*T`（optional ハンドル、null=none）/ `void`（`!err`）戻り。
  `?*T` は Frame / Window のメニューバー API（`nmFrameSetMenuBar` 等）や `MenuBar.at` で使用。
* スカラ（`f32`/`f64`/`i32`/`u32`/`usize`/`bool`）の引数・戻り（素通し）。`usize` は C `size_t`
  （index / count / size 系。`ComboBox` の index API や `List.edit` で使用）。
* enum（`enum` 宣言、int ABI + comptime ドリフト検知、引数・戻り）。
* 値構造体（`struct` 宣言、`extern` 生成 + フィールド詰め替え、引数・戻り）。
* 文字列の**戻り** `str` / `?str`（借用 `nmStr {ptr,len}`、上記「文字列の戻り」）。
* 文字列**配列**引数 `strs`（`const char* const*` + count、一時スライス変換）。
* optional 値構造体 `?<struct>`（引数=nullable const ポインタ、戻り=out 引数 + bool）。
* `cast`（アップキャスト）と `destroy`（汎用デストラクタ）。
* 所有権タグ `@owned` / `@borrowed` / `@transfer`（→ IR `ownership`）。
* コールバック / イベントハンドラ（`callback` 宣言、案 C の box + トランポリン、event は不透明 + 手書きアクセサ）。
  登録解除（`remove`）も同じコールバック引数（box ポインタで一致削除）で生成可。
* ブートストラップ: `nmAppCreate` / `nmAppDestroy`（手書き）+ `nmAppRun`（生成）。C だけで
  create → 操作 → run → destroy が到達可能。
* Image / icon（手書き bespoke。`nmImage` typedef のみ生成）: 画像ロード・破棄・寸法、
  Button の icon 取得/設定、ビルトイン icon（curated `nmIcon` + 文字列フォールバック）。
  上記「Image / icon」。
* List / CellFactory（手書き bespoke。typedef・rowHeight・change-listener・upcast は生成）:
  cell プロトコル（factory→cell の 2 段アダプタ）・ListModel・選択。上記「List / CellFactory」。
* バインディング IR（`bindings/nimbus_api.json`）: 型・継承・`structs`・`enums`・`callbacks`・
  関数のクラス対応づけ・ターゲット言語名・`casts`・`destructors`。
* 手書き関数の IR マージ（`preamble_ir.txt` の `@section` エントリを生成 IR の各配列に連結。
  `"impl":"manual"` 印・説明的型文字列。上記「手書き関数の IR」）。これで .h / .zig / .json の
  3 出力すべてで手書き + 生成がマージされる。

未対応（文法・IR は本書で確定済みだがコード生成が未実装、もしくは文法ごと今後）:

* `@ctor` / `@dtor` で `nmCreateXxx` / `nmDestroyXxx` を型側 IR に紐づける案
  （現状はファクトリ + 汎用デストラクタで代替）。
* コールバックの拡張: event に追加 typed 引数を持つ署名（`remove`/解除はコールバック引数の再利用で対応済み）。
* 値構造体の拡張: ネスト構造体・配列・enum フィールド、値戻り＋エラーの組み合わせ。
* enum の拡張: 明示値・非連続値・フラグ（ビット或）。
* 値（スカラ/enum/struct/str）戻り＋エラーの組み合わせ（out 引数かセンチネルか要決定。現状は失敗なしのみ）。
* 名前マップ型 curated enum（`nmIcon` を生成に乗せ IR にも出す）— 現状は手書き preamble。上記「Image / icon」。
* List のセル編集（`Cell.edit`）・`ScrollPane` ラップ — 上記「List / CellFactory」制約。
* Timer（`setTimeout` の event 無し callback + `!TimerId` 値戻り）— bespoke。棚上げ（`doc/c_api_codegen_backlog.md` #6b）。

## シンボル名の規約: 公開 ABI 名と awt-c 内部名を分ける
かつて awt-c（`glfw_shim.c`）の C 関数が公開 ABI と同じ `nmGetBackendVersion` を名乗っており、
preamble の `export fn nmGetBackendVersion` と衝突して、glfw スタックを引き込む export
（`Application.frame` 等）を公開すると lld が duplicate symbol で落ちた。

解決済み（2026-05-31）: awt-c の C 関数を内部名 `nmAwtBackendVersion` にリネームし、公開名
`nmGetBackendVersion` は preamble の Zig export だけが持つ形にした（`glfw_shim.c` / `internal.h` /
awt `root.zig` の呼び出しを更新）。これにより `Application.frame` 等の Window 系ファクトリも公開できる。

規約: **awt-c の内部 C 関数は公開 ABI 名（`nm` + 機能名）と衝突させない**。awt-c 内部は
`nmAwt...` 等の接頭辞で分け、公開名は preamble の Zig export が単独で持つ。
