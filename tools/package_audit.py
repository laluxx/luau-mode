#!/usr/bin/env python3
"""Offline MELPA-readiness source audit; never replaces package-lint or ERT."""
from __future__ import annotations

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
MODE = (ROOT / 'luau-mode.el').read_text(encoding='utf-8')
LSP = (ROOT / 'luau-lsp.el').read_text(encoding='utf-8')
MAKE = (ROOT / 'luau-make.el').read_text(encoding='utf-8')
ROBLOX = (ROOT / 'luau-roblox.el').read_text(encoding='utf-8')
INTERFACE = (ROOT / 'luau-interface.el').read_text(encoding='utf-8')
SOURCES = MODE + '\n' + LSP + '\n' + MAKE + '\n' + ROBLOX + '\n' + INTERFACE


def names(kind: str) -> list[str]:
    return re.findall(r'\(' + kind + r'\s+(luau-[a-z0-9-]+)', SOURCES)


def main() -> int:
    checks = {
        'Copyright and original Lua attribution': 'Free Software Foundation' in MODE
        and 'Based on GNU Emacs lua-mode.el' in MODE,
        'Package-Requires metadata': 'Package-Requires:' in MODE,
        'Author attribution': 'Author: laluxx' in MODE,
        'SPDX or GPL license': 'GPL' in MODE and (ROOT / 'COPYING').is_file(),
        'Autoloaded .luau files': bool(re.search(r';;;###autoload\s*\n\(add-to-list\s+\x27auto-mode-alist\s+\x27\("', MODE)),
        'Standalone dependency graph': "(require 'lua-mode)" not in SOURCES,
        'Explicit LSP language registration': "(luau-mode . \"luau\")" in LSP,
        'Eager client registration hook': '(luau-lsp--register-lsp-mode)' in MODE
        and '(eval-after-load ' not in LSP
        and '(with-eval-after-load ' not in LSP,
        'Customizable language-server command': 'defcustom luau-lsp-command' in LSP,
        'Explicit Roblox API download only': '(defun luau-roblox-api-install' in ROBLOX and '(luau-roblox-api-install)' not in LSP,
        'Roblox API cache wired to LSP': '(luau-roblox-api-arguments)' in LSP,
        'Roblox API runtime recovery':
        'defun luau-lsp--roblox-arguments' in LSP
        and '(luau-lsp--roblox-arguments)' in LSP,
        'Live Creator Hub documentation command':
        'defun luau-roblox-doc-at-point' in ROBLOX
        and '(kbd "C-c C-o")' in MODE,
        'Standalone annotated Imenu and Eldoc':
        'defun luau-interface-imenu-annotate' in INTERFACE
        and 'defun luau-interface-eldoc' in INTERFACE,
        'Matching region inherited face':
        "(defface luau-interface-match-face" in INTERFACE
        and "'((t :inherit region))" in INTERFACE,
        'New UI checks routed through make check':
        'test-interface' in (ROOT / 'Makefile').read_text()
        and 'test-interface' in (ROOT / 'tools/make_ui.py').read_text(),
        'Isolated package distribution includes interface':
        '"luau-interface.el"' in (ROOT / 'tools/build_release.py').read_text(),
        'Checkdoc compliant installation message':
        '(error "Package.el did not install luau-mode")' in
        (ROOT / 'test/batch-package-install.el').read_text(encoding='utf-8'),
        'Make check reports installed source cycle':
        'development_cycle' in (ROOT / 'tools/make_ui.py').read_text(encoding='utf-8')
        and 'package_version' in (ROOT / 'tools/make_ui.py').read_text(encoding='utf-8'),
        'Roblox API status declaration':
        '(declare-function luau-roblox-api-status "luau-roblox" ())' in MODE,
        'Roblox auxiliary module has no ineffective Package-Requires':
        'Package-Requires:' not in ROBLOX,
        'Roblox JSON punctuation literals are escaped':
        r'?\[' in ROBLOX and r'?\{' in ROBLOX
        and not re.search(r'(?<!\\)\?\[', ROBLOX),
        'Roblox API declared for package lint': '"luau-roblox.el"' in (ROOT / 'test/luau-doctor.el').read_text(),
        'Single Make quality entry': 'check:' in (ROOT / 'Makefile').read_text()
        and '$(MAKE_UI) bundle' in (ROOT / 'Makefile').read_text(),
    }
    defs = names('defface')
    opts = names('defcustom')
    checks['Unique face declarations'] = bool(defs) and len(defs) == len(set(defs))
    checks['Unique customizable options'] = bool(opts) and len(opts) == len(set(opts))
    checks['All faces inherit theme roles'] = all(
        re.search(r'\(defface ' + re.escape(face) + r'\s+\x27\(\(t\s+:inherit\s+',
                  SOURCES) for face in defs)
    # A bare custom face in a font-lock keyword is treated as a Lisp variable
    # by font-lock; this was the source of the user's void-variable failure.
    checks['No unquoted base face expressions'] = not bool(re.search(
        r'\([1-9]\s+(luau-[a-z-]+-face)\b', MODE)) and not bool(re.search(
        r'\.\s+(luau-[a-z-]+-face)\b', MODE))
    checks['ANSI check bridge available'] = ('ansi-color-compilation-filter' in MAKE
                                            and 'defun luau-make-check' in MAKE)
    checks['Font lock retains match bounds'] = (
        'defun luau--font-lock-syntax-state' in MODE
        and '(save-match-data (syntax-ppss position))' in MODE)
    checks['No Emacs 31 obsolete formatter call on new builds'] = (
        'version< emacs-version "31.1"' in MODE
        and 'replace-region-contents' in MODE)
    checks['Report archive contains source hashes'] = 'source-sha256.txt' in (
        ROOT / 'tools/make_ui.py').read_text()
    print('\nLUAU MODE / OFFLINE PACKAGE AUDIT')
    print('-' * 69)
    failed = []
    for item, passed in checks.items():
        print(f"  {'PASS' if passed else 'FAIL'}   {item}")
        if not passed:
            failed.append(item)
    print(f'  Faces: {len(defs)} | Custom options: {len(opts)} | Checks: {len(checks)}')
    print('  IMPORTANT: package-lint, byte-compiler and ERT must run in Emacs.')
    if failed:
        print('  Failed: ' + ', '.join(failed), file=sys.stderr)
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
