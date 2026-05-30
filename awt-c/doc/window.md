---
unsafe: true
---

# window
ウィンドウに関する設計ノート。
プラットフォーム固有のウィンドウシステムを抽象化した、描画と入力のホスト。

## 型定義
```c
typedef struct nmWindow nmWindow;

typedef void (*nmWindowResizeCallback)(nmWindow* window, int width, int height, void* user_data);
typedef void (*nmWindowRefreshCallback)(nmWindow* window, void* user_data);
typedef void (*nmWindowMoveCallback)(nmWindow* window, int x, int y, void* user_data);

typedef enum nmKeyAction {
    nmKeyActionRelease,
    nmKeyActionPress,
    nmKeyActionRepeat,
} nmKeyAction;

typedef enum nmMouseButton {
    nmMouseButtonLeft,
    nmMouseButtonMiddle,
    nmMouseButtonRight,
} nmMouseButton;

/* Modifier bitmask. Combine with bitwise OR. */
typedef enum nmModifiers {
    nmModifierShift = 1 << 0,
    nmModifierCtrl  = 1 << 1,
    nmModifierAlt   = 1 << 2,
    nmModifierMeta  = 1 << 3,
} nmModifiers;

/* Key code; mirrors GLFW_KEY_* values. The awt (Zig) layer maps these into a
 * typed enum. */
typedef int nmKeyCode;

typedef void (*nmMouseButtonCallback)(nmWindow* window, nmMouseButton button, nmKeyAction action, int modifiers, void* user_data);
typedef void (*nmCursorPosCallback)(nmWindow* window, double x, double y, void* user_data);
typedef void (*nmScrollCallback)(nmWindow* window, double dx, double dy, void* user_data);
typedef void (*nmKeyCallback)(nmWindow* window, nmKeyCode key, nmKeyAction action, int modifiers, void* user_data);
typedef void (*nmCharCallback)(nmWindow* window, uint32_t codepoint, void* user_data);

typedef struct nmCompositionEvent {
    const char* text;          /* UTF-8 preedit string (borrowed) */
    size_t      text_len;
    size_t      target_start;  /* byte offset, 変換中クローズの開始 */
    size_t      target_end;    /* byte offset, 変換中クローズの終了 */
} nmCompositionEvent;

typedef void (*nmCompositionCallback)(nmWindow* window,
                                       const nmCompositionEvent* ev,
                                       void* user_data);
```

`nmWindow` の内部実装に関する知識は外部に漏らさない。
awt の内部で定義された抽象化済みの型については保持しても構わない。

## ウィンドウの生成
nmWindow* nmCreateWindow(const char* title, int width, int height);

タイトル文字列、横幅、縦幅を指定してウィンドウを生成する。
`width` / `height` は論理ポイント単位で解釈される。
失敗時は `NULL` を返す。

### 事前条件
* `title` が NUL 終端された UTF-8 文字列であること。違反した場合の動作は UB。
* `width` / `height` がいずれも 1 以上であること。違反した場合の動作は UB。

## ウィンドウの破棄
void nmDestroyWindow(nmWindow* self);

ウィンドウを破棄する。
以後引数の `self` が使用可能であるかどうかは保証されない。

### 事前条件
* `self` が NULL のとき、なにも実行せずに終了する。
* `self` に関連付けられたスワップチェインが残っていないこと。違反した場合の動作は UB。

## ウィンドウタイトルの変更
void nmSetWindowTitle(nmWindow* self, const char* title);

OS のタイトルバー / タスクバーに表示される文字列を `title` に差し替える。即時反映。

### 事前条件
* `self` が non-NULL であること。違反した場合の動作は UB。
* `title` が NUL 終端された UTF-8 文字列であること。違反した場合の動作は UB。

## ウィンドウを閉じるべきか
bool nmShouldClose(nmWindow* self);

ウィンドウを閉じるべきであるなら `true` を返す。
ウィンドウマネージャによる閉じる操作 (X ボタン押下、Alt+F4 等) で `true` に切り替わる。

## バッファのスワップ
void nmSwapBuffers(nmWindow* self);

フロントバッファとバックバッファを入れ替え、最後に描画した内容を画面に反映する。
内部的には GLFW のスワップ機構を呼ぶが、その知識は外部に漏らさない。

## ウィンドウサイズの取得
void nmGetWindowSize(const nmWindow* self, int* width, int* height);

ウィンドウサイズを論理ポイント単位で取得する。
`nmCreateWindow` で指定した値と概ね対応する (ウィンドウマネージャによっては微調整される)。

### 事前条件
* `width` / `height` がいずれも NULL でないこと。違反した場合の動作は UB。

## ウィンドウサイズの変更
void nmSetWindowSize(nmWindow* self, int width, int height);

ウィンドウサイズを論理ポイント単位で変更する。単位は `nmGetWindowSize` と同じ。
フレームバッファも追従して変更され、登録済みのサイズ変更コールバックが発火する。

## フレームバッファサイズの取得
void nmGetFramebufferSize(const nmWindow* self, int* width, int* height);

フレームバッファのサイズを実ピクセル単位で取得する。
スワップチェインの初期サイズと一致し、`nmResizeSwapchain` に渡すべき値もこの単位。

### 事前条件
* `width` / `height` がいずれも NULL でないこと。違反した場合の動作は UB。

## コンテンツスケールの取得
void nmGetWindowContentScale(const nmWindow* self, float* xscale, float* yscale);

ウィンドウが配置されているモニタの DPR (device pixel ratio) を取得する。
`物理 = 論理 × スケール` の関係を持つ比率で、plain 1x display で 1.0、Retina で 2.0、Windows 150% で 1.5 など。
通常 `*xscale == *yscale`。

論理ポイント単位の値 (例えばフォントの pixel size) を物理ピクセルに変換する場合などに使う。

### 事前条件
* `xscale` / `yscale` がいずれも NULL でないこと。違反した場合の動作は UB。

## サイズ変更コールバックの登録
void nmSetWindowResizeCallback(nmWindow* self, nmWindowResizeCallback cb, void* user_data);

ウィンドウのサイズが変更された時に呼ばれるコールバックを登録する。
コールバックに渡される `width` / `height` は **フレームバッファサイズ (実ピクセル)** 。論理ポイントが必要ならコールバック内で `nmGetWindowSize` を呼んで取得する。
コールバックは `self` を生成 / 操作しているスレッドと同じスレッドから同期的に呼ばれる。
`cb` に `NULL` を渡すと登録解除される。

スワップチェインを使っている場合、通常はこのコールバックから `nmResizeSwapchain` を呼ぶ。

なお、ウィンドウ作成直後にはこのコールバックは発火しない。初回フレームの描画前にサイズを取得したい場合は、`nmGetWindowSize` / `nmGetFramebufferSize` を直接呼ぶこと。

## 再描画コールバックの登録
void nmSetWindowRefreshCallback(nmWindow* self, nmWindowRefreshCallback cb, void* user_data);

ウィンドウの内容を再描画すべき時に呼ばれるコールバックを登録する。
Windows の modal sizing loop 中 (利用者が枠をドラッグしている間) など、通常のメインループが回らない状況でも発火する。
コールバックは `self` を生成 / 操作しているスレッドと同じスレッドから同期的に呼ばれる。
`cb` に `NULL` を渡すと登録解除される。

リサイズ中も描画を継続したい場合、このコールバックから描画処理を呼ぶ。

## 移動コールバックの登録
void nmSetWindowMoveCallback(nmWindow* self, nmWindowMoveCallback cb, void* user_data);

ウィンドウが移動した時に呼ばれるコールバックを登録する。
コールバックに渡される `x` / `y` は移動後の左上隅を論理ポイント単位で表す。単位は `nmGetWindowPos` と同じ。
利用者によるドラッグ移動と、`nmSetWindowPos` によるプログラム移動の両方で発火する。
コールバックは `self` を生成 / 操作しているスレッドと同じスレッドから同期的に呼ばれる。
`cb` に `NULL` を渡すと登録解除される。

## マウスボタンコールバックの登録
void nmSetMouseButtonCallback(nmWindow* self, nmMouseButtonCallback cb, void* user_data);

マウスボタン押下 / 解放時に呼ばれるコールバックを登録する。
`action` は `nmKeyActionPress` または `nmKeyActionRelease`。
`modifiers` は `nmModifiers` のビットマスク。
`cb` に `NULL` を渡すと登録解除される。

## カーソル位置コールバックの登録
void nmSetCursorPosCallback(nmWindow* self, nmCursorPosCallback cb, void* user_data);

カーソル移動時に呼ばれるコールバックを登録する。
`x` / `y` は **ウィンドウローカル座標 (論理ポイント)** で、ウィンドウの左上が `(0, 0)`、右下が `(width, height)` となる。
`cb` に `NULL` を渡すと登録解除される。

## スクロールコールバックの登録
void nmSetScrollCallback(nmWindow* self, nmScrollCallback cb, void* user_data);

マウスホイール / トラックパッド スクロール時に呼ばれるコールバックを登録する。
`dx` / `dy` はスクロール量で、`dy` の正の値は上方向。
`cb` に `NULL` を渡すと登録解除される。

## キーコールバックの登録
void nmSetKeyCallback(nmWindow* self, nmKeyCallback cb, void* user_data);

キー押下 / 解放 / リピート時に呼ばれるコールバックを登録する。
`key` は GLFW のキーコードに対応する整数値。
`action` は `nmKeyActionPress` / `nmKeyActionRelease` / `nmKeyActionRepeat` のいずれか。
`modifiers` は `nmModifiers` のビットマスク。
`cb` に `NULL` を渡すと登録解除される。

## 文字入力コールバックの登録
void nmSetCharCallback(nmWindow* self, nmCharCallback cb, void* user_data);

OS のキーボードレイアウトを通過した後の Unicode codepoint を 1 つずつ受け取るコールバックを登録する。
`'a'` キー押下で `'a' = 0x61`、Shift+1 で `'!' = 0x21` のように、修飾キーの効果が反映された後の文字が届く。
ショートカット検出やカーソル移動には `nmSetKeyCallback` を使い、テキスト入力にはこちらを使う。
`cb` に `NULL` を渡すと登録解除される。

## IME composition コールバックの登録
void nmSetCompositionCallback(nmWindow* self, nmCompositionCallback cb, void* user_data);

IME の preedit（変換中文字列）が更新された時に呼ばれるコールバックを登録する。
コールバックには現在の preedit 文字列（UTF-8）と、変換中クローズの byte 範囲（`target_start` / `target_end`）が渡される。

空文字列 (`text_len == 0`) は **composition cleared**（キャンセル or 確定）のシグナル。
確定文字列自体は既存の `nmCharCallback` で別途配送されるため、利用者は preedit overlay をクリアするだけでよい。

`cb` に `NULL` を渡すと登録解除される。

### 実装状況
| プラットフォーム | 状態 |
|---|---|
| Windows | IMM32 + WNDPROC subclass で実装済み |
| macOS | NSView runtime subclass + `NSTextInputClient` (`setMarkedText:` / `unmarkText` / `firstRectForCharacterRange:`) で実装済み |
| Linux | stub（no-op）。Wayland text-input v3 ベースの実装は将来 |

## IME 候補ウィンドウ位置の設定
void nmSetCompositionCursorPos(nmWindow* self, int x, int y, int height);

IME 候補ウィンドウの表示位置を、現在のテキストキャレット位置（ウィンドウローカル ピクセル）+ 行高で OS に伝える。
TextField 等のキャレットが移動するたびに呼ぶ想定。
処理は軽量で、毎キー入力ごとに呼んでもパフォーマンス影響は無視できる。

* Windows: `ImmSetCompositionWindow` + `ImmSetCandidateWindow` で即時 push
* macOS: 内部キャッシュに保存し、`NSTextInputContext.invalidateCharacterCoordinates` で OS に再 pull を促す。実際の座標応答は `firstRectForCharacterRange:` ハンドラで行う
* Linux: `zwp_text_input_v3.set_cursor_rectangle` で即時 push（予定）

### 事前条件
* `self` が non-NULL であること。違反した場合の動作は UB。

## クリップボードからの読み出し
const char* nmGetClipboardString(nmWindow* self);

システムクリップボードに格納されている UTF-8 文字列を返す。
クリップボードが空、または UTF-8 テキスト以外を保持している場合は `NULL` を返す。
返り値のポインタは awt-c が所有しており、次に同スレッドから `nmGetClipboardString` / `nmSetClipboardString` を呼ぶまで有効。
それ以降は無効化されるので、呼び出し側は必要なら呼び出し直後に内容をコピーする。

### 事前条件
* `self` が non-NULL であること。違反した場合の動作は UB。

## クリップボードへの書き込み
void nmSetClipboardString(nmWindow* self, const char* utf8);

`utf8` の内容をシステムクリップボードに書き込む。
内部で内容のコピーを取るので、関数戻り後に `utf8` が解放されても安全。

### 事前条件
* `self` が non-NULL であること。違反した場合の動作は UB。
* `utf8` が NUL 終端された UTF-8 文字列であること。違反した場合の動作は UB。

## 機能要望
* ウィンドウ状態の取得 / 変更 API (最小化、最大化、フォーカス、可視性)。
* フルスクリーンモードへの切替。
* 複数モニタ環境におけるモニタ選択 API。
