---
unsafe: true
---

# popup_window
PopupWindow の立ち位置 (内部基盤・実利用者)、オーバーレイではなく OS 子ウィンドウを使う理由、配置アルゴリズム、自動消去の配線、値と ヒープの 2 つの寿命。

## 誰が使うか
`PopupWindow` は利用者が直接組み立てるウィジェットではなく、ポップアップ表示を必要とする内部ウィジェットの土台である。
現状の実利用者は `ComboBox` (ドロップダウン) と `Menu` (メニュー本体・サブメニュー) の 2 つである。
どちらも `Application.popupWindow` / `popupWindowWithOptions` 経由で取得する。
`PopupMenu` はまだこの実体ウィンドウ方式ではなく、従来のオーバーレイ (`overlay.md`) で描いている。移行は後続スライスに残している。

このモジュールは意図的に「プリミティブのぶんだけ」に絞ってある。
実体ウィンドウの登録・消去・位置決めと、ウィンドウを開かずに位置を試せる純関数の座標計算までを提供し、どのウィジェットがどう使うかには踏み込まない。

## なぜオーバーレイでなく OS 子ウィンドウか
親ウィンドウの内側にオーバーレイとして描く方式は、ポップアップが親の矩形をはみ出せない。
`ComboBox` を親の下端近くに置くとドロップダウンが親の外に出られず、途中で切れてしまう。
`PopupWindow` は枠なし・タスクバー非表示のトップレベルウィンドウを別に開くことで、親の矩形やモニターの端に縛られずに表示できる。
その代わりスクリーン座標・content scale (DPI)・作業領域を意識した位置決めが要る。そこを `decidePopupRect` などの純関数に閉じ込めた。

## 配置アルゴリズム
`decidePopupRect` はアンカー矩形・ポップアップサイズ・作業領域を受け取り、次の順で最終矩形を決める。

1. アンカーの真下に置いて作業領域に収まるなら、その下。
2. 収まらなければアンカーの上へフリップする。
3. 上も無理なら、作業領域の中へ縦位置をクランプする。

横位置も作業領域の左右に収まるようクランプする。
`showAtLocal` は `owner` ローカルのアンカーを content scale でスクリーン座標へ変換してからこの計算に渡す (`ownerLocalPopupRect`)。
これらを純関数にしたので、ウィンドウを開かずに「この画面配置ならどこに出るか」をテストできる。

## 自動消去の配線
ポップアップは明示的に閉じるだけでなく、フォーカスを失ったときと Escape を押したときにも自動で閉じる必要がある。
`showAtScreen` の中で focus-lost フック (`Window.onFocusLost`) と Escape のキーバインドを仕掛ける。
どちらも内部の `dismissFromFocusLoss` / `dismissFromEscape` へ繋ぐ。
`dismissFromSelection` / `dismissFromFocusLoss` / `dismissFromEscape` は実体としては同じ `dismiss` だが、呼び出し文脈が読めるよう別名にしてある。
`onDismiss` で登録したコールバックは、どの経路で閉じても `dismiss` の中で 1 度呼ばれる。
`ComboBox` / `Menu` はこれで「閉じたら選択状態を戻す」といった後処理を繋ぐ。

## 値とヒープの 2 つの寿命
`init` / `initWithOptions` は `PopupWindow` を値で返す。`Application.popupWindow` ファクトリはこれをヒープに確保して `*PopupWindow` を返す。
そのため破棄も 2 系統ある。値で持っているなら `deinit`、ファクトリが返したヒープインスタンスなら `destroy` (`deinit` + `allocator.destroy`) を使う。
表示中に破棄しても、`deinit` が先に `dismiss` を呼んで登録を外すので、閉じ忘れた未所有ウィンドウが `Application` に残らない。
