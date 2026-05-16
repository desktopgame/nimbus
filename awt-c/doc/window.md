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

## サイズ変更通知
typedef void (*nmWindowResizeCallback)(nmWindow* window, int width, int height, void* user_data);
void nmSetWindowResizeCallback(nmWindow* self, nmWindowResizeCallback cb, void* user_data);

ウィンドウのサイズが変更された時に呼ばれるコールバックを登録する。
`width` と `height` は実ピクセル単位（high-DPI 環境を考慮）で渡される。
コールバックは `self` を生成・操作しているスレッドと同じスレッドから同期的に呼ばれる。
`cb` に `NULL` を渡すと登録解除される。

スワップチェインを使っている場合、通常はこのコールバックから `nmResizeSwapchain` を呼ぶ。

## 再描画通知
typedef void (*nmWindowRefreshCallback)(nmWindow* window, void* user_data);
void nmSetWindowRefreshCallback(nmWindow* self, nmWindowRefreshCallback cb, void* user_data);

ウィンドウの内容を再描画すべき時に呼ばれるコールバックを登録する。
Windows の modal sizing loop 中（ユーザーが枠をドラッグしている間）など、通常のメインループが回らない状況でも発火する。
コールバックは `self` を生成・操作しているスレッドと同じスレッドから同期的に呼ばれる。
`cb` に `NULL` を渡すと登録解除される。

リサイズ中も描画を継続したい場合、このコールバックから描画処理を呼ぶ。