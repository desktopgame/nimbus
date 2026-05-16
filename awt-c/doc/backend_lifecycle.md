# backend_lifecycle
バックエンドのライフサイクルに関する設計ノート。

## awtの初期化
int nmInitAwt(void);

内部的なシステムを初期化する。
GLFWを使用しますが、その知識は外部に漏らさない。
戻り値として終了ステータス（成功ならゼロ）を返す。
リエントラントであることは保証しない。

## awtの終了
void nmTerminateAwt(void);

内部的なシステムを終了する。
GLFWを使用しますが、その知識は外部に漏らさない。
リエントラントであることは保証しない。

## awtのバージョン
const char* nmGetBackendVersion(void);

バージョン文字列を返す。
デバッグ用なので、ユーザーフレンドリーである必要はない。