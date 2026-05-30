---
unsafe: false
---

# event
入力イベント型まわりの設計判断・座標系・各 payload の意味・awt-c との関係。

## 消費モデル
イベントは Component ツリーで dispatch されるが、ある時点で「これは私が処理した」と宣言できる仕組みが必要。
nimbus では `Event.consumed: bool` フィールドで表現する。

* ハンドラ（`Component.vtable.processEvent`）は `event.consume()` を呼んで消費を宣言する
* framework の dispatcher は親へのバブリング前に `event.isConsumed()` を確認し、true なら伝搬を止める
* `consumed` は読み取り可能なので、複数ハンドラがある場合に「既に他のハンドラが処理したか」を見て挙動を変えられる

Java AWT の `AWTEvent.consume()` / `isConsumed()`、DOM の `Event.stopPropagation()` に近い設計。
vtable.processEvent のシグネチャは `*Event`（mutable）+ `void` 返却で、消費は戻り値ではなくフィールド経由。

### 部分的な処理を許す
return-bool 方式（消費 = 伝搬停止）と異なり、フィールド方式は「読み取るが消費しない」処理を表現できる。
たとえば「キーログを取るが、実際のキー処理は子に任せる」ような透明ハンドラが書ける。

## 座標系
MouseEvent の `x` / `y` は **ウィンドウローカル座標**（ウィンドウの左上が `(0, 0)`、右下が `(window_width, window_height)`）で届く。
ウィンドウの OS 絶対座標とは別物（OS 絶対座標は `framework.Window` の `component.position` 経由でアクセス可、`window.md` 参照）。

コンポーネントの bounds は「親 Container 内のローカル座標」で表現されているので、深くネストされたコンポーネントがマウスイベントを受け取るときには、ウィンドウローカル座標から自身のローカル座標へ変換する必要がある。

```
window-local mouse pos (300, 250)
   - container.position           (200, 200)   ← Container 自身の位置
   - label.position               (50, 30)     ← Container 内の Label 位置
   = label-local mouse pos        (50, 20)
```

これは framework の dispatcher が tree を辿りながら累積的に `translated` を適用する形で実現される。
利用者の `processEvent` には常にコンポーネントローカル座標の Event が届く。

### 親階層の絶対オフセット計算
framework は `Component.absoluteOriginInWindow(c: *const Component) Point` のような helper を提供する（詳細は `framework/doc/component.md` 参照）。
awt 層は座標計算ロジック自体を持たず、`Event.translated(offset)` という汎用 helper だけを提供する。

## KeyCode の値域
`KeyCode` は GLFW のキーコード（`GLFW_KEY_*`）に対応する `i32` enum。
具体的な値の対応は実装側で `c.GLFW_KEY_*` を直接 `@enumFromInt` する。
利用者は文字（`'a'`、`'5'` 等）ではなく enum 名（`.a`、`.digit_5`、`.enter` 等）で参照する。

主要なものを抜粋:

| 名前 | 用途 |
|---|---|
| `.a` ... `.z` | アルファベット |
| `.digit_0` ... `.digit_9` | 数字キー |
| `.f1` ... `.f12` | ファンクションキー |
| `.enter` / `.space` / `.tab` / `.escape` / `.backspace` / `.delete` | 制御キー |
| `.arrow_left` / `.arrow_right` / `.arrow_up` / `.arrow_down` | 矢印キー |
| `.shift_left` / `.shift_right` / `.ctrl_left` / `.ctrl_right` / ... | 修飾キー単体 |

修飾キーの状態は `Modifiers` 経由で取得する方が普通（`KeyEvent.modifiers.ctrl == true` 等）。
修飾キー自体の押下を検知したいときだけ `KeyCode.shift_left` 等を見る。

## マウスキャプチャ
ドラッグ操作（Slider つまみのドラッグ、Button の押下中ドラッグ取り消し等）では、カーソルが widget の bounds 外に出ても `.move` / `.release` を受け取り続ける必要がある。
hit-test ベースの素朴な dispatch では、カーソルが外れた瞬間にイベントが届かなくなりドラッグが途切れる。

これを解決するのが「マウスキャプチャ」。
具体的な流れ：

1. widget の `processEvent` が `.press` を受け取り、ドラッグ中の追跡が必要だと判断する
2. `ev.requestCapture(@ptrCast(self))` を呼ぶ（`self` は `*Component`）
3. framework 側 dispatcher が press 終了後にこの値を読み取り、capture state に保存する
4. 以降の `.move` イベントは hit-test を経由せず capture 先へ直接配送される
5. `.release` イベントも capture 先へ直接配送され、その後 capture state はクリアされる

awt 層自身は capture state を持たない。
awt は型を提供するだけで、実際の routing は framework の責務。
詳細は `framework/doc/window.md`「マウスキャプチャ」を参照。

## MouseAction の意味
| `action` | `button` | `wheel` | 意味 |
|---|---|---|---|
| `.press` | non-null | 0 | ボタン押下 |
| `.release` | non-null | 0 | ボタン解放 |
| `.move` | null（ボタン押下中のドラッグ時は ?） | 0 | カーソル移動 |
| `.scroll` | null | 非 0 | ホイール |

ドラッグ中の `move` で `button` を non-null にするか null にするかは、framework 層が dispatcher で決める。
awt 層は OS から来た情報をそのまま MouseEvent に詰めるだけ。

## CharEvent と KeyEvent の使い分け
`KeyEvent` は **物理キーの押下** を表す（`.code` は GLFW の `GLFW_KEY_*` 相当）。
`CharEvent` は **入力された文字** を表す（`.codepoint` は OS のキーボードレイアウトを通過した後の Unicode codepoint）。

| 用途 | 使うべきイベント |
|---|---|
| テキストフィールドへの文字入力 | `CharEvent` |
| ショートカット（Ctrl+S 等）の検出 | `KeyEvent`（`modifiers` を見る） |
| カーソル移動・編集操作（矢印 / Home / Backspace / Del） | `KeyEvent` |
| IME 変換中の文字列表示 | （将来）独立した composition イベント |

両者は同じキー操作に対して**両方発火する**ことがある。
たとえば `'a'` キーの押下では `KeyEvent{ .code = .a, .action = .press }` と `CharEvent{ .codepoint = 'a' }` が両方流れてくる（OS から見ると別系統のイベント）。

`CharEvent.codepoint` に修飾キーフィールドは持たない。
Shift+1 は OS がすでに `'!'` に変換した状態で来るので、利用者は文字そのものだけ見ればよい。

## FocusEvent
キーボード入力先のコンポーネント（フォーカスオーナー）が切り替わる際に dispatch される。
OS から来るのではなく framework 側（`Window.requestFocusFor`）が生成する点が他の payload と異なる。

旧オーナーには `FocusEvent{ .gained = false }`、新オーナーには `FocusEvent{ .gained = true }` がそれぞれ届く。
両方に届く順序は「旧オーナー lost → 新オーナー gained」。

`null → Component` や `Component → null` への切り替えも有効（片側だけが dispatch される）。

## CompositionEvent
IME（日本語・中国語・韓国語入力など）の **preedit (変換中文字列)** を運ぶ。
ユーザーが IME で入力中、確定する前の文字列がここに届く。

`text` は現在の preedit 文字列の借用 UTF-8（awt-c が所有、コールバックの有効期間のみ valid）。
ハンドラ側が保持したいなら呼び出し直後に `allocator.dupe` で複製を取る。

`target_start` / `target_end` は `text` 内の **byte offset** で、利用者が今変換中のクローズ（節）を指す。
ウィジェットはこの範囲を太い下線・濃い背景などで強調表示するのが一般的。
`target_start == target_end` のときは「変換中の特定範囲なし」を意味し、両者は preedit 内のキャレット位置として扱える。

空文字列 (`text.len == 0`) は **composition cleared** のシグナル（キャンセル or 確定）。
**確定文字列は CharEvent で別途届く**ので、ウィジェットは preedit overlay をクリアするだけでよい（commit を二重処理しない）。

OS との連携:
* preedit string の取得 → awt-c の `nmCompositionCallback` 経由
* IME 候補ウィンドウの位置設定 → `Window.setCompositionCursorPos(x, y, height)` でキャレット座標を push

現状の実装:
* Windows: WNDPROC subclass + IMM32 で `WM_IME_COMPOSITION` を拾う
* macOS: NSView の runtime subclass で `NSTextInputClient.setMarkedText:` / `firstRectForCharacterRange:` を intercept
* Linux: stub（no-op）。Wayland text-input v3 ベースの実装が将来追加される予定

## awt-c との関係
awt-c は GLFW の C 関数ポインタ型でコールバックを受ける（`nmKeyCallback`、`nmCharCallback`、`nmMouseButtonCallback`、`nmCursorPosCallback`、`nmScrollCallback` 等）。
これらのコールバックは個別の引数（コード / 文字 / ボタン / 座標 / スクロール量）を受け取る形になる。

加えて、IME 用に `nmCompositionCallback`（GLFW にはなく awt-c 独自）がある。
これは GLFW を経由せず、プラットフォーム別バックエンド（Windows: WNDPROC subclass、macOS: NSView runtime subclass + NSTextInputClient、Linux: Wayland text-input（予定））が直接 fire する。

awt 層がそれらを Zig の `Event` 型に統合してから framework に渡す。
`FocusEvent` は OS 由来ではなく framework が生成するため対応するコールバックは存在しない。
このため awt-c では「Event」という統合型は存在せず、event.md は awt 層のみに存在する。
