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