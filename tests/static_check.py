#!/usr/bin/env python3
"""Best-effort static structural checks without a local Emacs binary."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
paths = sorted(root.rglob('*.el'))


def check_balance(path):
    source = path.read_text()
    stack = []
    i = 0
    line = 1
    in_string = False
    in_comment = False
    while i < len(source):
        c = source[i]
        if c == '\n':
            line += 1
            in_comment = False
            i += 1
            continue
        if in_comment:
            i += 1
            continue
        if in_string:
            if c == '\\':
                i += 2
                continue
            if c == '"':
                in_string = False
            i += 1
            continue
        if c == ';':
            in_comment = True
        elif c == '"':
            in_string = True
        elif c == '?' and i + 1 < len(source) and (i == 0 or not source[i - 1].isalnum()):
            i += 1
            if source[i] == '\\' and i + 1 < len(source):
                i += 1
        elif c == '(':
            stack.append(line)
        elif c == ')':
            if not stack:
                raise AssertionError(f'{path}: unmatched ) at line {line}')
            stack.pop()
        i += 1
    if in_string or stack:
        raise AssertionError(f'{path}: unterminated string/form; {stack[-3:]}')


for file in paths:
    check_balance(file)
    print(f'[STATIC PASS] {file.relative_to(root)}')

content = (root / 'luau-mode.el').read_text()
for name in ('luau-mode', 'luau-rojo-serve', 'luau-rojo-stop',
             'luau-project-variables', 'luau-inspect-camera',
             'luau-setup-language-server', 'luau-flymake', 'luau-format-buffer'):
    assert re.search(r'\((?:defun|define-derived-mode|define-minor-mode)\s+' + re.escape(name) + r'\b', content), name
assert not re.search(r"\(require\s+'lua-mode\)", content)
assert content.endswith(';;; luau-mode.el ends here\n')
print(f'[STATIC PASS] standalone mode and project APIs; {len(paths)} Elisp files scanned')
print('NOTE: static checks do not replace Emacs byte-compilation, Checkdoc, or ERT.')
