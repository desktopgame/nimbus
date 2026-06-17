#!/usr/bin/env node
// ドキュメント参照腐敗チェッカー（mode1・read-only）。
// module doc（awt / awt-c / framework の doc）が挙げる API シンボルが source に実在するか検査する。
// 構造認識抽出: スタイルガイド（型定義 / 関数定義 / 利用例 / 機能要望）に乗り、利用例・機能要望節と
// prose を除外する。Zig は ```zig フェンス内の `pub fn` / `pub const`、C は ```c フェンス＋`(` を伴う
// `nm` シンボルのみ拾う。doc → source の一方向・名前一致。検出があれば exit 1（pre-commit ゲートで止める）。
// usage: node tools/docrot.mjs [repo-root]   （既定: カレントディレクトリ＝リポジトリルート）
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';

const ROOT = process.argv[2] || process.cwd();
const SKIP_DIRS = new Set(['node_modules', 'vendor', '.git', 'zig-out', '.zig-cache', 'dotgit']);

function walk(dir, filter, out = []) {
  let entries;
  try { entries = readdirSync(dir); } catch { return out; }
  for (const e of entries) {
    const p = join(dir, e);
    let st; try { st = statSync(p); } catch { continue; }
    if (st.isDirectory()) { if (!SKIP_DIRS.has(e)) walk(p, filter, out); }
    else if (filter(p)) out.push(p);
  }
  return out;
}

// --- source シンボル集合 ---
const zigDecl = /\bpub\s+(?:fn|const)\s+([A-Za-z_]\w*)/g;
const zigSyms = new Set();
for (const f of walk(ROOT, p => p.endsWith('.zig')))
  for (const m of readFileSync(f, 'utf8').matchAll(zigDecl)) zigSyms.add(m[1]);

const cSyms = new Set();
for (const root of ['awt-c', 'include'])
  for (const f of walk(join(ROOT, root), p => /\.(c|h|m)$/.test(p)))
    for (const m of readFileSync(f, 'utf8').matchAll(/\bnm[A-Z]\w*/g)) cSyms.add(m[0]);

// --- 非 spec 節（## 利用例 / ## 機能要望）を落とす ---
function stripNonSpec(md) {
  const out = []; let skip = false;
  for (const ln of md.split(/\r?\n/)) {
    if (/^##\s/.test(ln)) skip = /利用例|機能要望/.test(ln);
    if (!skip) out.push(ln);
  }
  return out.join('\n');
}

const isDoc = p =>
  /[\\/](awt|awt-c|framework)[\\/]doc[\\/]/.test(p) && p.endsWith('.md') && !/[\\/]narrative[\\/]/.test(p);

const findings = [];
for (const f of walk(ROOT, isDoc)) {
  const isC = /[\\/]awt-c[\\/]doc[\\/]/.test(f);
  const md = stripNonSpec(readFileSync(f, 'utf8'));
  if (isC) {
    // C: 型は ```c フェンス内、関数は `(` を伴う宣言/呼び出し形のみ（prose の族名参照は除外）
    const cand = new Set();
    for (const blk of md.matchAll(/```c[a-z+]*[^\n]*\n([\s\S]*?)```/g))
      for (const m of blk[1].matchAll(/\bnm[A-Z]\w*/g)) cand.add(m[0]);
    for (const m of md.matchAll(/\bnm[A-Z]\w*(?=\s*\()/g)) cand.add(m[0]);
    for (const s of cand) if (!cSyms.has(s)) findings.push([f, s]);
  } else {
    for (const blk of md.matchAll(/```zig[^\n]*\n([\s\S]*?)```/g))
      for (const m of blk[1].matchAll(zigDecl)) if (!zigSyms.has(m[1])) findings.push([f, m[1]]);
  }
}

const seen = new Set();
const uniq = findings.filter(([f, s]) => { const k = f + '|' + s; if (seen.has(k)) return false; seen.add(k); return true; });

if (uniq.length === 0) {
  console.log('docrot: ok（doc の API 参照はすべて source に実在）');
  process.exit(0);
}
console.error(`🚫 docrot: doc が参照する API シンボルが source に見つかりません（参照腐敗の疑い ${uniq.length} 件）。`);
console.error('   doc を現行 API に合わせて直すか、symbol 名を確認してください（## 利用例 / ## 機能要望 節は対象外）。');
for (const [f, s] of uniq) console.error(`   - ${relative(ROOT, f)}: ${s}`);
process.exit(1);
