---
unsafe: false
---

# application
Application の責務・ファクトリ方針・OS との同期・イベントキュー・タイマー・共有リソース。

## 責務
* アプリ全体の **アロケータ所有者**（ウィジェット / ウィンドウは全部ここの allocator で確保される）
* **ファクトリ**（`app.frame(...)`、`app.label(...)`、`app.button(...)` 等）
* **イベントループの主体**（`app.run()`）
* **共有リソースの所有者**（Graphics.Context、default font、EventQueue、ビルトインアイコンキャッシュ）
* **ウィンドウ追跡**（全 Window を `WindowEntry` で持ち、OS state diff を末尾で push）

## なぜ Application を作るのか（Swing との違い）
Swing には Application 型が無く、`JFrame` を直接 `new` する。
nimbus はあえて Application を持つ。

* **アロケータの集約**: Zig は GC が無いので allocator がアプリ全体に必要。ファクトリが allocator を握るのが素直
* **イベントループの隠蔽**: 利用者が `glfwPollEvents` / `glfwWaitEvents` を直接触らなくて済む。`app.run()` 1 つで起動
* **共有リソースの一元化**: Graphics.Context（programs / rings / atlas）や default font は重く、アプリ全体で 1 セット使うのが自然
* **ウィンドウ追跡**: 全 Window を 1 箇所で管理する場所が必要（OS state diff、close 回収、全ウィンドウクローズ判定）

参考: 後発の SwingApplicationFramework（JSR 296）は `Application` を導入していた（その後消えたが）。
nimbus は最初から入れる。

## プロセス内で 1 インスタンス
GLFW は `glfwInit` がプロセス単位なので、Application も実質シングルトン。
ただし型レベルでシングルトン強制（`getInstance()` パターン）はしない。
単に「2 個作るとうまく動かない」と doc で握る。

理由: テスト時に複数 Application を入れ替えて使うケース（mock や差し替え）が将来出るかもしれないので、強制よりは規約に留めておく。

## ファクトリの責務
ファクトリは「allocator 確保 + init + install + tracking 登録」を 1 まとめにする（`component.md`「ライフサイクル」参照）。
利用者は戻り値のポインタを使って setter / add 等を呼ぶだけで、メモリの面倒は見ない。

Window 系のファクトリは追加で `windows` リストへの append が要る。
ウィジェット系のファクトリはウィジェットの `create` をラップするだけ（default font / color を注入する）。

## OS との同期
位置とサイズの同期は実装済みで、**双方向**（コード → OS、OS → コード）に動く。
各イベントループ末尾 (`tickOnce` → `syncWindowGeometry`) で、すべての `WindowEntry` について以下の比較を行う。

* `window.getPos() != synced_pos` → `awt_window.setPos(...)` で OS に push、`synced_pos` を更新
* `window.getSize() != synced_size` → `awt_window.setSize(...)` で OS に push、`synced_size` を更新

ウィンドウ側の希望値は `framework.Window` の `win_pos` / `win_size` が保持する（利用者は `setPos` / `setSize` で更新する）。
`WindowEntry` 側の `synced_pos` / `synced_size` は「OS と同期済みの値」を覚える。
登録時 (`frame` / `registerDialog`) は両者を初期ジオメトリで揃えておく。

逆方向（OS 由来の移動 / リサイズ。利用者によるドラッグ等）は、それぞれのコールバックが値を書き戻す。

* 移動: `Window.onWindowPos` が `win_pos` を新しい screen 位置に更新
* リサイズ: `Window.onResize` が `win_size` を実サイズに更新

いずれも続けて `Application.noteOsGeometry` を呼び、`synced_*` も同時に更新する。
これがないと「OS が動かした → 末尾の diff で push し返す」の無限ピンポンになり、ライブな移動 / リサイズと喧嘩する。

タイトルは `Window.setTitle` が直接 awt-c に push する (loop-tail sync は経由しない)。
頻度が低いため一貫性より素直さを優先した。

## イベントキュー（invokeLater / invokeAndWait）
別スレッドから UI を触る唯一の正規ルート。CLAUDE.md「非同期処理」セクションを参照。

`invokeLater` / `invokeAndWait` は Application のメソッドとしては生やさず、Application が所有する `awt.EventQueue` のメソッドとして提供する。
Application からは `getEventQueue()` でアクセスする。
`invokeAndWait` は別スレッドから呼ぶ前提（UI スレッド自身から呼ぶとデッドロック）。assert で弾く。

EventQueue 自体の詳細な API は awt 側の doc で扱う。
Application はその所有とイベントループ内でのドレイン（`event_queue.drain()`）だけを担当する。

## タイマー
caret 点滅、ツールチップの遅延表示、tween アニメーション等の「未来のある時刻に UI スレッドで処理を実行したい」用途を、Application が一元的に提供する。

仕組み:
* `setTimeout` / `setInterval` で登録すると `timers` リストに `Timer` が積まれ、`due_time = awt.time() + delay` がセットされる
* run ループは毎回開始時に最も近い `due_time` までの残り秒を計算し、`awt.waitEventsTimeout(delta)` でブロックする
* OS イベント到着 or タイムアウトのどちらで戻っても `fireDueTimers` が `due_time <= now` の Timer を順に呼ぶ
* ワンショット (`period_ms = 0`) は発火後にリストから外す。繰り返し (`period_ms > 0`) は `due_time = now + period_ms / 1000` で更新する

精度:
* GLFW の `glfwWaitEventsTimeout` 精度に依存。Windows では 1ms オーダーまで詰められるが、OS スケジューラ遅延で数ミリ秒のジッタは普通に発生する
* ms 精度が要求される用途 (60fps 連続アニメーション等) には不向き。`requestAnimationFrame` 相当は機能要望

スレッド:
* `setTimeout` / `setInterval` / `clearTimer` / `cb` の呼び出しはすべて UI スレッドで完結する前提
* 別スレッドから時間遅延でタスクを差し込みたい場合は、別スレッド側で `std.Thread.sleep` してから `event_queue.invokeLater(...)` を呼ぶ方が安全

注意:
* タイマー登録の所有権は Application。`clearTimer` を呼ばずに widget を destroy するとコールバックが解放済みメモリを触る。widget の `uninstall` で必ず `clearTimer` を呼ぶ規約
* 発火順は「due_time の昇順」ではなく `timers` への登録順なので、同時刻に複数 due があるケースでは登録順に発火する (ms 単位で別なら昇順と等価)

## 入れ子イベントループ
モーダルダイアログは `Application.run()` の中からさらに小さなイベントループを回す。
`Dialog.showModal` がインスタンス固有の `modal_done` フラグを持ち、`Application.modal_stack` がネスト順を管理する (`framework/doc/dialog.md` 参照)。

入れ子ループの典型的な per-iteration 処理 (`fireDueTimers` / `drain` / dirty ウィンドウの redraw / close 回収) は `Application.tickOnce` に集約されていて、メインループと同じものを使う。

## 共有リソース

### Graphics.Context
programs（Color / Image / RoundedRect / Text）と ring バッファ（vertex_ring / uniforms / quad_index）と glyph_atlas を束ねたもの。
Application が所有し、全 Window が借用する。

なぜ Application 所有か:
* programs は shader compile を含むので 1 回作って共有が自然
* ring バッファ / atlas はメモリが大きく、Window 毎に持つと無駄
* 全 Window が同じ font atlas を共有すると glyph cache 効率が良い

### default_font
framework に同梱された Noto Sans JP（Latin + CJK JP）を `@embedFile` で焼き込んだものを Application init で読み込む。
本体は `framework/src/noto/NotoSansJP-Regular.ttf`、Zig 側からは `nimbus.noto.noto_sans_jp_regular` でバイト列としても参照できる（awt を直接叩く利用者向け）。
Label / Button 等のウィジェットファクトリが借用する。寿命は Application と同じ。

v1 ではランタイムでの差し替え API は無い。
差し替えたい場合は CLAUDE.md「フォント」を参照しつつ、利用者が独自 widget factory を組む形になる（機能要望）。

### icon_cache
ビルトインアイコン（`nimbus.lucide.Icon` の各エントリ）を、初回参照時にデコード + GPU テクスチャ化した `awt.Image` のキャッシュ。
`[lucide.Icon.count]?awt.Image` の配列で、添字は `@intFromEnum(icon)`。
Application init 時は全スロット null で、`app.icon(.foo)` の初回呼び出しでスロットが埋まる。
Application が所有し、Button / MenuItem 等が借用する。寿命は Application と同じ。

なぜ Application 所有か:
* 同じアイコンを複数のウィジェットが使い回しても GPU テクスチャは 1 つで済む
* 利用者が `awt.Image.fromMemory` / `deinit` を自分で書く必要が無くなり、boilerplate が消える
* デコード + GPU アップロードは重いので、初回 1 回だけにしたい
* 寿命がウィジェットより長い場所に置く必要があり、Application が自然な置き場所

### サイズコストの整理
ランタイムメモリ:
* `?awt.Image` 1 スロットは数十バイト程度。1711 エントリでも数十 KB に収まるため、Application が常時抱える分は無視できる。
* GPU 側のメモリは初回呼び出し時にしか確保されないので、未使用アイコンに対する GPU メモリのコストは 0。

バイナリサイズ:
* `Application.icon` がランタイムの `Icon` 値を受け取る設計のため、コンパイラ／リンカは「どのアイコンが使われるか」を静的に判定できず、`framework/src/lucide/icons.zig` の `all_bytes` 経由で**全 PNG が実行ファイルに残る**。
* 実測値: `widget_menu` (ReleaseSmall) で +1.7 MB（アイコンを 1 つも使わない `widget_simple` は影響なし）。
* これは設計上の意図的トレードオフ。`app.icon(.foo)` の使い勝手と、コンパイル時 typo チェックを優先した結果。
* switch 分岐版 (`switch (self) { .save => @embedFile(...), ... }`) でも実測差は出なかった。`Icon.bytes()` という間接層を挟む限り、デッドコード除去は原理的に効かない。

## 終了条件
`run()` は `windows.items.len > 0` の間ループする。
最後のウィンドウが閉じた時点でループを抜けて return する。
「ウィンドウが全部閉じても常駐したい」ケース向けの hook は将来追加する（機能要望参照）。

## 関連 doc
* `window.md` — Window / WindowEntry の詳細、イベントループとの関係
* `frame.md` — Frame factory の流れ
* `component.md` — ファクトリのライフサイクル / メモリ解放
* `binding.md` — Application 経由のファクトリが他言語バインディングでどう見えるか
