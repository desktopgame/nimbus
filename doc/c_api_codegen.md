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
tools/apigen/nimbus.api      （入力スペック / ABI 表面の真実）
tools/apigen/preamble.h      （手書き: C ヘッダ前置き）
tools/apigen/preamble.zig    （手書き: Zig ランタイム支援前置き）
        │
        ▼  zig build apigen   （tools/apigen/main.zig を host で実行）
        │
        ├─► include/nimbus.h          = preamble.h  + 生成 typedef/プロトタイプ + 末尾
        ├─► framework/src/c_api.zig   = preamble.zig + 生成 export fn シム
        └─► bindings/nimbus_api.json  = バインディング用 IR（メタデータ一枚）
```
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
`u32` / `bool`。引数（`<name>:<CName>`）や戻り（`-> <CName>`）に使える。
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
* `<arg>`: `<name>:<type> [<own>]` 形式。`<type>` は `str` / `*<ZigType>`（ハンドル）/
  スカラ（`f32`/`f64`/`i32`/`u32`/`bool`）/ 宣言済み値構造体 / 宣言済み enum。
* `<ret>`: `void` / `*<ZigType>` / スカラ / 宣言済み値構造体 / 宣言済み enum。
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
| `*T`（戻り、`!null`） | `nmT*` | `?*framework.T` | `catch` で `null` |
| スカラ（引数・戻り） | `int32_t`/`float`/… | `i32`/`f32`/… | そのまま素通し（変換なし） |
| enum（引数・戻り） | `<CName>`（C enum） | `c_int` | `@enumFromInt` / `@intFromEnum` で変換 |
| 値構造体（引数） | `<CName>` | `<CName>`（extern） | シムがフィールドごとに native へ詰め替え |
| 値構造体（戻り） | `<CName>` | `<CName>`（extern） | native からフィールドごとに詰め替え |
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

> 制約: 現状フィールドはスカラ（`f32`/`f64`/`i32`/`u32`/`bool`）のみ。ネストした構造体・
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

* ランタイム支援（last-error 退避とアクセサ）。
* awt 層への単純なパススルー（`nmGetBackendVersion`）。
* 将来、allocator / io を必要とするブートストラップ的なコンストラクタ
  （`nmAppCreate` 相当）もここに置く想定。これらは引数を C から渡せないため
  機械生成の対象外で、内部でデフォルトの allocator / io を確定する手書きグルーになる。

## 実装済み / 未対応
実装済み（生成器が出力する）:

* opaque 宣言・継承（`: <Parent>` → IR `extends`）。
* `&self` / `=self` / レシーバなしの関数、`str` 引数、ハンドル引数 `*T`、
  `*T`（`!null`）/ `void`（`!err`）戻り。
* スカラ（`f32`/`f64`/`i32`/`u32`/`bool`）の引数・戻り（素通し）。
* enum（`enum` 宣言、int ABI + comptime ドリフト検知、引数・戻り）。
* 値構造体（`struct` 宣言、`extern` 生成 + フィールド詰め替え、引数・戻り）。
* `cast`（アップキャスト）と `destroy`（汎用デストラクタ）。
* 所有権タグ `@owned` / `@borrowed` / `@transfer`（→ IR `ownership`）。
* コールバック / イベントハンドラ（`callback` 宣言、案 C の box + トランポリン、event は不透明 + 手書きアクセサ）。
* バインディング IR（`bindings/nimbus_api.json`）: 型・継承・`structs`・`enums`・`callbacks`・
  関数のクラス対応づけ・ターゲット言語名・`casts`・`destructors`。

未対応（文法・IR は本書で確定済みだがコード生成が未実装、もしくは文法ごと今後）:

* `@ctor` / `@dtor` で `nmCreateXxx` / `nmDestroyXxx` を型側 IR に紐づける案
  （現状はファクトリ + 汎用デストラクタで代替）。
* コールバックの拡張: event に追加 typed 引数を持つ署名、登録の `remove`（解除）エクスポート。
* 値構造体の拡張: ネスト構造体・配列・enum フィールド、値戻り＋エラーの組み合わせ。
* enum の拡張: 明示値・非連続値・フラグ（ビット或）。
* 値（スカラ/enum/struct）戻り＋エラーの組み合わせ（out 引数かセンチネルか要決定。現状は失敗なしのみ）。
* スライス（`[]const u8`）の**戻り**。`getText` 等。NUL 終端でないため
  `ptr + len` の 2 値か呼び出し側バッファ方式かを別途決める。
* allocator / io を要するブートストラップ系コンストラクタ（上記プリアンブル参照）。

## シンボル名の規約: 公開 ABI 名と awt-c 内部名を分ける
かつて awt-c（`glfw_shim.c`）の C 関数が公開 ABI と同じ `nmGetBackendVersion` を名乗っており、
preamble の `export fn nmGetBackendVersion` と衝突して、glfw スタックを引き込む export
（`Application.frame` 等）を公開すると lld が duplicate symbol で落ちた。

解決済み（2026-05-31）: awt-c の C 関数を内部名 `nmAwtBackendVersion` にリネームし、公開名
`nmGetBackendVersion` は preamble の Zig export だけが持つ形にした（`glfw_shim.c` / `internal.h` /
awt `root.zig` の呼び出しを更新）。これにより `Application.frame` 等の Window 系ファクトリも公開できる。

規約: **awt-c の内部 C 関数は公開 ABI 名（`nm` + 機能名）と衝突させない**。awt-c 内部は
`nmAwt...` 等の接頭辞で分け、公開名は preamble の Zig export が単独で持つ。
