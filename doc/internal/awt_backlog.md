# awt / awt-c バックログ
awt（描画バックエンド抽象）・awt-c（GLFW / FreeType / DX12 / Metal の薄いラッパー）層で後回しにした項目。
書き方は [backlog.md](backlog.md) を参照。

由来: 旧 `todo.md`（backlog 規約より前のフラットな TODO）の "Later" のうち、CLAUDE.md の目標と重複しない
ものをここへ移した。`todo.md` の Now/Next は実装済み、Done は git 履歴、宣言的レイアウト / Linux /
Python・JS バインディングは CLAUDE.md に目標として記載済みのため移送せず。

---

## #1 ビルド時シェーダーコンパイルへの移行
- 状態: 棚上げ
- 優先度: 低
- 影響範囲: awt-c（`nmCompileShader`）、ビルド（DXC / Metal compiler 導入）
- 更新日: 2026-06-02
- 依存: なし

### 何
現状シェーダーは実行時コンパイル（awt-c の `nmCompileShader` 経由）。これをビルド時コンパイル
（Windows: DXC、Mac: Metal compiler）に移す。起動コスト削減・配布時のドライバ依存低減が狙い。

### なぜ（保留理由）
実行時コンパイルで動いており、ビルド時化はツールチェーン導入（DXC/metal）とクロスコンパイルへの影響を
要検討。実需（起動コスト・配布要件）が出てから。

---

## #2 `nmAwtInit` / `nmTerminateAwt` の命名最終確認
- 状態: 未着手
- 優先度: 低
- 影響範囲: awt-c 公開 API 名
- 更新日: 2026-06-02
- 依存: なし

### 何
awt 初期化/終了の API 名を最終確認する（`nmInit` だと汎用すぎる懸念。`nmAwtInit` 等に寄せるか）。
公開 ABI 名なので決めたら早めに固定したい。

---

## #3 vendor/glfw の大きいバイナリ資産の整理
- 状態: 棚上げ
- 優先度: 低
- 影響範囲: リポジトリ（vendoring）
- 更新日: 2026-06-02
- 依存: なし

### 何
`vendor/glfw-3.4/` の `glfw.ico` 等のバイナリ資産を Git LFS に流すか、不要なら除外するか整理する。
リポジトリ肥大の抑制。

## #4 buffer bind 系の診断情報と実装のズレ (offset 境界 / 256 アライン)
- 状態: 未着手
- 優先度: 中
- 影響範囲: awt-c の `nmBindVertexBuffer` / `nmBindIndexBuffer` / `nmBindConstantBuffer`（`dx12_buffer.c` / `metal_buffer.m`）、`awt-c/doc/buffer.md`
- 更新日: 2026-06-07
- 依存: なし

### 何
2026-06-07 の doc↔実装 追従監査で検出。`buffer.md` の `### 診断情報` が以下の検査を約束しているが、実装に該当チェックもログも無い:
- `nmBindVertexBuffer`（doc:79）: `offset` が buf サイズ以上で `[ERROR] ... offset out of bounds`。実装（`dx12_buffer.c:80-88`）は無条件に `buf->size - offset` で view 作成（offset > size で負値ラップの危険）。
- `nmBindIndexBuffer`（doc:93）: 同上（`dx12_buffer.c:90-98`）。
- `nmBindConstantBuffer`（doc:132）: `offset` が 256 の倍数でないとき `[ERROR] ... not aligned to 256`。実装（`dx12_buffer.c:100-132`）に 256 アラインチェック無し。なお doc:125 は既に「256 の倍数であること。違反は UB」と事前条件で書いており、診断情報と二重・矛盾している。

診断情報を信じて呼ぶ利用者が、実際にはチェックされず壊れうる。

### なぜ（保留理由）
「ガードを実装する」か「doc を UB 事前条件に寄せて診断行を削除する」かは、awt-c のバインド系 API の安全契約の選択であり作者判断。即 doc 削除に倒すと runtime の安全網を下げる方向なので一旦保留。

### 候補アプローチ
- 案A: 実装にチェック + ログを足す — doc に実装を合わせる。メリット: 約束どおりの安全網。デメリット: bind ホットパスに分岐追加。
- 案B: doc を UB 事前条件に寄せ、診断情報行を削除 — 実装に doc を合わせる（追従基準のデフォルト）。`nmBindConstantBuffer` は既に UB 事前条件があるので診断行を消すだけ。vertex / index は事前条件「`offset` は buf サイズ以内。違反は UB」を足して診断行削除。メリット: ホットパスを増やさない・即追従。デメリット: 安全網は無いまま。
- 判断軸: bind 系のホットパス性能を取るなら B、デバッグ時の安全網を取るなら A（debug ビルドのみ assert にする折衷も可）。
- 推奨: 折衷（debug で assert、release はノーチェック、doc は「debug で検出 / release は UB」に統一）。最終判断は作者。

### 決めること
A / B / 折衷 のいずれか。3 関数で揃える。

### 完了条件
選んだ方針で実装 or doc を更新し、`buffer.md` の `### 診断情報` と実装が一致する状態。

## #5 EventQueue.invokeAndWait の UI スレッド呼び出し診断（release でログ無し）
- 状態: 未着手
- 優先度: 低
- 影響範囲: awt の `EventQueue.invokeAndWait`（`EventQueue.zig`）、`awt/doc/event_queue.md`
- 更新日: 2026-06-07
- 依存: なし

### 何
`event_queue.md`:93 が「UI スレッドから `invokeAndWait` を呼ぶと release ビルドでは `[ERROR] [event_queue] invokeAndWait called from UI thread (would deadlock)` を出して return」と書くが、実装（`EventQueue.zig:87-93`）は `std.debug.assert(false); return;` のみ。release（ReleaseFast / Small）では assert が no-op になり、**何のログも出さず黙って return** する。

### なぜ（保留理由）
release でデッドロック回避の sentinel return をするとき、診断を出すか黙るかは設計判断。doc は「ログを出す」前提で書かれているので、ログを足すか doc を「release は無診断 return」に直すか作者が選ぶ。

### 候補アプローチ
- 案A: 実装に release でも出る `nm_log`（ERROR）相当を足す — doc に実装を合わせる。誤用が静かに握り潰されないメリット。
- 案B: doc:93 を実装に合わせ「debug: panic / release: 無診断で即 return」に書き換え。追従基準のデフォルト。
- 推奨: 案A 寄り（静かなデッドロック回避は気付けないと厄介）。ただし最終判断は作者。

### 決めること
A（ログ追加）か B（doc を無診断 return に修正）か。

### 完了条件
選んだ方針で実装 or doc を更新し、`event_queue.md`:90-93 と実装が一致。

## #6 エラー名の正規化と公開境界での名前付きエラーセット導入
- 状態: 未着手
- 優先度: 低
- 影響範囲: awt の error リテラル全般（`Device` / `Swapchain` / `Pipeline` / `VertexRing` / `UniformBuffer` / `GlyphAtlas` / `RootSignature` / `RenderTarget` / `Font` / `root.zig`）、公開境界としては framework の `Application` / `Window` も。最終的に C ABI 変換層（`c_api.zig` の `errorToCode`）
- 更新日: 2026-06-07
- 依存: なし（ただし C ABI 本格実装と一緒にやると手戻りが少ない）

### 何
旧 `doc/audit-2026-05-23.md` §2 から移送。現状 framework / awt とも名前付き `error{...}` セットは 0 件で、全て inferred `!T`。C ABI 変換（NULL 返し + `last_error_code`）でタグ集合を確定させるには、少なくとも公開境界の戻り値を名前付きエラーセットへ昇格させたい。あわせて以下の命名の揺れを揃える:
- `awt/src/root.zig` の `error.AwtInitFailed` が唯一の非対称（`Init` + `Failed` 二重）。他は単一動詞 + `Failed`（`DeviceCreateFailed` 等）。→ `AwtInitializeFailed` か `AwtCreateFailed` に寄せる。
- 容量超過系が 3 流派: `VertexRingFull` / `UniformBufferFull` / `GlyphTooLargeForAtlas` / `TooManyBindings`。→ `XxxOverflow` 等で統一を検討。
- `RenderTarget.zig` の `error.ReadbackFailed` はサブジェクト無冠（`RenderTargetReadbackFailed` が筋）。

### なぜ（保留理由）
公開 ABI に出るタグ名なので、決めたら固定したい＝後戻りコストが高い。C ABI の本格実装（`c_api.zig` の `errorToCode` switch）と同時に確定させた方が、タグの網羅と命名を一度に詰められて手戻りが少ない。それまでは意図的に保留。

### 候補アプローチ
- 案A: `framework/src/error.zig`（または awt 側）を新設し、タグ⇔コードの対応表を一元管理。公開境界の関数戻り値を名前付きセットへ昇格。
- 案B: 当面 inferred のまま、C ABI 化のタイミングで `errorToCode` の `else => 99` に頼る（命名揺れだけ先に直す）。
- 判断軸: ABI 安定性を早く取るなら A、C ABI 着手まで動かさないなら B。

### 決めること
名前付きエラーセットを今導入するか（A/B）。命名統一（`AwtInitFailed` / 容量系 / `ReadbackFailed`）をどう揃えるか。

### 完了条件
命名を統一し、（採用するなら）公開境界に名前付きエラーセットを導入。`c_api.zig` の `errorToCode` が網羅するタグ集合と一致する状態。

## #7 awt の Zig wrapper に対応する doc が無い
- 状態: 未着手
- 優先度: 低
- 影響範囲: `awt/doc/`（新規 doc）、対象は `awt/src/` の `Device` / `CommandBuffer` / `Swapchain` / `Window` / `Buffer` / `Pipeline` / `RootSignature` / `Shader` / `Texture` / `UniformBuffer` / `VertexRing` / `QuadIndexBuffer` / `GlyphAtlas`
- 更新日: 2026-06-07
- 依存: なし

### 何
旧 `doc/audit-2026-05-23.md` (a) から移送。awt の公開 API を持つ Zig wrapper 群に対応する `awt/doc/*.md` が無い。awt-c 側（`awt-c/doc/*.md`）はほぼ揃っているので「awt-c のラッパーで自明」という前提で省略してきたと思われるが、`Pipeline` / `Buffer` / `UniformBuffer` 等は Zig 側で `Usage` / `IndexFormat` / `BlendMode` / `StencilState` といった独自型を提供しており、awt-c の doc だけでは利用者が型を把握できない。

### なぜ（保留理由）
全 wrapper に doc を起こすのは量があり、かつ「どこまでが自明な薄ラッパーで doc 不要か」の線引き自体が作者判断。実需（利用者が awt を直接触る場面）が薄いうちは保留。

### 候補アプローチ
- 案A: Zig 側独自型を持つもの（`Pipeline` / `Buffer` / `UniformBuffer` / `Texture` 等）だけ先に doc を起こし、純粋な薄ラッパーは「awt-c の同名 doc 参照」で済ませる。
- 案B: 全 wrapper に doc を用意して網羅性を取る。
- 判断軸: point-of-need を取るなら A（独自型があるものだけ）、網羅性を取るなら B。
- 推奨: 案A。CLAUDE.md の point-of-need 方針と整合。

### 決めること
A（独自型のあるものだけ）か B（全部）か。線引きの基準。

### 完了条件
選んだ範囲で `awt/doc/*.md` を用意し、Zig 側独自型（`Usage` / `IndexFormat` / `BlendMode` / `StencilState` 等）が doc から辿れる状態。

## #8 修飾キーに super（Cmd / Win / Meta）を追加
- 状態: 完了
- 優先度: 高
- 影響範囲: awt-c の修飾ビット（`nmModifierShift` / `Ctrl` / `Alt` 系の enum に `nmModifierSuper` 追加、glfw コールバックのビット変換）、awt の `Event.Modifiers`（`src/Event.zig`：`super: bool` フィールド + `fromBits` のマッピング）、`awt/doc/event.md`
- 更新日: 2026-06-11
- 依存: なし（framework のキーストローク/ニーモニックの Mac 対応がこれに依存する側）

### 結果（2026-06-11、キーバインディング実装時の調査で判明）
起票時の前提が実態と違った: `awt.Event.Modifiers` には既に `meta: bool` があり、
`glfw_shim.c` が `GLFW_MOD_SUPER → nmModifierMeta` をマッピング済み（Cmd / Win キーは
最初から拾えていた）。新規実装は不要で、「決めること」は既存実装が答えていた —
フィールド名は `meta`、Win キーと Mac Cmd は GLFW に倣い 1 ビットに束ねる。
framework 側 `keybinding.KeyStroke.satisfies` は `command` を macOS で `meta`、
Win/Linux で `ctrl` に解決して照合する（実装済み・単体テストあり）。
残件は Mac 実機での動作検証のみ（Metal バックエンド検証時に合わせて行う）。

### 何
現状 `awt.Event.Modifiers` は `shift` / `ctrl` / `alt` の 3 つのみ。macOS のアクセラレータは Cmd（= super）を使うため、Cmd 修飾を表すビットが無いと Mac でメニューアクセラレータ／ニーモニックの照合ができない。
awt-c の修飾ビット enum に super を足し、`Event.Modifiers` に `super: bool` を追加して `fromBits` で拾えるようにする。

framework 側のキーストローク設計では抽象「コマンド修飾キー」（`KeyStroke.Mods.command`）を Win/Linux は ctrl ビット、macOS は super ビットに解決して raw modifiers と突き合わせる。その「macOS は super」の照合先がこの項目で初めて存在するようになる。CLAUDE.md「プラットフォーム」方針（Windows / Mac をまずサポート）に沿い、Mac 対応は必須。

### なぜ（保留理由）
framework のキーストローク/ニーモニック実装を進めるために awt の小改修を切り出しただけで、保留ではない（別タスク化）。Win/Linux 単独なら ctrl で動くため、Mac の実機検証と一緒に入れるのが自然。

### 決めること
- フィールド名を `super` にするか `meta` / `cmd` にするか（`super` は Zig の予約語ではないが一般語と紛れる懸念。Windows キーも同じビットに乗せるかは要確認）。
- Windows キー（左 super）と Mac Cmd を 1 ビットに束ねるか、プラットフォームで意味を分けるか。

### 完了条件
`Event.Modifiers` が super を表現でき、`event.md` と実装が一致。framework の `KeyStroke.Mods.command` が macOS で super、Win/Linux で ctrl に解決して照合できる状態。

## #9 ベクター描画プリミティブ（drawPolygon / fillPolygon）or テクスチャ方式の小アイコン
- 状態: 未着手
- 優先度: 低
- 影響範囲: awt の `Graphics`（`Graphics.zig` に描画 API 追加 / `awt/doc/graphics.md`）、採用案によっては awt-c のパイプライン / シェーダー（新 program）。consumer は framework の小アイコン手組み（`CheckBox.drawCheck` / `Table.paintSortIndicator` / `CheckBoxMenuItem.drawCheckmark`）
- 更新日: 2026-06-18
- 依存: なし

### 関連（LAF プリミティブ）
本項目は小アイコン（チェック / caret）が主眼だが、グラデ / 9-slice という別系統の awt プリミティブ追加は
`doc/internal/awt_primitives_laf.md`（LAF＝Metal / JTattoo 用）で別途設計済み。あちらも「テクスチャ経路の
ゴールデン脆化」という本項目と同じ判断軸を扱うので、テクスチャ方式を採るときは両方を見ること。

### 何
`awt.Graphics` の描画語彙は実質 `fillRect` / `drawRect` / `fillRoundRect`（SDF `sdfQuad`）/ `fillCircle` /
`drawString` / `drawImage` 等で、線・三角・任意多角形・パスを直接描くプリミティブが無い。
このため framework は小アイコンを軸並行 `fillRect` の階段で手組みしている:
- `CheckBox.drawCheck`（`framework/src/CheckBox.zig:231-253`）— 2x2 の dot を斜めに点描してチェックマークを作る
  （コメント「no line primitive in awt」）。
- `Table.paintSortIndicator`（`framework/src/Table.zig:756-768`）— 高さ 2px の横バーを幅を変えて積んで三角の caret を作る
  （コメント「no triangle primitive」）。
- `CheckBoxMenuItem.drawCheckmark` も同じ trick（`drawCheck` のコメントが参照している）。

任意のベクター形状（チェック / caret / 将来の richer iconography）を、形状ごとの手組み無しで描けるようにしたい。
利用者の要望は「`drawPolygon` 的なプリミティブが欲しい。あるいはテクスチャで済ませてもよい」。

### なぜ（保留理由）
現状の階段描画で動いており見た目も許容範囲。これは「richer iconography を可能にする＋形状ごとの手組みを無くす」
cleanup / enabler であって、機能の欠落で詰まっているわけではない（point-of-need）。
加えてゴールデン PNG スナップショットテストとの相性が判断軸に絡む（下記）ため、急いで倒さず方針を選んでから着手したい。

### 候補アプローチ
- 案A: awt に `fillPolygon` / `drawPolygon` を足す（ベクタープリミティブ）。簡易 / 凸多角形を CPU で三角形分割して
  頂点バッファに積む、または SDF 的手法で描く。任意形状を滑らかに描ける。AA 手法（頂点 AA / SDF / MSAA いずれか）は要検討。
  メリット: 形状を式で書け、HiDPI でも解像度非依存に鮮明。`drawString` の SDF 経路と思想が揃う。
  デメリット: 三角形分割＋AA の実装コスト。新しい program（シェーダー）が要る可能性。AA を入れると下記スナップショットの脆化リスク。
- 案B: テクスチャ / アトラス方式（小アイコンをラスタライズして `drawImage`）。
  **lucide アイコンが既にこの経路（`awt.Image.fromMemory` → GPU アップロード、`Application.icon(...)` でキャッシュ。
  `framework/src/lucide/icons.zig` 冒頭）を実装済みで、そのまま再利用できる**。
  メリット: 最小コスト（新プリミティブ不要、既存経路の流用）。
  デメリット: HiDPI で拡大するとスケール品質が落ちる / 各サイズ分のメモリ。ピクセル等倍以外では AA ゆらぎがスナップショットを脆くしうる。
- 案C（最安）: 新プリミティブを足さず、チェックと caret を lucide アイコンへ置換するだけ。lucide セットには
  `check` / `chevron_up` / `chevron_down`（`chevrons_up_down` も）が存在する（`framework/src/lucide/icons.zig` で確認済み）。
  メリット: awt 無改修・実装ほぼゼロ。デメリット: 任意形状の汎用解にはならない（個別アイコンの差し替えに留まる）。テクスチャ拡大時の品質 / スナップショット脆化は案B と同様。
- 判断軸: 任意ベクター形状の汎用性を取るなら A、実装コスト最小を取るなら B / C。
  ただしどの案も**ゴールデン PNG スナップショットとの相性**が効く: 現状の `fillRect` 階段は
  ピクセルスナップで決定論的＝ AA ゆらぎが無く、`snapshot_test.zig` の `TOLERANCE = 1`（1 LSB）が成立している理由そのもの。
  AA 付きポリゴン（案A）や拡大テクスチャ（案B / C）は GPU ドライバ間で AA 結果がぶれ、スナップショットを脆くしうる
  （tolerance 引き上げ or 該当 scene の許容調整が要るか要検討）。
- 推奨: 当面は積むだけ（実需が出るまで保留）。実需が「個別アイコンを綺麗にしたい」だけなら最安の案C、
  「任意形状を描く API が欲しい」なら案A。最終判断は作者。

### 決めること
- A / B / C のいずれか（ベクタープリミティブを足すか、テクスチャで済ませるか、個別アイコン置換に留めるか）。
- 案A を採るなら: `fillPolygon` / `drawPolygon` のシグネチャ（頂点列の渡し方・凸限定か凹も許すか）、AA 手法、新 program の要否。
- いずれの案でも: ゴールデン PNG スナップショットの許容（`TOLERANCE` を上げるか、該当 scene を個別に許容するか）をどうするか。

### 完了条件
選んだ方針で awt（案A）or framework（案C）or 両方（案B）を更新し、`CheckBox.drawCheck` /
`Table.paintSortIndicator` / `CheckBoxMenuItem.drawCheckmark` の手組み階段が新プリミティブ or アイコンへ移行している。
スナップショットテストが緑（許容方針を決めた上で fixtures 再生成）。案A なら `graphics.md` に新プリミティブを記載。
