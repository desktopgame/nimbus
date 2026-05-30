"""PostToolUse hook: mark edited doc markdown files as `unsafe: true`.

Reads PostToolUse JSON from stdin, filters to project doc markdown files
(spec or narrative), and updates the file's frontmatter.

Idempotent. Cases:
  - no frontmatter:                          prepend `---\nunsafe: true\n---\n`
  - frontmatter without `unsafe:` key:       insert `unsafe: true` at top of frontmatter
  - frontmatter with `unsafe: false` (etc):  replace with `unsafe: true`
  - frontmatter with `unsafe: true`:         no-op
"""

import json
import os
import re
import sys

# Match {layer}/doc/...md anywhere (spec or narrative). Path separator
# can be / or \ on Windows.
DOC_RE = re.compile(
    r'[/\\](awt|awt-c|framework)[/\\]doc[/\\].*\.md$',
    re.IGNORECASE,
)


def update_frontmatter(content: str) -> str:
    """Return content with `unsafe: true` ensured. Adds frontmatter if missing."""
    lines = content.splitlines(keepends=True)

    # No frontmatter: prepend.
    if not lines or lines[0].rstrip('\r\n') != '---':
        return '---\nunsafe: true\n---\n\n' + content

    # Find closing `---`.
    end = None
    for i in range(1, len(lines)):
        if lines[i].rstrip('\r\n') == '---':
            end = i
            break
    if end is None:
        # Malformed; leave alone.
        return content

    # Look for an existing `unsafe:` line inside the frontmatter body.
    unsafe_re = re.compile(r'^unsafe:\s*(\S+)\s*$')
    for i in range(1, end):
        m = unsafe_re.match(lines[i].rstrip('\r\n'))
        if not m:
            continue
        if m.group(1) == 'true':
            return content  # already true; no-op
        new_lines = lines[:]
        new_lines[i] = 'unsafe: true\n'
        return ''.join(new_lines)

    # No `unsafe:` key: insert right after the opening `---`.
    return ''.join([lines[0], 'unsafe: true\n'] + lines[1:])


def mark_unsafe(path: str) -> None:
    with open(path, 'r', encoding='utf-8', newline='') as f:
        content = f.read()
    new_content = update_frontmatter(content)
    if new_content == content:
        return
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(new_content)


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0

    file_path = (payload.get('tool_input') or {}).get('file_path') or ''
    if not file_path:
        return 0
    if not DOC_RE.search(file_path):
        return 0
    if not os.path.isfile(file_path):
        return 0

    try:
        mark_unsafe(file_path)
    except Exception:
        # Hooks must not block tool calls. Swallow errors silently.
        pass
    return 0


if __name__ == '__main__':
    sys.exit(main())
