# ScrollPane 3x3 領域モデル設計 (columnHeader / rowHeader / corner)

backlog framework #28 の設計。作者決定は **案A（一括）**: columnHeader / rowHeader / corner を 3 つとも一度に入れ、設計は最初から 3x3 で固める。
これは設計のみの正本で、実装はまだしない（ブランチ `feat/scroll-headers`、以後 Codex が in-place 実装する）。
公開 API スケッチは spec `framework/doc/scrollpane.md`「機能要望」に置く（未実装を spec の「型定義 / 関数定義」に書くと doc↔実装 追従監査が NG になるため、昇格は実装時）。

## 動機（実バグ）
現状の ScrollPane は `container = [viewport, hbar, vbar]` で、vbar は `container` の全高に並ぶ。
Table を `view` に入れると Table が自前でヘッダーを viewport 上端に pin する（`Table.zig` の `scroll_top = @max(0, -position.y)` でスクロールを打ち消して `paintHeader` を最後に描く）が、vbar はその pin したヘッダー帯の右端に被る。
これは app_filer 詳細ビューの実バグ（作者がスクショで発見）。
ヘッダー帯を ScrollPane 自身の領域として持ち、**vbar をヘッダー帯の下から始める**ことが構造的な解。

## 領域
ScrollPane を概念的に 3 行 3 列のグリッドとして扱う。

```
            列: [  left   ][   center   ][ right ]
行 top    :  [    UL     ][columnHeader ][  UR   ]
行 center :  [ rowHeader ][  viewport   ][ vbar  ]
行 bottom :  [    LL     ][    hbar     ][  LR   ]
```

帯の寸法（W, H = ScrollPane の内寸、T = `ScrollBar.THICKNESS`）:

- `left`   = rowHeader があれば `rowHeader.effectiveMinSize().width`、無ければ 0
- `top`    = columnHeader があれば `columnHeader.effectiveMinSize().height`、無ければ 0
- `right`  = vbar 表示時 `T`、非表示で 0
- `bottom` = hbar 表示時 `T`、非表示で 0
- `center_w = W - left - right`、 `center_h = H - top - bottom`

各領域の矩形（x, y, w, h）:

| 領域 | x | y | w | h |
|---|---|---|---|---|
| UL | 0 | 0 | left | top |
| columnHeader | left | 0 | center_w | top |
| UR | left+center_w | 0 | right | top |
| rowHeader | 0 | top | left | center_h |
| viewport | left | top | center_w | center_h |
| vbar | left+center_w | top | right | center_h |
| LL | 0 | top+center_h | left | bottom |
| hbar | left | top+center_h | center_w | bottom |
| LR | left+center_w | top+center_h | right | bottom |

レイアウト規約: vbar は y = top（columnHeader の下）から始まり高さ center_h（viewport 行のみ）。
hbar は x = left（rowHeader の右）から始まり幅 center_w（viewport 列のみ）。
スクロールバーはヘッダー帯 / コーナーを跨がない。これが #28 のバグの解。

## 縮退
- ヘッダー / コーナーが無いとき left = top = 0 となり、領域は現行の `[viewport, hbar, vbar]` に一致する（既存挙動の上位互換 = 回帰しない）。
- コーナーはその行帯と列帯がともに非ゼロのときだけ可視: UL は left>0 かつ top>0、UR は right>0 かつ top>0、LL は left>0 かつ bottom>0、LR は right>0 かつ bottom>0。
  片方でも 0 ならコーナー view は 0×0（非表示バーと同じ畳み方）。
- バー要否の収束（現行の 2 パス settle）はそのまま。
  ヘッダー帯ぶん（left / top）は定数として center から差し引くだけで、収束ロジックには影響しない（ヘッダーの自然サイズはバー有無に依存しないため）。

## ヘッダーのクリップ — ポート方式
columnHeader / rowHeader の view は帯より大きい（columnHeader の幅 = コンテンツ幅、rowHeader の高さ = コンテンツ高）。
これを帯にクリップするため、**viewport とまったく同じ仕組み**を使う: 各ヘッダー帯を内部 `Container`（ポート）とし、ヘッダー view をその唯一の子として offset 配置する。
`Container` の `containsWindowPoint` 門番 + `paintAt` の bounds クリップにより、ヘッダーのクリップも当たり判定も既存機構でそのまま成立する（専用クリップ / ヒットテストは不要、viewport と同型）。

- `col_header_port` の bounds = columnHeader 領域、その子 view の bounds = `{ x = -h, y = 0, w = view_size.width, h = top }`
- `row_header_port` の bounds = rowHeader 領域、その子 view の bounds = `{ x = 0, y = -v, w = left, h = view_size.height }`

columnHeader view の幅は**帯の幅ではなくコンテンツ（view）の幅** `view_size.width` に揃える。
これで Table のヘッダーと本体の列位置が一致する。
rowHeader view の高さも同様に `view_size.height` に揃える。

コーナーはポート不要（静的・帯サイズちょうど）。
コーナー view を `container` の直接の子とし、対応するセル矩形に `setBounds` するだけでよい（`paintAt` がセルサイズにクリップする）。

ポートを使わずヘッダー view を直接 `container` の子にすると、paintAt はヘッダー view 自身の bounds でしかクリップしないため、コンテンツ幅いっぱいのヘッダーが帯を越えて vbar / UR や viewport 上へはみ出して描かれる。
だからクリップ用ポートは必須（viewport を独立コンテナーにしているのと同じ理由）。

## スクロール同期の配線
スクロールの単一の真実は従来どおりバーの `BoundedRangeModel`。
位置反映は 2 段に分ける:

1. **doLayout（サイズ + 初期 offset）**: 上記の view / ヘッダー view の bounds を一括で置く。
2. **`onScrollChange`（毎フレームの安価な offset 更新、再レイアウト無し）**: 既存の `view.position = {-h, -v}` に加えて、
   - columnHeader があれば `col_header_view.position.x = -h`（y は 0 のまま = 縦には固定）
   - rowHeader があれば `row_header_view.position.y = -v`（x は 0 のまま = 横には固定）

これにより columnHeader は水平オフセットのみ、rowHeader は垂直オフセットのみ追従、viewport は両軸追従、という規約が自然に落ちる。
配線の置き場所は「初期サイズは doLayout、毎フレームの追従は ChangeListener」という現行 ScrollPane の流儀をそのまま踏襲する（新しい配線機構は作らない）。

ヘッダー帯上のホイールは、ポートの子（Table ヘッダー等）が `.scroll` を消費しないので、ScrollPane の `processEvent` が未消費ホイールを拾って従来どおりペインをスクロールする（ヘッダー上で回しても中身が動く）。

`scrollRectToVisible` はヘッダー帯の外（= viewport = center 領域）だけを対象にするので、ヘッダー補正は要らない。
Table 移行後は Table 側の「行を header の下に潜らせない」rect 拡張ハック（`scrollToRow` の `- HEADER_HEIGHT`）も不要になる。

## API と所有
公開 API スケッチ（`Corner` enum + `setColumnHeaderView` / `setRowHeaderView` / `setCorner` + getter）は spec `framework/doc/scrollpane.md`「機能要望」に置いた。

- 所有: `setColumnHeaderView` / `setRowHeaderView` / `setCorner` に渡した view は ScrollPane が所有する（`setView` と同じ規約）。
  既に設定済みの位置へ再設定すると、古い view を `destroy` してから差し替える。
- 解放: ヘッダーポート / コーナー view はいずれも `container` の子（コーナーは直接、ヘッダーは port 経由）になるので、`destroy` → `container.deinit` の既存経路でまとめて解放される。
  **新しい teardown 経路は作らない**。
- fallible: 生成失敗（ポート確保の失敗）は `!void` で返す。
  `setView` が void なのと不揃いに見えるが、`setView` は常在スロット（viewport）の中身入れ替えで確保が無いのに対し、ヘッダーは初回にポートを確保するため本質的に fallible。
  沈黙ドロップより `!void` を選ぶ。
- view を外す（null 化）は実需が出るまで持たない（機能要望）。
  現行 `setView` も「外す」を持たず「差し替え」だけなのと同じ判断。

## Table の移行
Table は現在ヘッダーを自前 pin している（`HEADER_HEIGHT` 帯を本体内に持ち、`scroll_top` でスクロールを打ち消して `paintHeader` を最後に描く）。
これを廃し、ヘッダーを columnHeaderView として出す。

手順:

1. ヘッダーだけを描く薄い Component `TableHeader`（`Table.zig` 内の入れ子型）を追加し、`Table.headerView(self) -> *Component` で生成する。
   `TableHeader` は Table を**借用**し（所有しない）、`effectiveMinSize = { totalWidth(), HEADER_HEIGHT }`、paint = 既存 `paintHeader`（top = 0、scroll_top 打ち消し無し）、processEvent = 既存 `handleHeaderPress` / 列リサイズ / ソートを local x で呼ぶ、という委譲シェルにする。
   列定義・ソート状態・リサイズロジックは Table 側に残す（同一ファイル内なので private を共有できる）。
2. Table 本体から header 帯を除去する: `syncContentSize` の高さを `rows * row_height`（HEADER_HEIGHT を足さない）、`paint` はヘッダーを描かない、`rowAtLocalY` / `reconcile` / `layoutCell` / `scrollToRow` の `+ HEADER_HEIGHT` オフセットを除去する。
3. app_filer 詳細ビューの配線（setColumnHeaderView を呼ぶのは**アプリ側**）:

```zig
const tsp = try app.scrollPane(tbl.asComponent());
try tsp.setColumnHeaderView(try tbl.headerView());
```

Table と ScrollPane は独立モジュールで、Table は ScrollPane を知らない（Table が自分を ScrollPane に挿し込まない）ので、配線はアプリの責務。
ヘッダー view の幅は ScrollPane が `view_size.width`（= 本体の measured 幅 = `totalWidth()`）に揃えるので、ヘッダーと本体の列が一致する。
列幅ドラッグは `TableHeader` が `Table.columns` を書き換え、本体も同じ `columns` を読むので両者が連動する。

所有と解放順: `TableHeader`（ScrollPane が所有、`col_header_port` の子）は Table（ScrollPane が所有、viewport の子）を借用する。
両者は同じ ScrollPane の `destroy` で死に、`destroy` は相手を deref しないので順序に関わらず安全。
ただし **`TableHeader` は Table より長生きしてはならない**（借用先が先に消えると dangling）。
同一 ScrollPane が両方を所有するこの構成なら、これは構造的に守られる。

## awt 充足
3x3 は既存の `paintAt`（bounds クリップ）/ `drawImage`（コーナーのアイコン）/ `Container`（門番 + 当たり判定）で組める。
ヘッダーポートは素の `Container` なのでクリップ・ヒットテストは自動で成立する。
**追加プリミティブは不要**（awt_backlog への起票なし）。

## テスト方針
領域レイアウト計算は純ロジック（Application / GPU 非依存）。
`ScrollPane.create`（→ `ScrollBar.createWithModel`）は device もフォントも要らないので、ダミー `Container` を view にして `setBounds` + `doLayout` を回し、各領域の bounds を読むだけで検証できる（Table の埋め込みテストが GPU 無しで動くのと同じ手）。

GPU 非依存で常時実行する単体テスト:

- **vbar がヘッダー帯を跨がない**: columnHeader 設定 + コンテンツ高 > viewport で `vbar.position.y == top` かつ `vbar.size.height == center_h`（#28 バグの直接の回帰テスト）。
- **hbar が rowHeader を跨がない**: `hbar.position.x == left`。
- **同期オフセット**: `setScrollX(40)` 後に `col_header_view.position == { -40, 0 }`、`setScrollY(30)` 後に `row_header_view.position == { 0, -30 }`、viewport の view は `{ -40, -30 }`。
- **縮退**: ヘッダー無しで left = top = 0、領域が現行 `[viewport, hbar, vbar]` に一致（既存挙動不変）。
- **コーナー畳み**: 片帯が 0 のときコーナーが 0×0。

描画契約が要る所だけ GPU ゲートにする: ヘッダーの実描画（`drawString` の列タイトル・ソート指標）は snapshot / Robot。
Robot スモーク: ScrollPane + columnHeader をスクロールし、ヘッダーが縦固定・横追従、vbar がヘッダー帯に被らないことを確認する。

## 設計上のリスク
- **embedded layout の invalid-free**: `ScrollLayout` は ScrollPane に値で埋め込まれ `vtable.deinit = null`。
  `Container.deinitLayout` は deinit が null なら触らないので安全。
  3x3 化でも `ScrollLayout` に deinit を**付けてはならない**（付けると内部ポインタを free して invalid-free になる）。
- **ヘッダー / コーナー view の所有・解放順**: すべて `container` の子（ヘッダーは port 経由）に統一し、`destroy` → `container.deinit` の単一経路で解放する。
  `TableHeader` が Table を借用する点だけ別管理（上記「Table の移行」）。
- **Table 移行で既存テストが落ちる**: 現行 Table 埋め込みテストの多くが HEADER_HEIGHT オフセット前提（`rowAtLocalY` の header 加味、body クリック y=62 → row1 = (62-26)/24、header クリックの y=10、リサイズの y=10 等）。
  移行で body 系は HEADER_HEIGHT を抜いた座標へ、header 系（ソート / リサイズ）は `TableHeader` のテストへ移す必要がある。
  これは想定済みの破壊で、移行 PR でテストごと書き換える。
