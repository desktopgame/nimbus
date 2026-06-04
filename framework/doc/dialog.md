---
unsafe: false
---

# dialog
オーナーを持つトップレベルウィンドウ。
`Window` を embed し、モーダル（呼び出し側をブロックして結果を返す）／モードレス（非ブロック）の両方で表示できる。
Swing の `JDialog` 相当。

## 型定義
```zig
pub const Dialog = struct {
    window:     Window,                  // embed (title / close / resize / root container / repaint はすべてここ)
    owner:      *Window,                 // オーナーウィンドウ (必須)。中央寄せ / 「オーナーが閉じたら一緒に閉じる」の基準
    modal:      bool,                    // showModal で開かれていれば true (show なら false)
    result:     Result,                  // 閉じた時の結果。showModal の戻り値になる
    modal_done: bool,                    // close が立てる。showModal の入れ子ループを抜ける条件
    shown:      bool,                    // Application の windows リストに登録中か (二重 show / 二重 close 防止)
    // 注意喚起の点滅 (flash) 用の状態
    flash_timer:     ?Application.TimerId,
    flash_remaining: u8,
    flash_on:        bool,
    base_bg:         awt.Graphics.Color, // 点滅前の背景色 (復元用)
    allocator:  std.mem.Allocator,
};

pub const Result = enum(i32) {
    none   = 0,    // 明示結果なしで閉じた (X ボタン / dispose 等)
    ok     = 1,
    cancel = 2,
    _,             // 利用者定義の結果コード (非網羅。任意の i32 を流せる)
};
```

`Result` を非網羅 enum にしているのは、`ok` / `cancel` 以外の選択肢（"yes" / "no" / "apply" や、リスト選択のインデックス等）を利用者が独自コードで表現できるようにするため。
`i32` backing なので、`close(@enumFromInt(my_code))` のように任意コードも流せる。

`Dialog` は `Frame` と同じく `Window` を embed する。
共通機能（タイトル、close、resize、root container、repaint）はすべて `Window` 側にあり、`Dialog` はそこに「オーナー」と「モダリティ」を足しただけの薄い派生（`window.md`「階層と依存関係」参照）。

## ダイアログの生成
```zig
pub fn init(
    allocator: std.mem.Allocator,
    app_ptr: *anyopaque,
    event_queue: *awt.EventQueue,
    owner: *Window,
    title: []const u8,
    w: u32,
    h: u32,
    device: *awt.Device,
    context: *awt.Graphics.Context,
) !Dialog;
```

内部で `Window` を構築し、`owner` を保持した `Dialog` を返す。
`modal = false`、`result = .none`、`shown = false` で初期化する。
OS ウィンドウは生成直後に**非表示にする**（`Dialog` は close で破棄せず使い回すので、create/destroy ではなく show/hide で可視性を切り替える）。
この時点ではまだ表示されず、`showModal` / `show` を呼ぶまで Application のループにも乗らない。

利用者が直接呼ぶことは想定しておらず、`app.dialog(owner, title, w, h)` factory から呼ばれる。

### 事前条件
* `owner` が生存中の登録済みウィンドウであること（`app.frame(...)` で作った Frame の `&frame.window` 等）。

## モーダル表示
```zig
pub fn showModal(self: *Dialog) Result;
```

ダイアログを表示し、**閉じられるまで呼び出し側をブロック**して、`Result` を返す。

手順（契約として）:
1. ウィンドウを Application の windows リストに登録する（描画とイベントのループに乗る）。
2. `modal = true` にし、Application のモーダルスタックに自分を積む（「モーダル入力ブロック」参照）。
3. タイマー対応の入れ子イベントループを回してブロックする（毎反復 `Application.tickOnce`。詳細は後述「Application との連携」）。
4. ダイアログ内のボタン等が `close(result)` を呼ぶ（または X ボタンで閉じられる）と `modal_done` が立ち、入れ子ループを抜ける。
5. モーダルスタックから降ろし、windows リストから外して `result` を返す。

戻った時点で**ウィンドウは非表示（未登録）になるが、`Dialog` 自身と内部のウィジェットツリーは生存している**。
そのため呼び出し側は `showModal` の後でテキストフィールドの内容などダイアログ内のウィジェット状態を読める（後片付けは利用者が `deinit`、「寿命」参照）。

### 事前条件
* UI スレッドから呼ぶこと。
* `Application.run()` の中（イベントハンドラ等）から呼ぶこと。外側のメインループが回っている前提で入れ子ループを起こす。

## モードレス表示
```zig
pub fn show(self: *Dialog) !void;
```

ダイアログを表示して**即座に return** する（ブロックしない）。
ウィンドウを windows リストに登録するだけで、モーダルスタックには積まない。
オーナーや他のウィンドウは通常どおり操作できる。

非ブロックなので結果は戻り値では返らない。
利用者は閉じられたかどうかを `result` / `shown` のポーリング、または将来の close リスナー（機能要望）で知る。

検索パネルやツールパレットのような「開いたまま親と並行して使う」UI 向け。

## クローズ
```zig
pub fn close(self: *Dialog, result: Result) void;
```

`result` を保存してダイアログを閉じる。
OS ウィンドウを非表示にし、windows リストから外す（破棄はしない）。

* モーダル中なら `modal_done` を立てて `showModal` の入れ子ループを抜けさせる（`postEmptyEvent` で待機中のループを起こす）。
* モードレスなら非表示にして windows リストから外すだけ（`modal_done` は無視される）。

ダイアログ内の "OK" / "Cancel" ボタンのハンドラから呼ぶのが典型。
既に閉じている（`shown == false`）なら no-op。

## 結果の取得
```zig
pub fn getResult(self: Dialog) Result;
```

最後に `close` で設定された結果を返す。
まだ閉じていなければ `.none`。
モードレスダイアログで「閉じられたか」を後から確認する用途。

## ダイアログの破棄
```zig
pub fn deinit(self: *Dialog) void;
```

内部の `Window.deinit` を呼んで、ウィジェットツリー / swapchain / OS ウィンドウを解放する。
まだ表示中（`shown == true`）の場合は先に windows リストから外す。

`Frame` と違い **`Dialog` の寿命は利用者が持つ**（「寿命」参照）。
`app.dialog(...)` が返したポインタは、使い終わったら利用者が `dialog.deinit()` してから `allocator.destroy` する。

## 利用例
モーダルダイアログを開いて結果を受け取る典型コード（OK / Cancel）。

```zig
// owner は app.frame(...) で作った Frame の Window
const dialog = try app.dialog(&frame.window, "確認", 320, 160);
defer {
    dialog.deinit();          // 利用者が寿命を持つ
    init.gpa.destroy(dialog);
}

const msg = try app.label("保存しますか?");
try dialog.window.add(&msg.component);

const ok = try app.button("OK");
const cancel = try app.button("Cancel");
// ボタンの ActionListener から dialog.close(...) を呼ぶ
try ok.getModel().addActionListener(nimbus.Dialog, onOk, dialog);
try cancel.getModel().addActionListener(nimbus.Dialog, onCancel, dialog);
try dialog.window.add(&ok.component);
try dialog.window.add(&cancel.component);

const result = dialog.showModal();   // 閉じるまでブロック
switch (result) {
    .ok     => { /* 保存処理 */ },
    .cancel, .none => {},
    else    => {},
}
```

```zig
fn onOk(d: *nimbus.Dialog, _: *const Event) void {
    d.close(.ok);
}
fn onCancel(d: *nimbus.Dialog, _: *const Event) void {
    d.close(.cancel);
}
```

モードレスダイアログ（検索パネル等）を開いて、メインウィンドウと並行して使う例。

```zig
const finder = try app.dialog(&frame.window, "検索", 360, 120);
// finder は利用者がフィールドに保持して寿命を管理する
try finder.show();   // 即 return。app.run() は継続
```

## 機能要望
* `setVisible(false)` / hide（破棄せず一時的に隠して再表示）。現状は close で windows から外すのみ
* close リスナー（モードレスダイアログが閉じられたことの通知）
* 任意位置指定 / オーナー追従（オーナー移動に合わせて動く）/ オーナーが閉じたら所有ダイアログも一緒に閉じる cascade
* `JOptionPane` 相当のヘルパー（`app.confirm(msg)` → `Result`、`app.prompt(msg)` → 文字列 等の定型ダイアログ）
* `resizable` / `always on top` の切替
* ダイアログ用メニューバー（Swing `JDialog.setJMenuBar` 相当。優先度低）
* 非モーダルとモーダルの動的切替（表示中の昇格 / 降格。優先度低）
