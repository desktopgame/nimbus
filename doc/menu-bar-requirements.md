# menu-bar-requirements
nimbus のメニューバーに求めることについて。

## 必須要件
* ウィンドウのクライアント領域に自前でメニューを描画する。
* メニューの中には**典型的には**決まったコンポーネントしか入らないことを想定していい、が、任意のコンポーネントも入れられる。（それをしたい利用者が多少のハックすることになってもいい）
	* ハックの参考例：[JMenuItemの内部にJButtonを配置する](https://ateraimemo.com/Swing/ButtonsInMenuItem.html)
* MenuBar, Menu, MenuItem, MenuSeparator, CheckBoxMenuItem, PopupMenu を最低限サポートする。
	* Menu のネスト（サブメニュー）は必須。任意の深さで Menu の中に Menu を入れられる。
	* PopupMenu には MenuItem / MenuSeparator / CheckBoxMenuItem / Menu をそのまま入れられる。`PopupMenuItem` のような専用の派生型は作らない。
* MenuItem の左側にアイコンを置けるようにする。アイコン領域は MenuItem / CheckBoxMenuItem / サブメニューを示す Menu に共通の幅で確保し、アイコンを持たない項目とも縦に揃う。
* メニューバーは特別なAPIを通じてセットする前提（Window.setMenuBarのような形式）
	* ウィンドウは自身の子コンポーネントとは別にメニューのための領域を割り当てる
		* Window.menu_bar としてオプショナルに保持する。
		* 所有する。
	* 少なくともコンテナーに `.add` されることは想定しなくていい
* メニューバーはクリックで要素を展開、メニューはホバーで要素を展開
* エスケープキーで展開を閉じる。またはほかのところをクリックしても閉じる
	* メニューバー上の別メニューにマウスが移動した時も、開いているメニューを閉じて新しい方を開く
	* dismiss を伴う外クリックは、そのクリックを下層コンポーネントに**届けない**（dismiss のみ行う）

## 描画と当たり判定
* メニューは Window のオーバーレイ層に描画される。通常のコンポーネント（Container の children）の上に重なって描かれ、ヒットテストでも先にイベントを取る。
* v1 ではメニュー矩形をクライアント領域内に収まるよう reposition / clip する。
* v2 以降は、はみ出すケースに対して borderless / undecorated な別ウィンドウ（popup window）を生成して描画する方向で拡張する。GLFW のフラグ（`GLFW_DECORATED` / `GLFW_FOCUS_ON_SHOW` / `GLFW_FLOATING`）でほぼまかなえる前提。Windows / Mac のタスクバー除外などは native handle 経由で追加調整。
* `Menu.show(anchor)` 等の利用者向け API は、内部 backend（in-window / popup-window）を意識せず使えるように設計する。

## モーダル性
* メニュー展開中は下層コンポーネントはマウス / キー入力を受け取らない。
* メニュー側のハンドラが消費するか、外クリック → dismiss の経路で吸収される。

## 機能要望（v1 では対応しない）
* ニーモニック（`Alt+F` で File メニューを開く）/ アクセラレータ（`Ctrl+S` で Save を実行）
	* 機能としては必要だが v1 のスコープ外。

## 未決事項
以下は v1 でサポートするか機能要望に回すか未定。
* RadioButtonMenuItem（CheckBoxMenuItem は最低限に入っているが Radio は？）