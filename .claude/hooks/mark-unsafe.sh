#!/usr/bin/env bash
# Mark a doc file's frontmatter as `unsafe: true`.
# Idempotent: a file already at `unsafe: true` is left untouched.
#
# Cases:
#   - no frontmatter:                          prepend `---\nunsafe: true\n---\n`
#   - frontmatter without `unsafe:` key:       insert `unsafe: true` at top of frontmatter
#   - frontmatter with `unsafe: false` (etc):  replace with `unsafe: true`
#   - frontmatter with `unsafe: true`:         no-op
#
# Handles CRLF input; output is LF.

set -euo pipefail

file="${1:-}"
if [[ -z "$file" ]]; then
    echo "usage: mark-unsafe.sh <file>" >&2
    exit 1
fi
if [[ ! -f "$file" ]]; then
    # Silently skip non-files (deleted, directory, etc.). Hooks fire broadly.
    exit 0
fi

first=$(head -n1 "$file" | tr -d '\r')

if [[ "$first" != "---" ]]; then
    # No frontmatter — prepend a fresh one.
    tmp=$(mktemp)
    printf -- '---\nunsafe: true\n---\n\n' > "$tmp"
    cat "$file" >> "$tmp"
    mv "$tmp" "$file"
    exit 0
fi

# Frontmatter is present. Find the closing `---`.
end=$(awk 'NR > 1 { sub(/\r$/, ""); if ($0 == "---") { print NR; exit } }' "$file")
if [[ -z "$end" ]]; then
    echo "mark-unsafe: malformed frontmatter in $file (no closing ---)" >&2
    exit 1
fi

# Existing `unsafe:` value within the frontmatter (lines 2 .. end-1).
existing=$(awk -v end="$end" '
    NR > 1 && NR < end {
        sub(/\r$/, "")
        if (match($0, /^unsafe:[[:space:]]*/)) {
            v = substr($0, RLENGTH + 1)
            sub(/[[:space:]]+$/, "", v)
            print v
            exit
        }
    }' "$file")

if [[ "$existing" == "true" ]]; then
    exit 0
fi

tmp=$(mktemp)
if [[ -n "$existing" ]]; then
    # Replace the existing `unsafe:` line (within frontmatter only).
    awk -v end="$end" '
        NR < end && /^unsafe:[[:space:]]*/ { print "unsafe: true"; next }
        { sub(/\r$/, ""); print }
    ' "$file" > "$tmp"
else
    # No `unsafe:` key — insert it right after the opening `---`.
    awk '
        NR == 1 { print; print "unsafe: true"; next }
        { sub(/\r$/, ""); print }
    ' "$file" > "$tmp"
fi
mv "$tmp" "$file"
