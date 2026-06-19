# FileChooser v1 設計ノート

framework 新規モジュール **FileChooser**（Swing `JFileChooser` / Qt `QFileDialog` 相当）の v1 設計。
これは設計のみの正本で、実装はまだしない（ブランチ `feat/file-chooser`、以後 Codex が in-place 実装する）。
公開 API スケッチは spec `framework/doc/filechooser.md`「機能要望」に置く（未実装を spec の「型定義 / 関数定義」に書くと doc↔実装 追従監査が NG になるため、昇格は実装時。直近の scroll-headers 設計と同じ作法）。

## 確定スコープ（作者決定）

- **配置**: framework モジュール（`framework/src/FileChooser.zig`）。examples ではない。
  本命は再利用 — 後続のテキストエディター（dogfooding ロードマップ）が open / save にこの API をそのまま使う。
- **v1 = ミドル**: モーダルダイアログ + places サイドバー + ファイル種別フィルタ（ComboBox）+ list ビュー。
  土台は open / save / ディレクトリ選択の 3 モード・単一選択。
- **C-ABI はスコープ外**: 依存する Table / SplitPane / PaddingLayout / columnHeader が C 未公開なので、Zig-only 先行。
- **v1 で出さない（将来拡張として構造だけ見据える）**: details / Table ビュー、複数選択、非同期検索、新規フォルダ作成。

## なぜ framework か（app_filer との関係）

`app_filer` は卒業済みの dogfooding example で、ファイル列挙・places・セルレンダラ・sort をすべて**私有**で持つ。
FileChooser は「複数アプリ（ファイラー / エディター / 任意の利用者アプリ）が共有する部品」なので、
example の私有実装を framework が import するのは依存の向きが逆（framework → examples）になり禁じ手。

判断: **app_filer から抽出せず、framework グレードで作り直す**。
ただし `app_filer` で実証済みの設計の形（`Entry` モデル、folders-first の `sortLess`、VirtualFlow セル）は流用する。
コードのコピーではなく、**動くと分かっている形を framework の語彙で再構築**する。

## 決定 1: filesystem の扱い — 注入可能な薄い抽象 `DirSource`

### 分岐と判断

GUI framework に OS のディレクトリ列挙（`std.Io.Dir.openDirAbsolute` + `iterate`）を直に埋めるか、
Swing `FileSystemView` 的な薄い interface を挟むか。

**判断: 薄い interface `DirSource` を挟む（推奨）。** 理由は 2 つ。

1. **テスト容易性**: ナビゲーション / フィルタ / 選択 / save 名確定は純ロジックである。
   フェイク `DirSource`（インメモリのツリー）を注入すれば、GPU も実ファイルも介さずこれらを常時実行できる。
   CLAUDE.md「テスト」の規律（純ロジックは Application / GPU 非依存で常時実行）に直結する。
2. **framework 純度**: framework が `std.Io.Dir` をハードコードすると、列挙という OS 依存が抽象レイヤーの内側に固定される。
   `DirSource` を挟めば OS 依存は seam の外（既定実装）に隔離され、framework 本体は純粋なロジックになる。

`std.Io` 自体も注入点ではあるが、フェイク `std.Io` で仮想 FS を組むのは重い（vtable 全面実装）。
FileChooser が必要とする操作は「ディレクトリ列挙 / 正規化 / places 列挙」の 3 つだけなので、
その 3 メソッドに絞った framework 独自 interface の方が、フェイクが数十行で書けて軽い。

### interface 定義（内部詳細。spec には要点だけ載せる）

```zig
/// 1 ディレクトリエントリ。`DirSource.list` が `out` へ詰める。
/// name は basename（UTF-8）で、list の allocator で dup される（呼び出し側所有）。
pub const DirEntry = struct {
    name:   []const u8,
    is_dir: bool,
    size:   u64 = 0,
    mtime:  i64 = 0,   // seconds since epoch (UTC), 0 = unknown
};

/// 1 サイドバー行（Home / ドライブ / ルート）。
pub const PlaceEntry = struct {
    name: []const u8,   // 表示名
    path: []const u8,   // 絶対パス
    kind: Kind,
    pub const Kind = enum { home, root };
};

/// ディレクトリ列挙 / 正規化 / places 列挙を抽象した注入可能 interface。
/// 既定実装は std.Io を包む（`FileChooser.osDirSource`）。テストはフェイクを注入する。
pub const DirSource = struct {
    vtable:    *const VTable,
    user_data: *anyopaque,

    pub const VTable = struct {
        /// 絶対パス `path` を列挙し、各エントリを `allocator` で dup して `out` に append する。
        /// open 失敗時はエラー（現在ディレクトリは呼び出し側で保持し、status だけ更新する）。
        list: *const fn (user_data: *anyopaque, allocator: std.mem.Allocator, path: []const u8, out: *std.ArrayList(DirEntry)) anyerror!void,
        /// `path`（絶対）を正規化して `buf` に書き、その slice を返す（".." / symlink 解決、"up" 用）。
        realPath: *const fn (user_data: *anyopaque, path: []const u8, buf: []u8) anyerror![]const u8,
        /// サイドバーの places（Home + ドライブ / ルート）を `allocator` で dup して `out` に詰める。
        places: *const fn (user_data: *anyopaque, allocator: std.mem.Allocator, out: *std.ArrayList(PlaceEntry)) anyerror!void,
    };
};
```

- **places を DirSource に入れる理由**: ドライブ列挙（Windows の `A:`〜`Z:` access）は OS 依存。
  places も seam の内側に置けば、サイドバーのテストもフェイクで回せる。フィルタは純粋（拡張子一致）なので seam の外。
- **既定実装**: `FileChooser.osDirSource(io: std.Io) DirSource` が std.Io を包んだ `DirSource` を返す。
  `user_data` に io を載せる（`std.Io` は値で持てる小さい interface）。`app.fileChooser(owner)` factory はこれを内部で使う。
- **所有**: `list` / `places` が詰めた `DirEntry.name` / `PlaceEntry.{name,path}` は FileChooser が**自分の store にコピーし直して**所有する
  （`DirSource` が返した transient は列挙直後に解放）。`app_filer` の `entries` / `places` 所有と同じ形。

## 決定 2: 公開 API（JFileChooser 流）

完全な型 / 関数スケッチは `framework/doc/filechooser.md`「機能要望」。ここでは設計判断のみ。

### モードと起動

```zig
pub const Mode = enum { open, save, select_directory };

pub fn showOpenDialog(self: *FileChooser) Dialog.Result;
pub fn showSaveDialog(self: *FileChooser) Dialog.Result;
pub fn showDialog(self: *FileChooser, approve_text: []const u8) Dialog.Result;
```

`showModal` を内側で回し `Dialog.Result`（`.ok` / `.cancel` / `.none`）を返す。
戻った後もダイアログツリーは生存している（Dialog の契約）ので、`getSelectedPath()` で選択を読める。
「`null` を返す showOpen」ではなく「`Result` を返して getter で読む」を採る — Dialog の既存契約（`showModal` 後もツリー生存）に素直に乗り、
選択パスの寿命を chooser 所有として安定させられる（次節）。

### owner の与え方 — 構築時固定（v1）

`Dialog.init` は owner を構築時に要求する（中央寄せ / floating の基準）。
JFileChooser は `showOpenDialog(parent)` で show 時に owner を渡すが、nimbus Dialog はそうなっていない。

判断: **owner は `FileChooser.create` で固定**（show 時に渡さない）。
FileChooser は典型的に 1 つのメインウィンドウに属して使い回されるので、構築時固定で実害が無く、
show ごとに Dialog を作り直す複雑さを避けられる。show 時 owner 指定は将来拡張（機能要望）。

### 選択パスの所有

```zig
pub fn getSelectedPath(self: *FileChooser) ?[]const u8;       // 絶対パス。未選択 / cancel なら null
pub fn getCurrentDirectory(self: *FileChooser) []const u8;    // 現在ディレクトリ（絶対）
```

判断: **chooser 所有**（呼び出し側 dup ではない）。
返す slice は FileChooser 内部の固定バッファ（`selected[PATH_BUF]`）への借用で、
**次の show か `destroy` まで有効**。Dialog が showModal 後もツリー生存なので、これが最も自然。
呼び出し側が保持したいなら自分で dup する（List item の借用契約と同じ流儀）。

### フィルタ

```zig
pub fn addFilter(self: *FileChooser, name: []const u8, extensions: []const []const u8) !void;
```

`name`（表示名）+ `extensions`（`{"png","jpg"}` 等、空 = すべて）を内部に dup して登録。
最初に add したものを既定選択にする。フィルタ UI は下部バーの ComboBox で、
ComboBox の選択変更（ChangeListener）で list を再フィルタ + 再投影する。
拡張子一致は純ロジック（`std.ascii.endsWithIgnoreCase` 相当）で、`DirSource` には触れない。

### save モード

- 下部バーの filename TextField が有効になり、利用者がファイル名を打つ（または list で選んだ名がフィールドに入る）。
- OK 押下時に「現在ディレクトリ + filename」を選択パスとして確定。
- **上書き確認**: 確定先が既存ファイルなら、ネストした確認ダイアログ（セカンダリーループ。CLAUDE.md「イベントループ」でモーダルの入れ子は許容）を出し、
  「上書きしますか？」yes で確定 / no で chooser に戻る。v1 は yes/no のみ。
- `setSelectedFileName(name)` で filename フィールドを seed できる（"名前を付けて保存" の初期名）。

## 決定 3: 内部レイアウト

ルートは Dialog の `window.container` に `BorderLayout`。直近 ship した余白プリミティブ（`PaddingLayout` / `BoxLayout` spaced）と `ScrollPane` で「見栄えのいい」既定にする。

```
┌─ PaddingLayout(all 8) ─────────────────────────────┐
│ north : [↑up] [ path TextField (growX) ]            │  ← パスバー
│ center: SplitPane.horizontal                        │
│         ├ first : ScrollPane( places List )  180px  │  ← サイドバー
│         └ second: cardHolder                        │
│                   └ ScrollPane( files List )         │  ← メイン（v1 は list のみ）
│ south : [ filename TextField (growX) ][ filter ▼ ]  │  ← 下部バー
│         [ OK ][ Cancel ]                             │
└─────────────────────────────────────────────────────┘
```

- **sidebar / main の分割は SplitPane**（単純 BorderLayout ではない）。
  理由: 利用者がサイドバー幅を調整したくなるのが自然で、SplitPane なら `resize_weight = 0`（既定）で
  「サイドバーは固定幅・伸縮は main が受ける」が即得られる（`split_pane.md` のファイラー例そのまま）。
- **下部バー**は `BoxLayout.horizontalSpaced` で filename / filter / OK / Cancel を間隔付きに並べ、
  filename を `growX = 1` で伸ばす。OK / Cancel は右寄せ（間に filler を挟む）。
- **パスバー**も `BoxLayout.horizontalSpaced`、path field を `growX = 1`。
- **余白**は外周 `PaddingLayout(Insets.all(8))`、行間は BoxLayout の spacing で出す（空スペーサ Container を置かない）。

### details ビューの差し替え点（将来）

main を直接 ScrollPane にせず、`cardHolder`（`Container`）を 1 枚噛ませる。
v1 は list の ScrollPane 1 枚だけを子に持つが、将来 Table（columnHeader 入り ScrollPane）を 2 枚目の子として足し、
`app_filer` の `CardLayout`（アクティブな子だけ実サイズ・他は 0×0）で切り替える差し替え点にできる。
v1 では `cardHolder` に list ScrollPane を 1 枚だけ入れ、`BorderLayout.center` で充填（CardLayout はまだ使わない）。
こうしておけば details 追加が「2 枚目を add + view ボタン」で済み、レイアウト骨格を壊さない。

### セル

list のセルはアイコン（folder / file）+ 名前。`app_filer` の `FileCell` を framework 語彙で作り直した
内部セル（編集なし — FileChooser は rename しない）。`app.icon(.folder)` / `app.icon(.file)` を使う。

## 決定 4: メモリ / ライフタイム

FileChooser は Dialog と同じ **caller-owned**（Application のウィンドウツリー外）。
所有するものと解放順:

| 所有物 | 確保 | 解放 |
|---|---|---|
| `dialog: *Dialog` | `create` 時に `app.dialog(owner, ...)` | `destroy` で `dialog.destroy()` |
| `entries: ArrayList(*Entry)` + 各 Entry.name | `loadDir` ごとに DirSource 列挙からコピー | `clearEntries`（再ロード時）/ `destroy` |
| `places: ArrayList(*Place)` + name/path | `create` 時に DirSource.places からコピー | `destroy` |
| `filters: ArrayList(Filter)` + name/exts | `addFilter` ごと | `destroy` |
| `model / places_model` (ListModel) | `create` | `destroy` |
| `selected[PATH_BUF]` / `cur[PATH_BUF]` | 値（固定バッファ） | 解放不要 |

- ListModel は item を**借用**で持つ（List の契約）。よって `entries` / `places` の実体は FileChooser が ListModel より長生きさせる。
  再ロード時は「`model.clear()` → `clearEntries()` → 新エントリ append → `model.add`」の順（model を先に空にしてから実体を消す。
  さもないと List の reconcile が解放済み item を投影する。`app_filer.loadDir` と同じ順序）。
- **安全な使用手順**: `create` → `setMode` / `setCurrentDirectory` / `addFilter` → `showOpenDialog`（ブロック）→
  `getSelectedPath()` を読む → 必要なら再度 show → 最後に `destroy`。
  `getSelectedPath` の戻りは次 show / destroy まで有効なので、保持したい呼び出し側は読んだ直後に dup する。
- ウィジェットツリー（list / split / combo / buttons）は Dialog の `window.container` 配下に add されるので、
  `dialog.destroy()`（= `window.deinit`）の単一経路でまとめて解放される。**新しい teardown 経路は作らない**。

## 決定 5: テスト計画（CLAUDE.md 準拠）

### GPU 非依存・常時実行（フェイク DirSource、純ロジック）

`DirSource` を注入できるので、`FileChooser` の内部ナビゲーション関数を Application / GPU 無しで叩ける。
フェイクはインメモリのツリー（`map[path] -> []DirEntry`、places も固定）で、数十行。

- **ナビゲーション**: フェイク FS で `cd(child)` / `up()` / `selectPlace(i)` を呼び、`getCurrentDirectory()` が期待ディレクトリに移ることを確認。
- **フィルタ適用**: 拡張子フィルタを選んだ後、可視エントリ（model 投影前のフィルタ済みリスト）が拡張子で絞られることを確認。
  フォルダはフィルタに関わらず常に表示されることも（folders-first / 常時可視の規約）。
- **選択状態**: list 選択 → `getSelectedPath()` が「現在ディレクトリ + 選択名」になることを確認。
- **save 名の確定**: save モードで filename を設定 → OK 相当 → `getSelectedPath()` が確定パス。
  既存ファイル名なら overwrite 確認パスに入ること（確認ロジックを純粋に切り出して検証）。

これらは `FileChooser` のロジック部（loadDir / filter / selection / commit）を、
ウィジェット生成と分離して呼べる形にしておくと素直（`app_filer` が `Filer` のロジックを `*ForTest` で公開しているのと同じ手）。
ただしウィジェット生成には Application が要るので、純ロジックテストは「ロジック構造体を直接」叩く設計にする
（FileChooser をウィジェット層と FS ロジック層に内部分離しておくと、ロジック層だけ GPU 無しで回せる）。

### Robot スモーク（Driver.clickOn、ヘッドレス）

`Application.initHeadless` + `Robot` / `Driver` で、role + text 駆動の黒箱スモーク 1 本:
chooser を開く → places か list でディレクトリ移動 → ファイル行を選択 → `driver.clickOn(.{ .role = .button, .text = "OK" })` →
`getSelectedPath()` が正しい / `snapshotTree` が妥当。
このスモークでは実 FS ではなくフェイク DirSource を注入して決定的にする（GPU はヘッドレス RT）。

**ゴールデン PNG は使わない**（構造化スナップショット + ハンドル検証で足りる）。

### デモ

`examples/widget_filechooser`（framework 機能のデモ = `widget_*` 命名規約）に最小デモを置く:
`app.fileChooser(&frame.window)` → ボタン押下で `showOpenDialog` → 選択パスをラベルに出す。
これが Robot スモークの対象も兼ねる。`examples/readme.md` に 1 行追加（example-guide 規約）。
将来テキストエディターは同じ `showOpenDialog` / `showSaveDialog` で open / save する道筋。

## 決定 6: リスク

- **DirSource 注入境界の所有**: `list` / `places` が返す transient（name 文字列）の所有が曖昧だと leak / use-after-free になる。
  契約を「DirSource が allocator で dup → FileChooser が自分の store に再コピー → transient を即解放」に固定し、spec に明記する。
- **モーダル中の同期列挙**: v1 は**同期列挙で十分**と判断する。
  ファイル選択ダイアログの典型ディレクトリ（数十〜数百エントリ）は同期で一瞬。
  `app_filer #5`（再帰検索の非同期）とは別物で、FileChooser は再帰しない（カレントの 1 階層のみ）。
  巨大ディレクトリ（数万エントリ）で固まるのは v1 の許容トレードオフとし、非同期列挙は機能要望に倒す。
- **大ディレクトリ**: 列挙自体は List の VirtualFlow（可視ぶんだけセル実体化）で描画は O(可視)。
  ボトルネックは列挙 + sort の同期コストのみ。上記のとおり v1 は許容。
- **パスの絶対 / 相対と Windows ドライブ**:
  内部は常に絶対パスで持つ（`setCurrentDirectory` も絶対前提、相対が来たら `DirSource.realPath` で正規化）。
  Windows のドライブルート（`C:\`）では `std.fs.path.dirname` が `null` を返す → "up" は no-op（ルートより上に行かない）。
  places の root は Windows = 各ドライブ、その他 = `/`（`DirSource.places` が OS 差を吸収）。
  パス区切りは `std.fs.path.sep`（OS 依存）に委ね、結合は `std.fs.path.join`。
- **owner 構築時固定**: 複数ウィンドウから同一 chooser を共有して別 owner で出したい場合に不足する。
  v1 は単一 owner で割り切り、show 時 owner 指定を機能要望に置く。

## v1 で欲張らないもの（ミドルの線）

details / Table ビュー、複数選択、非同期 / 再帰検索、新規フォルダ作成は**すべて将来**。
レイアウトの差し替え点（cardHolder）と DirSource の seam だけ先に用意し、後から additive に差せる構造にしておく。
