---
unsafe: false
---

# dialog
Dialog の Frame との違い・モーダル入力ブロック・Application との連携・位置/サイズ・委譲方針。

## Frame との違い
| | `Frame` | `Dialog` |
|---|---|---|
| オーナー | なし（独立トップレベル） | 必須 |
| モダリティ | なし | モーダル / モードレス |
| 表示の入口 | 生成時に即 windows 登録 | `showModal` / `show` で明示的に登録 |
| 寿命の所有者 | Application（windows リスト経由で close / `app.deinit` で破棄） | **利用者**（`deinit` を自分で呼ぶ） |

寿命を利用者所有にする理由:
* モーダルは「閉じた後にダイアログ内のウィジェット状態を読む」のが普通（入力されたテキスト等）。閉じた瞬間に破棄すると読めない。
* 同じダイアログを使い回して複数回 `showModal` したいことがある。

`Frame` はアプリ常駐の主ウィンドウで「閉じる = 破棄」が自然なので Application 所有。
`Dialog` は「開いて結果を受け取り、後で破棄」というライフサイクルなので利用者所有。
この非対称は意図的。

## モーダル入力ブロック
GLFW / OS はウィンドウ単位のモダリティを提供しないので、**入力ブロックは nimbus 側で実装する**。

仕組み（契約）:
* Application はモーダルダイアログのスタックを持つ（入れ子モーダルに対応）。
* スタックが非空のとき、入力イベント（mouse / key / char）は **スタック最上位のダイアログのウィンドウにだけ** dispatch し、それ以外のウィンドウ宛ては drop する。
* オーナーや他の Frame は描画は続くが、クリックやキー入力には反応しなくなる。
* close リクエスト（X ボタン）は例外的に処理し、対象がモーダルダイアログ自身なら `close(.none)` 相当として扱う。オーナーの close はモーダル中は無視する（モーダルを閉じてから）。

詳細な dispatch ルールは `window.md`「3 層の dispatch 順」を拡張する形で実装側に置く。

`input_blocked` はウィジェットへの入力を止めるだけで、OS レベルのウィンドウ操作（前面化・フォーカス・移動）までは止められない（GLFW にウィンドウ単位のモーダルがない）。
そのままだとオーナーを前面に出してモーダルを隠せてしまい「モーダルでない」感覚になるため、モーダル表示中はダイアログを **floating（常に最前面）+ focus** にしてオーナーの上に固定する（`awt.Window.setFloating` / `focus`）。
close でこれを解除する。
floating + `input_blocked` の二段で、「オーナーの上に必ずダイアログが見え、かつオーナーのウィジェットは反応しない」というモーダルの体感を作る。

### 注意喚起の点滅
Swing / NetBeans と同じく、**ブロックされたウィンドウをクリック / キー押下するとモーダルダイアログのウィンドウ枠を点滅させて**「こっちを先に処理して」と促す。
`dispatchInput` がブロック時に press 系イベント（mouse press / key press）を捨てる際に `Application.flashActiveModal` → `awt.Window.requestAttention` を呼ぶ。
move / scroll / release のような受動的イベントでは点滅させない（ホバーで点滅し続けないように）。

点滅は **OS のウィンドウ枠効果**で行う（`awt.Window.requestAttention`）:
* Windows: `FlashWindowEx`（`FLASHW_ALL`）でタイトルバー + タスクバーを数回点滅させる。DWM のドロップシャドウも一緒に点滅する。
  GLFW 標準の `glfwRequestWindowAttention` は単発の `FlashWindow` で弱いため、awt-c 側で `FlashWindowEx` を直接呼ぶ。
  前面でないウィンドウにだけ効くが、ここではユーザーが（ブロックされた）オーナーをクリックした直後＝オーナーが前面・ダイアログは背面なので点滅する。
* macOS: dock アイコンのバウンス（`glfwRequestWindowAttention`）。

これはウィンドウ枠の効果なので、**ダイアログがオーナーの外に完全にはみ出して配置されている場合は枠の点滅が視界に入らない**ことがある。
これは Swing / NetBeans でも同じ挙動（ドロップシャドウ＝枠を光らせる方式の本質的な制約）であり、nimbus でも同様とする。
ダイアログは既定でオーナー中央に出る（「位置とサイズ」参照）ので通常は問題にならない。

## Application との連携
`Dialog` のウィンドウも `Frame` と同様、表示中は Application の `windows: ArrayList(WindowEntry)` に `*Window`（= `&dialog.window`）として登録される。
これにより Application のループが Frame / Dialog を区別せず一律で描画・close 回収できる（`application.md` / `frame.md`「Application との連携」参照）。

ただし `WindowEntry.destroy` の扱いが Frame と異なる:
* Frame は close 回収時に `destroy` まで走らせて破棄する。
* Dialog は close 回収時に windows リストから外すだけで、`Dialog` オブジェクト本体は破棄しない（利用者所有のため）。

モーダル表示中は Application の**メインループではなく `Dialog.showModal` の中の入れ子ループ**がイベントを回す。
この入れ子ループは `app.run` と同じく **タイマー対応**（最も近い timer の `due_time` まで `waitEventsTimeout`、なければ `waitEvents`）で、毎反復 `Application.tickOnce`（`fireDueTimers` / `drain` / dirty ウィンドウの `redraw` / close 回収）を呼ぶ。
`close` が `modal_done` を立てるとループを抜ける。

タイマー対応なので、モーダル中もダイアログ内 `TextField` のキャレット点滅などタイマー駆動の UI が正しく動く（素の `awt.waitEvents` だけでは次のイベントが来るまで止まるため、`Application.earliestDueIn` を見て `waitEventsTimeout` で起こす形にしている）。
モーダル中もダイアログ・オーナー双方が描画され、別スレッドからの `invokeLater` も消化される。

## 位置とサイズ
v1 ではオーナーの中央に配置する（オーナーの bounds の中心に、ダイアログの w / h を中央寄せ）。
`Window` の position は OS 絶対座標で扱う（`window.md`「position / size のセマンティクス」参照）ので、オーナーの絶対座標から計算する。

任意位置指定やオーナー追従（オーナー移動に合わせて動く）は機能要望。

## 委譲メソッドは生やさない
`add` / `setTitle` / `repaint` 等は `Dialog` に生やさず、`dialog.window.add(...)` のように `window` フィールド経由で直接呼ぶ。
`Frame` と同じ方針（`frame.md`「委譲メソッドは生やさない」、`component.md`「派生型から Component メソッドへのアクセス」参照）。
