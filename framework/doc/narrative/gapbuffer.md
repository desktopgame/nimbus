---
unsafe: false
---

# gapbuffer
GapBuffer の設計メモ。

## 設計メモ
* 連続編集の局所性が利点。1 文字ずつの挿入のような操作では、ギャップが編集位置にある限り memmove が発生しない。`MIN_GAP` ぶんの余裕を確保するので、連続挿入のたびに realloc されることもない。
* `byteAt` / `copyRange` は論理座標を物理座標に変換してアクセスする。ギャップの存在は隠蔽される。
* 連続したスライスを取り出したいとき (例: `TextArea.getText`) は `moveGap(len())` でギャップを末尾に寄せてから `buf[0..len()]` を読む。
