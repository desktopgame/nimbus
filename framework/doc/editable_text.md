---
unsafe: true
---

# editable_text
テキスト本体・キャレット・選択・アンドゥ/リドゥ だけを持つ、テキストウィジェット共有の編集コア。
描画・クリップボード・IME・画面行モデルは持たず、`TextField` / `TextArea` がそれらを載せる土台として内包する。

## 型定義
```zig
pub const EditableText = struct {
    allocator:        std.mem.Allocator,
    buffer:           Buffer,   // 内部 gap buffer (UTF-8、'\n' 正規化済み)
    caret:            usize,    // キャレットのバイト位置 (内部)
    mark:             usize,    // 選択範囲の他端 (caret == mark なら選択なし)
    undo_stack:       UndoStack,
    merge_generation: usize,    // コアレッシングの世代 (breakCoalescing で進む)
};

pub const Selection = struct {
    start: usize,
    end:   usize,
};
```

`caret` / `mark` は UTF-8 バイトオフセットだが内部実装の詳細で、挿入・削除・キャレット移動はすべて書記素クラスタ境界で行う。
内部バッファは改行を `\n` に正規化して保持する (`\r\n` と `\r` は `\n` に畳む)。
`Buffer` は `GapBuffer` を包む非公開型で、利用者は直接触らない。

## 関数定義

### 生成 (空 / 初期文字列)
```zig
pub fn init(allocator: std.mem.Allocator) EditableText;
pub fn initFromSlice(allocator: std.mem.Allocator, bytes: []const u8) !EditableText;
```

`init` は空の編集コアを値で返す。`initFromSlice` は `bytes` を改行正規化してからバッファへコピーし、キャレットと mark を末尾に置く。
どちらもアンドゥ履歴は空で始まる。

#### 事前条件
* `bytes` が有効な UTF-8 であること。違反した場合の動作は UB。

### 破棄
```zig
pub fn deinit(self: *EditableText) void;
```

アンドゥスタックと内部バッファを解放する。以後 `self` は使用不可。

### テキストの取得
```zig
pub fn len(self: EditableText) usize;
pub fn byteAt(self: EditableText, i: usize) u8;
pub fn copyRange(self: EditableText, dst: []u8, start: usize, end: usize) void;
pub fn textSlice(self: *EditableText) []const u8;
pub fn rangeSlice(self: EditableText, start: usize, end: usize) ![]u8;
```

`len` はバイト長、`byteAt` は 1 バイト、`copyRange` は `[start, end)` を呼び出し側の `dst` へ写す。
`textSlice` は内部ギャップを末尾へ寄せてから全体の連続スライスを返す (レシーバが `*EditableText` なのは状態を変えるため)。返したスライスは次の編集操作まで有効。
`rangeSlice` は `[start, end)` を `allocator` で確保して返す (呼び出し側が解放する)。

### テキストの置き換え
```zig
pub fn setText(self: *EditableText, bytes: []const u8) !void;
```

内部バッファを改行正規化した `bytes` で置き換え、キャレットと mark を末尾へ移し、アンドゥ履歴を破棄する。

### 選択の取得
```zig
pub fn hasSelection(self: EditableText) bool;
pub fn selectionStart(self: EditableText) usize;
pub fn selectionEnd(self: EditableText) usize;
pub fn selection(self: EditableText) Selection;
pub fn selectionSlice(self: EditableText, allocator: std.mem.Allocator) ![]u8;
```

選択範囲は `[min(caret, mark), max(caret, mark))`。`hasSelection` は `caret != mark` を返す。
`selectionSlice` は選択部分を `allocator` で確保して返す (呼び出し側が解放する)。

### キャレット / 選択の設定
```zig
pub fn setCaret(self: *EditableText, pos: usize) void;
pub fn setSelection(self: *EditableText, caret: usize, mark: usize) void;
```

`setCaret` は `pos` を書記素クラスタ境界へスナップしてキャレットに設定し、mark をそろえる (選択解除)。
`setSelection` は両端をそれぞれ境界へスナップして設定する。いずれもコアレッシングを区切る。

### 書記素クラスタ境界の計算
```zig
pub fn prevBoundary(self: *EditableText, from: usize) usize;
pub fn nextBoundary(self: *EditableText, from: usize) usize;
pub fn snapToBoundary(self: *EditableText, byte_pos: usize) usize;
```

`prevBoundary` / `nextBoundary` は `from` の前後の書記素クラスタ境界を返す。`snapToBoundary` は境界上でない位置を手前の境界へ丸める。
いずれも `awt.grapheme` の UAX #29 ベースの実装に委譲する。ウィジェットのキャレット移動・ヒットテストのスナップがこれを使う。

### 低レベル編集
```zig
pub fn applyEdit(self: *EditableText, pos: usize, del_len: usize, new_bytes: []const u8) !bool;
```

`pos` から `del_len` バイトを削除し、そこへ改行正規化した `new_bytes` を挿入する 1 手。アンドゥコマンドを push する。
実際に内容が変わったら `true`、削除も挿入も無い no-op なら `false` を返す。以下の高レベル操作はすべてこれを通す。

#### 失敗時の保証
確保に失敗した場合は `error.OutOfMemory` を返し、テキスト・キャレット・アンドゥスタックは操作前のまま変わらない (all-or-nothing)。

### 挿入 / 削除 / 貼り付け
```zig
pub fn insert(self: *EditableText, bytes: []const u8) !bool;
pub fn replaceSelection(self: *EditableText, bytes: []const u8) !bool;
pub fn paste(self: *EditableText, bytes: []const u8) !bool;
pub fn cutSelection(self: *EditableText, allocator: std.mem.Allocator) !?[]u8;
pub fn deleteSelection(self: *EditableText) !bool;
pub fn deleteBackward(self: *EditableText) !bool;
pub fn deleteForward(self: *EditableText) !bool;
```

`insert` は選択があれば置換、無ければキャレット位置へ挿入する。`replaceSelection` は選択範囲を `bytes` で置き換える。
`paste` は前後でコアレッシングを区切ってから選択を `bytes` で置換する (直前・直後のタイプ入力と 1 手にまとまらない)。
`cutSelection` は選択が無ければ `null`、あれば選択文字列を `allocator` で確保して返しつつ削除する。
`deleteBackward` / `deleteForward` は選択があればそれを、無ければキャレット前後の 1 書記素クラスタを削除する。
戻り値の `bool` は「内容が変わったか」。変化があったときだけ呼び出し側で change 通知を出せばよい。

### undo / redo
```zig
pub fn undo(self: *EditableText) !bool;
pub fn redo(self: *EditableText) !bool;
pub fn canUndo(self: EditableText) bool;
pub fn canRedo(self: EditableText) bool;
pub fn breakCoalescing(self: *EditableText) void;
```

`undo` / `redo` はアンドゥスタックを 1 手戻す / 進める。戻せる / 進められる手が無ければ `false` を返す (それ以外は `true`)。
戻し / 進めのあとはコアレッシングを区切るので、以後の入力は別のアンドゥ単位になる。
`breakCoalescing` は明示的にコアレッシングの区切りを入れる。キャレット移動・選択変更・IME クリアの節目でウィジェットが呼ぶ。

### 行の位置
```zig
pub fn lineStartAtByte(self: EditableText, byte: usize) usize;
pub fn byteAtLine(self: EditableText, line: usize) usize;
```

`lineStartAtByte` は `byte` を含む論理行の先頭バイト位置を返す。`byteAtLine` は 0 始まりの `line` 番目の論理行の先頭バイト位置を返す。
論理行は `\n` で区切る (`TextArea` の画面行モデルとは別)。

---

## 利用例
最小の編集フロー (挿入 → 前方削除 → アンドゥ)。

```zig
var core = try EditableText.initFromSlice(allocator, "hello");
defer core.deinit();

core.setCaret(0);
_ = try core.insert("Say: ");   // "Say: hello"、キャレットは挿入後ろへ
_ = try core.deleteForward();    // キャレット直後の 1 書記素クラスタを削除

if (core.canUndo()) _ = try core.undo();
const text = core.textSlice();   // 次の編集操作まで有効
_ = text;
```

## 機能要望
* 単語単位の削除 / 移動 (`Ctrl+Backspace` / `Ctrl+←` 等が叩く境界計算)。
* アンドゥコマンドの合体ポリシーの調整 (現状は 1 書記素クラスタずつの連続挿入のみ 1 手にまとめる)。
