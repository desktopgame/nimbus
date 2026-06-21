# LAF（Look and Feel）機構 設計探索

LAF（ルックアンドフィール）の差し替え機構の **設計提案**。利用者とのレビューを経て収束した方針を記録するが、
これは確定版の正本ではなく、**「確定」と「未決」を明確に分けた探索ドキュメント**である。
実装はまだしない（コードは書かない）。実装着手時にこの doc を基に詰める。

この doc は `framework_backlog.md` #4（既定 LAF を public な Theme テーブルから引く＝**完了済み**）の続きにあたる。
#4 は「LAF とは vtable 一式の差し替え／Theme は公開データ」という線引きで、**新しい委譲機構は作らない**と
していた。本 doc はその一点を **作者承認のもと意識的に覆す**（2026-06-20）: paint / measure だけを別 vtable
（後述の `LookVTable`）へ隔離する委譲機構を新設する。覆す理由は **#4 が LAF 固有の measure（最小サイズ計算）を
予見していなかった**から（Metal の bevel・JTattoo の 9-slice は寸法計算も LAF 固有で、`setVTable` では表現できない）。
詳細は §2.11。#4 の他の決定（Theme＝公開データ・起動時固定・ファクトリ DI）は維持する。

関連: theme.zig 冒頭コメント（「a LAF in nimbus is a vtable swap」「no runtime switching」）、
`framework/doc/narrative/theme.md`、awt_backlog.md #9 / framework_backlog.md #27（描画プリミティブ）。

---

## 1. 大前提（確定）

### 1.1 LAF は init 時に固定。実行時差し替えは非対応

LAF はアプリ初期化時に 1 回設定し、**セッション中は固定**とする。実行時の差し替えは（少なくとも v1 では）持たない。

- 根拠: Swing の実行時 LAF 切替（`updateComponentTreeUI`）はバグの温床で、結局アプリ再起動が必要になる経験則。
- 構造的な理由: nimbus はメトリクス（padding 等）を **生成時に `min_size` へ焼き込む**設計
  （`Button.applyMetrics` が `self.component.min_size` を直接書く。Button.zig:115-136）。
  実行中に LAF を差し替えると、全ツリーの re-metrics ＋ 再レイアウト（Swing の無効化プロトコル相当）が必要になり、
  これこそが「実行中 LAF 更新で描画が壊れる」の正体。
- **最初の描画前に 1 回適用して固定する**と宣言することで、runtime-swap バグを設計から消す。

これは theme.zig の既存方針（「The theme is fixed at startup ... there is no runtime switching」）と完全に同じ立場で、
Theme（色）だけでなく Look（描画ロジック＋メトリクス）全体に拡張する。

### 1.2 Zig コアは mechanism だけを露出する

Zig コアが提供するのは「paint / measure を差し替えられる」という **機構（mechanism）だけ**。

- 「LAF」という抽象（名前付き LAF の列挙・レジストリ・簡単切替・選択ポリシー）は、
  Python / JS バインディング層が機構の上に組む。
- LAF 列挙・レジストリ・policy を Zig コアに焼き込まない（[[project_bindings_codegen]] と整合：
  コアは契約を最小に保ち、利便 API は上層）。

---

## 2. アーキテクチャ（確定＝(B1) 変種）

### 2.1 現状の VTable（実装確認）

現状 `Component.VTable` は 5 スロット（Component.zig:138-155）:

```zig
pub const VTable = struct {
    install:      *const fn (self: *Component) anyerror!void,
    uninstall:    *const fn (self: *Component) void,
    paint:        *const fn (self: *Component, g: *awt.Graphics) void,
    processEvent: *const fn (self: *Component, ev: *Event) void,
    destroy:      *const fn (self: *Component, allocator: std.mem.Allocator) void,
};
```

差し替えは `Component.setVTable`（Component.zig:533）が `uninstall → 差し替え → install` で行う（vtable 丸ごと単位）。

### 2.2 VTable を「構造」と「外見」に割る

VTable を 2 つに分割する。

**Component.VTable（構造）** — そのコンポーネントの「振る舞い・骨格」。LAF では変わらない。

- `install` / `uninstall` / `processEvent`
- **`destroy`**（具象 widget のメモリ解放）。これは構造スロットなので **必ず残す**。
  （`destroy` は `@fieldParentPtr` で外側の具象型へ戻り `allocator.destroy` する＝LAF と無関係の寿命管理。
  Button.zig:382-391 / Container.zig:269-273 が現にそうしている。利用者スケッチでは抜けていたが、構造側に残す。）

**Component.LookVTable（外見・名前は仮）** — そのコンポーネントの「見た目・寸法」。LAF で差し替わる対象。

- `paint`（自分の外見を子の **下**に描く＝前フェーズ。背景など）
- `paintOver`（自分の外見を子の **上**に描く＝後フェーズ。ボーダーなど。仮称。詳細は §2.4 の 2 フェーズ paint）
- `measureMinSize`（intrinsic な最小サイズ＝`Size` を計算する。名前は仮だが採用。§2.5）

`paint` / `paintOver` / `measureMinSize` は **`user_data`（`*anyopaque`）引数を受け取る**。これは delegate 自身が持つ
（widget 横断で共有される）データ — テクスチャハンドル・グラデーションの stop 配列・9-slice の inset 等 —
を読むため。delegate は 1 つの Look を多数の widget インスタンスに適用するので、共有データは
インスタンス側ではなく delegate（＋ctx）側に置く。

これは **paint を `Component.VTable` から `LookVTable` へ「移す」変種**。`install` / `uninstall` /
`processEvent` / `destroy` は構造側に残り、`paint` が外見側へ移動し、そこへ後フェーズの `paintOver` と
`measureMinSize` が加わる。

### 2.3 なぜ分離するのか（1 スロットだけ差し替えたい）

vtable は **型ごとの `const` を `*const` で指している**（例: `Container.vtable` は `pub const vtable = ...`、
Container.zig:32-38）。よって個別スロットを書き換えできない（const だから書けないし、書けても
同じ型の全インスタンスへ波及する）。「paint だけ差し替えたい」を満たす手は 3 つ:

1. **vtable 丸ごと別 const に差し替え**（現 `setVTable`）。構造（install/processEvent/destroy）まで巻き込むので、
   LAF の入れ替えで振る舞いまで作り替える羽目になる。
2. **インスタンス毎の可変 vtable**。List のセルのように同型を大量生成する場面でメモリが無駄
   （[[project_list_cell_design]]：可視ぶんの実セル＋recycle で個数が出る）。
3. **変わる部分（paint＋paintOver＋measure）だけを別 vtable に隔離して指し替える** ＝ `LookVTable`。

→ **(3) を採用**。構造は型ごとの const のまま共有し、外見だけを LAF 単位で差せる。

### 2.4 Container の子再帰（最重要の詰めどころ）

現状 `Container.paint` は **子への再帰**をしている（Container.zig:225-230）:

```zig
fn paint(self: *Component, g: *awt.Graphics) void {
    const container = self.container orelse return;
    for (container.children.items) |elem| elem.component.paintAt(g);
}
```

`paintAt`（Component.zig:593-596）は bounds でクリップして `self.vtable.paint` を呼ぶ:

```zig
pub fn paintAt(self: *Component, parent_g: *awt.Graphics) void {
    var g = parent_g.clip(self.getBounds());
    self.vtable.paint(self, &g);
}
```

つまり現状の `paint` は「**自分の外見を描く**」と「**子を再帰描画する**」が 1 つのスロットに同居している。
子の再帰は **Look ではなく構造**（どの LAF でも子は同じ順序・同じクリップで描かれる）。
paint を `LookVTable`（自分の外見のみ）へ移すには、この 2 つを分離する必要がある。

**新しい巡回（2 フェーズ paint・確定）**（Swing の `paintComponent` vs `paintChildren` と同型）:
`LookVTable` は子の **前** と **後** の 2 つの描画フックを持つ。

- `paint`（前）— 子の **下**に描く。背景など。
- `paintOver`（後）— 子の **上**に描く。ボーダーなど。**※`paintOver` は仮称**（命名は §6-1 の未決に含める）。

```
paintAt(self, parent_g):
    g = parent_g.clip(self.getBounds())          // クリップ設定は構造側（不変）
    self.look.paint(self, self.look.ctx, &g)     // 前フェーズ＝子の下（背景など）
    if self.container != null:                   // コンテナなら…
        for child in children: child.paintAt(&g) // 子を再帰（構造側・不変）
    self.look.paintOver(self, self.look.ctx, &g) // 後フェーズ＝子の上（ボーダーなど）
```

帰結:

- **Container は専用 `paint` を持たなくなる**。「子を描く」はフレームワークの `paintAt` 巡回が担い、
  Container の両フェーズは no-op（ふつうのコンテナは自分の外見が無い）。Panel なら前で背景・後でボーダーを描く。
- クリップ / transform の設定（`parent_g.clip(bounds)`）と子の巡回順序（追加順）は構造側に固定され、
  LAF からは触れない。LAF が触れるのは「自分の前後 2 枚の外見」だけ。
- **ほとんどの widget は `paint` だけを使い、`paintOver` は no-op**。
  leaf（子を持たない widget。Button など）は前後の区別が無関係なので、すべて `paint` に描けばよい
  （`paintOver` は使わない）。`paintOver` が効くのは「子の上に重ねたい外見を持つコンテナ」＝Panel のボーダー等だけ。

**Panel が現状の見た目を完全維持する（作者要望）**: 現 `Panel.paint`（Panel.zig:119-143）は
`背景 fillRect → 子の再帰 → ボーダー fillRect` の順で、**自分の外見が子再帰の前後に割り込んでいる**
（背景は子の前、ボーダーは子の後）。この 3 段はそのまま 2 フェーズへ機械的に対応づく:

- `背景 fillRect`（Panel.zig:126-129）→ **前フェーズ `paint`**（子の下）。
- `子の再帰`（Panel.zig:131-133）→ フレームワークの `paintAt` 巡回（構造側）。
- `ボーダー fillRect`（Panel.zig:135-142）→ **後フェーズ `paintOver`**（子の上）。

これにより **ボーダー後描き（子の上）の現挙動が保たれ、見た目は不変**（回帰しない）。
素朴な「`paint(self)` → 子を再帰」だけだとボーダーが子より先に描かれて崩れるが、後フェーズを設けたことで解消される。

### 2.5 measureMinSize の配線（確定）

`measureMinSize`（LookVTable・名前は仮だが採用）が **intrinsic な最小サイズ（`Size`）**を計算し、
フレームワークがその結果を **既存の `Component.min_size` フィールドにキャッシュ**する。

- **戻りは最小サイズ（`Size`）のみ・確定**。max は `measureMinSize` の担当外で、widget が上限を持つ箇所
  （例: TextField の高さ）だけ従来どおり `max_size` を設定する（measure は min 担当・max は据え置きでよい）。
- レイアウト機構は無改修。`effectiveMinSize`（Component.zig:327-330）は従来どおり
  `min_size`（コンテナは `Container.getMinSize` の layout 合成）を読むだけ。
  `measureMinSize` はその `min_size` を埋める担当に差し替わるだけで、読み手は変わらない。
- **re-measure トリガ**: 今 `applyMetrics` を呼んでいる箇所（`setText` / `setIcon` / `setFont`。
  Button.zig:142-187）が、代わりに `Look.measureMinSize` を呼んで `min_size` を更新する。
  Look の差し替え時にも 1 回 `measureMinSize` する（§3 のユーティリティ）。
- **コンテナは従来どおり** `layout.computeMinSize` で測る（`Container.getMinSize`、Container.zig:132-146）。
  `Look.measureMinSize` は **leaf 用フック**であり、コンテナの `measureMinSize` は null / defer でよい
  （コンテナの最小サイズは子から導出され、Look では決まらない）。
- nimbus に **「preferred size」概念は無い**（レイアウトは min ＋ grow）。
  Swing の `getPreferredSize` 相当は持ち込まない。

### 2.6 メトリクスは LAF 側の定数

Button の `PADDING_X` / `PADDING_Y` / `CORNER_RADIUS` 等（Button.zig:16-20）のようなメトリクスは、
**LAF（Look delegate）側が自分の定数として持つ**。その delegate の `measureMinSize` / `paint` がその定数を使う。

- **コンポーネント側に可変メトリクスフィールドは持たせない**。まずは Look 内の定数で十分。
  将来は `user_data` 経由で渡す構造体の変数を読むかもしれない（v1 では定数）。
- LAF 切替 ＝ delegate を丸ごと差し替える → padding 等が一緒に付いてくる → `measureMinSize` 再計算 → `min_size` 更新。
- **「paint だけ差し替えて寸法が古いまま潰れる」不整合は起きない**: paint と `measureMinSize` は同じ `LookVTable` に
  同居し、セットで差し替わるため。これが paint と `measureMinSize` を 1 つの vtable に束ねる主目的。

### 2.7 default Look ＝ FlatLaf 扱い

現在のデフォルト描画を、そのまま **FlatLaf という名の 1 つの LAF** として扱う。

- default `LookVTable` ＝ 今の各 widget の `paint` ＋ 今の `applyMetrics`（updateMinSize）ロジック。
- つまり「LAF 機構を入れる」第一歩は、既存の paint / applyMetrics を default Look へ機械的に移すだけで、
  見た目は不変（回帰しない）。

### 2.8 ctx / user_data の役割分担

- **per-delegate の共有データ**（テクスチャ・グラデ stop・9-slice inset 等、widget 横断で同一）:
  `paint` / `measureMinSize` が `user_data`（＝Look の `ctx`）経由で読む。
- **per-instance の LAF 固有状態**（アニメーションの進行度など。稀）: 既存の Component プロパティ袋
  （`putProperty` / `getProperty` / `putTyped` / `getTyped`、Component.zig:624-662）で足りる。
  → **v1 では専用フィールド不要**。

### 2.9 theme と Look は分ける

`theme`（色カタログ）と `Look`（描画ロジック）は別物として分離する（Swing の `UIDefaults` vs `ComponentUI` と同型）。

- 既存 `theme`（`Component.theme: *const Theme`、Component.zig:215。色のみ・約 26 フィールド。theme.zig）は **Look とは別に残す**。
- 将来「LAF の UIDefaults」（gradient stop / texture / メトリクス値の器）へ育てる余地がある。
  Look はそのトークンを読む側になる。
- 役割: **Theme ＝ 値の器（公開データ）**、**Look ＝ それを使って描く手続き（差し替え対象）**。
  自前 Look は `component.theme` を読んでアプリのテーマ切替に追従してもよいし、無視してもよい
  （theme.zig 既述：「Custom-paint LAFs may read `component.theme` ... or ignore it entirely」）。

### 2.10 Look を Component にどう持たせるか（end-state は非 null で確定）

既存の `theme` ポインタの隣に、Look を指すフィールドを置く（フィールド名 `ui` は仮）。

**end-state では `ui` は常に非 null**（既定は built-in default Look を指す）に**確定**。
読み手は「`ui` があれば」の分岐を持たず、常に `ui` 経由で `paint` / `measureMinSize` へ入る（**分岐レス**）。

```zig
// 名前は仮。end-state は非 null（移行期のみ ? を許す。§5 cutover 参照）
ui: ?struct {
    vtable: *const LookVTable,
    ctx: *anyopaque,
},
```

- `theme: *const Theme` と同じく「既定はフレームワーク既定、ファクトリ DI で差す」流儀に乗せられる。
- 型上 `?`（optional）にするのは **移行期のフォールバックのため**（`ui` 無しは旧 `Component.VTable.paint` へ落とす）。
  これは段階移行の足場であり、**P2 完了時の cleanup で常に非 null 化して `?` とフォールバックを撤去**する（§5 cutover）。
- ctx の所有・寿命は詳細（未決・§6-3）。
- `processEvent` 等の構造 vtable（`component.vtable`）は従来どおり型ごとの const を指したまま。

### 2.11 #4 の「新機構を作らない」を意識的に覆す（明記）

framework_backlog #4 は「差し替えの座席は既存 `setVTable` のみ、**新しい委譲機構は作らない**」「Swing
ComponentUI 風の委譲機構新設は**却下**」としていた。
**作者は 2026-06-20、この一点を意識的に覆すことを承認した。**

正直に言えば、`LookVTable` は #4 の文言上の「**二つ目の差し替え機構**」そのものである（§2.3 の (1)＝`setVTable`
一本だけ、という #4 の前提を崩す）。「別物だから #4 と矛盾しない」という和解では甘い。覆す理由を明示する:

- **#4 は LAF 固有の `measure`（最小サイズ計算）を一切考慮していなかった**。#4 が見ていたのは色とメトリクスを
  Theme テーブルへ追い出すことと、フル LAF を「既定 vtable をコピーして `paint` を差し替える」既存の
  デコレーションパターンで実現することだった。
- ところが新ターゲット（§4）の **Swing Metal の bevel・JTattoo の 9-slice** は、`paint` だけでなく
  **寸法計算も LAF 固有**になる（bevel ぶんの内寸・9-slice の inset が最小サイズに効く）。
  `setVTable`（paint コピー差し替え）では **measure を表現できない** — そもそも `measureMinSize` は現状の
  `VTable`（Component.zig:138-155）に存在せず、各 widget が `applyMetrics` で `min_size` を焼くだけ
  （Button.zig:115-136）。LAF ごとに寸法を差し替える受け皿が無い。
- つまり **#4 の機構は新ターゲットに力不足**。「二つ目の機構を作らない」は、**#4 が予見しなかった要件
  （LAF 固有の measure）のために改める**。paint と measure をセットで隔離する `LookVTable` がその受け皿になる。

ただし **#4 の他の決定はすべて維持する**: 「Theme ＝ 公開データ」「LAF は起動時固定（実行時切替なし）」
「ファクトリ DI でテーマ／Look を注入」。覆すのは「`setVTable` 一本／二つ目の機構なし」の一点のみ。
レジストリ・名前付き LAF・カスケードは依然 **持ち込まない**（§1.2 のとおりバインディング層の仕事）。

---

## 3. 一括差し替えユーティリティ（確定）

Look（外見 vtable）を **ツリー全体へ一斉に差し替える**ユーティリティが要る。

- ツリーを巡回し、caller 指定の Look を各コンポーネントへ適用（`LookVTable` ポインタ＋`ctx` を設定）→
  各ノードで re-measure（`min_size` 更新）→ 全体 relayout。
- 呼び出しタイミング: **init 時・最初の描画前に 1 回**（§1.1 のセッション固定を実現する唯一の入口）。
- 位置づけ: **power-user / irregular なツール**。`init` / `initWithTheme` と並ぶ第一級 API ではなく、
  脇に置く（普通の利用者は名前付き LAF をバインディング層から選ぶだけ。生の Look 差し替えは上級者向け）。

このユーティリティ（P3）の確定設計は [laf_enabler.md](laf_enabler.md) に切り出した
（remap 表の表現・`applyLook` の署名と巡回・部分 LAF・ゼロピクセルテスト・ctx 寿命）。

---

## 4. 狙う LAF と awt 依存

### 4.1 狙う LAF

- **FlatLaf（既定）**: 現状描画そのまま。現状の awt プリミティブ（`fillRect` / `fillRoundRect` /
  `drawString` 等）で描ける。追加プリミティブ不要。
- **Swing Metal**: linear 縦グラデーション ＋ bevel ＋ bumps。
  Button 縦スライス（初の実 Metal Look）の設計 spec は [laf_metal_button.md](laf_metal_button.md)。
- **JTattoo**: テクスチャ（skin）ベース。

### 4.2 awt に要る 2 つの描画プリミティブ（別ワークストリーム・依存として参照のみ）

Metal / JTattoo を実現するには awt 側に 2 つのプリミティブが要る。**本 doc ではスコープ外**（依存として挙げるだけで、
詳細設計は別途・awt 側で行う）。**詳細設計は `awt_primitives_laf.md` に切り出した**（軸 / stop 数 / 9-slice の
inset 表現 / ゴールデン tolerance / program 配線 / フェーズ分けを確定）:

1. **linear グラデーション fill**（Metal 用。Swing Nimbus 系もほぼ無料で付く）。
2. **テクスチャ ＋ 9-slice（＋tint）**（JTattoo 用）。

既存 backlog との接続:

- `awt_backlog.md` #9（ベクター描画プリミティブ or テクスチャ方式の小アイコン）— テクスチャ経路は
  既に lucide アイコンで実装済み（`awt.Image.fromMemory` → GPU アップロード）であり、9-slice / グラデは
  その延長に位置づく。
- `framework_backlog.md` #27（小アイコン手組みの脱・階段描画）— #9 の framework 側 follow-up。

これらの詳細（グラデの stop 数・軸、テクスチャのゴールデン許容 tolerance 等）は本 doc では決めず、
`awt_primitives_laf.md` で確定させた。

---

## 5. 実装フェーズと cutover（実装計画）

LAF 機構を **default Look ＝ 現状の見た目** のまま段階導入する実装計画。
メカニズム移行のみなので、各フェーズの受け入れ条件の核は **snapshot golden が 1 枚も動かないこと**。

### 5.1 ゼロピクセル不変条件（回帰ガード）

default Look は現状描画をそのまま移し替えたものなので、**snapshot golden は 1 枚も変わらないはず**。
golden が動いたら、それは LAF の見た目変更ではなく **移行のバグ**である。
このゼロピクセル不変条件を全フェーズの回帰ガードとする（golden が動いたら移行ミスを疑う、と明記）。

### 5.2 cutover（移行期はフォールバック付き）

`paintAt` を `LookVTable` 経由に変えるのは **全ウィジェットに効く**ため、一斉切替はリスクが高い。
そこで移行期は `ui` を **任意（null 可）** にし、`paintAt` を次のフォールバック付きにする:

- `ui` があれば → 新経路（2 フェーズ `paint` / `paintOver` ＋ `measureMinSize`）。
- `ui` が無ければ → 旧 `Component.VTable.paint` にフォールバック。

これで **一部のウィジェットだけ default Look へ移行しても golden を動かさず段階移行できる**。
**P2 完了時の cleanup で `ui` を常に非 null 化し、旧 paint スロットとフォールバックを撤去**する。
これにより §2.10 の「end-state では常に非 null（分岐レス）」が **end-state として実現**する。

### 5.3 フェーズ分け

- **P1: 足場 ＋ 代表 3 つ**。`LookVTable` 型・`ui` フィールド・2 フェーズ `paintAt` を入れ、
  次の代表 3 つを default Look へ移行する:
  - **Button**（leaf）
  - **Panel**（2 フェーズ paint＝前で背景・後でボーダー。§2.4）
  - **素の Container**（再帰のみ・自分の外見なし）

  受け入れ条件: **視覚回帰ゼロ（snapshot golden を 1 枚も変えない）＋全テスト緑**。
- **P2: 残りの全ウィジェットを default Look へ移行**。leaf は機械的に、
  再帰するコンテナは P1 と同型に慎重に移す。完了時に §5.2 の cleanup（`ui` 非 null 化・フォールバック撤去）。
- **P3: 一括差し替えユーティリティ**（§3）。power-user 向け。
  走査で per-widget-type の Look を当てる **型識別の宿題はここで詰める**。
  → 確定設計は [laf_enabler.md](laf_enabler.md)（型識別は §5.3 の宿題を「型ごと一意な
  `&Type.look_vtable` を型タグに流用」で解いた。§2.2）。
- **後（別イニシアチブ）**: awt の 2 プリミティブ（linear グラデ／テクスチャ＋9-slice。§4.2）と
  実 Metal / JTattoo Look。本 doc / 本フェーズ群のスコープ外。

---

## 6. 未決（解決しない・列挙のみ）

以下は意図的に未確定のまま残す。実装着手時 or 実需が出た時点で作者が決める。

（旧「paint と子再帰の順序問題」は **2 フェーズ paint で解決済み**。§2.4 を参照。残る論点は命名のみで、下記 1 に含む。）

1. **残りの命名**: `Component.LookVTable` / `paint` の後フェーズ `paintOver` / `ui` フィールド等は仮のまま進めてよい
   （確定不要）。※`measure` だけは `measureMinSize` を採用済み（§2.5）。
2. **`measureMinSize` と `size_query` の統合**: min を返す点は確定（§2.5）。残るは既存の `size_query`
   （height-for-width の pure query、Component.zig:61-66 / 184）との統合をどうするか
   （`measureMinSize` に畳むか、別フックのまま併存させるか）。
3. **ctx の所有・寿命**: `ui` が常時非 null（end-state）である点は確定（§2.10）。残るは `ctx` の所有・寿命の詳細。
4. **外部 `setMinSize` と delegate 自動計算の潰し合い**: **min_size については解決済み**。
   `applyLook` の true-leaf re-measure が外部 `setMinSize` を潰す実需（showcase の縦スライダー）が出たため、
   Swing の `isMinimumSizeSet` 流の explicit-set フラグ（`Component.min_size_explicit`）を導入し、
   **明示は「絶対勝ち」＝re-measure をスキップ**（floor ではない）とした。コンテナは `getMinSize` の
   `@max(field, layout)` floor 同居のまま無改修。確定設計は [min_size_explicit.md](min_size_explicit.md)。
   色 override 等への横展開（フィールド別フラグ）は将来課題として同 doc §6。
5. **awt 2 プリミティブの詳細**: グラデの stop 数・軸、テクスチャのゴールデン許容 tolerance（§4.2）。
   → **`awt_primitives_laf.md` に切り出して確定済み**（縦固定 2 stop・9-slice は 4 inset・per-scene tolerance）。
   本 doc 側では未決のまま残さない。
6. **着手順**: LAF イニシアチブと text editor ロードマップ（framework_backlog.md #5：編集コア抽出＋undo）の
   どちらを先に着手するか。

---

## 7. 確定／未決サマリ

| 区分 | 項目 |
|---|---|
| 確定 | init 時固定・実行時差し替え非対応（§1.1） |
| 確定 | Zig コアは mechanism のみ。名前付き LAF はバインディング層（§1.2） |
| 確定 | VTable を構造（install/uninstall/processEvent/**destroy**）と LookVTable（paint/measureMinSize＋user_data）へ分割（§2.2） |
| 確定 | 分離理由は「paint＋measureMinSize だけを差し替えたい」(3) 案（§2.3） |
| 確定 | Container は専用 paint を失い、`paintAt` 巡回が子再帰を担う（§2.4） |
| 確定 | 2 フェーズ paint＝`paint`（子の下・背景）／子再帰／`paintOver`（子の上・ボーダー）。Panel の現状の見た目を維持（§2.4） |
| 確定 | #4 の「新委譲機構を作らない」を作者承認のもと覆す（measure 固有化のため）。他の #4 決定は維持（§2.11） |
| 確定 | measure は `measureMinSize`（仮だが採用）。最小サイズ（`Size`）のみ返し min_size へキャッシュ。max は widget が従来どおり設定。コンテナは従来 computeMinSize（§2.5） |
| 確定 | メトリクスは Look 側の定数。paint＋measureMinSize セット差し替えで寸法不整合を回避（§2.6） |
| 確定 | default Look ＝ FlatLaf（現状描画そのまま）（§2.7） |
| 確定 | theme と Look は分離（UIDefaults vs ComponentUI）（§2.9） |
| 確定 | 一括差し替えユーティリティは power-user 向け・init 前 1 回（§3） |
| 確定 | 狙うのは FlatLaf / Metal / JTattoo。awt に grad / texture+9-slice が要る（別ワークストリーム）（§4） |
| 確定 | Look 保持は `ui`（`theme` 隣）。**end-state は常に非 null**（分岐レス・移行期のみ null 可）（§2.10） |
| 確定 | 実装フェーズ P1（足場＋Button/Panel/素 Container）→ P2（全移行＋cleanup）→ P3（一括差し替え）。ゼロピクセル不変条件が回帰ガード（§5） |
| 未決 | 残命名（LookVTable / paintOver / ui）／`measureMinSize` と `size_query` の統合／ctx 所有・寿命／setMinSize 衝突／awt 詳細／着手順（§6） |
</content>
