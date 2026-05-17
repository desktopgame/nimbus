# window
ウィンドウに関する設計ノート。

## 型定義
typedef struct nmWindow nmWindow;

内部実装に関する知識は外部に漏らさない。
awtの内部で定義された抽象化済みの型については保持しても構わない。

## ウィンドウの生成
nmWindow* nmCreateWindow(const char* title, int width, int height);

タイトル文字列、横幅、縦幅を指定してウィンドウを生成する。

## ウィンドウの破棄
void nmDestroyWindow(nmWindow* self);

ウィンドウを破棄する。
以後引数の `self` が使用可能であるかどうかは保証されない。

## ウィンドウを閉じるべきか
int nmShouldClose(nmWindow* self);

ウィンドウを閉じるべきであるなら 1 を返す。

## バッファのスワップ
void nmSwapBuffers(nmWindow* self);

フロントバッファとバックバッファを入れ替え、最後に描画した内容を画面に反映する。
内部的にはGLFWのスワップ機構を呼ぶが、その知識は外部に漏らさない。

## ウィンドウサイズとフレームバッファサイズ
nimbus はウィンドウに対して **2 種類のサイズ** を区別する。

| 概念 | 単位 | 取得 API | 用途 |
|---|---|---|---|
| ウィンドウサイズ | 論理ポイント | `nmGetWindowSize` | ユーザー向け描画座標、レイアウト計算 |
| フレームバッファサイズ | 実ピクセル | `nmGetFramebufferSize` | スワップチェイン、ビューポート、シザー矩形 |

通常の Windows（DPI awareness なし）では両者は同じ値になる。
一方、 macOS の Retina ディスプレイのように HiDPI な環境では、ウィンドウサイズが 800x600 でもフレームバッファサイズは 1600x1200（2 倍）になり得る。

ユーザーが書く描画コードは「論理ポイント」を入力単位とする想定であり、その方が DPI に依らず同じ見た目になる。
そのため、awt 上位レイヤー (`Graphics` 等) は NDC 変換にウィンドウサイズを、シザー矩形・ビューポートにはフレームバッファサイズを使い分ける。

### ウィンドウサイズ取得
void nmGetWindowSize(const nmWindow* self, int* width, int* height);

ウィンドウサイズを論理ポイント単位で取得する。
`nmCreateWindow` で指定した値と概ね対応する（ウィンドウマネージャによっては微調整される）。

### フレームバッファサイズ取得
void nmGetFramebufferSize(const nmWindow* self, int* width, int* height);

フレームバッファのサイズを実ピクセル単位で取得する。
スワップチェインの初期サイズと一致し、`nmResizeSwapchain` に渡すべき値もこの単位。

## サイズ変更通知
typedef void (*nmWindowResizeCallback)(nmWindow* window, int width, int height, void* user_data);
void nmSetWindowResizeCallback(nmWindow* self, nmWindowResizeCallback cb, void* user_data);

ウィンドウのサイズが変更された時に呼ばれるコールバックを登録する。
`width` と `height` は **フレームバッファサイズ（実ピクセル）** で渡される。論理ポイントが必要なら、コールバック内で `nmGetWindowSize` を呼んで取得する。
コールバックは `self` を生成・操作しているスレッドと同じスレッドから同期的に呼ばれる。
`cb` に `NULL` を渡すと登録解除される。

スワップチェインを使っている場合、通常はこのコールバックから `nmResizeSwapchain` を呼ぶ。

なお、ウィンドウ作成直後にはこのコールバックは発火しない。初回フレームの描画前にサイズを取得したい場合は、`nmGetWindowSize` / `nmGetFramebufferSize` を直接呼ぶこと。

## 再描画通知
typedef void (*nmWindowRefreshCallback)(nmWindow* window, void* user_data);
void nmSetWindowRefreshCallback(nmWindow* self, nmWindowRefreshCallback cb, void* user_data);

ウィンドウの内容を再描画すべき時に呼ばれるコールバックを登録する。
Windows の modal sizing loop 中（ユーザーが枠をドラッグしている間）など、通常のメインループが回らない状況でも発火する。
コールバックは `self` を生成・操作しているスレッドと同じスレッドから同期的に呼ばれる。
`cb` に `NULL` を渡すと登録解除される。

リサイズ中も描画を継続したい場合、このコールバックから描画処理を呼ぶ。