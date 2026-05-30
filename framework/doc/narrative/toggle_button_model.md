---
unsafe: true
---

# toggle_button_model
button フィールドへの直接アクセス方針。

## button フィールドへの直接アクセス
press / armed / rollover / enabled の操作 / 取得には、 ラッパーを介さず `model.button.setPressed(...)` / `model.button.isEnabled()` のように **直接アクセス**する。
Zig の慣用 (`component.md`「派生型から Component メソッドへのアクセス」と同じ方針) で、 委譲メソッドを生やさないことでボイラープレートを避ける。

```zig
// widget 側の処理イメージ
const btn = &cb.model.button;
if (!btn.enabled) return;
btn.setPressed(true);
btn.setArmed(true);
// ... toggle 反転は ToggleButtonModel API で
cb.model.setSelected(!cb.model.isSelected());
cb.model.fireAction();
```
