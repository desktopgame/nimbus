---
unsafe: true
---

# component
Component のプラッガブル設計・プロパティ・レイアウト属性・メモリ解放・列挙/デバッグ・派生型アクセス方針・setter/getter・ライフサイクル・L&F 想定・フォーカス・ScrollController・install/uninstall。

## プラッガブルな設計
Component を継承した Button、Label などは VTable を独自に実装する。
利用者は普通にビルトインのウィジェットを使えばよく、カスタマイズしたいときだけ VTable を差し替える。
ルックアンドフィールのような「全コンポーネントの VTable を一斉に入れ替える」操作も同じ仕組みで実現できる。

nimbus はルックアンドフィールそのものの設計は提供しない。
設計が難しいことと、カスタマイズポイントを露出しておけば利用者側で実装可能であることが理由。

VTable のカスタマイズポイントは以下の 5 つ。

| エントリ | 用途 |
|---|---|
| `install` | 差し替え時の初期化 hook（プロパティ登録など） |
| `uninstall` | 差し替え時の後片付け hook |
| `paint` | 描画ロジック |
| `processEvent` | イベント処理ロジック |
| `destroy` | メモリ解放（L&F カスタマイズではなく内部責務） |

`destroy` だけは L&F の範疇ではなく、Zig の制約から必要な内部責務（後述「メモリ解放」を参照）。

VTable には「サイズ変化フック」のような枠は意図的に置かない。サイズ変化に反応する必要があるウィジェット (折り返し `TextArea` 等) は、`Component.size_query: ?SizeQuery` (opt-in 能力構造体) で**親レイアウトに pure query 経路を提供する**形を採る。`DragSource` / `DropTarget` と同じパターン (`dnd.md` 参照)。詳細は `component.md`「SizeQuery」と `scrollpane.md`「height-for-width」参照。

### 却下案: VTable.reshape による push 型通知
かつては `?*const fn (*Component, Size) void = null` を VTable に持ち、`setBounds` でサイズが変わると発火していた。`TextArea` がここで `reflow` を呼び `min_size` を更新し、ScrollPane が直後に読み戻すという 2 段モデル。

問題は:

1. **観測可能な state を query 中に書き換える**: `setBounds` の中で `min_size` を更新 → `markLayoutDirty` で親の `min_cache` を invalidate、という副作用が走る。レイアウト計算中にこれが起きると親の cache 整合性が崩れる
2. **暗黙の契約**: 「reshape が呼ばれたら `min_size` を更新し、呼び出し側はその直後に `effectiveMinSize` を読め」という順序前提が型では表現できない
3. **VTable に枠を 1 個生やすコスト**: 全 Component に乗るが事実上 1 ウィジェット (`TextArea` wrap mode) しか使わない
4. **ScrollPane 内部に閉じない**: 同じ height-for-width が必要なケース (vertical BoxLayout 内の折り返し Label など) では、「親が view の reshape 結果を読み戻す合意」がそもそも無いため救えない

`SizeQuery` 路線は (1) pure query で副作用なし、(2) 呼び出しと結果が 1 行に閉じる、(3) opt-in なので必要なウィジェットだけ持つ、(4) ScrollPane に限らずどんな親レイアウトからも `if (child.size_query) |sq| sq.minHeightForWidth(child, w)` で使える、で 4 点とも解消する。

## プロパティ
VTable の差し替えだけでは「コンポーネントが追加の独自状態を持ち、イベントで変化する」ような拡張に対応できない。
このために `Component.properties` を提供する。
Swing `JComponent.putClientProperty` と同じ位置付け。

## レイアウト属性
LayoutManager が子の bounds を計算するための入力として、4 つの属性を持つ。
意味と分配アルゴリズムの詳細は `{REPO_ROOT}/doc/layout-design.md` を参照。

| フィールド | 型 | デフォルト | 意味 |
|---|---|---|---|
| `min_size` | `Size` | `(0, 0)` | これ以下のサイズにはならない |
| `max_size` | `Size` | `(inf, inf)` | これより大きいサイズにはならない |
| `grow_x` | `f32` | `0` | 水平方向に余白があるときの分配重み |
| `grow_y` | `f32` | `0` | 垂直方向に余白があるときの分配重み |
| `align_x` | `Alignment` | `.stretch` | 水平方向の配置（コンテナの主軸が y のとき適用） |
| `align_y` | `Alignment` | `.stretch` | 垂直方向の配置（コンテナの主軸が x のとき適用） |

`min_size` / `max_size` はハード境界であり、grow による分配は max を超えない。
`align_x` / `align_y` は当該軸がコンテナの**交差軸**になっているレイアウトが解釈する（BoxLayout 等）。

### コンテンツ依存の min_size
Label のようにテキスト幅から自然な min_size が決まるウィジェットでは、ウィジェット側 (`Label.setText` など) が自前で `component.min_size` を計算してセットする。
Component 自身には「コンテンツから min を導出する」仕組みは持たない（ウィジェットごとに参照する内部状態が違うため）。

利用者が明示的に上書きしたい場合は `setMinSize` を呼ぶ。
ただしウィジェットが次回 setter を呼んだときに再計算で上書きされる場合がある（ウィジェットの方針による）。

## メモリ解放
Container が子を解放するとき、`allocator.destroy(child)` で素直に free できないのが Zig の制約。
`child` の型は `*Component` だが実体は外側のウィジェット (Label、Button 等) であり、`allocator.destroy` は引数の静的サイズ（sizeof Component）しか free しない。
このままだとウィジェット固有のフィールドが leak する。

そのため VTable に `destroy` を持ち、各ウィジェットが `@fieldParentPtr` で外側に戻して正しいサイズで free する責務を負う。
ファクトリー経由で生成されたウィジェットを利用者が自分で free する場合も `component.vtable.destroy(&comp, allocator)` を呼ぶのが正規ルート。

`Component.deinit` 自体はメモリ解放を行わない（uninstall + properties cleanup まで）。
メモリ解放は `vtable.destroy` の責務。

## コンポーネントの列挙
コンポーネントを再帰的にたどるとき、leaf か container かを判別する手段が必要になる。
`Component.container` フィールドが non-null かどうかで判別する。
Container embed の場合だけ `container` が self を指す。

## コンポーネントのデバッグ
コンポーネントに名前をつけることができる（`setName` / `getName`）。
ルックアップ用ではなく、デバッグダンプ用を想定している。

## 派生型から Component メソッドへのアクセス
Zig は継承を持たないので、派生ウィジェット (Label、Container など) からの Component メソッド呼び出しは**親フィールド直接アクセス**で書く。
委譲メソッドは生やさない。

```zig
label.component.setBounds(.{ ... });
label.component.repaint();
label.component.setName("submit");
```

これは Zig 慣用（`std.ArrayList` の field 直接アクセスと同じスタンス）。
階層が見え、ボイラープレートがゼロになる。

### なぜ委譲メソッドを置かないか
Java の感覚だと `setBounds` / `repaint` あたりは利用者が頻繁に呼ぶ気がするが、nimbus の API 設計だと実際にはそうならない。

| メソッド | 実際の呼び出し主 |
|---|---|
| `setBounds` / `getBounds` | **LayoutManager**。利用者は設定しない |
| `repaint` | **setter が内部で呼ぶ** (`setText` 等)。利用者が直接呼ぶ機会は稀 |
| `setName` / `getName` | デバッグ用。出番少 |
| `setVTable` / properties | 上級者用、明示的でいい |

利用者が頻繁に呼ぶのはウィジェット固有 setter (`label.setText`、`label.setColor`) であり、親 Component メソッドはほぼ呼ばない。
委譲を生やしても普段使われない上にボイラープレートになる。
将来「本当に頻出と判明したメソッド」が出てきたら、その時に派生型に委譲を生やす。

### アップキャスト用 helper
Container には `asComponent()` という親型へのアップキャストのための明示的 helper がある。

```zig
try container.add(label.asComponent());
```

Label など leaf ウィジェットには `asComponent` はないが、`&label.component` で同等。

## setter / getter の方針
書き換え可能なプロパティは **setter / getter をペアで提供する**（Swing 流の対称性）。

| 用途 | 方法 |
|---|---|
| 書き換え（副作用あり） | `setXxx(...)` 必須。内部で dup / repaint / dirty フラグ更新 / (将来) PropertyChangeEvent 等を行う |
| 読み（副作用なし） | `getXxx()` が公式。フィールド直接 read もショートカットとして許容（Zig 慣用） |

Zig はフィールド単位の private 修飾子を持たないので、言語レベルでフィールド直接 write を禁止することはできない。
しかし副作用を必要とする書き換えは setter 経由でないと壊れる（例: text の単純代入は旧 text が leak）。
したがって read は getter / 直接 read どちらも可、write は setter 必須（直接 write 禁止は doc / レビューでカバー）。

将来 `PropertyChangeListener`（Swing の PCE 相当）を導入する余地を残している。
入った時に setter が listener 通知を担う。

## ライフサイクル
factory（またはウィジェットの `create`）が次の手順をひとまとめに行う。

1. `allocator.create(WidgetType)` でウィジェット全体を確保
2. `init` でウィジェット固有のフィールドを初期化（Component のフィールドも含む）。Component の `init(allocator, vtable)` でデフォルト vtable をセット
3. `try component.vtable.install(&component)` を呼ぶ（失敗時は手順 1 で確保した分を errdefer で free して伝搬）

deinit の前に必ず `uninstall` を呼び出すこと。
正規ルートは `component.vtable.destroy(&component, allocator)` で、これが内部で `deinit`（uninstall + cleanup）と `allocator.destroy(widget)` を順に行う。

## ルックアンドフィールの想定実装
コンポーネントを再帰的に列挙して `setVTable` を呼ぶ、というのが想定。
nimbus 自身はこの実装を提供しない。利用者の自由領域。

## フォーカス
`focusable` フィールドはこのコンポーネントがキーボードフォーカスを受け取れるかを示す。
デフォルトは false で、Button / Label / Slider など v1 のウィジェットの多くはフォーカスを取らない。
TextField / TextArea のようにテキスト入力を受けるウィジェットだけが true にセットする。

`requestFocus` を呼ぶと、Window が `focus_owner` を切り替え、新旧のフォーカスオーナーに `FocusEvent` を dispatch する。
詳細は `window.md`「フォーカス」を参照。

framework は Component と Window の直接依存を避けるため、`FocusController` プロパティを介して通知する設計を採る。
Window が各ルートコンポーネント (`container.component`、`menu_bar`、各 overlay) にこのプロパティを install しておき、`Component.requestFocus` は親チェーンを遡ってルートで読み取り、コールバック経由で Window に届ける。
`DirtyNotify` プロパティと同じパターン。

```zig
pub const FocusController = struct {
    user_data:         *anyopaque,
    request_focus_for: *const fn (*anyopaque, ?*Component) void,
};
```

利用者がこの型に触る必要はない (Window が install / 利用する内部仕掛け)。

TODO: フォーカス周りは再設計の可能性高。

## スクロール連携 (ScrollController)
`FocusController` / `DirtyNotify` と同じパターンで、スクロールされるビューが囲っている `ScrollPane` に「この矩形を可視域に入れて」と依頼するための仕掛け。
framework→ScrollPane の直接依存を避けるためプロパティ経由にする。

```zig
pub const ScrollController = struct {
    user_data:              *anyopaque,
    // rect はビューのローカル座標 (0 = ビュー左上)。
    scroll_rect_to_visible: *const fn (*anyopaque, Rect) void,
};

pub fn enclosingScrollController(self: *Component) ?*ScrollController;
```

`ScrollPane` が自分の viewport コンポーネントにこのプロパティを install する (`scrollpane.md` 参照)。
ビュー (例: `TextArea`) は `enclosingScrollController` で親方向に最も近いものを探し、キャレット矩形を渡してスクロールを依頼する。
`ScrollPane` の外で使われている場合は `null` が返り、追従は no-op になる。
`enclosingScrollController` は自分自身は対象に含めず、親から上を探す。

TODO: ScrollControllerは一度チェックの可能性高。

## install / uninstall
`install` を呼んだら必ず対応する `uninstall` も呼び出さなければならない。
VTable を差し替えるときは古い vtable の `uninstall` → 新しい vtable の `install` の順（`setVTable` が内部で行う）。

`install` は失敗し得る (`anyerror!void`)。
リスナー登録 / プロパティ登録など allocator を使う処理を含むウィジェットの install が OOM 等で失敗した場合、`create` factory がその error を呼び出し元に伝搬する。
利用者は通常通り `try app.button(...)` の形で受け取る。

`uninstall` はデストラクタ風で、常に void を返す。
リソース解放しかしないため失敗を返さない設計。
（リスナー解除 / プロパティ free などは失敗しても呼び出し側が回復できないため、`uninstall` 自身が握りつぶす or panic する責任を負う。）
