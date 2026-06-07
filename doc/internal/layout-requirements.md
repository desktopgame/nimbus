# layout-requirements
nimbus のレイアウトエンジンに求めることについて。

## 必須要件
* 最小サイズ（MinimumSize）を指定できる
* 最大サイズ（MaximumSize）を指定できる
* 水平ボックス、垂直ボックスのサポート
* フィラーのサポート（ボックスの左・右・中央寄せに使える）
* [ボーダーレイアウト](https://docs.oracle.com/javase/jp/8/docs/api/java/awt/BorderLayout.html)に相当する機能のサポート

## 推奨要件（優先度高）
* 推奨サイズ（PreferredSize）を不要にする
* 可能な限りプリミティブな少数のインターフェイスから多様なレイアウトを実装できる

### 参考
以下は悪い例。私が以前TUI向けに実装したレイアウトエンジンだが、表現力が弱い。
```go
package base

// Control is graphical unit for compose a screen.
// Control can be contain another Control, but no distinction to interface by the see outer.
type Control interface {
	// MinimumSize is provide size of needs to print Control.
	MinimumSize(width int, height int) (Width int, Height int)

	// Move is move a Control to specified position.
	Move(x int, y int)

	// Layout is relayout sub controls within specified size.
	Layout(w int, h int)

	// IsFlexibleWidth is returns true if Control is flexible on horizontal.
	IsFlexibleWidth() bool

	// IsFlexibleHeight is returns true if Control is flexible on vertical.
	IsFlexibleHeight() bool
}
```

## 推奨要件（優先度中）
* レイアウトエンジンに対するヒントを与えることができる（"NORTH", "SOUTH"など）

## 推奨要件（優先度低）
* レイアウトが破綻するコードや組み合わせはコンパイルエラー、またはランタイムエラーになる
