---
unsafe: true
---

# list
List の可視範囲実体化方針・状態の置き場所・identity 問題・イベント処理・描画・編集（CellEditor）・寿命。

## 可視範囲だけ実体化する
List は「全行ぶんのセル」を持たない。 **可視範囲を覆うのに必要な数＋少しのバッファ**だけ実セルを `pool` に持つ。

* `component.min_size.height = model.getSize() * row_height` を報告する。 これにより外側の `ScrollPane` がスクロール範囲を決める (`scrollpane.md`)。
* List は自分のビューポート内でのオフセット (自分の `position`) とビューポートの高さから 可視行範囲を求める。
* `pool` 内の各セルを 1 つの可視行に割り当て、 `cell.component.position` を行の矩形 (`y = row * row_height`、 高さ `row_height`、 幅は List 内幅) にセットする。
  割り当てた行に対して `cell.update(ctx)` を呼ぶ。
* 可視範囲が動いたら (スクロール / リサイズ / `row_height` 変更 / モデル 変更)、 プールを **再調整 (reconcile)** する。
  足りなければ `factory.create` で増やし、 余ったセルは非表示 (`row = null`) にし、 行が変わったセルにだけ `update` を呼び直す (= リサイクル)。

可視セルは List の子として `parent` チェーンに繋ぐ。
描画クリップも当たり判定も `Container` と同じ既存機構 (`paintAt` の bounds クリップ、 `containsWindowPoint` の門番) でそのまま成立する (`container.md`)。
専用のセル dispatch コードは要らない。

### なぜ単一インスタンスの判子にしないか
セルを 1 個だけ使い回し、 paint / dispatch のたびに位置と内容を付け替える「判子」方式も考えられるが、 **対話 (interaction) で破綻する**ため採らない。

描画は行の純関数 (`value, index, selected, focused` から一意に決まる) なので 1 個を使い回せる。
だが押下状態のような対話状態は「どの物理行で押し下げたか」という **入力履歴と identity の関数**であって、 行データからは導出できない。
判子は 1 インスタンス共有で identity を持たないため、 「3 行目だけ押下中」を表現できない (全行同じ表示になるか、 行データから復元できず消えるか)。
さらにマウスキャプチャは捕捉コンポーネントへ直送されるため (`event.md`)、 判子が paint で位置を付け替えられると、 ドラッグ中に「自分がどの行か」が失われる。

対話は「対話中セルごとの安定した identity」を要求する。
可視ぶんの実セルを置くと、 操作の間そのセルは同じ行に固定されるので identity が自然に保たれ、
判子方式に必要だった特殊機構 (List 側のジェスチャ調停 / controlled 駆動) が一切要らなくなる。

## 状態の置き場所
セルの状態を **寿命**で 3 つに分け、 置き場所を変える。 これがこの設計の要。

| 状態の種類 | 例 | 置き場所 | 寿命 |
|---|---|---|---|
| 投影 (一方向) | 表示テキスト / アイコン / 選択ハイライト | ListModel の item (＋ `ctx.selected` 等)。 `update` で毎回上書き | 行データと同じ |
| 一時的な対話状態 | pressed / armed / hover | セル実体が普通に持つ | セル実体と同じ (リサイクル で消えてよい) |
| 永続的な per-row 状態 | checked / expanded / 編集後テキスト | ListModel の item が真実。 `update` で投影し、 変更はコールバックで書き戻す | 行データと同じ |

要点:

* 投影状態は状態ではない — 表示テキストはセルが originate しない。 `update` で item から毎回上書きされるだけなので、 リサイクル されても正しい行の値になる。
* 一時的な対話状態はセルに任せてよい — セルが実体なので、 `processEvent` で `setPressed` 等が走っても他の行に漏れない。
  リサイクル で別の行に使い回されるとき、 押下中の行は リサイクル されない (操作中＝可視＆フォーカス近傍) ので問題にならない。
* 永続 per-row 状態をセルに溜め込まない — 例えばセルに Checkbox を置いて `selected` をセル側だけに持つと、 リサイクル で別行に使い回した瞬間に値が紛れる。
  真実は item に置き、 セルは投影＋書き戻しの view に徹する (controlled)。

## 「個別のボタンを認識する」問題が消える理由
Swing でセル内ボタンの行を `getEditingRow()` で逆引きする必要があったのは、 判子に実体と行 identity が無かったから。

この設計ではセルが実体で、 factory が **セルごとに専用の状態構造体 (`user_data`) を new する**。
セル内ボタンの action リスナー は、 そのセルの状態構造体を `user_data` にして **生成時に一度だけ** 登録する
(`getModel().addActionListener(CellState, fn, &cell_state)`、 型付き登録は `model.md`)。
`update` のたびにセルは自分の状態構造体へ現在の行 (`ctx.index`) を書き込む。

セルは リサイクル されるまで同じ行に固定され、 イベントもその間に来るので、 action ハンドラが自分のセル状態から現在行を読めば常に正しい行が取れる。
共有インスタンスからの逆引きも、 editor のライフサイクルも要らない。

> action が `EventQueue.invokeLater` 等で遅延実行される場合は、 遅延時に行が recycle で変わっている可能性があるため、 行番号を先にコピーしておくこと。

## イベント処理
可視セルは List の子なので、 セル内のマウス処理 (ボタン押下、 ドラッグ、 キャプチャ) は通常のウィジェットと同じコードでそのまま動く。
List 自身の `processEvent` は、 その上に行選択とキーボード操作を足すだけ。

| 入力 | 動作 |
|---|---|
| マウス move | ポインタ下のセルへ配送。 加えて hover 追跡 (後述) を更新する |
| マウス left press (行上) | まず子 (セル) へ配送し、 消費されなければその行を選択 (`setSelected`) して List にフォーカスを要求する (矢印キーを効かせるため) |
| マウス wheel (scroll) | 何もしない (外側の `ScrollPane` に処理させるため消費しない) |
| ↓ / ↑ キー | `selected` を移動 (端でクランプ)、 ChangeListener 発火、 `enclosingScrollController` 経由で可視域へスクロール |

セル内ボタンの press → drag → release は、 そのボタンが `requestCapture` してキャプチャ先で完結する (`event.md`「マウスキャプチャ」)。
List はキャプチャに関与しない (実セルなのでボタン自身の identity が安定しているため)。

### hover の解除 (合成 move)
nimbus には OS の enter/leave が無く、 ウィジェットは受け取った `.move` の inside 判定で rollover を更新する。
ポインタがセルから離れると、 そのセル内ボタンは move を受け取らなくなり rollover が固着しうる。
そこで List は「いまポインタが乗っているセル」(`hovered`) を覚え、
**乗っているセルが変わったら、 離れた側のセルへ現在のポインタ座標 (＝もうそのセルの外) の `.move` を合成して送る**。
セルはその move を通常処理して rollover を落とし、 セルがコンテナーなら自分の子へ同じ伝播が連鎖する。
これは `Container` / `Panel` と同一の hover 解除機構 (`container.md`)。
List 自身も ビューポート の子なので、 ポインタが List の外へ出たときは ビューポート から同じ合成 move が届いて連鎖が起きる。

## 描画
ビューポート (typically `ScrollPane`) 越しに表示される前提。
`paint` はまず可視範囲を再調整 (reconcile) し、 背景を塗り、 選択行があればその矩形に背景ハイライトを描く。
その後、 `pool` の各可視セル (`cell.component`) を `paintAt` で重ねて描く。
画面外の行はそもそもセルが割り当たっていない (プールが可視範囲しか覆わない) ので、 描画コストは行数 N ではなく可視行数に比例する。

選択ハイライトを List 側で描くのは、 read-only セルが選択表示を持たなくても見た目が成立するようにするため。
セルは `ctx.selected` を受け取るので、 必要なら自前で選択時の描画を上書きしてもよい。

## 編集 (CellEditor)
List のセルは既定で読み取り専用 (投影のみ) だが、 セルが `Cell.edit` を与えれば編集モードを持てる。
**実装済み** (型・操作 API は spec `list.md`「セルの編集 (CellEditor)」、 動く例は `examples/widget_listedit`)。
セル内テキスト編集が要るのは主に Table / Tree のセルで List 自体には必須ではなかったが、
後付けで core (実セル + リサイクル) を作り直さずに済むよう editor 機構を additive に組み込んだ。
この節はその設計の根拠 — 型を任意フィールドにした理由・リサイクル / identity との整合・却下案 — を述べる。

### editor が要るセル / 要らないセル
セルが editor を必要とするかは、 **「view と item のあいだに未確定のズレが、 ある時間のあいだ続くか」**で決まる。

| セル | view→item の書き戻し | ズレの継続時間 | editor |
|---|---|---|---|
| ボタン (削除等) | アクション発火＝即 item 構造変更 | ゼロ (アトミック) | 不要 |
| チェックボックス | クリック＝即 item の bool を反転 | ゼロ (アトミック) | 不要 |
| テキスト編集 | 数文字打つ / IME 変換中は item にまだ無い文字を view が抱える | 編集セッションのあいだ継続 | **必要** |

アトミックに書き戻すセル (ボタン / チェックボックス) は editor ではなく **ただの interactive セル**で、
「状態の置き場所」の controlled 契約 (投影 + 書き戻し) だけで成立する。
editor が要るのは「確定前のスクラッチ状態を一定時間保持し、 確定 / 取り消しで決着させる」セルだけ。
この線引きが Table / Tree で「このセルは editor 化が要るか」を判断する基準になる。

### モデル: 同じ実セルが編集モードへトグルする
Swing は renderer (判子) と editor (実体) を別コンポーネントに分けるが、
ここでは JavaFX `ListView` に倣い **同じ実セルが編集モードへトグルする** (実セルは既にあるので別オーバーレイが要らない)。
表示モードではセルは item を投影するラベル等、 編集モードでは自分の部分木を入力ウィジェット (スクラッチ) に差し替える。

編集にまつわる状態 (キャレット位置 / 選択範囲 / IME の未確定文字列) は **編集している間だけ**そのスクラッチが保持し、 編集が終われば失われる。
これは pressed が リサイクル で消えるのと同型で、 「per-row でない一時状態は、 それを抱える文脈が終われば消える」という一貫した扱い。
失って困るのは確定テキストだけで、 それは item へ書き戻すので残る。

### 型 (additive)
`Cell` に編集ライフサイクルを **任意フィールド** 1 つ (`edit: ?CellEdit`) で足した。 読み取り専用セルは null のままで、 既存セルは一切変わらない。

```zig
pub const CellEdit = struct {
    // 編集モードへ入る。 セル部分木をスクラッチ入力ウィジェットへ差し替え、
    // item の値で seed し、 入力ウィジェットへフォーカスを要求する。
    start:  *const fn (self: *anyopaque, ctx: CellContext) void,
    // 確定。 スクラッチの値を item へ書き戻し、 表示モードへ戻す。
    commit: *const fn (self: *anyopaque) void,
    // 取り消し。 スクラッチを破棄し、 表示モードへ戻す (item は変えない)。
    cancel: *const fn (self: *anyopaque) void,
};

pub const Cell = struct {
    component: *Component,
    update:    *const fn (self: *anyopaque, ctx: CellContext) void,
    destroy:   *const fn (self: *anyopaque, allocator: std.mem.Allocator) void,
    edit:      ?CellEdit = null,   // null = 読み取り専用 (編集不可)
    user_data: *anyopaque,
};
```

編集の開始トリガと、 フォーカス喪失時の決着方針は設定可能にする。

```zig
pub const EditTrigger = enum {
    double_click,            // セルのダブルクリックで開始
    enter,                   // 選択行で Enter キーを押すと開始
    double_click_or_enter,   // 上記どちらでも開始 (既定)
    manual,                  // `edit(idx)` の明示呼び出しのみ
};

pub const FocusLostPolicy = enum {
    commit,   // 編集中にフォーカスが外れたら確定 (既定)
    cancel,   // 編集中にフォーカスが外れたら取り消し
};
```

`List` には編集状態と設定を持つ。 読み取り専用 List では `editing` は常に null。

```zig
editing:      ?usize,            // 編集中の行 (高々 1 つ)
edit_trigger: EditTrigger,       // 既定 .double_click_or_enter
focus_lost:   FocusLostPolicy,   // 既定 .commit
```

操作 API:

```zig
pub fn edit(self: *List, idx: usize) void;   // その行が edit != null なら編集開始
pub fn commitEdit(self: *List) void;          // 編集中なら確定して終了
pub fn cancelEdit(self: *List) void;          // 編集中なら取り消して終了
pub fn getEditing(self: List) ?usize;

pub fn setEditTrigger(self: *List, t: EditTrigger) void;
pub fn setFocusLostPolicy(self: *List, p: FocusLostPolicy) void;
```

### ライフサイクル
* 開始 (`edit(idx)`): すでに別の行が編集中ならそれを先に確定 / 取り消ししてから、 対象行のセルの `edit.start(ctx)` を呼び `editing = idx` にする。
  対象セルの `edit` が null なら no-op。
* 編集中: スクラッチ (入力ウィジェット) が確定前の状態を持つ。 モデル は触らない。
  **このセルだけ `update` の投影を止める** — item から上書きするとキャレットや IME 未確定文字が消えるため。
  これが編集を守る唯一の核。
* 確定 (`commitEdit`): セルの `edit.commit` がスクラッチの確定値を item へ書き戻し、 表示モードへ戻す。
  `editing = null`。 投影が再開し、 次の `update` で確定値が表示される (書き戻し済みなので一致する)。
* 取り消し (`cancelEdit`): `edit.cancel` がスクラッチを破棄して表示モードへ戻す。 item は変えない。

item の内容が変わっても件数は変わらないので、 `ListModel.change_listeners` (構造変更通知) は発火しない。 確定後は repaint で足りる。
共有 モデル の他ビューへ内容変更を伝える細粒度通知は「機能要望」(`ListDataListener` 相当) の領分。

### reconcile への追加
編集中の行 (`editing`) は、 reconcile で **`update` の投影をスキップ**し、
かつ **プールへ返さない (リサイクル しない)**。
これにより編集中セルが別行に束縛し直されたり、 投影で入力中文字が消えたりしない。

### 制約 (これにより recycle / identity の厄介がすべて消える)
* **同時に 2 つ以上のセルが編集状態になることはない** (`editing` は単一)。
  これにより未確定スクラッチを持つ実体は常に高々 1 つで、 リサイクル / フォーカスの競合が生じない。
* **編集が開始してから終了するまでの間、 そのセルがプールに返される (リサイクル される) ことはない。**
  編集中セルが可視域外へスクロールされそうなときは、 その時点で編集を終える。

### 開始トリガとフォーカス喪失 (設定可能)
* **開始トリガ** (`edit_trigger`、 既定 `.double_click_or_enter`): `double_click` はポインタ下のセル、 `enter` は選択行を編集開始する。
  `double_click_or_enter` は両方受け付ける。 `manual` は `edit(idx)` のみ (UI からは開始しない)。 `setEditTrigger` で変更する。
* **フォーカス喪失時** (`focus_lost`、 既定 `.commit`): 編集中に他所をクリックしてスクラッチがフォーカスを失ったら、 `commit` なら確定、 `cancel` なら取り消し。
  JavaFX でも版により揺れた点なので明示的に持つ。 `setFocusLostPolicy` で変更する。

### キー (固定)
編集中のキーは固定で、 設定しない。
* **Enter** = commit (確定)
* **Escape** = cancel (取り消し)

## 寿命
`factory` の所有者は **利用者** (typically factory を実装した view 構造体)。 List は借用するだけで `destroy` で解放しない。
一方、 factory が生成した **セル (`Cell` とその部分木) は List が所有**する (動的に増減するため)。 `destroy` が `pool` 内の全セルを `cell.destroy` で解放する。

`model` は `owns_model` を見て、 `create` で内部生成した場合のみ List が解放する (`createWithModel` の借用は触らない)。

item の実メモリ (`*anyopaque` の指す先) は利用者の所有。 ListModel は借用ポインタを並べるだけで、 List / ListModel より長生きさせる責任は利用者にある。
