---
unsafe: true
---

# combobox
ComboBox のレイアウト・描画・イベント処理・寿命管理。

## レイアウト
* 横方向: `(item label の最大幅) + PADDING_X * 2 + CHEVRON_W (16)`
* 縦方向: `line_height + PADDING_Y * 2`
* `grow_x = 0` (固定幅、 利用者が `setGrowX(1)` で拡張可)

## 描画
**閉じている状態**:
1. 背景塗り (enabled = false なら灰)
2. 枠 (focus 時青、 通常灰)
3. selected の item の文字 (左寄せ、 中央上下揃え)
4. 右側に下向き chevron (▼) を 1px 縞の三角形で描画

**popup (overlay)**:
1. 白背景
2. 各 item を縦に並べる (行高 = `line_height + ITEM_PADDING_Y * 2`)
3. hover している行は背景を青、 テキストを白に
4. 外周に 1px 枠

popup のサイズ:
* 幅: ComboBox 本体と同じ
* 高さ: `items.len * item_height`
* 位置: ComboBox 本体の下端

## イベント処理
### 閉じている状態 (本体に対する操作)
| 入力 | 動作 |
|---|---|
| マウス left press (内側) | フォーカス取得 + popup open (or 既に open なら close) |
| ↓ キー | `selected_index + 1` (リスト末尾でクランプ)、 ChangeListener 発火 |
| ↑ キー | `selected_index - 1` (0 でクランプ) |
| Enter / Space | popup open (or 既に open なら close) |
| Escape | open なら close |

### popup が open している状態
| 入力 | 動作 |
|---|---|
| マウス move (popup 内) | `hovered_index` 更新 + repaint |
| マウス left press (popup 内、 item 上) | その index を確定 (`setSelectedIndex`) + close |
| マウス left press (popup 外) | Window が `dismissAllOverlays` を呼ぶ → close (選択変更なし) |
| Escape | close (選択変更なし) |
| ↓ / ↑ | `hovered_index` 移動 |
| Enter / Space | `hovered_index` を確定 + close |

popup は Menu / PopupMenu と同じ Window overlay 機構の上に乗っており、 cascade 等の管理は Window 側に任せている。

## 寿命
ComboBox は `popup_root` を自身の中に embed しており、 open 時のみ Window の overlays リストにポインタが入る。
`uninstall` / `destroy` 時に open 中なら自動で `hide()` (= `Window.removeOverlay`) を呼ぶので、 利用者が手動で close する必要はない。

`popup_root` はどの Container にも属さない独立 Component なので、 ツリー側からは deinit されない。
`Window.addOverlay` は初回 open 時に `popup_root` のプロパティマップ (DirtyNotify / FocusController) を遅延確保する。
そのため `destroy` では本体 Component に加えて `popup_root` も明示的に deinit し、 このマップを解放する。

各 item の文字列は `items` (ArrayList of dup) として所有しており、 `destroy` で全部 free。
