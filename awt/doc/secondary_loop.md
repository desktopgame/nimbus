# secondary_loop
入れ子イベントループのプリミティブ。
`Application.run()` の中からさらに小さな blocking ループを回し、明示的に `exit()` が呼ばれるまで待機する。
Swing の `SecondaryLoop` / Qt の `QEventLoop` 相当。
主用途は将来追加される modal dialog だが、awt 層のプリミティブとして利用者が直接使うこともできる。

## 型定義
```zig
pub const SecondaryLoop = struct {
    tick:           ?*const fn (*anyopaque) void,
    tick_user_data: ?*anyopaque,
    exit_requested: bool = false,
    exit_code:      i32  = 0,

    // ... メソッド
};
```

`tick` は各イベント反復で UI 更新を行うためのコールバック（再描画、OS 同期等）。
framework 層は Application のティック関数を渡し、awt 層のみで使う場合は null でよい（イベントを流すだけ）。

## ループの生成
```zig
pub fn init(
    tick: ?*const fn (*anyopaque) void,
    tick_user_data: ?*anyopaque,
) SecondaryLoop;
```

`SecondaryLoop` の値型を初期化して返す。
内部状態は `exit_requested = false`、`exit_code = 0` で始まる。

ヒープアロケーションは行わない。
呼び出し側のスタックに置いて使うのが想定。

## ループの実行
```zig
pub fn exec(self: *SecondaryLoop) i32;
```

ブロックして以下を繰り返す。

1. `awt.waitEvents()` でイベントを待つ
2. `tick` が non-null なら呼ぶ（UI 更新が必要な処理一式）
3. `exit_requested` が true なら break

最後に `exit_code` を返す。

### 事前条件
* UI スレッドから呼ぶこと
* 親の `Application.run()` の中から呼ぶこと（ネストして使う想定）

## ループの終了予約
```zig
pub fn exit(self: *SecondaryLoop, code: i32) void;
```

`exit_requested = true`、`exit_code = code` をセットする。
実際の終了は次の反復で `exec` ループが check して break する。
内部で `glfwPostEmptyEvent` を呼んで UI スレッドを起こす（既に `waitEvents` でブロックしている場合に必要）。

任意のスレッドから呼べる（ただし通常は UI スレッド上のイベントハンドラから呼ぶ）。

---

## なぜ tick コールバックを取るか
SecondaryLoop は awt 層のプリミティブとして「イベントを流す機構」だけを提供する。
再描画 / OS 同期 / dirty フラグ管理は framework 層の責務であり、それを awt 層から直接呼ぶと層が逆転する。

そのため SecondaryLoop は「イベント駆動でループを回す」だけを行い、ループ反復ごとに何をするかは `tick` コールバックで利用者（framework）に委ねる。
framework は `Application.tickOnce` のような関数を渡して、メインループと同じ per-iteration 処理を SecondaryLoop でも回す。

awt 層単体でも使える（modal dialog の代わりに低レベル blocking UI を作る用途等）。
その場合は `tick = null` で初期化し、イベントだけ流して `exit()` 呼び出しを待つ。

## ネスト
SecondaryLoop は入れ子で使える。
modal dialog の中から別の modal dialog を開く、というケースに対応する。
各 SecondaryLoop が独立した `exit_requested` を持つので、外側は内側の終了を待ってから自分の `exit` を判定する。

## EventQueue との関係
SecondaryLoop の `tick` が EventQueue の `drain` を呼ぶ責務を負う（framework 側で実装する）。
これにより、SecondaryLoop 実行中も別スレッドからの `invokeLater` が消化される。
`event_queue.md` を参照。

## メインループとの違い
| | `Application.run()` | `SecondaryLoop.exec()` |
|---|---|---|
| 終了条件 | 全ウィンドウが閉じた | `exit()` が呼ばれた |
| 階層 | 最外殻、1 回だけ | 入れ子で複数回 |
| tick | 自分で処理一式を持つ | コールバック経由 |
| 戻り値 | `!void` | `i32`（exit code） |

「最後のウィンドウが閉じたら」終了するのは `Application.run()` のみ。
SecondaryLoop は明示的な `exit()` を待つ。

## modal dialog での想定利用フロー
将来 Dialog が追加された時の典型フロー:

1. `dialog.showModal()` が呼ばれる
2. Dialog 内部で SecondaryLoop を init
3. `loop.exec()` で blocking 開始
4. ダイアログ内の OK / Cancel ボタンのイベントハンドラから `loop.exit(result_code)` を呼ぶ
5. `exec()` が return、`showModal()` が結果を返す

呼び出し側コード：

```zig
const result = dialog.showModal();
if (result == .ok) { ... }
```

これにより modal dialog の同期的な API がイベント駆動アーキテクチャの上に成立する。

---

## 利用例
awt 層単体で使う最小例（framework なし、イベントを流すだけのブロッキング処理）。

```zig
var loop = awt.SecondaryLoop.init(null, null);

// 別スレッドから (または同スレッドの GLFW callback 経由で)
// loop.exit(0) を呼ぶことで抜ける

const code = loop.exec();
std.debug.print("loop exited with code {d}\n", .{code});
```

framework 側から tick 付きで使う想定（modal dialog 実装相当の擬似コード）。

```zig
fn showDialogModal(self: *Dialog) DialogResult {
    var loop = awt.SecondaryLoop.init(
        appTickFn,
        @ptrCast(self.app),
    );
    self.modal_loop = &loop;
    defer self.modal_loop = null;

    self.show();
    const code = loop.exec();
    return @enumFromInt(code);
}

// OK ボタンのハンドラ
fn onOkClick(dialog: *Dialog) void {
    dialog.modal_loop.?.exit(@intFromEnum(DialogResult.ok));
}
```

ネスト例（外側の SecondaryLoop の中で別の SecondaryLoop を開く）。

```zig
// 外側のダイアログ
var outer = awt.SecondaryLoop.init(tick, data);

// 外側ダイアログのハンドラから内側ダイアログを開く
fn onOpenInner() void {
    var inner = awt.SecondaryLoop.init(tick, data);
    const inner_code = inner.exec();   // 内側の exit() まで待つ
    // ここから外側ループに戻る
    _ = inner_code;
}

const outer_code = outer.exec();
```

## 機能要望
* タイムアウト付き `exec(timeout)`（指定時間で自動 exit）
* `processEventsOnce()` ノンブロッキング版（1 イベントだけ流して return）
* exit 時のクリーンアップ hook
* ネスト深度の自動 assert（過剰なネストを検知）
