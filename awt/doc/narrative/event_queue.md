---
unsafe: true
---

# event_queue
EventQueue の配置理由・スレッド安全性・利用パターン。

## なぜ awt 層に置くか
EventQueue は GLFW の `glfwPostEmptyEvent` で UI スレッドを起こす仕組みに依存する。
これは awt-c のイベントループプリミティブ（`nmPostEmptyEvent`、別途追加予定）と組になる。

CLAUDE.md「非同期処理」セクションでは「いくつかイベントキューに関するプリミティブを提供しなければならない」とあり、awt 層に置くのが自然。
framework 層からは `app.getEventQueue()` 経由でアクセスする（`framework/doc/application.md` 参照）。

## スレッド安全性
* `invokeLater` / `invokeAndWait` は任意スレッドから安全に呼べる
* `drain` は UI スレッドのみ
* `deinit` は他スレッドからの呼び出しが完了していることを利用者が保証する

内部はミューテックスで保護されているため、複数スレッドから同時に `invokeLater` を呼んでも順序は決定的（FIFO）。

## ドレインのタイミング
ドレインは「UI スレッドが安全にタスクを実行できる時点」で行う必要がある。
Application のイベントループでは：

1. `awt.waitEvents()` — イベント待ち（OS / GUI イベントまたは `glfwPostEmptyEvent` で起きる）
2. `event_queue.drain()` — ポストされたタスクを実行
3. 各 Window の dirty 再描画
4. OS 状態同期
5. close 回収

タスクが UI 状態を変えると `layout_dirty` / `paint_dirty` が立ち、ステップ 3 でその反映が走る。
したがって「別スレッドが invokeLater で UI 更新 → 次のイベントループで自動的に再描画」が成立する。

## 入力イベントとタスクを同じキューに並べる理由
1. **単一の入口**: GLFW から来る生の入力、`invokeLater` で投入されるタスク、テスト用の合成入力イベントがすべて同じ FIFO を通る。デバッグ時に「どの順番で何が起きるか」を 1 か所だけ見ればよい
2. **post API の公開**: `postEvent` が公開 API なので、テスト / マクロ / IME の文字確定通知 / accessibility tool 等が外部から入力イベントを差し込める（Java AWT の `EventQueue.postEvent` と同じ）
3. **ordering の保証**: 「ボタン押下 → ハンドラ内で `invokeLater(redraw)` → 次のクリック」のような並びが post された順に厳密に再生される
4. **mouse-move coalescing の足場**: 入力イベントもキューにあるので、将来「連続する `.move` を 1 個にまとめる」最適化を入れやすい（機能要望）

トレードオフは「OS コールバックから widget に届くまで 1 イベントループ分の latency が乗る」だが、60fps なら 16ms 未満で体感はほぼ無い。

## 期待される利用パターン
別スレッドで時間のかかる処理を実行し、結果を UI に反映する典型。

1. UI スレッドがワーカースレッドを spawn
2. ワーカーが長い処理を実行
3. 完了したら `invokeLater` で「結果を UI に反映するタスク」をポスト
4. UI スレッドが次のループでそのタスクを実行 → setText 等で UI 更新
5. 再描画が自動的に走る

`invokeAndWait` は「ワーカーが UI スレッドの応答を待たないと先に進めない」場合のみ使う（稀）。
理由：UI スレッドの応答時間に依存するため、ワーカーがブロックする。
通常は `invokeLater` で fire-and-forget するか、`std.Thread.Channel` などで結果を返す。
