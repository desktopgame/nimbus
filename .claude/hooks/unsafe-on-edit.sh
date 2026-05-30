#!/usr/bin/env bash
# PostToolUse wrapper:
#   on Edit/Write of a project doc markdown file (spec or narrative),
#   mark its frontmatter as `unsafe: true` via mark-unsafe.sh.
#
# Claude Code passes PostToolUse payload as JSON on stdin; this script
# extracts tool_input.file_path, filters to doc files, and delegates.

set -euo pipefail

file=$(python -c "import json,sys
d = json.load(sys.stdin)
print((d.get('tool_input') or {}).get('file_path') or '')
" 2>/dev/null || true)

[[ -z "$file" ]] && exit 0

# Normalize backslashes (Windows) for path matching.
file_norm=$(echo "$file" | tr '\\' '/')

# Only project doc markdown files (spec + narrative).
case "$file_norm" in
    */awt/doc/*.md|*/awt-c/doc/*.md|*/framework/doc/*.md) ;;
    *) exit 0 ;;
esac

exec "$(dirname "$0")/mark-unsafe.sh" "$file"
