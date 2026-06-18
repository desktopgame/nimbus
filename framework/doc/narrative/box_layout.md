---
unsafe: true
---

# box_layout
BoxLayout の主軸/交差軸の処理・分配アルゴリズム・シングルトン採用の理由・spacing の置き場所。

## 主軸と交差軸
ボックスレイアウトでは「主軸（main axis）」と「交差軸（cross axis）」の 2 つの軸を区別する。
方向ごとの対応関係：

| Orientation | 主軸 | 交差軸 |
|---|---|---|
| `.horizontal` | x | y |
| `.vertical` | y | x |

子の bounds は両軸独立に決まる。
主軸は分配アルゴリズム、交差軸はストレッチ。

## 主軸の分配アルゴリズム
1. すべての子の主軸 `min_size` を合計する
2. コンテナーの主軸サイズから合計 min を引く（= 余白）
3. 余白を `grow_x` / `grow_y`（主軸側）の重みに従って一括配分する
4. 配分結果が主軸 `max_size` を超える子はそこでクランプする
5. クランプで生じた余りは隙間としてコンテナー末尾に残す

CSS flexbox の「再分配ループ」は採用しない。
利用者が余白を確実に埋めたい場合は **Filler**（`filler.md` 参照）を末尾に置く。

## 交差軸の処理
各子の交差軸サイズと位置は、子の `align_x` / `align_y`（コンテナの主軸に応じて参照する軸が決まる）で決まる。

| Orientation | 参照する align | 意味 |
|---|---|---|
| `.horizontal` | `align_y` | 子の垂直方向の配置 |
| `.vertical` | `align_x` | 子の水平方向の配置 |

`Alignment` の値ごとの挙動：

| 値 | 交差軸サイズ | 交差軸位置 |
|---|---|---|
| `.stretch`（デフォルト） | コンテナの交差サイズ（min / max でクランプ） | 0（左端 / 上端） |
| `.start` | `min` | 0 |
| `.center` | `min` | `(container_cross - child_min) / 2` |
| `.end` | `min` | `container_cross - child_min` |

子の cross max が無限（典型）なら `.stretch` でコンテナ交差サイズに広がる。
固定値（例: 高さ 32 のボタン）なら `.stretch` でも max でクランプされる。
`.start` / `.center` / `.end` は常に `min` サイズで配置される。

利用者はウィジェットの作成後 `widget.component.setAlignY(.center)` のように指定する。

## computeMinSize の計算
| 軸 | 計算 |
|---|---|
| 主軸 | 子の主軸 `min_size` の総和 |
| 交差軸 | 子の交差軸 `min_size` の最大値 |

子が 0 個なら `(0, 0)`。
これに Container 自身の `component.min_size` との max を取った値が最終的な `Container.getMinSize()` の戻り値になる（`container.md` 参照）。

## computeMaxSize の計算
| 軸 | 計算 |
|---|---|
| 主軸 | 子の主軸 `max_size` の総和（無限が混ざれば結果も無限） |
| 交差軸 | 子の交差軸 `max_size` の最大値 |

無限値の加算は `std.math.inf(f32)` で吸収される（無限 + 何か = 無限）。

## hint は使わない
BoxLayout は `LayoutElement.hint` を無視する。
すべての分配ロジックは Component の `min_size` / `max_size` / `grow_x` / `grow_y` から導出される。
利用者は `container.add(child)` を使えばよく、`addWithHint` は不要。

## シングルトンとして提供する理由
BoxLayout は `spacing = 0` ならインスタンス固有の状態を持たない（orientation の 2 種類があるだけ）。
したがって隙間なしの horizontal / vertical の 2 つだけプロセス全体で共有すれば足りる。
利用者が `allocator` で確保する手間と、いつ `deinit` するかを考える手間が省ける。

内部実装は `pub var` の static インスタンスを 2 つ用意し、`horizontal()` / `vertical()` がそのアドレスを返す。
両シングルトンは `spacing = 0` で、`base.vtable` は `singleton_vtable`（`deinit = null`）を指す（解放不要。後述「なぜ vtable を 2 つに分けるのか」）。

## spacing をどこに置くか（決定）
子間ギャップ `spacing` は LayoutManager（BoxLayout）のプロパティにした。
candidate は 3 つあった。

* 案 1（Container 持ち）: `Container` に `spacing` フィールドを足す。却下。spacing はボックス分配アルゴリズムの一部であって、
  `BorderLayout` など他のレイアウトには意味を持たない。レイアウト非依存の場所に置くと使われないフィールドが増える。
* 案 2（常に per-instance）: `BoxLayout` を必ず確保にする。却下。既存の `horizontal()` / `vertical()` 呼び出し全箇所が確保を伴うようになり、
  隙間ゼロの一般ケースにまで `allocator` と解放を持ち込む。
* 案 3（採用）: `spacing` を `BoxLayout` のフィールドにし、`spacing = 0` は従来どおり const シングルトンで提供、
  `spacing > 0` のときだけ `horizontalSpaced` / `verticalSpaced` でインスタンスを確保する。

採用案なら既存の `horizontal()` / `vertical()` 呼び出しは一切変わらず、確保も発生しない。
spacing が実際に要るときだけ確保し、その寿命は差し先の `Container` が `deinit` フック経由で肩代わりする
（`layout.md`「LayoutManager の所有」と一致）。
spec の型定義で `spacing: f32 = 0` を `BoxLayout` に足し、シングルトンはこのデフォルトに乗る。

## なぜ vtable を 2 つに分けるのか
`layout.md` の所有規約は「`deinit` 非 null なら Container が解放する／const シングルトンは `deinit = null`」という、
`deinit` の有無だけを discriminator にした判定で成り立っている。
ところが BoxLayout はシングルトンと spaced 変種で同じ構造体・同じ doLayout を共有する。
vtable を 1 つ（`deinit` 非 null）にまとめると、その vtable を指す const シングルトンを Container が解放しようとする。
結果として const グローバルへの invalid-free を招く（spec の自己矛盾）。

そこで doLayout / computeMinSize / computeMaxSize は共通のまま、vtable だけを 2 つに割る。

* `singleton_vtable`（`deinit = null`）: `horizontal()` / `vertical()` のシングルトンが指す。Container は解放しない。
* `spaced_vtable`（`deinit` 非 null）: `horizontalSpaced` / `verticalSpaced` の確保インスタンスが指す。Container が解放する。

これで所有の discriminator が BoxLayout でも正しく機能する。
常に確保される `PaddingLayout` は単一 vtable（`deinit` 非 null）のままで矛盾しない（シングルトン経路を持たないため）。

## spacing を入れた分配の調整
`spacing` は分配前に主軸から取り除く固定費として扱う。

* `doLayout`: 分配可能量（distributable）から `spacing * (n - 1)` を先に引いてから grow 配分する。
  各子を配置したあと、次の子へ進む `pos` を子サイズに加えて `spacing` ぶんさらに進める。
* `computeMinSize` / `computeMaxSize`: 主軸の総和に `spacing * (n - 1)` を加える（`n` は子の個数、`n <= 1` なら加算 0）。

交差軸の処理は spacing の影響を受けない。

## テスト方針
`Application` / GPU 非依存の純ロジックテスト。

* `n` 個の子を入れた水平／垂直ボックスで、主軸 `computeMinSize` が `Σ child_min + spacing * (n - 1)` になることを確認する。
* `doLayout` 後、隣り合う子の主軸方向の間隔がちょうど `spacing` であることを確認する。
* `spacing = 0` の既存シングルトンが従来どおりの配置（隙間なし）を返す回帰を確認する。
