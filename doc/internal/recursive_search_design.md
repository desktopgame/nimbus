# 再帰検索（dogfooding #5）設計ノート

app_filer に「名前部分一致のサブツリー検索」を足すための設計。
これは framework にとって **初の本格 async**（時間のかかる FS 歩きを別実行に逃がし、
ヒットを UI スレッドへ逐次フィードバックし、キャンセル可能にする）なので、
実装よりも設計と検証戦略を厚く取る。本ノートは Codex 実装の前提資料。

対象バックログ: dogfooding #5（`doc/internal/dogfooding_backlog.md`）。
完了条件: 大きなツリーで検索中も UI が固まらず、結果が逐次出て、再検索 / キャンセルが安全。

---

## 1. 現状の async 基盤（実コード調査）

「想定」ではなく実コードで確認した事実のみを書く。該当ファイル・関数を明示する。

### 1.1 UI スレッド marshalling = `awt.EventQueue`（実在・スレッド安全）

`awt/src/EventQueue.zig`。Application が 1 個所有（`framework/src/Application.zig:86 event_queue`）。

- `invokeLater(self, fn_ptr, user_data) !void`（`EventQueue.zig:71`）
  - **実装済み・スレッド安全**。内部 `std.Io.Mutex` でキューをロックして 1 アイテム append し、
    `awt_root.postEmptyEvent()`（`awt/src/root.zig:29` → `nmPostEmptyEvent`）で UI スレッドを起こす。
  - **どのスレッドからでも呼べる**（doc/event_queue.md「事前条件: どのスレッドから呼んでもよい」）。
  - `fn_ptr` は UI スレッドで実行される前提。`user_data` は不透明ポインタ。
  - app_filer は既にこれを使う（`scheduleReload`→`reloadTask`、`startPendingEdit`→`pendingEditTask`）。
- `invokeAndWait`（`EventQueue.zig:88`）: UI スレッドが実行し終えるまでブロック。
  **UI スレッドから呼ぶと debug assert で死ぬ**（デッドロック防止）。検索では使わない。
- `postEvent`（`EventQueue.zig:111`）: 入力イベント用。Robot の合成入力もこれ。
- `drain(self)`（`EventQueue.zig:140`）:
  - **UI スレッドのみが呼ぶ**。呼んだ瞬間にキューにあったぶんだけ処理する
    （`std.mem.swap` でローカルへ抜き取ってから実行）。
  - **drain 中に新たに post されたアイテムはこの drain では拾わない**（次の drain 行き）。
    → ここが決定性に効く。1 回の drain は「その瞬間のスナップショット」だけを流す。
- `setUiThread`（`EventQueue.zig:65`）: UI スレッド id を記録（`Application.init:180` で現在スレッド登録）。

### 1.2 ループ駆動と仮想クロック

- `Application.tickOnce`（`Application.zig:282`）: `fireDueTimers()` → `event_queue.drain()` →
  `syncWindowGeometry()` → dirty window の `redraw()` → `collectClosedWindows()`。
- `Robot.pump`（`Robot.zig`）= `app.tickOnce()` をそのまま呼ぶ。よって **pump 1 回 = drain 1 回**。
- `initHeadless`（`Application.zig:190`）は `clock_mode=.virtual`。
  `advanceClock(ms)`（`Application.zig:255`）が `virtual_now` を進めるだけで、
  **タイマーは次の pump まで発火しない**。検索は時間ではなくイベントで進めるのでクロックに依存させない。
- **async ワークが実スレッドで走る場合、その完了が UI/Robot に伝わる唯一の経路は
  `invokeLater`（→ 次の `pump` の `drain`）**。Robot は OS 待ちをしないので、
  ワーカースレッドが `invokeLater` した結果は「次に誰かが `pump` した時」に初めて現れる。
  → これが後述の非決定性の根。

### 1.3 既存のワーカーパターン（ドキュメント済みの正攻法）

`awt/doc/event_queue.md`「利用例」が **`std.Thread.spawn` + `invokeLater`** を正式パターンとして載せている。
`io.async` / `std.Io.Dir.Walker` はリポジトリ内で **まだ一度も使われていない**
（`grep io.async` ヒット 0）。app_filer は `std.Io.Dir`（同期 API）を `loadDir` 等で使用。

### 1.4 キャンセル機構

- framework / awt に **汎用キャンセル機構は無い**。あるのは `Application.clearTimer`（タイマー解除）だけ。
- `EventQueue` の「機能要望」に「タスクの cancel / dedupe / coalescing」が挙がっているが **未実装**。
- → 検索のキャンセルは **アプリ側で自前のトークン（atomic フラグ + 世代カウンタ）** を作る。

### 1.5 teardown の順序（UAF を踏んだ実績があるので厳密に）

`examples/app_filer/main.zig` の `main` / smoke test とも defer 登録順は同じ:
```
const filer = try build(...);
defer filer.deinitModel(gpa);  // 登録1 → 実行は最後
defer app.deinit();            // 登録2 → 実行は2番目
defer filer.deinitUi();        // 登録3 → 実行は最初
```
**実行順 = deinitUi → app.deinit → deinitModel**。
- `deinitUi`（`main.zig:132`）: entries / places / popup / dialog / ghost を解放（UI 側資産）。
- `app.deinit`（`Application.zig:212`）: window 破棄 → **`event_queue.deinit()`**。
  `EventQueue.deinit` は **キュー残タスクを破棄（実行しない）**。
- `deinitModel`（`main.zig:143`）: 共有 `model.deinit()` と `gpa.destroy(self)`（Filer 本体解放）。

ここから導かれる不変条件:
- ワーカースレッドと、それが `invokeLater` したタスクは「Filer 本体・result UI・検索 job」を触る。
- **app.deinit より前（= deinitUi の中）でスレッドを join しないと**、event_queue.deinit がキューを
  捨てた後にスレッドが post → 解放済みキューや Filer を触って UAF/leak。
- **Filer 本体は deinitModel まで生きている**（最後に解放）。result UI は deinitUi で解放される。
  → 「停止 + join + 残タスク処理」は **deinitUi の先頭**で行うのが正解（後述 §4）。

---

## 2. UI 設計

### 2.1 検索ボックスの置き場所

`build`（`main.zig:1204`）の north トースバー（`bar`, `BoxLayout.horizontal`）を 2 段化する。
- north に縦 `BoxLayout` のコンテナ `north_stack` を置き、
  - row1 = 既存ツールバー（up / view / gap / path_field）
  - row2 = 検索バー: `search_field`(growX=1) + `search_button`("Search") + `cancel_button`("Cancel") + `result_count`(Label)
- 既存の `BorderLayout.add(&window.container, .north, ...)` は `north_stack` を載せ替えるだけ。
- 起動 UX: 常時表示で十分（Ctrl+F でフォーカスを当てるキーバインドは任意の上積み）。
- `search_field` の submit（Enter）= 検索開始。`cancel_button` = 実行中検索の停止。
- Esc / 空クエリ submit = 検索終了（結果ビューを畳んで元ビューへ戻す）。

### 2.2 結果ビューは既存 CardLayout の **第3カード**として出す

右ペインの `right_center`（`CardLayout`、`main.zig:1255`）は今 `list_sp` / `table_sp` の 2 枚を持ち、
`card.active` で 1 枚だけ表示している。ここに **`results_sp`（結果リストの ScrollPane）を 3 枚目**として add する。
- 検索開始時: `prev_view`(= 現在の `card.active`) を退避 → `card.active = results_sp` → markLayoutDirty+repaint。
- 検索終了時: `card.active = prev_view` に戻す。
- これは `setViewMode`（386）と同じ仕組みの素直な拡張で、新規レイアウト機構は不要（既存 recipe の再利用）。
- 検索中は view 切替ボタンは「結果モードでは無効化 or 無視」（実装簡素のため無視で可、要コメント）。

結果リスト = `app.list` + `ResultCell`（アイコン + 相対パス表示）。1 行 = 1 ヒット。
- ダブルクリック / Enter: ヒットの親ディレクトリへ `loadDir` し、`requestSelectName(basename)` で当該行を選択
  （既存の pending-select 機構をそのまま使う）。これで「検索 → 飛ぶ」が既存部品で完結する。
- 結果の backing data は Filer 所有の `results: std.ArrayList(*Hit)`（`Hit{ path: []u8 }`）。
  この ListModel は app_filer 内に新設（`results_model: Model`）。共有 `model` とは別。

### 2.3 ステータス表記

`result_count` Label と既存 status を更新: `searching… N` / `done: N found` / `cancelled (N)` / `no matches`。

---

## 3. 非同期ウォーク設計

### 3.1 実行バックエンドは抽象化（= 決定性の継ぎ目）

`io.async` の並行性は Io 実装依存で **本リポジトリでは未検証**（使用実績 0）。
一方 `std.Thread.spawn + invokeLater` は **event_queue.md が公式パターンとして載せ、app_filer の隣接 API も同流儀**。
→ **本番は `std.Thread.spawn + std.Io.Dir.Walker`（同期 FS API をスレッドで回す）を採用**する。
`io.async` は将来このバックエンドを差し替える候補として残す（§5 / §6）。

実行を `SearchRunner` で抽象化し、注入可能にする:
```zig
const RunnerKind = enum { threaded, manual };
```
- `.threaded`（本番 / `Application.init` 経路）: 検索開始で `std.Thread.spawn(walkThread, job)`。
- `.manual`（テスト / `initHeadless` 経路で build に渡す）: スレッドを起こさず、
  テストが `filer.searchStepForTest(n)` を直接呼んで n エントリぶん進める。
  ヒットの publish 経路（invokeLater）は本番と完全に同一にする（経路を「真に突く」ため）。

`build` のシグネチャに `runner: RunnerKind = .threaded` を足す（既存呼び出しは default、テストは `.manual` 指定）。

### 3.2 publish/process パターン（SwingWorker 流）

ワーカー → UI への受け渡しは **世代スタンプ付きのヒープ Batch** で行う。共有可変状態を最小化する。

```zig
// 検索 1 回ぶんの制御ブロック。Filer が 1 個だけ所有し、停止 + join 後にのみ解放する。
const SearchJob = struct {
    gen: u64,                               // この検索の世代（開始時に filer.search_gen から採番）
    cancelled: std.atomic.Value(bool),      // ワーカーが各エントリで polling
    thread: ?std.Thread = null,             // .threaded のときのみ
    root: [PATH_BUF]u8, root_len: usize,    // 検索ルート（curPath のスナップショット）
    query: [NAME_BUF]u8, query_len: usize,  // クエリのスナップショット（小文字化済み）
    allocator: std.mem.Allocator,           // ★スレッド安全な allocator であること（§3.4）
    io: std.Io,
    filer: *Filer,                          // back-pointer（Filer は最後まで生存）
    state: enum { idle, running, done, cancelled } = .idle, // 状態機械（純ロジック単体テスト対象）
};

// UI へ渡す 1 バッチ。paths を所有する。
const Batch = struct {
    gen: u64,
    filer: *Filer,
    paths: [][]u8,     // ヒープ。publishBatch が消費して free する
};
```

ワーカー（`walkThread` / `searchStepForTest` 共通の中核 `produce`）:
1. `std.Io.Dir.Walker` でルート以下を歩く（または手動スタック）。
2. 各エントリ: `if (job.cancelled.load(.acquire)) break;`
3. 名前が `query`（小文字部分一致）にマッチ → フルパスを dupe してローカル batch buffer に push。
4. batch が K 件（例 32）たまる or 末尾で `flush`: `Batch` をヒープ確保 → `invokeLater(publishBatch, batch)`。
5. 走り終え or キャンセルで `invokeLater(finishTask, doneMsg)`（doneMsg も gen 付きヒープ）。

UI 側タスク（必ず gen ガード）:
```zig
fn publishBatch(ud) {
    const b: *Batch = ...;
    defer freeBatch(b);                       // paths も struct も常に解放（leak しない）
    if (b.gen != b.filer.search_gen) return;  // 世代違い = stale → 何もせず free だけ
    for (b.paths) |p| b.filer.appendResult(p);// 結果モデルへ（appendResult が dupe or move）
    // ステータス更新は setStatus 経由
}
```
- **stale 判定が `filer.search_gen` と `b.gen` の比較だけ**で済むのがキモ。両方とも生存メモリ
  （filer は最後まで、batch は自分自身）。古い検索の batch が残っていても安全に捨てられる。
- coalescing（連続 publish の 1 本化）は v1 では「K 件バッチ」で十分。さらなる間引きは optimize 行き。

### 3.3 キャンセル + ライフタイム（必ず 3 ケース）

共通の停止手順 `searchStop(self)`（UI スレッドから呼ぶ）:
```
1. if job == null: return;
2. job.cancelled.store(true, .release);     // producer に即停止を要求
3. if job.thread |t| t.join();              // ★ join 後はもう invokeLater されない
4. self.search_gen +%= 1;                   // 以降キューに残る batch はすべて stale 化
5. // 残 batch の回収（leak 防止）: 通常運転中は次の pump の drain で stale 自己解放。
   //   teardown では §4 のとおり deinitUi 内で 1 回 drain する。
6. self.results をクリア（結果データ free） / 結果ビューを畳む(必要なら)
7. job を free（thread join 済みなので安全）
8. job = null; state = idle
```

- **① 再検索（前の検索を止める）**: 新クエリ submit / Search ボタン →
  `searchStop()`（前 job を cancel+join+gen++）→ `results` クリア → 新 `SearchJob`（gen = search_gen）→ spawn。
  join はワーカーが各エントリで cancelled を見るので即返る（粒度はエントリ単位。巨大単一 readdir 中の最悪
  ケースは 1 回の syscall ぶん待つが許容、要コメント）。
- **② ディレクトリ移動 / 検索離脱**: `loadDir`（236）の先頭で「検索中なら `searchStop()`」を呼ぶ。
  Esc / 空クエリ / 結果クリックで `loadDir` する場合も同様に経由する。結果ビューは元ビューへ戻す。
- **③ ウィンドウ閉じ = teardown**: §4。

### 3.4 allocator のスレッド安全性

ワーカースレッドが `allocator.dupe`/`free` する。`Application.init` 経路の gpa（および
`std.testing.allocator` = DebugAllocator）は **内部 mutex でスレッド安全**。
この前提を `SearchJob.allocator` のコメントに明記する。
不安なら検索専用に `std.heap.ThreadSafeAllocator` でラップしてもよい（v1 は gpa 直で可、要コメント）。

---

## 4. teardown 設計（直近 2 回の UAF を踏まえて厳密に）

実行順は **deinitUi → app.deinit → deinitModel**（§1.5）。**走行中 async は `deinitUi` の先頭で止める。**

`Filer.deinitUi` の先頭に以下を順に置く（既存の clearEntries 等より **前**）:
```
1. self.tearing_down = true;                // 後述の非検索タスクも no-op 化するフラグ
2. searchStop();                            // cancel → join → gen++ → results free → job free
3. self.app.event_queue.drain();            // ★ join 後にキューへ残った batch/done を 1 回流す
                                            //   - 検索系: gen が stale なので触らず自己 free（leak 回避）
                                            //   - 非検索系(reloadTask 等): tearing_down で早期 return
4. （以降）既存の clearEntries / places / popup / dialog / ghost 解放
```
理由:
- **join を deinitUi で行う**: app.deinit の `event_queue.deinit()`（残タスク破棄）より前でないと、
  破棄後にワーカーが post して UAF/leak する。Filer 本体も result UI もこの時点で生存。
- **drain を deinitUi で 1 回行う**: app.deinit はキューを **実行せず破棄**するので、
  そこに残った `Batch`（paths をヒープ所有）は drain しないと **leak**。join 済みなので新規 post は無い。
  gen++ 済みなので残 batch は result モデルを触らず free だけして消える（解放順序事故が起きない）。
- **`tearing_down` ガード**: drain がたまたま拾った `reloadTask`/`pendingEditTask` が
  解放直前の UI を触らないよう、これらの先頭で `if (self.tearing_down) return;` を入れる。

`deinitModel` 側: **検索固有の停止処理は置かない**（join は既に deinitUi で完了）。
`results_model.deinit()` を共有 `model.deinit()` の隣に置くのは可（join + drain 済みなので安全）。
結果データ（`results` の `*Hit` 群）は deinitUi で free 済みにする（UI 資産なので deinitUi が筋）。

**どちらで・どの順で停止/join するかの結論**:
- 停止 + join + 残 batch drain = **deinitUi の最先頭**（UI 資産と job の解放より前）。
- model 構造体の deinit のみ deinitModel（停止とは無関係、最後）。

---

## 5. 決定的テスト戦略（仮想クロック下で flaky にしない）

非決定性の根（§1.2）: 実スレッドの `invokeLater` は「次に誰かが pump した時」に現れる。
1 回 pump = 1 回 drain = 「その瞬間のキュー」だけ。よって **実スレッド + Robot の中間状態アサートは原理的に非決定**。

方針 = **(A) 純ロジックは常時テスト / (B) 経路は manual runner で決定化 / (C) スレッド版は境界だけ検証**。

### (A) 純ロジック単体テスト（GPU / Application / スレッド非依存、常に走る）

`std.testing.allocator` のみ。`SkipZigTest` しない。
- `match(name, query)`: 大文字小文字無視の部分一致（境界 / マルチバイト / 空クエリ）。
- 結果集約: append 順序保持、件数、（必要なら）重複排除。
- **キャンセル状態機械**: `idle→running→cancelled`、`running→done`、`cancelled` 後の step は no-op、
  `gen` 不一致 batch は破棄、を `SearchJob`/`Batch` を直接叩いて検証。
  ここを「描画なしで動く純構造体」に切り出すのが設計上の要点（GPU ゲート不要にするため）。

### (B) 経路を突く決定的結合テスト（manual runner）

`initHeadless`（GPU 必要 → 無ければ `catch return error.SkipZigTest`、既存 smoke と同形）。
`build(..., runner = .manual)` で**スレッドを起こさない**。手順:
```
1. TmpDir に既知のツリーを作る（fixture）。例: a/match1.txt, a/b/match2.txt, c/nope.bin …
2. filer の検索ボックスに "match" を投入して検索開始（manual: job は running だが produce は未実行）
3. ループ: filer.searchStepForTest(1); robot.pump();
   - step が 1 エントリ produce → ヒットなら invokeLater(publishBatch)
   - pump(=drain) が publishBatch を実行 → results に反映
4. step k 回後に「results 件数 == その時点で踏破済みのマッチ数」を逐次アサート（= 逐次反映の検査）
5. 全踏破後に done 状態 / 件数 / 結果ビューのスナップショット（role=list に該当パスが出る）を確認
```
**1 step ↔ 1 pump を 1:1 で回すので完全に決定的**。「逐次反映される」を実際に検査できる。

### (C) スレッド版の境界検証（中間はアサートしない）

`.threaded` で大きめの TmpDir ツリーに対し検索 → **即 `searchStop()`（cancel+join）** → 終了状態の整合のみ確認。
中間件数は見ない。`std.testing.allocator`（DebugAllocator）が leak を検出するので、
join 漏れ / batch 解放漏れは自動で失敗になる。スレッド版が無い環境（Io 制約）では SkipZigTest。

### 回帰ガード（「真に経路を突く」3 点）

1. **キャンセルで止まる**: manual で 1 step（1 hit）→ `searchStop()` → さらに step を試みても
   produce が走らない / results が増えない / state==idle、をアサート（cancelled が producer を止める経路）。
2. **teardown で UAF しない**: manual で検索開始 → publishBatch を **pump せずキューに残したまま** →
   `deinitUi`（→ 内部で join + gen++ + drain）を走らせ、**leak 0**（DebugAllocator）で完走することを確認。
   さらに `.threaded` 版: 巨大ツリー検索を開始した直後に teardown（join が安全網）を別テストで。
   これが「直近 2 回の teardown UAF」への直接の回帰ガード。
3. **逐次反映**: (B) の step/pump ループで件数が単調増加することをアサート。

### 既存テストとの整合
- 既存 `framework/tests/app_filer_smoke_test.zig` と同じハーネス（`newApp`/`makeFixture`/`Driver`）に相乗り。
- 描画依存（結果が画面に出る pixel / snapshot）だけ GPU ゲート（initHeadless skip）。
  ロジックは GPU 非依存で常時走らせる（CLAUDE.md / test.md のテスト規律）。

---

## 6. framework 変更の要否

### 結論: **#5 の正しい実装に framework 変更は不要**（backlog 方針どおり app 側だけで書ける）

- marshalling: `EventQueue.invokeLater` が実装済み・スレッド安全・headless でも pump で drain される（§1.1）。
- バックグラウンド実行: `std.Thread.spawn`（公式パターン）で app 側完結。
- キャンセル: framework に無いが、atomic フラグ + 世代カウンタを **app 側**で持てば足りる（§3.3）。
- 結果 UI: `app.list` + `ListModel` + 既存 CardLayout の 3 枚目（§2.2）。新規 framework 部品ゼロ。

→ まず **app 側だけで実装**し、痛み（キャンセル+join+gen+teardown drain の手順が毎回手書きで事故りやすい等）を
   実コードで観測する。これは backlog #5 の完了条件「ヘルパー化するか否かの判断材料を残す」に直結する。

### 将来の最小切り出し（条件付き・framework_backlog 起票候補）

#5 を書いて「同じ定型を #6 フォルダサイズ集計でも繰り返す」ことが確定した時点で、
SwingWorker 相当を **最小限**で framework に切り出す。要件（framework_backlog 新規行の素案）:

```
framework #27（候補）: BackgroundWorker ヘルパー（SwingWorker 相当・最小）
- 何: spawn + cancel フラグ + join-on-deinit + invokeLater publish/process + 世代ガードを 1 つにまとめる。
- シグネチャ案:
    Worker(Result) = struct {
        start(eq, io, produceFn, publishFn, doneFn, ctx) !void  // spawn
        cancel(self) void                                       // atomic フラグ
        join(self) void                                         // 所有者の deinit で必ず呼ぶ
        isCancelled(self) bool                                  // produce 側が polling
    }
- ライフタイム: 所有者は deinit で必ず join → その後にのみ ctx/結果バッファを解放（teardown 規約を型で強制）。
- 非機能: EventQueue だけに依存。GPU 非依存。headless で manual 駆動できる注入点を持つ（テスト決定性）。
- 非対象: io.async バックエンド差し替え、優先度/dedupe（EventQueue 側「機能要望」の範疇）。
```
- これを入れるかは **#5 実装後に作者判断**。入れない場合も本ノートが知見として残る（#5 完了条件）。
- 併せて `EventQueue` 側「機能要望」（cancel / coalescing）は別軸の将来課題として既存記載のまま据え置き。

### 実装順（framework を切り出す場合）
1. app 側だけで #5 を完成（本ノートの §2–§5）。← まずここまで。
2. #6 着手時に重複が確定したら framework #27 を起票し、最小ヘルパーを実装。
3. app_filer / 後続アプリをヘルパー利用に置換（リファクタ。挙動不変・テスト据え置き）。

---

## 7. Codex 向け実装スペック

### 7.1 読むべきファイル（必読）
- `examples/app_filer/main.zig` … 実装対象。特に:
  - `Filer` struct（94–）、`deinitUi`（132）、`deinitModel`（143）
  - `CardLayout`（64–90）、`build`（1204–1373）の right_center / card 周り（1226–1261）
  - 既存 invokeLater 利用: `scheduleReload`/`reloadTask`（321–328）、`startPendingEdit`/`pendingEditTask`（330–339, 456–465）
  - `loadDir`（236–313）、`requestSelectName`（315–319）… 結果クリックの飛び先 + pending-select
  - north トースバー組み立て（1324–1347）… 検索バー追加箇所
- `awt/src/EventQueue.zig` … `invokeLater`/`drain` の正確な意味（drain は呼んだ瞬間のスナップショットのみ）。
- `awt/doc/event_queue.md` … `std.Thread.spawn + invokeLater` 公式パターン（利用例）。
- `framework/src/Application.zig` … `tickOnce`(282)/`deinit`(212: event_queue.deinit が残タスク破棄)/`initHeadless`(190)。
- `framework/src/Robot.zig` … `pump`=`tickOnce`、snapshotTree の使い方（テスト）。
- `framework/tests/app_filer_smoke_test.zig` … 追加するテストのハーネス（newApp/makeFixture/Driver、teardown 順）。
- `doc/internal/test.md` … テスト種別と GPU ゲート規律。
- `doc/internal/dogfooding_backlog.md` #5 … 完了条件。

### 7.2 実装タスク（順序）
1. `build` に `runner: RunnerKind = .threaded` 引数追加。`main` は default、テストは `.manual`。
2. `Filer` に検索状態を追加: `search_gen: u64`, `job: ?*SearchJob`, `results: ArrayList(*Hit)`,
   `results_model: Model`, `results_list/results_sp`, `prev_view: ?*Component`, `tearing_down: bool`,
   検索バーの widget 群。
3. north を 2 段化、結果リスト + ResultCell、CardLayout に 3 枚目を add（§2）。
4. `SearchJob` / `Batch` / `produce` / `publishBatch` / `finishTask` / `searchStart` / `searchStep`(manual) /
   `searchStop` を実装（§3）。`.threaded` は `walkThread` から `produce` を回す。
5. `loadDir` 先頭に「検索中なら searchStop」を挿入（②）。結果クリック → loadDir + requestSelectName。
6. `deinitUi` の先頭に teardown 手順（tearing_down=true → searchStop → drain）（§4）。
   `reloadTask`/`pendingEditTask` 先頭に `if (self.tearing_down) return;`。
   `deinitModel` に `results_model.deinit()` を追加。
7. テスト追加（§5）: 純ロジック（埋め込み test）＋ smoke（manual で逐次/キャンセル/teardown、threaded で teardown 境界）。
   `framework/tests/app_filer_smoke_test.zig` に相乗り。`build.zig` のテスト wiring は既存
   `app_filer_smoke_test`(305–315) を流用（新ファイル不要）。

### 7.3 制約・非機能
- コメントは英語（CLAUDE.md）。コミット件名は `Add:`/`Update:` + 日本語本文。
- 純ロジックは GPU/Application 非依存に保つ（常時テスト）。描画依存のみ initHeadless skip。
- allocator のスレッド安全性をコメント明記（§3.4）。
- coalescing/優先度/io.async 差し替えはスコープ外（将来）。
- **teardown 不変条件を崩さないこと**: join は deinitUi、event_queue.deinit より前。Batch は必ず free（leak 0）。
