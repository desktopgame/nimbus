---
unsafe: false
---

# scroll_bar
ScrollBar のレイアウト・描画・イベント処理。

## レイアウト
* 垂直: `min_size = { width = THICKNESS, height = 0 }`、`max_size.width = THICKNESS`、高さは伸びる
* 水平: `min_size = { width = 0, height = THICKNESS }`、`max_size.height = THICKNESS`、幅は伸びる

`THICKNESS` は定数 (初版 14px 程度)。

## 描画
1. トラック (溝) を薄いグレーで塗る
2. つまみを濃いグレーで塗る (`rollover` / `dragging` で少し濃く)

つまみの長さ = `extent / (max - min) * トラック長` (下限 `MIN_THUMB`)。
つまみ位置 = `(value - min) / ((max - min) - extent) * (トラック長 - つまみ長)`。
`(max - min) <= extent` (スクロール不要) のときはつまみがトラックいっぱいになり、ドラッグ不可。

## イベント処理
| 入力 | 動作 |
|---|---|
| つまみ上で left press | ドラッグ開始 (`requestCapture`)、`drag_grab` を記録 |
| ドラッグ中 move | カーソル位置から `value` を算出して `setValue` |
| left release | ドラッグ終了 |
| トラック上 (つまみ外) で left press | クリック側へ `block_increment` (or 1 ページ) 進む |
| ホイール (`.scroll`) | `unit_increment` 分進む |
| move (ドラッグ外) | `rollover` 更新 |

ドラッグは `Slider` と同じ標準のマウスキャプチャ機構 (`ev.requestCapture`) を使う (`window.md`「マウスキャプチャ」参照)。
