---
unsafe: true
---

# filechooser
v1 は実装済み。下記の公開 API ブロックは機能要望ではなく、実装済みの型定義 / 関数定義である。
詳細設計（DirSource、レイアウト、所有 / 寿命、テスト、リスク）は `{REPO_ROOT}/doc/internal/file_chooser_design.md` を参照。

ファイルを開く / 保存する / ディレクトリを選ぶためのモーダルダイアログ。
Swing の `JFileChooser`、Qt の `QFileDialog` 相当。places サイドバー + ファイル種別フィルタ + list ビューを持つ。

v1 はまだ未実装の設計段階である。
詳細設計（filesystem 注入境界 `DirSource`、レイアウト、所有 / 寿命、テスト計画、リスク）は
`{REPO_ROOT}/doc/internal/file_chooser_design.md` を参照。
下の公開 API スケッチは実装時に「型定義 / 関数定義」へ昇格する。それまでは未実装なので
doc↔実装 追従監査を避けるため「機能要望」に置く（scroll-headers 設計と同じ作法）。

## 機能要望

### v1 公開 API（実装時に昇格）

JFileChooser 流の caller-owned なダイアログ。`Dialog` と同じく Application のウィンドウツリー外に生き、
複数回の show で使い回せる。owner は構築時に固定する。

```zig
pub const FileChooser = struct {
    // 内部に Dialog（owner 固定）/ places List / files List / filter ComboBox /
    // filename TextField / OK・Cancel Button を抱える。詳細は内部設計ノート。
    // ... フィールドとメソッド
};

/// 起動モード。open / save / ディレクトリ選択の 3 つ。v1 は単一選択。
pub const Mode = enum { open, save, select_directory };

/// ファイル種別フィルタ。name は表示名、extensions は対象拡張子（空 = すべて）。
pub const Filter = struct {
    name:       []const u8,           // 例 "Images"
    extensions: []const []const u8,   // 例 .{ "png", "jpg" }。空 = フィルタしない
};

/// 1 ディレクトリエントリ。`DirSource.list` が詰める。
pub const DirEntry = struct {
    name:   []const u8,   // basename（UTF-8）
    is_dir: bool,
    size:   u64 = 0,
    mtime:  i64 = 0,      // seconds since epoch (UTC)、0 = 不明
};

/// 1 サイドバー行（Home / ドライブ / ルート）。
pub const PlaceEntry = struct {
    name: []const u8,
    path: []const u8,     // 絶対パス
    kind: enum { home, root },
};

/// ディレクトリ列挙 / 正規化 / places 列挙を抽象した注入可能 interface。
/// 既定は OS（std.Io）を包む。テストはインメモリのフェイクを注入して GPU / 実 FS 非依存で純ロジックを回す。
pub const DirSource = struct {
    vtable:    *const VTable,
    user_data: *anyopaque,

    pub const VTable = struct {
        list:     *const fn (user_data: *anyopaque, allocator: std.mem.Allocator, path: []const u8, out: *std.ArrayList(DirEntry)) anyerror!void,
        realPath: *const fn (user_data: *anyopaque, path: []const u8, buf: []u8) anyerror![]const u8,
        places:   *const fn (user_data: *anyopaque, allocator: std.mem.Allocator, out: *std.ArrayList(PlaceEntry)) anyerror!void,
    };
};
```

#### 生成 / 破棄（caller-owned）

```zig
/// owner と dir_source を固定して FileChooser をヒープに確保する。
/// 内部で Dialog（owner 基準で中央寄せ / floating）と全ウィジェットを組む。
pub fn create(
    allocator:  std.mem.Allocator,
    app:        *Application,
    owner:      *Window,
    dir_source: DirSource,
) !*FileChooser;

/// 内部リソース解放 + ヒープ解放を 1 回で行う（Dialog.destroy と同じ流儀）。
pub fn destroy(self: *FileChooser) void;

/// OS（std.Io）を包む既定 DirSource。`app.fileChooser` が内部で使う。
pub fn osDirSource(io: std.Io) DirSource;
```

```zig
/// Application ファクトリ。既定の OS DirSource で FileChooser を作る。
pub fn fileChooser(self: *Application, owner: *Window) !*FileChooser;
```

#### 設定

```zig
pub fn setMode             (self: *FileChooser, mode: Mode) void;
pub fn setCurrentDirectory (self: *FileChooser, path: []const u8) void;          // 絶対パス。内部コピー
pub fn addFilter           (self: *FileChooser, name: []const u8, extensions: []const []const u8) !void; // 内部コピー。最初の add が既定
pub fn setSelectedFileName (self: *FileChooser, name: []const u8) void;          // save の filename フィールドを seed
```

#### 起動（モーダル）

```zig
pub fn showOpenDialog(self: *FileChooser) Dialog.Result;
pub fn showSaveDialog(self: *FileChooser) Dialog.Result;
pub fn showDialog    (self: *FileChooser, approve_text: []const u8) Dialog.Result;
```

内部で `showModal` を回して閉じるまでブロックし、`Dialog.Result`（`.ok` / `.cancel` / `.none`）を返す。
戻った後もダイアログツリーは生存しており、選択は次の getter で読める。
save モードで確定先が既存ファイルなら、ネストした上書き確認ダイアログを挟む。

#### 結果の取得

```zig
pub fn getSelectedPath     (self: *FileChooser) ?[]const u8;   // 絶対パス。未選択 / cancel なら null
pub fn getCurrentDirectory (self: *FileChooser) []const u8;    // 現在ディレクトリ（絶対）
```

返す slice は FileChooser 内部バッファへの**借用で、次の show か `destroy` まで有効**（chooser 所有）。
保持したい呼び出し側は読んだ直後に dup する。

#### 利用例（実装後の姿）

```zig
const chooser = try app.fileChooser(&frame.window);
defer chooser.destroy();

try chooser.addFilter("Images", &.{ "png", "jpg", "gif" });
try chooser.addFilter("All Files", &.{});
chooser.setCurrentDirectory(home);

if (chooser.showOpenDialog() == .ok) {
    if (chooser.getSelectedPath()) |path| {
        // path は次の show / destroy まで有効。保持するなら dup する。
        openFile(path);
    }
}
```

### v1 で出さないもの（将来 additive）

* details / Table ビュー（columnHeader 入り。レイアウトに差し替え点 `cardHolder` だけ先に用意する）
* 複数選択
* 非同期 / 再帰列挙（v1 は同期・カレント 1 階層のみ）
* 新規フォルダ作成
* show 時の owner 指定（v1 は構築時固定）
* `setSelectedFile`（パスで初期選択行を指定）/ 直近ディレクトリ履歴
