# window
ウィンドウに関する設計ノート。
プラットフォーム固有のウィンドウシステムを抽象化した、描画と入力のホスト。

## 型定義
```c
typedef struct nmWindow nmWindow;

typedef void (*nmWindowResizeCallback)(nmWindow* window, int width, int height, void* user_data);
typedef void (*nmWindowRefreshCallback)(nmWindow* window, void* user_data);

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
```

`nmWindow` の内部実装に関する知識は外部に漏らさない。
awt の内部で定義された抽象化済みの型については保持しても構わない。

## ウィンドウサイズとフレームバッファサイズ
nimbus はウィンドウに対して **2 種類のサイズ** を区別する。

| 概念 | 単位 | 取得 API | 用途 |
|---|---|---|---|
| ウィンドウサイズ | 論理ポイント | `nmGetWindowSize` | 利用者向け描画座標、レイアウト計算 |
| フレームバッファサイズ | 実ピクセル | `nmGetFramebufferSize` | スワップチェイン、ビューポート、シザー矩形 |

通常の Windows (DPI awareness なし) では両者は同じ値になる。
一方、macOS の Retina ディスプレイのような HiDPI 環境では、ウィンドウサイズが 800x600 でもフレームバッファサイズは 1600x1200 (2 倍) になり得る。

利用者が書く描画コードは「論理ポイント」を入力単位とする想定で、その方が DPI に依らず同じ見た目になる。
そのため、awt 上位レイヤー (`Graphics` 等) は NDC 変換にウィンドウサイズを、シザー矩形 / ビューポートにはフレームバッファサイズを使い分ける。

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

## フレームバッファサイズの取得
void nmGetFramebufferSize(const nmWindow* self, int* width, int* height);

フレームバッファのサイズを実ピクセル単位で取得する。
スワップチェインの初期サイズと一致し、`nmResizeSwapchain` に渡すべき値もこの単位。

### 事前条件
* `width` / `height` がいずれも NULL でないこと。違反した場合の動作は UB。

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
* DPI スケール係数の単独取得 API (現状は論理 / 実ピクセルの 2 値から逆算が必要)。
* ウィンドウ状態の取得 / 変更 API (最小化、最大化、フォーカス、可視性)。
* タイトルの後付け変更 API。
* フルスクリーンモードへの切替。
* 複数モニタ環境におけるモニタ選択 API。
