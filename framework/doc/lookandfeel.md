# Look and Feel — 検討草案

CLAUDE.md「目指すゴール」に挙げられている **ルックアンドフィールの切り替え** をどう実装するかの設計検討。

## 結論 (草案)

**nimbus framework は L&F 機構を組み込まない**。

代わりに次の 2 つを提供する:
1. **Component vtable のフック点** — `ctor` / `dtor` / `paint` / `processEvent` の最小セット
2. **ビルトイン widget のデフォルト実装** — Label / Button / ... が固定の見た目で動く (= nimbus 純正 L&F)

L&F を切り替えたい / カスタマイズしたいユーザーは、フック点を使って好きにやる。Theme / UIManager / Style といったレイヤーは framework に置かない。

## なぜこの方針か

### Swing の paintComponent が達人を生んだ理由

参考: <https://ateraimemo.com/Swing.html> — 寺西さんの Swing/Tips。円形ボタン、フィッシュアイメニュー、ガラスペインエフェクト、独自スピナー、Pie Chart 風プログレス、星形チェックボックス ...「Swing でここまでできる」の宝庫。

これらが成立する核心は **「特別な機構なしに paint を override できる」** こと。Swing の `JComponent.paintComponent(g)` は最終的に `Graphics` を受けるだけのコールバック。Look and Feel (`ComponentUI`) の存在を意識せずに自由に描ける。

逆に言えば、framework が「Theme」「UIManager」「Style」を組み込んだ瞬間、「framework が想定しなかったハック」がやりにくくなる。寺西さんの作例の多くは、もし `Theme` 経由でしか描画できない API だったら成立しない。

### mechanism, not policy

UNIX 哲学の有名な原則。framework は「描画とイベントをフックできる場所」(mechanism) だけを提供し、「色をどう管理するか」「テーマをどう束ねるか」(policy) はユーザーに任せる。

- Theme を組み込まない → ユーザーが好きな粒度で自前 Theme を書ける (or 書かなくてもよい)
- UIManager を組み込まない → 「全 widget の色を一括変更」がしたければユーザーが setter を呼べばよい
- Skin / Behavior 分離をしない → どうしてもやりたい人は自分の widget 階層でそう設計できる

framework が引いた線は誰も超えられない。引かないことで自由になる。

### 「ビルトインで十分」というユーザーの満足

逆方向の配慮も必要: 「そんな自由はいらない、よくある GUI を最小コストで作りたい」というユーザーが大多数。

→ **ビルトイン widget は固定の見た目を持ち、constructor で作っただけで普通に動く**。Theme を書く必要も、paint を override する必要もない。これが nimbus 純正 L&F。

```zig
const button = try app.button("OK");  // この時点で nimbus 純正の見た目になる
try frame.add(&button.component);
```

達人と一般ユーザーの両方を満たすには:
- mechanism (vtable + paint) は誰でも触れる
- ビルトイン default は触らなくても完成している

## Component vtable (草案)

ユーザー提案のシンプル版:

```zig
pub const Component = struct {
    pub const VTable = struct {
        ctor:         *const fn (self: *Component) void,                       // 初期化 hook (将来用、v1 では未使用)
        dtor:         *const fn (self: *Component) void,                       // 破棄
        paint:        *const fn (self: *Component, g: *awt.Graphics) void,     // 描画
        processEvent: *const fn (self: *Component, ev: *const Event) bool,     // イベント (true = handled)
    };

    vtable:   *const VTable,
    position: Point,    // 親 Container 内のローカル座標 (論理pt)
    size:     Size,     // 論理pt
    parent:   ?*Component,

    pub fn getBounds(self: Component) Rect {
        return .{ .x = self.position.x, .y = self.position.y, .width = self.size.width, .height = self.size.height };
    }
};
```

これだけで「描画と入力をフックできる」状態になる。L&F の機構は **framework として** は何もしない。

### Container も Component の一種

Container は Component を embed して `children: ArrayList(*Component)` を持つ通常の widget。vtable.paint で children を再帰描画、vtable.processEvent で子に dispatch、vtable.dtor で子を再帰開放。

Container 自体に L&F 的なものは無い。「children の並べ方を変えたい」→ Container を継承して自前の paint / layout を書く。

## ユーザーが L&F をやりたい時のパターン

framework は「やり方」を強制しない。ユーザーは状況に応じて選ぶ:

### パターン 1: widget を継承して paint override

```zig
// 自前 RoundedButton — Button をベースに見た目だけ変える
pub const RoundedButton = struct {
    button: nimbus.Button,
    radius: f32,

    pub const vtable = nimbus.Component.VTable{
        .ctor         = nimbus.Button.vtable.ctor,
        .dtor         = nimbus.Button.vtable.dtor,
        .processEvent = nimbus.Button.vtable.processEvent,  // 振る舞いは Button 流用
        .paint        = paint,                              // 描画だけ差し替え
    };

    fn paint(self: *nimbus.Component, g: *awt.Graphics) void {
        const rb: *RoundedButton = @fieldParentPtr("button", @as(*nimbus.Button, @fieldParentPtr("component", self)));
        g.setColor(rb.button.background);
        g.fillRoundRect(.{ .x = 0, .y = 0, .width = self.size.width, .height = self.size.height }, rb.radius);
        // テキスト描画など
    }
};
```

vtable はフィールド単位で部分差替できるので、「振る舞いは Button のまま、描画だけ変える」が自然に書ける。

### パターン 2: setter で個別調整

ビルトイン widget が `setBackground` / `setForeground` / `setFont` / `setBorder` を持つ。これで色変更程度はカバーできる。

```zig
const btn = try app.button("OK");
btn.setBackground(Color.rgb(0.2, 0.5, 0.9));
btn.setFont(my_font);
```

### パターン 3: ユーザーランド Theme

「色テーマを束ねて全 widget に適用したい」というユーザーが、**自分で** Theme struct を作って各 widget に注入する。

```zig
// ── ユーザーが自分のアプリで定義する Theme ────────────
const MyTheme = struct {
    button_bg: Color,
    text_color: Color,
    // ...

    fn apply(self: MyTheme, b: *nimbus.Button) void {
        b.setBackground(self.button_bg);
        b.setForeground(self.text_color);
    }
};

const theme = MyTheme{ ... };
theme.apply(button1);
theme.apply(button2);
```

framework はこれを **強制しない / 機構として提供しない**。やりたい人が自分で書ける構造になっている、それで十分。将来「よくあるパターン」が固まったら helper として外付けライブラリ (`nimbus-themes` 等) で配るのは可。

### パターン 4: 完全自作 widget

`Component` vtable から自前で書く。paint も processEvent も自由。これで「Swing の達人ハック」相当が可能。

```zig
pub const PieChart = struct {
    component: nimbus.Component,
    values: []const f32,

    pub const vtable = nimbus.Component.VTable{
        .ctor = noop, .dtor = dtor,
        .paint = paint,
        .processEvent = noop_event,
    };

    fn paint(self: *nimbus.Component, g: *awt.Graphics) void {
        const pc: *PieChart = @fieldParentPtr("component", self);
        // pc.values を使って円グラフを描く ...
    }
};
```

これで Label / Button と全く同じ扱いで使える。framework は「ビルトイン widget」と「ユーザー定義 widget」を区別しない。

## 不採用とした案

過去案として書いていた「Theme + Painter Override」(framework に Theme を組み込む案) は **不採用**。理由:

1. framework が Theme を抱え込むと、ユーザーが想定しなかったハックがやりにくい (寺西さんモデルの否定)
2. ビルトインの見た目が欲しいだけのユーザーには Theme は overkill
3. 真の意味でカスタム L&F を作りたいユーザーには Theme は窮屈
4. mechanism (vtable) があれば policy (Theme) はユーザーランドで書ける

「framework が Theme を提供しないと L&F 切替ができない」と感じるが、実態は逆: ユーザーが自由に paint を書ける方が、より多様な L&F が作れる。

## 他フレームワーク再評価

| フレームワーク | L&F 機構 | ユーザー自由度 |
|---|---|---|
| wxWidgets | OS native のみ | 低 (native widget の置き換えはやりにくい) |
| Qt QStyle + QSS | 強力な機構を framework が用意 | 中 (QStyle を継承して書ける、ただし大変) |
| Swing ComponentUI + UIManager | 強力 | 中 (ComponentUI 書くのは大仕事) |
| Swing paintComponent | (上記に加えて) 自由 | **高** ← nimbus が真似たい部分 |
| JavaFX Skin + Behavior + CSS | 強力 | 中〜高 |
| **nimbus** | **持たない** | **高** (vtable + paint override が自然) |

nimbus は Swing の `ComponentUI / UIManager` 系統を **採用せず**、`paintComponent` 系統だけを採る (寺西さん風)。

## ビルトイン nimbus L&F の position

各 widget (Label / Button / ...) は **固定の見た目** を vtable.paint のデフォルトとして持つ:
- 色: ニュートラルなパレット (light / dark の 2 種類用意するかは v2 検討)
- フォント: Application default font (Noto Sans CJK)
- メトリクス: 適度なパディング、角丸 4pt 程度

これは「nimbus を入れてすぐ動く」体験のため。ユーザーが触らない限りこの見た目で動く。

将来「dark mode 検出」「OS hint」を入れる場合も、framework に強制的に組み込むのではなく、`app.setDefaultBackground(...)` 程度の setter で対応する想定。

## まとめ

| 観点 | nimbus の方針 |
|---|---|
| Theme 機構 | **framework として提供しない** (ユーザーランドで書ける) |
| UIManager | 提供しない |
| Skin / Behavior 分離 | しない (vtable に両方ある) |
| ビルトイン見た目 | 各 widget が固定 paint を持つ (= nimbus 純正) |
| カスタム見た目 | widget 継承 + paint override で実現 |
| カスタム L&F 切替 | ユーザーが自前 Theme struct + setter で実現 |
| 達人ハック (寺西モデル) | **vtable.paint で何でもできる** |

mechanism は最小に、policy はユーザーに開放する。
