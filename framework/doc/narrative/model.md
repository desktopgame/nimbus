---
unsafe: true
---

# model
Model の役割・共有モデル・標準実装パターン・通知設計。

## Model の役割
Model は次の 3 つを担う。

1. **状態の保持** — 値そのもの（slider なら min/value/max、button なら pressed/armed/enabled 等）
2. **観測可能性** — 変更を外部から検知できる仕組み（ChangeListener 登録）
3. **共有可能性** — 複数のウィジェットが同じ Model を参照して同じ状態を共有できる

特に 3 が「setter で直接 dirty を立てる」方式と決定的に違う点。
Model があれば「左右に並んだ 2 つの Slider が同じ値を表示する」「アプリコードから `model.setValue(50)` を呼ぶと Slider が自動的に追従する」が表現できる。

## 個別 Model はウィジェット側で定義する
nimbus は汎用的な抽象 Model 型を提供しない。
各 Model は対応するウィジェットの doc で個別に定義する。

| ウィジェット | Model | 主なフィールド |
|---|---|---|
| Slider | `BoundedRangeModel` | `min, value, max, extent` |
| Button | `ButtonModel` | `pressed, armed, rollover, enabled, selected` |
| TextField（将来） | `Document` | テキストバッファ |
| Checkbox（将来） | `ButtonModel`（再利用） | `selected` フィールドを使う |

共通するのは「`ChangeListenerList` を embed する」「変更があったら `fire()` を呼ぶ」だけ。
状態の型 / 変更の意味 / setter の名前は Model 個別に決める。

TODO: ChangeListenerListが何の意図に使われるのか？（Changeでは分からない。再描画を伝える？）

## 標準的な Model の実装パターン
新規 Model を作るときの標準パターンは以下。

* 状態フィールドを直接フィールドとして持つ
* `change_listeners: ChangeListenerList` を embed する
* setter は「値変更 → 実際に変化したら `change_listeners.fire()` を呼ぶ」の順
* `addChangeListener` / `removeChangeListener` は `change_listeners` への薄いラッパ

setter の中で「変化しなかったら発火しない」が重要(無駄な再描画を防ぐ)。
`if (new_value == self.value) return;` の早期 return を入れる。

## ウィジェットとの連携（install / uninstall で配線する）
ウィジェット本体は Model を**参照するだけ**でリスナー登録のコードは持たない。
リスナーの登録は `Component.vtable.install` で行い、`uninstall` で外す。

これにより：

* **vtable 差し替え（ルックアンドフィール）が安全**: 旧 vtable の `uninstall` がリスナーを外し、新 vtable の `install` が必要なリスナーを付け直す
* **リスナーの寿命が vtable の寿命と一致**: Model にゴーストリスナーが残らない

これは Swing の `ComponentUI.installUI` / `uninstallUI` が `BoundedRangeModel.addChangeListener` を行うパターンと同じ。

## Model の所有モデル
ウィジェットは Model を内部生成して所有することも、外部から受け取って借用することもできる。
両方の入口を提供する。

| 入口 | Model の出所 | 所有者 |
|---|---|---|
| `Widget.create(allocator)` | ウィジェットが内部生成 | ウィジェット |
| `Widget.createWithModel(allocator, *Model)` | 利用者が事前に作って渡す | 利用者 |

ウィジェットの `destroy` は所有フラグを見て、自分が生成した場合のみ Model を解放する。
借用の場合は触らない。

```zig
pub const Slider = struct {
    component:   Component,
    model:       *BoundedRangeModel,
    owns_model:  bool,
    // ...
};
```

## 通知のタイミング
`fire()` は **同期実行**。
setter のスタックの中でリスナーが呼ばれて、setter が return する時点ですべてのリスナーの実行が完了している。

非同期にしたい場合はリスナー側で `EventQueue.invokeLater` を使う。
Model 自体は同期発火の単純な仕様に留める。

## ChangeEvent と ActionEvent（専用イベント型）
リスナーは `*const Event` を受け取る。`Event` は意味別に 2 つの型に分かれている。

* `ChangeEvent` — 状態が変わった（Swing の `ChangeEvent` 相当）
* `ActionEvent` — 確定的なアクション（クリック、submit / cancel。Swing の `ActionEvent` 相当）

両者は同一レイアウト（`source` だけ）だが**別の型**であり、ハンドラのシグネチャがどちらを
受け取るかを表す。当初は `kind` タグ付きの単一 `Event` で兼ねていたが（「いまはこれでよい」と
した暫定形）、型で区別する本来の形に分割した。共通プリミティブ `ListenerList(E)` を
イベント型 `E` でジェネリック化し、`ChangeListenerList = ListenerList(ChangeEvent)` /
`ActionListenerList = ListenerList(ActionEvent)` として具体化している。

イベントが運ぶのは `source`（発火した Model）だけ。「何が変わったか」を伝える必要があれば、
リスナーは source（または user_data）経由で Model のポインタを受け取り、Model の現在値を直接読む。
Swing は変更内容を `DocumentEvent.getOffset()` のように伝えるが、nimbus はシンプルにする。
「変わった、現在値はこれ」だけを観測する。

将来「何が変わったか」を細かく区別したい Model（Document の挿入 / 削除など）が出てきたら、その Model に専用のリスナー型を追加する（`DocumentListener` 等）。
その型も `ListenerList(E)` を別のイベント型で具体化すれば踏襲できる。
