---
unsafe: true
---

# overlay
OverlayManager の描画・イベント/dismiss・座標と所有権・用途・実装状況。

## 描画
描画順は container → menu_bar → overlays。
オーバーレイは**登録順（古 → 新）**に重ねるので、後から開いたサブメニューが手前に来る。
描画はポリシーに関係なく全エントリが対象。

## イベントと dismiss
`modal_popup` のオーバーレイが 1 つでも開いている間、入力は次のように扱われる。

* **ヒットテストは登録の逆順（新 → 古）**。最初に bounds 内へ当たったオーバーレイへ dispatch する。
* bounds の外で press → `dismissAllOverlays`（cascade した全 popup が閉じる）。外側の hover / scroll も飲み込む（モーダルな手触り）。
* ESC → 全 dismiss。
* オーバーレイ内の MenuItem が action を発火 → owner のリスナーが `dismissAllOverlays` を呼ぶ。

`passthrough` のエントリは**この一連の対象外**である。
ヒットテストでスキップされ（決して consume しない）、外クリックでの dismiss も引き起こさない。
座標が重なっていても、イベントはその下の `modal_popup` / container が受ける。
だからカーソル追従のゴーストやツールチップを、下の操作を妨げずに重ねられる。

詳細な dispatch 順は `window.md`「3 つの描画 / イベント層」を参照。

## 座標と所有権
* `root.position` はウィンドウローカルの絶対座標。`parent = null`。
* オーバーレイのルート component は **所有されない**。
  owner（Menu / PopupMenu 等）が寿命を持ち、`OverlayManager` はリストを保持するだけで `deinit` でも component を破棄しない。
  `remove` でリストから外すのは owner の責任。

## 用途
| 用途 | ポリシー | dismiss |
|---|---|---|
| ポップアップメニュー / サブメニュー | `modal_popup` | 外クリック / ESC / 項目選択 |
| コンボボックスのドロップダウン | `modal_popup` | 外クリック / ESC / 項目選択 |
| ドラッグ中のゴースト | `passthrough` | ドラッグ終了時に登録解除（dismiss 経由ではない） |
| ツールチップ（将来） | `passthrough` | 表示元が hide |

## 実装状況
* `modal_popup`: 実装済み（menu / combobox / popup menu）。
* `passthrough`: 実装済み。
  `OverlayEntry.policy` と `addPassthrough`、ヒットテスト / dismiss で `passthrough` をスキップする分岐を入れた。
  **nimbus は既定ゴーストを描かない**。
  利用者がゴーストを出したいときは、次の手順を踏む。
    * `DragSource.onDragStart` で `window.overlays.addPassthrough`。
    * `onDrag`（ウィンドウ座標）で位置更新。
    * `onDragDone` で `window.overlays.remove`。
  実例は `examples/widget_listdnd`（ラベルをゴーストにする）。
  `dnd.md`「描画 (ゴースト / 挿入先)」を参照。
