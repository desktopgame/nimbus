---
unsafe: true
---

# log
内部ログ出力に関する設計ノート。
nimbus 内部で発生したエラー・警告・情報メッセージを利用者側に通知する仕組み。

## 型定義
```c
typedef enum nmLogLevel {
    nmLogLevelDebug,
    nmLogLevelInfo,
    nmLogLevelWarn,
    nmLogLevelError,
} nmLogLevel;

typedef void (*nmLogCallback)(nmLogLevel level, const char* category, const char* message, void* user_data);
```

`category` はメッセージの発生源を表す短い文字列リテラル (`"shader"`, `"dx12"`, `"glfw"`, `"device"` など)。
列挙ではなく文字列にすることで、内部実装の都合で増減しても ABI に影響しない。

`message` は NUL 終端された UTF-8 文字列。
コールバック呼び出しの間のみ有効で、それ以降の参照を保持したい場合は呼び出し側で複製する。

## ログコールバックの設定
void nmSetLogCallback(nmLogCallback cb, void* user_data);

ログ出力を受け取るコールバックを登録する。
コールバックは同期的に呼ばれ、ログを発生させたスレッドと同じスレッドから実行される。
nimbus は単一 UI スレッド前提で動くため、通常はメインスレッドからのみ呼ばれる。

`cb` に `NULL` を渡すとデフォルトの挙動 (`stderr` への `[LEVEL] [category] message\n` 形式の出力) に戻る。
コールバック未設定時もこのデフォルト挙動が適用され、開発初期で何も設定しなくても重要なメッセージが見える。

### 事前条件
* `nmInitAwt()` の前後どちらからでも呼び出し可能。
