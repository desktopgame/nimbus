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
- `measure`（intrinsic な最小サイズを計算する）

`paint` / `paintOver` / `measure` は **`user_data`（`*anyopaque`）引数を受け取る**。これは delegate 自身が持つ
（widget 横断で共有される）データ — テクスチャハンドル・グラデーションの stop 配列・9-slice の inset 等 —
を読むため。delegate は 1 つの Look を多数の widget インスタンスに適用するので、共有データは
インスタンス側ではなく delegate（＋ctx）側に置く。

これは **paint を `Component.VTable` から `LookVTable` へ「移す」変種**。`install` / `uninstall` /
`processEvent` / `destroy` は構造側に残り、`paint` が外見側へ移動し、そこへ後フェーズの `paintOver` と
`measure` が加わる。

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
- `paintOver`（後）— 子の **上**に描く。ボーダーなど。**※`paintOver` は仮称**（命名は §5-1 の未決に含める）。

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

### 2.5 measure の配線

`measure`（LookVTable）が **intrinsic な最小サイズ**を計算し、フレームワークがその結果を
**既存の `Component.min_size` / `max_size` フィールドにキャッシュ**する。

- レイアウト機構は無改修。`effectiveMinSize`（Component.zig:327-330）は従来どおり
  `min_size`（コンテナは `Container.getMinSize` の layout 合成）を読むだけ。
  measure はその `min_size` を埋める担当に差し替わるだけで、読み手は変わらない。
- **re-measure トリガ**: 今 `applyMetrics` を呼んでいる箇所（`setText` / `setIcon` / `setFont`。
  Button.zig:142-187）が、代わりに `Look.measure` を呼んで `min_size` を更新する。
  Look の差し替え時にも 1 回 measure する（§3 のユーティリティ）。
- **コンテナは従来どおり** `layout.computeMinSize` で測る（`Container.getMinSize`、Container.zig:132-146）。
  `Look.measure` は **leaf 用フック**であり、コンテナの measure は null / defer でよい
  （コンテナの最小サイズは子から導出され、Look では決まらない）。
- nimbus に **「preferred size」概念は無い**（レイアウトは min ＋ grow）。よって measure が返すのは
  min（必要なら max も）。Swing の `getPreferredSize` 相当は持ち込まない。

### 2.6 メトリクスは LAF 側の定数

Button の `PADDING_X` / `PADDING_Y` / `CORNER_RADIUS` 等（Button.zig:16-20）のようなメトリクスは、
**LAF（Look delegate）側が自分の定数として持つ**。その delegate の `measure` / `paint` がその定数を使う。

- **コンポーネント側に可変メトリクスフィールドは持たせない**。まずは Look 内の定数で十分。
  将来は `user_data` 経由で渡す構造体の変数を読むかもしれない（v1 では定数）。
- LAF 切替 ＝ delegate を丸ごと差し替える → padding 等が一緒に付いてくる → measure 再計算 → `min_size` 更新。
- **「paint だけ差し替えて寸法が古いまま潰れる」不整合は起きない**: paint と measure は同じ `LookVTable` に
  同居し、セットで差し替わるため。これが paint と measure を 1 つの vtable に束ねる主目的。

### 2.7 default Look ＝ FlatLaf 扱い

現在のデフォルト描画を、そのまま **FlatLaf という名の 1 つの LAF** として扱う。

- default `LookVTable` ＝ 今の各 widget の `paint` ＋ 今の `applyMetrics`（updateMinSize）ロジック。
- つまり「LAF 機構を入れる」第一歩は、既存の paint / applyMetrics を default Look へ機械的に移すだけで、
  見た目は不変（回帰しない）。

### 2.8 ctx / user_data の役割分担

- **per-delegate の共有データ**（テクスチャ・グラデ stop・9-slice inset 等、widget 横断で同一）:
  `paint` / `measure` が `user_data`（＝Look の `ctx`）経由で読む。
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

### 2.10 Look を Component にどう持たせるか（提案）

既存の `theme` ポインタの隣に、Look を指すフィールドを置く案を **提案**する（正確な形は詳細で詰める）:

```zig
// 提案（名前・形は仮）
ui: ?struct {
    vtable: *const LookVTable,
    ctx: *anyopaque,
},
```

- `theme: *const Theme` と同じく「既定はフレームワーク既定、ファクトリ DI で差す」流儀に乗せられる。
- 既定（FlatLaf）を `null` で表し「`null` なら built-in default Look」にするか、常に非 null で
  default の `LookVTable` を指すかは詳細（未決）。
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
  `setVTable`（paint コピー差し替え）では **measure を表現できない** — そもそも `measure` は現状の
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

---

## 4. 狙う LAF と awt 依存

### 4.1 狙う LAF

- **FlatLaf（既定）**: 現状描画そのまま。現状の awt プリミティブ（`fillRect` / `fillRoundRect` /
  `drawString` 等）で描ける。追加プリミティブ不要。
- **Swing Metal**: linear 縦グラデーション ＋ bevel ＋ bumps。
- **JTattoo**: テクスチャ（skin）ベース。

### 4.2 awt に要る 2 つの描画プリミティブ（別ワークストリーム・依存として参照のみ）

Metal / JTattoo を実現するには awt 側に 2 つのプリミティブが要る。**本 doc ではスコープ外**（依存として挙げるだけで、
詳細設計は別途・awt 側で行う）:

1. **linear グラデーション fill**（Metal 用。Swing Nimbus 系もほぼ無料で付く）。
2. **テクスチャ ＋ 9-slice（＋tint）**（JTattoo 用）。

既存 backlog との接続:

- `awt_backlog.md` #9（ベクター描画プリミティブ or テクスチャ方式の小アイコン）— テクスチャ経路は
  既に lucide アイコンで実装済み（`awt.Image.fromMemory` → GPU アップロード）であり、9-slice / グラデは
  その延長に位置づく。
- `framework_backlog.md` #27（小アイコン手組みの脱・階段描画）— #9 の framework 側 follow-up。

これらの詳細（グラデの stop 数・軸、テクスチャのゴールデン許容 tolerance 等）は本 doc では決めない。

---

## 5. 未決（解決しない・列挙のみ）

以下は意図的に未確定のまま残す。実装着手時 or 実需が出た時点で作者が決める。

（旧「paint と子再帰の順序問題」は **2 フェーズ paint で解決済み**。§2.4 を参照。残る論点は命名のみで、下記 1 に含む。）

1. **命名**: `Component.LookVTable` / `paint` の後フェーズ `paintOver` / `ui` フィールド / `measure` 等はすべて仮称。
2. **measure の正確なシグネチャ**: min のみか、min ＋ max か。
   既存の `size_query`（height-for-width の pure query、Component.zig:61-66 / 184）との統合をどうするか
   （measure に畳むか、別フックのまま併存させるか）。
3. **Look を Component に持たせる正確な形**: §2.10 の `ui` フィールド案の詳細（null 既定か常時非 null か、
   ctx の所有・寿命）。
4. **外部 `setMinSize` と delegate 自動計算の潰し合い**: **保留（作者が考えたい）**。
   現状、leaf は `applyMetrics` が `min_size` をフィールド上書きするため外部の `setMinSize` が消える
   （Button.zig:135）。コンテナは `getMinSize` が `@max(field, layout)` で合成するので外部設定は floor として同居
   （Container.zig:142-145）。Swing の explicit-set フラグ（`isMinimumSizeSet` 流）で「明示設定は自動計算に勝つ」と
   するかは未決。初心者の罠だがブロッカーではない。override が「勝つ」か「floor」かも未決。
5. **awt 2 プリミティブの詳細**: グラデの stop 数・軸、テクスチャのゴールデン許容 tolerance（§4.2）。
6. **着手順**: LAF イニシアチブと text editor ロードマップ（framework_backlog.md #5：編集コア抽出＋undo）の
   どちらを先に着手するか。

---

## 6. 確定／未決サマリ

| 区分 | 項目 |
|---|---|
| 確定 | init 時固定・実行時差し替え非対応（§1.1） |
| 確定 | Zig コアは mechanism のみ。名前付き LAF はバインディング層（§1.2） |
| 確定 | VTable を構造（install/uninstall/processEvent/**destroy**）と LookVTable（paint/measure＋user_data）へ分割（§2.2） |
| 確定 | 分離理由は「paint＋measure だけを差し替えたい」(3) 案（§2.3） |
| 確定 | Container は専用 paint を失い、`paintAt` 巡回が子再帰を担う（§2.4） |
| 確定 | 2 フェーズ paint＝`paint`（子の下・背景）／子再帰／`paintOver`（子の上・ボーダー）。Panel の現状の見た目を維持（§2.4） |
| 確定 | #4 の「新委譲機構を作らない」を作者承認のもと覆す（measure 固有化のため）。他の #4 決定は維持（§2.11） |
| 確定 | measure 結果を既存 min_size/max_size へキャッシュ。レイアウトは無改修。コンテナは従来 computeMinSize（§2.5） |
| 確定 | メトリクスは Look 側の定数。paint＋measure セット差し替えで寸法不整合を回避（§2.6） |
| 確定 | default Look ＝ FlatLaf（現状描画そのまま）（§2.7） |
| 確定 | theme と Look は分離（UIDefaults vs ComponentUI）（§2.9） |
| 確定 | 一括差し替えユーティリティは power-user 向け・init 前 1 回（§3） |
| 確定 | 狙うのは FlatLaf / Metal / JTattoo。awt に grad / texture+9-slice が要る（別ワークストリーム）（§4） |
| 提案 | Look の保持は `theme` 隣の `ui: ?{ vtable, ctx }`（§2.10） |
| 未決 | 命名（LookVTable / paintOver 等）／measure シグネチャ／ui の形／setMinSize 衝突／awt 詳細／着手順（§5） |
</content>
