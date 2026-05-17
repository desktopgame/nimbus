# nimbus
このプロジェクトは Swing や wxWidgets のようなクロスプラットフォームGUIフレームワークを作るのが目標です。
実装には c, zig を使う予定です。
将来的には python や js 向けのバインディングも提供したいです。

## 目指すゴール
Swing の次の特徴を引き継いだものにしたいと思っています。
* 非即時UI（Retained UI）
* 便利なレイアウトマネージャ（BoxLayout, BorderLayout, GridBagLayout）
* コンポーネントのカスタムペイント（paintComponent）
* コードドリブン、手続き型のレイアウトの実装
* ルックアンドフィールの切り替え

逆に、以下はそのまま取り入れずに改善したいです。
* 複雑なレイアウト設定（minimumSize, preferredSize, maximumSize）

その他、やってみたいこと。
* 手続き型のレイアウトAPIをラップする形で、宣言型なレイアウトAPIも作りたい。

## リポジトリ構成
nimbus は以下3つのモジュールで構成されます。
* framework
* awt
* awt-c

### framework
framework はもっとも抽象的なレイヤーです。
Swing でいうところの JComponent, JContainer, JFrame, JButton... などがここで定義されます。

### awt
awt はウィンドウシステム、描画バックエンド、入力イベントを抽象化するレイヤーです。
MouseEvent, KeyEvent, Window, Graphics... などがここで定義されます。
※ここでのWindowは描画先のスワップチェインとしての機能のみ。レイアウトなどはない。
また、 awt は awt-c に依存する形で実装されます。

### awt-c
awt-c は glfw や freetype の薄いラッパーです。
なぜこれが必要かというと、 zig にあるC言語との連携機能、cImport/cIncludeは複雑なヘッダーをパース出来ないからです。
なので、このレイヤーでは内部的に glfw, freetype などに依存するものの、それらは .c からのみインクルードします。
zig 向けに公開されるヘッダーではそれらを直接露出しない設計になります。

## ビルド
内部で glfw や freetype を必要としますが、パッケージマネージャを使わずにソースコードをリポジトリ以下に展開します。
バージョンの固定が簡単かつ、将来サービスが落ちたり変わったりしても確実にビルド環境を保存できるメリットがあります。

## プラットフォーム
Windows(DirectX12), Mac(Metal)をまずはサポートする。
両方とも動作確認済み（hello でウィンドウに 'A' が表示される）。
Linuxはあとまわし。

また、シェーダーコードはそれぞれの言語ごとに用意する。
ユーザー定義のシェーダーは存在せず、ビルトインのみ。

## コーディング規約

### 共通
コード中のコメントは英語で書く。言語は問わずすべてのソース（C / Zig / シェーダー等）に適用される。
（CLAUDE.md など Markdown ドキュメントはこの限りではない。）

### C
インクルードガードはプラグマを使う。
````h
#pragma once
````

プレフィックスとして `nm` を用いる。
```h
#define NM_SYMBOL
typedef enum nmEnum;
typedef struct nmStruct;
````

関数のプレフィックスもこのルールに従う。
加えて、メソッドとして振舞う関数についてはさらに以下の規則に従う。
* 第一引数の名前は常に `self` とする。
* 常に nm{struct_name}Xxx という形式の名前にする必要は**ない**
```h
void nmInitStruct(nmStruct* self)
```

公開 API（`internal.h` などのヘッダーで宣言され、Zig 層から参照されるもの）は `nm` + PascalCase。
それに対し、モジュール内部や `.c` ファイル間でのみ共有される非公開のヘルパは `nm_` + snake_case にする。
内部用であることがひと目で分かり、公開 API と混じらない。
```c
/* public API (declared in internal.h) */
nmDevice* nmCreateDevice(void);

/* internal helper (declared in dx12_internal.h, shared between dx12_*.c only) */
void nm_log(nmLogLevel level, const char* category, const char* fmt, ...);
void nm_transition(nmCommandBuffer* cb, nmRenderTarget* rt, D3D12_RESOURCE_STATES new_state);
```

引数を取らない関数は `(void)` を明示する。
（C99/C11 では `foo()` は「引数情報なし」という古い意味になり引数チェックが効かないため。）
```h
int nmInitAwt(void);
```

整数型は基本 `int` を使う。次のような明確な理由がある場合のみ明示幅型を使う。
* バイト数や容量を表す: `size_t`
* 2^31 を超え得る値: `int64_t` / `uint64_t`
* メモリレイアウトが契約に含まれる (シリアライズ等): `int32_t` 等
* DX12 等の外部 API がそうなっている場合

真偽値は `<stdbool.h>` の `bool` を使う。`int` で代用しない。
公開 API の引数・戻り値・構造体メンバ、内部の状態フラグも同様。
代入には `true` / `false` を使い、`0` / `1` リテラルでの代入は避ける。
```c
typedef struct nmStencilState {
    bool enable;
    /* ... */
} nmStencilState;

bool nmFontHasGlyph(nmFont* self, uint32_t codepoint);
```


### Zig
Zigの一般的な規則に従う。このプロジェクト特有の方針はない。

## その他の決定項目

### アロケーター

Application が allocator を持ち、ウィジェット工場として振る舞う。

```.zig
pub const Application = struct {
    allocator: std.mem.Allocator,
    // ...

    pub fn init(allocator: std.mem.Allocator) !Application { ... }
    pub fn window(self: *Application, opts: Window.InitOptions) !*Window { ... }
    pub fn button(self: *Application, label: []const u8) !*Button { ... }
};
```

### 所有権

Containerが子Componentを所有し、開放の責任を持つ。

```.zig
pub const Container = struct {
    children: std.ArrayList(*Component),

    pub fn add(self: *Container, child: *Component) !void {
        try self.children.append(self.allocator, child);
        child.parent = self.asComponent();
    }

    pub fn deinit(self: *Container) void {
        for (self.children.items) |child| {
            child.deinit();       // 再帰
            self.allocator.destroy(child);
        }
        self.children.deinit(self.allocator);
    }
};
```

### スレッドモデル

単一UIスレッド。別スレッドからUIを操作することはできない。（その場合の動作は保証されない）
描画スレッドとUIスレッドは分けない。

### イベントループ / 複数ウィンドウ

イベントループは Application が一本だけ所有する。GLFW のイベントキューはプロセスにひとつなので、「ウィンドウごとのループ」は持たない。
Application はすべての Window をトラッキングし、`run()` の中で次を繰り返す:

1. `waitEvents` でブロック（イベント or `glfwPostEmptyEvent` で起きる）
2. EventQueue に溜まった task を drain
3. dirty フラグの立った Window だけ redraw
4. 全ウィンドウが閉じたら exit

描画は retained UI / invalidation 駆動。`Window.invalidate()` で dirty フラグを立てた窓だけが次のループで再描画される。毎フレーム常時 redraw はしない（immediate GUI と同じ CPU 消費になってしまう）。
resize / refresh コールバックは内部で自動的に invalidate を呼ぶ。
アニメーション等で連続描画したい場合は、redraw 中に再度自分自身を invalidate するか、専用 API（`requestAnimationFrame` 相当）でループを回し続ける。

### EventQueue / invokeLater

`java.awt.EventQueue` + `SwingUtilities.invokeLater` 相当を露出する。
別スレッドから UI を触る唯一の正規の手段。これが無いとバックグラウンド処理の結果を画面に反映できない。

awt 層に `EventQueue` を置き、framework の `Application` がそれを所有して `invokeLater` / `invokeAndWait` を生やす二段構成。
内部実装は GLFW の `glfwPostEmptyEvent()` で UI スレッドを起こすパターン:

* awt-c に thread-safe な task queue（mutex + 連結リスト）
* `nmEventQueuePost(fn, user_data)` で enqueue + `glfwPostEmptyEvent()`
* メインループが events のあとに queue を drain して task を実行
* `invokeAndWait` は condition variable で完了待ち

`invokeAndWait` は **別スレッドから呼ぶ前提**。UI スレッド自身から呼ぶと「自分の完了を自分で待つ」＝デッドロックなので、Swing / Qt と同様に assert / error で弾く。
用途は SwingWorker 相当（バックグラウンドで計算 → 結果を UI に反映して呼び出し元はその完了を待つ）。

task の所有権: C ABI 層では `void*` をそのまま渡す。Zig 側では closure を Application の allocator に確保して、実行後に解放するラッパーで隠す。

### 座標系

int32 ではなく、 float で管理する。

### 頂点の winding

front face は CCW（反時計回り、OpenGL / Vulkan / Metal のデフォルトと同じ）として規定する。
nimbus は GUI 用途で back-face culling を行わないので winding は描画結果に影響しないが、規約を明示しておくことで shader ユーティリティや将来のバックエンド設定に一貫性を持たせる。
DX12 バックエンドは PSO の `FrontCounterClockwise = TRUE` を指定する（D3D12 のデフォルトは CW front なので明示反転が必要）。

### 画像 / テクスチャ

GUI 用途なので DXT/ASTC/BCn のような GPU 圧縮形式はサポートしない。
サポートする形式は **PNG / JPEG / GIF(静止画) / BMP** で、デコーダは **zigimg**（純 Zig）を `vendor/zigimg/` に subtree で展開する。
アニメ GIF / SVG / WebP は v1 では対応しない。必要になったら追加で考える。

zigimg を選ぶ理由:
* 純 Zig 実装で C 依存なし → クロスコンパイル制約と相性 ◎（awt-c の C ビルドに同居させる必要がない）
* 画像デコードは GPU と無関係 → **awt 層で完結** すべき責務。awt-c に decode 関数を生やさない
* `@embedFile` で得たバイト列を `std.io.fixedBufferStream` 経由で直接 decode する API になじむ

ビルトインアイコン（チェックボックス、ラジオボタン背景、スクロール矢印 等）は Zig の `@embedFile` で `.rodata` に焼き込む。
生 PNG のまま埋め込み、初回参照時に zigimg でデコード → GPU upload → キャッシュ。L&F 切替時はキャッシュをクリアする（or L&F ごとに別キャッシュ）。

ユーザー提供画像（`Image.fromFile("foo.png")` 相当）は別系統で、こちらは普通のランタイム読み込み。

### フォント

freetype でレンダリング。フォントファイルは `framework/assets/fonts/` 配下に vendored して `@embedFile` で埋め込む。

デフォルトフォントは **Noto Sans (Latin) + Noto Sans CJK JP (日本語)** を採用。両方 **OFL 1.1** ライセンス。
Swing と違ってシステムフォントを使わず埋め込みにする理由は、システムフォント列挙を Windows (DirectWrite) / Mac (Core Text) / Linux (fontconfig) の 3 バックエンドで実装するのが「そこまで頑張りたくない」領域だから。代わりに **「何もしなくても日本語が出る」Swing 体験** を維持する。

OFL 1.1 は再配布物にライセンス文を含めることを要求するので、`framework/assets/fonts/OFL.txt` も一緒に vendored する。
パワーユーザー向けには `Application.setDefaultFont(path)` でファイル差し替えを許可する（"C:\Windows\Fonts\meiryo.ttc" 等を渡せる）。

ライセンス露出は **`nimbus.licenses()`** API で、組込み資産の attribution 文字列を返す設計にする。アプリ側で About ダイアログ等から表示する想定。

システムフォント列挙 API（`getAvailableFontFamilyNames` 相当）は v1 のスコープ外。将来必要になったら DirectWrite / Core Text / fontconfig を後付けする余地は残す。

### フォントのラスタライズと描画

テキスト描画は **グリフアトラス + バッチドロー** で実装する。
awt-c 層に専用プリミティブは持たない（`nmDrawFont` のような API は作らない）。awt-c は freetype ラッパとして「指定 codepoint をビットマップにラスタライズする API」だけを提供し、アトラス管理・テキスト VB 構築・描画は awt 層が `nmBuffer` / `nmPipeline` / `nmDraw` を組み合わせて実現する。

**アトラス**: R8 (8bit grayscale) 単一テクスチャ（例: 2048×2048）。
新しい `(font, size, codepoint)` を見た時だけ freetype でラスタライズ → shelf packing でアトラスに配置 → glyph cache に `{uv_rect, bearing_x, bearing_y, advance_x}` を記録。一度焼いたグリフは使い回す。
アトラスが満杯になったら **全クリアして再構築** で十分（GUI なら同じグリフを使い回すので定常状態に落ちる）。フラグメンテーション対策は v1 では不要。

**描画**: テキスト文字列 → glyph 列 → 各 glyph を quad（2 三角形）として一つの VB に積む → 1 draw call で出す。
頂点ごとに「絶対画面座標」と「アトラス内 UV」を焼くので、シェーダーは固定の「アトラスから R 値サンプル → カラー uniform と乗算」で済む。テクスチャ切替も不要（アトラス bind しっぱなし）。

**VB の更新方針**: テキスト変更時は **フル rebuild**。partial update は実装しない。
理由は、典型 GUI スケール（label 数文字 〜 textfield 数百文字）なら memcpy + cursor 累積で **サブマイクロ秒〜数マイクロ秒** で済むため。UPLOAD heap + persistent mapping を使えば「mapped ポインタへの memcpy」だけで更新できる。
TextField の毎キーストロークでフル rebuild しても問題ない。TextArea のような長文ケースは行 chunk 分割 + viewport カリングが要るが、v1 では考えない。

**スコープ外（v1）**:
- LCD subpixel AA（grayscale 一択。回転やアニメに弱く、現代の Web/モバイルも grayscale に倒れている）
- HarfBuzz による complex script shaping（CJK は codepoint→glyph がほぼ 1:1 で動く。アラビア・インド系・絵文字結合等は v1 非対応）
- glyph prewarming API（on-demand で十分。必要になったら `Font.prewarm(...)` を後付け）
- フレーム全体のテキスト VB 統合（Skia 風の frame-level batcher）。v1 はコンポーネント単位の VB キャッシュで十分

### 文字コード

公開 API はすべて **UTF-8 一本**。内部表現も UTF-8 で持ち、freetype に渡す直前で 1 codepoint ずつデコードする。

選定理由:
* Zig の文字列リテラルが UTF-8
* GLFW のクリップボード・タイトル・drag&drop が全部 UTF-8
* ファイル I/O も UTF-8 が現代標準
* freetype は最終的に UTF-32 codepoint しか見ないので、どの内部表現を選んでもデコードは要る

プラットフォーム境界での変換:
* **Windows Win32**: UTF-16 (wchar_t) のため UTF-8 ↔ UTF-16 変換が要る。GLFW が内部でやってくれるので、awt-c が直接 Win32 を触る箇所（ウィンドウタイトル、クリップボード、ファイルダイアログ）でだけ気にする
* **Mac Cocoa**: NSString は UTF-8 を受け付けるので透過
* **freetype**: `FT_ULong` (UTF-32 codepoint) を渡す

#### v1 のスコープと将来計画

| 問題 | v1 でやる? | 備考 |
|---|---|---|
| codepoint 境界での backspace / cursor 移動 | やる | UTF-8 を「直前の 1 codepoint」単位で扱う |
| **書記素クラスタ (grapheme cluster) 単位の編集** | **v1 では codepoint 単位、将来 TextField で対応** | "é" = e + 結合アクセント、絵文字 + ZWJ + 絵文字、絵文字 + スキントーン等を 1 編集単位として扱う。UAX #29 のテーブル or libgrapheme 相当が要る |
| Unicode 正規化 (NFC/NFD) | やらない | 入力バイト列をそのまま保持 |
| BiDi (Hebrew/Arabic 右→左) | やらない | LTR 限定。後付けの余地は残す |
| IME composition string | 受信のみ | GLFW の char callback は確定後しか来ない。変換中の inline 表示は v1 非対応 |

**TextField の編集は最終的に書記素クラスタ単位を目指す**。 v1 は codepoint 単位で割り切るが、API 設計時から「将来 grapheme 単位に差し替える」前提で、`countCharacters` / `deleteBackward` 等は実装詳細を隠した抽象 API にしておく（バイト index を直接公開しない）。

### エラーのC_ABIでの表現

NULLを返し、内部エラーを `GetLastError()` のように取得できるようにする。

```.zig
// framework/src/c_api.zig
const std = @import("std");
const framework = @import("nimbus");

// Zig側のerror unionを返す関数を、C ABI互換のNULL返しに変換
export fn nimbus_button_create(label: [*:0]const u8) ?*framework.widget.Button {
    const label_slice = std.mem.span(label);
    const btn = framework.widget.Button.init(getApp(), label_slice) catch |err| {
        setLastError(err);    // ★ ここでerror値を保存
        return null;          // ★ C ABIにはNULLで失敗を伝える
    };
    return btn;
}

// thread-local last error storage
threadlocal var last_error: ?anyerror = null;
threadlocal var last_error_buf: [256]u8 = undefined;
threadlocal var last_error_msg: []const u8 = "";

fn setLastError(err: anyerror) void {
    last_error = err;
    last_error_msg = std.fmt.bufPrint(&last_error_buf, "{s}", .{@errorName(err)}) catch "";
}

export fn nimbus_last_error_code() c_int {
    return errorToCode(last_error orelse return 0);
}

export fn nimbus_last_error_message() [*:0]const u8 {
    return @ptrCast(last_error_msg.ptr);  // 簡略化
}

fn errorToCode(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory => 1,
        error.WindowCreateFailed => 2,
        // ...
        else => 99,
    };
}
```

#### Create 関数の失敗時セマンティクス

`nmCreateXxx` 系の関数が NULL を返した場合、**その関数内で確保したリソースはすべて関数内で解放されている**。利用者は失敗時に何も後片付けする必要はない（NULL に対して `nmDestroyXxx` を呼ぶ必要も無いし、呼んではいけない）。

これは「強い例外保証 (strong exception guarantee)」相当で、`nmCreateXxx` は **all-or-nothing**:
* 成功 → 有効な non-NULL ポインタを返す。利用者は `nmDestroyXxx` を呼んで解放する責任を負う。
* 失敗 → NULL を返す。関数呼び出しの前後でリソース状態は実質変わらない。

ただし「システム全体の完全な状態リストア」は保証しない。たとえば device の初期化中に debug layer の有効化に成功した後で別の段階が失敗した場合、debug layer の有効化を取り消すような巻き戻しはしない。あくまで **この関数呼び出しが新規に確保したオブジェクトのみ** 解放する。