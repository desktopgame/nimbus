---
unsafe: true
---

# backend_lifecycle
バックエンドのライフサイクルに関する設計ノート。

## awtの初期化
int nmInitAwt(void);

内部的なシステムを初期化する。
* GLFW の初期化 (`glfwInit`)
* freetype の初期化 (`FT_Init_FreeType`) — FT_Library は単一インスタンスを内部保持する

GLFW / freetype を使用する知識は外部に漏らさない。
戻り値として終了ステータス（成功ならゼロ）を返す。
リエントラントであることは保証しない。

## awtの終了
void nmTerminateAwt(void);

内部的なシステムを終了する。
* freetype の終了 (`FT_Done_FreeType`)
* GLFW の終了 (`glfwTerminate`)

GLFW / freetype を使用する知識は外部に漏らさない。
利用者が生成した nmFont 等のリソースは、この呼び出し前に破棄しておくこと。
リエントラントであることは保証しない。

## awtのバージョン
const char* nmAwtBackendVersion(void);

バージョン文字列を返す。
デバッグ用なので、ユーザーフレンドリーである必要はない。