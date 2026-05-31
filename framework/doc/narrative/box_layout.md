---
unsafe: false
---

# box_layout
BoxLayout の主軸/交差軸の処理・分配アルゴリズム・シングルトン採用の理由。

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
BoxLayout はインスタンス固有の状態を持たない（orientation の 2 種類があるだけ）。
したがって horizontal / vertical の 2 つだけプロセス全体で共有すれば足りる。
利用者が allocator で確保する手間と、いつ deinit するかを考える手間が省ける。

内部実装は `pub var` の static インスタンスを 2 つ用意し、`horizontal()` / `vertical()` がそのアドレスを返す。
LayoutManager の vtable は `deinit = null`（解放不要）。
