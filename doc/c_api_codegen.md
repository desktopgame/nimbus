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
* `<arg>`: `<name>:<type> [<own>]` 形式。`<type>` は `str` または `*<ZigType>`（ハンドル）。
* `<ret>`: `void` または `*<ZigType>`。
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
| `void`（戻り、`!err`） | `int` | `c_int` | `catch` で `errorToCode`、成功時 `0` |
| `void`（戻り、失敗なし） | `void` | `void` | そのまま呼ぶ |

所有権タグ（`@owned` / `@borrowed` / `@transfer`）は C/Zig のコード生成には影響せず、
IR にのみ出る（バインディングの解放判断に使う。「所有権」参照）。

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
* `casts` — アップキャスト一覧（`from` → `to`）。
* `destructors` — 汎用デストラクタ一覧（`type` のハンドルを破棄する `c` 関数）。
* `callbacks` — 後述。コールバック型の一覧。現状は空配列だが、契約として常に存在する。

## コールバック / イベントハンドラ（設計・コード生成は未実装）
リスナー登録のような「関数ポインタを渡す」API を、1 つの宣言で 3 レイヤーに展開する。

スペックでコールバック型を宣言し、引数で参照する:
```
callback ActionListener = fn ()      # userdata 以外に渡る引数（ActionListener は無し）

fn nmButtonOnAction = Button.addActionListener (&self, cb:ActionListener) -> void !err
```
`cb:ActionListener` という **1 引数**が各レイヤーでこう展開される:

| レイヤー | 形 |
|---|---|
| C ABI | **2 引数**に展開: `void (*cb)(void*), void* userdata` |
| Zig シム | `self.addActionListener(cb, userdata)` にそのまま渡す |
| Python / JS | **1 つの呼び出し可能オブジェクト**。クロージャを `userdata` に詰めて `(fnptr, userdata)` を組み立てる |

IR ではこの引数を `{"type":"callback","callback":"ActionListener","role":"event_handler"}`
と印す。これにより生成器は「ここはネイティブ関数を 1 個の callable として見せる」と判断できる。
これが「イベントハンドラとして使われることを期待する関数ポインタ」の宣言にあたる。

> 現状: 文法と IR 表現は本書で確定。実コード生成（C シムでの 2 引数展開、値戻り＋エラーの
> 表現）は未実装。Zig 側に `fn(*anyopaque)+*anyopaque` を直接取るメソッド（`setTimeout`
> 等）と、リスナー登録経路の統一（typed-callbacks 計画）がそろってから着手する。

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
* `cast`（アップキャスト）と `destroy`（汎用デストラクタ）。
* 所有権タグ `@owned` / `@borrowed` / `@transfer`（→ IR `ownership`）。
* バインディング IR（`bindings/nimbus_api.json`）: 型・継承・関数のクラス対応づけ・
  ターゲット言語名・`casts`・`destructors`・`callbacks`（空配列）。

未対応（文法・IR は本書で確定済みだがコード生成が未実装、もしくは文法ごと今後）:

* コールバック / イベントハンドラ（上記専用セクション）。文法・IR 確定、コード生成未実装。
* `@ctor` / `@dtor` で `nmCreateXxx` / `nmDestroyXxx` を型側 IR に紐づける案
  （現状はファクトリ + 汎用デストラクタで代替。下記の型サポート拡張が前提）。
* 値構造体の引数・戻り（`Color` 等）→ `struct` 宣言と値渡しの写像。
* enum 引数（`Slider.Orientation` 等）。
* int / float / bool などプリミティブ引数、値戻り＋エラー（out 引数かセンチネルか要決定）。
* スライス（`[]const u8`）の**戻り**。`getText` 等。NUL 終端でないため
  `ptr + len` の 2 値か呼び出し側バッファ方式かを別途決める。
* allocator / io を要するブートストラップ系コンストラクタ（上記プリアンブル参照）。
